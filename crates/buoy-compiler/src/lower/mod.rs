//! Lowers one module to Erlang, following sections 2 to 12 of the contract.

mod capture;
pub mod class;
mod expr;
pub mod function;
mod hoist;
mod place;
mod rebind;
mod scope;
mod stmt;

use std::collections::{HashMap, HashSet};

use oxc::ast::ast::{
    BindingPattern, Class, Declaration, ExportDefaultDeclarationKind, Expression, FormalParameter,
    Function, ImportDeclarationSpecifier, Program, PropertyDefinition, Statement, TSType,
    TSTypeAnnotation, TSTypeName, VariableDeclarationKind, VariableDeclarator,
};
use oxc::semantic::{Semantic, SymbolId};
use oxc::span::{GetSpan, Span};

use crate::diagnostic::{Code, Diagnostic, Reporter};
use crate::erlang::{self, Clause, Expr};
use crate::graph::{self, ExportKind, Graph};
use crate::library;
use crate::parse::with_program;

use class::{ClassContext, ClassKind};
use rebind::{Rebound, Roots};
use scope::{Scope, Target};

/// What a module-scope name refers to.
#[derive(Debug, Clone)]
pub enum Binding {
    /// A function of this module, by its Erlang name.
    Function(String),
    /// A module-level `const`. A literal initializer is inlined at each use.
    Const {
        key: String,
        literal: Option<Expr>,
    },
    Class {
        name: String,
        kind: ClassKind,
    },
    ImportedFunction {
        module: String,
        name: String,
    },
    ImportedConst {
        module: String,
        name: String,
    },
    ImportedClass {
        module: String,
        name: String,
        kind: ClassKind,
    },
    /// `import * as m from "./m.ts"`.
    ImportedModule(String),
    Library(library::Binding),
}

/// Facts about the module that every function in it needs.
#[derive(Debug)]
pub struct ModuleContext {
    /// The Erlang module name.
    pub name: String,
    pub bindings: HashMap<SymbolId, Binding>,
    /// Module-level consts that `'__init__'/0` stores in `persistent_term`.
    pub persisted: HashSet<SymbolId>,
    /// Symbols that are never places: library and module namespace imports, and actor refs.
    pub opaque: HashSet<SymbolId>,
    /// Variables and parameters declared with the type `Promise<T>`.
    pub promises: HashSet<SymbolId>,
    /// The local names of `Data` from "effect", for error class bases.
    pub data: HashSet<SymbolId>,
    /// The fields that hold actor refs (section 6), such as `#store` in
    /// `#store: Ref<Store>`, for the class at each span.
    pub ref_fields: Vec<(Span, HashSet<String>)>,
    /// The Buoy modules this module imports, in import order.
    pub imports: Vec<String>,
    /// The export table of each imported Buoy module.
    pub exports: HashMap<String, HashMap<String, graph::Export>>,
}

/// How the function being lowered returns a value (section 9).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Frame {
    /// A function: returns the value.
    Function,
    /// A class method: returns `{Result, This1}`.
    Method,
    /// A constructor: returns `This`.
    Constructor,
    /// `'__init__'/0`: returns `ok`.
    Init,
}

/// What the end of a block, and each jump out of it, must evaluate to (section 12).
#[derive(Debug, Clone, Copy)]
pub enum Tail<'t> {
    /// The body of a function.
    Function,
    /// A branch of an `if`, `try`, or conditional statement that rebinds `vars`.
    Branch { vars: &'t [Target], abrupt: bool },
    /// The body of a `switch` case. `vars` are the variables the switch rebinds.
    SwitchCase { vars: &'t [Target], abrupt: bool },
    /// The body of the innermost loop.
    LoopBody,
}

/// A statement that `break` or `continue` can target.
#[derive(Debug, Clone)]
pub enum JumpTarget<'a> {
    Loop {
        state: Vec<Target>,
        fun: String,
        next: Next<'a>,
    },
    Switch {
        vars: Vec<Target>,
    },
}

