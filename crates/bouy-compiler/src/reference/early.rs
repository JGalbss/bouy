//! Bindings that code reads before their declaration runs: a `let`, `const`, or `class`
//! that a hoisted function or earlier code refers to, and a parameter that an earlier
//! default refers to. Each is a cell from the start of its scope, which holds
//! `'$uninitialized'` until the declaration runs, and a read before then throws a
//! `ReferenceError`: the temporal dead zone.

use oxc::ast::ast::{FormalParameters, Statement};
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

    /// Whether a reference to `symbol` comes before `end` or inside a hoisted function.
    fn read_early(&self, symbol: SymbolId, end: u32, hoisted: &[Span]) -> bool {
        let nodes = self.semantic.nodes();
        self.semantic
            .scoping()
            .get_resolved_references(symbol)
            .any(|reference| {
                let span = nodes.get_node(reference.node_id()).span();
                span.start < end || hoisted.iter().any(|function| contains(*function, span))
            })
    }

    fn early_cell(&mut self, symbol: SymbolId) -> Expr {
        let cell = self.fresh("Early");
        self.frame.env.insert(symbol, Local::Cell(cell.clone()));
        self.early.insert(symbol);
        Expr::matches(
            Expr::var(cell),
            Expr::call("bouy_heap", "cell", vec![Expr::atom("$uninitialized")]),
        )
    }

    /// The read of an early binding: its value, or a `ReferenceError` before its
    /// declaration ran.
    pub fn early_read(&mut self, symbol: SymbolId, cell: &str) -> Expr {
        let name = self.semantic.scoping().symbol_name(symbol).to_owned();
        self.bind(Expr::call(
            "bouy_ref_class",
            "initialized",
            vec![cell_get(cell), Expr::js_string(&name)],
        ))
    }
}
