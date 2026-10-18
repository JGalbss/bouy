//! Classes (section 9): actor classes and error classes.

use std::collections::HashSet;

use oxc::ast::ast::{
    Argument, Class, ClassElement, Expression, Function, IdentifierReference,
    ImportDeclarationSpecifier, MethodDefinition, MethodDefinitionKind, Program,
    PropertyDefinition, PropertyKey, Statement, TSAccessibility, ThisExpression,
};
use oxc::ast_visit::Visit;
use oxc::semantic::{Scoping, SymbolId};
use oxc::span::Span;
use oxc::syntax::scope::ScopeFlags;

use super::expr::{argument_expression, class_value, field_key, field_write};
use super::function::Callable;
use super::rebind::{Rebound, Roots, strip};
use super::scope::{Scope, Target};
use super::{Frame, Lowerer, Tail};
use crate::erlang::{self, Clause, Expr};

/// What a class compiles to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClassKind {
    /// A class without `extends`: an actor class.
    Actor,
    Error(ErrorBase),
    /// A class with a base that Buoy cannot lower, already reported (`BUOY206`).
    Unsupported,
}

/// The base of an error class.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorBase {
    /// `extends Error`, or another global error class.
    Global(String),
    /// `extends Data.TaggedError("Tag")`.
    Tagged(String),
    /// `extends Data.Error`.
    Data,
}

impl ClassKind {
    pub fn is_error(&self) -> bool {
        matches!(self, Self::Error(_))
    }
}

/// The class whose methods are being lowered.
#[derive(Debug, Clone)]
pub struct ClassContext {
    pub name: String,
    /// The method names, with `#` for private methods.
    pub methods: HashSet<String>,
    /// The methods that rebind `this`, directly or through `this.m()` calls. A call to
    /// another method leaves `This` as it was.
    pub mutating: HashSet<String>,
    /// The methods that always end with `return this`, so that `this.m(a).n(b)` calls `n`
    /// on `this` too.
    pub fluent: HashSet<String>,
}

/// The kind of `class`, or `None` when it extends something Buoy cannot lower. A base
/// resolves as a name does: `Error` is the global only when no declaration shadows it, and
/// `Data.TaggedError("Tag")` needs `Data` from "effect", whose local names are `data`.
pub fn classify(
    class: &Class<'_>,
    scoping: &Scoping,
    data: &HashSet<SymbolId>,
) -> Option<ClassKind> {
    let Some(heritage) = &class.heritage else {
        return Some(ClassKind::Actor);
    };
    let symbol = |ident: &IdentifierReference<'_>| {
        ident
            .reference_id
            .get()
            .and_then(|id| scoping.get_reference(id).symbol_id())
    };
    let is_data = |expression: &Expression<'_>| {
        matches!(strip(expression), Expression::Identifier(ident)
            if symbol(ident).is_some_and(|symbol| data.contains(&symbol)))
    };
    match strip(&heritage.expression) {
        Expression::Identifier(ident)
            if matches!(
                ident.name.as_str(),
                "Error" | "TypeError" | "RangeError" | "SyntaxError"
            ) && symbol(ident).is_none() =>
        {
            Some(ClassKind::Error(ErrorBase::Global(ident.name.to_string())))
        }
        Expression::CallExpression(call) => {
            match (strip(&call.callee), call.arguments.as_slice()) {
                (Expression::StaticMemberExpression(member), [Argument::StringLiteral(tag)])
                    if member.property.name == "TaggedError" && is_data(&member.object) =>
                {
                    Some(ClassKind::Error(ErrorBase::Tagged(tag.value.to_string())))
                }
                _ => None,
            }
        }
        Expression::StaticMemberExpression(member)
            if member.property.name == "Error" && is_data(&member.object) =>
        {
            Some(ClassKind::Error(ErrorBase::Data))
        }
        _ => None,
    }
}

