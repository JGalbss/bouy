//! Function declarations in the blocks of sloppy code (ECMA-262 Annex B.3.2 to B.3.4).
//!
//! In sloppy code a plain function declared in a block, in a `case` clause, or as the arm
//! of an `if` binds its name in that block, and also has a `var` binding in the enclosing
//! function, which the declaration sets when it runs, unless a `var` of the name would be
//! an early error there or the name is a parameter or `arguments`.
//!
//! oxc gives one symbol to the block binding and to a binding of the var scope when it
//! moved the block function there, or when another declaration shares the name, such as
//! the `let` around the arm of an `if`. Such a block function gets a cell of its own,
//! which its block sets when it begins: a reference inside the block reads that cell, and
//! a reference outside reads the other binding. When oxc moved the symbol and Annex B does
//! not apply, a reference outside the block resolves as if the block function did not
//! exist.

use oxc::ast::ast::{ArrowFunctionExpression, Class, Function, IfStatement, Statement};
use oxc::ast_visit::{Visit, walk};
use oxc::semantic::{ReferenceId, ScopeFlags, ScopeId, SymbolId};
use oxc::span::{GetSpan, Span};

use super::context::{Local, Lowerer, Top, cell_get, cell_set};
use crate::erlang::Expr;

/// A function declaration of a sloppy block.
#[derive(Debug, Clone)]
pub struct BlockFunction {
    pub symbol: SymbolId,
    /// The block whose binding the declaration makes: the block, the `switch`, or the
    /// declaration itself as the arm of an `if`.
    pub block: Span,
    pub declaration: Span,
    /// Whether the symbol stands for more than the block binding, so that the block
    /// binding is a cell of its own.
    pub separate: bool,
    /// Whether a reference outside the block resolves around the var scope.
    pub hidden: bool,
    /// The var binding that the declaration sets when it runs, when Annex B applies.
    pub target: Option<SymbolId>,
    /// The cell of a separate block binding, from the start of the block.
    pub cell: Option<String>,
    /// Whether the target is a global that the code may not have been able to declare,
    /// which the declaration then leaves alone (`buoy_ref_realm:set_block_function/3`).
    pub checked: bool,
}

