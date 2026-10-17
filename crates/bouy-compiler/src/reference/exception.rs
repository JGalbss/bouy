//! `try`, `catch`, and `finally`. A `try` without suspension points reifies its
//! completion; a `try` around `await` or `yield` is a region (see `suspend`).

use oxc::ast::ast::TryStatement;
use oxc::ast_visit::Visit;

use super::analyze::Suspends;
use super::context::{Cont, Lowerer, Reify, block, throw_value};
use super::stmt::jump_tuple;
use crate::erlang::{CatchClause, Clause, Expr};

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
        self.frame.reify.push(Reify {
            base,
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
        for (index, is_continue) in reify.jumps {
            let code = self.jump_target(index, is_continue);
            clauses.push(Clause::new(jump_tuple(index, is_continue), code));
        }
        code.push(Expr::case(result, clauses));
        code
    }

    /// `try Code catch error:R:S -> {'$raised', JsValue} end`.
    pub fn raising_try(&mut self, code: Vec<Expr>) -> Expr {
        let reason = self.fresh("Reason");
        let stack = self.fresh("Stack");
        Expr::Try {
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
        }
    }

    /// A `try` with suspension points: a region. Each segment of the body runs inside
    /// an Erlang `try` whose handler runs the `catch` clause.
    pub fn region_try(&mut self, statement: &'a TryStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        if statement.finalizer.is_some() {
            self.unsupported(statement.span, "`finally` around `await` or `yield`");
            return vec![Expr::undefined()];
        }
        let Some(handler) = &statement.handler else {
            return vec![Expr::undefined()];
        };
        let name = self.fresh("Handler");
        let error = self.fresh("E");
        let saved_env = self.frame.env.clone();
        let saved = std::mem::take(&mut self.pre);
        if let Some(param) = &handler.param {
            self.declare_pattern(&param.pattern, Expr::var(error.clone()));
        }
        let mut catch = std::mem::replace(&mut self.pre, saved);
        catch.extend(self.stmts(handler.body.body.iter().collect(), k));
        self.frame.env.clone_from(&saved_env);
        let outer = self.handler();
        let catch = self.wrap_with(catch, outer);
        let mut code = vec![Expr::matches(
            Expr::var(name.clone()),
            Expr::Fun {
                name: None,
                clauses: vec![Clause::new(Expr::var(error), vec![catch])],
            },
        )];
        self.frame.region += 1;
        self.frame.handlers.push(name.clone());
        let body = self.stmts(statement.block.body.iter().collect(), k);
        self.frame.handlers.pop();
        self.frame.region -= 1;
        self.frame.env = saved_env;
        code.push(self.wrap_with(body, Some(name)));
        code
    }
}
