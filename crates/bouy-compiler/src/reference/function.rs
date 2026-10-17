//! Functions: parameters, bodies, `return`, and the function values of arrows,
//! function expressions, and object literal methods, with their `name` and `length`.

use oxc::ast::ast::{
    ArrowFunctionExpression, BindingPattern, Expression, FormalParameters, Function, FunctionBody,
};

use oxc::ast_visit::Visit;
use oxc::semantic::{ScopeId, SymbolId};

use super::analyze::{UsesArguments, UsesThis, VarDeclarations, is_simple};
use super::context::{ClassFrame, Cont, Frame, Kind, Local, Lowerer, Ret};
use super::expr::strip;
use crate::erlang::{Clause, Expr};

/// How a function refers to itself: for `arguments.callee`, and for the name of a named
/// function expression inside its body.
#[derive(Debug, Clone)]
pub enum Itself {
    None,
    /// A module-level function: its static value.
    Static(Expr),
    /// A function made at run time: `id` holds the id that `bouy_heap:new_id/0` gave it
    /// before the fun existed, and `fun` names the named fun, so the body can build
    /// `{'$f', Id, Fun}`. `symbol` is the binding of a named function expression.
    Named {
        id: String,
        fun: String,
        symbol: Option<SymbolId>,
    },
}