impl<'a> Lowerer<'a, '_> {
    /// Finds the block functions of the code of a function, or of the top level of a
    /// script or an eval, whose parameters are `parameters`.
    pub fn find_block_functions<'s>(
        &mut self,
        statements: impl IntoIterator<Item = &'s Statement<'a>>,
        parameters: &[String],
    ) where
        'a: 's,
    {
        if !self.frame.sloppy {
            return;
        }
        let mut found = Declarations::default();
        for statement in statements {
            found.visit_statement(statement);
        }
        let found: Vec<BlockFunction> = found
            .found
            .iter()
            .filter_map(|declaration| self.block_function(declaration, &found.found, parameters))
            .collect();
        self.block_functions.extend(found);
    }

    fn block_function(
        &self,
        declaration: &Declaration,
        others: &[Declaration],
        parameters: &[String],
    ) -> Option<BlockFunction> {
        let symbol = declaration.symbol;
        let scoping = self.semantic.scoping();
        let enclosing = scoping.scope_parent_id(declaration.scope)?;
        let var_scope = scoping
            .scope_ancestors(enclosing)
            .find(|scope| scoping.scope_flags(*scope).is_var())?;
        // A labelled function at the top of the code is an ordinary declaration there.
        if enclosing == var_scope && !declaration.if_arm {
            return None;
        }
        let block = if declaration.if_arm {
            declaration.span
        } else {
            self.semantic
                .nodes()
                .get_node(scoping.get_node_id(enclosing))
                .kind()
                .span()
        };
        let declarations = scoping.symbol_declarations(symbol).count();
        let moved = scoping.symbol_scope_id(symbol) == var_scope && enclosing != var_scope;
        let separate = moved || declarations > 1 || declaration.if_arm;
        let name = scoping.symbol_name(symbol);
        let first = if declaration.if_arm {
            Some(enclosing)
        } else {
            scoping.scope_parent_id(enclosing)
        };
        let applies = name != "arguments"
            && !parameters.iter().any(|parameter| parameter == name)
            && !self.var_conflicts(declaration, others, name, first, var_scope);
        let target = if !applies {
            None
        } else if scoping.symbol_scope_id(symbol) == var_scope {
            Some(symbol)
        } else {
            scoping.get_binding(var_scope, name.into())
        };
        Some(BlockFunction {
            symbol,
            block,
            declaration: declaration.span,
            separate,
            // oxc moved the symbol out of its block, also with a `let` of the block that
            // shares it: outside the block it does not exist.
            hidden: target.is_none()
                && moved
                && (declarations == 1 || scoping.symbol_flags(symbol).is_block_scoped()),
            target,
            cell: None,
            checked: false,
        })
    }

    /// Whether `var name` in the block would be an early error: a lexical binding of the
    /// name in a scope from `first` to the var scope. A simple catch parameter does not
    /// conflict (Annex B.3.4), and neither do a `var` or a function of the var scope.
    fn var_conflicts(
        &self,
        declaration: &Declaration,
        others: &[Declaration],
        name: &str,
        first: Option<ScopeId>,
        var_scope: ScopeId,
    ) -> bool {
        let symbol = declaration.symbol;
        let scoping = self.semantic.scoping();
        // A function of an enclosing block is lexical there, also when oxc moved its
        // symbol to the var scope.
        let block_function_in = |scope: ScopeId| {
            others.iter().any(|other| {
                other.span != declaration.span
                    && !other.if_arm
                    && scoping.scope_parent_id(other.scope) == Some(scope)
                    && scoping.symbol_name(other.symbol) == name
            })
        };
        let mut scope = first;
        while let Some(current) = scope {
            if current != var_scope && block_function_in(current) {
                return true;
            }
            if let Some(found) = scoping.get_binding(current, name.into()) {
                let flags = scoping.symbol_flags(found);
                // A destructured catch parameter is block scoped; a simple one is not.
                let lexical = flags.is_block_scoped()
                    || (flags.is_function() && current != var_scope && found != symbol);
                if lexical {
                    return true;
                }
            }
            if current == var_scope {
                break;
            }
            scope = scoping.scope_parent_id(current);
        }
        false
    }

    /// The block cell that a reference to `symbol` at `span` reads: the innermost block of
    /// a separate block binding that holds the reference.
    pub fn block_cell(&self, symbol: SymbolId, span: Span) -> Option<String> {
        self.block_binding(symbol, span)
            .and_then(|function| function.cell.clone())
    }

    /// The separate block binding of `symbol` whose block holds `span`, the innermost.
    pub fn block_binding(&self, symbol: SymbolId, span: Span) -> Option<&BlockFunction> {
        self.block_functions
            .iter()
            .filter(|function| {
                function.symbol == symbol
                    && function.separate
                    && function.block.start <= span.start
                    && span.end <= function.block.end
            })
            .min_by_key(|function| function.block.size())
    }

    /// Whether `reference` to `symbol` is outside the blocks of a hidden block function, so
    /// that it resolves around the var scope (`outer_binding`).
    pub fn is_hidden_reference(&self, symbol: SymbolId, reference: ReferenceId) -> bool {
        let mut functions = self
            .block_functions
            .iter()
            .filter(|function| function.symbol == symbol)
            .peekable();
        if functions.peek().is_none() {
            return false;
        }
        let scoping = self.semantic.scoping();
        let node = scoping.get_reference(reference).node_id();
        let span = self.semantic.nodes().get_node(node).kind().span();
        functions.all(|function| {
            let inside = function.block.start <= span.start && span.end <= function.block.end;
            function.hidden && !inside
        })
    }

    /// The binding of the name of `symbol` around its var scope, or none for a global.
    pub fn outer_binding(&self, symbol: SymbolId) -> Option<SymbolId> {
        let scoping = self.semantic.scoping();
        let name = scoping.symbol_name(symbol);
        scoping
            .scope_parent_id(scoping.symbol_scope_id(symbol))
            .and_then(|parent| scoping.find_binding(parent, name.into()))
    }

    /// Whether `function` is a block function whose binding is a cell of its block.
    pub fn is_block_function(&self, function: &Function<'a>) -> bool {
        self.block_functions.iter().any(|block_function| {
            block_function.declaration == function.span && block_function.separate
        })
    }

    /// Whether the block of `function` made its cell already.
    pub fn has_block_cell(&self, function: &Function<'a>) -> bool {
        self.block_functions.iter().any(|block_function| {
            block_function.declaration == function.span && block_function.cell.is_some()
        })
    }

    /// The block cell of the separate block function `function`, which holds undefined
    /// until the block sets it, and the code that makes it.
    /// A second declaration of the same name in the block shares the cell of the first
    /// (`shared`), and the block sets it to each in turn, so the last one wins (Annex
    /// B.3.2.4), and no code makes a cell.
    pub fn block_function_cell(
        &mut self,
        function: &Function<'a>,
        shared: Option<String>,
    ) -> (String, Vec<Expr>) {
        let (cell, code) = match shared {
            Some(cell) => (cell, Vec::new()),
            None => {
                let cell = self.fresh("Block");
                let code = vec![Expr::matches(
                    Expr::var(cell.clone()),
                    Expr::call("buoy_heap", "cell", vec![Expr::undefined()]),
                )];
                (cell, code)
            }
        };
        for block_function in &mut self.block_functions {
            if block_function.declaration == function.span {
                block_function.cell = Some(cell.clone());
            }
        }
        (cell, code)
    }

    /// Drops the var binding of each block function of eval code whose name a `let`,
    /// `const`, or class of the caller binds between the eval and its function: the
    /// declaration does not reach past it (Annex B.3.3.3, bindingExists).
    pub fn shadow_block_functions(&mut self) {
        let scoping = self.semantic.scoping();
        let lexical = self.eval_context.lexical.clone();
        for function in &mut self.block_functions {
            let name = scoping.symbol_name(function.symbol);
            if lexical.iter().any(|shadowed| shadowed == name) {
                function.target = None;
                function.hidden =
                    function.separate && scoping.symbol_declarations(function.symbol).count() == 1;
            }
        }
    }

    /// Marks the block functions whose target is `target` as checked: a global that
    /// `buoy_ref_realm:declare_block_functions/3` may not have declared.
    pub fn check_block_function_target(&mut self, target: SymbolId) {
        for function in &mut self.block_functions {
            if function.target == Some(target) {
                function.checked = true;
            }
        }
    }

    /// The var bindings that the block functions set when they run.
    pub fn block_function_targets(&self) -> Vec<SymbolId> {
        let mut targets = Vec::new();
        for target in self
            .block_functions
            .iter()
            .filter_map(|function| function.target)
        {
            if !targets.contains(&target) {
                targets.push(target);
            }
        }
        targets
    }

    /// The names of the block functions of a script's top-level code that Annex B.3.3.2
    /// hoists, each a property of the global object: a function that the code never
    /// assigns stops being a static function, because the declaration writes it.
    pub fn script_block_functions(&mut self) -> Vec<String> {
        for function in &mut self.block_functions {
            function.checked = function.target.is_some();
        }
        let scoping = self.semantic.scoping();
        let mut names = Vec::new();
        for target in self
            .block_functions
            .iter()
            .filter_map(|function| function.target)
        {
            let name = scoping.symbol_name(target).to_owned();
            if !matches!(self.tops.get(&target), Some(Top::Global(_))) {
                self.tops.insert(target, Top::Global(name.clone()));
            }
            if !names.contains(&name) {
                names.push(name);
            }
        }
        names
    }

    /// The code of a block function declaration when it runs: the var binding takes the
    /// value of the block binding (Annex B.3.3.1).
    pub fn block_function_evaluation(&mut self, function: &Function<'a>) -> Vec<Expr> {
        let Some(block_function) = self
            .block_functions
            .iter()
            .find(|block_function| block_function.declaration == function.span)
            .cloned()
        else {
            return Vec::new();
        };
        let Some(target) = block_function.target else {
            return Vec::new();
        };
        let value = match &block_function.cell {
            Some(cell) => cell_get(cell),
            None => self.current(block_function.symbol),
        };
        let saved = std::mem::take(&mut self.pre);
        let value = self.bind(value);
        // A property of the global object, which the declaration sets only when the script
        // or the eval could declare it (Annex B.3.3.2 and B.3.3.3). A variable of the
        // function of a direct eval is set as eval code sets its `var`.
        if let Some(Top::Global(name)) = self.tops.get(&target).cloned()
            && block_function.checked
        {
            self.pre.push(Expr::call(
                "buoy_ref_realm",
                "set_block_function",
                vec![
                    Expr::atom(self.module.clone()),
                    Expr::js_string(&name),
                    value,
                ],
            ));
            return std::mem::replace(&mut self.pre, saved);
        }
        // A global or a variable of eval code is the var binding, also inside a catch
        // clause whose parameter shadows it there.
        if let Some(Top::Global(name)) = self.tops.get(&target).cloned() {
            let _ = self.set_global(&name, value);
            return std::mem::replace(&mut self.pre, saved);
        }
        match self.frame.env.get(&target).cloned() {
            Some(Local::Cell(cell)) => self.pre.push(cell_set(&cell, value)),
            // A span outside every block, so that the write reaches the var binding.
            _ => {
                let _ = self.assign_symbol(target, value, Span::new(u32::MAX, u32::MAX));
            }
        }
        std::mem::replace(&mut self.pre, saved)
    }
}

