//! Expressions (sections 4, 5, 6, and 11).
//!
//! An expression lowers to one Erlang expression. A rebinding (an assignment, an update, or
//! a mutating call) is pushed into the statement sequence instead, so that the new version
//! is visible to the code after it. When a later operand rebinds, earlier operands are bound
//! to temporaries first, which keeps JavaScript's left-to-right evaluation order.

use oxc::ast::ast::{
    Argument, ArrayExpression, ArrayExpressionElement, BinaryExpression, CallExpression,
    ChainElement, ChainExpression, ConditionalExpression, Expression, IdentifierReference,
    LogicalExpression, NewExpression, ObjectExpression, ObjectPropertyKind, PropertyKey,
    PropertyKind, SequenceExpression, StringLiteral, TemplateLiteral, UnaryExpression,
    YieldExpression,
};
use oxc::semantic::SymbolId;
use oxc::span::{GetSpan, Span};
use oxc::syntax::operator::{BinaryOperator, LogicalOperator, UnaryOperator};

use super::class::ClassKind;
use super::function::Callable;
use super::place::arithmetic_function;
use super::rebind::{MUTATORS, chain_base, method_callee, strip};
use super::scope::{Target, base_name};
use super::stmt::boolean_case;
use super::{Binding, Lowerer};
use crate::diagnostic::Code;
use crate::erlang::{Clause, Expr};
use crate::graph::ExportKind;
use crate::library;

/// What the object of `X.m(...)` or `X.p` names, when it is not an ordinary value.
enum Namespace {
    /// An Erlang namespace module, such as `bouy_math` for `Math`.
    Module(&'static str),
    /// `import * as m from "./m.ts"`.
    Bouy(String),
    Process,
}

/// One link of an optional chain.
enum Link<'a> {
    Get {
        key: Key<'a>,
        optional: bool,
    },
    Call {
        arguments: &'a [Argument<'a>],
        optional: bool,
    },
    Method {
        key: Key<'a>,
        arguments: &'a [Argument<'a>],
        optional_get: bool,
        optional_call: bool,
    },
}