impl<'a> Lowerer<'a, '_> {
    /// Lowers a function: returns the names of its `This` and `Args` parameters and its
    /// body.
    pub fn function_code(
        &mut self,
        params: &'a FormalParameters<'a>,
        body: FnBody<'a>,
        kind: Kind,
        callee: Callee,
        scope: Option<ScopeId>,
        itself: &Itself,
    ) -> (String, String, Vec<Expr>) {
        let this_param = self.fresh("This");
        let args = self.fresh("Args");
        let outer = std::mem::take(&mut self.frame);
        let outer_pre = std::mem::take(&mut self.pre);
        let own_arguments = matches!(callee, Callee::Function(_));
        let (this, class, arguments, new_target, callee_value) = match callee {
            Callee::Arrow => (
                outer.this.clone(),
                outer.class.clone(),
                outer.arguments.clone(),
                outer.new_target.clone(),
                outer.callee.clone(),
            ),
            Callee::Function(class) => (Some(this_param.clone()), class, None, None, None),
        };
        let sloppy = scope.is_some() && self.is_sloppy(scope);
        self.frame = Frame {
            env: outer.env.clone(),
            this,
            kind,
            class,
            arguments,
            new_target,
            sloppy,
            callee: callee_value,
            ..Frame::default()
        };
        let mut prologue = Vec::new();
        match itself {
            Itself::None => {}
            Itself::Static(value) => self.frame.callee = Some(value.clone()),
            Itself::Named { id, fun, symbol } => {
                let value = self.fresh("Self");
                prologue.push(Expr::matches(
                    Expr::var(value.clone()),
                    Expr::Tuple(vec![
                        Expr::atom("$f"),
                        Expr::var(id.clone()),
                        Expr::var(fun.clone()),
                    ]),
                ));
                if let Some(symbol) = symbol {
                    self.frame.env.insert(*symbol, Local::Var(value.clone()));
                }
                self.frame.callee = Some(Expr::var(value));
            }
        }
        let code = match kind {
            Kind::Sync => {
                let mut code = self.entry(params, body, &args, own_arguments);
                code.extend(self.body(body));
                code
            }
            Kind::Async => {
                let args_var = args.clone();
                self.async_body(move |me| {
                    let mut code = me.entry(params, body, &args_var, own_arguments);
                    code.extend(me.body(body));
                    code
                })
            }
            Kind::Generator => {
                let mut code = self.entry(params, body, &args, own_arguments);
                self.frame.ret = Ret::Generator;
                let inner = self.body(body);
                code.push(Expr::call(
                    "bouy_ref_iterator",
                    "make_generator",
                    vec![Expr::Fun {
                        name: None,
                        clauses: vec![Clause {
                            patterns: vec![],
                            guards: vec![],
                            body: inner,
                        }],
                    }],
                ));
                code
            }
        };
        prologue.extend(code);
        self.frame = outer;
        self.pre = outer_pre;
        (this_param, args, prologue)
    }

    pub fn body(&mut self, body: FnBody<'a>) -> Vec<Expr> {
        match body {
            FnBody::Block(block) => self.stmts(block.statements.iter().collect(), &Cont::Return),
            FnBody::Expr(expression) => {
                let value = self.expr(expression);
                let mut code = std::mem::take(&mut self.pre);
                code.push(self.ret(value));
                self.seal(code)
            }
        }
    }

    /// The code at the start of a function: `new.target` and a sloppy `this` when it reads
    /// them, its `arguments` object when it reads one, its parameters, and its `var` names,
    /// which hold `undefined` until their declarations run.
    fn entry(
        &mut self,
        params: &'a FormalParameters<'a>,
        body: FnBody<'a>,
        args: &str,
        own_arguments: bool,
    ) -> Vec<Expr> {
        let mut uses = UsesArguments::default();
        uses.visit_formal_parameters(params);
        let mut reads = UsesThis::default();
        reads.visit_formal_parameters(params);
        let mut vars = VarDeclarations::default();
        if let FnBody::Block(block) = body {
            uses.visit_function_body(block);
            reads.visit_function_body(block);
            vars.visit_function_body(block);
        }
        let mut code = Vec::new();
        if own_arguments {
            code.extend(self.receiver(&reads));
        }
        let mapped = uses.0 && own_arguments && self.frame.sloppy && is_simple(params);
        if uses.0 && own_arguments && !mapped {
            let arguments = self.fresh("Arguments");
            code.push(Expr::matches(
                Expr::var(arguments.clone()),
                Expr::call("bouy_ref", "arguments_object", vec![Expr::var(args)]),
            ));
            self.frame.arguments = Some(arguments);
        }
        code.extend(self.params(params, args));
        if mapped {
            code.push(self.mapped_arguments(params, args));
        }
        let saved = std::mem::take(&mut self.pre);
        for symbol in vars.0 {
            if !self.frame.env.contains_key(&symbol) {
                self.declare_symbol(symbol, Expr::undefined());
            }
        }
        code.extend(std::mem::replace(&mut self.pre, saved));
        code
    }

    /// `new.target` of an ordinary function, and the `this` of a sloppy one: the global
    /// object when the caller passed undefined or null.
    fn receiver(&mut self, reads: &UsesThis) -> Vec<Expr> {
        let mut code = Vec::new();
        let in_constructor = self
            .frame
            .class
            .as_ref()
            .is_some_and(|class| class.new_target.is_some());
        if reads.new_target && !in_constructor {
            let new_target = self.fresh("NewTarget");
            code.push(Expr::matches(
                Expr::var(new_target.clone()),
                Expr::call("bouy_ref", "new_target", vec![self.this_expr()]),
            ));
            self.frame.new_target = Some(new_target);
        }
        if reads.this && self.frame.sloppy {
            let this = self.fresh("This");
            code.push(Expr::matches(
                Expr::var(this.clone()),
                Expr::call("bouy_ref", "sloppy_this", vec![self.this_expr()]),
            ));
            self.frame.this = Some(this);
        }
        code
    }

    /// The mapped `arguments` object of a sloppy function with simple parameters: each
    /// index below the argument count shares the cell of its parameter.
    fn mapped_arguments(&mut self, params: &'a FormalParameters<'a>, args: &str) -> Expr {
        let cells = params
            .items
            .iter()
            .map(|param| match &param.pattern {
                BindingPattern::BindingIdentifier(id) => match id
                    .symbol_id
                    .get()
                    .and_then(|symbol| self.frame.env.get(&symbol))
                {
                    Some(Local::Cell(cell)) => Expr::var(cell.clone()),
                    _ => Expr::undefined(),
                },
                _ => Expr::undefined(),
            })
            .collect();
        let arguments = self.fresh("Arguments");
        let callee = self.frame.callee.clone().unwrap_or_else(Expr::undefined);
        self.frame.arguments = Some(arguments.clone());
        Expr::matches(
            Expr::var(arguments),
            Expr::call(
                "bouy_ref",
                "mapped_arguments",
                vec![Expr::var(args), Expr::List(cells), callee],
            ),
        )
    }

    /// Binds the parameters from the argument list `args`.
    pub fn params(&mut self, params: &'a FormalParameters<'a>, args: &str) -> Vec<Expr> {
        let saved = std::mem::take(&mut self.pre);
        for (index, param) in params.items.iter().enumerate() {
            let position = Expr::Integer(i64::try_from(index + 1).unwrap_or(i64::MAX));
            let arg = Expr::call("bouy_rt", "arg", vec![position, Expr::var(args)]);
            let value = match &param.initializer {
                None => arg,
                Some(default) => {
                    let given = self.bind(arg);
                    let name = binding_name(&param.pattern);
                    let fallback = self.branch(|me| me.named_expr(default, name));
                    self.bind(Expr::case(
                        given.clone(),
                        vec![
                            Clause::new(Expr::undefined(), fallback),
                            Clause::new(Expr::var("_"), vec![given]),
                        ],
                    ))
                }
            };
            self.declare_pattern(&param.pattern, value);
        }
        if let Some(rest) = &params.rest {
            let position = Expr::Integer(i64::try_from(params.items.len() + 1).unwrap_or(i64::MAX));
            let value = Expr::call(
                "bouy_heap",
                "new_array",
                vec![Expr::call(
                    "bouy_rt",
                    "rest",
                    vec![position, Expr::var(args)],
                )],
            );
            let value = self.bind(value);
            self.declare_pattern(&rest.rest.argument, value);
        }
        std::mem::replace(&mut self.pre, saved)
    }

    /// The expression that ends the function with `value`.
    pub fn ret(&mut self, value: Expr) -> Expr {
        if !self.frame.reify.is_empty() {
            return Expr::tagged("return", value);
        }
        match self.frame.ret.clone() {
            Ret::Value => value,
            Ret::Generator => Expr::tagged("done", value),
            Ret::Resolve(resolve) => Expr::Apply(Box::new(Expr::var(resolve)), vec![value]),
            Ret::Constructor => {
                let this = self.this_expr();
                if value == Expr::undefined() {
                    return this;
                }
                let v = self.fresh("R");
                Expr::case(
                    value,
                    vec![
                        Clause::guarded(
                            Expr::var(v.clone()),
                            vec![Expr::call(
                                "bouy_heap",
                                "is_object",
                                vec![Expr::var(v.clone())],
                            )],
                            vec![Expr::var(v)],
                        ),
                        Clause::new(Expr::var("_"), vec![this]),
                    ],
                )
            }
        }
    }

    /// The function value of an object literal method, getter, or setter, whose `name` is
    /// `name`: its own `this`, and no `prototype` unless it is a generator.
    pub fn method_value(&mut self, value: &'a Expression<'a>, name: Expr) -> Expr {
        match value {
            Expression::FunctionExpression(function) => {
                let kind = fn_kind(function);
                if kind != "normal" {
                    return self.function_value(function, Some(name), false);
                }
                let fun = self.function_fun(function, None);
                let length = Expr::Integer(i64::try_from(length_of(&function.params)).unwrap_or(0));
                self.bind(Expr::call("bouy_ref", "fn", vec![fun, name, length]))
            }
            other => self.expr(other),
        }
    }

    /// An expression whose value is named `name` when it is an anonymous function: the
    /// `NamedEvaluation` of ECMA-262 §8.4.5.
    pub fn named_expr(&mut self, expression: &'a Expression<'a>, name: Option<Expr>) -> Expr {
        let Some(name) = name else {
            return self.expr(expression);
        };
        match strip(expression) {
            Expression::FunctionExpression(function) if function.id.is_none() => {
                self.function_value(function, Some(name), false)
            }
            Expression::ArrowFunctionExpression(arrow) => self.arrow_named(arrow, name),
            _ => self.expr(expression),
        }
    }

    pub fn arrow(&mut self, arrow: &'a ArrowFunctionExpression<'a>) -> Expr {
        self.arrow_named(arrow, Expr::js_string(""))
    }

    fn arrow_named(&mut self, arrow: &'a ArrowFunctionExpression<'a>, name: Expr) -> Expr {
        let body = match (arrow.get_expression(), arrow.get_function_body()) {
            (Some(expression), _) => FnBody::Expr(expression),
            (None, Some(body)) => FnBody::Block(body),
            (None, None) => return Expr::undefined(),
        };
        let (this_param, args, code) = self.function_code(
            &arrow.params,
            body,
            kind_of(arrow.r#async, false),
            Callee::Arrow,
            arrow.scope_id.get(),
            &Itself::None,
        );
        let fun = fun2(None, this_param, args, code);
        let length = Expr::Integer(i64::try_from(length_of(&arrow.params)).unwrap_or(0));
        self.bind(Expr::call("bouy_ref", "fn", vec![fun, name, length]))
    }

    pub fn function_expression(&mut self, function: &'a Function<'a>) -> Expr {
        self.function_value(function, None, true)
    }

    /// The value of a function expression or a nested function declaration:
    /// `named_fn(Fun, Name, Length, Kind)`. `name` names an anonymous function, and
    /// `expression` says that the function's own name is a binding inside it.
    pub fn function_value(
        &mut self,
        function: &'a Function<'a>,
        name: Option<Expr>,
        expression: bool,
    ) -> Expr {
        let name = match (&function.id, name) {
            (Some(id), _) => Expr::js_string(id.name.as_str()),
            (None, Some(name)) => name,
            (None, None) => Expr::js_string(""),
        };
        let length = Expr::Integer(i64::try_from(length_of(&function.params)).unwrap_or(0));
        let kind = Expr::atom(self.value_kind(function));
        let symbol = function
            .id
            .as_ref()
            .and_then(|id| id.symbol_id.get())
            .filter(|symbol| {
                expression
                    && self
                        .semantic
                        .scoping()
                        .get_resolved_references(*symbol)
                        .next()
                        .is_some()
            });
        if symbol.is_none() && !self.needs_callee(function) {
            let fun = self.function_fun(function, None);
            return self.bind(Expr::call(
                "bouy_ref",
                "named_fn",
                vec![fun, name, length, kind],
            ));
        }
        let id = self.fresh("Id");
        self.pre.push(Expr::matches(
            Expr::var(id.clone()),
            Expr::call("bouy_heap", "new_id", vec![]),
        ));
        let fun_name = self.fresh("Fn");
        let itself = Itself::Named {
            id: id.clone(),
            fun: fun_name,
            symbol,
        };
        let fun = self.function_fun_itself(function, None, &itself);
        self.bind(Expr::call(
            "bouy_ref",
            "named_fn",
            vec![Expr::var(id), fun, name, length, kind],
        ))
    }

    /// The kind of a function value: `sloppy` for a normal function of sloppy code.
    pub fn value_kind(&self, function: &'a Function<'a>) -> &'static str {
        match fn_kind(function) {
            "normal"
                if function.scope_id.get().is_some() && self.is_sloppy(function.scope_id.get()) =>
            {
                "sloppy"
            }
            kind => kind,
        }
    }

    /// Whether a function's `arguments` object needs the function itself, as
    /// `arguments.callee` of a sloppy function.
    pub fn needs_callee(&self, function: &'a Function<'a>) -> bool {
        if function.scope_id.get().is_none() || !self.is_sloppy(function.scope_id.get()) {
            return false;
        }
        let mut uses = UsesArguments::default();
        if let Some(body) = &function.body {
            uses.visit_function_body(body);
        }
        uses.0
    }

    /// The Erlang fun of a non-arrow function: `fun(This, Args) -> ... end`.
    pub fn function_fun(&mut self, function: &'a Function<'a>, class: Option<ClassFrame>) -> Expr {
        self.function_fun_itself(function, class, &Itself::None)
    }

    pub fn function_fun_itself(
        &mut self,
        function: &'a Function<'a>,
        class: Option<ClassFrame>,
        itself: &Itself,
    ) -> Expr {
        let Some(body) = &function.body else {
            return Expr::undefined();
        };
        let (this_param, args, code) = self.function_code(
            &function.params,
            FnBody::Block(body),
            kind_of(function.r#async, function.generator),
            Callee::Function(class),
            function.scope_id.get(),
            itself,
        );
        let name = match itself {
            Itself::Named { fun, .. } => Some(fun.clone()),
            _ => None,
        };
        fun2(name, this_param, args, code)
    }
}

