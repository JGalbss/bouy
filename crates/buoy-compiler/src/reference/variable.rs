//! Variables: reads, writes, and declarations of locals (versions or heap cells) and of
//! module-level names.

use oxc::ast::ast::IdentifierReference;
use oxc::semantic::SymbolId;
use oxc::span::Span;

use super::context::{Local, Lowerer, Top, capitalize, cell_get, cell_set};
use crate::erlang::Expr;

impl<'a> Lowerer<'a, '_> {
    pub fn identifier(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        let objects = self.with_objects(ident);
        if !objects.is_empty() {
            return self.with_read(ident, &objects);
        }
        self.identifier_plain(ident)
    }

    /// A read of `ident` without the `with` statements around it.
    pub fn identifier_plain(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        match self.symbol_of(ident.reference_id.get()) {
            Some(symbol) => self.read_symbol(symbol, ident.span),
            None => match ident.name.as_str() {
                "undefined" => Expr::undefined(),
                "NaN" => Expr::atom("NaN"),
                "Infinity" => Expr::atom("Infinity"),
                "arguments" if self.frame.arguments.is_some() => self.arguments_value(),
                name if self.eval_binding(name).is_some() => self.eval_binding_read(name),
                name => self.bind(Expr::call(
                    "buoy_ref",
                    "global",
                    vec![Expr::js_string(name)],
                )),
            },
        }
    }

    /// `new.target`: the variable of the function or of the class constructor, else
    /// undefined.
    pub fn new_target_expr(&self) -> Expr {
        match &self.frame.new_target {
            Some(new_target) => Expr::var(new_target.clone()),
            None => Expr::undefined(),
        }
    }

    pub fn read_symbol(&mut self, symbol: SymbolId, span: Span) -> Expr {
        if let Some(cell) = self.block_cell(symbol, span) {
            return self.bind(cell_get(&cell));
        }
        if let Some(local) = self.frame.env.get(&symbol) {
            return match local.clone() {
                Local::Var(name) => Expr::var(name),
                Local::Cell(name) if self.early.contains(&symbol) => self.early_read(symbol, &name),
                Local::Cell(name) => self.bind(cell_get(&name)),
            };
        }
        match self.tops.get(&symbol).cloned() {
            Some(Top::Function { name, length, form }) => self.static_function(&name, length, form),
            // A class reads as uninitialized until its declaration runs.
            Some(Top::Class(name)) => {
                let read = self.declared_class(&name);
                self.bind(read)
            }
            Some(Top::Var(name)) => self.bind(Expr::local_call(&format!("$get_{name}"), vec![])),
            Some(Top::Global(name)) => self.bind(Expr::call(
                "buoy_ref",
                "global",
                vec![Expr::js_string(&name)],
            )),
            Some(Top::Literal(value)) => value,
            Some(Top::Buoy(_)) => self.unsupported(span, "a function of \"buoy\" used as a value"),
            Some(Top::Import(binding)) => {
                let read = self.linking.read(&binding);
                self.bind(read)
            }
            None if self.is_local_binding(symbol) => {
                // A read before the declaration ran: the temporal dead zone.
                let binding = self.semantic.scoping().symbol_name(symbol).to_owned();
                self.bind(Expr::call(
                    "buoy_ref",
                    "tdz_error",
                    vec![Expr::js_string(&binding)],
                ))
            }
            None => self.unsupported(
                span,
                "a reference to a local variable before its declaration",
            ),
        }
    }

    /// Stores a computed value in the binding of `ident`: a local, a module variable, or a
    /// global.
    pub fn assign_name_value(&mut self, ident: &'a IdentifierReference<'a>, value: Expr) -> Expr {
        match self.symbol_of(ident.reference_id.get()) {
            Some(symbol) => self.assign_symbol(symbol, value, ident.span),
            None => self.set_global(ident.name.as_str(), value),
        }
    }

    /// The value of the `arguments` binding of the function.
    pub fn arguments_value(&mut self) -> Expr {
        match self.frame.arguments.clone() {
            Some(Local::Var(arguments)) => Expr::var(arguments),
            Some(Local::Cell(cell)) => self.bind(cell_get(&cell)),
            None => Expr::undefined(),
        }
    }

    /// The value of a name that no scope of the code declares: the `arguments` of the
    /// function, a binding of the caller of a direct eval, else a global.
    pub fn identifier_read(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        if ident.name == "arguments" && self.frame.arguments.is_some() {
            return self.arguments_value();
        }
        if self.eval_binding(ident.name.as_str()).is_some() {
            return self.eval_binding_read(ident.name.as_str());
        }
        self.bind(Expr::call(
            "buoy_ref",
            "global",
            vec![Expr::js_string(ident.name.as_str())],
        ))
    }

    /// The read of a binding of the caller of a direct eval, which may still be in its
    /// dead zone.
    fn eval_binding_read(&mut self, name: &str) -> Expr {
        let cell = self.eval_binding(name).unwrap_or_default();
        self.bind(Expr::call(
            "buoy_ref_class",
            "initialized",
            vec![cell_get(&cell), Expr::js_string(name)],
        ))
    }

    /// Whether `symbol` is a `let`, `const`, class, or parameter: a binding whose read
    /// before its declaration is a `ReferenceError`.
    fn is_local_binding(&self, symbol: SymbolId) -> bool {
        let flags = self.semantic.scoping().symbol_flags(symbol);
        flags.is_block_scoped()
            || flags.contains(oxc::semantic::SymbolFlags::FunctionScopedVariable)
    }

    /// Stores `value` in the variable `symbol` and returns the stored value.
    pub fn assign_symbol(&mut self, symbol: SymbolId, value: Expr, span: Span) -> Expr {
        // A write before the declaration ran, such as from a hoisted function, is in the
        // temporal dead zone (SetMutableBinding, ECMA-262 §9.1.1.1.5).
        if self.early.contains(&symbol)
            && let Some(Local::Cell(cell)) = self.frame.env.get(&symbol).cloned()
        {
            let value = self.bind(value);
            let check = self.initialized(symbol, &cell);
            self.pre.push(check);
            return self.assign_initialized(symbol, value, span);
        }
        self.assign_initialized(symbol, value, span)
    }

    fn assign_initialized(&mut self, symbol: SymbolId, value: Expr, span: Span) -> Expr {
        if let Some(cell) = self.block_cell(symbol, span) {
            let value = self.bind(value);
            self.pre.push(cell_set(&cell, value.clone()));
            return value;
        }
        // The name of a function expression is immutable: sloppy code ignores a write to
        // it (ECMA-262 §9.1.1.1.5).
        if self.class_bindings.contains(&symbol) && self.frame.sloppy {
            return self.bind(value);
        }
        if self.class_bindings.contains(&symbol)
            || self
                .semantic
                .scoping()
                .symbol_flags(symbol)
                .is_const_variable()
        {
            // A `const`, and the name of a class inside the class, are constants: the
            // value runs, then a TypeError.
            let value = self.bind(value);
            self.pre.push(Expr::call("buoy_ref", "const_error", vec![]));
            return value;
        }
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
                    "buoy_ref_class",
                    "set_module",
                    vec![key, value.clone(), Expr::js_string(&name)],
                ));
                value
            }
            Some(Top::Global(name)) => self.set_global(&name, value),
            // A module-level class name holds the value that replaces the class in this
            // realm.
            Some(Top::Class(name)) => {
                let value = self.bind(value);
                let key = self.class_key(&name);
                self.pre
                    .push(Expr::call("erlang", "put", vec![key, value.clone()]));
                value
            }
            Some(Top::Import(_)) => {
                let _ = self.bind(value);
                self.bind(Expr::call(
                    "buoy_ref",
                    "type_error",
                    vec![Expr::js_string("Assignment to constant variable.")],
                ))
            }
            _ => self.unsupported(span, "an assignment to this name"),
        }
    }

    /// Declares `symbol` with `value`: a version, a cell, or a module variable.
    pub fn declare_symbol(&mut self, symbol: SymbolId, value: Expr) {
        // A catch parameter that shares the symbol of a global or module `var` shadows it
        // inside its clause, also for the writes of a `var` there (Annex B.3.4).
        if self.tops.contains_key(&symbol)
            && let Some(Local::Cell(cell)) = self.frame.env.get(&symbol).cloned()
        {
            let value = self.bind(value);
            self.pre.push(cell_set(&cell, value));
            return;
        }
        if self.early.contains(&symbol)
            && let Some(Local::Cell(cell)) = self.frame.env.get(&symbol).cloned()
        {
            let value = self.bind(value);
            self.pre.push(cell_set(&cell, value));
            return;
        }
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
            Some(Top::Global(name)) => {
                self.set_global(&name, value);
                return;
            }
            Some(Top::Literal(_)) => return,
            _ => {}
        }
        // A `var` declaration after the start of the function writes the cell that the
        // start of the function made, which closures may hold.
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
        if self.analysis.cells.contains(&symbol) {
            let cell = self.fresh("Cell");
            self.pre.push(Expr::matches(
                Expr::var(cell.clone()),
                Expr::call("buoy_heap", "cell", vec![value]),
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