/// How a loop starts its next iteration.
#[derive(Debug, Clone, Copy)]
pub enum Next<'a> {
    /// `for`: run the update, then recurse.
    For(Option<&'a Expression<'a>>),
    /// `while`: recurse.
    While,
    /// `do...while`: test, then recurse or break.
    DoWhile(&'a Expression<'a>),
    /// `for...of` and `for...in`: recurse on the rest of the items.
    Each,
}

/// Whether a statement left control in the block or ended the block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flow {
    Continue,
    Ended,
}

pub struct Lowerer<'a, 'c> {
    pub semantic: &'a Semantic<'a>,
    pub module: &'c ModuleContext,
    pub roots: Roots<'c>,
    pub reporter: Reporter<'c>,
    pub scope: Scope,
    /// The statement sequence being built.
    pub seq: Vec<Expr>,
    pub frame: Frame,
    pub targets: Vec<JumpTarget<'a>>,
    pub class: Option<ClassContext>,
    /// The name of the `Rest` variable of each enclosing `for...of`, innermost last.
    pub rests: Vec<String>,
    /// The enclosing `try` statements that record their variables (section 7).
    pub checkpoints: Vec<Checkpoint>,
    /// The nested function declarations already created, by span.
    pub hoisted: HashSet<Span>,
    /// The nested function declarations that a group creates later in their block.
    pub pending: HashSet<Span>,
    /// The spans of the closures being lowered, innermost last.
    pub closures: Vec<Span>,
    /// Whether the module needs the `'$construct'/2` helper for `new` on a class value.
    pub constructs: bool,
    /// Whether the code being lowered is directly in the body of a generator function, an
    /// Effect body (section 13).
    pub generator: bool,
}

/// A `try` whose `catch` and `finally` must see the variables as they were when the body
/// threw. The body records them under `key` in the process dictionary at each rebinding.
#[derive(Debug, Clone)]
pub struct Checkpoint {
    pub key: String,
    pub vars: Vec<Target>,
}

/// Lowers `module` to Erlang source.
pub fn lower_module(module: &graph::Module, graph: &Graph) -> Result<String, Vec<Diagnostic>> {
    with_program(
        &module.path,
        &module.source,
        module.source_type,
        |program, semantic| {
            let mut reporter = Reporter::new(&module.path, &module.source);
            let context = ModuleContext::build(program, semantic, module, graph, &mut reporter);
            let roots = Roots {
                scoping: semantic.scoping(),
                opaque: &context.opaque,
                ref_fields: &context.ref_fields,
            };
            capture::check(program, semantic, &context, &roots, &mut reporter);
            let mut lowerer = Lowerer {
                semantic,
                module: &context,
                roots,
                reporter,
                scope: Scope::default(),
                seq: Vec::new(),
                frame: Frame::Init,
                targets: Vec::new(),
                class: None,
                rests: Vec::new(),
                checkpoints: Vec::new(),
                hoisted: HashSet::new(),
                pending: HashSet::new(),
                closures: Vec::new(),
                constructs: false,
                generator: false,
            };
            let functions = lowerer.module_functions(program);
            if lowerer.reporter.diagnostics.is_empty() {
                Ok(erlang::print_module(&erlang::Module {
                    name: context.name.clone(),
                    functions,
                }))
            } else {
                Err(lowerer.reporter.diagnostics)
            }
        },
    )?
}

impl ModuleContext {
    fn build(
        program: &Program<'_>,
        semantic: &Semantic<'_>,
        module: &graph::Module,
        graph: &Graph,
        reporter: &mut Reporter<'_>,
    ) -> Self {
        let mut context = Self {
            name: module.name.clone(),
            bindings: HashMap::new(),
            persisted: HashSet::new(),
            opaque: HashSet::new(),
            promises: HashSet::new(),
            data: class::data_imports(program),
            ref_fields: Vec::new(),
            imports: Vec::new(),
            exports: HashMap::new(),
        };
        for statement in &program.body {
            context.declare(statement, semantic, module, graph, reporter);
        }
        for declaration in graph::module_declarations(program) {
            context.declare_declaration(declaration, semantic, reporter);
        }
        context.persisted = persisted(program, semantic, &context, module);
        let ref_types = ref_types(program);
        let mut refs = ActorRefs {
            context: &context,
            scoping: semantic.scoping(),
            ref_types: &ref_types,
            found: HashSet::new(),
            promises: HashSet::new(),
            classes: Vec::new(),
            open: Vec::new(),
        };
        oxc::ast_visit::Visit::visit_program(&mut refs, program);
        let ActorRefs {
            found,
            promises,
            classes,
            ..
        } = refs;
        context.opaque.extend(found);
        context.promises = promises;
        context.ref_fields = classes
            .into_iter()
            .filter(|(_, fields)| !fields.is_empty())
            .collect();
        context
    }

