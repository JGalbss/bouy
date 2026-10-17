//! Functions: parameters, bodies, `return`, and the function objects of arrows,
//! function expressions, and methods, with their `name`, `length`, and source text.
//!
//! A generator or an async generator function compiles to a maker,
//! `fun(SelfId) -> fun(This, Args) -> ... end end`, so that its body can find the
//! prototype of its own function object for the generators it makes. A function that
//! reads `new.target` compiles to `fun(This, Args, NewTarget)`.

use oxc::ast::ast::{
    ArrowFunctionExpression, BindingPattern, Class, Expression, FormalParameters, Function,
    FunctionBody, NewTarget,
};
use oxc::ast_visit::Visit;
use oxc::semantic::{ScopeFlags, ScopeId};
use oxc::span::Span;

use super::analyze::{BlockFunctions, UsesArguments, UsesThis, VarDeclarations, is_simple};
use super::class::method_kind;
use super::context::{ClassFrame, Cont, Frame, Kind, Local, Lowerer, Ret, cell_get, cell_set};
use crate::erlang::{Clause, Expr};

/// The lowered code of a function.
pub struct Code {
    pub this: String,
    pub args: String,
    pub new_target: Option<String>,
    pub body: Vec<Expr>,
}

impl Code {
    /// `fun(This, Args) -> Body end`, with `NewTarget` when the function reads it.
    pub fn fun(self) -> Expr {
        let mut patterns = vec![Expr::var(self.this), Expr::var(self.args)];
        if let Some(new_target) = self.new_target {
            patterns.push(Expr::var(new_target));
        }
        Expr::Fun {
            name: None,
            clauses: vec![Clause {
                patterns,
                guards: vec![],
                body: self.body,
            }],
        }
    }
}

