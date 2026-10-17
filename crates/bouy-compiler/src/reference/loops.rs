//! Loops: `while`, `do...while`, `for`, `for...of`, and `for...in`. A loop is a named
//! fun that calls itself with the versions of the variables its body changes.

use oxc::ast::ast::{
    DoWhileStatement, ForInStatement, ForOfStatement, ForStatement, ForStatementInit,
    ForStatementLeft, Statement, WhileStatement,
};
use oxc::ast_visit::Visit;
use oxc::semantic::SymbolId;
use oxc::span::{GetSpan, Span};

use super::context::{Cont, Lowerer, Target, TargetKind, boolean_case};
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

    pub fn for_of_statement(
        &mut self,
        statement: &'a ForOfStatement<'a>,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        if statement.r#await {
            self.unsupported(statement.span, "`for await`");
            return vec![Expr::undefined()];
        }
        let right = self.expr(&statement.right);
        let state = Expr::call("bouy_ref_iterator", "iterate", vec![right]);
        self.each(&statement.left, &statement.body, statement.span, state, k)
    }

    pub fn for_in_statement(
        &mut self,
        statement: &'a ForInStatement<'a>,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let right = self.expr(&statement.right);
        let state = Expr::Tuple(vec![
            Expr::atom("list"),
            Expr::call("bouy_ref_iterator", "for_in_keys", vec![right]),
        ]);
        self.each(&statement.left, &statement.body, statement.span, state, k)
    }

    /// A loop over the steps of an iteration state, for `for...of` and `for...in`.
    pub fn each(
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
            Expr::call("bouy_ref_iterator", "step", vec![Expr::var(current)]),
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
}