    /// Whether `callee` is `spawn` or `supervise` from "buoy".
    fn spawns(&self, callee: &Expression<'_>, scoping: &oxc::semantic::Scoping) -> bool {
        let Expression::Identifier(ident) = rebind::strip(callee) else {
            return false;
        };
        let symbol = ident
            .reference_id
            .get()
            .and_then(|id| scoping.get_reference(id).symbol_id());
        matches!(
            symbol.and_then(|symbol| self.bindings.get(&symbol)),
            Some(Binding::Library(library::Binding::Function {
                module: "buoy",
                function: "spawn" | "supervise",
            }))
        )
    }

    fn declare(
        &mut self,
        statement: &Statement<'_>,
        semantic: &Semantic<'_>,
        module: &graph::Module,
        graph: &Graph,
        reporter: &mut Reporter<'_>,
    ) {
        match statement {
            Statement::ImportDeclaration(import) if import.import_kind.is_value() => {
                self.import(import, semantic, module, graph, reporter);
            }
            Statement::ExportDefaultDeclaration(export) => match &export.declaration {
                ExportDefaultDeclarationKind::FunctionDeclaration(function)
                    if function.id.is_some() =>
                {
                    self.declare_function(function, reporter);
                }
                ExportDefaultDeclarationKind::ClassDeclaration(class) if class.id.is_some() => {
                    self.declare_class(class, semantic);
                }
                _ => reporter.report(
                    export.span,
                    Code::Unsupported,
                    "`export default` is supported only on a named function or class declaration; declare the value with a name and export that",
                ),
            },
            _ => {}
        }
    }

    fn declare_declaration(
        &mut self,
        declaration: &Declaration<'_>,
        semantic: &Semantic<'_>,
        reporter: &mut Reporter<'_>,
    ) {
        match declaration {
            Declaration::FunctionDeclaration(function) => self.declare_function(function, reporter),
            Declaration::ClassDeclaration(class) => self.declare_class(class, semantic),
            Declaration::VariableDeclaration(variables) if !variables.declare => {
                if variables.kind != VariableDeclarationKind::Const {
                    reporter.report(
                        variables.span,
                        Code::ModuleState,
                        format!(
                            "a module-level `{}` is shared mutable state; use `const`, or keep the state in a function or an actor",
                            variables.kind.as_str()
                        ),
                    );
                }
                for declarator in &variables.declarations {
                    self.declare_const(declarator, reporter);
                }
            }
            Declaration::TSEnumDeclaration(enumeration) if !enumeration.declare => reporter.report(
                enumeration.span,
                Code::Unsupported,
                "enums are not supported; use a union of string literals",
            ),
            Declaration::TSNamespaceDeclaration(namespace) if !namespace.declare => reporter
                .report(
                    namespace.span,
                    Code::Unsupported,
                    "namespaces are not supported; use modules",
                ),
            _ => {}
        }
    }

    fn declare_function(&mut self, function: &Function<'_>, reporter: &mut Reporter<'_>) {
        if let Some(id) = &function.id
            && function.body.is_some()
            && let Some(symbol) = id.symbol_id.get()
        {
            reserved(id.name.as_str(), id.span, reporter);
            self.bindings
                .insert(symbol, Binding::Function(id.name.to_string()));
        }
    }