/// A property key of a member expression.
#[derive(Clone, Copy)]
pub enum Key<'a> {
    Static(&'a str),
    Private(&'a str),
    Computed(&'a Expression<'a>),
}

impl<'a> Lowerer<'a, '_> {
    pub fn expr(&mut self, expression: &'a Expression<'a>) -> Expr {
        match expression {
            Expression::BooleanLiteral(literal) => bool_atom(literal.value),
            Expression::NullLiteral(_) => Expr::atom("null"),
            Expression::NumericLiteral(literal) => number(literal.value),
            Expression::StringLiteral(literal) => self.string(literal),
            Expression::TemplateLiteral(template) => self.template(template),
            Expression::Identifier(ident) => self.identifier(ident),
            Expression::ThisExpression(this) => self.this(this.span),
            Expression::ArrayExpression(array) => self.array(array),
            Expression::ObjectExpression(object) => self.object(object),
            Expression::ArrowFunctionExpression(arrow) => {
                self.closure(None, Callable::Arrow(arrow))
            }
            Expression::FunctionExpression(function) => {
                let name = function
                    .id
                    .as_ref()
                    .and_then(|id| id.symbol_id.get().map(|symbol| (symbol, &id.name)))
                    .map(|(symbol, name)| {
                        self.scope.bind(Target::Symbol(symbol), &base_name(name))
                    });
                self.closure(name, Callable::Function(function))
            }
            Expression::AssignmentExpression(assignment) => self.assign(assignment, true),
            Expression::UpdateExpression(update) => self.update(update, true),
            Expression::AwaitExpression(await_expression) => self.expr(&await_expression.argument),
            Expression::BinaryExpression(binary) => self.binary(binary),
            Expression::LogicalExpression(logical) => self.logical(logical),
            Expression::ConditionalExpression(conditional) => self.conditional(conditional),
            Expression::SequenceExpression(sequence) => self.sequence(sequence, expression),
            Expression::UnaryExpression(unary) => self.unary(unary),
            Expression::CallExpression(call) => self.call(call),
            Expression::NewExpression(new) => self.new_expression(new),
            Expression::ChainExpression(chain) => self.chain(chain),
            Expression::ParenthesizedExpression(inner) => self.expr(&inner.expression),
            Expression::TSAsExpression(inner) => self.expr(&inner.expression),
            Expression::TSSatisfiesExpression(inner) => self.expr(&inner.expression),
            Expression::TSNonNullExpression(inner) => self.expr(&inner.expression),
            Expression::TSTypeAssertion(inner) => self.expr(&inner.expression),
            Expression::TSInstantiationExpression(inner) => self.expr(&inner.expression),
            Expression::StaticMemberExpression(member) => self.member(
                &member.object,
                Key::Static(&member.property.name),
                member.span,
            ),
            Expression::ComputedMemberExpression(member) => self.member(
                &member.object,
                Key::Computed(&member.expression),
                member.span,
            ),
            Expression::PrivateFieldExpression(member) => self.member(
                &member.object,
                Key::Private(&member.field.name),
                member.span,
            ),
            Expression::BigIntLiteral(literal) => self.unsupported(
                literal.span,
                "BigInt is not supported; integers already have arbitrary precision",
            ),
            Expression::RegExpLiteral(literal) => {
                self.unsupported(literal.span, "regular expressions are not supported yet")
            }
            Expression::YieldExpression(expression) => self.yield_effect(expression),
            Expression::ClassExpression(class) => self.unsupported(
                class.span,
                "class expressions are not supported; declare the class at module level",
            ),
            Expression::ImportExpression(import) => self.unsupported(
                import.span,
                "`import()` is not supported; use a static import",
            ),
            Expression::TaggedTemplateExpression(tagged) => {
                self.unsupported(tagged.span, "tagged templates are not supported")
            }
            Expression::Super(base) => self.unsupported(
                base.span,
                "`super` is supported only as `super(...)` in an error class constructor",
            ),
            other => self.unsupported(other.span(), "this syntax has no BEAM lowering"),
        }
    }

    /// `yield* effect` in a generator body runs the Effect: `bouy_effect:bind(Effect)`
    /// (section 13).
    fn yield_effect(&mut self, expression: &'a YieldExpression<'a>) -> Expr {
        if !expression.delegate {
            return self.unsupported(
                expression.span,
                "`yield` without `*` is not supported: a generator function is the body of an Effect, and `yield* effect` runs an Effect",
            );
        }
        let effect = expression
            .argument
            .as_ref()
            .map_or_else(Expr::undefined, |argument| self.expr(argument));
        Expr::call("bouy_effect", "bind", vec![effect])
    }

    fn conditional(&mut self, conditional: &'a ConditionalExpression<'a>) -> Expr {
        let test = self.test(&conditional.test);
        if self.emits(&conditional.consequent) || self.emits(&conditional.alternate) {
            return self.rebinding_case(
                conditional.span,
                test,
                [&conditional.consequent, &conditional.alternate],
            );
        }
        let yes = self.sub_expr(&conditional.consequent);
        let no = self.sub_expr(&conditional.alternate);
        boolean_case(test, vec![yes], vec![no])
    }

    /// `(a, b)`: the effects of `a`, then the value of `b`. When an operand rebinds a
    /// variable, the effects go to the statement sequence.
    fn sequence(
        &mut self,
        sequence: &'a SequenceExpression<'a>,
        expression: &'a Expression<'a>,
    ) -> Expr {
        let Some((last, init)) = sequence.expressions.split_last() else {
            return Expr::undefined();
        };
        if self.emits(expression) {
            for item in init {
                self.effect(item);
            }
            return self.expr(last);
        }
        self.nested(|lowerer| {
            for item in init {
                lowerer.effect(item);
            }
            lowerer.expr(last)
        })
    }

    /// Lowers `expression` for its effects. The value is dropped.
    pub fn effect(&mut self, expression: &'a Expression<'a>) {
        if let Expression::CallExpression(call) = strip(expression)
            && let Some(receiver) = self.mutated_temporary(call)
        {
            self.report(
                receiver.span(),
                Code::Unsupported,
                "this call changes a value that no variable holds, so the change is lost; store the value in a variable or a property first",
            );
        }
        match strip(expression) {
            Expression::AssignmentExpression(assignment) => {
                self.assign(assignment, false);
            }
            Expression::UpdateExpression(update) => {
                self.update(update, false);
            }
            Expression::SequenceExpression(sequence) => {
                for item in &sequence.expressions {
                    self.effect(item);
                }
            }
            _ => {
                let value = self.expr(expression);
                if let Expr::Var(name) = &value
                    && self.discard_result(name)
                {
                    return;
                }
                if !value.is_trivial() {
                    self.push(value);
                }
            }
        }
    }

    /// The receiver of a mutator call, or the target of `Object.assign`, when it is a value
    /// that no variable holds, such as the result of a call.
    fn mutated_temporary(&self, call: &'a CallExpression<'a>) -> Option<&'a Expression<'a>> {
        let receiver = if let Some(target) = self.roots.assigned_object(call) {
            target
        } else {
            let (object, name) = method_callee(&call.callee)?;
            if !MUTATORS.contains(&name.as_str()) || call.optional {
                return None;
            }
            object
        };
        let temporary = self.roots.receiver(receiver).is_none()
            && !matches!(
                chain_base(receiver),
                Expression::Identifier(_) | Expression::ThisExpression(_)
            );
        temporary.then_some(receiver)
    }

    /// Turns the unused result variable of the last `{Result, R1} = ...` into `_`. The
    /// checkpoint records that follow a binding are skipped.
    fn discard_result(&mut self, name: &str) -> bool {
        let last = self.seq.iter_mut().rev().find(|expr| {
            !matches!(expr, Expr::Call { module: Some(module), function, .. } if module == "erlang" && function == "put")
        });
        let Some(Expr::Match(pattern, _)) = last else {
            return false;
        };
        let Expr::Tuple(items) = pattern.as_mut() else {
            return false;
        };
        match items.first_mut() {
            Some(first) if *first == Expr::var(name) => {
                *first = Expr::var("_");
                true
            }
            _ => false,
        }
    }

    /// Lowers `expression` as a condition: an Erlang expression that yields `true` or
    /// `false`.
    pub fn test(&mut self, expression: &'a Expression<'a>) -> Expr {
        match strip(expression) {
            Expression::LogicalExpression(logical)
                if logical.operator != LogicalOperator::Coalesce && !self.emits(&logical.right) =>
            {
                let left = self.test(&logical.left);
                let right = self.nested(|lowerer| lowerer.test(&logical.right));
                let operator = if logical.operator == LogicalOperator::And {
                    "andalso"
                } else {
                    "orelse"
                };
                Expr::op(operator, left, right)
            }
            Expression::UnaryExpression(unary) if unary.operator == UnaryOperator::LogicalNot => {
                Expr::not(self.test(&unary.argument))
            }
            _ => {
                let value = self.expr(expression);
                if is_boolean(&value) {
                    value
                } else {
                    Expr::rt("truthy", vec![value])
                }
            }
        }
    }

    /// Lowers an expression that runs only on some paths: the branch of a conditional, the
    /// right side of a logical operator, a default value. It must not rebind a variable.
    pub fn sub_expr(&mut self, expression: &'a Expression<'a>) -> Expr {
        if self.emits(expression) {
            return self.unsupported(
                expression.span(),
                "an assignment or a mutating call here is not supported; move it into an if statement",
            );
        }
        self.nested(|lowerer| lowerer.expr(expression))
    }

    /// Runs `build` in its own sequence and returns its value, as a `begin ... end` block
    /// when it needed bindings.
    pub fn nested(&mut self, build: impl FnOnce(&mut Self) -> Expr) -> Expr {
        let outer = std::mem::take(&mut self.seq);
        let value = build(self);
        let mut body = std::mem::replace(&mut self.seq, outer);
        if body.is_empty() {
            return value;
        }
        body.push(value);
        Expr::Block(body)
    }

    /// Lowers operands in order. When a later operand rebinds a variable, each earlier
    /// operand is bound to a temporary first.
    pub fn ordered(&mut self, operands: &[&'a Expression<'a>]) -> Vec<Expr> {
        let emitting: Vec<bool> = operands.iter().map(|operand| self.emits(operand)).collect();
        let mut values = Vec::with_capacity(operands.len());
        for (index, operand) in operands.iter().enumerate() {
            let value = self.expr(operand);
            if emitting[index + 1..].contains(&true) {
                values.push(self.trivial(value));
            } else {
                values.push(value);
            }
        }
        values
    }

    /// A case whose arms rebind variables: `{Value, {Vars}} = case ... end`.
    fn rebinding_case(&mut self, span: Span, test: Expr, arms: [&'a Expression<'a>; 2]) -> Expr {
        use oxc::ast_visit::Visit;
        let vars = self.rebound(span, |found| {
            for arm in arms {
                found.visit_expression(arm);
            }
        });
        let [yes, no] = arms.map(|arm| {
            self.branch(|lowerer| {
                let value = lowerer.expr(arm);
                let tuple = lowerer.scope.tuple(&vars);
                lowerer.seq.push(Expr::Tuple(vec![value, tuple]));
            })
        });
        let result = self.scope.temp();
        let tuple = self.rebind_tuple(&vars);
        self.push_match(
            Expr::Tuple(vec![Expr::var(&result), tuple]),
            boolean_case(test, yes, no),
        );
        Expr::Var(result)
    }

    fn string(&mut self, literal: &StringLiteral<'_>) -> Expr {
        if literal.lone_surrogates {
            return self.unsupported(
                literal.span,
                "strings with lone surrogates are not supported",
            );
        }
        Expr::binary(literal.value.as_str())
    }

    fn template(&mut self, template: &'a TemplateLiteral<'a>) -> Expr {
        let expressions: Vec<&'a Expression<'a>> = template.expressions.iter().collect();
        let mut values = self.ordered(&expressions).into_iter();
        let mut parts = Vec::new();
        for quasi in &template.quasis {
            if quasi.lone_surrogates {
                return self
                    .unsupported(quasi.span, "strings with lone surrogates are not supported");
            }
            match &quasi.value.cooked {
                Some(cooked) if !cooked.is_empty() => parts.push(Expr::binary(cooked.as_str())),
                Some(_) => {}
                None => {
                    return self.unsupported(quasi.span, "invalid escape in a template literal");
                }
            }
            if !quasi.tail
                && let Some(value) = values.next()
            {
                parts.push(value);
            }
        }
        match parts.as_slice() {
            [] => Expr::binary(""),
            [Expr::Binary(text)] => Expr::binary(text.clone()),
            _ => Expr::rt("concat", vec![Expr::List(parts)]),
        }
    }

    pub fn symbol_of(&self, ident: &IdentifierReference<'_>) -> Option<SymbolId> {
        let reference = self
            .semantic
            .scoping()
            .get_reference(ident.reference_id.get()?);
        reference.symbol_id()
    }

    fn identifier(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        let Some(symbol) = self.symbol_of(ident) else {
            return self.global(&ident.name, ident.span);
        };
        if let Some(name) = self.scope.current(Target::Symbol(symbol)) {
            return Expr::var(name);
        }
        match self.module.bindings.get(&symbol).cloned() {
            Some(binding) => self.binding_value(&binding, ident.span),
            None if self.declared_unsupported(symbol) => Expr::undefined(),
            None => self.unbound(symbol, ident),
        }
    }

    /// Reports a variable that has no value where it is read: a closure created before its
    /// declaration or inside its own initializer (`BOUY205`), or a read before the
    /// declaration (`BOUY206`).
    fn unbound(&mut self, symbol: SymbolId, ident: &IdentifierReference<'_>) -> Expr {
        let scoping = self.semantic.scoping();
        let name = &ident.name;
        let declared = scoping.symbol_span(symbol);
        let declaration = self
            .semantic
            .nodes()
            .get_node(scoping.symbol_declaration(symbol))
            .kind()
            .span();
        let closure = self
            .closures
            .iter()
            .rev()
            .find(|closure| !(closure.start <= declared.start && declared.end <= closure.end))
            .copied();
        let message = match closure {
            Some(closure) if declared.start >= closure.end => format!(
                "this closure reads `{name}`, which is declared after the closure is created; an Erlang fun copies the values it captures, so declare `{name}` before the closure"
            ),
            Some(closure)
                if declaration.start <= closure.start && closure.end <= declaration.end =>
            {
                format!(
                    "this closure reads `{name}`, which its own declaration assigns after the closure is created; an Erlang fun copies the values it captures, so create the closure from values that exist first"
                )
            }
            _ => {
                return self.unsupported(
                    ident.span,
                    format!("`{name}` is used before its declaration; declare it first"),
                );
            }
        };
        self.report(ident.span, Code::Capture, message);
        Expr::undefined()
    }

    /// Whether `symbol` is an enum or a namespace, whose declaration is already reported.
    fn declared_unsupported(&self, symbol: SymbolId) -> bool {
        use oxc::semantic::SymbolFlags;
        self.semantic
            .scoping()
            .symbol_flags(symbol)
            .intersects(SymbolFlags::Enum | SymbolFlags::NamespaceModule | SymbolFlags::ValueModule)
    }

    fn binding_value(&mut self, binding: &Binding, span: Span) -> Expr {
        match binding {
            Binding::Function(name) => Expr::FunRef {
                module: None,
                function: name.clone(),
                arity: 1,
            },
            Binding::Const {
                literal: Some(literal),
                ..
            } => literal.clone(),
            Binding::Const { key, literal: None } => {
                let module = self.module.name.clone();
                persisted(&module, key)
            }
            Binding::Class { name, .. } => class_value(&self.module.name, name),
            Binding::ImportedFunction { module, name } => Expr::FunRef {
                module: Some(module.clone()),
                function: name.clone(),
                arity: 1,
            },
            Binding::ImportedConst { module, name } => persisted(module, name),
            Binding::ImportedClass { module, name, .. } => class_value(module, name),
            Binding::ImportedModule(_) => self.unsupported(
                span,
                "a module namespace can only be used to read or call its exports",
            ),
            Binding::Library(binding) => self.library_value(*binding, span),
        }
    }

    fn global(&mut self, name: &str, span: Span) -> Expr {
        match library::global(name) {
            Some(binding) => self.library_value(binding, span),
            None => self.unknown_global(name, span),
        }
    }

    fn unknown_global(&mut self, name: &str, span: Span) -> Expr {
        let message = match name {
            "arguments" => "`arguments` is not supported; use a rest parameter".to_owned(),
            "eval" => "`eval` is not supported".to_owned(),
            _ => format!("`{name}` is not available in Bouy"),
        };
        self.unsupported(span, message)
    }

    fn library_value(&mut self, binding: library::Binding, span: Span) -> Expr {
        match binding {
            library::Binding::Namespace(DATA) => self.data_use(span),
            library::Binding::Namespace(module) => {
                Expr::Tuple(vec![Expr::atom("$namespace"), Expr::atom(module)])
            }
            library::Binding::Function { module, function } => Expr::FunRef {
                module: Some(module.to_owned()),
                function: function.to_owned(),
                arity: 1,
            },
            library::Binding::ErrorClass(name) => class_value("bouy_error", name),
            library::Binding::Boolean => self.unary_fun(|value| Expr::rt("truthy", vec![value])),
            library::Binding::StructuredClone => {
                self.unary_fun(|value| Expr::rt("structured_clone", vec![value]))
            }
            library::Binding::Constant(name) => Expr::atom(name),
            library::Binding::Process => self.host_api(span, "process"),
            library::Binding::HostApi => {
                let name = self.reporter.text(span).to_owned();
                self.host_api(span, &name)
            }
        }
    }

    /// Reports a use of `Data` from "effect" other than an error class base.
    fn data_use(&mut self, span: Span) -> Expr {
        self.report(
            span,
            Code::BadImport,
            "`Data` from \"effect\" is implemented only as an error class base, `extends Data.TaggedError(\"Tag\")` or `extends Data.Error`; the rest of it is planned",
        );
        Expr::undefined()
    }

    /// Reports a host API (`BOUY207`), such as `process.exit` or `setTimeout`, with the
    /// alternative for its kind.
    pub fn host_api(&mut self, span: Span, name: &str) -> Expr {
        let alternative = match name.split('.').next().unwrap_or(name) {
            "process" => {
                "read process.env.NAME or process.argv, and throw an error to exit with status 1"
            }
            "globalThis" => "import the value or pass it as an argument",
            _ => "use sleep or schedule from \"bouy\" for timers",
        };
        self.report(
            span,
            Code::HostApi,
            format!("`{name}` is not available in Bouy; {alternative}"),
        );
        Expr::undefined()
    }

    /// `fun(Args) -> F(arg(1, Args)) end`, for a one-argument global used as a value.
    fn unary_fun(&mut self, apply: impl FnOnce(Expr) -> Expr) -> Expr {
        let args = self.scope.fresh("Args");
        let first = Expr::rt("arg", vec![Expr::Integer(1), Expr::var(&args)]);
        Expr::Fun {
            name: None,
            clauses: vec![Clause::new(Expr::Var(args), vec![apply(first)])],
        }
    }

    fn this(&mut self, span: Span) -> Expr {
        match self.scope.current(Target::This) {
            Some(name) => Expr::var(name),
            None => self.unsupported(
                span,
                "`this` is supported only inside class methods and the arrow functions in them",
            ),
        }
    }

    fn array(&mut self, array: &'a ArrayExpression<'a>) -> Expr {
        let mut operands = Vec::new();
        let mut spread = Vec::new();
        for element in &array.elements {
            match element {
                ArrayExpressionElement::SpreadElement(element) => {
                    operands.push(&element.argument);
                    spread.push(true);
                }
                ArrayExpressionElement::Elision(_) => {}
                other => {
                    if let Some(expression) = other.as_expression() {
                        operands.push(expression);
                        spread.push(false);
                    }
                }
            }
        }
        let values = self.ordered(&operands);
        if !spread.contains(&true) {
            let mut values = values.into_iter();
            return Expr::List(
                array
                    .elements
                    .iter()
                    .map(|element| match element {
                        ArrayExpressionElement::Elision(_) => Expr::undefined(),
                        _ => values.next().unwrap_or_else(Expr::undefined),
                    })
                    .collect(),
            );
        }
        let entries = values
            .into_iter()
            .zip(spread)
            .map(|(value, spread)| entry(value, spread, "$item"))
            .collect();
        Expr::rt("array", vec![Expr::List(entries)])
    }

    fn object(&mut self, object: &'a ObjectExpression<'a>) -> Expr {
        let mut operands: Vec<&'a Expression<'a>> = Vec::new();
        for property in &object.properties {
            match property {
                ObjectPropertyKind::ObjectProperty(property) => {
                    if property.kind != PropertyKind::Init {
                        self.unsupported(property.span, "getters and setters are not supported");
                    }
                    if !property.computed
                        && !property.shorthand
                        && !property.method
                        && property
                            .key
                            .static_name()
                            .is_some_and(|name| name == "__proto__")
                    {
                        self.unsupported(
                            property.span,
                            "`__proto__` in an object literal sets a prototype, and Bouy objects have no prototype chain; copy the properties with a spread instead",
                        );
                    }
                    if property.computed
                        && static_key(&property.key).is_none()
                        && let Some(key) = property.key.as_expression()
                    {
                        operands.push(key);
                    }
                    operands.push(&property.value);
                }
                ObjectPropertyKind::SpreadProperty(spread) => operands.push(&spread.argument),
            }
        }
        let mut values = self.ordered(&operands).into_iter();
        let mut entries: Vec<(Option<Expr>, Expr)> = Vec::new();
        for property in &object.properties {
            match property {
                ObjectPropertyKind::ObjectProperty(property) => {
                    let key = if let Some(name) = static_key(&property.key) {
                        Expr::binary(name)
                    } else if let PropertyKey::PrivateIdentifier(private) = &property.key {
                        Expr::binary(format!("#{}", private.name))
                    } else {
                        let key = values.next().unwrap_or_else(Expr::undefined);
                        Expr::rt("to_string", vec![key])
                    };
                    let value = values.next().unwrap_or_else(Expr::undefined);
                    entries.push((Some(key), value));
                }
                ObjectPropertyKind::SpreadProperty(_) => {
                    entries.push((None, values.next().unwrap_or_else(Expr::undefined)));
                }
            }
        }
        if entries.iter().all(|(key, _)| key.is_some()) {
            return Expr::Map(
                entries
                    .into_iter()
                    .filter_map(|(key, value)| key.map(|key| (key, value)))
                    .collect(),
            );
        }
        let entries = entries
            .into_iter()
            .map(|(key, value)| match key {
                Some(key) => Expr::Tuple(vec![key, value]),
                None => Expr::tagged("$spread", value),
            })
            .collect();
        Expr::rt("object", vec![Expr::List(entries)])
    }

    fn binary(&mut self, binary: &'a BinaryExpression<'a>) -> Expr {
        let mut operands = self.ordered(&[&binary.left, &binary.right]).into_iter();
        let left = operands.next().unwrap_or_else(Expr::undefined);
        let right = operands.next().unwrap_or_else(Expr::undefined);
        let function = match binary.operator {
            BinaryOperator::Equality => "loose_eq",
            BinaryOperator::Inequality => {
                return Expr::not(Expr::rt("loose_eq", vec![left, right]));
            }
            BinaryOperator::StrictEquality => "strict_eq",
            BinaryOperator::StrictInequality => {
                return Expr::not(Expr::rt("strict_eq", vec![left, right]));
            }
            BinaryOperator::LessThan => "lt",
            BinaryOperator::LessEqualThan => "le",
            BinaryOperator::GreaterThan => "gt",
            BinaryOperator::GreaterEqualThan => "ge",
            BinaryOperator::In => {
                // `has/2` takes the object first, so the key runs first through a temporary.
                let left = if right.is_trivial() {
                    left
                } else {
                    self.trivial(left)
                };
                return Expr::rt("has", vec![right, left]);
            }
            BinaryOperator::Instanceof => "instance_of",
            arithmetic => arithmetic_function(arithmetic).unwrap_or("add"),
        };
        Expr::rt(function, vec![left, right])
    }

    fn logical(&mut self, logical: &'a LogicalExpression<'a>) -> Expr {
        let left = self.expr(&logical.left);
        if self.emits(&logical.right) {
            let left = self.trivial(left);
            return self.short_circuit(logical.operator, &left, &logical.right, logical.span);
        }
        let right = self.sub_expr(&logical.right);
        if logical.operator == LogicalOperator::Coalesce {
            let absent = self.scope.temp();
            let present = self.scope.temp();
            let guards = ["null", "undefined"]
                .map(|name| Expr::op("=:=", Expr::var(&absent), Expr::atom(name)))
                .to_vec();
            return Expr::case(
                left,
                vec![
                    Clause::guarded(Expr::var(&absent), guards, vec![right]),
                    Clause::new(Expr::var(&present), vec![Expr::Var(present)]),
                ],
            );
        }
        let and = logical.operator == LogicalOperator::And;
        self.with_temp(left, |left| {
            let truthy = Expr::rt("truthy", vec![left.clone()]);
            if and {
                boolean_case(truthy, vec![right], vec![left])
            } else {
                boolean_case(truthy, vec![left], vec![right])
            }
        })
    }

    /// `a || (b = c)` and `a ??= (b++, c)`: the left value when it decides the result, else
    /// the right side, which rebinds variables.
    pub fn short_circuit(
        &mut self,
        operator: LogicalOperator,
        left: &Expr,
        right: &'a Expression<'a>,
        span: Span,
    ) -> Expr {
        use oxc::ast_visit::Visit;
        let vars = self.rebound(span, |found| found.visit_expression(right));
        let keep = vec![Expr::Tuple(vec![left.clone(), self.scope.tuple(&vars)])];
        let evaluate = self.branch(|lowerer| {
            let value = lowerer.expr(right);
            let tuple = lowerer.scope.tuple(&vars);
            lowerer.seq.push(Expr::Tuple(vec![value, tuple]));
        });
        let truthy = || Expr::rt("truthy", vec![left.clone()]);
        let choice = match operator {
            LogicalOperator::Or => boolean_case(truthy(), keep, evaluate),
            LogicalOperator::And => boolean_case(truthy(), evaluate, keep),
            LogicalOperator::Coalesce => {
                let absent = self.scope.temp();
                let guards = ["null", "undefined"]
                    .map(|name| Expr::op("=:=", Expr::var(&absent), Expr::atom(name)))
                    .to_vec();
                Expr::case(
                    left.clone(),
                    vec![
                        Clause::guarded(Expr::var(&absent), guards, evaluate),
                        Clause::new(Expr::var("_"), keep),
                    ],
                )
            }
        };
        let result = self.scope.temp();
        let tuple = self.rebind_tuple(&vars);
        self.push_match(Expr::Tuple(vec![Expr::var(&result), tuple]), choice);
        Expr::Var(result)
    }

    /// Binds `value` to a temporary inside a `begin ... end` block when it is not trivial,
    /// and builds an expression that uses it more than once.
    pub fn with_temp(&mut self, value: Expr, build: impl FnOnce(Expr) -> Expr) -> Expr {
        if value.is_trivial() {
            return build(value);
        }
        let name = self.scope.temp();
        let body = build(Expr::var(&name));
        Expr::Block(vec![Expr::matches(Expr::Var(name), value), body])
    }

    fn unary(&mut self, unary: &'a UnaryExpression<'a>) -> Expr {
        match unary.operator {
            UnaryOperator::UnaryNegation => {
                if let Expression::NumericLiteral(literal) = strip(&unary.argument) {
                    return number(-literal.value);
                }
                let value = self.expr(&unary.argument);
                Expr::rt("negate", vec![value])
            }
            UnaryOperator::UnaryPlus => {
                let value = self.expr(&unary.argument);
                Expr::rt("to_number", vec![value])
            }
            UnaryOperator::LogicalNot => Expr::not(self.test(&unary.argument)),
            UnaryOperator::BitwiseNot => {
                let value = self.expr(&unary.argument);
                Expr::rt("bit_not", vec![value])
            }
            UnaryOperator::Typeof => {
                if let Expression::Identifier(ident) = strip(&unary.argument)
                    && self.symbol_of(ident).is_none()
                    && library::global(&ident.name).is_none()
                {
                    return Expr::binary("undefined");
                }
                let value = self.expr(&unary.argument);
                Expr::rt("type_of", vec![value])
            }
            UnaryOperator::Void => {
                let value = self.expr(&unary.argument);
                if value.is_trivial() {
                    Expr::undefined()
                } else {
                    Expr::Block(vec![value, Expr::undefined()])
                }
            }
            UnaryOperator::Delete => self.delete(&unary.argument, unary.span),
        }
    }

    /// The argument list of a call: a list, or `bouy_rt:array/1` when it spreads.
    pub fn arguments(&mut self, arguments: &'a [Argument<'a>]) -> Expr {
        let operands: Vec<&'a Expression<'a>> = arguments.iter().map(argument_expression).collect();
        let values = self.ordered(&operands);
        let spread: Vec<bool> = arguments
            .iter()
            .map(|argument| matches!(argument, Argument::SpreadElement(_)))
            .collect();
        if !spread.contains(&true) {
            return Expr::List(values);
        }
        Expr::rt(
            "array",
            vec![Expr::List(
                values
                    .into_iter()
                    .zip(spread)
                    .map(|(value, spread)| entry(value, spread, "$item"))
                    .collect(),
            )],
        )
    }

    fn call(&mut self, call: &'a CallExpression<'a>) -> Expr {
        match strip(&call.callee) {
            Expression::Identifier(ident) => self.call_identifier(ident, &call.arguments, call.span),
            Expression::StaticMemberExpression(member) => self.call_method(
                &member.object,
                Key::Static(&member.property.name),
                &call.arguments,
                call,
            ),
            Expression::PrivateFieldExpression(member) => self.call_method(
                &member.object,
                Key::Private(&member.field.name),
                &call.arguments,
                call,
            ),
            Expression::ComputedMemberExpression(member) => self.call_method(
                &member.object,
                Key::Computed(&member.expression),
                &call.arguments,
                call,
            ),
            Expression::Super(base) => self.unsupported(
                base.span,
                "`super(...)` is supported only as the first statement of an error class constructor",
            ),
            callee => {
                let fun = self.expr(callee);
                let fun = if self.arguments_emit(&call.arguments) {
                    self.trivial(fun)
                } else {
                    fun
                };
                let arguments = self.arguments(&call.arguments);
                Expr::rt("call", vec![fun, arguments])
            }
        }
    }

    fn arguments_emit(&self, arguments: &[Argument<'_>]) -> bool {
        arguments
            .iter()
            .any(|argument| self.emits(argument_expression(argument)))
    }

    fn call_identifier(
        &mut self,
        ident: &'a IdentifierReference<'a>,
        arguments: &'a [Argument<'a>],
        span: Span,
    ) -> Expr {
        let symbol = self.symbol_of(ident);
        if let Some(name) = symbol.and_then(|symbol| self.scope.current(Target::Symbol(symbol))) {
            let fun = Expr::var(name);
            let arguments = self.arguments(arguments);
            return Expr::rt("call", vec![fun, arguments]);
        }
        let binding = symbol.map_or_else(
            || library::global(&ident.name).map(Binding::Library),
            |symbol| self.module.bindings.get(&symbol).cloned(),
        );
        match binding {
            Some(Binding::Function(name)) => {
                let arguments = self.arguments(arguments);
                Expr::local_call(&name, vec![arguments])
            }
            Some(Binding::ImportedFunction { module, name }) => {
                let arguments = self.arguments(arguments);
                Expr::call(&module, &name, vec![arguments])
            }
            Some(Binding::Library(library::Binding::Function { module, function })) => {
                let arguments = self.arguments(arguments);
                Expr::call(module, function, vec![arguments])
            }
            Some(Binding::Library(library::Binding::Boolean)) => {
                let value = self.first_argument(arguments);
                Expr::rt("truthy", vec![value])
            }
            Some(Binding::Library(library::Binding::StructuredClone)) => {
                let value = self.first_argument(arguments);
                Expr::rt("structured_clone", vec![value])
            }
            Some(Binding::Library(library::Binding::ErrorClass(name))) => {
                let arguments = self.arguments(arguments);
                Expr::call("bouy_error", &format!("{name}#new"), vec![arguments])
            }
            Some(Binding::Class { .. } | Binding::ImportedClass { .. }) => self.unsupported(
                span,
                "a class cannot be called; use `spawn` for an actor class or `new` for an error class",
            ),
            Some(Binding::Library(library::Binding::Namespace(module))) => {
                let arguments = self.arguments(arguments);
                Expr::call(module, "$call", vec![arguments])
            }
            Some(Binding::ImportedModule(_)) => self.unsupported(span, "a module namespace cannot be called"),
            Some(Binding::Library(library::Binding::Process | library::Binding::HostApi)) => {
                self.host_api(ident.span, &ident.name)
            }
            Some(other @ (Binding::Const { .. } | Binding::ImportedConst { .. })) => {
                let fun = self.binding_value(&other, span);
                let arguments = self.arguments(arguments);
                Expr::rt("call", vec![fun, arguments])
            }
            Some(Binding::Library(library::Binding::Constant(_))) => {
                let arguments = self.arguments(arguments);
                Expr::rt("call", vec![Expr::undefined(), arguments])
            }
            None => match symbol {
                Some(symbol) => self.unbound(symbol, ident),
                None => self.unknown_global(&ident.name, ident.span),
            },
        }
    }

    /// The first argument of a conversion such as `String(x)`.
    fn first_argument(&mut self, arguments: &'a [Argument<'a>]) -> Expr {
        if let Some(Argument::SpreadElement(spread)) = arguments.first() {
            return self.unsupported(spread.span, "a spread argument is not supported here");
        }
        let operands: Vec<&'a Expression<'a>> = arguments.iter().map(argument_expression).collect();
        self.ordered(&operands)
            .into_iter()
            .next()
            .unwrap_or_else(Expr::undefined)
    }

    fn namespace(&self, object: &Expression<'_>) -> Option<Namespace> {
        let Expression::Identifier(ident) = strip(object) else {
            return None;
        };
        let binding = match self.symbol_of(ident) {
            Some(symbol) => {
                if self.scope.current(Target::Symbol(symbol)).is_some() {
                    return None;
                }
                match self.module.bindings.get(&symbol)? {
                    Binding::Library(binding) => *binding,
                    Binding::ImportedModule(module) => {
                        return Some(Namespace::Bouy(module.clone()));
                    }
                    _ => return None,
                }
            }
            None => library::global(&ident.name)?,
        };
        match binding {
            library::Binding::Namespace(module) => Some(Namespace::Module(module)),
            library::Binding::Process => Some(Namespace::Process),
            _ => None,
        }
    }

    fn call_method(
        &mut self,
        object: &'a Expression<'a>,
        key: Key<'a>,
        arguments: &'a [Argument<'a>],
        call: &'a CallExpression<'a>,
    ) -> Expr {
        // A string literal key names the method as a static key does: `xs["push"](1)`.
        let key = match key {
            Key::Computed(expression) => match strip(expression) {
                Expression::StringLiteral(literal) => Key::Static(literal.value.as_str()),
                _ => key,
            },
            other => other,
        };
        let name = match key {
            Key::Static(name) => Some(name.to_owned()),
            Key::Private(name) => Some(format!("#{name}")),
            Key::Computed(_) => None,
        };
        if let (Some(namespace), Some(name)) = (self.namespace(object), &name) {
            return self.call_namespace(namespace, name, arguments, call);
        }
        // `this.m(a).n(b)` where `m` returns `this`: `n` runs on `this` after `m`.
        if let Expression::CallExpression(inner) = strip(object)
            && let Expression::StaticMemberExpression(member) = strip(&inner.callee)
            && matches!(strip(&member.object), Expression::ThisExpression(_))
            && self
                .class
                .as_ref()
                .is_some_and(|class| class.fluent.contains(member.property.name.as_str()))
        {
            self.effect(object);
            return self.call_method(&member.object, key, arguments, call);
        }
        if let Some(name) = &name {
            if matches!(strip(object), Expression::ThisExpression(_))
                && let Some(class) = &self.class
                && class.methods.contains(name)
            {
                let function = format!("{}#{name}", class.name);
                if class.mutating.contains(name) {
                    return self.call_own_method(&function, arguments, call.span);
                }
                return self.call_reading_method(&function, arguments, call.span);
            }
            // Every call returns its result, so a promise chain has nothing to chain on.
            if matches!(name.as_str(), "then" | "catch" | "finally") && self.is_promise(object) {
                return self.unsupported(
                    call.span,
                    format!("`.{name}()` chains are not supported; use `await` and try/catch"),
                );
            }
            if MUTATORS.contains(&name.as_str()) {
                if self.roots.receiver(object).is_some() {
                    return self.mutate(object, name, arguments);
                }
                if !matches!(strip(object), Expression::Identifier(_)) {
                    self.unwritable_root(object);
                }
            }
        }
        if let Key::Computed(method) = key
            && matches!(strip(object), Expression::ThisExpression(_))
            && self.class.is_some()
        {
            return self.dispatch_own(method, arguments, call.span);
        }
        let arguments_emit = self.arguments_emit(arguments);
        let key_emits = matches!(key, Key::Computed(key) if self.emits(key));
        let receiver = self.expr(object);
        let receiver = if arguments_emit || key_emits {
            self.trivial(receiver)
        } else {
            receiver
        };
        let method = match key {
            Key::Computed(key) => {
                let method = self.expr(key);
                if arguments_emit {
                    self.trivial(method)
                } else {
                    method
                }
            }
            _ => Expr::binary(name.unwrap_or_default()),
        };
        let arguments = self.arguments(arguments);
        Expr::rt("call_method", vec![receiver, method, arguments])
    }

    /// Whether `object` is a promise in TypeScript: a call, a `new` expression, or a
    /// variable declared with the type `Promise<T>`.
    fn is_promise(&self, object: &Expression<'_>) -> bool {
        match strip(object) {
            Expression::CallExpression(_) | Expression::NewExpression(_) => true,
            Expression::Identifier(ident) => self
                .symbol_of(ident)
                .is_some_and(|symbol| self.module.promises.contains(&symbol)),
            _ => false,
        }
    }

    /// `this.m(args)` for a method that leaves `this` as it was: the result of the direct
    /// call, `erlang:element(1, 'C#m'(This, Args))`.
    fn call_reading_method(
        &mut self,
        function: &str,
        arguments: &'a [Argument<'a>],
        span: Span,
    ) -> Expr {
        let arguments = self.arguments(arguments);
        let Some(this) = self.scope.current(Target::This).map(str::to_owned) else {
            return self.this(span);
        };
        Expr::call(
            "erlang",
            "element",
            vec![
                Expr::Integer(1),
                Expr::local_call(function, vec![Expr::Var(this), arguments]),
            ],
        )
    }

    /// `this[name](args)` inside a class: the call goes through `'C#dispatch'/3`, which
    /// returns `{Result, This1}`, so it rebinds `This` like a call of a method that changes
    /// `this`.
    fn dispatch_own(
        &mut self,
        method: &'a Expression<'a>,
        arguments: &'a [Argument<'a>],
        span: Span,
    ) -> Expr {
        let name = self.expr(method);
        let name = self.trivial(Expr::rt("to_string", vec![name]));
        let arguments = self.arguments(arguments);
        let (Some(this), Some(class)) = (
            self.scope.current(Target::This).map(str::to_owned),
            self.class.as_ref().map(|class| class.name.clone()),
        ) else {
            return self.this(span);
        };
        let result = self.scope.temp();
        let next = self.scope.bind(Target::This, "This");
        self.push_match(
            Expr::Tuple(vec![Expr::var(&result), Expr::Var(next)]),
            Expr::local_call(
                &format!("{class}#dispatch"),
                vec![name, Expr::Var(this), arguments],
            ),
        );
        Expr::Var(result)
    }

    /// `this.m(args)` inside a class: a direct call that returns `{Result, This1}`.
    fn call_own_method(
        &mut self,
        function: &str,
        arguments: &'a [Argument<'a>],
        span: Span,
    ) -> Expr {
        let arguments = self.arguments(arguments);
        let Some(this) = self.scope.current(Target::This).map(str::to_owned) else {
            return self.this(span);
        };
        let result = self.scope.temp();
        let next = self.scope.bind(Target::This, "This");
        self.push_match(
            Expr::Tuple(vec![Expr::var(&result), Expr::Var(next)]),
            Expr::local_call(function, vec![Expr::Var(this), arguments]),
        );
        Expr::Var(result)
    }

    fn call_namespace(
        &mut self,
        namespace: Namespace,
        name: &str,
        arguments: &'a [Argument<'a>],
        call: &'a CallExpression<'a>,
    ) -> Expr {
        match namespace {
            Namespace::Module("bouy_task")
                if matches!(name, "all" | "allSettled" | "race" | "any") =>
            {
                self.promise_form(name, arguments, call.span)
            }
            Namespace::Module("bouy_object")
                if name == "assign"
                    && let Some(target) = self.roots.assigned_object(call)
                    && self.roots.place(target).is_some()
                    && let Some(merged) = self.assign_object(target, &arguments[1..]) =>
            {
                merged
            }
            Namespace::Module("bouy_object")
                if name == "assign"
                    && let Some(target) = self.roots.assigned_object(call) =>
            {
                self.unwritable_root(target);
                let arguments = self.arguments(arguments);
                Expr::call("bouy_object", "assign", vec![arguments])
            }
            Namespace::Module(DATA) => self.data_use(call.span),
            Namespace::Module(module) => {
                if let Some(global) = library::missing_global_function(module, name) {
                    return self.unsupported(
                        call.span,
                        format!("`{global}.{name}` is not available in Bouy"),
                    );
                }
                let arguments = self.arguments(arguments);
                Expr::call(module, name, vec![arguments])
            }
            Namespace::Bouy(module) => {
                let export = self.export_of(&module, name);
                match export.map(|export| (export.module, export.local, export.kind)) {
                    Some((module, function, ExportKind::Function)) => {
                        let arguments = self.arguments(arguments);
                        Expr::call(&module, &function, vec![arguments])
                    }
                    Some((module, key, ExportKind::Const)) => {
                        let arguments = self.arguments(arguments);
                        Expr::rt("call", vec![persisted(&module, &key), arguments])
                    }
                    Some((_, _, ExportKind::Class(_))) => self.unsupported(
                        call.span,
                        "a class cannot be called; use `spawn` for an actor class or `new` for an error class",
                    ),
                    Some((_, _, ExportKind::Namespace)) => {
                        self.unsupported(call.span, "a module namespace cannot be called")
                    }
                    None => {
                        self.report(call.span, Code::MissingExport, format!("the imported module has no export `{name}`"));
                        Expr::undefined()
                    }
                }
            }
            Namespace::Process => self.host_api(call.span, &format!("process.{name}")),
        }
    }

    fn export_of(&self, module: &str, name: &str) -> Option<crate::graph::Export> {
        self.module
            .exports
            .get(module)
            .and_then(|exports| exports.get(name))
            .cloned()
    }

    /// `Promise.all`, `Promise.allSettled`, and `Promise.race` (section 7).
    fn promise_form(&mut self, name: &str, arguments: &'a [Argument<'a>], span: Span) -> Expr {
        let function = match name {
            "allSettled" => "all_settled",
            other => other,
        };
        let [argument] = arguments else {
            return self.unsupported(span, format!("`Promise.{name}` takes one argument"));
        };
        let argument = argument_expression(argument);
        match strip(argument) {
            Expression::ArrayExpression(array)
                if array
                    .elements
                    .iter()
                    .all(|element| element.as_expression().is_some()) =>
            {
                let thunks = array
                    .elements
                    .iter()
                    .filter_map(ArrayExpressionElement::as_expression)
                    .map(|element| self.thunk(element))
                    .collect();
                Expr::call("bouy_task", function, vec![Expr::List(thunks)])
            }
            Expression::CallExpression(mapped) if mapped_items(mapped).is_some() => {
                let Some((items, fun)) = mapped_items(mapped) else {
                    return Expr::undefined();
                };
                let params = literal_params(fun);
                let mut values = self.ordered(&[items, fun]).into_iter();
                let items = values.next().unwrap_or_else(Expr::undefined);
                let fun = values.next().unwrap_or_else(Expr::undefined);
                let function = match name {
                    "allSettled" => "map_settled",
                    "race" => "map_race",
                    "any" => "map_any",
                    _ => "map",
                };
                let mut arguments = vec![items, fun];
                // A function literal with at most two parameters cannot read the array, so no
                // worker gets a copy of it (section 7).
                if let Some(params) = params.filter(|params| *params < 3) {
                    arguments.push(Expr::Integer(params));
                }
                Expr::call("bouy_task", function, arguments)
            }
            _ if name == "all" => {
                let value = self.expr(argument);
                Expr::rt("to_list", vec![value])
            }
            _ => self.unsupported(
                span,
                format!(
                    "`Promise.{name}` needs an array literal of the operations to run, or `items.map(f)`"
                ),
            ),
        }
    }

    /// `fun() -> E end`: one operation of `Promise.all` that runs in its own process.
    fn thunk(&mut self, expression: &'a Expression<'a>) -> Expr {
        if self.emits(expression) {
            self.report(
                expression.span(),
                Code::Capture,
                "an operation of Promise.all runs in its own process and cannot assign variables; assign the results after it",
            );
        }
        let versions = self.scope.versions();
        let outer = std::mem::take(&mut self.seq);
        let value = self.expr(expression);
        let mut body = std::mem::replace(&mut self.seq, outer);
        self.scope.restore(versions);
        body.push(value);
        Expr::Fun {
            name: None,
            clauses: vec![Clause {
                patterns: Vec::new(),
                guards: Vec::new(),
                body,
            }],
        }
    }

    fn member(&mut self, object: &'a Expression<'a>, key: Key<'a>, span: Span) -> Expr {
        if let Key::Static(name) = key {
            if let Some(value) = self.process_member(object, name, span) {
                return value;
            }
            // `This` of an actor is a map of its fields, so the class comes from the lowering.
            if name == "constructor"
                && matches!(strip(object), Expression::ThisExpression(_))
                && let Some(class) = &self.class
            {
                return class_value(&self.module.name, &class.name);
            }
        }
        if let Some(name) = own_method(key)
            && matches!(strip(object), Expression::ThisExpression(_))
            && self
                .class
                .as_ref()
                .is_some_and(|class| class.methods.contains(&name))
        {
            return self.method_value(&name, span);
        }
        if let Key::Static(name) = key {
            match self.namespace(object) {
                Some(Namespace::Module(DATA)) => return self.data_use(span),
                Some(Namespace::Module(module)) => {
                    return Expr::call(module, "$member", vec![Expr::binary(name)]);
                }
                Some(Namespace::Bouy(module)) => {
                    return match self
                        .export_of(&module, name)
                        .map(|export| (export.module, export.local, export.kind))
                    {
                        Some((module, function, ExportKind::Function)) => Expr::FunRef {
                            module: Some(module),
                            function,
                            arity: 1,
                        },
                        Some((module, key, ExportKind::Const)) => persisted(&module, &key),
                        Some((module, local, ExportKind::Class(_))) => class_value(&module, &local),
                        Some((_, _, ExportKind::Namespace)) => self.unsupported(
                            span,
                            "a module namespace can only be used to read or call its exports",
                        ),
                        None => {
                            self.report(
                                span,
                                Code::BadImport,
                                format!("the imported module has no export `{name}`"),
                            );
                            Expr::undefined()
                        }
                    };
                }
                Some(Namespace::Process) => return self.host_api(span, "process"),
                None => {}
            }
        }
        let operands: Vec<&'a Expression<'a>> = match key {
            Key::Computed(key) => vec![object, key],
            _ => vec![object],
        };
        let mut values = self.ordered(&operands).into_iter();
        let receiver = values.next().unwrap_or_else(Expr::undefined);
        let key = match key {
            Key::Static(name) => Expr::binary(name),
            Key::Private(name) => return private_read(receiver, name),
            Key::Computed(_) => values.next().unwrap_or_else(Expr::undefined),
        };
        Expr::rt("get", vec![receiver, key])
    }

    /// `this.m` read as a value: a fun over the current `This`, which sees the fields as they
    /// are now. A method that changes `this` has no such value, because the change would be
    /// lost (`BOUY205`).
    fn method_value(&mut self, name: &str, span: Span) -> Expr {
        let Some(class) = &self.class else {
            return Expr::undefined();
        };
        let function = format!("{}#{name}", class.name);
        if class.mutating.contains(name) {
            self.report(
                span,
                Code::Capture,
                format!(
                    "`this.{name}` changes `this`, so it cannot be a value: a function value keeps a copy of `this` and would lose the change; call `this.{name}(...)` instead"
                ),
            );
            return Expr::undefined();
        }
        let this = self.this(span);
        let args = self.scope.fresh("Args");
        Expr::Fun {
            name: None,
            clauses: vec![Clause::new(
                Expr::var(&args),
                vec![Expr::call(
                    "erlang",
                    "element",
                    vec![
                        Expr::Integer(1),
                        Expr::local_call(&function, vec![this, Expr::Var(args)]),
                    ],
                )],
            )],
        }
    }

    /// `process.env.NAME` and `process.argv`.
    fn process_member(
        &mut self,
        object: &'a Expression<'a>,
        name: &str,
        span: Span,
    ) -> Option<Expr> {
        if let Expression::StaticMemberExpression(env) = strip(object)
            && env.property.name == "env"
            && matches!(self.namespace(&env.object), Some(Namespace::Process))
        {
            return Some(Expr::rt("env", vec![Expr::binary(name)]));
        }
        if matches!(self.namespace(object), Some(Namespace::Process)) {
            return Some(match name {
                "argv" => Expr::rt("argv", Vec::new()),
                _ => self.host_api(span, &format!("process.{name}")),
            });
        }
        None
    }

    fn new_expression(&mut self, new: &'a NewExpression<'a>) -> Expr {
        let Expression::Identifier(ident) = strip(&new.callee) else {
            return self.construct(new);
        };
        let binding = match self.symbol_of(ident) {
            Some(symbol) if self.scope.current(Target::Symbol(symbol)).is_some() => None,
            Some(symbol) => self.module.bindings.get(&symbol).cloned(),
            None => library::global(&ident.name).map(Binding::Library),
        };
        let actor = || {
            format!(
                "`new {}` creates an actor; use `spawn({}, {{ args: [...] }})` from \"bouy\"",
                ident.name, ident.name
            )
        };
        match binding {
            Some(Binding::Library(library::Binding::Namespace("bouy_task"))) => self.unsupported(
                new.span,
                "`new Promise` is not supported; call the async function and await it",
            ),
            Some(Binding::Library(library::Binding::Namespace(module))) => {
                let arguments = self.arguments(&new.arguments);
                Expr::call(module, "new", vec![arguments])
            }
            Some(Binding::Library(library::Binding::ErrorClass(name))) => {
                let arguments = self.arguments(&new.arguments);
                Expr::call("bouy_error", &format!("{name}#new"), vec![arguments])
            }
            Some(Binding::Class { name, kind }) if kind.is_error() => {
                let arguments = self.arguments(&new.arguments);
                Expr::local_call(&format!("{name}#new"), vec![arguments])
            }
            Some(Binding::ImportedClass { module, name, kind }) if kind.is_error() => {
                let arguments = self.arguments(&new.arguments);
                Expr::call(&module, &format!("{name}#new"), vec![arguments])
            }
            Some(
                Binding::Class {
                    kind: ClassKind::Unsupported,
                    ..
                }
                | Binding::ImportedClass {
                    kind: ClassKind::Unsupported,
                    ..
                },
            ) => Expr::undefined(),
            Some(Binding::Class { .. } | Binding::ImportedClass { .. }) => {
                let message = actor();
                self.report(new.span, Code::NewActor, message);
                Expr::undefined()
            }
            _ => self.construct(new),
        }
    }

    /// `new C(args)` where `C` is a value, such as a parameter that holds a class: the call
    /// `'$construct'(C, Args)` of the module helper, which `module_functions` adds.
    fn construct(&mut self, new: &'a NewExpression<'a>) -> Expr {
        let class = self.expr(&new.callee);
        let class = if self.arguments_emit(&new.arguments) {
            self.trivial(class)
        } else {
            class
        };
        let arguments = self.arguments(&new.arguments);
        self.constructs = true;
        Expr::local_call(CONSTRUCT, vec![class, arguments])
    }

    fn chain(&mut self, chain: &'a ChainExpression<'a>) -> Expr {
        // `this.m?.()` and `this?.m()`: `this` and its methods always exist.
        if let ChainElement::CallExpression(call) = &chain.expression
            && let Expression::StaticMemberExpression(member) = &call.callee
            && matches!(strip(&member.object), Expression::ThisExpression(_))
            && self
                .class
                .as_ref()
                .is_some_and(|class| class.methods.contains(member.property.name.as_str()))
        {
            return self.call_method(
                &member.object,
                Key::Static(&member.property.name),
                &call.arguments,
                call,
            );
        }
        if let ChainElement::CallExpression(call) = &chain.expression
            && !call.optional
            && let Expression::StaticMemberExpression(member) = &call.callee
            && member.optional
            && MUTATORS.contains(&member.property.name.as_str())
            && self.roots.receiver(&member.object).is_some()
            && let Some(value) = self.optional_mutate(
                &member.object,
                &member.property.name,
                &call.arguments,
                chain.span,
            )
        {
            return value;
        }
        let mut links = Vec::new();
        let base = match &chain.expression {
            ChainElement::CallExpression(call) => chain_call(call, &mut links),
            ChainElement::TSNonNullExpression(inner) => chain_links(&inner.expression, &mut links),
            ChainElement::StaticMemberExpression(member) => {
                let base = chain_links(&member.object, &mut links);
                links.push(Link::Get {
                    key: Key::Static(&member.property.name),
                    optional: member.optional,
                });
                base
            }
            ChainElement::ComputedMemberExpression(member) => {
                let base = chain_links(&member.object, &mut links);
                links.push(Link::Get {
                    key: Key::Computed(&member.expression),
                    optional: member.optional,
                });
                base
            }
            ChainElement::PrivateFieldExpression(member) => {
                let base = chain_links(&member.object, &mut links);
                links.push(Link::Get {
                    key: Key::Private(&member.field.name),
                    optional: member.optional,
                });
                base
            }
        };
        let rooted = self.roots.place(base).is_some();
        let value = self.expr(base);
        self.apply_links(value, &links, rooted, chain.span)
    }

    fn apply_links(&mut self, value: Expr, links: &[Link<'a>], rooted: bool, span: Span) -> Expr {
        let Some((link, rest)) = links.split_first() else {
            return value;
        };
        let optional = match link {
            Link::Get { optional, .. } | Link::Call { optional, .. } => *optional,
            Link::Method { optional_get, .. } => *optional_get,
        };
        if optional {
            let name = self.scope.temp();
            let inner = self.nested(|lowerer| {
                let next = lowerer.apply_link(Expr::var(&name), link, rooted, span);
                let rooted = rooted && matches!(link, Link::Get { .. });
                lowerer.apply_links(next, rest, rooted, span)
            });
            return absent_or(value, &name, inner);
        }
        let next = self.apply_link(value, link, rooted, span);
        let rooted = rooted && matches!(link, Link::Get { .. });
        self.apply_links(next, rest, rooted, span)
    }

    fn apply_link(&mut self, value: Expr, link: &Link<'a>, rooted: bool, span: Span) -> Expr {
        match link {
            Link::Get {
                key: Key::Private(name),
                ..
            } => private_read(value, name),
            Link::Get { key, .. } => {
                let key = self.key_value(*key);
                Expr::rt("get", vec![value, key])
            }
            Link::Call { arguments, .. } => {
                let arguments = self.chain_arguments(arguments);
                Expr::rt("call", vec![value, arguments])
            }
            Link::Method {
                key,
                arguments,
                optional_call,
                ..
            } => {
                if rooted
                    && let Key::Static(name) = key
                    && MUTATORS.contains(name)
                {
                    return self.unsupported(
                        span,
                        "a mutating method after an optional link is supported only as `place?.method(...)`; check for null with an if statement",
                    );
                }
                let method = self.key_value(*key);
                if !*optional_call {
                    let arguments = self.chain_arguments(arguments);
                    return Expr::rt("call_method", vec![value, method, arguments]);
                }
                let receiver = self.scope.temp();
                let present = self.scope.temp();
                let arguments = self.chain_arguments(arguments);
                let call = Expr::rt(
                    "call_method",
                    vec![Expr::var(&receiver), method.clone(), arguments],
                );
                Expr::Block(vec![
                    Expr::matches(Expr::var(&receiver), value),
                    absent_or(
                        Expr::rt("get", vec![Expr::var(&receiver), method]),
                        &present,
                        call,
                    ),
                ])
            }
        }
    }

    fn key_value(&mut self, key: Key<'a>) -> Expr {
        match key {
            Key::Static(name) => Expr::binary(name),
            Key::Private(name) => Expr::binary(format!("#{name}")),
            Key::Computed(expression) => self.sub_expr(expression),
        }
    }

    fn chain_arguments(&mut self, arguments: &'a [Argument<'a>]) -> Expr {
        if self.arguments_emit(arguments) {
            return self.unsupported(
                arguments.first().map_or_else(Span::default, GetSpan::span),
                "an assignment inside an optional chain is not supported; move it into an if statement",
            );
        }
        self.nested(|lowerer| lowerer.arguments(arguments))
    }
}

