//! Variables: reads, writes, and declarations of locals (versions or heap cells) and of
//! module-level names.

use oxc::ast::ast::IdentifierReference;
use oxc::semantic::SymbolId;
use oxc::span::Span;

use super::context::{Local, Lowerer, Top, capitalize, cell_get, cell_set};
use crate::erlang::Expr;

impl<'a> Lowerer<'a, '_> {
    pub fn identifier(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        match self.symbol_of(ident.reference_id.get()) {
            Some(symbol) => self.read_symbol(symbol, ident.span),
            None => match ident.name.as_str() {
                "undefined" => Expr::undefined(),
                "NaN" => Expr::atom("NaN"),
                "Infinity" => Expr::atom("Infinity"),
                "arguments" if self.frame.arguments.is_some() => {
                    Expr::var(self.frame.arguments.clone().unwrap_or_default())
                }
                name => self.bind(Expr::call(
                    "bouy_ref",
                    "global",
                    vec![Expr::js_string(name)],
                )),
            },
        }
    }

    pub fn read_symbol(&mut self, symbol: SymbolId, span: Span) -> Expr {
        if let Some(local) = self.frame.env.get(&symbol) {
            return match local.clone() {
                Local::Var(name) => Expr::var(name),
                Local::Cell(name) => self.bind(cell_get(&name)),
            };
        }
        match self.tops.get(&symbol).cloned() {
            Some(Top::Function { name, length, form }) => self.static_function(&name, length, form),
            Some(Top::Class(name)) => {
                self.bind(Expr::local_call("$class", vec![Expr::binary(name)]))
            }
            Some(Top::Var(name)) => self.bind(Expr::local_call(&format!("$get_{name}"), vec![])),
            Some(Top::Literal(value)) => value,
            Some(Top::Bouy(_)) => self.unsupported(span, "a function of \"bouy\" used as a value"),
            None => self.unsupported(
                span,
                "a reference to a local variable before its declaration",
            ),
        }
    }

    /// Stores `value` in the variable `symbol` and returns the stored value.
    pub fn assign_symbol(&mut self, symbol: SymbolId, value: Expr, span: Span) -> Expr {
        if let Some(local) = self.frame.env.get(&symbol).cloned() {
            return match local {
                Local::Var(_) => {
                    let name = self.symbol_var(symbol);
                    self.pre.push(Expr::matches(Expr::var(name.clone()), value));
                    self.frame.env.insert(symbol, Local::Var(name.clone()));
                    Expr::var(name)
                }
                Local::Cell(cell) => self.bind(cell_set(&cell, value)),
            };
        }
        match self.tops.get(&symbol).cloned() {
            Some(Top::Var(name)) => {
                let value = self.bind(value);
                let key = self.var_key(&name);
                self.pre.push(Expr::call(
                    "erlang",
                    "put",
                    vec![key, Expr::tagged("v", value.clone())],
                ));
                value
            }
            _ => self.unsupported(span, "an assignment to this name"),
        }
    }

    /// Declares `symbol` with `value`: a version, a cell, or a module variable.
    pub fn declare_symbol(&mut self, symbol: SymbolId, value: Expr) {
        match self.tops.get(&symbol).cloned() {
            Some(Top::Var(name)) => {
                let value = self.bind(value);
                let key = self.var_key(&name);
                self.pre.push(Expr::call(
                    "erlang",
                    "put",
                    vec![key, Expr::tagged("v", value)],
                ));
                return;
            }
            Some(Top::Literal(_)) => return,
            _ => {}
        }
        if self.analysis.cells.contains(&symbol) {
            // A `var` declaration after the start of the function writes the cell that
            // the start of the function made, which closures may hold.
            if let Some(Local::Cell(cell)) = self.frame.env.get(&symbol).cloned()
                && self
                    .semantic
                    .scoping()
                    .symbol_flags(symbol)
                    .is_function_scoped_declaration()
            {
                let value = self.bind(value);
                self.pre.push(cell_set(&cell, value));
                return;
            }
            let cell = self.fresh("Cell");
            self.pre.push(Expr::matches(
                Expr::var(cell.clone()),
                Expr::call("bouy_heap", "cell", vec![value]),
            ));
            self.frame.env.insert(symbol, Local::Cell(cell));
            return;
        }
        if let Expr::Var(name) = &value {
            self.frame.env.insert(symbol, Local::Var(name.clone()));
            return;
        }
        let name = self.symbol_var(symbol);
        self.pre.push(Expr::matches(Expr::var(name.clone()), value));
        self.frame.env.insert(symbol, Local::Var(name));
    }

    pub fn symbol_var(&mut self, symbol: SymbolId) -> String {
        let name = self.semantic.scoping().symbol_name(symbol).to_owned();
        self.fresh(&capitalize(&name))
    }
}