impl<'a> Lowerer<'a, '_> {
    /// Lowers a function. `own` is the value that a generator's body finds its function
    /// object by: the id of its record, or the static function value. `scope` is the scope
    /// of the function, which says whether its code is sloppy.
    pub fn function_code(
        &mut self,
        params: &'a FormalParameters<'a>,
        body: FnBody<'a>,
        kind: Kind,
        callee: Callee,
        own: Option<Expr>,
        scope: Option<ScopeId>,
    ) -> Code {
        let this_param = self.fresh("This");
        let args = self.fresh("Args");
        let outer = std::mem::take(&mut self.frame);
        let outer_pre = std::mem::take(&mut self.pre);
        let own_arguments = !matches!(callee, Callee::Arrow);
        let reads_new_target = match (&callee, body) {
            (Callee::Function(_), FnBody::Block(block)) if kind == Kind::Sync => {
                let mut uses = UsesNewTarget(false);
                uses.visit_formal_parameters(params);
                uses.visit_function_body(block);
                uses.0
            }
            _ => false,
        };
        let new_target_param = reads_new_target.then(|| self.fresh("NewTarget"));
        let mut frame = Frame {
            env: outer.env.clone(),
            kind,
            sloppy: scope.is_some() && self.is_sloppy(scope),
            withs: outer.withs.clone(),
            ..Frame::default()
        };
        match callee {
            Callee::Arrow => {
                frame.this.clone_from(&outer.this);
                frame.class.clone_from(&outer.class);
                frame.arguments.clone_from(&outer.arguments);
                frame.this_cell.clone_from(&outer.this_cell);
                frame.new_target.clone_from(&outer.new_target);
                frame.callee.clone_from(&outer.callee);
            }
            Callee::Function(itself) => {
                frame.this = Some(this_param.clone());
                frame.new_target.clone_from(&new_target_param);
                frame.callee = itself;
            }
            Callee::Method(class) => {
                frame.this = Some(this_param.clone());
                frame.class = class;
            }
        }
        self.frame = frame;
        let own = own.unwrap_or_else(Expr::undefined);
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
                    "bouy_ref_generator",
                    "start",
                    vec![
                        own,
                        Expr::Fun {
                            name: None,
                            clauses: vec![Clause {
                                patterns: vec![],
                                guards: vec![],
                                body: inner,
                            }],
                        },
                    ],
                ));
                code
            }
            Kind::AsyncGenerator => {
                let mut code = self.entry(params, body, &args, own_arguments);
                code.push(self.async_generator_body(body, own));
                code
            }
        };
        self.frame = outer;
        self.pre = outer_pre;
        Code {
            this: this_param,
            args,
            new_target: new_target_param,
            body: code,
        }
    }

    /// `bouy_ref_generator:start_async(Own, fun(Resolve, Reject, Yield) -> ... end)`: the
    /// body of an async generator, which its first `next()` starts.
    fn async_generator_body(&mut self, body: FnBody<'a>, own: Expr) -> Expr {
        let resolve = self.fresh("Resolve");
        let reject = self.fresh("Reject");
        let yield_fun = self.fresh("Yield");
        self.frame.ret = Ret::Resolve(resolve.clone());
        self.frame.reject = Some(reject.clone());
        self.frame.yield_fun = Some(yield_fun.clone());
        let inner = self.body(body);
        let inner = self.wrap_level(inner, &reject, 0);
        Expr::call(
            "bouy_ref_generator",
            "start_async",
            vec![
                own,
                Expr::Fun {
                    name: None,
                    clauses: vec![Clause {
                        patterns: vec![Expr::var(resolve), Expr::var(reject), Expr::var(yield_fun)],
                        guards: vec![],
                        body: vec![inner],
                    }],
                },
            ],
        )
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

    /// The code at the start of a function: a sloppy `this` when it reads it, its
    /// `arguments` object when it reads one, its parameters, and its `var` names, which
    /// hold `undefined` until their declarations run.
    pub fn entry(
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
        // The parameter scope binds the parameters, and `arguments` in an ordinary
        // function. A direct eval in a default may not declare them.
        let mut bindings: Vec<String> = params
            .items
            .iter()
            .flat_map(|param| param.pattern.get_binding_identifiers())
            .map(|id| id.name.to_string())
            .collect();
        if own_arguments {
            bindings.push("arguments".to_owned());
        }
        self.frame.param_bindings = bindings;
        code.extend(self.params(params, args));
        self.frame.param_bindings = Vec::new();
        if mapped {
            code.push(self.mapped_arguments(params, args));
        }
        let saved = std::mem::take(&mut self.pre);
        if self.frame.sloppy
            && let FnBody::Block(block) = body
        {
            let mut blocks = BlockFunctions::default();
            for statement in &block.statements {
                blocks.visit_statement(statement);
            }
            for symbol in blocks.found {
                if !self.frame.env.contains_key(&symbol) {
                    let cell = self.fresh("Fn");
                    self.pre.push(Expr::matches(
                        Expr::var(cell.clone()),
                        Expr::call("bouy_heap", "cell", vec![Expr::undefined()]),
                    ));
                    self.frame.env.insert(symbol, Local::Cell(cell));
                }
            }
        }
        for symbol in vars.0 {
            if !self.frame.env.contains_key(&symbol) {
                // `var arguments` keeps the arguments object (ECMA-262 §10.2.11).
                let value = match &self.frame.arguments {
                    Some(arguments)
                        if self.semantic.scoping().symbol_name(symbol) == "arguments" =>
                    {
                        Expr::var(arguments.clone())
                    }
                    _ => Expr::undefined(),
                };
                self.declare_symbol(symbol, value);
            }
        }
        code.extend(std::mem::replace(&mut self.pre, saved));
        code
    }

    /// The `this` of a sloppy function: the global object when the caller passed undefined
    /// or null.
    fn receiver(&mut self, reads: &UsesThis) -> Vec<Expr> {
        let mut code = Vec::new();
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
        let early = self.early_params(params);
        self.pre.extend(early);
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

    /// The expression that ends the function with `value`: through the `finally` blocks
    /// and the loops around the code that must close their iterators.
    pub fn ret(&mut self, value: Expr) -> Expr {
        if self.reify_innermost() {
            return Expr::tagged("return", value);
        }
        if let Some(finally) = self.frame.finally.last() {
            let (fun, region) = (finally.fun.clone(), finally.region);
            return self.call_cont(&fun, vec![Expr::tagged("return", value)], region);
        }
        match self.frame.ret.clone() {
            Ret::Value => value,
            Ret::Generator => Expr::tagged("done", value),
            Ret::Resolve(resolve) => Expr::Apply(Box::new(Expr::var(resolve)), vec![value]),
            Ret::Constructor => {
                if let Some(cell) = self.frame.this_cell.clone() {
                    return Expr::call(
                        "bouy_ref_class",
                        "derived_return",
                        vec![Expr::var(cell), value],
                    );
                }
                let this = self.this_expr();
                if value == Expr::undefined() {
                    return this;
                }
                Expr::call("bouy_ref_class", "base_return", vec![this, value])
            }
        }
    }

    /// The function object of an object literal method, named after its key. `home` is
    /// the object, for `super`. `span` is the source text of the method, from its key to
    /// its body.
    pub fn method_value(
        &mut self,
        value: &'a Expression<'a>,
        key: Expr,
        kind: &'static str,
        home: Option<String>,
        span: Span,
    ) -> Expr {
        let Expression::FunctionExpression(function) = value else {
            return self.expr(value);
        };
        let frame = home.map(|home| ClassFrame {
            home,
            class: None,
            init: None,
        });
        let fun = self.function_fun(function, Callee::Method(frame));
        let kind = match kind {
            "method" => method_kind(function.r#async, function.generator),
            other => other,
        };
        let source = self.source_span(span);
        self.bind(Expr::call(
            "bouy_ref_class",
            "method",
            vec![
                fun,
                key,
                int(length_of(&function.params)),
                Expr::atom(kind),
                source,
            ],
        ))
    }

    /// `{Module, Start, End}`: where the source text of a function is in `'$source'/0`.
    pub fn source_span(&self, span: Span) -> Expr {
        Expr::Tuple(vec![
            Expr::atom(self.module.clone()),
            Expr::Integer(i64::from(span.start)),
            Expr::Integer(i64::from(span.end)),
        ])
    }

    pub fn arrow(&mut self, arrow: &'a ArrowFunctionExpression<'a>) -> Expr {
        self.arrow_value(arrow, None)
    }

    /// An arrow function: a record with its name, from `NamedEvaluation` or empty, and its
    /// length.
    pub fn arrow_value(
        &mut self,
        arrow: &'a ArrowFunctionExpression<'a>,
        name: Option<Expr>,
    ) -> Expr {
        let body = match (arrow.get_expression(), arrow.get_function_body()) {
            (Some(expression), _) => FnBody::Expr(expression),
            (None, Some(body)) => FnBody::Block(body),
            (None, None) => return Expr::undefined(),
        };
        let code = self.function_code(
            &arrow.params,
            body,
            kind_of(arrow.r#async, false),
            Callee::Arrow,
            None,
            arrow.scope_id.get(),
        );
        let fun = code.fun();
        let kind = if arrow.r#async { "async" } else { "arrow" };
        let source = self.source_span(arrow.span);
        self.bind(Expr::call(
            "bouy_ref_class",
            "method",
            vec![
                fun,
                name.unwrap_or_else(|| Expr::js_string("")),
                int(length_of(&arrow.params)),
                Expr::atom(kind),
                source,
            ],
        ))
    }

    pub fn function_expression(&mut self, function: &'a Function<'a>) -> Expr {
        self.function_value(function, None)
    }

    /// The function object of a function expression or a nested declaration: named after
    /// its own name, or the key of `NamedEvaluation`.
    pub fn function_value(&mut self, function: &'a Function<'a>, name: Option<Expr>) -> Expr {
        let name = match (&function.id, name) {
            (Some(id), _) => Expr::js_string(id.name.as_str()),
            (None, Some(name)) => name,
            (None, None) => Expr::js_string(""),
        };
        let reads_new_target = !function.r#async && !function.generator && {
            let mut uses = UsesNewTarget(false);
            uses.visit_formal_parameters(&function.params);
            if let Some(body) = &function.body {
                uses.visit_function_body(body);
            }
            uses.0
        };
        // The name of a function expression is a constant binding inside it, to the
        // function itself, and so is `arguments.callee` of a sloppy function: a cell that
        // is set once the function exists.
        let symbol = function
            .id
            .as_ref()
            .filter(|_| function.is_expression())
            .and_then(|id| id.symbol_id.get())
            .filter(|symbol| {
                !self
                    .semantic
                    .scoping()
                    .get_resolved_reference_ids(*symbol)
                    .is_empty()
            });
        let callee = self.needs_callee(function);
        let cell = (symbol.is_some() || callee).then(|| {
            let cell = self.fresh("Own");
            self.pre.push(Expr::matches(
                Expr::var(cell.clone()),
                Expr::call("bouy_heap", "cell", vec![Expr::undefined()]),
            ));
            cell
        });
        let own = symbol.zip(cell.clone()).map(|(symbol, cell)| {
            let saved = self.frame.env.insert(symbol, Local::Cell(cell));
            self.class_bindings.push(symbol);
            (symbol, saved)
        });
        let itself = cell.clone().filter(|_| callee).map(|cell| cell_get(&cell));
        let fun = self.function_fun(function, Callee::Function(itself));
        let kind = match method_kind(function.r#async, function.generator) {
            "method" if reads_new_target => "normal_nt",
            "method" if self.is_sloppy(function.scope_id.get()) => "sloppy",
            "method" => "normal",
            other => other,
        };
        let source = self.source_span(function.span);
        let value = self.bind(Expr::call(
            "bouy_ref_class",
            "method",
            vec![
                fun,
                name,
                int(length_of(&function.params)),
                Expr::atom(kind),
                source,
            ],
        ));
        if let Some((symbol, saved)) = own {
            self.class_bindings.pop();
            match saved {
                Some(local) => self.frame.env.insert(symbol, local),
                None => self.frame.env.remove(&symbol),
            };
        }
        if let Some(cell) = cell {
            self.pre.push(cell_set(&cell, value.clone()));
        }
        value
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

    /// The Erlang fun of a non-arrow function: `fun(This, Args) -> ... end`, or the maker
    /// of a generator.
    pub fn function_fun(&mut self, function: &'a Function<'a>, callee: Callee) -> Expr {
        let Some(body) = &function.body else {
            return Expr::undefined();
        };
        let kind = kind_of(function.r#async, function.generator);
        let maker = matches!(kind, Kind::Generator | Kind::AsyncGenerator);
        let own = maker.then(|| self.fresh("Own"));
        let code = self.function_code(
            &function.params,
            FnBody::Block(body),
            kind,
            callee,
            own.clone().map(Expr::var),
            function.scope_id.get(),
        );
        let fun = code.fun();
        match own {
            Some(own) => Expr::Fun {
                name: None,
                clauses: vec![Clause::new(Expr::var(own), vec![fun])],
            },
            None => fun,
        }
    }
}

/// What `this`, `super`, `new.target`, and `arguments.callee` mean in a function.
#[derive(Debug, Clone)]
pub enum Callee {
    /// An arrow function: the `this` and the class of the enclosing function.
    Arrow,
    /// A function declaration or expression: its own `this` and `new.target`, and the
    /// value of the function itself for `arguments.callee` of a sloppy function.
    Function(Option<Expr>),
    /// A method: its own `this`, and the home object for `super`.
    Method(Option<ClassFrame>),
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
        (true, true) => Kind::AsyncGenerator,
        (false, true) => Kind::Generator,
        (true, false) => Kind::Async,
        (false, false) => Kind::Sync,
    }
}

/// The name that `NamedEvaluation` gives an anonymous function bound to `pattern`.
pub fn binding_name(pattern: &BindingPattern<'_>) -> Option<Expr> {
    match pattern {
        BindingPattern::BindingIdentifier(id) => Some(Expr::js_string(id.name.as_str())),
        _ => None,
    }
}

fn int(value: usize) -> Expr {
    Expr::Integer(i64::try_from(value).unwrap_or(0))
}

/// Whether a function reads `new.target`: in its own code or in an arrow function inside
/// it, which shares it.
pub struct UsesNewTarget(pub bool);

impl<'a> Visit<'a> for UsesNewTarget {
    fn visit_new_target(&mut self, _it: &NewTarget) {
        self.0 = true;
    }
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
    fn visit_class(&mut self, _it: &Class<'a>) {}
}
