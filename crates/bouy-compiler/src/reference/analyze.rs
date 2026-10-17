//! The facts the reference lowering needs before it emits code: which variables live in
//! heap cells, and the shape of the control flow of a statement.

use std::collections::HashSet;

use oxc::ast::AstKind;
use oxc::ast::ast::{
    ArrowFunctionExpression, AwaitExpression, BindingPattern, Class, ForOfStatement, ForStatement,
    ForStatementInit, FormalParameters, Function, IdentifierReference, NewTarget, Program,
    Statement, ThisExpression, VariableDeclaration, VariableDeclarationKind, YieldExpression,
};
use oxc::ast_visit::{Visit, walk};
use oxc::semantic::{NodeId, ScopeFlags, ScopeId, Scoping, Semantic, SymbolId};
use oxc::span::Span;

/// The variables that live in heap cells.
pub struct Analysis {
    /// A variable that changes after its declaration and that a closure sees, or that a
    /// `try` statement or a conditional expression changes. Every other local variable is
    /// a single-assignment Erlang variable with versions.
    pub cells: HashSet<SymbolId>,
    /// Cells declared in the head of a `for (let ...)` loop whose body creates closures:
    /// each iteration copies them, as the per-iteration bindings of JavaScript.
    pub per_iteration: HashSet<SymbolId>,
}

pub fn analyze(program: &Program<'_>, semantic: &Semantic<'_>) -> Analysis {
    let scoping = semantic.scoping();
    let nodes = semantic.nodes();
    let mut cells = HashSet::new();
    for symbol in scoping.symbol_ids() {
        if !scoping.symbol_flags(symbol).is_variable() {
            continue;
        }
        let references: Vec<_> = scoping.get_resolved_references(symbol).collect();
        if !references.iter().any(|reference| reference.is_write()) {
            continue;
        }
        let home = function_scope(scoping, scoping.symbol_scope_id(symbol));
        let declared = scoping.symbol_span(symbol);
        let captured = references
            .iter()
            .any(|reference| function_scope(scoping, reference.scope_id()) != home);
        let guarded = references
            .iter()
            .filter(|reference| reference.is_write())
            .any(|reference| guarded_write(nodes, reference.node_id(), declared));
        if captured || guarded {
            cells.insert(symbol);
        }
    }
    let mut mapped = MappedParameters {
        scoping,
        javascript: !semantic.source_type().is_typescript(),
        found: Vec::new(),
    };
    mapped.visit_program(program);
    cells.extend(mapped.found);
    let mut loops = LoopHeads {
        cells: &cells,
        found: HashSet::new(),
    };
    loops.visit_program(program);
    let per_iteration = loops.found;
    Analysis {
        cells,
        per_iteration,
    }
}

/// The scope of the function that holds `scope`: a function, an arrow, a static block, or
/// the module.
pub fn function_scope(scoping: &Scoping, scope: ScopeId) -> ScopeId {
    scoping
        .scope_ancestors(scope)
        .find(|ancestor| {
            let flags = scoping.scope_flags(*ancestor);
            flags
                .intersects(ScopeFlags::Function | ScopeFlags::Arrow | ScopeFlags::ClassStaticBlock)
                || flags.is_top()
        })
        .unwrap_or(scope)
}

/// Whether a write sits in a `try` statement that does not declare the variable, or in a
/// conditional part of an expression, where a version could not reach the code after it.
fn guarded_write(nodes: &oxc::semantic::AstNodes<'_>, node: NodeId, declared: Span) -> bool {
    let mut in_expression = true;
    for ancestor in nodes.ancestors(node) {
        match ancestor.kind() {
            AstKind::Function(_) | AstKind::ArrowFunctionExpression(_) => return false,
            AstKind::TryStatement(statement) => {
                if !contains(statement.span, declared) {
                    return true;
                }
            }
            AstKind::LogicalExpression(_)
            | AstKind::ConditionalExpression(_)
            | AstKind::ChainExpression(_)
            | AstKind::AssignmentPattern(_)
            | AstKind::FormalParameter(_)
                if in_expression =>
            {
                return true;
            }
            AstKind::ExpressionStatement(_)
            | AstKind::VariableDeclarator(_)
            | AstKind::ReturnStatement(_)
            | AstKind::IfStatement(_)
            | AstKind::ForStatement(_)
            | AstKind::WhileStatement(_)
            | AstKind::DoWhileStatement(_)
            | AstKind::ForOfStatement(_)
            | AstKind::ForInStatement(_)
            | AstKind::SwitchStatement(_)
            | AstKind::ThrowStatement(_) => in_expression = false,
            _ => {}
        }
    }
    false
}