    fn declare_class(&mut self, class: &Class<'_>, semantic: &Semantic<'_>) {
        if let Some(id) = &class.id
            && let Some(symbol) = id.symbol_id.get()
        {
            let kind = class::classify(class, semantic.scoping(), &self.data)
                .unwrap_or(ClassKind::Unsupported);
            self.bindings.insert(
                symbol,
                Binding::Class {
                    name: id.name.to_string(),
                    kind,
                },
            );
        }
    }

    fn declare_const(&mut self, declarator: &VariableDeclarator<'_>, reporter: &mut Reporter<'_>) {
        let pattern = &declarator.id;
        if let BindingPattern::BindingIdentifier(id) = pattern
            && let Some(symbol) = id.symbol_id.get()
            && graph::is_function_const(declarator)
        {
            reserved(id.name.as_str(), id.span, reporter);
            self.bindings
                .insert(symbol, Binding::Function(id.name.to_string()));
            // `const g = function f() {...}`: `f` names the same function inside its body.
            if let Some(Expression::FunctionExpression(function)) =
                declarator.init.as_ref().map(rebind::strip)
                && let Some(own) = function.id.as_ref().and_then(|id| id.symbol_id.get())
            {
                self.bindings
                    .insert(own, Binding::Function(id.name.to_string()));
            }
            return;
        }
        let literal = match pattern {
            BindingPattern::BindingIdentifier(_) => {
                declarator.init.as_ref().and_then(expr::literal)
            }
            _ => None,
        };
        for id in pattern.get_binding_identifiers() {
            if let Some(symbol) = id.symbol_id.get() {
                self.bindings.insert(
                    symbol,
                    Binding::Const {
                        key: id.name.to_string(),
                        literal: literal.clone(),
                    },
                );
            }
        }
    }

    fn import(
        &mut self,
        import: &oxc::ast::ast::ImportDeclaration<'_>,
        semantic: &Semantic<'_>,
        module: &graph::Module,
        graph: &Graph,
        reporter: &mut Reporter<'_>,
    ) {
        let specifier = import.source.value.as_str();
        let target = module
            .imports
            .get(specifier)
            .and_then(|name| graph.module(name));
        if let Some(target) = target
            && !self.imports.contains(&target.name)
        {
            self.imports.push(target.name.clone());
            self.exports
                .insert(target.name.clone(), target.exports.clone());
        }
        for item in import.specifiers.iter().flatten() {
            let local = item.local();
            let Some(symbol) = local.symbol_id.get() else {
                continue;
            };
            if !graph::has_value_use(semantic, local) {
                continue;
            }
            let binding = match (target, item) {
                (None, ImportDeclarationSpecifier::ImportSpecifier(named)) => {
                    library::named_import(specifier, named.imported.name().as_str())
                        .map(Binding::Library)
                }
                (None, ImportDeclarationSpecifier::ImportNamespaceSpecifier(_)) => {
                    library::namespace_import(specifier).map(Binding::Library)
                }
                (Some(target), ImportDeclarationSpecifier::ImportSpecifier(named)) => {
                    imported(target, named.imported.name().as_str())
                }
                (Some(target), ImportDeclarationSpecifier::ImportNamespaceSpecifier(_)) => {
                    Some(Binding::ImportedModule(target.name.clone()))
                }
                (Some(target), ImportDeclarationSpecifier::ImportDefaultSpecifier(_)) => {
                    imported(target, "default")
                }
                (None, ImportDeclarationSpecifier::ImportDefaultSpecifier(_)) => None,
            };
            let name = match item {
                ImportDeclarationSpecifier::ImportSpecifier(named) => {
                    named.imported.name().to_string()
                }
                ImportDeclarationSpecifier::ImportDefaultSpecifier(_) => "default".to_owned(),
                ImportDeclarationSpecifier::ImportNamespaceSpecifier(_) => "*".to_owned(),
            };
            if let Some(binding) = binding {
                if matches!(binding, Binding::Library(_) | Binding::ImportedModule(_)) {
                    self.opaque.insert(symbol);
                }
                self.bindings.insert(symbol, binding);
            } else {
                reporter.report(
                    item.span(),
                    Code::MissingExport,
                    format!("\"{specifier}\" does not export `{name}`"),
                );
                // The name reads as `undefined`, so its uses report nothing more.
                self.bindings.insert(
                    symbol,
                    Binding::Library(library::Binding::Constant("undefined")),
                );
            }
        }
    }

