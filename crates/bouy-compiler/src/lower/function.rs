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

    fn generator(self) -> Option<Span> {
        match self {
            Self::Function(function) if function.generator => Some(function.span),
            _ => None,
        }
    }

    fn is_arrow(self) -> bool {
        matches!(self, Self::Arrow(_))
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
        let versions = self.scope.versions();
        let outer_seq = std::mem::take(&mut self.seq);
        let outer_frame = std::mem::replace(&mut self.frame, Frame::Function);
        let outer_targets = std::mem::take(&mut self.targets);
        let outer_rests = std::mem::take(&mut self.rests);
        let outer_checkpoints = std::mem::take(&mut self.checkpoints);
        if !callable.is_arrow() {
            self.scope.forget(Target::This);
        }
        let args = self.scope.fresh("Args");
        let body = self.function_body(&args, callable);
        self.seq = outer_seq;
        self.frame = outer_frame;
        self.targets = outer_targets;
        self.rests = outer_rests;
        self.checkpoints = outer_checkpoints;
        self.scope.restore(versions);
        Expr::Fun {
            name,
            clauses: vec![Clause::new(Expr::Var(args), body)],
        }
    }

    /// The body of a function whose argument list is the variable `args`.
    pub fn function_body(&mut self, args: &str, callable: Callable<'a>) -> Vec<Expr> {
        if let Some(span) = callable.generator() {
            self.unsupported(
                span,
                "generators are not supported yet; Effect.gen and async * methods come in a later stage",
            );
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
