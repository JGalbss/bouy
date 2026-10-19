//! Suspension points: `await`, `yield`, and `yield*` leave a marker, and `seal` splits a
//! body at each marker into the continuation fun that a promise reaction or a generator
//! resumption calls later.
//!
//! Code at region depth `d` runs protected by a chain of handlers: the Reject fun of an
//! async function at level 0, then the handler of each suspending `try` around it at
//! levels 1 to `d`. Each level is an Erlang `try` (`wrap_level`): a throw inside it goes
//! to its handler, and a continuation of a lower level returns `{'$k', F, A, Level}` so
//! that the wrapper of the level above `Level` calls `F` outside the inner `try`s. A fun
//! that the job loop or a generator resumption calls runs outside every Erlang `try`, so
//! its body is wrapped in the whole chain (`wrap_chain`), and so is every handler.

use super::context::{Kind, Lowerer, block, throw_value};
use crate::erlang::{CatchClause, Clause, Expr};

impl Lowerer<'_, '_> {
    /// The code of an async function body: `buoy_jobs:async_call(fun(Resolve, Reject) ->
    /// ... end)`, its first segment wrapped so a throw rejects.
    pub fn async_body(&mut self, lower: impl FnOnce(&mut Self) -> Vec<Expr>) -> Vec<Expr> {
        let resolve = self.fresh("Resolve");
        let reject = self.fresh("Reject");
        self.frame.kind = Kind::Async;
        self.frame.ret = super::context::Ret::Resolve(resolve.clone());
        self.frame.reject = Some(reject.clone());
        let code = lower(self);
        let wrapped = self.wrap_level(code, &reject, 0);
        vec![Expr::call(
            "buoy_jobs",
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

    /// The handlers that protect code at this point, outermost first, with their levels.
    pub fn handler_chain(&self) -> Vec<(String, usize)> {
        let mut chain = Vec::new();
        if let Some(reject) = &self.frame.reject {
            chain.push((reject.clone(), 0));
        }
        for (index, handler) in self.frame.handlers.iter().enumerate() {
            chain.push((handler.clone(), index + 1));
        }
        chain
    }

    /// One level of the chain: a throw in `code` goes to `handler`, and a continuation of
    /// the level below runs outside the Erlang `try`.
    pub fn wrap_level(&mut self, code: Vec<Expr>, handler: &str, level: usize) -> Expr {
        let reason = self.fresh("Reason");
        let stack = self.fresh("Stack");
        let error = self.fresh("E");
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
                        "buoy_ref",
                        "caught",
                        vec![Expr::var(reason), Expr::var(stack)],
                    ),
                ])],
            }],
            after: vec![],
        };
        let mut clauses = vec![Clause::new(
            Expr::Tuple(vec![Expr::atom("$raised"), Expr::var(error.clone())]),
            vec![Expr::Apply(
                Box::new(Expr::var(handler.to_owned())),
                vec![Expr::var(error)],
            )],
        )];
        if level > 0 {
            let fun = self.fresh("F");
            let args = self.fresh("A");
            clauses.push(Clause::new(
                Expr::Tuple(vec![
                    Expr::atom("$k"),
                    Expr::var(fun.clone()),
                    Expr::var(args.clone()),
                    Expr::Integer(i64::try_from(level - 1).unwrap_or(0)),
                ]),
                vec![Expr::call(
                    "erlang",
                    "apply",
                    vec![Expr::var(fun), Expr::var(args)],
                )],
            ));
        }
        clauses.push(Clause::new(
            Expr::var(other.clone()),
            vec![Expr::var(other)],
        ));
        Expr::case(attempt, clauses)
    }

    /// Wraps `code` in every level of `chain`, for a fun that runs outside the Erlang
    /// `try`s of the code that made it.
    pub fn wrap_chain(&mut self, code: Vec<Expr>, chain: &[(String, usize)]) -> Expr {
        let mut code = code;
        for (handler, level) in chain.iter().rev() {
            code = vec![self.wrap_level(code, handler, *level)];
        }
        block(code)
    }

    /// A suspension marker: `seal` turns it into an `await`, a `yield`, or a `yield*`. It
    /// holds the chain at this point, and for a `yield` the fun that returns from the
    /// function here, for a resumption with `return`.
    pub fn marker(&mut self, kind: &str, value: Expr) -> Expr {
        let var = self.fresh("Resumed");
        let chain = Expr::List(
            self.handler_chain()
                .into_iter()
                .map(|(handler, level)| {
                    Expr::Tuple(vec![
                        Expr::var(handler),
                        Expr::Integer(i64::try_from(level).unwrap_or(0)),
                    ])
                })
                .collect(),
        );
        let on_return = if kind == "await" {
            Expr::atom("none")
        } else {
            let returned = self.fresh("Returned");
            let saved = std::mem::take(&mut self.pre);
            let ret = self.ret(Expr::var(returned.clone()));
            let mut body = std::mem::replace(&mut self.pre, saved);
            body.push(ret);
            Expr::Fun {
                name: None,
                clauses: vec![Clause::new(Expr::var(returned), body)],
            }
        };
        self.pre.push(Expr::call(
            "$suspend",
            kind,
            vec![Expr::var(var.clone()), value, chain, on_return],
        ));
        Expr::var(var)
    }

    /// Splits `code` at its first suspension point: the rest of the code becomes the
    /// continuation fun of the `await` or the `yield`. A suspension point inside a branch
    /// of a conditional expression makes the code after the conditional a join fun that
    /// each branch calls with its value.
    pub fn seal(&mut self, mut code: Vec<Expr>) -> Vec<Expr> {
        let Some(index) = code.iter().position(holds_marker) else {
            return code;
        };
        if is_region(&code[index]) {
            return self.seal_region(code, index);
        }
        if !is_marker(&code[index]) {
            return self.seal_conditional(code, index);
        }
        let after = code.split_off(index + 1);
        let Some(Expr::Call { function, args, .. }) = code.pop() else {
            return code;
        };
        let after = self.seal(after);
        let Ok([Expr::Var(var), value, Expr::List(chain), on_return]) = <[Expr; 4]>::try_from(args)
        else {
            return code;
        };
        let chain: Vec<(String, usize)> = chain
            .into_iter()
            .filter_map(|link| match link {
                Expr::Tuple(mut parts) if parts.len() == 2 => {
                    let level = match parts.pop() {
                        Some(Expr::Integer(level)) => usize::try_from(level).unwrap_or(0),
                        _ => 0,
                    };
                    match parts.pop() {
                        Some(Expr::Var(handler)) => Some((handler, level)),
                        _ => None,
                    }
                }
                _ => None,
            })
            .collect();
        let reject = chain
            .last()
            .map_or_else(Expr::undefined, |(handler, _)| Expr::var(handler.clone()));
        match function.as_str() {
            "await" => {
                let resumed = self.wrap_chain(after, &chain);
                code.push(Expr::call(
                    "buoy_jobs",
                    "await",
                    vec![value, fun1(&var, vec![resumed]), reject],
                ));
            }
            "yield" => {
                let resumption = self.resumption(&var, after, &chain, on_return);
                if let Some(yield_fun) = self.frame.yield_fun.clone() {
                    // An async generator awaits the operand of `yield` first.
                    let awaited = self.fresh("Awaited");
                    let step = Expr::Apply(
                        Box::new(Expr::var(yield_fun)),
                        vec![Expr::var(awaited.clone()), resumption],
                    );
                    code.push(Expr::call(
                        "buoy_jobs",
                        "await",
                        vec![value, fun1(&awaited, vec![step]), reject],
                    ));
                } else {
                    code.push(Expr::Tuple(vec![Expr::atom("yield"), value, resumption]));
                }
            }
            _ => {
                let done = {
                    let resumed = self.wrap_chain(after, &chain);
                    fun1(&var, vec![resumed])
                };
                let thrown = self.fresh("Thrown");
                let throw = {
                    let body =
                        self.wrap_chain(vec![throw_value(Expr::var(thrown.clone()))], &chain);
                    fun1(&thrown, vec![body])
                };
                let returned = self.fresh("Returned");
                let ret = {
                    let body = self.wrap_chain(
                        vec![Expr::Apply(
                            Box::new(on_return),
                            vec![Expr::var(returned.clone())],
                        )],
                        &chain,
                    );
                    fun1(&returned, vec![body])
                };
                match self.frame.yield_fun.clone() {
                    Some(yield_fun) => code.push(Expr::call(
                        "buoy_ref_generator",
                        "yield_star_async",
                        vec![value, Expr::var(yield_fun), done, throw, ret],
                    )),
                    None => code.push(Expr::call(
                        "buoy_ref_generator",
                        "yield_star",
                        vec![value, done, throw, ret],
                    )),
                }
            }
        }
        code
    }

    /// The continuation of a `yield`: `fun(Resumption)`, which goes on with `next`,
    /// throws with `throw`, and returns from the generator with `return`, after an await
    /// of the value in an async generator.
    fn resumption(
        &mut self,
        var: &str,
        after: Vec<Expr>,
        chain: &[(String, usize)],
        on_return: Expr,
    ) -> Expr {
        let resumption = self.fresh("Resumption");
        let thrown = self.fresh("Thrown");
        let returned = self.fresh("Returned");
        let ret = if self.frame.yield_fun.is_some() {
            let awaited = self.fresh("Awaited");
            let body = self.wrap_chain(
                vec![Expr::Apply(
                    Box::new(on_return),
                    vec![Expr::var(awaited.clone())],
                )],
                chain,
            );
            let reject = chain
                .last()
                .map_or_else(Expr::undefined, |(handler, _)| Expr::var(handler.clone()));
            Expr::call(
                "buoy_jobs",
                "await",
                vec![
                    Expr::var(returned.clone()),
                    fun1(&awaited, vec![body]),
                    reject,
                ],
            )
        } else {
            Expr::Apply(Box::new(on_return), vec![Expr::var(returned.clone())])
        };
        let dispatch = Expr::case(
            Expr::var(resumption.clone()),
            vec![
                Clause::new(Expr::tagged("next", Expr::var(var.to_owned())), after),
                Clause::new(
                    Expr::tagged("throw", Expr::var(thrown.clone())),
                    vec![throw_value(Expr::var(thrown))],
                ),
                Clause::new(Expr::tagged("return", Expr::var(returned)), vec![ret]),
            ],
        );
        let body = self.wrap_chain(vec![dispatch], chain);
        fun1(&resumption, vec![body])
    }

    /// `Pattern = $region:enter(Handler, Level, Body)` with a suspension point in the
    /// body: the body runs as a region of `Level` whose last value goes to `Join`, the
    /// code after it, which runs outside the region.
    fn seal_region(&mut self, mut code: Vec<Expr>, index: usize) -> Vec<Expr> {
        let after = code.split_off(index + 1);
        let Some(Expr::Match(pattern, call)) = code.pop() else {
            return code;
        };
        let Expr::Call { args, .. } = *call else {
            return code;
        };
        let Ok(
            [
                Expr::Var(handler),
                Expr::Integer(level),
                Expr::Block(mut body),
            ],
        ) = <[Expr; 3]>::try_from(args)
        else {
            return code;
        };
        let join = self.fresh("Join");
        let after = self.seal(after);
        code.push(Expr::matches(
            Expr::var(join.clone()),
            Expr::Fun {
                name: None,
                clauses: vec![Clause::new(*pattern, after)],
            },
        ));
        let value = body.pop().unwrap_or_else(Expr::undefined);
        body.push(Expr::Tuple(vec![
            Expr::atom("$k"),
            Expr::var(join),
            Expr::List(vec![value]),
            Expr::Integer(level - 1),
        ]));
        let body = self.seal(body);
        let level = usize::try_from(level).unwrap_or(1);
        code.push(self.wrap_level(body, &handler, level));
        code
    }

    /// `T = case ... end` with a suspension point in a clause: the code after it becomes
    /// `Join(T)`, and each clause ends with a call of `Join` with its value.
    fn seal_conditional(&mut self, mut code: Vec<Expr>, index: usize) -> Vec<Expr> {
        let after = code.split_off(index + 1);
        let Some(conditional) = code.pop() else {
            return code;
        };
        let (result, case) = match conditional {
            Expr::Match(pattern, value) => (*pattern, *value),
            other => (Expr::var("_"), other),
        };
        let Expr::Case(subject, clauses) = case else {
            self.reporter.report(
                oxc::span::Span::default(),
                crate::diagnostic::Code::Unsupported,
                "`await` or `yield` inside this expression is not supported by the reference-semantics prototype",
            );
            return code;
        };
        if after.is_empty() {
            // A case in tail position, such as the dispatch of a `switch`: each clause
            // ends the code itself.
            let clauses = clauses
                .into_iter()
                .map(|mut clause| {
                    clause.body = self.seal(clause.body);
                    clause
                })
                .collect();
            code.push(Expr::Case(subject, clauses));
            return code;
        }
        let join = self.fresh("Join");
        let after = self.seal(after);
        code.push(Expr::matches(
            Expr::var(join.clone()),
            Expr::Fun {
                name: None,
                clauses: vec![Clause::new(result, after)],
            },
        ));
        let clauses = clauses
            .into_iter()
            .map(|mut clause| {
                let value = clause.body.pop().unwrap_or_else(Expr::undefined);
                clause
                    .body
                    .push(Expr::Apply(Box::new(Expr::var(join.clone())), vec![value]));
                clause.body = self.seal(clause.body);
                clause
            })
            .collect();
        code.push(Expr::Case(subject, clauses));
        code
    }
}

