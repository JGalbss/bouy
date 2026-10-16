//! Lowers one module to Erlang, following sections 2 to 12 of the contract.

mod capture;
pub mod class;
mod expr;
pub mod function;
mod place;
mod rebind;
mod scope;
mod stmt;

use std::collections::{HashMap, HashSet};

use oxc::ast::ast::{
    BindingPattern, Class, Declaration, Expression, FormalParameter, ImportDeclarationSpecifier,
    Program, PropertyDefinition, Statement, TSType, TSTypeAnnotation, TSTypeName,
    VariableDeclarationKind, VariableDeclarator,
};
use oxc::semantic::{Semantic, SymbolId};
use oxc::span::{GetSpan, Span};

use crate::diagnostic::{Code, Diagnostic, Reporter};
use crate::erlang::{self, Clause, Expr};
use crate::graph::{self, Export, Graph};
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
    /// The fields that hold actor refs (section 6), such as `#store` in
    /// `#store: Ref<Store>`, for the class at each span.
    pub ref_fields: Vec<(Span, HashSet<String>)>,
    /// The Bouy modules this module imports, in import order.
    pub imports: Vec<String>,
    /// The export table of each imported Bouy module.
    pub exports: HashMap<String, HashMap<String, Export>>,
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
}

/// A `try` whose `catch` and `finally` must see the variables as they were when the body
/// threw. The body records them under `key` in the process dictionary after each
/// statement that rebinds one.
#[derive(Debug, Clone)]
pub struct Checkpoint {
    pub key: String,
    pub vars: Vec<Target>,
}

