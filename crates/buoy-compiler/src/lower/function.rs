//! Functions (section 4): parameters, defaults, rest parameters, and closures.

use oxc::ast::ast::{ArrowFunctionExpression, Expression, FormalParameters, Function, Statement};
use oxc::span::Span;

use super::rebind::strip;
use super::scope::{Scope, Target};
use super::{Frame, Lowerer, Tail};
use crate::erlang::{self, Clause, Expr};

/// A function body that lowering turns into an Erlang function or fun.
#[derive(Debug, Clone, Copy)]
pub enum Callable<'a> {
    Function(&'a Function<'a>),
    Arrow(&'a ArrowFunctionExpression<'a>),
}

enum Body<'a> {
    Block(&'a [Statement<'a>]),
    Expression(&'a Expression<'a>),
}

impl<'a> Callable<'a> {
    pub fn of(expr: &'a Expression<'a>) -> Option<Self> {
        match strip(expr) {
            Expression::FunctionExpression(function) => Some(Self::Function(function)),
            Expression::ArrowFunctionExpression(arrow) => Some(Self::Arrow(arrow)),
            _ => None,
        }
    }

    fn params(self) -> &'a FormalParameters<'a> {
        match self {
            Self::Function(function) => &function.params,
            Self::Arrow(arrow) => &arrow.params,
        }
    }

    fn body(self) -> Body<'a> {
        match self {
            Self::Function(function) => Body::Block(
                function
                    .body
                    .as_ref()
                    .map_or(&[][..], |body| &body.statements[..]),
            ),
            Self::Arrow(arrow) => match (arrow.get_expression(), arrow.get_function_body()) {
                (Some(expression), _) => Body::Expression(expression),
                (None, Some(body)) => Body::Block(&body.statements),
                (None, None) => Body::Block(&[]),
            },
        }
    }

    fn is_generator(self) -> bool {
        matches!(self, Self::Function(function) if function.generator)
    }

    fn is_async(self) -> bool {
        match self {
            Self::Function(function) => function.r#async,
            Self::Arrow(arrow) => arrow.r#async,
        }
    }

    fn is_arrow(self) -> bool {
        matches!(self, Self::Arrow(_))
    }

    fn span(self) -> Span {
        match self {
            Self::Function(function) => function.span,
            Self::Arrow(arrow) => arrow.span,
        }
    }
}

/// Whether `expr` is a function expression or an arrow function.
pub fn is_function_value(expr: &Expression<'_>) -> bool {
    matches!(
        strip(expr),
        Expression::FunctionExpression(_) | Expression::ArrowFunctionExpression(_)
    )
}