fn chain_call<'a>(call: &'a CallExpression<'a>, links: &mut Vec<Link<'a>>) -> &'a Expression<'a> {
    let member = match &call.callee {
        Expression::StaticMemberExpression(member) => Some((
            &member.object,
            Key::Static(&member.property.name),
            member.optional,
        )),
        Expression::ComputedMemberExpression(member) => Some((
            &member.object,
            Key::Computed(&member.expression),
            member.optional,
        )),
        Expression::PrivateFieldExpression(member) => Some((
            &member.object,
            Key::Private(&member.field.name),
            member.optional,
        )),
        _ => None,
    };
    if let Some((object, key, optional_get)) = member {
        let base = chain_links(object, links);
        links.push(Link::Method {
            key,
            arguments: &call.arguments,
            optional_get,
            optional_call: call.optional,
        });
        return base;
    }
    let base = chain_links(&call.callee, links);
    links.push(Link::Call {
        arguments: &call.arguments,
        optional: call.optional,
    });
    base
}

fn chain_links<'a>(
    expression: &'a Expression<'a>,
    links: &mut Vec<Link<'a>>,
) -> &'a Expression<'a> {
    match expression {
        Expression::StaticMemberExpression(member) => {
            let base = chain_links(&member.object, links);
            links.push(Link::Get {
                key: Key::Static(&member.property.name),
                optional: member.optional,
            });
            base
        }
        Expression::ComputedMemberExpression(member) => {
            let base = chain_links(&member.object, links);
            links.push(Link::Get {
                key: Key::Computed(&member.expression),
                optional: member.optional,
            });
            base
        }
        Expression::PrivateFieldExpression(member) => {
            let base = chain_links(&member.object, links);
            links.push(Link::Get {
                key: Key::Private(&member.field.name),
                optional: member.optional,
            });
            base
        }
        Expression::CallExpression(call) => chain_call(call, links),
        Expression::TSNonNullExpression(inner) => chain_links(&inner.expression, links),
        other => other,
    }
}