/// The local names of `Data` from "effect": `import { Data } from "effect"` and
/// `import * as Data from "effect/Data"`.
pub fn data_imports(program: &Program<'_>) -> HashSet<SymbolId> {
    program
        .body
        .iter()
        .filter_map(|statement| match statement {
            Statement::ImportDeclaration(import) => Some(import),
            _ => None,
        })
        .flat_map(|import| {
            let specifier = import.source.value.as_str();
            import
                .specifiers
                .iter()
                .flatten()
                .filter(move |item| match item {
                    ImportDeclarationSpecifier::ImportSpecifier(named) => {
                        specifier == "effect" && named.imported.name() == "Data"
                    }
                    ImportDeclarationSpecifier::ImportNamespaceSpecifier(_) => {
                        specifier == "effect/Data"
                    }
                    ImportDeclarationSpecifier::ImportDefaultSpecifier(_) => false,
                })
                .filter_map(|item| item.local().symbol_id.get())
        })
        .collect()
}

/// The methods of `class` that rebind `this`: they assign to, update, delete, or call a
/// mutator on a property of `this`, or call such a method through `this.m()`.
pub fn mutating_methods(class: &Class<'_>, roots: &Roots<'_>) -> HashSet<String> {
    let none = HashSet::new();
    let mut mutating = HashSet::new();
    let mut calls: Vec<(String, HashSet<String>)> = Vec::new();
    for element in &class.body.body {
        let ClassElement::MethodDefinition(method) = element else {
            continue;
        };
        let (Some(name), Some(body)) = (key_name(&method.key), &method.value.body) else {
            continue;
        };
        let mut rebound = Rebound::new(roots, Some(&none), Span::default());
        rebound.visit_function_body(body);
        if rebound.finish().contains(&Target::This) {
            mutating.insert(name.clone());
        }
        let mut called = ThisCalls(HashSet::new());
        called.visit_function_body(body);
        calls.push((name, called.0));
    }
    loop {
        let before = mutating.len();
        for (name, callees) in &calls {
            if callees.iter().any(|callee| mutating.contains(callee)) {
                mutating.insert(name.clone());
            }
        }
        if mutating.len() == before {
            return mutating;
        }
    }
}

/// The names of the methods that a body calls through `this.m()`, outside closures.
struct ThisCalls(HashSet<String>);

impl<'a> Visit<'a> for ThisCalls {
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}

    fn visit_arrow_function_expression(
        &mut self,
        _it: &oxc::ast::ast::ArrowFunctionExpression<'a>,
    ) {
    }

    fn visit_call_expression(&mut self, it: &oxc::ast::ast::CallExpression<'a>) {
        let name = match strip(&it.callee) {
            Expression::StaticMemberExpression(member)
                if matches!(strip(&member.object), Expression::ThisExpression(_)) =>
            {
                Some(member.property.name.to_string())
            }
            Expression::PrivateFieldExpression(member)
                if matches!(strip(&member.object), Expression::ThisExpression(_)) =>
            {
                Some(format!("#{}", member.field.name))
            }
            _ => None,
        };
        self.0.extend(name);
        oxc::ast_visit::walk::walk_call_expression(self, it);
    }
}

/// The name of a method or field key: `m`, or `#m` for a private name.
pub fn key_name(key: &PropertyKey<'_>) -> Option<String> {
    match key {
        PropertyKey::PrivateIdentifier(private) => Some(format!("#{}", private.name)),
        other => other.static_name().map(|name| name.to_string()),
    }
}