    /// Whether `symbol` is declared at module scope.
    pub fn is_module_scope(&self, symbol: SymbolId) -> bool {
        self.bindings.contains_key(&symbol)
    }
}

/// Reports a module-level function whose name is one that every Erlang module defines.
fn reserved(name: &str, span: Span, reporter: &mut Reporter<'_>) {
    if matches!(name, "module_info" | "__init__" | "$construct") {
        reporter.report(
            span,
            Code::Unsupported,
            format!("a module-level function cannot be named `{name}`, which every Erlang module defines; rename it"),
        );
    }
}

/// The local names of the type `Ref` imported from "buoy".
fn ref_types(program: &Program<'_>) -> HashSet<SymbolId> {
    program
        .body
        .iter()
        .filter_map(|statement| match statement {
            Statement::ImportDeclaration(import) if import.source.value == "buoy" => {
                import.specifiers.as_ref()
            }
            _ => None,
        })
        .flatten()
        .filter_map(|specifier| match specifier {
            ImportDeclarationSpecifier::ImportSpecifier(named)
                if named.imported.name() == "Ref" =>
            {
                named.local.symbol_id.get()
            }
            _ => None,
        })
        .collect()
}

/// The bindings and fields that hold actor refs (section 6): `const ref = spawn(...)`,
/// `const team = supervise(...)`, and a variable, parameter, or field declared with the
/// type `Ref<C>` from "buoy". A ref is never a place, so `ref.add(x)` is an actor call and
/// not a `Set` mutation.
struct ActorRefs<'c> {
    context: &'c ModuleContext,
    scoping: &'c oxc::semantic::Scoping,
    ref_types: &'c HashSet<SymbolId>,
    found: HashSet<SymbolId>,
    /// The bindings declared with the type `Promise<T>`.
    promises: HashSet<SymbolId>,
    /// The span of each class and its fields of type `Ref`.
    classes: Vec<(Span, HashSet<String>)>,
    /// The classes that enclose the visit, as indexes into `classes`.
    open: Vec<usize>,
}

impl ActorRefs<'_> {
    fn declares_ref(&self, annotation: Option<&TSTypeAnnotation<'_>>) -> bool {
        annotation.is_some_and(|annotation| self.is_ref(&annotation.type_annotation))
    }

    /// `Ref<C>`, or a union of it with `undefined` and `null`.
    fn is_ref(&self, ty: &TSType<'_>) -> bool {
        match ty {
            TSType::TSTypeReference(reference) => match &reference.type_name {
                TSTypeName::IdentifierReference(ident) => ident
                    .reference_id
                    .get()
                    .and_then(|id| self.scoping.get_reference(id).symbol_id())
                    .is_some_and(|symbol| self.ref_types.contains(&symbol)),
                _ => false,
            },
            TSType::TSUnionType(union) => {
                let values: Vec<&TSType<'_>> = union
                    .types
                    .iter()
                    .filter(|member| {
                        !matches!(
                            member,
                            TSType::TSUndefinedKeyword(_) | TSType::TSNullKeyword(_)
                        )
                    })
                    .collect();
                !values.is_empty() && values.iter().all(|member| self.is_ref(member))
            }
            _ => false,
        }
    }

    fn add_bindings(&mut self, pattern: &BindingPattern<'_>) {
        self.found.extend(
            pattern
                .get_binding_identifiers()
                .iter()
                .filter_map(|id| id.symbol_id.get()),
        );
    }

    /// Records the bindings of `pattern` when `annotation` is the global `Promise<T>`.
    fn add_promises(
        &mut self,
        pattern: &BindingPattern<'_>,
        annotation: Option<&TSTypeAnnotation<'_>>,
    ) {
        let promise = annotation.is_some_and(|annotation| {
            matches!(
                &annotation.type_annotation,
                TSType::TSTypeReference(reference)
                    if matches!(&reference.type_name, TSTypeName::IdentifierReference(name)
                        if name.name == "Promise" || name.name == "PromiseLike")
            )
        });
        if promise {
            self.promises.extend(
                pattern
                    .get_binding_identifiers()
                    .iter()
                    .filter_map(|id| id.symbol_id.get()),
            );
        }
    }
}