/// The key of the field `key`: a binary, or for a private field `#name`, the atom `'#name'`.
/// JSON and object literals make only binary keys, and reflection lists only binary keys,
/// so a private field stays private (section 9).
pub fn field_key(key: &str) -> Expr {
    if key.starts_with('#') {
        Expr::atom(key)
    } else {
        Expr::binary(key)
    }
}

/// `object.#name`.
pub fn private_read(object: Expr, name: &str) -> Expr {
    Expr::call(
        "maps",
        "get",
        vec![field_key(&format!("#{name}")), object, Expr::undefined()],
    )
}

/// `object.key = value` for a field key: `maps:put/3` for a private field, else
/// `bouy_rt:set/3`.
pub fn field_write(object: Expr, key: &Expr, value: Expr) -> Expr {
    match key {
        Expr::Atom(_) => Expr::call("maps", "put", vec![key.clone(), value, object]),
        _ => Expr::rt("set", vec![object, key.clone(), value]),
    }
}

/// The namespace of `Data` from "effect", which exists only as an error class base.
const DATA: &str = "bouy_data";

/// The module helper that runs `new` on a class value (section 5).
pub const CONSTRUCT: &str = "$construct";

/// `'$construct'(Class, Args)`: `'C#new'(Args)` of an error class value, `Module:new(Args)` of
/// a global namespace such as `Map`, and a `TypeError` for an actor class or any other value.
pub fn construct_function() -> crate::erlang::Function {
    let var = Expr::var;
    let name_with = |suffix: &str| {
        Expr::call(
            "erlang",
            "binary_to_atom",
            vec![
                Expr::call(
                    "erlang",
                    "iolist_to_binary",
                    vec![Expr::List(vec![var("Name"), Expr::binary(suffix)])],
                ),
                Expr::atom("utf8"),
            ],
        )
    };
    let throw = |message: Expr| {
        Expr::call(
            "bouy_error",
            "throw",
            vec![Expr::binary("TypeError"), message],
        )
    };
    let actor = Expr::call(
        "erlang",
        "function_exported",
        vec![var("Module"), name_with("#dispatch"), Expr::Integer(3)],
    );
    let class = vec![boolean_case(
        actor,
        vec![throw(Expr::rt(
            "concat",
            vec![Expr::List(vec![
                Expr::binary("`new "),
                var("Name"),
                Expr::binary("` creates an actor; use spawn() from \"bouy\""),
            ])],
        ))],
        vec![Expr::call(
            "erlang",
            "apply",
            vec![
                var("Module"),
                name_with("#new"),
                Expr::List(vec![var("Args")]),
            ],
        )],
    )];
    let namespace = vec![Expr::call(
        "erlang",
        "apply",
        vec![
            var("Module"),
            Expr::atom("new"),
            Expr::List(vec![var("Args")]),
        ],
    )];
    let other = vec![throw(Expr::rt(
        "concat",
        vec![Expr::List(vec![
            var("Other"),
            Expr::binary(" is not a constructor"),
        ])],
    ))];
    let clause = |patterns: Vec<Expr>, body: Vec<Expr>| Clause {
        patterns,
        guards: Vec::new(),
        body,
    };
    crate::erlang::Function {
        name: CONSTRUCT.to_owned(),
        clauses: vec![
            clause(
                vec![
                    Expr::Tuple(vec![Expr::atom("$class"), var("Module"), var("Name")]),
                    var("Args"),
                ],
                class,
            ),
            clause(
                vec![
                    Expr::Tuple(vec![Expr::atom("$namespace"), var("Module")]),
                    var("Args"),
                ],
                namespace,
            ),
            clause(vec![var("Other"), var("_Args")], other),
        ],
    }
}