impl<'a> Lowerer<'a, '_> {
    /// The Erlang functions of a module-level class.
    pub fn class(&mut self, class: &'a Class<'a>) -> Vec<erlang::Function> {
        let Some(id) = &class.id else {
            return Vec::new();
        };
        if class.declare {
            return Vec::new();
        }
        let name = id.name.to_string();
        let Some(kind) = classify(class, self.semantic.scoping(), &self.module.data) else {
            self.unsupported(
                class.span,
                "class inheritance is supported only for error classes: extends Error, TypeError, RangeError, or SyntaxError, or Data.TaggedError(\"Tag\") or Data.Error with `Data` from \"effect\"",
            );
            return Vec::new();
        };
        if let Some(decorator) = class.decorators.first() {
            self.unsupported(decorator.span, "decorators are not supported");
        }
        self.check_members(class, &kind);
        let functions = match kind {
            ClassKind::Actor => self.actor_class(class, &name),
            ClassKind::Error(base) => vec![self.error_class(class, &name, &base)],
            ClassKind::Unsupported => Vec::new(),
        };
        self.class = None;
        functions
    }

    fn check_members(&mut self, class: &'a Class<'a>, kind: &ClassKind) {
        let decorators = class.body.body.iter().flat_map(|element| match element {
            ClassElement::MethodDefinition(method) => method
                .decorators
                .iter()
                .chain(
                    method
                        .value
                        .params
                        .items
                        .iter()
                        .flat_map(|param| &param.decorators),
                )
                .collect::<Vec<_>>(),
            ClassElement::PropertyDefinition(property) => property.decorators.iter().collect(),
            _ => Vec::new(),
        });
        let spans: Vec<_> = decorators.map(|decorator| decorator.span).collect();
        for span in spans {
            self.unsupported(span, "decorators are not supported");
        }
        for element in &class.body.body {
            match element {
                ClassElement::StaticBlock(block) => {
                    self.unsupported(block.span, "static blocks are not supported");
                }
                ClassElement::AccessorProperty(accessor) => {
                    self.unsupported(accessor.span, "accessor properties are not supported");
                }
                ClassElement::MethodDefinition(method) => {
                    if method.r#static {
                        self.unsupported(
                            method.span,
                            "static class members are not supported; use a module-level function",
                        );
                    } else if matches!(
                        method.kind,
                        MethodDefinitionKind::Get | MethodDefinitionKind::Set
                    ) {
                        self.unsupported(
                            method.span,
                            "getters and setters are not supported; use a method",
                        );
                    } else if method.computed || key_name(&method.key).is_none() {
                        self.unsupported(method.span, "computed method names are not supported");
                    } else if kind.is_error() && method.kind == MethodDefinitionKind::Method {
                        self.unsupported(
                            method.span,
                            "an error class may declare fields and a constructor, and no methods",
                        );
                    }
                }
                ClassElement::PropertyDefinition(property) => {
                    if property.r#static {
                        self.unsupported(
                            property.span,
                            "static class members are not supported; use a module-level const",
                        );
                    } else if property.computed || key_name(&property.key).is_none() {
                        self.unsupported(property.span, "computed field names are not supported");
                    }
                }
                ClassElement::TSIndexSignature(_) => {}
            }
        }
    }

    fn actor_class(&mut self, class: &'a Class<'a>, name: &str) -> Vec<erlang::Function> {
        let methods: Vec<&'a MethodDefinition<'a>> = class
            .body
            .body
            .iter()
            .filter_map(|element| match element {
                ClassElement::MethodDefinition(method)
                    if method.kind == MethodDefinitionKind::Method
                        && !method.r#static
                        && method.value.body.is_some() =>
                {
                    Some(&**method)
                }
                _ => None,
            })
            .collect();
        let names: Vec<String> = methods
            .iter()
            .filter_map(|method| key_name(&method.key))
            .collect();
        let mutating = mutating_methods(class, &self.roots);
        let fluent = methods
            .iter()
            .zip(&names)
            .filter(|(method, _)| returns_this(&method.value))
            .map(|(_, name)| name.clone())
            .collect();
        self.class = Some(ClassContext {
            name: name.to_owned(),
            methods: names.iter().cloned().collect(),
            mutating,
            fluent,
        });
        let constructor = self.actor_constructor(class, name);
        let pure = is_pure(&constructor);
        let mut functions = vec![constructor];
        if pure {
            functions.push(pure_marker(name));
        }
        for (method, key) in methods.iter().zip(&names) {
            functions.push(self.method(name, key, &method.value));
        }
        let public: Vec<&String> = methods
            .iter()
            .zip(&names)
            .filter(|(method, key)| {
                !key.starts_with('#')
                    && !matches!(
                        method.accessibility,
                        Some(TSAccessibility::Private | TSAccessibility::Protected)
                    )
            })
            .map(|(_, key)| key)
            .collect();
        functions.push(dispatch(name, &public));
        functions
    }

    fn start_function(&mut self, frame: Frame) {
        self.scope = Scope::default();
        self.frame = frame;
        self.seq.clear();
        self.targets.clear();
        self.rests.clear();
        self.checkpoints.clear();
    }

    /// `'C#new'(Args) -> This`: parameters, then fields in order, then the constructor body.
    fn actor_constructor(&mut self, class: &'a Class<'a>, name: &str) -> erlang::Function {
        self.start_function(Frame::Constructor);
        let constructor = constructor(class);
        if let Some(constructor) = constructor {
            self.bind_params(&constructor.params, "Args");
        }
        let fields = fields(class);
        if fields
            .iter()
            .any(|field| field.value.as_ref().is_some_and(mentions_this))
        {
            self.scope.set(Target::This, "This".to_owned());
            self.seq
                .push(Expr::matches(Expr::var("This"), Expr::Map(Vec::new())));
            self.set_fields(&fields);
        } else {
            let values: Vec<&'a Expression<'a>> = fields
                .iter()
                .filter_map(|field| field.value.as_ref())
                .collect();
            let mut values = self.ordered(&values).into_iter();
            let entries = fields
                .iter()
                .filter_map(|field| {
                    let value = match field.value {
                        Some(_) => values.next().unwrap_or_else(Expr::undefined),
                        None => Expr::undefined(),
                    };
                    key_name(&field.key).map(|key| (field_key(&key), value))
                })
                .collect();
            self.scope.set(Target::This, "This".to_owned());
            self.seq
                .push(Expr::matches(Expr::var("This"), Expr::Map(entries)));
        }
        if let Some(constructor) = constructor {
            self.parameter_properties(constructor);
        }
        let statements: Vec<&'a Statement<'a>> = constructor
            .and_then(|constructor| constructor.body.as_ref())
            .map(|body| body.statements.iter().collect())
            .unwrap_or_default();
        self.block_of(&statements, &Tail::Function);
        erlang::Function {
            name: format!("{name}#new"),
            clauses: vec![Clause::new(
                Expr::var("Args"),
                std::mem::take(&mut self.seq),
            )],
        }
    }

    fn set_fields(&mut self, fields: &[&'a PropertyDefinition<'a>]) {
        for field in fields {
            let Some(key) = key_name(&field.key) else {
                continue;
            };
            let value = field
                .value
                .as_ref()
                .map_or_else(Expr::undefined, |value| self.expr(value));
            self.set_this(&key, value);
        }
    }

    fn set_this(&mut self, key: &str, value: Expr) {
        let this = self
            .scope
            .current(Target::This)
            .map_or_else(Expr::undefined, Expr::var);
        let next = self.scope.bind(Target::This, "This");
        self.push_match(Expr::Var(next), field_write(this, &field_key(key), value));
    }

    /// TypeScript parameter properties: `constructor(private name: string)`.
    fn parameter_properties(&mut self, constructor: &'a Function<'a>) {
        for param in &constructor.params.items {
            if param.accessibility.is_none() && !param.readonly {
                continue;
            }
            let Some(id) = param.pattern.get_binding_identifier() else {
                continue;
            };
            let value = id
                .symbol_id
                .get()
                .and_then(|symbol| self.scope.current(Target::Symbol(symbol)))
                .map_or_else(Expr::undefined, Expr::var);
            self.set_this(&id.name, value);
        }
    }

    /// `'C#m'(This, Args) -> {Result, This1}`.
    fn method(&mut self, class: &str, key: &str, function: &'a Function<'a>) -> erlang::Function {
        self.start_function(Frame::Method);
        self.scope.set(Target::This, "This".to_owned());
        let body = self.function_body("Args", Callable::Function(function));
        erlang::Function {
            name: format!("{class}#{key}"),
            clauses: vec![Clause {
                patterns: vec![Expr::var("This"), Expr::var("Args")],
                guards: Vec::new(),
                body,
            }],
        }
    }

    /// `'E#new'(Args)` for an error class: an error value from `buoy_error:new/3`.
    fn error_class(
        &mut self,
        class: &'a Class<'a>,
        name: &str,
        base: &ErrorBase,
    ) -> erlang::Function {
        self.start_function(Frame::Constructor);
        let fields = fields(class);
        let body: Vec<&'a Statement<'a>> = match constructor(class) {
            None => {
                let first = Expr::rt("arg", vec![Expr::Integer(1), Expr::var("Args")]);
                let options = Expr::rt("arg", vec![Expr::Integer(2), Expr::var("Args")]);
                self.build_error(name, base, first, options);
                Vec::new()
            }
            Some(constructor) => {
                self.bind_params(&constructor.params, "Args");
                let statements: Vec<&'a Statement<'a>> = constructor
                    .body
                    .as_ref()
                    .map(|body| body.statements.iter().collect())
                    .unwrap_or_default();
                let call = statements.split_first().and_then(|(first, rest)| {
                    super_arguments(first).map(|arguments| (arguments, rest))
                });
                let Some((arguments, rest)) = call else {
                    self.unsupported(
                        constructor.span,
                        "an error class constructor must call `super(...)` as its first statement",
                    );
                    return self.finish_error(name, fields, None, &[]);
                };
                let operands: Vec<&'a Expression<'a>> =
                    arguments.iter().map(argument_expression).collect();
                let mut values = self.ordered(&operands).into_iter();
                let first = values.next().unwrap_or_else(Expr::undefined);
                let options = values.next().unwrap_or_else(Expr::undefined);
                self.build_error(name, base, first, options);
                return self.finish_error(name, fields, Some(constructor), rest);
            }
        };
        self.finish_error(name, fields, None, &body)
    }

    /// Sets the initialized fields and the parameter properties, then runs the rest of the
    /// constructor body.
    fn finish_error(
        &mut self,
        name: &str,
        fields: Vec<&'a PropertyDefinition<'a>>,
        constructor: Option<&'a Function<'a>>,
        body: &[&'a Statement<'a>],
    ) -> erlang::Function {
        let initialized: Vec<&'a PropertyDefinition<'a>> = fields
            .into_iter()
            .filter(|field| field.value.is_some())
            .collect();
        self.set_fields(&initialized);
        if let Some(constructor) = constructor {
            self.parameter_properties(constructor);
        }
        self.block_of(body, &Tail::Function);
        erlang::Function {
            name: format!("{name}#new"),
            clauses: vec![Clause::new(
                Expr::var("Args"),
                std::mem::take(&mut self.seq),
            )],
        }
    }

    /// Binds `This` to the error value that `super(first, options)` builds. The `cause` of
    /// `options` becomes a field, as the global error classes do.
    fn build_error(&mut self, name: &str, base: &ErrorBase, first: Expr, options: Expr) {
        let (message, fields) = match base {
            ErrorBase::Global(_) => {
                let message = self.message(first);
                let fields = if options == Expr::undefined() {
                    Expr::Map(Vec::new())
                } else {
                    let given = self.scope.temp();
                    let key = || Expr::binary("cause");
                    let has_cause = Expr::op(
                        "andalso",
                        Expr::call("erlang", "is_map", vec![Expr::var(&given)]),
                        Expr::call("erlang", "is_map_key", vec![key(), Expr::var(&given)]),
                    );
                    let cause = Expr::call("maps", "get", vec![key(), Expr::var(&given)]);
                    Expr::case(
                        options,
                        vec![
                            Clause::guarded(
                                Expr::var(&given),
                                vec![has_cause],
                                vec![Expr::Map(vec![(key(), cause)])],
                            ),
                            Clause::new(Expr::var("_"), vec![Expr::Map(Vec::new())]),
                        ],
                    )
                };
                (message, fields)
            }
            ErrorBase::Tagged(_) | ErrorBase::Data => {
                let props = self.scope.temp();
                let given = self.scope.temp();
                self.seq.push(Expr::matches(
                    Expr::var(&props),
                    Expr::case(
                        first,
                        vec![
                            Clause::new(Expr::undefined(), vec![Expr::Map(Vec::new())]),
                            Clause::new(Expr::var(&given), vec![Expr::Var(given)]),
                        ],
                    ),
                ));
                let message = self.message(Expr::rt(
                    "get",
                    vec![Expr::var(&props), Expr::binary("message")],
                ));
                let fields = match base {
                    ErrorBase::Tagged(tag) => Expr::rt(
                        "set",
                        vec![
                            Expr::var(&props),
                            Expr::binary("_tag"),
                            Expr::binary(tag.as_str()),
                        ],
                    ),
                    _ => Expr::Var(props),
                };
                (message, fields)
            }
        };
        let global = match base {
            ErrorBase::Global(global) => global.as_str(),
            ErrorBase::Tagged(_) | ErrorBase::Data => "Error",
        };
        let classes = Expr::List(vec![
            class_value(&self.module.name, name),
            class_value("buoy_error", global),
        ]);
        let this = self.scope.bind(Target::This, "This");
        self.push_match(
            Expr::Var(this),
            Expr::call("buoy_error", "new", vec![classes, message, fields]),
        );
    }

    /// The message of an error: `<<>>` for `undefined`, else the value as a string.
    fn message(&mut self, value: Expr) -> Expr {
        let concatenated = matches!(&value, Expr::Call { module: Some(module), function, .. } if module == "buoy_rt" && function == "concat");
        if matches!(value, Expr::Binary(_)) || concatenated {
            return value;
        }
        let present = self.scope.temp();
        Expr::case(
            value,
            vec![
                Clause::new(Expr::undefined(), vec![Expr::binary("")]),
                Clause::new(
                    Expr::var(&present),
                    vec![Expr::rt("to_string", vec![Expr::Var(present)])],
                ),
            ],
        )
    }
}