impl<'a> oxc::ast_visit::Visit<'a> for ActorRefs<'_> {
    fn visit_variable_declarator(&mut self, it: &VariableDeclarator<'a>) {
        if self.declares_ref(it.type_annotation.as_deref()) {
            self.add_bindings(&it.id);
        }
        self.add_promises(&it.id, it.type_annotation.as_deref());
        oxc::ast_visit::walk::walk_variable_declarator(self, it);
    }

    fn visit_formal_parameter(&mut self, it: &FormalParameter<'a>) {
        if self.declares_ref(it.type_annotation.as_deref()) {
            self.add_bindings(&it.pattern);
        }
        self.add_promises(&it.pattern, it.type_annotation.as_deref());
        oxc::ast_visit::walk::walk_formal_parameter(self, it);
    }

    fn visit_class(&mut self, it: &Class<'a>) {
        self.open.push(self.classes.len());
        self.classes.push((it.span, HashSet::new()));
        oxc::ast_visit::walk::walk_class(self, it);
        self.open.pop();
    }

    fn visit_property_definition(&mut self, it: &PropertyDefinition<'a>) {
        if self.declares_ref(it.type_annotation.as_deref())
            && let Some(key) = class::key_name(&it.key)
            && let Some(&index) = self.open.last()
        {
            self.classes[index].1.insert(key);
        }
        oxc::ast_visit::walk::walk_property_definition(self, it);
    }

    fn visit_variable_declaration(&mut self, it: &oxc::ast::ast::VariableDeclaration<'a>) {
        if it.kind == VariableDeclarationKind::Const {
            for declarator in &it.declarations {
                let init = declarator.init.as_ref().map(rebind::strip);
                let init = match init {
                    Some(Expression::AwaitExpression(awaited)) => {
                        Some(rebind::strip(&awaited.argument))
                    }
                    other => other,
                };
                if let Some(Expression::CallExpression(call)) = init
                    && self.context.spawns(&call.callee, self.scoping)
                {
                    // `const { a, b } = supervise(...)` binds a ref to each name.
                    self.add_bindings(&declarator.id);
                }
            }
        }
        oxc::ast_visit::walk::walk_variable_declaration(self, it);
    }
}

fn imported(target: &graph::Module, name: &str) -> Option<Binding> {
    let export = target.exports.get(name)?;
    let module = export.module.clone();
    let local = export.local.clone();
    Some(match &export.kind {
        ExportKind::Function => Binding::ImportedFunction {
            module,
            name: local,
        },
        ExportKind::Const => Binding::ImportedConst {
            module,
            name: local,
        },
        ExportKind::Class(kind) => Binding::ImportedClass {
            module,
            name: local,
            kind: kind.clone(),
        },
        ExportKind::Namespace => Binding::ImportedModule(module),
    })
}

/// The module-level consts that functions read or other modules import. `'__init__'/0`
/// stores them in `persistent_term`. A function here is any code that can run after the
/// top-level code, such as a closure in the initializer of the const it reads.
fn persisted(
    program: &Program<'_>,
    semantic: &Semantic<'_>,
    context: &ModuleContext,
    module: &graph::Module,
) -> HashSet<SymbolId> {
    let units = deferred_code(program);
    let exported: HashSet<&str> = module
        .exports
        .values()
        .filter(|export| export.kind == ExportKind::Const && export.module == module.name)
        .map(|export| export.local.as_str())
        .collect();
    context
        .bindings
        .iter()
        .filter_map(|(symbol, binding)| match binding {
            Binding::Const { key, literal } => Some((*symbol, key, literal.is_some())),
            _ => None,
        })
        .filter(|(symbol, key, literal)| {
            exported.contains(key.as_str())
                || !literal
                    && semantic
                        .scoping()
                        .get_resolved_references(*symbol)
                        .any(|reference| {
                            let at = semantic.reference_span(reference);
                            units
                                .iter()
                                .any(|unit| unit.start <= at.start && at.end <= unit.end)
                        })
        })
        .map(|(symbol, _, _)| symbol)
        .collect()
}

