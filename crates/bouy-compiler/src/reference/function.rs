//! Functions: parameters, bodies, `return`, and the function values of arrows,
//! function expressions, and object literal methods.

use oxc::ast::ast::{
    ArrowFunctionExpression, Expression, FormalParameters, Function, FunctionBody,
};

use super::context::{ClassFrame, Cont, Frame, Kind, Lowerer, Ret};
use crate::erlang::{Clause, Expr};

impl<'a> Lowerer<'a, '_> {
    /// Lowers a function: returns the names of its `This` and `Args` parameters and its
    /// body.
    pub fn function_code(
        &mut self,
        params: &'a FormalParameters<'a>,
        body: FnBody<'a>,
        kind: Kind,
        callee: Callee,
    ) -> (String, String, Vec<Expr>) {
        let this_param = self.fresh("This");
        let args = self.fresh("Args");
        let outer = std::mem::take(&mut self.frame);
        let outer_pre = std::mem::take(&mut self.pre);
        let (this, class) = match callee {
            Callee::Arrow => (outer.this.clone(), outer.class.clone()),
            Callee::Function(class) => (Some(this_param.clone()), class),
        };
        self.frame = Frame {
            env: outer.env.clone(),
            this,
            kind,
            class,
            ..Frame::default()
        };
        let code = match kind {
            Kind::Sync => {
                let mut code = self.params(params, &args);
                code.extend(self.body(body));
                code
            }
            Kind::Async => {
                let args_var = args.clone();
                self.async_body(move |me| {
                    let mut code = me.params(params, &args_var);
                    code.extend(me.body(body));
                    code
                })
            }
            Kind::Generator => {
                let mut code = self.params(params, &args);
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
        self.frame = outer;
        self.pre = outer_pre;
        (this_param, args, code)
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
                    let fallback = self.branch(|me| me.expr(default));
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

    /// The function value of an object literal method: its own `this`.
    pub fn method_value(&mut self, value: &'a Expression<'a>) -> Expr {
        match value {
            Expression::FunctionExpression(function) => {
                let fun = self.function_fun(function, None);
                self.bind(Expr::call("bouy_ref", "fn", vec![fun]))
            }
            other => self.expr(other),
        }
    }

    pub fn arrow(&mut self, arrow: &'a ArrowFunctionExpression<'a>) -> Expr {
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
        );
        let fun = fun2(this_param, args, code);
        self.bind(Expr::call("bouy_ref", "fn", vec![fun]))
    }

    pub fn function_expression(&mut self, function: &'a Function<'a>) -> Expr {
        let fun = self.function_fun(function, None);
        let name = function
            .id
            .as_ref()
            .map_or_else(String::new, |id| id.name.to_string());
        let length = function
            .params
            .items
            .iter()
            .take_while(|param| param.initializer.is_none())
            .count();
        self.bind(Expr::call(
            "bouy_ref",
            "named_fn",
            vec![
                fun,
                Expr::js_string(&name),
                Expr::Integer(i64::try_from(length).unwrap_or(0)),
            ],
        ))
    }

    /// The Erlang fun of a non-arrow function: `fun(This, Args) -> ... end`.
    pub fn function_fun(&mut self, function: &'a Function<'a>, class: Option<ClassFrame>) -> Expr {
        let Some(body) = &function.body else {
            return Expr::undefined();
        };
        let (this_param, args, code) = self.function_code(
            &function.params,
            FnBody::Block(body),
            kind_of(function.r#async, function.generator),
            Callee::Function(class),
        );
        fun2(this_param, args, code)
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

pub fn kind_of(is_async: bool, generator: bool) -> Kind {
    match (is_async, generator) {
        (_, true) => Kind::Generator,
        (true, false) => Kind::Async,
        (false, false) => Kind::Sync,
    }
}

pub fn fun2(this: String, args: String, body: Vec<Expr>) -> Expr {
    Expr::Fun {
        name: None,
        clauses: vec![Clause {
            patterns: vec![Expr::var(this), Expr::var(args)],
            guards: vec![],
            body,
        }],
    }
}