/// A plain function declaration in a block: its symbol, its own scope, its span, and
/// whether it is the arm of an `if`.
struct Declaration {
    symbol: SymbolId,
    scope: ScopeId,
    span: Span,
    if_arm: bool,
}

/// The plain function declarations inside the blocks of a body, outside nested functions
/// and classes.
#[derive(Default)]
struct Declarations {
    depth: usize,
    found: Vec<Declaration>,
}

impl Declarations {
    fn record(&mut self, function: &Function<'_>, if_arm: bool) {
        if function.r#async || function.generator || function.body.is_none() {
            return;
        }
        if let (Some(symbol), Some(scope)) = (
            function.id.as_ref().and_then(|id| id.symbol_id.get()),
            function.scope_id.get(),
        ) {
            self.found.push(Declaration {
                symbol,
                scope,
                span: function.span,
                if_arm,
            });
        }
    }

    fn arm(&mut self, statement: &Statement<'_>) {
        match statement {
            Statement::FunctionDeclaration(function) => self.record(function, true),
            other => self.visit_statement(other),
        }
    }
}

impl<'a> Visit<'a> for Declarations {
    fn visit_statement(&mut self, it: &Statement<'a>) {
        if let Statement::FunctionDeclaration(function) = it {
            if self.depth > 0 {
                self.record(function, false);
            }
            return;
        }
        self.depth += 1;
        walk::walk_statement(self, it);
        self.depth -= 1;
    }
    fn visit_if_statement(&mut self, it: &IfStatement<'a>) {
        self.visit_expression(&it.test);
        self.arm(&it.consequent);
        if let Some(alternate) = &it.alternate {
            self.arm(alternate);
        }
    }
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
    fn visit_arrow_function_expression(&mut self, _it: &ArrowFunctionExpression<'a>) {}
    fn visit_class(&mut self, _it: &Class<'a>) {}
}
