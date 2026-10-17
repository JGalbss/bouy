//! Statements in continuation-passing style. Every path of a compound statement ends in a
//! tail call: of the join fun of the rest of the block, of a loop fun, or of the function
//! end. So `return v` is just the value, and loops do not grow the stack.

use oxc::ast::ast::{
    BindingPattern, Declaration, IfStatement, LabeledStatement, Statement, SwitchStatement,
    VariableDeclarationKind,
};
use oxc::ast_visit::Visit;
use oxc::semantic::SymbolId;
use oxc::span::{GetSpan, Span};

use super::analyze::{Assigned, completes_normally};
use super::context::{
    Cont, Kind, Local, Lowerer, Target, TargetKind, Top, boolean_case, cell_set, throw_value,
};
use super::function::binding_name;
use crate::erlang::{Clause, Expr};

impl<'a> Lowerer<'a, '_> {
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
            if is_using(statement) {
                code.extend(self.using_block(&list[index..], k));
                break;
            }
            // A block with `using` declarations disposes at its own end, so it stays a
            // statement; another block joins the list.
            if let Statement::BlockStatement(inner) = statement
                && !inner.body.iter().any(is_using)
            {
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
    pub fn hoist(&mut self, list: &[&'a Statement<'a>]) -> Vec<Expr> {
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
        let early = self.early_bindings(list);
        self.pre.extend(early);
        let mut cells = Vec::new();
        for (symbol, _) in &functions {
            // A sloppy block function shares the cell that its function made for it at the
            // start (Annex B.3.3), and the rest of a block hoists again into the same cell.
            if let Some(Local::Cell(cell)) = self.frame.env.get(symbol) {
                cells.push(cell.clone());
                continue;
            }
            let cell = self.fresh("Fn");
            self.pre.push(Expr::matches(
                Expr::var(cell.clone()),
                Expr::call("bouy_heap", "cell", vec![Expr::undefined()]),
            ));
            self.frame.env.insert(*symbol, Local::Cell(cell.clone()));
            cells.push(cell);
        }
        for ((_, function), cell) in functions.iter().zip(cells) {
            let value = self.function_value(function, None);
            self.pre.push(cell_set(&cell, value));
        }
        std::mem::replace(&mut self.pre, saved)
    }

    /// The variables declared outside `span` that `visit` assigns and that are versions
    /// or per-iteration cells in the environment.
    pub fn assigned_in(&self, span: Span, visit: impl FnOnce(&mut Assigned<'_>)) -> Vec<SymbolId> {
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
    pub fn simple(&mut self, statement: &'a Statement<'a>) -> Vec<Expr> {
        let saved = std::mem::take(&mut self.pre);
        match statement {
            Statement::ExpressionStatement(statement) => self.effect(&statement.expression),
            Statement::VariableDeclaration(declaration) => self.variables(declaration),
            Statement::ExportDeclaration(export) => match &export.declaration {
                Declaration::VariableDeclaration(declaration) => self.variables(declaration),
                Declaration::ClassDeclaration(class) if !class.declare => {
                    if let Some(id) = &class.id {
                        self.declare_class(id.name.as_str(), class);
                    }
                }
                _ => {}
            },
            Statement::ExportDefaultDeclaration(export) => match &export.declaration {
                oxc::ast::ast::ExportDefaultDeclarationKind::ClassDeclaration(class) => {
                    let name = class.id.as_ref().map_or("default", |id| id.name.as_str());
                    self.declare_class(name, class);
                }
                other => {
                    if let Some(expression) = other.as_expression() {
                        self.export_default(expression);
                    }
                }
            },
            Statement::ClassDeclaration(class)
                if class.id.as_ref().is_some_and(|id| {
                    id.symbol_id.get().is_some_and(|symbol| {
                        matches!(self.tops.get(&symbol), Some(Top::Class(_) | Top::Var(_)))
                    })
                }) =>
            {
                if let Some(id) = &class.id {
                    self.declare_class(id.name.as_str(), class);
                }
            }
            Statement::ClassDeclaration(class) if !class.declare => {
                self.class_declaration(class);
            }
            _ => {}
        }
        std::mem::replace(&mut self.pre, saved)
    }

    pub fn variables(&mut self, declaration: &'a oxc::ast::ast::VariableDeclaration<'a>) {
        if declaration.declare {
            return;
        }
        for declarator in &declaration.declarations {
            // A `var` exists from the start of its function, so a declaration without an
            // initializer does nothing.
            if declaration.kind.is_var() && declarator.init.is_none() {
                continue;
            }
            if declaration.kind.is_var()
                && let (BindingPattern::BindingIdentifier(id), Some(init)) =
                    (&declarator.id, &declarator.init)
                && let Some(symbol) = id.symbol_id.get()
            {
                let objects = self.with_objects_for(Some(symbol));
                if !objects.is_empty() {
                    self.with_var_initializer(id.name.as_str(), symbol, &objects, init);
                    continue;
                }
            }
            let value = match &declarator.init {
                Some(init) => self.named_expr(init, binding_name(&declarator.id)),
                None => Expr::undefined(),
            };
            let hint = match declaration.kind {
                VariableDeclarationKind::Using => Some("sync"),
                VariableDeclarationKind::AwaitUsing => Some("async"),
                _ => None,
            };
            let value = match (hint, self.using_stacks.last().cloned()) {
                (Some(hint), Some(stack)) => self.bind(Expr::call(
                    "bouy_ref_dispose",
                    "add",
                    vec![Expr::var(stack), value, Expr::atom(hint)],
                )),
                _ => value,
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
            Statement::WithStatement(statement) => self.with_statement(statement, k),
            Statement::BlockStatement(inner) => self.stmts(inner.body.iter().collect(), k),
            Statement::ReturnStatement(statement) => {
                let value = match &statement.argument {
                    // An async generator awaits the value that it returns.
                    Some(argument) if self.frame.kind == Kind::AsyncGenerator => {
                        let value = self.expr(argument);
                        self.marker("await", value)
                    }
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
    pub fn arm(&mut self, statement: &'a Statement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        let env = self.frame.env.clone();
        let code = self.stmts(vec![statement], k);
        self.frame.env = env;
        code
    }

    pub fn if_statement(&mut self, statement: &'a IfStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
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

    /// A call of a continuation fun made at region depth `region`: direct, or, from
    /// inside a deeper suspending `try`, returned to the wrapper of the segment so that it
    /// runs outside the Erlang `try`.
    pub fn call_cont(&self, name: &str, args: Vec<Expr>, region: usize) -> Expr {
        if self.frame.region > region {
            Expr::Tuple(vec![
                Expr::atom("$k"),
                Expr::var(name.to_owned()),
                Expr::List(args),
                Expr::Integer(i64::try_from(region).unwrap_or(0)),
            ])
        } else {
            Expr::Apply(Box::new(Expr::var(name.to_owned())), args)
        }
    }

    /// The code that completes a statement normally with continuation `k`.
    pub fn jump(&mut self, k: &Cont<'a>) -> Vec<Expr> {
        match k {
            Cont::Call {
                fun,
                args,
                vars,
                region,
            } => {
                let mut all = args.clone();
                all.extend(vars.iter().map(|v| self.carried(*v)));
                vec![self.call_cont(fun, all, *region)]
            }
            Cont::Value(value) => vec![value.clone()],
            Cont::Return => vec![self.ret(Expr::undefined())],
            Cont::Next {
                update,
                fun,
                vars,
                copies,
                region,
            } => {
                let saved_env = self.frame.env.clone();
                let saved = std::mem::take(&mut self.pre);
                for symbol in copies {
                    let value = self.current(*symbol);
                    let cell = self.fresh("Cell");
                    self.pre.push(Expr::matches(
                        Expr::var(cell.clone()),
                        Expr::call("bouy_heap", "cell", vec![value]),
                    ));
                    self.frame.env.insert(*symbol, Local::Cell(cell));
                }
                if let Some(update) = update {
                    self.effect(update);
                }
                let args = vars.iter().map(|v| self.carried(*v)).collect();
                let call = self.call_cont(fun, args, *region);
                let mut code = std::mem::replace(&mut self.pre, saved);
                code.push(call);
                self.frame.env = saved_env;
                code
            }
            Cont::Test {
                test,
                fun,
                vars,
                exit,
                region,
            } => {
                let saved_env = self.frame.env.clone();
                let saved = std::mem::take(&mut self.pre);
                let condition = self.test(test);
                let args = vars.iter().map(|v| self.carried(*v)).collect();
                let again = self.call_cont(fun, args, *region);
                let out = self.jump(exit);
                let mut code = std::mem::replace(&mut self.pre, saved);
                code.push(boolean_case(condition, vec![again], out));
                self.frame.env = saved_env;
                code
            }
        }
    }

    pub fn switch_statement(
        &mut self,
        statement: &'a SwitchStatement<'a>,
        k: &Cont<'a>,
    ) -> Vec<Expr> {
        let labels = std::mem::take(&mut self.frame.labels);
        let discriminant = self.expr(&statement.discriminant);
        let discriminant = self.bind(discriminant);
        let early = self.early_case_bindings(statement);
        self.pre.extend(early);
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

    pub fn labeled_statement(
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

    pub fn break_to(&mut self, label: Option<&str>, is_continue: bool, span: Span) -> Vec<Expr> {
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

    /// The variables that the continuation of a jump to target `index` passes on.
    pub fn target_vars(&self, index: usize, is_continue: bool) -> Vec<SymbolId> {
        let target = &self.frame.targets[index];
        let k = match (&target.cont, is_continue) {
            (Some(cont), true) => cont,
            _ => &target.brk,
        };
        match k {
            Cont::Call { vars, .. } | Cont::Next { vars, .. } | Cont::Test { vars, .. } => {
                vars.clone()
            }
            Cont::Return | Cont::Value(_) => Vec::new(),
        }
    }

    fn target_values(&self, index: usize, is_continue: bool) -> Expr {
        Expr::List(
            self.target_vars(index, is_continue)
                .iter()
                .map(|symbol| self.carried(*symbol))
                .collect(),
        )
    }

    pub fn jump_target(&mut self, index: usize, is_continue: bool) -> Vec<Expr> {
        if self.reify_innermost()
            && let Some(reify) = self.frame.reify.last()
            && index < reify.base
        {
            let values = self.target_values(index, is_continue);
            if let Some(reify) = self.frame.reify.last_mut()
                && !reify.jumps.contains(&(index, is_continue))
            {
                reify.jumps.push((index, is_continue));
            }
            return vec![jump_tuple(index, is_continue, values)];
        }
        if !self.reify_innermost()
            && let Some(finally) = self.frame.finally.last()
            && index < finally.base
            && !(is_continue && finally.stays == Some(index))
        {
            let (fun, region) = (finally.fun.clone(), finally.region);
            let values = self.target_values(index, is_continue);
            if let Some(finally) = self.frame.finally.last_mut()
                && !finally.jumps.contains(&(index, is_continue))
            {
                finally.jumps.push((index, is_continue));
            }
            return vec![self.call_cont(
                &fun,
                vec![jump_tuple(index, is_continue, values)],
                region,
            )];
        }
        let target = &self.frame.targets[index];
        let k = match (&target.cont, is_continue) {
            (Some(cont), true) => cont.clone(),
            _ => target.brk.clone(),
        };
        self.jump(&k)
    }
}

/// The completion of a jump out of a `try` or a `for...of`: the target, and the values
/// of the variables that the target passes on.
pub fn jump_tuple(index: usize, is_continue: bool, values: Expr) -> Expr {
    Expr::Tuple(vec![
        Expr::atom("jump"),
        Expr::Integer(i64::try_from(index).unwrap_or(0)),
        Expr::atom(is_continue.to_string()),
        values,
    ])
}

/// A `using` or `await using` declaration.
pub fn is_using(statement: &Statement<'_>) -> bool {
    matches!(
        statement,
        Statement::VariableDeclaration(declaration)
            if matches!(declaration.kind, VariableDeclarationKind::Using | VariableDeclarationKind::AwaitUsing)
    )
}

/// Statements that run straight through, with no jump or join.
pub fn is_simple(statement: &Statement<'_>) -> bool {
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
            | Statement::ExportDefaultDeclaration(_)
            | Statement::DebuggerStatement(_)
    )
}