/// The name of a method that `key` reads on `this`: `m` for `this.m`, `#m` for `this.#m`,
/// and `m` for `this["m"]`.
fn own_method(key: Key<'_>) -> Option<String> {
    match key {
        Key::Static(name) => Some(name.to_owned()),
        Key::Private(name) => Some(format!("#{name}")),
        Key::Computed(expression) => match strip(expression) {
            Expression::StringLiteral(literal) => Some(literal.value.to_string()),
            _ => None,
        },
    }
}

/// `case Value of null -> undefined; undefined -> undefined; Name -> Present end`.
fn absent_or(value: Expr, name: &str, present: Expr) -> Expr {
    Expr::case(
        value,
        vec![
            Clause::new(Expr::atom("null"), vec![Expr::undefined()]),
            Clause::new(Expr::undefined(), vec![Expr::undefined()]),
            Clause::new(Expr::var(name), vec![present]),
        ],
    )
}

/// `xs` and `f` of `xs.map(f)`.
fn mapped_items<'a>(
    call: &'a CallExpression<'a>,
) -> Option<(&'a Expression<'a>, &'a Expression<'a>)> {
    let Expression::StaticMemberExpression(member) = strip(&call.callee) else {
        return None;
    };
    match call.arguments.as_slice() {
        [argument]
            if member.property.name == "map" && !member.optional && !argument.is_spread() =>
        {
            Some((&member.object, argument_expression(argument)))
        }
        _ => None,
    }
}