/// `'C#dispatch'(Method, This, Args)`: one clause for each public method.
/// The calls that a pure constructor may make: each one returns a value and cannot throw.
const PURE_CALLS: [(&str, &str, usize); 4] = [
    ("buoy_rt", "arg", 2),
    ("buoy_rt", "rest", 2),
    ("maps", "put", 3),
    ("maps", "get", 3),
];

/// The operators that a pure constructor may use: none of them throws.
const PURE_OPERATORS: [&str; 6] = ["=:=", "=/=", "==", "/=", "andalso", "orelse"];

/// Whether `'C#new'` has no effect and cannot throw: it binds its arguments and builds
/// `This` from literals and arguments only. `spawn` runs such a constructor in the calling
/// process and starts the actor without a wait (section 9).
fn is_pure(constructor: &erlang::Function) -> bool {
    constructor
        .clauses
        .iter()
        .all(|clause| clause.guards.is_empty() && clause.body.iter().all(pure_expr))
}

fn pure_expr(expr: &Expr) -> bool {
    match expr {
        Expr::Var(_) | Expr::Atom(_) | Expr::Integer(_) | Expr::Float(_) | Expr::Binary(_) => true,
        Expr::Tuple(items) | Expr::List(items) | Expr::Block(items) => items.iter().all(pure_expr),
        Expr::Cons(items, tail) => items.iter().all(pure_expr) && pure_expr(tail),
        Expr::Map(entries) => entries
            .iter()
            .all(|(key, value)| pure_expr(key) && pure_expr(value)),
        // A match binds a fresh variable, so it cannot fail.
        Expr::Match(pattern, value) => matches!(**pattern, Expr::Var(_)) && pure_expr(value),
        // A case whose last clause takes any value cannot fail.
        Expr::Case(subject, clauses) => {
            pure_expr(subject)
                && clauses.last().is_some_and(|last| {
                    last.guards.is_empty() && matches!(last.patterns.as_slice(), [Expr::Var(_)])
                })
                && clauses.iter().all(|clause| {
                    clause.patterns.iter().all(pure_expr)
                        && clause.guards.iter().all(pure_expr)
                        && clause.body.iter().all(pure_expr)
                })
        }
        Expr::Op(operator, left, right) => {
            PURE_OPERATORS.contains(operator) && pure_expr(left) && pure_expr(right)
        }
        Expr::Not(operand) => pure_expr(operand),
        Expr::Call {
            module: Some(module),
            function,
            args,
        } => {
            PURE_CALLS.contains(&(module.as_str(), function.as_str(), args.len()))
                && args.iter().all(pure_expr)
        }
        _ => false,
    }
}