impl<'a> Lowerer<'a, '_> {
    /// A module-level function `'name'(Args)` (section 2).
    pub fn named_function(&mut self, name: &str, callable: Callable<'a>) -> erlang::Function {
        self.scope = Scope::default();
        self.frame = Frame::Function;
        self.targets.clear();
        self.rests.clear();
        self.checkpoints.clear();
        self.class = None;
        let body = self.function_body("Args", callable);
        erlang::Function {
            name: name.to_owned(),
            clauses: vec![Clause::new(Expr::var("Args"), body)],
        }
    }

    /// A function value: an Erlang fun that closes over the current versions. A named fun
    /// can call itself.
    pub fn closure(&mut self, name: Option<String>, callable: Callable<'a>) -> Expr {
        self.closure_with(name, callable, |_| {})
    }

    /// A function value whose body starts with the statements that `prelude` pushes.
    pub fn closure_with(
        &mut self,
        name: Option<String>,
        callable: Callable<'a>,
        prelude: impl FnOnce(&mut Self),
    ) -> Expr {
        let versions = self.scope.versions();
        let outer_seq = std::mem::take(&mut self.seq);
        let outer_frame = std::mem::replace(&mut self.frame, Frame::Function);
        let outer_targets = std::mem::take(&mut self.targets);
        let outer_rests = std::mem::take(&mut self.rests);
        let outer_checkpoints = std::mem::take(&mut self.checkpoints);
        let outer_generator = std::mem::replace(&mut self.generator, false);
        if !callable.is_arrow() {
            self.scope.forget(Target::This);
        }
        let args = self.scope.fresh("Args");
        prelude(self);
        self.closures.push(callable.span());
        let body = self.function_body(&args, callable);
        self.closures.pop();
        self.seq = outer_seq;
        self.frame = outer_frame;
        self.targets = outer_targets;
        self.rests = outer_rests;
        self.checkpoints = outer_checkpoints;
        self.generator = outer_generator;
        self.scope.restore(versions);
        Expr::Fun {
            name,
            clauses: vec![Clause::new(Expr::Var(args), body)],
        }
    }

    /// The body of a function whose argument list is the variable `args`.
    pub fn function_body(&mut self, args: &str, callable: Callable<'a>) -> Vec<Expr> {
        if callable.is_generator() {
            return self.generator_body(args, callable);
        }
        self.bind_params(callable.params(), args);
        match callable.body() {
            Body::Block(statements) => {
                let statements: Vec<&'a Statement<'a>> = statements.iter().collect();
                self.block_of(&statements, &Tail::Function);
            }
            Body::Expression(expression) => {
                let value = self.expr(expression);
                let value = self.frame_return(value);
                self.push(value);
            }
        }
        std::mem::take(&mut self.seq)
    }

    /// A generator function returns an Effect: `buoy_effect:generator(fun() -> Body end)`,
    /// whose body binds the parameters and runs when the Effect runs (section 13).
    fn generator_body(&mut self, args: &str, callable: Callable<'a>) -> Vec<Expr> {
        let span = callable.span();
        if callable.is_async() {
            self.unsupported(
                span,
                "async generators are not supported; a generator function is the body of an Effect, so drop `async` and run asynchronous work with `yield*`",
            );
        }
        if matches!(self.frame, Frame::Method | Frame::Constructor) {
            self.unsupported(
                span,
                "a generator method is not supported; return `Effect.gen(function* () { ... })` from a plain method",
            );
        }
        let outer = std::mem::replace(&mut self.generator, true);
        self.bind_params(callable.params(), args);
        if let Body::Block(statements) = callable.body() {
            let statements: Vec<&'a Statement<'a>> = statements.iter().collect();
            self.block_of(&statements, &Tail::Function);
        }
        self.generator = outer;
        let body = std::mem::take(&mut self.seq);
        vec![Expr::call(
            "buoy_effect",
            "generator",
            vec![Expr::Fun {
                name: None,
                clauses: vec![Clause {
                    patterns: Vec::new(),
                    guards: Vec::new(),
                    body: if body.is_empty() {
                        vec![Expr::undefined()]
                    } else {
                        body
                    },
                }],
            }],
        )]
    }

    /// Binds each parameter from the argument list (section 4).
    pub fn bind_params(&mut self, params: &'a FormalParameters<'a>, args: &str) {
        for (index, param) in params.items.iter().enumerate() {
            let arg = Expr::rt("arg", vec![position(index), Expr::var(args)]);
            let value = match &param.initializer {
                Some(default) => self.defaulted(arg, default),
                None => arg,
            };
            self.bind_pattern(&param.pattern, value);
        }
        if let Some(rest) = &params.rest {
            let value = Expr::rt("rest", vec![position(params.items.len()), Expr::var(args)]);
            self.bind_pattern(&rest.rest.argument, value);
        }
    }

    /// `value`, or `default` when `value` is `undefined`.
    pub fn defaulted(&mut self, value: Expr, default: &'a Expression<'a>) -> Expr {
        let default = self.sub_expr(default);
        let present = self.scope.temp();
        Expr::case(
            value,
            vec![
                Clause::new(Expr::undefined(), vec![default]),
                Clause::new(Expr::var(&present), vec![Expr::Var(present)]),
            ],
        )
    }
}

/// The 1-based position of the parameter at `index`.
fn position(index: usize) -> Expr {
    Expr::Integer(i64::try_from(index).map_or(i64::MAX, |index| index + 1))
}
