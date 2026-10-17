//! Statements in continuation-passing style. Every path of a compound statement ends in a
//! tail call: of the join fun of the rest of the block, of a loop fun, or of the function
//! end. So `return v` is just the value, and loops do not grow the stack.

use oxc::ast::ast::{
    Declaration, DoWhileStatement, ForInStatement, ForOfStatement, ForStatement, ForStatementInit,
    ForStatementLeft, IfStatement, LabeledStatement, Statement, SwitchStatement, TryStatement,
    WhileStatement,
};
use oxc::ast_visit::Visit;
use oxc::semantic::SymbolId;
use oxc::span::{GetSpan, Span};

use super::analyze::{Assigned, Suspends, completes_normally};
use super::{
    Cont, Local, Lowerer, Reify, Target, TargetKind, block, boolean_case, cell_set, throw_value,
};
use crate::erlang::{CatchClause, Clause, Expr};

impl<'a> Lowerer<'a, '_> {
    /// Lowers a list of statements, then continuation `k`.
    pub fn stmts(&mut self, list: Vec<&'a Statement<'a>>, k: &Cont<'a>) -> Vec<Expr> {
        let saved = std::mem::take(&mut self.pre);
        let mut code = self.hoist(&list);
        let mut list = list;
        let mut index = 0;
        loop {
            let Some(statement) = list.get(index).copied() else {
                code.extend(self.jump(k));
                break;
            };
            if let Statement::BlockStatement(inner) = statement {
                let mut spliced: Vec<&'a Statement<'a>> = inner.body.iter().collect();
                code.extend(self.hoist(&spliced));
                spliced.extend_from_slice(&list[index + 1..]);
                list = spliced;
                index = 0;
                continue;
            }
            if is_simple(statement) {
                code.extend(self.simple(statement));
                index += 1;
                continue;
            }
            let rest = &list[index + 1..];
            if rest.is_empty() || !completes_normally(statement) {
                code.extend(self.stmt(statement, k));
                break;
            }
            let vars = self.assigned_in(statement.span(), |visitor| {
                visitor.visit_statement(statement);
            });
            let join = self.fresh("K");
            let saved_env = self.frame.env.clone();
            let params = self.rebind_params(&vars);
            let rest_code = self.stmts(rest.to_vec(), k);
            self.frame.env = saved_env;
            code.push(Expr::matches(
                Expr::var(join.clone()),
                Expr::Fun {
                    name: None,
                    clauses: vec![Clause {
                        patterns: params,
                        guards: vec![],
                        body: rest_code,
                    }],
                },
            ));
            let region = self.frame.region;
            let next = Cont::Call {
                fun: join,
                args: vec![],
                vars,
                region,
            };
            code.extend(self.stmt(statement, &next));
            break;
        }
        self.pre = saved;
        self.seal(code)
    }

    /// The nested function declarations of a block: a cell each, set before the first
    /// statement runs, so that they can call each other.
    fn hoist(&mut self, list: &[&'a Statement<'a>]) -> Vec<Expr> {
        let functions: Vec<_> = list
            .iter()
            .filter_map(|statement| match statement {
                Statement::FunctionDeclaration(function) => function
                    .id
                    .as_ref()
                    .and_then(|id| id.symbol_id.get())
                    .filter(|symbol| !self.tops.contains_key(symbol))
                    .map(|symbol| (symbol, function)),
                _ => None,
            })
            .collect();
        let saved = std::mem::take(&mut self.pre);
        let mut cells = Vec::new();
        for (symbol, _) in &functions {
            let cell = self.fresh("Fn");
            self.pre.push(Expr::matches(
                Expr::var(cell.clone()),
                Expr::call("bouy_heap", "cell", vec![Expr::undefined()]),
            ));
            self.frame.env.insert(*symbol, Local::Cell(cell.clone()));
            cells.push(cell);
        }
        for ((_, function), cell) in functions.iter().zip(cells) {
            let fun = self.function_fun(function, None);
            let name = function
                .id
                .as_ref()
                .map_or_else(String::new, |id| id.name.to_string());
            let length = function
                .params
                .items
                .iter()
                .take_while(|p| p.initializer.is_none())
                .count();
            let value = self.bind(Expr::call(
                "bouy_ref",
                "named_fn",
                vec![
                    fun,
                    Expr::binary(name),
                    Expr::Integer(i64::try_from(length).unwrap_or(0)),
                ],
            ));
            self.pre.push(cell_set(&cell, value));
        }
        std::mem::replace(&mut self.pre, saved)
    }

    /// The variables declared outside `span` that `visit` assigns and that are versions
    /// or per-iteration cells in the environment.
    fn assigned_in(&self, span: Span, visit: impl FnOnce(&mut Assigned<'_>)) -> Vec<SymbolId> {
        let mut assigned = Assigned {
            scoping: self.semantic.scoping(),
            span,
            found: Vec::new(),
        };
        visit(&mut assigned);
        assigned
            .found
            .into_iter()
            .filter(|symbol| match self.frame.env.get(symbol) {
                Some(Local::Var(_)) => true,
                Some(Local::Cell(_)) => self.analysis.per_iteration.contains(symbol),
                None => false,
            })
            .collect()
    }

    /// A statement that runs straight through: its code and no jump.
    fn simple(&mut self, statement: &'a Statement<'a>) -> Vec<Expr> {
        let saved = std::mem::take(&mut self.pre);
        match statement {
            Statement::ExpressionStatement(statement) => self.effect(&statement.expression),
            Statement::VariableDeclaration(declaration) => self.variables(declaration),
            Statement::ExportDeclaration(export) => {
                if let Declaration::VariableDeclaration(declaration) = &export.declaration {
                    self.variables(declaration);
                }
            }
            Statement::ClassDeclaration(class) if !class.declare => {
                self.unsupported(class.span, "a class declared inside a function");
            }
            _ => {}
        }
        std::mem::replace(&mut self.pre, saved)
    }

    fn variables(&mut self, declaration: &'a oxc::ast::ast::VariableDeclaration<'a>) {
        if declaration.declare {
            return;
        }
        for declarator in &declaration.declarations {
            let value = match &declarator.init {
                Some(init) => self.expr(init),
                None => Expr::undefined(),
            };
            self.declare_pattern(&declarator.id, value);
        }
    }

    /// Lowers a compound statement with continuation `k`.
    pub fn stmt(&mut self, statement: &'a Statement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        let saved = std::mem::take(&mut self.pre);
        let code = match statement {
            Statement::IfStatement(statement) => self.if_statement(statement, k),
            Statement::WhileStatement(statement) => self.while_statement(statement, k),
            Statement::DoWhileStatement(statement) => self.do_while_statement(statement, k),
            Statement::ForStatement(statement) => self.for_statement(statement, k),
            Statement::ForOfStatement(statement) => self.for_of_statement(statement, k),
            Statement::ForInStatement(statement) => self.for_in_statement(statement, k),
            Statement::SwitchStatement(statement) => self.switch_statement(statement, k),
            Statement::TryStatement(statement) => self.try_statement(statement, k),
            Statement::LabeledStatement(statement) => self.labeled_statement(statement, k),
            Statement::BlockStatement(inner) => self.stmts(inner.body.iter().collect(), k),
            Statement::ReturnStatement(statement) => {
                let value = match &statement.argument {
                    Some(argument) => self.expr(argument),
                    None => Expr::undefined(),
                };
                let ret = self.ret(value);
                let mut code = std::mem::take(&mut self.pre);
                code.push(ret);
                code
            }
            Statement::ThrowStatement(statement) => {
                let value = self.expr(&statement.argument);
                let mut code = std::mem::take(&mut self.pre);
                code.push(throw_value(value));
                code
            }
            Statement::BreakStatement(statement) => {
                let label = statement.label.as_ref().map(|label| label.name.to_string());
                self.break_to(label.as_deref(), false, statement.span)
            }
            Statement::ContinueStatement(statement) => {
                let label = statement.label.as_ref().map(|label| label.name.to_string());
                self.break_to(label.as_deref(), true, statement.span)
            }
            other => {
                let mut code = self.simple(other);
                code.extend(self.jump(k));
                code
            }
        };
        self.pre = saved;
        code
    }

    /// The code of one arm of a branch: the environment of the arm does not leak.
    fn arm(&mut self, statement: &'a Statement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        let env = self.frame.env.clone();
        let code = self.stmts(vec![statement], k);
        self.frame.env = env;
        code
    }

    fn if_statement(&mut self, statement: &'a IfStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        self.frame.labels.clear();
        let test = self.test(&statement.test);
        let mut code = std::mem::take(&mut self.pre);
        let yes = self.arm(&statement.consequent, k);
        let no = match &statement.alternate {
            Some(alternate) => self.arm(alternate, k),
            None => self.jump(k),
        };
        code.push(boolean_case(test, yes, no));
        code
    }

    /// `(fun Loop(Params) -> Body end)(Initial)`.
    fn loop_call(name: String, params: Vec<Expr>, body: Vec<Expr>, initial: Vec<Expr>) -> Expr {
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

    fn while_statement(&mut self, statement: &'a WhileStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
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

    fn do_while_statement(
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

    fn for_statement(&mut self, statement: &'a ForStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        let labels = std::mem::take(&mut self.frame.labels);
        let saved_env = self.frame.env.clone();
        match &statement.init {
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

    fn for_of_statement(&mut self, statement: &'a ForOfStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        if statement.r#await {
            self.unsupported(statement.span, "`for await`");
            return vec![Expr::undefined()];
        }
        let right = self.expr(&statement.right);
        let state = Expr::call("bouy_ref", "iterate", vec![right]);
        self.each(&statement.left, &statement.body, statement.span, state, k)
    }

    fn for_in_statement(&mut self, statement: &'a ForInStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        let right = self.expr(&statement.right);
        let state = Expr::Tuple(vec![
            Expr::atom("list"),
            Expr::call("bouy_ref", "for_in_keys", vec![right]),
        ]);
        self.each(&statement.left, &statement.body, statement.span, state, k)
    }

    /// A loop over the steps of an iteration state, for `for...of` and `for...in`.
    fn each(
        &mut self,
        left: &'a ForStatementLeft<'a>,
        body: &'a Statement<'a>,
        span: Span,
        state: Expr,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let labels = std::mem::take(&mut self.frame.labels);
        let state = self.bind(state);
        let mut code = std::mem::take(&mut self.pre);
        let vars = self.assigned_in(span, |visitor| visitor.visit_statement(body));
        let initial: Vec<Expr> = std::iter::once(state)
            .chain(vars.iter().map(|v| self.carried(*v)))
            .collect();
        let fun = self.fresh("Loop");
        let saved_env = self.frame.env.clone();
        let current = self.fresh("S");
        let mut params = vec![Expr::var(current.clone())];
        params.extend(self.rebind_params(&vars));
        let next_state = self.fresh("Next");
        let item = self.fresh("Item");
        let again = Cont::Call {
            fun: fun.clone(),
            args: vec![Expr::var(next_state.clone())],
            vars: vars.clone(),
            region: self.frame.region,
        };
        self.frame.targets.push(Target {
            kind: TargetKind::Loop,
            labels,
            brk: k.clone(),
            cont: Some(again.clone()),
        });
        let inner_env = self.frame.env.clone();
        match left {
            ForStatementLeft::VariableDeclaration(declaration) => {
                if let Some(declarator) = declaration.declarations.first() {
                    self.declare_pattern(&declarator.id, Expr::var(item.clone()));
                }
            }
            other => {
                if let Some(target) = other.as_assignment_target() {
                    self.assign_target(target, Expr::var(item.clone()));
                }
            }
        }
        let mut value_code = std::mem::take(&mut self.pre);
        value_code.extend(self.arm(body, &again));
        self.frame.env = inner_env;
        let done = self.jump(k);
        self.frame.targets.pop();
        let step = Expr::case(
            Expr::call("bouy_ref", "step", vec![Expr::var(current)]),
            vec![
                Clause::new(
                    Expr::Tuple(vec![
                        Expr::atom("value"),
                        Expr::var(item),
                        Expr::var(next_state),
                    ]),
                    value_code,
                ),
                Clause::new(Expr::atom("done"), done),
            ],
        );
        let body = self.seal(vec![step]);
        self.frame.env = saved_env;
        code.push(Self::loop_call(fun, params, body, initial));
        code
    }

    fn switch_statement(&mut self, statement: &'a SwitchStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        let labels = std::mem::take(&mut self.frame.labels);
        let discriminant = self.expr(&statement.discriminant);
        let discriminant = self.bind(discriminant);
        let mut code = std::mem::take(&mut self.pre);
        let vars = self.assigned_in(statement.span, |visitor| {
            for case in &statement.cases {
                for item in &case.consequent {
                    visitor.visit_statement(item);
                }
            }
        });
        let region = self.frame.region;
        self.frame.targets.push(Target {
            kind: TargetKind::Switch,
            labels,
            brk: k.clone(),
            cont: None,
        });
        let names: Vec<String> = statement.cases.iter().map(|_| self.fresh("Case")).collect();
        let mut funs = Vec::new();
        for (index, case) in statement.cases.iter().enumerate().rev() {
            let next = match names.get(index + 1) {
                Some(name) => Cont::Call {
                    fun: name.clone(),
                    args: vec![],
                    vars: vars.clone(),
                    region,
                },
                None => k.clone(),
            };
            let saved_env = self.frame.env.clone();
            let params = self.rebind_params(&vars);
            let body = self.stmts(case.consequent.iter().collect(), &next);
            self.frame.env = saved_env;
            funs.push(Expr::matches(
                Expr::var(names[index].clone()),
                Expr::Fun {
                    name: None,
                    clauses: vec![Clause {
                        patterns: params,
                        guards: vec![],
                        body,
                    }],
                },
            ));
        }
        self.frame.targets.pop();
        code.extend(funs);
        let enter = |name: &str, me: &Self| {
            Expr::Apply(
                Box::new(Expr::var(name.to_owned())),
                vars.iter().map(|v| me.carried(*v)).collect(),
            )
        };
        let default = statement.cases.iter().position(|case| case.test.is_none());
        let mut dispatch = match default {
            Some(index) => vec![enter(&names[index], self)],
            None => self.jump(k),
        };
        for (index, case) in statement.cases.iter().enumerate().rev() {
            let Some(test) = &case.test else {
                continue;
            };
            let saved = std::mem::take(&mut self.pre);
            let value = self.expr(test);
            let mut test_code = std::mem::replace(&mut self.pre, saved);
            test_code.push(boolean_case(
                Expr::call("bouy_ref", "strict_eq", vec![discriminant.clone(), value]),
                vec![enter(&names[index], self)],
                dispatch,
            ));
            dispatch = test_code;
        }
        code.extend(dispatch);
        code
    }

    fn labeled_statement(
        &mut self,
        statement: &'a LabeledStatement<'a>,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let label = statement.label.name.to_string();
        let is_loop = matches!(
            statement.body,
            Statement::ForStatement(_)
                | Statement::WhileStatement(_)
                | Statement::DoWhileStatement(_)
                | Statement::ForOfStatement(_)
                | Statement::ForInStatement(_)
        );
        if is_loop || matches!(statement.body, Statement::LabeledStatement(_)) {
            self.frame.labels.push(label);
            return self.stmt(&statement.body, k);
        }
        self.frame.labels.clear();
        self.frame.targets.push(Target {
            kind: TargetKind::Label,
            labels: vec![label],
            brk: k.clone(),
            cont: None,
        });
        let code = self.stmts(vec![&statement.body], k);
        self.frame.targets.pop();
        code
    }

    fn break_to(&mut self, label: Option<&str>, is_continue: bool, span: Span) -> Vec<Expr> {
        let index = self.frame.targets.iter().rposition(|target| match label {
            Some(label) => target.labels.iter().any(|l| l == label),
            None if is_continue => target.kind == TargetKind::Loop,
            None => target.kind != TargetKind::Label,
        });
        let Some(index) = index else {
            self.unsupported(span, "this jump");
            return vec![Expr::undefined()];
        };
        self.jump_target(index, is_continue)
    }

    fn jump_target(&mut self, index: usize, is_continue: bool) -> Vec<Expr> {
        if let Some(reify) = self.frame.reify.last_mut()
            && index < reify.base
        {
            if !reify.jumps.contains(&(index, is_continue)) {
                reify.jumps.push((index, is_continue));
            }
            return vec![jump_tuple(index, is_continue)];
        }
        let target = &self.frame.targets[index];
        let k = match (&target.cont, is_continue) {
            (Some(cont), true) => cont.clone(),
            _ => target.brk.clone(),
        };
        self.jump(&k)
    }

    fn try_statement(&mut self, statement: &'a TryStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
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
    fn reified_try(&mut self, statement: &'a TryStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
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
    fn raising_try(&mut self, code: Vec<Expr>) -> Expr {
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
    fn region_try(&mut self, statement: &'a TryStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
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

fn jump_tuple(index: usize, is_continue: bool) -> Expr {
    Expr::Tuple(vec![
        Expr::atom("jump"),
        Expr::Integer(i64::try_from(index).unwrap_or(0)),
        Expr::atom(is_continue.to_string()),
    ])
}

/// Statements that run straight through, with no jump or join.
fn is_simple(statement: &Statement<'_>) -> bool {
    matches!(
        statement,
        Statement::ExpressionStatement(_)
            | Statement::VariableDeclaration(_)
            | Statement::EmptyStatement(_)
            | Statement::FunctionDeclaration(_)
            | Statement::ClassDeclaration(_)
            | Statement::TSTypeAliasDeclaration(_)
            | Statement::TSInterfaceDeclaration(_)
            | Statement::ExportDeclaration(_)
            | Statement::ExportNamedDeclaration(_)
            | Statement::DebuggerStatement(_)
    )
}