/// The count of parameters of an arrow or function literal without a rest parameter, which
/// is all that it can read of its arguments: Bouy has no `arguments` object.
fn literal_params(expression: &Expression<'_>) -> Option<i64> {
    let params = match strip(expression) {
        Expression::ArrowFunctionExpression(arrow) => &arrow.params,
        Expression::FunctionExpression(function) => &function.params,
        _ => return None,
    };
    if params.rest.is_some() {
        return None;
    }
    i64::try_from(params.items.len()).ok()
}

pub fn argument_expression<'e, 'a>(argument: &'e Argument<'a>) -> &'e Expression<'a> {
    match argument {
        Argument::SpreadElement(spread) => &spread.argument,
        other => other.to_expression(),
    }
}

fn entry(value: Expr, spread: bool, item: &str) -> Expr {
    if spread {
        Expr::tagged("$spread", value)
    } else {
        Expr::tagged(item, value)
    }
}

fn bool_atom(value: bool) -> Expr {
    Expr::atom(if value { "true" } else { "false" })
}

/// The property name of a key that is not computed, or of a computed literal key, as
/// JavaScript converts it: the number key `1e21` names `"1e+21"`.
pub fn static_key(key: &PropertyKey<'_>) -> Option<String> {
    match key {
        PropertyKey::NumericLiteral(number) => Some(number_key(number.value)),
        other => other.static_name().map(std::borrow::Cow::into_owned),
    }
}