/// What `this` and `super` mean in a function.
#[derive(Debug, Clone)]
pub enum Callee {
    /// An arrow function: the `this` and the class of the enclosing function.
    Arrow,
    /// A function with its own `this`, and the class frame of a method.
    Function(Option<ClassFrame>),
}

/// The body of a function: a block, or the expression of an arrow function.
#[derive(Clone, Copy)]
pub enum FnBody<'a> {
    Block(&'a FunctionBody<'a>),
    Expr(&'a Expression<'a>),
}

/// The `length` of a function: the parameters before the first default or rest.
pub fn length_of(params: &FormalParameters<'_>) -> usize {
    params
        .items
        .iter()
        .take_while(|param| param.initializer.is_none())
        .count()
}

pub fn kind_of(is_async: bool, generator: bool) -> Kind {
    match (is_async, generator) {
        (_, true) => Kind::Generator,
        (true, false) => Kind::Async,
        (false, false) => Kind::Sync,
    }
}

/// The kind of a function value for `bouy_ref:named_fn/4`.
pub fn fn_kind(function: &Function<'_>) -> &'static str {
    match (function.r#async, function.generator) {
        (false, false) => "normal",
        (false, true) => "generator",
        (true, false) => "async",
        (true, true) => "async_generator",
    }
}

/// The name that `NamedEvaluation` gives an anonymous function bound to `pattern`.
pub fn binding_name(pattern: &BindingPattern<'_>) -> Option<Expr> {
    match pattern {
        BindingPattern::BindingIdentifier(id) => Some(Expr::js_string(id.name.as_str())),
        _ => None,
    }
}

pub fn fun2(name: Option<String>, this: String, args: String, body: Vec<Expr>) -> Expr {
    Expr::Fun {
        name,
        clauses: vec![Clause {
            patterns: vec![Expr::var(this), Expr::var(args)],
            guards: vec![],
            body,
        }],
    }
}