/// `'C#pure'() -> true`, the mark of a pure constructor.
fn pure_marker(class: &str) -> erlang::Function {
    erlang::Function {
        name: format!("{class}#pure"),
        clauses: vec![Clause {
            patterns: Vec::new(),
            guards: Vec::new(),
            body: vec![Expr::atom("true")],
        }],
    }
}

fn dispatch(class: &str, methods: &[&String]) -> erlang::Function {
    let mut clauses: Vec<Clause> = methods
        .iter()
        .map(|method| Clause {
            patterns: vec![
                Expr::binary(method.as_str()),
                Expr::var("This"),
                Expr::var("Args"),
            ],
            guards: Vec::new(),
            body: vec![Expr::local_call(
                &format!("{class}#{method}"),
                vec![Expr::var("This"), Expr::var("Args")],
            )],
        })
        .collect();
    clauses.push(Clause {
        patterns: vec![Expr::var("Method"), Expr::var("_This"), Expr::var("_Args")],
        guards: Vec::new(),
        body: vec![Expr::call(
            "buoy_error",
            "throw",
            vec![
                Expr::binary("TypeError"),
                Expr::rt(
                    "concat",
                    vec![Expr::List(vec![
                        Expr::binary(format!("{class}.")),
                        Expr::var("Method"),
                        Expr::binary(" is not a function"),
                    ])],
                ),
            ],
        )],
    });
    erlang::Function {
        name: format!("{class}#dispatch"),
        clauses,
    }
}