fn fun1(param: &str, body: Vec<Expr>) -> Expr {
    Expr::Fun {
        name: None,
        clauses: vec![Clause::new(Expr::var(param.to_owned()), body)],
    }
}

/// `Pattern = $region:enter(...)`: a region of an array pattern that suspends.
fn is_region(expr: &Expr) -> bool {
    matches!(expr, Expr::Match(_, call) if matches!(&**call, Expr::Call { module: Some(module), .. } if module == "$region"))
}

pub fn is_marker(expr: &Expr) -> bool {
    matches!(expr, Expr::Call { module: Some(module), .. } if module == "$suspend")
}

/// Whether the expression holds a suspension marker that `seal` has not turned into a
/// continuation yet.
pub fn holds_marker(expr: &Expr) -> bool {
    if is_marker(expr) {
        return true;
    }
    match expr {
        Expr::Match(_, value) | Expr::Not(value) | Expr::Site(_, value) => holds_marker(value),
        Expr::Case(subject, clauses) => {
            holds_marker(subject)
                || clauses
                    .iter()
                    .any(|clause| clause.body.iter().any(holds_marker))
        }
        Expr::Block(items) | Expr::List(items) | Expr::Tuple(items) => {
            items.iter().any(holds_marker)
        }
        Expr::Call { args, .. } => args.iter().any(holds_marker),
        Expr::Apply(fun, args) => holds_marker(fun) || args.iter().any(holds_marker),
        Expr::Try { body, .. } => body.iter().any(holds_marker),
        Expr::Op(_, left, right) => holds_marker(left) || holds_marker(right),
        _ => false,
    }
}