pub fn contains(outer: Span, inner: Span) -> bool {
    outer.start <= inner.start && inner.end <= outer.end
}

/// Finds the cells of `for (let ...)` heads whose loop creates closures.
struct LoopHeads<'c> {
    cells: &'c HashSet<SymbolId>,
    found: HashSet<SymbolId>,
}

impl<'a> Visit<'a> for LoopHeads<'_> {
    fn visit_for_statement(&mut self, it: &ForStatement<'a>) {
        if let Some(ForStatementInit::VariableDeclaration(declaration)) = &it.init
            && declaration.kind != VariableDeclarationKind::Var
        {
            let mut closures = HasClosure(false);
            closures.visit_statement(&it.body);
            if let Some(update) = &it.update {
                closures.visit_expression(update);
            }
            if closures.0 {
                for declarator in &declaration.declarations {
                    for id in declarator.id.get_binding_identifiers() {
                        if let Some(symbol) = id.symbol_id.get()
                            && self.cells.contains(&symbol)
                        {
                            self.found.insert(symbol);
                        }
                    }
                }
            }
        }
        walk::walk_for_statement(self, it);
    }
}

struct HasClosure(bool);

impl<'a> Visit<'a> for HasClosure {
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {
        self.0 = true;
    }
    fn visit_arrow_function_expression(&mut self, _it: &ArrowFunctionExpression<'a>) {
        self.0 = true;
    }
    fn visit_class(&mut self, _it: &Class<'a>) {
        self.0 = true;
    }
}

/// Whether the code holds an `await` or a `yield` outside nested functions: the points
/// where an async function or a generator suspends.
#[derive(Default)]
pub struct Suspends(pub bool);

impl<'a> Visit<'a> for Suspends {
    fn visit_await_expression(&mut self, _it: &AwaitExpression<'a>) {
        self.0 = true;
    }
    fn visit_yield_expression(&mut self, _it: &YieldExpression<'a>) {
        self.0 = true;
    }
    fn visit_for_of_statement(&mut self, it: &ForOfStatement<'a>) {
        if it.r#await {
            self.0 = true;
        }
        walk::walk_for_of_statement(self, it);
    }
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
    fn visit_arrow_function_expression(&mut self, _it: &ArrowFunctionExpression<'a>) {}
    fn visit_class(&mut self, it: &Class<'a>) {
        if let Some(heritage) = &it.heritage {
            self.visit_expression(&heritage.expression);
        }
    }
}

/// The `var` declarations of a function body or a program, outside nested functions and
/// classes: the names that exist from the start of the function.
#[derive(Default)]
pub struct VarDeclarations(pub Vec<SymbolId>);

impl<'a> Visit<'a> for VarDeclarations {
    fn visit_variable_declaration(&mut self, it: &VariableDeclaration<'a>) {
        if it.kind == VariableDeclarationKind::Var {
            for declarator in &it.declarations {
                for id in declarator.id.get_binding_identifiers() {
                    if let Some(symbol) = id.symbol_id.get()
                        && !self.0.contains(&symbol)
                    {
                        self.0.push(symbol);
                    }
                }
            }
        }
        walk::walk_variable_declaration(self, it);
    }
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
    fn visit_arrow_function_expression(&mut self, _it: &ArrowFunctionExpression<'a>) {}
    fn visit_class(&mut self, _it: &Class<'a>) {}
}

/// The parameters of each sloppy function whose `arguments` object maps them (ECMA-262
/// §10.4.4.7): a write to one shows in the other, so they live in heap cells.
struct MappedParameters<'s> {
    scoping: &'s Scoping,
    javascript: bool,
    found: Vec<SymbolId>,
}

impl<'a> Visit<'a> for MappedParameters<'_> {
    fn visit_function(&mut self, it: &Function<'a>, flags: ScopeFlags) {
        let sloppy = self.javascript
            && it
                .scope_id
                .get()
                .is_some_and(|scope| !self.scoping.scope_flags(scope).is_strict_mode());
        if sloppy && is_simple(&it.params) {
            let mut uses = UsesArguments::default();
            if let Some(body) = &it.body {
                uses.visit_function_body(body);
            }
            if uses.0 {
                for param in &it.params.items {
                    if let BindingPattern::BindingIdentifier(id) = &param.pattern
                        && let Some(symbol) = id.symbol_id.get()
                    {
                        self.found.push(symbol);
                    }
                }
            }
        }
        walk::walk_function(self, it, flags);
    }
}

