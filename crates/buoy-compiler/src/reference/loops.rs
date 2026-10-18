//! Loops: `while`, `do...while`, `for`, `for...of`, and `for...in`. A loop is a named
//! fun that calls itself with the versions of the variables its body changes.

use oxc::ast::ast::{
    DoWhileStatement, ForInStatement, ForOfStatement, ForStatement, ForStatementInit,
    ForStatementLeft, Statement, VariableDeclarationKind, WhileStatement,
};
use oxc::ast_visit::Visit;
use oxc::semantic::SymbolId;
use oxc::span::{GetSpan, Span};

use super::context::{
    Cont, FinallyFrame, Lowerer, Target, TargetKind, block, boolean_case, throw_value,
};
use crate::erlang::{Clause, Expr};

impl<'a> Lowerer<'a, '_> {
    /// `(fun Loop(Params) -> Body end)(Initial)`.
    pub fn loop_call(name: String, params: Vec<Expr>, body: Vec<Expr>, initial: Vec<Expr>) -> Expr {
        Expr::Apply(
            Box::new(Expr::Fun {
                name: Some(name),
                clauses: vec![Clause {
                    patterns: params,
                    guards: vec![],
                    body,
                }],
            }),
            initial,
        )
    }

    pub fn while_statement(
        &mut self,
        statement: &'a WhileStatement<'a>,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let labels = std::mem::take(&mut self.frame.labels);
        let vars = self.assigned_in(statement.span, |visitor| {
            visitor.visit_expression(&statement.test);
            visitor.visit_statement(&statement.body);
        });
        let initial: Vec<Expr> = vars.iter().map(|v| self.carried(*v)).collect();
        let fun = self.fresh("Loop");
        let saved_env = self.frame.env.clone();
        let params = self.rebind_params(&vars);
        let again = Cont::Call {
            fun: fun.clone(),
            args: vec![],
            vars: vars.clone(),
            region: self.frame.region,
        };
        self.frame.targets.push(Target {
            kind: TargetKind::Loop,
            labels,
            brk: k.clone(),
            cont: Some(again.clone()),
        });
        let test = self.test(&statement.test);
        let mut body = std::mem::take(&mut self.pre);
        let yes = self.arm(&statement.body, &again);
        let no = self.jump(k);
        body.push(boolean_case(test, yes, no));
        self.frame.targets.pop();
        let body = self.seal(body);
        self.frame.env = saved_env;
        vec![Self::loop_call(fun, params, body, initial)]
    }

    pub fn do_while_statement(
        &mut self,
        statement: &'a DoWhileStatement<'a>,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let labels = std::mem::take(&mut self.frame.labels);
        let vars = self.assigned_in(statement.span, |visitor| {
            visitor.visit_expression(&statement.test);
            visitor.visit_statement(&statement.body);
        });
        let initial: Vec<Expr> = vars.iter().map(|v| self.carried(*v)).collect();
        let fun = self.fresh("Loop");
        let saved_env = self.frame.env.clone();
        let params = self.rebind_params(&vars);
        let again = Cont::Test {
            test: &statement.test,
            fun: fun.clone(),
            vars: vars.clone(),
            exit: Box::new(k.clone()),
            region: self.frame.region,
        };
        self.frame.targets.push(Target {
            kind: TargetKind::Loop,
            labels,
            brk: k.clone(),
            cont: Some(again.clone()),
        });
        let body = self.arm(&statement.body, &again);
        self.frame.targets.pop();
        self.frame.env = saved_env;
        vec![Self::loop_call(fun, params, body, initial)]
    }

    pub fn for_statement(&mut self, statement: &'a ForStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        // `for (using x = ...; ...)` disposes its resources when the loop ends.
        if let Some(ForStatementInit::VariableDeclaration(declaration)) = &statement.init
            && matches!(
                declaration.kind,
                VariableDeclarationKind::Using | VariableDeclarationKind::AwaitUsing
            )
        {
            return self.using_region(
                declaration.kind == VariableDeclarationKind::AwaitUsing,
                |me, stack| {
                    me.using_stacks.push(stack.to_owned());
                    me.variables(declaration);
                    me.using_stacks.pop();
                    std::mem::take(&mut me.pre)
                },
                |me, after| me.for_loop(statement, after, false),
                k,
            );
        }
        self.for_loop(statement, k, true)
    }

    /// A `for` loop; `init` says whether to run its initializer here.
    fn for_loop(&mut self, statement: &'a ForStatement<'a>, k: &Cont<'a>, init: bool) -> Vec<Expr> {
        let labels = std::mem::take(&mut self.frame.labels);
        let saved_env = self.frame.env.clone();
        match &statement.init {
            _ if !init => {}
            Some(ForStatementInit::VariableDeclaration(declaration)) => self.variables(declaration),
            Some(other) => {
                if let Some(expression) = other.as_expression() {
                    self.effect(expression);
                }
            }
            None => {}
        }
        let mut code = std::mem::take(&mut self.pre);
        let vars = self.assigned_in(statement.body.span(), |visitor| {
            if let Some(test) = &statement.test {
                visitor.visit_expression(test);
            }
            if let Some(update) = &statement.update {
                visitor.visit_expression(update);
            }
            visitor.visit_statement(&statement.body);
        });
        let copies: Vec<SymbolId> = vars
            .iter()
            .copied()
            .filter(|symbol| self.analysis.per_iteration.contains(symbol))
            .collect();
        // CreatePerIterationEnvironment runs once before the first test too, so a closure
        // of the initializer keeps the first copy (ECMA-262 §14.7.4.3).
        for symbol in &copies {
            code.push(self.copy_cell(*symbol));
        }
        let initial: Vec<Expr> = vars.iter().map(|v| self.carried(*v)).collect();
        let fun = self.fresh("Loop");
        let params = self.rebind_params(&vars);
        let next = Cont::Next {
            update: statement.update.as_ref(),
            fun: fun.clone(),
            vars: vars.clone(),
            copies,
            region: self.frame.region,
        };
        self.frame.targets.push(Target {
            kind: TargetKind::Loop,
            labels,
            brk: k.clone(),
            cont: Some(next.clone()),
        });
        let body = match &statement.test {
            Some(test) => {
                let test = self.test(test);
                let mut body = std::mem::take(&mut self.pre);
                let yes = self.arm(&statement.body, &next);
                let no = self.jump(k);
                body.push(boolean_case(test, yes, no));
                body
            }
            None => self.arm(&statement.body, &next),
        };
        self.frame.targets.pop();
        let body = self.seal(body);
        self.frame.env = saved_env;
        code.push(Self::loop_call(fun, params, body, initial));
        code
    }

    pub fn for_of_statement(
        &mut self,
        statement: &'a ForOfStatement<'a>,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let head = self.head_bindings(&statement.left, statement.right.span());
        let right = self.expr(&statement.right);
        self.end_head_bindings(head);
        if statement.r#await {
            let state = Expr::call("buoy_ref_generator", "async_iterator", vec![right]);
            return self.each(
                &statement.left,
                &statement.body,
                statement.span,
                state,
                Each::Await,
                k,
            );
        }
        let state = Expr::call("buoy_ref_iterator", "iterate", vec![right]);
        self.each(
            &statement.left,
            &statement.body,
            statement.span,
            state,
            Each::Of,
            k,
        )
    }

    pub fn for_in_statement(
        &mut self,
        statement: &'a ForInStatement<'a>,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let head = self.head_bindings(&statement.left, statement.right.span());
        let right = self.expr(&statement.right);
        self.end_head_bindings(head);
        let state = Expr::call("buoy_ref_iterator", "for_in", vec![right]);
        self.each(
            &statement.left,
            &statement.body,
            statement.span,
            state,
            Each::In,
            k,
        )
    }

    /// A loop over the steps of an iteration state, for `for...of`, `for await...of`, and
    /// `for...in`. The body of a `for...of` is a region whose handler closes the iterator
    /// before the throw goes on, and a jump or a return out of it goes through the
    /// `Close` fun, which closes the iterator first. The step itself is outside the
    /// region: an iterator whose `next` throws is not closed.
    pub fn each(
        &mut self,
        left: &'a ForStatementLeft<'a>,
        body: &'a Statement<'a>,
        span: Span,
        state: Expr,
        each: Each,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let labels = std::mem::take(&mut self.frame.labels);
        let initial_state = self.bind_var("State", state);
        let mut code = std::mem::take(&mut self.pre);
        let vars = self.assigned_in(span, |visitor| visitor.visit_statement(body));
        let initial: Vec<Expr> = std::iter::once(initial_state.clone())
            .chain(vars.iter().map(|v| self.carried(*v)))
            .collect();
        let fun = self.fresh("Loop");
        let saved_env = self.frame.env.clone();
        let depth = self.frame.region;
        let current = self.fresh("S");
        let mut params = vec![Expr::var(current.clone())];
        params.extend(self.rebind_params(&vars));
        let next_state = self.fresh("Next");
        let item = self.fresh("Item");
        let again = Cont::Call {
            fun: fun.clone(),
            args: vec![Expr::var(next_state.clone())],
            vars: vars.clone(),
            region: depth,
        };
        self.frame.targets.push(Target {
            kind: TargetKind::Loop,
            labels,
            brk: k.clone(),
            cont: Some(again.clone()),
        });
        let close = (each != Each::In).then(|| self.enter_close(depth));
        let inner_env = self.frame.env.clone();
        let mut value_code = if let Some(hint) = using_hint(left) {
            // Each iteration disposes the value of its `using` binding when it ends.
            self.using_region(
                hint == "async",
                |me, stack| {
                    let value = me.bind(Expr::call(
                        "buoy_ref_dispose",
                        "add",
                        vec![
                            Expr::var(stack.to_owned()),
                            Expr::var(item.clone()),
                            Expr::atom(hint),
                        ],
                    ));
                    me.bind_each_item(left, value);
                    std::mem::take(&mut me.pre)
                },
                |me, after| me.arm(body, after),
                &again,
            )
        } else {
            self.bind_each_item(left, Expr::var(item.clone()));
            let mut code = std::mem::take(&mut self.pre);
            code.extend(self.arm(body, &again));
            code
        };
        self.frame.env = inner_env;
        if let Some((_, handler)) = &close {
            self.frame.handlers.pop();
            self.frame.region -= 1;
            let sealed = self.seal(value_code);
            value_code = vec![self.wrap_level(sealed, handler, depth + 1)];
        }
        let done = self.jump(k);
        // The dispatch of the Close fun lowers while the loop is still a target, so that a
        // break that went through it ends the loop.
        let closing = close.map(|(close, handler)| {
            let completion = self.fresh("Completion");
            let frame = self.frame.finally.pop();
            let env = std::mem::replace(&mut self.frame.env, saved_env.clone());
            let dispatch = match &frame {
                Some(frame) => self.completion_dispatch(&completion, frame, k),
                None => vec![],
            };
            self.frame.env = env;
            (close, handler, completion, dispatch)
        });
        self.frame.targets.pop();
        let step = self.each_step(each, &current, &next_state, &item, value_code, done);
        let body = self.seal(step);
        self.frame.env.clone_from(&saved_env);
        if let Some((close, handler, completion, dispatch)) = closing {
            let funs = CloseFuns {
                close,
                handler,
                completion,
            };
            code.extend(self.close_funs(each, &initial_state, funs, dispatch));
        }
        self.frame.env = saved_env;
        code.push(Self::loop_call(fun, params, body, initial));
        code
    }

    /// `value` in a variable, so that funs made later can use it.
    fn bind_var(&mut self, base: &str, value: Expr) -> Expr {
        let value = self.bind(value);
        if let Expr::Var(_) = value {
            return value;
        }
        let name = self.fresh(base);
        self.pre.push(Expr::matches(Expr::var(name.clone()), value));
        Expr::var(name)
    }

    /// Starts the region of the body of a `for...of`: the finally frame of its `Close`
    /// fun and its handler. Returns their names.
    fn enter_close(&mut self, depth: usize) -> (String, String) {
        let close = self.fresh("Close");
        let handler = self.fresh("LoopHandler");
        let order = self.next_order();
        self.frame.finally.push(FinallyFrame {
            fun: close.clone(),
            order,
            base: self.frame.targets.len(),
            region: depth,
            jumps: Vec::new(),
            stays: Some(self.frame.targets.len() - 1),
        });
        self.frame.region += 1;
        self.frame.handlers.push(handler.clone());
        (close, handler)
    }

    /// Binds the left side of a `for...of` or `for...in` to the value of a step.
    fn bind_each_item(&mut self, left: &'a ForStatementLeft<'a>, item: Expr) {
        match left {
            ForStatementLeft::VariableDeclaration(declaration) => {
                if let Some(declarator) = declaration.declarations.first() {
                    self.declare_pattern(&declarator.id, item);
                }
            }
            other => {
                if let Some(target) = other.as_assignment_target() {
                    self.assign_target(target, item);
                }
            }
        }
    }

    /// One step of the loop: the body with the value, or `done`. A `for await` awaits the
    /// result of `next` first.
    fn each_step(
        &mut self,
        each: Each,
        current: &str,
        next_state: &str,
        item: &str,
        value_code: Vec<Expr>,
        done: Vec<Expr>,
    ) -> Vec<Expr> {
        if each != Each::Await {
            return vec![Expr::case(
                Expr::call(
                    "buoy_ref_iterator",
                    "step",
                    vec![Expr::var(current.to_owned())],
                ),
                vec![
                    Clause::new(
                        Expr::Tuple(vec![
                            Expr::atom("value"),
                            Expr::var(item.to_owned()),
                            Expr::var(next_state.to_owned()),
                        ]),
                        value_code,
                    ),
                    Clause::new(Expr::atom("done"), done),
                ],
            )];
        }
        let result = self.bind(Expr::call(
            "buoy_ref_iterator",
            "async_next",
            vec![Expr::var(current.to_owned())],
        ));
        let result = self.marker("await", result);
        let mut step = std::mem::take(&mut self.pre);
        step.push(Expr::matches(
            Expr::var(next_state.to_owned()),
            Expr::var(current.to_owned()),
        ));
        step.push(Expr::case(
            Expr::call("buoy_ref_iterator", "async_step", vec![result]),
            vec![
                Clause::new(
                    Expr::tagged("value", Expr::var(item.to_owned())),
                    value_code,
                ),
                Clause::new(Expr::atom("done"), done),
            ],
        ));
        step
    }

    /// The `Close` fun, which closes the iterator and then completes the loop the way its
    /// completion says, and the handler of the body, which closes the iterator and
    /// throws again. A `for await` awaits the result of `return`.
    fn close_funs(
        &mut self,
        each: Each,
        state: &Expr,
        funs: CloseFuns,
        dispatch: Vec<Expr>,
    ) -> Vec<Expr> {
        let outer = self.handler_chain();
        let error = self.fresh("E");
        let rethrow = self.wrap_chain(vec![throw_value(Expr::var(error.clone()))], &outer);
        let (close_body, handler_body) = if each == Each::Await {
            let then = self.wrap_chain(dispatch, &outer);
            let thrown = self.fresh("Thrown");
            let fail_body = self.wrap_chain(vec![throw_value(Expr::var(thrown.clone()))], &outer);
            let fail = Expr::Fun {
                name: None,
                clauses: vec![Clause::new(Expr::var(thrown), vec![fail_body])],
            };
            let close_body = vec![Expr::call(
                "buoy_ref_iterator",
                "async_close",
                vec![state.clone(), thunk(vec![then]), fail],
            )];
            let handler_body = self.wrap_chain(
                vec![Expr::call(
                    "buoy_ref_iterator",
                    "async_close_quietly",
                    vec![state.clone(), thunk(vec![rethrow])],
                )],
                &outer,
            );
            (close_body, handler_body)
        } else {
            let mut close_body = vec![Expr::call(
                "buoy_ref_iterator",
                "close_state",
                vec![state.clone()],
            )];
            close_body.extend(dispatch);
            let quiet = Expr::call("buoy_ref_iterator", "close_quietly", vec![state.clone()]);
            (close_body, block(vec![quiet, rethrow]))
        };
        vec![
            Expr::matches(
                Expr::var(funs.close),
                Expr::Fun {
                    name: None,
                    clauses: vec![Clause::new(Expr::var(funs.completion), close_body)],
                },
            ),
            Expr::matches(
                Expr::var(funs.handler),
                Expr::Fun {
                    name: None,
                    clauses: vec![Clause::new(Expr::var(error), vec![handler_body])],
                },
            ),
        ]
    }
}

/// The names of the funs that close the iterator of a `for...of`.
struct CloseFuns {
    close: String,
    handler: String,
    completion: String,
}

/// The hint of a `using` or `await using` loop head.
fn using_hint(left: &ForStatementLeft<'_>) -> Option<&'static str> {
    match left {
        ForStatementLeft::VariableDeclaration(declaration) => match declaration.kind {
            VariableDeclarationKind::Using => Some("sync"),
            VariableDeclarationKind::AwaitUsing => Some("async"),
            _ => None,
        },
        _ => None,
    }
}

/// The kind of an `each` loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Each {
    Of,
    Await,
    In,
}

fn thunk(body: Vec<Expr>) -> Expr {
    Expr::Fun {
        name: None,
        clauses: vec![Clause {
            patterns: vec![],
            guards: vec![],
            body,
        }],
    }
}
