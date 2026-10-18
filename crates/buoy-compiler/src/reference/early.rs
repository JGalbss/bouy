//! Bindings that code reads before their declaration runs: a `let`, `const`, or `class`
//! that a hoisted function or earlier code refers to, and a parameter that an earlier
//! default refers to. Each is a cell from the start of its scope, which holds
//! `'$uninitialized'` until the declaration runs, and a read before then throws a
//! `ReferenceError`: the temporal dead zone.

use oxc::ast::ast::{ForStatementLeft, FormalParameters, Statement, SwitchCase, SwitchStatement};
use oxc::semantic::SymbolId;
use oxc::span::{GetSpan, Span};

use super::analyze::contains;
use super::context::{Local, Lowerer, cell_get};
use crate::erlang::Expr;

impl<'a> Lowerer<'a, '_> {
    /// The cells of the lexical declarations of a block that code reads early: before
    /// the declaration, or in a function declaration, which runs from the block start.
    pub fn early_bindings(&mut self, list: &[&'a Statement<'a>]) -> Vec<Expr> {
        let hoisted: Vec<Span> = list
            .iter()
            .filter(|statement| matches!(statement, Statement::FunctionDeclaration(_)))
            .map(|statement| statement.span())
            .collect();
        let mut declared = Vec::new();
        for statement in list {
            match statement {
                Statement::VariableDeclaration(declaration) if declaration.kind.is_lexical() => {
                    for declarator in &declaration.declarations {
                        for id in declarator.id.get_binding_identifiers() {
                            declared.push((id.symbol_id.get(), declarator.span.end));
                        }
                    }
                }
                Statement::ClassDeclaration(class) => {
                    if let Some(id) = &class.id {
                        declared.push((id.symbol_id.get(), class.body.span.start));
                    }
                }
                _ => {}
            }
        }
        let mut code = Vec::new();
        for (symbol, end) in declared {
            let Some(symbol) = symbol else {
                continue;
            };
            if !self.tops.contains_key(&symbol)
                && !self.frame.env.contains_key(&symbol)
                && self.read_early(symbol, end, &hoisted)
            {
                code.push(self.early_cell(symbol));
            }
        }
        code
    }

    /// The lexical declarations of a `switch`, whose cases share one scope: a cell for
    /// each that code reads outside its case or before its declaration.
    pub fn early_case_bindings(&mut self, statement: &'a SwitchStatement<'a>) -> Vec<Expr> {
        let mut code = Vec::new();
        for case in &statement.cases {
            let Some(span) = case_span(case) else {
                continue;
            };
            for item in &case.consequent {
                let Statement::VariableDeclaration(declaration) = item else {
                    continue;
                };
                if !declaration.kind.is_lexical() {
                    continue;
                }
                for declarator in &declaration.declarations {
                    for id in declarator.id.get_binding_identifiers() {
                        let Some(symbol) = id.symbol_id.get() else {
                            continue;
                        };
                        let nodes = self.semantic.nodes();
                        let early = self.semantic.scoping().get_resolved_references(symbol).any(
                            |reference| {
                                let at = nodes.get_node(reference.node_id()).span();
                                !contains(span, at) || at.start < declarator.span.end
                            },
                        );
                        if early && !self.frame.env.contains_key(&symbol) {
                            code.push(self.early_cell(symbol));
                        }
                    }
                }
            }
        }
        code
    }

    /// The cells of the parameters that a default before them reads.
    pub fn early_params(&mut self, params: &'a FormalParameters<'a>) -> Vec<Expr> {
        let mut code = Vec::new();
        for param in &params.items {
            for id in param.pattern.get_binding_identifiers() {
                if let Some(symbol) = id.symbol_id.get()
                    && !self.frame.env.contains_key(&symbol)
                    && self.read_early(symbol, param.span.end, &[])
                {
                    code.push(self.early_cell(symbol));
                }
            }
        }
        code
    }

    /// The bindings of a `for...of` or `for...in` head that its right side reads: a
    /// separate scope whose bindings are never initialized. Returns what to restore.
    pub fn head_bindings(
        &mut self,
        left: &'a ForStatementLeft<'a>,
        right: Span,
    ) -> Vec<(SymbolId, Option<Local>)> {
        let ForStatementLeft::VariableDeclaration(declaration) = left else {
            return Vec::new();
        };
        if !declaration.kind.is_lexical() {
            return Vec::new();
        }
        let nodes = self.semantic.nodes();
        let mut saved = Vec::new();
        for declarator in &declaration.declarations {
            for id in declarator.id.get_binding_identifiers() {
                let Some(symbol) = id.symbol_id.get() else {
                    continue;
                };
                let read = self
                    .semantic
                    .scoping()
                    .get_resolved_references(symbol)
                    .any(|reference| contains(right, nodes.get_node(reference.node_id()).span()));
                if read {
                    let previous = self.frame.env.get(&symbol).cloned();
                    let cell = self.early_cell(symbol);
                    self.pre.push(cell);
                    saved.push((symbol, previous));
                }
            }
        }
        saved
    }

    /// Ends the scope of `head_bindings`: each iteration declares its own bindings.
    pub fn end_head_bindings(&mut self, saved: Vec<(SymbolId, Option<Local>)>) {
        for (symbol, previous) in saved {
            self.early.remove(&symbol);
            match previous {
                Some(local) => self.frame.env.insert(symbol, local),
                None => self.frame.env.remove(&symbol),
            };
        }
    }

    /// The inner binding of a class name that its `extends` clause refers to: a cell of its
    /// own, apart from the binding outside the class, which the class initializes once it
    /// exists (`ClassDefinitionEvaluation`, ECMA-262 §15.7.14).
    pub fn heritage_binding(&mut self, symbol: SymbolId, heritage: Span) -> Option<String> {
        if !self.reads_within(symbol, &[heritage]) {
            return None;
        }
        self.class_binding_cell(symbol)
    }

    /// A cell for the inner binding of a class name, in its dead zone until the class
    /// initializes it.
    pub fn class_binding_cell(&mut self, symbol: SymbolId) -> Option<String> {
        let cell = self.early_cell(symbol);
        self.pre.push(cell);
        match self.frame.env.get(&symbol) {
            Some(Local::Cell(cell)) => Some(cell.clone()),
            _ => None,
        }
    }

    /// Whether a reference to `symbol` lies in one of `spans`.
    pub fn reads_within(&self, symbol: SymbolId, spans: &[Span]) -> bool {
        let nodes = self.semantic.nodes();
        self.semantic
            .scoping()
            .get_resolved_references(symbol)
            .map(|reference| nodes.get_node(reference.node_id()).span())
            .any(|read| spans.iter().any(|span| contains(*span, read)))
    }

    /// Whether a reference to `symbol` comes before `end` or inside a hoisted function.
    /// Whether code may read `symbol` before its declaration ends at `end`: a reference, or
    /// a direct eval in its scope, before it or in a hoisted function.
    fn read_early(&self, symbol: SymbolId, end: u32, hoisted: &[Span]) -> bool {
        let nodes = self.semantic.nodes();
        let scoping = self.semantic.scoping();
        let early = |span: Span| {
            span.start < end || hoisted.iter().any(|function| contains(*function, span))
        };
        let scope = nodes
            .get_node(scoping.get_node_id(scoping.symbol_scope_id(symbol)))
            .span();
        scoping
            .get_resolved_references(symbol)
            .any(|reference| early(nodes.get_node(reference.node_id()).span()))
            || scoping
                .root_unresolved_references()
                .get("eval")
                .into_iter()
                .flatten()
                .map(|reference| {
                    nodes
                        .get_node(scoping.get_reference(*reference).node_id())
                        .span()
                })
                .any(|span| contains(scope, span) && early(span))
    }

    fn early_cell(&mut self, symbol: SymbolId) -> Expr {
        let cell = self.fresh("Early");
        self.frame.env.insert(symbol, Local::Cell(cell.clone()));
        self.early.insert(symbol);
        Expr::matches(
            Expr::var(cell),
            Expr::call("buoy_heap", "cell", vec![Expr::atom("$uninitialized")]),
        )
    }

    /// The read of an early binding: its value, or a `ReferenceError` before its
    /// declaration ran.
    pub fn early_read(&mut self, symbol: SymbolId, cell: &str) -> Expr {
        let read = self.initialized(symbol, cell);
        self.bind(read)
    }

    /// The value of the early binding `symbol` in `cell`, which throws a `ReferenceError`
    /// before its declaration ran.
    pub fn initialized(&self, symbol: SymbolId, cell: &str) -> Expr {
        let name = self.semantic.scoping().symbol_name(symbol);
        Expr::call(
            "buoy_ref_class",
            "initialized",
            vec![cell_get(cell), Expr::js_string(name)],
        )
    }
}

/// The span of the statements of a case.
fn case_span(case: &SwitchCase<'_>) -> Option<Span> {
    let first = case.consequent.first()?;
    let last = case.consequent.last()?;
    Some(Span::new(first.span().start, last.span().end))
}
