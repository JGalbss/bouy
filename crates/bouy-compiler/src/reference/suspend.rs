//! Suspension points: `await` and `yield` leave a marker, and `seal` splits a body at
//! each marker into the continuation fun that a promise reaction or `next()` calls later.
//! A `try` around a suspension point is a region: `wrap_with` runs each segment inside an
//! Erlang `try` whose handler is the `catch` clause.

use super::context::{Kind, Lowerer, Ret, block, throw_value};
use crate::erlang::{CatchClause, Clause, Expr};

impl Lowerer<'_, '_> {
    /// The code of an async function body: `bouy_jobs:async_call(fun(Resolve, Reject) ->
    /// ... end)`, its first segment wrapped so a throw rejects.
    pub fn async_body(&mut self, lower: impl FnOnce(&mut Self) -> Vec<Expr>) -> Vec<Expr> {
        let resolve = self.fresh("Resolve");
        let reject = self.fresh("Reject");
        self.frame.kind = Kind::Async;
        self.frame.ret = Ret::Resolve(resolve.clone());
        self.frame.reject = Some(reject.clone());
        let code = lower(self);
        let wrapped = self.wrap_with(code, Some(reject.clone()));
        vec![Expr::call(
            "bouy_jobs",
            "async_call",
            vec![Expr::Fun {
                name: None,
                clauses: vec![Clause {
                    patterns: vec![Expr::var(resolve), Expr::var(reject)],
                    guards: vec![],
                    body: vec![wrapped],
                }],
            }],
        )]
    }

    /// Wraps `code` so that a throw goes to `handler`, and `{'$k', F, A}` runs `F`
    /// outside the Erlang `try`. Without a handler the code is unchanged.
    pub fn wrap_with(&mut self, code: Vec<Expr>, handler: Option<String>) -> Expr {
        let Some(handler) = handler else {
            return block(code);
        };
        let reason = self.fresh("Reason");
        let stack = self.fresh("Stack");
        let error = self.fresh("E");
        let fun = self.fresh("F");
        let args = self.fresh("A");
        let other = self.fresh("Other");
        let attempt = Expr::Try {
            body: code,
            catches: vec![CatchClause {
                class: Expr::atom("error"),
                reason: Expr::var(reason.clone()),
                stack: stack.clone(),
                body: vec![Expr::Tuple(vec![
                    Expr::atom("$raised"),
                    Expr::call(
                        "bouy_ref",
                        "caught",
                        vec![Expr::var(reason), Expr::var(stack)],
                    ),
                ])],
            }],
            after: vec![],
        };
        Expr::case(
            attempt,
            vec![
                Clause::new(
                    Expr::Tuple(vec![Expr::atom("$raised"), Expr::var(error.clone())]),
                    vec![Expr::Apply(
                        Box::new(Expr::var(handler)),
                        vec![Expr::var(error)],
                    )],
                ),
                Clause::new(
                    Expr::Tuple(vec![
                        Expr::atom("$k"),
                        Expr::var(fun.clone()),
                        Expr::var(args.clone()),
                    ]),
                    vec![Expr::call(
                        "erlang",
                        "apply",
                        vec![Expr::var(fun), Expr::var(args)],
                    )],
                ),
                Clause::new(Expr::var(other.clone()), vec![Expr::var(other)]),
            ],
        )
    }

    /// The fun that receives a throw at this point: the handler of the innermost
    /// suspending `try`, or Reject. None in a generator outside such a `try`.
    pub fn handler(&self) -> Option<String> {
        self.frame
            .handlers
            .last()
            .cloned()
            .or_else(|| self.frame.reject.clone())
    }

    /// Splits `code` at its first suspension marker: the rest of the code becomes the
    /// continuation fun of the `await` or the `yield`.
    pub fn seal(&mut self, mut code: Vec<Expr>) -> Vec<Expr> {
        let Some(index) = code.iter().position(is_marker) else {
            return code;
        };
        let after = code.split_off(index + 1);
        let Some(Expr::Call { function, args, .. }) = code.pop() else {
            return code;
        };
        let after = self.seal(after);
        let [Expr::Var(var), value, handler] = <[Expr; 3]>::try_from(args).unwrap_or([
            Expr::var("_"),
            Expr::undefined(),
            Expr::atom("none"),
        ]) else {
            return code;
        };
        let handler = match handler {
            Expr::Var(name) => Some(name),
            _ => None,
        };
        let resumed = self.wrap_with(after, handler.clone());
        if function == "await" {
            let reject = handler.map_or_else(Expr::undefined, Expr::var);
            code.push(Expr::call(
                "bouy_jobs",
                "await",
                vec![
                    value,
                    Expr::Fun {
                        name: None,
                        clauses: vec![Clause::new(Expr::var(var), vec![resumed])],
                    },
                    reject,
                ],
            ));
            return code;
        }
        let resumption = self.fresh("Resumption");
        let thrown = self.fresh("Thrown");
        let returned = self.fresh("Returned");
        let throw = match handler {
            Some(handler) => Expr::Apply(
                Box::new(Expr::var(handler)),
                vec![Expr::var(thrown.clone())],
            ),
            None => throw_value(Expr::var(thrown.clone())),
        };
        let continuation = Expr::Fun {
            name: None,
            clauses: vec![Clause::new(
                Expr::var(resumption.clone()),
                vec![Expr::case(
                    Expr::var(resumption),
                    vec![
                        Clause::new(Expr::tagged("next", Expr::var(var)), vec![resumed]),
                        Clause::new(Expr::tagged("throw", Expr::var(thrown)), vec![throw]),
                        Clause::new(
                            Expr::tagged("return", Expr::var(returned.clone())),
                            vec![Expr::tagged("done", Expr::var(returned))],
                        ),
                    ],
                )],
            )],
        };
        code.push(Expr::Tuple(vec![Expr::atom("yield"), value, continuation]));
        code
    }

    /// A suspension marker: `seal` turns it into an `await` or a `yield`.
    pub fn marker(&mut self, kind: &str, value: Expr) -> Expr {
        let var = self.fresh("Resumed");
        let handler = self.handler().map_or_else(|| Expr::atom("none"), Expr::var);
        self.pre.push(Expr::call(
            "$suspend",
            kind,
            vec![Expr::var(var.clone()), value, handler],
        ));
        Expr::var(var)
    }
}

pub fn is_marker(expr: &Expr) -> bool {
    matches!(expr, Expr::Call { module: Some(module), .. } if module == "$suspend")
}
