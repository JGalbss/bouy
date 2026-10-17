//! `try`, `catch`, and `finally`. A `try` without suspension points reifies its
//! completion; a `try` around `await` or `yield` is a region (see `suspend`).

use oxc::ast::ast::{
    ArrowFunctionExpression, BlockStatement, CatchClause, Class, Function, ReturnStatement,
    TryStatement,
};
use oxc::ast_visit::Visit;
use oxc::semantic::ScopeFlags;

use super::analyze::Suspends;
use super::context::{Cont, FinallyFrame, Kind, Lowerer, Reify, block, throw_value};
use super::stmt::jump_tuple;
use crate::erlang::{CatchClause as ErlangCatch, Clause, Expr};

impl<'a> Lowerer<'a, '_> {
    pub fn try_statement(&mut self, statement: &'a TryStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        self.frame.labels.clear();
        let mut suspends = Suspends::default();
        suspends.visit_block_statement(&statement.block);
        if let Some(handler) = &statement.handler {
            suspends.visit_catch_clause(handler);
        }
        if let Some(finalizer) = &statement.finalizer {
            suspends.visit_block_statement(finalizer);
        }
        if self.frame.kind == Kind::AsyncGenerator {
            // `return value` awaits the value in an async generator.
            let mut returns = ReturnsValue(false);
            returns.visit_try_statement(statement);
            suspends.0 |= returns.0;
        }
        if suspends.0 {
            self.region_try(statement, k)
        } else {
            self.reified_try(statement, k)
        }
    }

    /// A `try` without suspension points: an Erlang `try` whose body yields its
    /// completion, then a dispatch on the completion outside it.
    pub fn reified_try(&mut self, statement: &'a TryStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        let normal = Expr::atom("normal");
        let base = self.frame.targets.len();
        let order = self.next_order();
        self.frame.reify.push(Reify {
            base,
            order,
            jumps: Vec::new(),
        });
        let saved_env = self.frame.env.clone();
        let body = self.stmts(
            statement.block.body.iter().collect(),
            &Cont::Value(normal.clone()),
        );
        self.frame.env.clone_from(&saved_env);
        let mut code = Vec::new();
        let first = self.fresh("R");
        code.push(Expr::matches(
            Expr::var(first.clone()),
            self.raising_try(body),
        ));
        let mut result = Expr::var(first);
        if let Some(handler) = &statement.handler {
            let error = self.fresh("E");
            let saved = std::mem::take(&mut self.pre);
            if let Some(param) = &handler.param {
                self.declare_pattern(&param.pattern, Expr::var(error.clone()));
            }
            let mut catch = std::mem::replace(&mut self.pre, saved);
            catch.extend(self.stmts(
                handler.body.body.iter().collect(),
                &Cont::Value(normal.clone()),
            ));
            self.frame.env.clone_from(&saved_env);
            let catch = if statement.finalizer.is_some() {
                self.raising_try(catch)
            } else {
                block(catch)
            };
            let other = self.fresh("Other");
            let second = self.fresh("R");
            code.push(Expr::matches(
                Expr::var(second.clone()),
                Expr::case(
                    result,
                    vec![
                        Clause::new(
                            Expr::Tuple(vec![Expr::atom("$raised"), Expr::var(error)]),
                            vec![catch],
                        ),
                        Clause::new(Expr::var(other.clone()), vec![Expr::var(other)]),
                    ],
                ),
            ));
            result = Expr::var(second);
        }
        if let Some(finalizer) = &statement.finalizer {
            let finally = self.stmts(
                finalizer.body.iter().collect(),
                &Cont::Value(normal.clone()),
            );
            self.frame.env.clone_from(&saved_env);
            let completion = self.fresh("F");
            code.push(Expr::matches(Expr::var(completion.clone()), block(finally)));
            let third = self.fresh("R");
            let other = self.fresh("Other");
            code.push(Expr::matches(
                Expr::var(third.clone()),
                Expr::case(
                    Expr::var(completion),
                    vec![
                        Clause::new(normal.clone(), vec![result]),
                        Clause::new(Expr::var(other.clone()), vec![Expr::var(other)]),
                    ],
                ),
            ));
            result = Expr::var(third);
        }
        let reify = self.frame.reify.pop().unwrap_or(Reify {
            base,
            order,
            jumps: Vec::new(),
        });
        let value = self.fresh("V");
        let error = self.fresh("E");
        let mut clauses = vec![
            Clause::new(normal, self.jump(k)),
            Clause::new(
                Expr::tagged("return", Expr::var(value.clone())),
                vec![self.ret(Expr::var(value))],
            ),
            Clause::new(
                Expr::Tuple(vec![Expr::atom("$raised"), Expr::var(error.clone())]),
                vec![throw_value(Expr::var(error))],
            ),
        ];
        clauses.extend(self.jump_clauses(&reify.jumps));
        code.push(Expr::case(result, clauses));
        code
    }

    /// The clauses that go on with each jump out of a `try` or a `for...of`, after the
    /// variables that the target passes on are bound from the completion.
    fn jump_clauses(&mut self, jumps: &[(usize, bool)]) -> Vec<Clause> {
        let env = self.frame.env.clone();
        let mut clauses = Vec::new();
        for &(index, is_continue) in jumps {
            let vars = self.target_vars(index, is_continue);
            let params = self.rebind_params(&vars);
            let jump = self.jump_target(index, is_continue);
            self.frame.env.clone_from(&env);
            clauses.push(Clause::new(
                jump_tuple(index, is_continue, Expr::List(params)),
                jump,
            ));
        }
        clauses
    }

    /// `try Code catch error:R:S -> {'$raised', JsValue} end`.
    pub fn raising_try(&mut self, code: Vec<Expr>) -> Expr {
        let reason = self.fresh("Reason");
        let stack = self.fresh("Stack");
        Expr::Try {
            body: code,
            catches: vec![ErlangCatch {
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
        }
    }

    /// A `try` with suspension points: a region. Each segment of the try block runs
    /// inside an Erlang `try` whose handler runs the `catch` clause. With a `finally`
    /// block, the try block and the catch clause end by calling the `Finally` fun with
    /// their completion: it runs the block and then completes the same way.
    pub fn region_try(&mut self, statement: &'a TryStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        let saved_env = self.frame.env.clone();
        let depth = self.frame.region;
        let mut code = Vec::new();
        let finally = statement.finalizer.as_ref().map(|_| self.fresh("Finally"));
        if let Some(fun) = &finally {
            let order = self.next_order();
            self.frame.finally.push(FinallyFrame {
                fun: fun.clone(),
                order,
                base: self.frame.targets.len(),
                region: depth,
                jumps: Vec::new(),
                stays: None,
            });
        }
        let after = match &finally {
            Some(fun) => Cont::Call {
                fun: fun.clone(),
                args: vec![Expr::atom("normal")],
                vars: vec![],
                region: depth,
            },
            None => k.clone(),
        };
        // A throw in the catch clause, or in a try block without one, runs the finally
        // block with the throw completion.
        let throw_finally = finally.as_ref().map(|fun| {
            let (name, definition) = self.throw_finally(fun);
            code.push(definition);
            name
        });
        let handler = self.fresh("Handler");
        let error = self.fresh("E");
        let handler_body = match (&statement.handler, &throw_finally) {
            (Some(clause), _) => self.catch_body(clause, &error, throw_finally.as_deref(), &after),
            (None, Some(throw_finally)) => Expr::Apply(
                Box::new(Expr::var(throw_finally.clone())),
                vec![Expr::var(error.clone())],
            ),
            (None, None) => throw_value(Expr::var(error.clone())),
        };
        self.frame.env.clone_from(&saved_env);
        code.push(Expr::matches(
            Expr::var(handler.clone()),
            Expr::Fun {
                name: None,
                clauses: vec![Clause::new(Expr::var(error), vec![handler_body])],
            },
        ));
        self.frame.region += 1;
        self.frame.handlers.push(handler.clone());
        let body = self.stmts(statement.block.body.iter().collect(), &after);
        self.frame.handlers.pop();
        self.frame.region -= 1;
        self.frame.env.clone_from(&saved_env);
        let body = self.wrap_level(body, &handler, depth + 1);
        if let (Some(fun), Some(finalizer)) = (finally, &statement.finalizer) {
            let definition = self.finally_fun(&fun, finalizer, k);
            code.insert(0, definition);
        }
        self.frame.env = saved_env;
        code.push(body);
        code
    }

    /// `ThrowFinally = fun(E) -> Finally({throw, E}) end`, protected by the handlers
    /// around the `try`.
    fn throw_finally(&mut self, fun: &str) -> (String, Expr) {
        let outer = self.handler_chain();
        let name = self.fresh("ThrowFinally");
        let error = self.fresh("E");
        let call = Expr::Apply(
            Box::new(Expr::var(fun.to_owned())),
            vec![Expr::tagged("throw", Expr::var(error.clone()))],
        );
        let body = self.wrap_chain(vec![call], &outer);
        let definition = Expr::matches(
            Expr::var(name.clone()),
            Expr::Fun {
                name: None,
                clauses: vec![Clause::new(Expr::var(error), vec![body])],
            },
        );
        (name, definition)
    }

    /// The body of the handler of a region `try` with a `catch` clause: the clause, in a
    /// region of its own whose throws run the finally block when there is one.
    fn catch_body(
        &mut self,
        clause: &'a CatchClause<'a>,
        error: &str,
        throw_finally: Option<&str>,
        after: &Cont<'a>,
    ) -> Expr {
        let outer = self.handler_chain();
        let depth = self.frame.region;
        let saved = std::mem::take(&mut self.pre);
        if let Some(param) = &clause.param {
            self.declare_pattern(&param.pattern, Expr::var(error.to_owned()));
        }
        let mut catch = std::mem::replace(&mut self.pre, saved);
        match throw_finally {
            Some(throw_finally) => {
                self.frame.region += 1;
                self.frame.handlers.push(throw_finally.to_owned());
                let body = self.stmts(clause.body.body.iter().collect(), after);
                self.frame.handlers.pop();
                self.frame.region -= 1;
                catch.push(self.wrap_level(body, throw_finally, depth + 1));
            }
            None => catch.extend(self.stmts(clause.body.body.iter().collect(), after)),
        }
        let catch = self.seal(catch);
        self.wrap_chain(catch, &outer)
    }

    /// `Finally = fun(Completion) -> ... end`: the finally block, then the completion.
    fn finally_fun(&mut self, fun: &str, finalizer: &'a BlockStatement<'a>, k: &Cont<'a>) -> Expr {
        let env = self.frame.env.clone();
        let frame = self.frame.finally.pop();
        let completion = self.fresh("Completion");
        let then = self.fresh("Then");
        let dispatch = match &frame {
            Some(frame) => self.completion_dispatch(&completion, frame, k),
            None => vec![],
        };
        self.frame.env.clone_from(&env);
        let mut body = vec![Expr::matches(
            Expr::var(then.clone()),
            Expr::Fun {
                name: None,
                clauses: vec![Clause {
                    patterns: vec![],
                    guards: vec![],
                    body: dispatch,
                }],
            },
        )];
        body.extend(self.stmts(
            finalizer.body.iter().collect(),
            &Cont::Call {
                fun: then,
                args: vec![],
                vars: vec![],
                region: self.frame.region,
            },
        ));
        self.frame.env = env;
        Expr::matches(
            Expr::var(fun.to_owned()),
            Expr::Fun {
                name: None,
                clauses: vec![Clause::new(Expr::var(completion), body)],
            },
        )
    }

    /// Completes a statement the way `completion` says, after its `finally` code ran:
    /// normally with `k`, by a throw, a return, or a jump that left it. A jump carries
    /// the variables that its target passes on.
    pub fn completion_dispatch(
        &mut self,
        completion: &str,
        frame: &FinallyFrame,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let env = self.frame.env.clone();
        let value = self.fresh("V");
        let error = self.fresh("E");
        let mut clauses = vec![
            Clause::new(Expr::atom("normal"), self.jump(k)),
            Clause::new(
                Expr::tagged("throw", Expr::var(error.clone())),
                vec![throw_value(Expr::var(error))],
            ),
            Clause::new(
                Expr::tagged("return", Expr::var(value.clone())),
                vec![self.ret(Expr::var(value))],
            ),
        ];
        self.frame.env.clone_from(&env);
        clauses.extend(self.jump_clauses(&frame.jumps));
        vec![Expr::case(Expr::var(completion.to_owned()), clauses)]
    }
}

/// Whether the code returns a value, outside nested functions.
struct ReturnsValue(bool);

impl<'a> Visit<'a> for ReturnsValue {
    fn visit_return_statement(&mut self, it: &ReturnStatement<'a>) {
        if it.argument.is_some() {
            self.0 = true;
        }
    }
    fn visit_function(&mut self, _it: &Function<'a>, _flags: ScopeFlags) {}
    fn visit_arrow_function_expression(&mut self, _it: &ArrowFunctionExpression<'a>) {}
    fn visit_class(&mut self, _it: &Class<'a>) {}
}