/// `String(value)` for a number, as a property key.
fn number_key(value: f64) -> String {
    use oxc::syntax::number::ToJsString;
    if value == 0.0 {
        "0".to_owned()
    } else {
        value.to_js_string()
    }
}

/// A number literal: an integer when it is integral and exactly representable.
pub fn number(value: f64) -> Expr {
    const EXACT: f64 = 9_007_199_254_740_992.0;
    if value.is_nan() {
        return Expr::atom("NaN");
    }
    if value.is_infinite() {
        return Expr::atom(if value > 0.0 { "Infinity" } else { "-Infinity" });
    }
    if value.fract() == 0.0 && value.abs() < EXACT && !(value == 0.0 && value.is_sign_negative()) {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the value is integral and below 2^53"
        )]
        return Expr::Integer(value as i64);
    }
    Expr::Float(value)
}

/// `persistent_term:get({Module, <<"name">>})` (section 2).
pub fn persisted(module: &str, name: &str) -> Expr {
    Expr::call(
        "persistent_term",
        "get",
        vec![Expr::Tuple(vec![Expr::atom(module), Expr::binary(name)])],
    )
}

/// `{'$class', Module, <<"Name">>}` (section 3).
pub fn class_value(module: &str, name: &str) -> Expr {
    Expr::Tuple(vec![
        Expr::atom("$class"),
        Expr::atom(module),
        Expr::binary(name),
    ])
}

