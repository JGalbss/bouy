//! Calls: argument lists with spread, method calls, calls of module functions and of
//! the functions of "buoy", and `new`.

use oxc::ast::ast::{
    Argument, CallExpression, Expression, IdentifierReference, MemberExpression, NewExpression,
};

use oxc::semantic::ScopeFlags;
use oxc::span::GetSpan;

use super::analyze::contains;
use super::context::{Local, Lowerer, Top, binding_name, cell_get};
use super::expr::strip;
use super::member::{MemberKey, super_parts};
use crate::erlang::{Clause, Expr};

impl<'a> Lowerer<'a, '_> {
    pub fn args(&mut self, arguments: &'a [Argument<'a>]) -> Expr {
        let spread = arguments
            .iter()
            .any(|argument| matches!(argument, Argument::SpreadElement(_)));
        if !spread {
            let items = arguments
                .iter()
                .map(|argument| match argument.as_expression() {
                    Some(expression) => self.expr(expression),
                    None => Expr::undefined(),
                })
                .collect();
            return Expr::List(items);
        }
        let parts = arguments
            .iter()
            .map(|argument| match argument {
                Argument::SpreadElement(spread) => {
                    let value = self.expr(&spread.argument);
                    self.bind(Expr::call(
                        "buoy_ref_iterator",
                        &self.iteration("to_list"),
                        vec![value],
                    ))
                }
                other => match other.as_expression() {
                    Some(expression) => Expr::List(vec![self.expr(expression)]),
                    None => Expr::List(vec![]),
                },
            })
            .collect();
        self.bind(Expr::call("lists", "append", vec![Expr::List(parts)]))
    }

    pub fn call(&mut self, call: &'a CallExpression<'a>) -> Expr {
        let callee = strip(&call.callee);
        if let Expression::Super(_) = callee {
            let parent = self.super_constructor();
            let args = self.args(&call.arguments);
            return self.super_constructor_call(parent, args);
        }
        if let Some(member) = callee.as_member_expression() {
            return self.method_call(call, member);
        }
        if let Expression::ChainExpression(chain) = callee
            && let Some(member) = chain.expression.as_member_expression()
        {
            let (function, this) = self.chain_reference(member);
            if call.optional {
                self.chain_guard(function.clone());
            }
            let args = self.args(&call.arguments);
            return self.bind(Expr::call("buoy_ref", "call", vec![function, this, args]));
        }
        // A call of the name `eval` is a direct eval also through a `with` object, a
        // parameter, or a variable, when the value is the intrinsic %eval%.
        if let Expression::Identifier(ident) = callee
            && ident.name == "eval"
            && !call.optional
        {
            return self.direct_eval(ident, call);
        }
        if let Expression::Identifier(ident) = callee
            && !call.optional
            && !self.with_objects(ident).is_empty()
        {
            let objects = self.with_objects(ident);
            let (function, this) = self.with_callee(ident, &objects);
            let args = self.args(&call.arguments);
            return self.bind(Expr::call("buoy_ref", "call", vec![function, this, args]));
        }
        // A static call, unless the name is the cell of a block function in its block.
        if let Expression::Identifier(ident) = callee
            && let Some(symbol) = self.symbol_of(ident.reference_id.get())
            && !self.frame.env.contains_key(&symbol)
            && self.block_cell(symbol, ident.span).is_none()
        {
            match self.tops.get(&symbol).cloned() {
                Some(Top::Function { name, .. }) if !call.optional => {
                    let args = self.args(&call.arguments);
                    return self.bind(Expr::local_call(&name, vec![Expr::undefined(), args]));
                }
                Some(Top::Buoy(name)) => return self.buoy_call(&name, call),
                Some(Top::Import(binding)) if !call.optional => {
                    if let Some((module, function)) = self.linking.direct_function(&binding) {
                        let args = self.args(&call.arguments);
                        return self.bind(Expr::call(
                            &module,
                            &function,
                            vec![Expr::undefined(), args],
                        ));
                    }
                }
                _ => {}
            }
        }
        let function = self.expr(callee);
        if call.optional {
            self.chain_guard(function.clone());
        }
        let args = self.args(&call.arguments);
        self.bind(Expr::call(
            "buoy_ref",
            "call",
            vec![function, Expr::undefined(), args],
        ))
    }

    /// A call of a member: `o.m(...)`, `o[k](...)`, `o.#m(...)`, `super.m(...)`, and their
    /// optional forms, with `o` as `this`.
    fn method_call(
        &mut self,
        call: &'a CallExpression<'a>,
        member: &'a MemberExpression<'a>,
    ) -> Expr {
        if let MemberExpression::StaticMemberExpression(static_member) = member
            && !call.optional
            && let Some((global, key)) = self.primordial(static_member)
        {
            let function = self.bind(Expr::call(
                "buoy_ref_realm",
                "primordial",
                vec![Expr::js_string(global), key],
            ));
            let this = self.bind(Expr::call(
                "buoy_ref",
                "global",
                vec![Expr::js_string(global)],
            ));
            let args = self.args(&call.arguments);
            return self.bind(Expr::call("buoy_ref", "call", vec![function, this, args]));
        }
        if let Expression::Super(_) = member.object() {
            let (object, key) = self.member_parts(member);
            let method = self.get(object.clone(), key);
            let args = self.args(&call.arguments);
            let this = super_parts(&object).map_or_else(Expr::undefined, |(_, this)| this);
            return self.bind(Expr::call("buoy_ref", "call", vec![method, this, args]));
        }
        let (object, key) = self.member_parts(member);
        // `o?.m()`: the chain ends when `o` is null or undefined.
        if member.optional() {
            self.chain_guard(object.clone());
        }
        if let MemberKey::Private(_) = key {
            if call.optional {
                self.chain_guard(object.clone());
            }
            let method = self.get(object.clone(), key);
            let args = self.args(&call.arguments);
            return self.bind(Expr::call("buoy_ref", "call", vec![method, object, args]));
        }
        if call.optional {
            let key = self.fix_key(key);
            let method = self.get(object.clone(), key);
            self.chain_guard(method.clone());
            let args = self.args(&call.arguments);
            return self.bind(Expr::call("buoy_ref", "call", vec![method, object, args]));
        }
        if !call.arguments.iter().all(is_pure) {
            // The method is read before the arguments run (ECMA-262 §13.3.6.1).
            let key = self.fix_key(key);
            let method = self.get(object.clone(), key.clone());
            let args = self.args(&call.arguments);
            let MemberKey::Static(key) = key else {
                return Expr::undefined();
            };
            return self.bind(Expr::call(
                "buoy_ref",
                "call_method_value",
                vec![method, object, key, args],
            ));
        }
        let args = self.args(&call.arguments);
        let value = match key {
            MemberKey::Static(key) => {
                Expr::call("buoy_ref", "call_method", vec![object, key, args])
            }
            MemberKey::Dynamic(key) => {
                Expr::call("buoy_ref", "call_method_computed", vec![object, key, args])
            }
            MemberKey::Private(_) => Expr::undefined(),
        };
        self.bind(value)
    }

    /// A direct eval. The runtime checks that `eval` is still the intrinsic.
    fn direct_eval(
        &mut self,
        ident: &'a IdentifierReference<'a>,
        call: &'a CallExpression<'a>,
    ) -> Expr {
        let objects = self.with_objects(ident);
        let eval = match self.symbol_of(ident.reference_id.get()) {
            _ if !objects.is_empty() => self.with_read(ident, &objects),
            Some(symbol) => self.read_symbol(symbol, ident.span),
            None => self.identifier_read(ident),
        };
        let args = self.args(&call.arguments);
        let mode = Expr::atom(if self.frame.sloppy {
            "sloppy"
        } else {
            "strict"
        });
        // In a derived constructor, `this` may not exist yet: the code reads its cell.
        let this = if self.frame.this_cell.is_some() {
            Expr::undefined()
        } else {
            self.this_expr()
        };
        let scope = self.eval_scope(ident);
        let lexical = self.eval_lexical(ident);
        let context = self.eval_context_map();
        self.bind(Expr::call(
            "buoy_ref_eval",
            "direct",
            vec![eval, args, mode, this, scope, lexical, context],
        ))
    }

    /// The context map of a direct eval (`EvalContext`): what the place of the call gives
    /// its code. `buoy_ref_eval` derives the flags of `buoy compile-eval` from its keys.
    fn eval_context_map(&mut self) -> Expr {
        let mut entries = Vec::new();
        if self.frame.in_function {
            entries.push(("new_target", self.new_target_expr()));
        }
        if self.frame.in_field {
            entries.push(("field", Expr::atom("true")));
        }
        if let Some(class) = self.frame.class.clone() {
            entries.push(("home", Expr::var(class.home)));
            if let (Some(cell), Some(constructor)) = (self.frame.this_cell.clone(), class.class) {
                entries.push(("this_cell", Expr::var(cell)));
                entries.push(("class", Expr::var(constructor)));
                let init = class.init.map_or_else(
                    || Expr::Fun {
                        name: None,
                        clauses: vec![Clause::new(Expr::var("_"), vec![Expr::ok()])],
                    },
                    Expr::var,
                );
                entries.push(("init", init));
            }
        }
        let mut names: Vec<String> = Vec::new();
        let mut privates = Vec::new();
        for scope in self.privates.iter().rev() {
            for (name, key) in scope {
                if !names.contains(name) {
                    names.push(name.clone());
                    privates.push(Expr::Tuple(vec![Expr::js_string(name), key.clone()]));
                }
            }
        }
        if !privates.is_empty() {
            entries.push(("privates", Expr::List(privates)));
        }
        entries.push(("referrer", self.referrer()));
        Expr::Map(
            entries
                .into_iter()
                .map(|(key, value)| (Expr::atom(key), value))
                .collect(),
        )
    }

    /// The scope that a direct eval at `ident` sees, innermost first: `{Name, Cell}` for
    /// each binding in a cell, with the arguments object in a cell of its own after the
    /// bindings of its function, `{<<"@with">>, Object}` for each `with` statement, and
    /// `{<<"@vars">>, Object}` for the variables of each sloppy function that calls eval
    /// directly. Module variables and globals stay out. In eval code, the scope of the
    /// code's own caller follows.
    fn eval_scope(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        let scoping = self.semantic.scoping();
        let Some(reference) = ident.reference_id.get() else {
            return Expr::List(vec![]);
        };
        let start = scoping.get_reference(reference).scope_id();
        let own_arguments = scoping.scope_ancestors(start).find(|scope| {
            let flags = scoping.scope_flags(*scope);
            flags.contains(ScopeFlags::Function) && !flags.contains(ScopeFlags::Arrow)
        });
        let withs: Vec<_> = self.frame.withs.iter().rev().cloned().collect();
        let mut objects = withs.into_iter().peekable();
        let mut names: Vec<String> = Vec::new();
        let mut entries = Vec::new();
        let mut arguments = self.frame.arguments.clone();
        for scope in scoping.scope_ancestors(start) {
            let span = self
                .semantic
                .nodes()
                .get_node(scoping.get_node_id(scope))
                .span();
            while let Some(object) = objects.next_if(|object| !contains(object.span, span)) {
                entries.push(object_entry(&object));
            }
            for (name, symbol) in scoping.get_bindings(scope) {
                if names.iter().any(|seen| seen == name.as_str()) {
                    continue;
                }
                // An immutable binding, such as the name of a class or of a function
                // expression, reaches the eval as a copy, marked with `!`.
                let (entry, cell) = match self.frame.env.get(symbol).cloned() {
                    Some(Local::Cell(cell)) if self.class_bindings.contains(symbol) => (
                        format!("!{name}"),
                        self.bind(Expr::call("buoy_heap", "cell", vec![cell_get(&cell)])),
                    ),
                    Some(Local::Cell(cell)) => (name.to_string(), Expr::var(cell)),
                    Some(Local::Var(value)) if self.class_bindings.contains(symbol) => (
                        format!("!{name}"),
                        self.bind(Expr::call("buoy_heap", "cell", vec![Expr::var(value)])),
                    ),
                    _ => continue,
                };
                names.push(name.to_string());
                entries.push(Expr::Tuple(vec![Expr::js_string(&entry), cell]));
            }
            if Some(scope) == own_arguments
                && let Some(object) = arguments.take()
            {
                entries.extend(self.arguments_entry(&names, object));
            }
        }
        entries.extend(objects.map(|object| object_entry(&object)));
        if let Some(object) = arguments {
            entries.extend(self.arguments_entry(&names, object));
        }
        // The scope of the caller of this eval code.
        for (name, var) in self.eval_bindings.clone() {
            if name.starts_with('@') || !names.iter().any(|seen| seen == binding_name(&name)) {
                entries.push(Expr::Tuple(vec![Expr::js_string(&name), Expr::var(var)]));
            }
        }
        Expr::List(entries)
    }

    /// The entry of the arguments object in the scope of a direct eval, unless a binding
    /// named `arguments` hides it.
    fn arguments_entry(&mut self, names: &[String], binding: Local) -> Option<Expr> {
        if names.iter().any(|name| name == "arguments") {
            return None;
        }
        let cell = match binding {
            Local::Cell(cell) => Expr::var(cell),
            Local::Var(object) => {
                self.bind(Expr::call("buoy_heap", "cell", vec![Expr::var(object)]))
            }
        };
        Some(Expr::Tuple(vec![Expr::js_string("arguments"), cell]))
    }

    /// The names that a sloppy direct eval at `ident` may not declare with `var`: the
    /// lexical bindings between the call and its function's variables, and in a parameter
    /// default the bindings of the parameter scope (ECMA-262 §19.2.1.3).
    fn eval_lexical(&self, ident: &'a IdentifierReference<'a>) -> Expr {
        let scoping = self.semantic.scoping();
        let Some(reference) = ident.reference_id.get() else {
            return Expr::List(vec![]);
        };
        let mut names: Vec<String> = self.frame.param_bindings.clone();
        // In a parameter default, the declarations of the body do not exist yet.
        if !names.is_empty() {
            return Expr::List(names.iter().map(|name| Expr::js_string(name)).collect());
        }
        let scope = scoping.get_reference(reference).scope_id();
        let home = super::analyze::function_scope(scoping, scope);
        for ancestor in scoping.scope_ancestors(scope) {
            for (name, symbol) in scoping.get_bindings(ancestor) {
                if scoping.symbol_flags(*symbol).is_block_scoped()
                    && !names.iter().any(|seen| seen == name.as_str())
                {
                    names.push(name.to_string());
                }
            }
            if ancestor == home {
                break;
            }
        }
        Expr::List(names.iter().map(|name| Expr::js_string(name)).collect())
    }

    /// A function imported from "buoy".
    pub fn buoy_call(&mut self, name: &str, call: &'a CallExpression<'a>) -> Expr {
        match name {
            "spawn" => {
                let class = match call.arguments.first().and_then(Argument::as_expression) {
                    Some(Expression::Identifier(ident)) => self
                        .symbol_of(ident.reference_id.get())
                        .and_then(|symbol| self.tops.get(&symbol).cloned()),
                    _ => None,
                };
                // An imported class: the actor's realm reads it through its module.
                let target = match class {
                    Some(Top::Class(class)) => {
                        Expr::Tuple(vec![Expr::atom(self.module.clone()), Expr::binary(class)])
                    }
                    Some(Top::Import(super::link::Binding::Export { unit, key }))
                        if self.linking.graph.units[unit].kind == super::graph::Kind::Esm =>
                    {
                        Expr::Tuple(vec![
                            Expr::atom("export"),
                            Expr::atom(self.linking.graph.units[unit].name.clone()),
                            Expr::binary(key),
                        ])
                    }
                    _ => {
                        return self.unsupported(
                            call.span,
                            "`spawn` of a value that is not a module-level class",
                        );
                    }
                };
                let options = match call.arguments.get(1).and_then(Argument::as_expression) {
                    Some(options) => self.expr(options),
                    None => Expr::undefined(),
                };
                self.bind(Expr::call(
                    "buoy_jobs",
                    "spawn_actor",
                    vec![target, Expr::call("buoy_ref", "spawn_args", vec![options])],
                ))
            }
            "stop" => {
                let args = self.args(&call.arguments);
                self.bind(Expr::call("buoy_ref", "stop_actor", vec![args]))
            }
            "heapStats" => self.bind(Expr::call("buoy_ref", "heap_stats", vec![])),
            "vmMemory" => self.bind(Expr::call("buoy_ref", "vm_memory", vec![])),
            other => self.unsupported(call.span, &format!("`{other}` from \"buoy\"")),
        }
    }

    pub fn new_expression(&mut self, new: &'a NewExpression<'a>) -> Expr {
        let constructor = self.expr(&new.callee);
        let args = self.args(&new.arguments);
        self.bind(Expr::call("buoy_ref", "construct", vec![constructor, args]))
    }
}

/// Whether an argument has no effect that the read of the method could observe: a literal,
/// a name, `this`, or a function.
fn is_pure(argument: &Argument<'_>) -> bool {
    match argument.as_expression().map(strip) {
        Some(
            Expression::NumericLiteral(_)
            | Expression::StringLiteral(_)
            | Expression::BooleanLiteral(_)
            | Expression::NullLiteral(_)
            | Expression::Identifier(_)
            | Expression::ThisExpression(_)
            | Expression::ArrowFunctionExpression(_)
            | Expression::FunctionExpression(_),
        ) => true,
        Some(Expression::TemplateLiteral(template)) => template.expressions.is_empty(),
        _ => false,
    }
}

/// The scope entry of a `with` object or of the variables of a function.
fn object_entry(object: &super::with::WithScope) -> Expr {
    let marker = if object.vars { "@vars" } else { "@with" };
    Expr::Tuple(vec![
        Expr::js_string(marker),
        Expr::var(object.object.clone()),
    ])
}