/// Whether a parameter list is simple: names only, without defaults, patterns, or a rest.
pub fn is_simple(params: &FormalParameters<'_>) -> bool {
    params.rest.is_none()
        && params.items.iter().all(|param| {
            param.initializer.is_none()
                && matches!(param.pattern, BindingPattern::BindingIdentifier(_))
        })
}

/// Whether a function reads `this` or `new.target`, in its own code or in an arrow function
/// inside it, which shares them.
#[derive(Default)]
pub struct UsesThis {
    pub this: bool,
    pub new_target: bool,
}

impl<'a> Visit<'a> for UsesThis {
    fn visit_this_expression(&mut self, _it: &ThisExpression) {
        self.this = true;
    }
    fn visit_new_target(&mut self, _it: &NewTarget) {
        self.new_target = true;
    }
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
    fn visit_class(&mut self, _it: &Class<'a>) {}
}

/// Whether a function reads its `arguments` object: in its own code or in an arrow
/// function inside it, which shares it.
#[derive(Default)]
pub struct UsesArguments(pub bool);

impl<'a> Visit<'a> for UsesArguments {
    fn visit_identifier_reference(&mut self, it: &IdentifierReference<'a>) {
        if it.name == "arguments" {
            self.0 = true;
        }
    }
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
    fn visit_class(&mut self, _it: &Class<'a>) {}
}

/// The variables, declared outside `span` or by a `var`, which exists from the start of its
/// function, that the code assigns.
pub struct Assigned<'s> {
    pub scoping: &'s Scoping,
    pub span: Span,
    pub found: Vec<SymbolId>,
}

impl<'a> Visit<'a> for Assigned<'_> {
    fn visit_identifier_reference(&mut self, it: &IdentifierReference<'a>) {
        let Some(reference) = it.reference_id.get() else {
            return;
        };
        let reference = self.scoping.get_reference(reference);
        if reference.is_write()
            && let Some(symbol) = reference.symbol_id()
            && (!contains(self.span, self.scoping.symbol_span(symbol))
                || self
                    .scoping
                    .symbol_flags(symbol)
                    .is_function_scoped_declaration())
            && !self.found.contains(&symbol)
        {
            self.found.push(symbol);
        }
    }
    /// A `var` declaration writes a name that the code after the statement can read.
    fn visit_variable_declaration(&mut self, it: &VariableDeclaration<'a>) {
        if it.kind == VariableDeclarationKind::Var {
            for declarator in &it.declarations {
                for id in declarator.id.get_binding_identifiers() {
                    if let Some(symbol) = id.symbol_id.get()
                        && !self.found.contains(&symbol)
                    {
                        self.found.push(symbol);
                    }
                }
            }
        }
        walk::walk_variable_declaration(self, it);
    }
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
    fn visit_arrow_function_expression(&mut self, _it: &ArrowFunctionExpression<'a>) {}
    fn visit_class(&mut self, _it: &Class<'a>) {}
}

/// Whether control can reach the end of the statement.
pub fn completes_normally(statement: &Statement<'_>) -> bool {
    match statement {
        Statement::ReturnStatement(_)
        | Statement::ThrowStatement(_)
        | Statement::BreakStatement(_)
        | Statement::ContinueStatement(_) => false,
        Statement::BlockStatement(block) => block.body.iter().all(completes_normally),
        Statement::IfStatement(statement) => {
            completes_normally(&statement.consequent)
                || statement.alternate.as_ref().is_none_or(completes_normally)
        }
        _ => true,
    }
}