/// The constructor implementation: the constructor with a body, after any overload
/// signatures.
fn constructor<'a>(class: &'a Class<'a>) -> Option<&'a Function<'a>> {
    class.body.body.iter().find_map(|element| match element {
        ClassElement::MethodDefinition(method)
            if method.kind == MethodDefinitionKind::Constructor && method.value.body.is_some() =>
        {
            Some(&*method.value)
        }
        _ => None,
    })
}

fn fields<'a>(class: &'a Class<'a>) -> Vec<&'a PropertyDefinition<'a>> {
    class
        .body
        .body
        .iter()
        .filter_map(|element| match element {
            ClassElement::PropertyDefinition(property)
                if !property.r#static && !property.declare =>
            {
                Some(&**property)
            }
            _ => None,
        })
        .collect()
}

/// The arguments of `super(...)` when `statement` is that call.
fn super_arguments<'a>(statement: &'a Statement<'a>) -> Option<&'a [Argument<'a>]> {
    let Statement::ExpressionStatement(statement) = statement else {
        return None;
    };
    match strip(&statement.expression) {
        Expression::CallExpression(call) if matches!(call.callee, Expression::Super(_)) => {
            Some(&call.arguments)
        }
        _ => None,
    }
}

/// Whether every way out of `function` is `return this`.
fn returns_this(function: &Function<'_>) -> bool {
    struct Returns {
        this: bool,
    }
    impl<'a> Visit<'a> for Returns {
        fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
        fn visit_arrow_function_expression(
            &mut self,
            _it: &oxc::ast::ast::ArrowFunctionExpression<'a>,
        ) {
        }
        fn visit_return_statement(&mut self, it: &oxc::ast::ast::ReturnStatement<'a>) {
            self.this &= it
                .argument
                .as_ref()
                .is_some_and(|value| matches!(strip(value), Expression::ThisExpression(_)));
        }
    }
    let Some(body) = &function.body else {
        return false;
    };
    let ends = matches!(body.statements.last(), Some(Statement::ReturnStatement(_)));
    let mut returns = Returns { this: true };
    returns.visit_function_body(body);
    ends && returns.this
}

/// Whether `expression` reads `this`, outside nested non-arrow functions.
fn mentions_this(expression: &Expression<'_>) -> bool {
    struct Finder(bool);
    impl<'a> Visit<'a> for Finder {
        fn visit_this_expression(&mut self, _it: &ThisExpression) {
            self.0 = true;
        }
        fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
    }
    let mut finder = Finder(false);
    finder.visit_expression(expression);
    finder.0
}