/// The spans of the code that runs later than the top-level statements around it: every
/// function, arrow function, and class.
fn deferred_code(program: &Program<'_>) -> Vec<Span> {
    struct Deferred(Vec<Span>);
    impl<'a> oxc::ast_visit::Visit<'a> for Deferred {
        fn visit_function(&mut self, it: &Function<'a>, _: oxc::syntax::scope::ScopeFlags) {
            self.0.push(it.span);
        }
        fn visit_arrow_function_expression(
            &mut self,
            it: &oxc::ast::ast::ArrowFunctionExpression<'a>,
        ) {
            self.0.push(it.span);
        }
        fn visit_class(&mut self, it: &Class<'a>) {
            self.0.push(it.span);
        }
    }
    let mut deferred = Deferred(Vec::new());
    oxc::ast_visit::Visit::visit_program(&mut deferred, program);
    deferred.0
}

impl<'a> Lowerer<'a, '_> {
    pub fn report(&mut self, span: Span, code: Code, message: impl Into<String>) {
        self.reporter.report(span, code, message);
    }

    /// Reports syntax that has no lowering and returns a placeholder value.
    pub fn unsupported(&mut self, span: Span, message: impl Into<String>) -> Expr {
        self.report(span, Code::Unsupported, message);
        Expr::undefined()
    }

    /// Lowers `build` into a separate sequence with its own versions, and returns that
    /// sequence. The versions and the current sequence are restored afterwards.
    pub fn branch(&mut self, build: impl FnOnce(&mut Self)) -> Vec<Expr> {
        let versions = self.scope.versions();
        let outer = std::mem::take(&mut self.seq);
        build(self);
        let body = std::mem::replace(&mut self.seq, outer);
        self.scope.restore(versions);
        if body.is_empty() {
            vec![Expr::ok()]
        } else {
            body
        }
    }

    /// Pushes `expr` as a statement, splicing a `begin ... end` block into the sequence.
    pub fn push(&mut self, expr: Expr) {
        match expr {
            Expr::Block(body) => self.seq.extend(body),
            other => self.seq.push(other),
        }
    }

    /// Binds `value` to `pattern` in the sequence, and records each open checkpoint whose
    /// variables the pattern rebinds.
    pub fn push_match(&mut self, pattern: Expr, value: Expr) {
        let records = self.records(&pattern);
        match value {
            Expr::Block(mut body) => {
                let last = body.pop().unwrap_or_else(Expr::undefined);
                self.seq.extend(body);
                self.seq.push(Expr::matches(pattern, last));
            }
            other => self.seq.push(Expr::matches(pattern, other)),
        }
        self.seq.extend(records);
    }

    /// `erlang:put(Key, {Vars})` for each open checkpoint (section 7) that `pattern` gives a
    /// new version. Recording at each rebinding, and not after each statement, lets `catch`
    /// and `finally` see a rebinding that a later part of the same statement follows with a
    /// throw, and a rebinding inside a loop header or a jumping `if`.
    fn records(&self, pattern: &Expr) -> Vec<Expr> {
        self.checkpoints
            .iter()
            .filter(|checkpoint| {
                checkpoint.vars.iter().any(|target| {
                    self.scope
                        .current(*target)
                        .is_some_and(|name| pattern.binds(name))
                })
            })
            .map(|checkpoint| {
                Expr::call(
                    "erlang",
                    "put",
                    vec![
                        Expr::var(&checkpoint.key),
                        self.scope.tuple(&checkpoint.vars),
                    ],
                )
            })
            .collect()
    }

    /// `value` as a variable or literal, binding it to a temporary when it is neither.
    pub fn trivial(&mut self, value: Expr) -> Expr {
        if value.is_trivial() {
            return value;
        }
        let name = self.scope.temp();
        self.push_match(Expr::var(&name), value);
        Expr::Var(name)
    }

    /// The variables that `nodes` rebind, declared outside `exclude`, in a stable order.
    pub fn rebound(&self, exclude: Span, visit: impl FnOnce(&mut Rebound<'_>)) -> Vec<Target> {
        let methods = self.class.as_ref().map(|class| &class.mutating);
        let mut rebound = Rebound::new(&self.roots, methods, exclude);
        visit(&mut rebound);
        rebound.finish()
    }

    /// Whether lowering `expr` rebinds a variable.
    pub fn emits(&self, expr: &Expression<'_>) -> bool {
        use oxc::ast_visit::Visit;
        !self
            .rebound(Span::default(), |rebound| rebound.visit_expression(expr))
            .is_empty()
    }

    /// The Erlang variable base name of a target.
    pub fn base(&self, target: Target) -> String {
        match target {
            Target::This => "This".to_owned(),
            Target::Symbol(symbol) => scope::base_name(self.semantic.scoping().symbol_name(symbol)),
        }
    }

    /// Gives each target a fresh version and returns the tuple of the new names.
    pub fn rebind_tuple(&mut self, targets: &[Target]) -> Expr {
        Expr::Tuple(
            targets
                .iter()
                .map(|target| {
                    let base = self.base(*target);
                    Expr::Var(self.scope.bind(*target, &base))
                })
                .collect(),
        )
    }

    /// The value the current function returns for `value` (section 9).
    pub fn frame_return(&self, value: Expr) -> Expr {
        let this = || {
            self.scope
                .current(Target::This)
                .map_or_else(Expr::undefined, Expr::var)
        };
        match self.frame {
            Frame::Function => value,
            Frame::Method => Expr::Tuple(vec![value, this()]),
            Frame::Constructor => this(),
            Frame::Init => Expr::ok(),
        }
    }

    fn module_functions(&mut self, program: &'a Program<'a>) -> Vec<erlang::Function> {
        let mut functions = vec![self.init(program)];
        match graph::default_export(program) {
            Some(graph::DefaultExport::Function(function)) => {
                if let Some(id) = &function.id {
                    functions.push(
                        self.named_function(&id.name, function::Callable::Function(function)),
                    );
                }
            }
            Some(graph::DefaultExport::Class(class)) => functions.extend(self.class(class)),
            None => {}
        }
        for declaration in graph::module_declarations(program) {
            match declaration {
                Declaration::FunctionDeclaration(function) => {
                    if let Some(id) = &function.id
                        && function.body.is_some()
                    {
                        functions.push(
                            self.named_function(&id.name, function::Callable::Function(function)),
                        );
                    }
                }
                Declaration::VariableDeclaration(variables) => {
                    for declarator in &variables.declarations {
                        if let (BindingPattern::BindingIdentifier(id), Some(init)) =
                            (&declarator.id, &declarator.init)
                            && let Some(callable) = function::Callable::of(init)
                        {
                            functions.push(self.named_function(&id.name, callable));
                        }
                    }
                }
                Declaration::ClassDeclaration(class) => functions.extend(self.class(class)),
                _ => {}
            }
        }
        if self.constructs {
            functions.push(expr::construct_function());
        }
        functions
    }

    /// `'__init__'/0`: imports, then the top-level statements in order (section 2).
    fn init(&mut self, program: &'a Program<'a>) -> erlang::Function {
        self.scope = Scope::default();
        self.frame = Frame::Init;
        self.seq = self
            .module
            .imports
            .iter()
            .map(|module| Expr::call("buoy_main", "import", vec![Expr::atom(module)]))
            .collect();
        let statements: Vec<&'a Statement<'a>> = program.body.iter().collect();
        self.block_of(&statements, &Tail::Function);
        erlang::Function {
            name: "__init__".to_owned(),
            clauses: vec![Clause {
                patterns: Vec::new(),
                guards: Vec::new(),
                body: std::mem::take(&mut self.seq),
            }],
        }
    }
}