/// Lowers `module` to Erlang source.
pub fn lower_module(module: &graph::Module, graph: &Graph) -> Result<String, Vec<Diagnostic>> {
    with_program(&module.path, &module.source, |program, semantic| {
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
    })?
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
            ref_fields: Vec::new(),
            imports: Vec::new(),
            exports: HashMap::new(),
        };
        for statement in &program.body {
            context.declare(statement, semantic, module, graph, reporter);
        }
        context.persisted = persisted(program, semantic, &context, module);
        let ref_types = ref_types(program);
        let mut refs = ActorRefs {
            context: &context,
            scoping: semantic.scoping(),
            ref_types: &ref_types,
            found: HashSet::new(),
            classes: Vec::new(),
            open: Vec::new(),
        };
        oxc::ast_visit::Visit::visit_program(&mut refs, program);
        let ActorRefs { found, classes, .. } = refs;
        context.opaque.extend(found);
        context.ref_fields = classes
            .into_iter()
            .filter(|(_, fields)| !fields.is_empty())
            .collect();
        context
    }

    /// Whether `callee` is `spawn` or `supervise` from "bouy".
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
                module: "bouy",
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
            Statement::ExportDeclaration(export) => {
                self.declare_declaration(&export.declaration, reporter);
            }
            Statement::ExportDefaultDeclaration(export) => reporter.report(
                export.span,
                Code::Unsupported,
                "`export default` is not supported; use a named export",
            ),
            Statement::ExportAllDeclaration(export) => reporter.report(
                export.span,
                Code::Unsupported,
                "re-exports are not supported; import from the module that declares the name",
            ),
            Statement::ExportFromDeclaration(export) if export.export_kind.is_value() => reporter
                .report(
                    export.span,
                    Code::Unsupported,
                    "re-exports are not supported; import from the module that declares the name",
                ),
            other => {
                if let Some(declaration) = other.as_declaration() {
                    self.declare_declaration(declaration, reporter);
                }
            }
        }
    }

    fn declare_declaration(&mut self, declaration: &Declaration<'_>, reporter: &mut Reporter<'_>) {
        match declaration {
            Declaration::FunctionDeclaration(function) => {
                if let Some(id) = &function.id
                    && function.body.is_some()
                    && let Some(symbol) = id.symbol_id.get()
                {
                    reserved(id.name.as_str(), id.span, reporter);
                    self.bindings
                        .insert(symbol, Binding::Function(id.name.to_string()));
                }
            }
            Declaration::ClassDeclaration(class) => {
                if let Some(id) = &class.id
                    && let Some(symbol) = id.symbol_id.get()
                {
                    let kind = class::classify(class).unwrap_or(ClassKind::Actor);
                    self.bindings.insert(
                        symbol,
                        Binding::Class {
                            name: id.name.to_string(),
                            kind,
                        },
                    );
                }
            }
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
                    self.declare_const(&declarator.id, declarator.init.as_ref(), reporter);
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

    fn declare_const(
        &mut self,
        pattern: &BindingPattern<'_>,
        init: Option<&Expression<'_>>,
        reporter: &mut Reporter<'_>,
    ) {
        if let BindingPattern::BindingIdentifier(id) = pattern
            && let Some(symbol) = id.symbol_id.get()
            && init.is_some_and(function::is_function_value)
        {
            reserved(id.name.as_str(), id.span, reporter);
            self.bindings
                .insert(symbol, Binding::Function(id.name.to_string()));
            return;
        }
        let literal = match pattern {
            BindingPattern::BindingIdentifier(_) => init.and_then(expr::literal),
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
                (_, ImportDeclarationSpecifier::ImportDefaultSpecifier(_)) => {
                    reporter.report(
                        item.span(),
                        Code::BadImport,
                        "default imports are not supported; use a named import",
                    );
                    continue;
                }
            };
            match binding {
                Some(binding) => {
                    if matches!(binding, Binding::Library(_) | Binding::ImportedModule(_)) {
                        self.opaque.insert(symbol);
                    }
                    self.bindings.insert(symbol, binding);
                }
                None => reporter.report(
                    item.span(),
                    Code::BadImport,
                    format!("\"{specifier}\" does not export `{}`", local.name),
                ),
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
    if matches!(name, "module_info" | "__init__") {
        reporter.report(
            span,
            Code::Unsupported,
            format!("a module-level function cannot be named `{name}`, which every Erlang module defines; rename it"),
        );
    }
}

/// The local names of the type `Ref` imported from "bouy".
fn ref_types(program: &Program<'_>) -> HashSet<SymbolId> {
    program
        .body
        .iter()
        .filter_map(|statement| match statement {
            Statement::ImportDeclaration(import) if import.source.value == "bouy" => {
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
/// type `Ref<C>` from "bouy". A ref is never a place, so `ref.add(x)` is an actor call and
/// not a `Set` mutation.
struct ActorRefs<'c> {
    context: &'c ModuleContext,
    scoping: &'c oxc::semantic::Scoping,
    ref_types: &'c HashSet<SymbolId>,
    found: HashSet<SymbolId>,
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
}

impl<'a> oxc::ast_visit::Visit<'a> for ActorRefs<'_> {
    fn visit_variable_declarator(&mut self, it: &VariableDeclarator<'a>) {
        if self.declares_ref(it.type_annotation.as_deref()) {
            self.add_bindings(&it.id);
        }
        oxc::ast_visit::walk::walk_variable_declarator(self, it);
    }

    fn visit_formal_parameter(&mut self, it: &FormalParameter<'a>) {
        if self.declares_ref(it.type_annotation.as_deref()) {
            self.add_bindings(&it.pattern);
        }
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
                    && let Some(symbol) = declarator
                        .id
                        .get_binding_identifier()
                        .and_then(|id| id.symbol_id.get())
                {
                    self.found.insert(symbol);
                }
            }
        }
        oxc::ast_visit::walk::walk_variable_declaration(self, it);
    }
}

fn imported(target: &graph::Module, name: &str) -> Option<Binding> {
    let module = target.name.clone();
    Some(match target.exports.get(name)? {
        Export::Function(local) => Binding::ImportedFunction {
            module,
            name: local.clone(),
        },
        Export::Const(local) => Binding::ImportedConst {
            module,
            name: local.clone(),
        },
        Export::Class(local, kind) => Binding::ImportedClass {
            module,
            name: local.clone(),
            kind: kind.clone(),
        },
    })
}

/// The module-level consts that functions read or other modules import. `'__init__'/0`
/// stores them in `persistent_term`.
fn persisted(
    program: &Program<'_>,
    semantic: &Semantic<'_>,
    context: &ModuleContext,
    module: &graph::Module,
) -> HashSet<SymbolId> {
    let units = function_units(program);
    let exported: HashSet<&str> = module
        .exports
        .values()
        .filter_map(|export| match export {
            Export::Const(local) => Some(local.as_str()),
            _ => None,
        })
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

/// The spans of module-level code that becomes named Erlang functions.
fn function_units(program: &Program<'_>) -> Vec<Span> {
    let mut units = Vec::new();
    for statement in &program.body {
        let declaration = match statement {
            Statement::ExportDeclaration(export) => &export.declaration,
            other => match other.as_declaration() {
                Some(declaration) => declaration,
                None => continue,
            },
        };
        match declaration {
            Declaration::FunctionDeclaration(function) => units.push(function.span),
            Declaration::ClassDeclaration(class) => units.push(class.span),
            Declaration::VariableDeclaration(variables) => units.extend(
                variables
                    .declarations
                    .iter()
                    .filter_map(|declarator| declarator.init.as_ref())
                    .filter(|init| function::is_function_value(init))
                    .map(GetSpan::span),
            ),
            _ => {}
        }
    }
    units
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

    /// Binds `value` to `pattern` in the sequence.
    pub fn push_match(&mut self, pattern: Expr, value: Expr) {
        match value {
            Expr::Block(mut body) => {
                let last = body.pop().unwrap_or_else(Expr::undefined);
                self.seq.extend(body);
                self.seq.push(Expr::matches(pattern, last));
            }
            other => self.seq.push(Expr::matches(pattern, other)),
        }
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
        for statement in &program.body {
            let declaration = match statement {
                Statement::ExportDeclaration(export) => &export.declaration,
                other => match other.as_declaration() {
                    Some(declaration) => declaration,
                    None => continue,
                },
            };
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
            .map(|module| Expr::call("bouy_main", "import", vec![Expr::atom(module)]))
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