/// Whether `value` is an Erlang boolean, so a condition needs no `bouy_rt:truthy/1`.
fn is_boolean(value: &Expr) -> bool {
    match value {
        Expr::Atom(name) => name == "true" || name == "false",
        Expr::Not(_) | Expr::Op(..) => true,
        Expr::Call {
            module: Some(module),
            function,
            ..
        } => {
            module == "bouy_rt"
                && matches!(
                    function.as_str(),
                    "strict_eq"
                        | "loose_eq"
                        | "lt"
                        | "le"
                        | "gt"
                        | "ge"
                        | "truthy"
                        | "instance_of"
                        | "has"
                )
        }
        _ => false,
    }
}

/// The Erlang value of a literal initializer that lowering can inline at each use.
pub fn literal(expression: &Expression<'_>) -> Option<Expr> {
    match strip(expression) {
        Expression::BooleanLiteral(literal) => Some(bool_atom(literal.value)),
        Expression::NullLiteral(_) => Some(Expr::atom("null")),
        Expression::NumericLiteral(literal) => Some(number(literal.value)),
        Expression::StringLiteral(literal) if !literal.lone_surrogates => {
            Some(Expr::binary(literal.value.as_str()))
        }
        Expression::TemplateLiteral(template) if template.expressions.is_empty() => template
            .quasis
            .first()
            .and_then(|quasi| quasi.value.cooked.as_ref())
            .map(|cooked| Expr::binary(cooked.as_str())),
        Expression::Identifier(ident) if ident.name == "undefined" => Some(Expr::undefined()),
        Expression::UnaryExpression(unary) if unary.operator == UnaryOperator::UnaryNegation => {
            match strip(&unary.argument) {
                Expression::NumericLiteral(literal) => Some(number(-literal.value)),
                _ => None,
            }
        }
        Expression::ArrayExpression(array) => array
            .elements
            .iter()
            .map(|element| element.as_expression().and_then(literal))
            .collect::<Option<Vec<_>>>()
            .map(Expr::List),
        Expression::ObjectExpression(object) => object
            .properties
            .iter()
            .map(|property| match property {
                ObjectPropertyKind::ObjectProperty(property)
                    if property.kind == PropertyKind::Init && !property.method =>
                {
                    let key = static_key(&property.key)?;
                    let value = literal(&property.value)?;
                    Some((Expr::binary(key), value))
                }
                _ => None,
            })
            .collect::<Option<Vec<_>>>()
            .map(Expr::Map),
        _ => None,
    }
}
