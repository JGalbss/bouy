//! Statements and control flow (sections 7 and 12).
//!
//! A block lowers into the current sequence. A construct that rebinds outer variables
//! yields their new versions as a tuple. A construct with an abrupt completion yields a
//! tagged completion, and the rest of the block lowers once, inside the `{next, ...}` clause
//! of a `case` on it. Loops are named recursive funs over a state tuple.

use oxc::ast::ast::{
    BindingPattern, Declaration, Expression, ForInStatement, ForOfStatement, ForStatement,
    ForStatementInit, ForStatementLeft, Function, IfStatement, Statement, SwitchCase,
    SwitchStatement, TryStatement, VariableDeclaration, VariableDeclarationKind,
};
use oxc::ast_visit::Visit;
use oxc::span::{GetSpan, Span};

use super::function::Callable;
use super::hoist;
use super::rebind::{self, Escapes, escapes, escapes_all, falls_through, strip};
use super::scope::{Target, base_name};
use super::{Binding, Checkpoint, Flow, JumpTarget, Lowerer, Next, Tail};
use crate::diagnostic::Code;
use crate::erlang::{CatchClause, Clause, Expr};

/// The value a construct yields when it completes normally.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    /// `if`, `switch`, `try`: the tuple of rebound variables, or `{next, Tuple}`.
    Bare,
    /// A loop: `{break, State}`.
    Break,
}

struct Group<'a> {
    tests: Vec<&'a Expression<'a>>,
    default: bool,
    body: Vec<&'a Statement<'a>>,
}

impl<'a> Lowerer<'a, '_> {
    pub fn block(&mut self, statements: &'a [Statement<'a>], tail: &Tail<'_>) {
        let statements: Vec<&'a Statement<'a>> = statements.iter().collect();
        self.block_of(&statements, tail);
    }

    /// Lowers `statements` into the current sequence and ends it as `tail` requires.
    pub fn block_of(&mut self, statements: &[&'a Statement<'a>], tail: &Tail<'_>) {
        let flat = flatten(statements);
        let groups = hoist::groups(&flat, self.semantic, |function| self.is_nested(function));
        for group in &groups {
            self.pending
                .extend(group.functions.iter().map(|function| function.span));
        }
        for (index, statement) in flat.iter().enumerate() {
            for group in groups.iter().filter(|group| group.position == index) {
                self.create_group(group);
            }
            if self.statement(statement, &flat[index + 1..], tail) == Flow::Ended {
                return;
            }
        }
        self.fall_through(tail);
    }

    /// Whether `function` is a nested function declaration that no group has created yet.
    fn is_nested(&self, function: &Function<'_>) -> bool {
        !self.hoisted.contains(&function.span)
            && function
                .id
                .as_ref()
                .and_then(|id| id.symbol_id.get())
                .is_some_and(|symbol| !self.module.is_module_scope(symbol))
    }

    /// Creates the functions of a group (section 12): one named fun, or for functions that
    /// call each other, a named fun that returns all of them, so that each one can reach the
    /// others:
    ///
    /// ```erlang
    /// Group@1 = fun Group@1() -> {fun(Args@1) -> {Even@2, Odd@2} = Group@1(), ... end, ...} end,
    /// {Even@1, Odd@1} = Group@1()
    /// ```
    fn create_group(&mut self, group: &hoist::Group<'a>) {
        if let Some((variable, at)) = group.declared_late {
            let scoping = self.semantic.scoping();
            let function = group
                .functions
                .first()
                .and_then(|function| function.id.as_ref());
            let message = format!(
                "`{}` reads `{}`, which is declared after this first use of `{}`; declare `{}` before it",
                function.map_or("", |id| id.name.as_str()),
                scoping.symbol_name(variable),
                function.map_or("", |id| id.name.as_str()),
                scoping.symbol_name(variable),
            );
            self.report(at, Code::Capture, message);
            // The functions cannot be created: bind them to `undefined` to report nothing more.
            for function in &group.functions {
                self.hoisted.insert(function.span);
                if let Some(symbol) = function.id.as_ref().and_then(|id| id.symbol_id.get()) {
                    let name = self.scope.bind(Target::Symbol(symbol), "Undefined");
                    self.push_match(Expr::Var(name), Expr::undefined());
                }
            }
            return;
        }
        for function in &group.functions {
            self.hoisted.insert(function.span);
        }
        let targets: Vec<Target> = group
            .functions
            .iter()
            .filter_map(|function| function.id.as_ref()?.symbol_id.get())
            .map(Target::Symbol)
            .collect();
        if let ([function], [target]) = (group.functions.as_slice(), targets.as_slice()) {
            let name = self.scope.bind(*target, &self.base(*target));
            let fun = self.closure(Some(name.clone()), Callable::Function(function));
            self.push_match(Expr::Var(name), fun);
            return;
        }
        let group_name = self.scope.fresh("Group");
        let create = || Expr::Apply(Box::new(Expr::var(&group_name)), Vec::new());
        let funs = group
            .functions
            .iter()
            .map(|function| {
                self.closure_with(None, Callable::Function(function), |lowerer| {
                    let members = lowerer.rebind_tuple(&targets);
                    lowerer.push_match(members, create());
                })
            })
            .collect();
        let definition = Expr::Fun {
            name: Some(group_name.clone()),
            clauses: vec![Clause {
                patterns: Vec::new(),
                guards: Vec::new(),
                body: vec![Expr::Tuple(funs)],
            }],
        };
        self.push_match(Expr::var(&group_name), definition);
        let members = self.rebind_tuple(&targets);
        self.push_match(members, create());
    }

    fn statement(
        &mut self,
        statement: &'a Statement<'a>,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        match statement {
            Statement::ExpressionStatement(statement) => {
                self.expression_statement(&statement.expression, rest, tail)
            }
            Statement::IfStatement(branch) => self.if_statement(branch, rest, tail),
            Statement::SwitchStatement(switch) => self.switch_statement(switch, rest, tail),
            Statement::TryStatement(attempt) => self.try_statement(attempt, rest, tail),
            Statement::ForStatement(each) => self.for_statement(each, rest, tail),
            Statement::ForOfStatement(each) => self.for_of(each, rest, tail),
            Statement::ForInStatement(each) => self.for_in(each, rest, tail),
            Statement::WhileStatement(each) => {
                let state = self.rebound(each.span, |found| {
                    found.visit_expression(&each.test);
                    found.visit_statement(&each.body);
                });
                self.lower_loop(
                    &state,
                    Next::While,
                    Some(&each.test),
                    &each.body,
                    rest,
                    tail,
                )
            }
            Statement::DoWhileStatement(each) => {
                let state = self.rebound(each.span, |found| {
                    found.visit_expression(&each.test);
                    found.visit_statement(&each.body);
                });
                self.lower_loop(
                    &state,
                    Next::DoWhile(&each.test),
                    None,
                    &each.body,
                    rest,
                    tail,
                )
            }
            Statement::ReturnStatement(statement) => {
                self.return_statement(statement.argument.as_ref(), tail);
                Flow::Ended
            }
            Statement::BreakStatement(statement) => {
                if statement.label.is_some() {
                    self.unsupported(
                        statement.span,
                        "labeled `break` is not supported; return from a helper function instead",
                    );
                }
                self.break_statement(statement.span, tail);
                Flow::Ended
            }
            Statement::ContinueStatement(statement) => {
                if statement.label.is_some() {
                    self.unsupported(statement.span, "labeled `continue` is not supported; return from a helper function instead");
                }
                self.continue_statement(tail);
                Flow::Ended
            }
            Statement::ThrowStatement(statement) => {
                let value = self.expr(&statement.argument);
                self.seq.push(throw(value));
                Flow::Ended
            }
            Statement::LabeledStatement(statement) => {
                self.unsupported(
                    statement.span,
                    "labeled statements are not supported; move the loop into a function and return from it",
                );
                Flow::Continue
            }
            Statement::WithStatement(statement) => {
                self.unsupported(statement.span, "`with` is not supported");
                Flow::Continue
            }
            Statement::ExportDeclaration(export) => {
                self.declaration(&export.declaration);
                Flow::Continue
            }
            Statement::TSExportAssignment(export) => {
                self.unsupported(
                    export.span,
                    "`export =` is not supported; use a named export",
                );
                Flow::Continue
            }
            Statement::TSNamespaceExportDeclaration(export) => {
                self.unsupported(export.span, "`export as namespace` is not supported");
                Flow::Continue
            }
            other => {
                if let Some(declaration) = other.as_declaration() {
                    self.declaration(declaration);
                }
                Flow::Continue
            }
        }
    }

    fn declaration(&mut self, declaration: &'a Declaration<'a>) {
        match declaration {
            Declaration::TSImportEqualsDeclaration(import) if import.import_kind.is_value() => {
                self.unsupported(
                    import.span,
                    "`import x = require(...)` is not supported; use an import declaration",
                );
            }
            Declaration::VariableDeclaration(variables) => self.variable_declaration(variables),
            Declaration::FunctionDeclaration(function) => self.function_declaration(function),
            Declaration::ClassDeclaration(class) => {
                let at_module_scope = class
                    .id
                    .as_ref()
                    .and_then(|id| id.symbol_id.get())
                    .is_some_and(|symbol| self.module.is_module_scope(symbol));
                if !at_module_scope && !class.declare {
                    self.unsupported(class.span, "classes must be declared at module level");
                }
            }
            _ => {}
        }
    }

    fn variable_declaration(&mut self, variables: &'a VariableDeclaration<'a>) {
        if variables.declare {
            return;
        }
        match variables.kind {
            VariableDeclarationKind::Var => {
                let at_module_scope = variables.declarations.iter().any(|declarator| {
                    declarator
                        .id
                        .get_binding_identifier()
                        .and_then(|id| id.symbol_id.get())
                        .is_some_and(|symbol| self.module.is_module_scope(symbol))
                });
                if !at_module_scope {
                    self.unsupported(
                        variables.span,
                        "`var` is not supported; use `let` or `const`",
                    );
                }
            }
            VariableDeclarationKind::Using | VariableDeclarationKind::AwaitUsing => {
                self.unsupported(variables.span, "`using` declarations are not supported");
                return;
            }
            VariableDeclarationKind::Let | VariableDeclarationKind::Const => {}
        }
        for declarator in &variables.declarations {
            if let BindingPattern::BindingIdentifier(id) = &declarator.id
                && let Some(symbol) = id.symbol_id.get()
            {
                match self.module.bindings.get(&symbol) {
                    Some(Binding::Function(_)) => continue,
                    Some(Binding::Const {
                        literal: Some(literal),
                        key,
                    }) => {
                        if self.module.persisted.contains(&symbol) {
                            let put = self.persist(key, literal.clone());
                            self.seq.push(put);
                        }
                        continue;
                    }
                    _ => {}
                }
                if let Some(callable) = declarator.init.as_ref().and_then(Callable::of) {
                    let name = self
                        .scope
                        .bind(Target::Symbol(symbol), &base_name(&id.name));
                    // `const g = function f() {...}`: `f` names the same fun inside its body.
                    if let Callable::Function(function) = callable
                        && let Some(own) = function.id.as_ref().and_then(|id| id.symbol_id.get())
                    {
                        self.scope.set(Target::Symbol(own), name.clone());
                    }
                    let fun = self.closure(Some(name.clone()), callable);
                    self.push_match(Expr::Var(name), fun);
                    continue;
                }
            }
            let value = match &declarator.init {
                Some(init) => self.expr(init),
                None => Expr::undefined(),
            };
            self.bind_pattern(&declarator.id, value);
            for id in declarator.id.get_binding_identifiers() {
                if let Some(symbol) = id.symbol_id.get()
                    && self.module.persisted.contains(&symbol)
                    && let Some(current) = self.scope.current(Target::Symbol(symbol))
                {
                    let put = self.persist(&id.name, Expr::var(current));
                    self.seq.push(put);
                }
            }
        }
    }

    /// `persistent_term:put({Module, <<"key">>}, Value)` (section 2).
    fn persist(&self, key: &str, value: Expr) -> Expr {
        Expr::call(
            "persistent_term",
            "put",
            vec![
                Expr::Tuple(vec![Expr::atom(&self.module.name), Expr::binary(key)]),
                value,
            ],
        )
    }

    /// A nested function declaration that `block_of` did not create in a group.
    fn function_declaration(&mut self, function: &'a Function<'a>) {
        let (Some(id), Some(_)) = (&function.id, &function.body) else {
            return;
        };
        let Some(symbol) = id.symbol_id.get() else {
            return;
        };
        if self.module.is_module_scope(symbol)
            || self.pending.contains(&function.span)
            || !self.hoisted.insert(function.span)
        {
            return;
        }
        let name = self
            .scope
            .bind(Target::Symbol(symbol), &base_name(&id.name));
        let fun = self.closure(Some(name.clone()), Callable::Function(function));
        self.push_match(Expr::Var(name), fun);
    }

    fn expression_statement(
        &mut self,
        expression: &'a Expression<'a>,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        use oxc::syntax::operator::LogicalOperator;
        match strip(expression) {
            Expression::LogicalExpression(logical) if self.emits(&logical.right) => {
                let test = match logical.operator {
                    LogicalOperator::And => self.test(&logical.left),
                    LogicalOperator::Or => Expr::not(self.test(&logical.left)),
                    LogicalOperator::Coalesce => {
                        let value = self.expr(&logical.left);
                        nullish(value)
                    }
                };
                self.conditional_statement(
                    test,
                    &logical.right,
                    None,
                    expression.span(),
                    rest,
                    tail,
                )
            }
            Expression::ConditionalExpression(conditional)
                if self.emits(&conditional.consequent) || self.emits(&conditional.alternate) =>
            {
                let test = self.test(&conditional.test);
                self.conditional_statement(
                    test,
                    &conditional.consequent,
                    Some(&conditional.alternate),
                    expression.span(),
                    rest,
                    tail,
                )
            }
            _ => {
                self.effect(expression);
                Flow::Continue
            }
        }
    }

    /// `a && b;` and `c ? x : y;` as statements whose branches rebind variables.
    fn conditional_statement(
        &mut self,
        test: Expr,
        consequent: &'a Expression<'a>,
        alternate: Option<&'a Expression<'a>>,
        span: Span,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        let vars = self.rebound(span, |found| {
            found.visit_expression(consequent);
            if let Some(alternate) = alternate {
                found.visit_expression(alternate);
            }
        });
        let branch = Tail::Branch {
            vars: &vars,
            abrupt: false,
        };
        let yes = self.branch(|lowerer| {
            lowerer.effect(consequent);
            lowerer.fall_through(&branch);
        });
        let no = self.branch(|lowerer| {
            if let Some(alternate) = alternate {
                lowerer.effect(alternate);
            }
            lowerer.fall_through(&branch);
        });
        let construct = boolean_case(test, yes, no);
        self.finish(
            construct,
            Shape::Bare,
            &vars,
            Escapes::default(),
            rest,
            tail,
        )
    }

    fn if_statement(
        &mut self,
        branch: &'a IfStatement<'a>,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        let escapes = escapes(&branch.consequent).union(
            branch
                .alternate
                .as_ref()
                .map_or_else(Escapes::default, escapes),
        );
        let yes_falls = falls_through(Some(&branch.consequent));
        let no_falls = branch
            .alternate
            .as_ref()
            .is_none_or(|alternate| falls_through(Some(alternate)));
        if escapes.any() && !(yes_falls && no_falls) {
            return self.if_jumping(branch, [yes_falls, no_falls], rest, tail);
        }
        let vars = self.rebound(branch.span, |found| found.visit_if_statement(branch));
        let test = self.test(&branch.test);
        let inner = Tail::Branch {
            vars: &vars,
            abrupt: escapes.any(),
        };
        let yes = self.branch(|lowerer| lowerer.block_of(&[&branch.consequent], &inner));
        let no = self.branch(|lowerer| match &branch.alternate {
            Some(alternate) => lowerer.block_of(&[alternate], &inner),
            None => lowerer.fall_through(&inner),
        });
        self.finish(
            boolean_case(test, yes, no),
            Shape::Bare,
            &vars,
            escapes,
            rest,
            tail,
        )
    }

    /// An `if` with at most one branch that can reach its end: the rest of the block lowers
    /// once, inside that branch, and each jump lowers as if it ended the block.
    fn if_jumping(
        &mut self,
        branch: &'a IfStatement<'a>,
        falls: [bool; 2],
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        let test = self.test(&branch.test);
        let arms = [Some(&branch.consequent), branch.alternate.as_ref()];
        let [yes, no] = [0, 1].map(|index| {
            let arm = arms[index];
            let falls = falls[index];
            self.branch(|lowerer| {
                let mut statements: Vec<&'a Statement<'a>> = arm.into_iter().collect();
                if falls {
                    statements.extend_from_slice(rest);
                }
                lowerer.block_of(&statements, tail);
            })
        });
        self.seq.push(boolean_case(test, yes, no));
        Flow::Ended
    }

    fn switch_statement(
        &mut self,
        switch: &'a SwitchStatement<'a>,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        let vars = self.rebound(switch.span, |found| found.visit_switch_statement(switch));
        let escapes = Escapes {
            brk: false,
            ..switch.cases.iter().fold(Escapes::default(), |found, case| {
                found.union(escapes_all(&case.consequent))
            })
        };
        let groups = self.groups(&switch.cases);
        let dispatch = groups.iter().any(|group| group.default)
            && groups.iter().all(|group| {
                !falls_through(group.body.last().copied())
                    && !group
                        .body
                        .iter()
                        .any(|statement| rebind::escapes(statement).brk)
            });
        let discriminant = self.expr(&switch.discriminant);
        let discriminant = match discriminant {
            Expr::Var(_) => discriminant,
            other => {
                let name = self.scope.temp();
                self.push_match(Expr::var(&name), other);
                Expr::Var(name)
            }
        };
        self.targets.push(JumpTarget::Switch { vars: vars.clone() });
        let case_tail = Tail::SwitchCase {
            vars: &vars,
            abrupt: escapes.any(),
        };
        let inner = if dispatch { tail } else { &case_tail };
        let construct = if groups.iter().all(|group| {
            group
                .tests
                .iter()
                .all(|test| switch_literal(test).is_some())
        }) {
            self.switch_case(&discriminant, &groups, inner)
        } else {
            let mut body = self.switch_chain(&discriminant, &groups, inner);
            block_value(&mut body)
        };
        self.targets.pop();
        if dispatch {
            self.seq.push(construct);
            return Flow::Ended;
        }
        self.finish(construct, Shape::Bare, &vars, escapes, rest, tail)
    }

    /// Groups the cases that share a body, and rejects fall-through between bodies.
    fn groups(&mut self, cases: &'a [SwitchCase<'a>]) -> Vec<Group<'a>> {
        let mut groups: Vec<Group<'a>> = Vec::new();
        let mut pending = Group {
            tests: Vec::new(),
            default: false,
            body: Vec::new(),
        };
        for (index, case) in cases.iter().enumerate() {
            match &case.test {
                Some(test) => pending.tests.push(test),
                None => pending.default = true,
            }
            if case.consequent.is_empty() {
                continue;
            }
            if index + 1 < cases.len() && falls_through(case.consequent.last()) {
                self.unsupported(
                    case.span,
                    "`switch` fall-through between non-empty cases is not supported; end the case with `break` or `return`",
                );
            }
            pending.body = case.consequent.iter().collect();
            groups.push(std::mem::replace(
                &mut pending,
                Group {
                    tests: Vec::new(),
                    default: false,
                    body: Vec::new(),
                },
            ));
        }
        if pending.default || !pending.tests.is_empty() {
            groups.push(pending);
        }
        groups
    }

    /// A `case` on the discriminant when every test is a literal. The clauses keep the
    /// source order, so the first case that matches wins, and `default` ends the `case`.
    fn switch_case(&mut self, discriminant: &Expr, groups: &[Group<'a>], inner: &Tail<'_>) -> Expr {
        let mut clauses = Vec::new();
        let mut default = None;
        for group in groups {
            let body = self.branch(|lowerer| lowerer.block_of(&group.body, inner));
            if group.default {
                default = Some(body.clone());
            }
            let literals: Vec<(Expr, bool)> = group
                .tests
                .iter()
                .filter_map(|test| switch_literal(test))
                .collect();
            if literals.is_empty() {
                continue;
            }
            if let [(literal, true)] = literals.as_slice() {
                clauses.push(Clause::new(literal.clone(), body));
                continue;
            }
            let guards = literals
                .iter()
                .map(|(literal, exact)| {
                    let operator = if *exact { "=:=" } else { "==" };
                    Expr::op(operator, discriminant.clone(), literal.clone())
                })
                .collect();
            clauses.push(Clause::guarded(Expr::var("_"), guards, body));
        }
        let otherwise =
            default.unwrap_or_else(|| self.branch(|lowerer| lowerer.fall_through(inner)));
        clauses.push(Clause::new(Expr::var("_"), otherwise));
        Expr::case(discriminant.clone(), clauses)
    }

    /// Nested `case`s on `buoy_rt:strict_eq/2` when some test is not a literal. The tests
    /// run in source order, and `default` runs only when none matches.
    fn switch_chain(
        &mut self,
        discriminant: &Expr,
        groups: &[Group<'a>],
        inner: &Tail<'_>,
    ) -> Vec<Expr> {
        let default = groups.iter().find(|group| group.default);
        self.switch_tests(discriminant, groups, default, inner)
    }

    fn switch_tests(
        &mut self,
        discriminant: &Expr,
        groups: &[Group<'a>],
        default: Option<&Group<'a>>,
        inner: &Tail<'_>,
    ) -> Vec<Expr> {
        let Some((group, later)) = groups.split_first() else {
            return self.branch(|lowerer| match default {
                Some(group) => lowerer.block_of(&group.body, inner),
                None => lowerer.fall_through(inner),
            });
        };
        if group.tests.is_empty() {
            return self.switch_tests(discriminant, later, default, inner);
        }
        let body = self.branch(|lowerer| lowerer.block_of(&group.body, inner));
        let test = group
            .tests
            .iter()
            .map(|test| {
                let value = self.sub_expr(test);
                Expr::rt("strict_eq", vec![discriminant.clone(), value])
            })
            .reduce(|left, right| Expr::op("orelse", left, right))
            .unwrap_or_else(|| Expr::atom("false"));
        let otherwise = self.switch_tests(discriminant, later, default, inner);
        vec![boolean_case(test, body, otherwise)]
    }

    fn try_statement(
        &mut self,
        attempt: &'a TryStatement<'a>,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        let vars = self.rebound(attempt.span, |found| {
            found.visit_block_statement(&attempt.block);
            if let Some(handler) = &attempt.handler {
                found.visit_catch_clause(handler);
            }
        });
        let escapes = escapes_all(&attempt.block.body).union(
            attempt
                .handler
                .as_ref()
                .map_or_else(Escapes::default, |handler| escapes_all(&handler.body.body)),
        );
        if let Some(finalizer) = &attempt.finalizer {
            if escapes_all(&finalizer.body).any() {
                self.unsupported(
                    finalizer.span,
                    "a `finally` block that returns or jumps is not supported; move that code after the `try`",
                );
            }
            let assigns = !self
                .rebound(attempt.span, |found| found.visit_block_statement(finalizer))
                .is_empty();
            // In a generator body, a failed `yield*` skips `finally` (section 13), which an
            // Erlang `after` block cannot do.
            if assigns || self.generator {
                return self.try_finally_rebinding(attempt, escapes, rest, tail);
            }
        }
        let finalizer_reads = attempt.finalizer.as_ref().is_some_and(|finalizer| {
            rebind::reads_any(self.semantic.scoping(), &vars, |reads| {
                reads.visit_block_statement(finalizer);
            })
        });
        let checkpoint = (!vars.is_empty() && (attempt.handler.is_some() || finalizer_reads))
            .then(|| self.open_checkpoint(&vars));
        let inner = Tail::Branch {
            vars: &vars,
            abrupt: escapes.any(),
        };
        let body = self.branch(|lowerer| lowerer.block(&attempt.block.body, &inner));
        let catches = match &attempt.handler {
            Some(handler) => {
                let reason = self.scope.temp();
                let stack = self.scope.temp();
                let caught = Expr::rt("caught", vec![Expr::var(&reason), Expr::var(&stack)]);
                let body = self.branch(|lowerer| {
                    lowerer.restore_checkpoint(checkpoint.as_ref());
                    if let Some(param) = &handler.param {
                        lowerer.bind_pattern(&param.pattern, caught);
                    }
                    lowerer.block(&handler.body.body, &inner);
                });
                vec![CatchClause {
                    class: Expr::atom("error"),
                    reason: Expr::Var(reason),
                    stack,
                    body,
                }]
            }
            None => Vec::new(),
        };
        if checkpoint.is_some() {
            self.checkpoints.pop();
        }
        let after = self.finalizer(attempt, checkpoint.as_ref(), finalizer_reads);
        let construct = Expr::Try {
            body,
            catches,
            after,
        };
        self.finish(construct, Shape::Bare, &vars, escapes, rest, tail)
    }

    /// A `try` whose `finally` block rebinds variables. Erlang's `after` cannot export
    /// bindings, so the `finally` statements run after the `try` expression instead:
    ///
    /// ```erlang
    /// Outcome = try {done, try Body catch error:R:S -> Handler end}
    ///           catch Class:Reason:Stack -> {raised, Class, Reason, Stack} end,
    /// {Vars} = erlang:get(Key),
    /// Finally,
    /// case Outcome of {raised, C, R, S} -> erlang:raise(C, R, S); ... end
    /// ```
    ///
    /// The checkpoint gives the variables as they were when the body or handler ended, on
    /// every path. A jump that the body or handler made is rebuilt from the versions that
    /// the `finally` statements leave.
    fn try_finally_rebinding(
        &mut self,
        attempt: &'a TryStatement<'a>,
        escapes: Escapes,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        let vars = self.rebound(attempt.span, |found| found.visit_try_statement(attempt));
        let checkpoint = self.open_checkpoint(&vars);
        let inner = Tail::Branch {
            vars: &vars,
            abrupt: escapes.any(),
        };
        let body = self.branch(|lowerer| lowerer.block(&attempt.block.body, &inner));
        let protected = match &attempt.handler {
            Some(handler) => {
                let reason = self.scope.temp();
                let stack = self.scope.temp();
                let caught = Expr::rt("caught", vec![Expr::var(&reason), Expr::var(&stack)]);
                let recovery = self.branch(|lowerer| {
                    lowerer.restore_checkpoint(Some(&checkpoint));
                    if let Some(param) = &handler.param {
                        lowerer.bind_pattern(&param.pattern, caught);
                    }
                    lowerer.block(&handler.body.body, &inner);
                });
                Expr::Try {
                    body,
                    catches: vec![CatchClause {
                        class: Expr::atom("error"),
                        reason: Expr::Var(reason),
                        stack,
                        body: recovery,
                    }],
                    after: Vec::new(),
                }
            }
            None => Expr::Block(body),
        };
        self.checkpoints.pop();
        let raised = |lowerer: &mut Self| {
            let names = [
                lowerer.scope.temp(),
                lowerer.scope.temp(),
                lowerer.scope.temp(),
            ];
            let pattern = Expr::Tuple(
                std::iter::once(Expr::atom("raised"))
                    .chain(names.iter().map(Expr::var))
                    .collect(),
            );
            (names, pattern)
        };
        let ([class, reason, stack], caught) = raised(self);
        let mut catches = Vec::new();
        if self.generator {
            catches.push(self.abandon(&checkpoint));
        }
        catches.push(CatchClause {
            class: Expr::Var(class),
            reason: Expr::Var(reason),
            stack,
            body: vec![caught],
        });
        let outcome = self.scope.temp();
        self.seq.push(Expr::matches(
            Expr::var(&outcome),
            Expr::Try {
                body: vec![Expr::tagged("done", protected)],
                catches,
                after: Vec::new(),
            },
        ));
        self.restore_checkpoint(Some(&checkpoint));
        self.seq.push(Expr::call(
            "erlang",
            "erase",
            vec![Expr::var(&checkpoint.key)],
        ));
        if let Some(finalizer) = &attempt.finalizer {
            let quiet = Tail::Branch {
                vars: &[],
                abrupt: false,
            };
            self.block(&finalizer.body, &quiet);
            if self.seq.last() == Some(&Expr::ok()) {
                self.seq.pop();
            }
        }
        let ([class, reason, stack], pattern) = raised(self);
        let reraise = Clause::new(
            pattern,
            vec![Expr::call(
                "erlang",
                "raise",
                vec![Expr::Var(class), Expr::Var(reason), Expr::Var(stack)],
            )],
        );
        if !escapes.any() {
            self.seq.push(Expr::case(
                Expr::var(&outcome),
                vec![reraise, Clause::new(Expr::var("_"), vec![Expr::ok()])],
            ));
            return Flow::Continue;
        }
        let completion = self.rebuilt_completion(&outcome, reraise, escapes, &vars);
        self.finish(completion, Shape::Bare, &vars, escapes, rest, tail)
    }

    /// `throw:Reason:Stack -> erlang:erase(Key), erlang:raise(throw, Reason, Stack)`: a
    /// failed `yield*` throws, and Effect abandons the generator, so `finally` does not run.
    fn abandon(&mut self, checkpoint: &Checkpoint) -> CatchClause {
        let reason = self.scope.temp();
        let stack = self.scope.temp();
        CatchClause {
            class: Expr::atom("throw"),
            reason: Expr::var(&reason),
            body: vec![
                Expr::call("erlang", "erase", vec![Expr::var(&checkpoint.key)]),
                Expr::call(
                    "erlang",
                    "raise",
                    vec![Expr::atom("throw"), Expr::Var(reason), Expr::var(&stack)],
                ),
            ],
            stack,
        }
    }

    /// The completion of a `try` after its `finally` statements ran: each jump that the
    /// body or handler made, rebuilt from the current versions.
    fn rebuilt_completion(
        &mut self,
        outcome: &str,
        reraise: Clause,
        escapes: Escapes,
        vars: &[Target],
    ) -> Expr {
        let done = |completion: Expr| Expr::tagged("done", completion);
        let mut clauses = vec![
            reraise,
            Clause::new(
                done(Expr::tagged("next", Expr::var("_"))),
                vec![Expr::tagged("next", self.scope.tuple(vars))],
            ),
        ];
        if escapes.ret {
            let value = self.scope.temp();
            let rebuilt = match self.frame {
                super::Frame::Method => self.frame_return(Expr::call(
                    "erlang",
                    "element",
                    vec![Expr::Integer(1), Expr::var(&value)],
                )),
                super::Frame::Constructor => self.frame_return(Expr::undefined()),
                super::Frame::Function | super::Frame::Init => Expr::var(&value),
            };
            clauses.push(Clause::new(
                done(Expr::tagged("return", Expr::Var(value))),
                vec![Expr::tagged("return", rebuilt)],
            ));
        }
        if escapes.brk {
            let target = match self.targets.last() {
                Some(JumpTarget::Loop { state, .. }) => state.clone(),
                Some(JumpTarget::Switch { vars }) => vars.clone(),
                None => Vec::new(),
            };
            clauses.push(Clause::new(
                done(Expr::tagged("break", Expr::var("_"))),
                vec![Expr::tagged("break", self.scope.tuple(&target))],
            ));
        }
        if escapes.cont {
            let state = self.loop_state();
            clauses.push(Clause::new(
                done(Expr::tagged("continue", Expr::var("_"))),
                vec![Expr::tagged("continue", self.scope.tuple(&state))],
            ));
        }
        Expr::case(Expr::var(outcome), clauses)
    }

    /// The `after` block: the `finally` statements, then the removal of the checkpoint.
    fn finalizer(
        &mut self,
        attempt: &'a TryStatement<'a>,
        checkpoint: Option<&Checkpoint>,
        restore: bool,
    ) -> Vec<Expr> {
        if attempt.finalizer.is_none() && checkpoint.is_none() {
            return Vec::new();
        }
        let mut after = self.branch(|lowerer| {
            if let Some(finalizer) = &attempt.finalizer {
                if restore {
                    lowerer.restore_checkpoint(checkpoint);
                }
                lowerer.block(
                    &finalizer.body,
                    &Tail::Branch {
                        vars: &[],
                        abrupt: false,
                    },
                );
            }
        });
        if after.len() > 1 && after.last() == Some(&Expr::ok()) {
            after.pop();
        }
        if let Some(checkpoint) = checkpoint {
            if after == [Expr::ok()] {
                after.clear();
            }
            after.push(Expr::call(
                "erlang",
                "erase",
                vec![Expr::var(&checkpoint.key)],
            ));
        }
        after
    }

    /// Starts recording `vars` for a `try`: `Key = make_ref(), put(Key, {Vars})`.
    fn open_checkpoint(&mut self, vars: &[Target]) -> Checkpoint {
        let key = self.scope.temp();
        self.seq.push(Expr::matches(
            Expr::var(&key),
            Expr::call("erlang", "make_ref", Vec::new()),
        ));
        let tuple = self.scope.tuple(vars);
        self.seq
            .push(Expr::call("erlang", "put", vec![Expr::var(&key), tuple]));
        let checkpoint = Checkpoint {
            key,
            vars: vars.to_vec(),
        };
        self.checkpoints.push(checkpoint.clone());
        checkpoint
    }

    /// Rebinds the variables of a `try` to the values its body last recorded.
    fn restore_checkpoint(&mut self, checkpoint: Option<&Checkpoint>) {
        if let Some(checkpoint) = checkpoint {
            let tuple = self.rebind_tuple(&checkpoint.vars);
            self.seq.push(Expr::matches(
                tuple,
                Expr::call("erlang", "get", vec![Expr::var(&checkpoint.key)]),
            ));
        }
    }

    fn for_statement(
        &mut self,
        each: &'a ForStatement<'a>,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        match &each.init {
            Some(ForStatementInit::VariableDeclaration(variables)) => {
                self.variable_declaration(variables);
            }
            Some(init) => {
                if let Some(expression) = init.as_expression() {
                    self.effect(expression);
                }
            }
            None => {}
        }
        let state = self.rebound(each.body.span(), |found| {
            if let Some(test) = &each.test {
                found.visit_expression(test);
            }
            if let Some(update) = &each.update {
                found.visit_expression(update);
            }
            found.visit_statement(&each.body);
        });
        self.lower_loop(
            &state,
            Next::For(each.update.as_ref()),
            each.test.as_ref(),
            &each.body,
            rest,
            tail,
        )
    }

    fn lower_loop(
        &mut self,
        state: &[Target],
        next: Next<'a>,
        test: Option<&'a Expression<'a>>,
        body: &'a Statement<'a>,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        let escapes = escapes(body).out_of_loop();
        let fun = self.scope.fresh("Loop");
        let initial = self.scope.tuple(state);
        let versions = self.scope.versions();
        let outer = std::mem::take(&mut self.seq);
        let param = self.rebind_tuple(state);
        self.targets.push(JumpTarget::Loop {
            state: state.to_vec(),
            fun: fun.clone(),
            next,
        });
        match test.filter(|test| !is_true(test)) {
            Some(test) if !matches!(next, Next::DoWhile(_)) => {
                let condition = self.test(test);
                let looped = self.branch(|lowerer| lowerer.block_of(&[body], &Tail::LoopBody));
                let done = Expr::tagged("break", self.scope.tuple(state));
                self.seq.push(boolean_case(condition, looped, vec![done]));
            }
            _ => self.block_of(&[body], &Tail::LoopBody),
        }
        self.targets.pop();
        let fun_body = std::mem::replace(&mut self.seq, outer);
        self.scope.restore(versions);
        let definition = Expr::Fun {
            name: Some(fun.clone()),
            clauses: vec![Clause::new(param, fun_body)],
        };
        self.seq.push(Expr::matches(Expr::var(&fun), definition));
        let call = Expr::Apply(Box::new(Expr::Var(fun)), vec![initial]);
        self.finish(call, Shape::Break, state, escapes, rest, tail)
    }

    fn for_of(
        &mut self,
        each: &'a ForOfStatement<'a>,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        if each.r#await {
            self.unsupported(each.span, "`for await` is not supported yet");
        }
        let items = self.expr(&each.right);
        let items = Expr::rt("to_list", vec![items]);
        self.for_each(&each.left, items, &each.body, each.span, rest, tail)
    }

    fn for_in(
        &mut self,
        each: &'a ForInStatement<'a>,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        let object = self.expr(&each.right);
        let keys = Expr::rt("keys", vec![object]);
        self.for_each(&each.left, keys, &each.body, each.span, rest, tail)
    }

    /// `for...of` and `for...in`: a fun over the remaining items and the state tuple.
    fn for_each(
        &mut self,
        left: &'a ForStatementLeft<'a>,
        items: Expr,
        body: &'a Statement<'a>,
        span: Span,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        if let ForStatementLeft::VariableDeclaration(variables) = left
            && variables.kind == VariableDeclarationKind::Var
        {
            self.unsupported(
                variables.span,
                "`var` is not supported; use `let` or `const`",
            );
        }
        let state = self.rebound(span, |found| {
            if let Some(target) = left.as_assignment_target() {
                found.assigned(target);
                found.visit_assignment_target(target);
            }
            found.visit_statement(body);
        });
        let escapes = escapes(body).out_of_loop();
        let fun = self.scope.fresh("Loop");
        let initial = self.scope.tuple(&state);
        let versions = self.scope.versions();
        let outer = std::mem::take(&mut self.seq);
        let item = self.loop_item(left);
        let remaining = self.scope.fresh("Rest");
        let param = self.rebind_tuple(&state);
        self.targets.push(JumpTarget::Loop {
            state: state.clone(),
            fun: fun.clone(),
            next: Next::Each,
        });
        self.rests.push(remaining.clone());
        self.bind_loop_item(left, &item);
        self.block_of(&[body], &Tail::LoopBody);
        self.rests.pop();
        self.targets.pop();
        let fun_body = std::mem::replace(&mut self.seq, outer);
        self.scope.restore(versions);
        let done = self.scope.temp();
        let definition = Expr::Fun {
            name: Some(fun.clone()),
            clauses: vec![
                Clause {
                    patterns: vec![
                        Expr::Cons(vec![Expr::var(&item)], Box::new(Expr::Var(remaining))),
                        param,
                    ],
                    guards: Vec::new(),
                    body: fun_body,
                },
                Clause {
                    patterns: vec![Expr::List(Vec::new()), Expr::var(&done)],
                    guards: Vec::new(),
                    body: vec![Expr::tagged("break", Expr::Var(done))],
                },
            ],
        };
        self.seq.push(Expr::matches(Expr::var(&fun), definition));
        let call = Expr::Apply(Box::new(Expr::Var(fun)), vec![items, initial]);
        self.finish(call, Shape::Break, &state, escapes, rest, tail)
    }

    /// The variable that holds the current item: the loop variable itself when it is a
    /// plain identifier, otherwise a temporary.
    fn loop_item(&mut self, left: &'a ForStatementLeft<'a>) -> String {
        if let ForStatementLeft::VariableDeclaration(variables) = left
            && let Some(declarator) = variables.declarations.first()
            && let BindingPattern::BindingIdentifier(id) = &declarator.id
            && let Some(symbol) = id.symbol_id.get()
        {
            return self
                .scope
                .bind(Target::Symbol(symbol), &base_name(&id.name));
        }
        self.scope.temp()
    }

    fn bind_loop_item(&mut self, left: &'a ForStatementLeft<'a>, item: &str) {
        match left {
            ForStatementLeft::VariableDeclaration(variables) => {
                if let Some(declarator) = variables.declarations.first()
                    && !matches!(declarator.id, BindingPattern::BindingIdentifier(_))
                {
                    self.bind_pattern(&declarator.id, Expr::var(item));
                }
            }
            other => {
                if let Some(target) = other.as_assignment_target() {
                    self.assign_target(target, Expr::var(item));
                }
            }
        }
    }

    fn return_statement(&mut self, argument: Option<&'a Expression<'a>>, tail: &Tail<'_>) {
        let value = argument.map_or_else(Expr::undefined, |argument| self.expr(argument));
        let value = self.frame_return(value);
        match tail {
            Tail::Function => self.push(value),
            _ => self.seq.push(Expr::tagged("return", value)),
        }
    }

    fn break_statement(&mut self, span: Span, tail: &Tail<'_>) {
        let completion = match tail {
            Tail::SwitchCase { vars, abrupt } => self.exit(vars, *abrupt),
            Tail::LoopBody | Tail::Branch { .. } => match self.targets.last() {
                Some(JumpTarget::Loop { state, .. }) => {
                    Expr::tagged("break", self.scope.tuple(state))
                }
                Some(JumpTarget::Switch { vars }) => Expr::tagged("break", self.scope.tuple(vars)),
                None => self.unsupported(span, "`break` outside a loop or switch"),
            },
            Tail::Function => self.unsupported(span, "`break` outside a loop or switch"),
        };
        self.seq.push(completion);
    }

    fn continue_statement(&mut self, tail: &Tail<'_>) {
        if let Tail::LoopBody = tail {
            self.next_iteration();
            return;
        }
        let state = self.loop_state();
        let completion = Expr::tagged("continue", self.scope.tuple(&state));
        self.seq.push(completion);
    }

    /// The state variables of the innermost loop.
    fn loop_state(&self) -> Vec<Target> {
        self.targets
            .iter()
            .rev()
            .find_map(|target| match target {
                JumpTarget::Loop { state, .. } => Some(state.clone()),
                JumpTarget::Switch { .. } => None,
            })
            .unwrap_or_default()
    }

    /// Ends the current loop body by starting the next iteration (section 12).
    fn next_iteration(&mut self) {
        let Some((state, fun, next)) = self.targets.iter().rev().find_map(|target| match target {
            JumpTarget::Loop { state, fun, next } => Some((state.clone(), fun.clone(), *next)),
            JumpTarget::Switch { .. } => None,
        }) else {
            return;
        };
        let call = |lowerer: &Self| {
            Expr::Apply(Box::new(Expr::var(&fun)), vec![lowerer.scope.tuple(&state)])
        };
        match next {
            Next::For(update) => {
                if let Some(update) = update {
                    self.effect(update);
                }
                let call = call(self);
                self.seq.push(call);
            }
            Next::While => {
                let call = call(self);
                self.seq.push(call);
            }
            Next::DoWhile(test) => {
                let condition = self.test(test);
                let again = call(self);
                let done = Expr::tagged("break", self.scope.tuple(&state));
                self.seq
                    .push(boolean_case(condition, vec![again], vec![done]));
            }
            Next::Each => {
                let remaining = self.rests.last().cloned().unwrap_or_default();
                let call = Expr::Apply(
                    Box::new(Expr::var(&fun)),
                    vec![Expr::Var(remaining), self.scope.tuple(&state)],
                );
                self.seq.push(call);
            }
        }
    }

    /// Ends a block as `tail` requires when control reaches its end.
    pub fn fall_through(&mut self, tail: &Tail<'_>) {
        let end = match tail {
            Tail::Function => self.frame_return(Expr::undefined()),
            Tail::Branch { vars, abrupt } | Tail::SwitchCase { vars, abrupt } => {
                self.exit(vars, *abrupt)
            }
            Tail::LoopBody => {
                self.next_iteration();
                return;
            }
        };
        self.seq.push(end);
    }

    /// The normal completion of a construct that rebinds `vars`.
    fn exit(&self, vars: &[Target], abrupt: bool) -> Expr {
        let tuple = self.scope.tuple(vars);
        match (abrupt, vars.is_empty()) {
            (true, _) => Expr::tagged("next", tuple),
            (false, true) => Expr::ok(),
            (false, false) => tuple,
        }
    }

    /// Binds the result of a construct, or lowers the rest of the block inside the
    /// `{next, ...}` clause of a `case` on its completion (section 12).
    pub fn finish(
        &mut self,
        construct: Expr,
        shape: Shape,
        vars: &[Target],
        escapes: Escapes,
        rest: &[&'a Statement<'a>],
        tail: &Tail<'_>,
    ) -> Flow {
        let tag = match shape {
            Shape::Bare => "next",
            Shape::Break => "break",
        };
        if !escapes.any() {
            if vars.is_empty() {
                self.push(construct);
            } else {
                let tuple = self.rebind_tuple(vars);
                let pattern = match shape {
                    Shape::Bare => tuple,
                    Shape::Break => Expr::tagged(tag, tuple),
                };
                self.push_match(pattern, construct);
            }
            return Flow::Continue;
        }
        let completion = match construct {
            Expr::Case(..) | Expr::Try { .. } => {
                let name = self.scope.temp();
                self.seq.push(Expr::matches(Expr::var(&name), construct));
                Expr::Var(name)
            }
            other => other,
        };
        let versions = self.scope.versions();
        let pattern = Expr::tagged(tag, self.rebind_tuple(vars));
        let continuation = self.branch(|lowerer| lowerer.block_of(rest, tail));
        self.scope.restore(versions);
        let mut clauses = vec![Clause::new(pattern, continuation)];
        clauses.extend(self.forward(escapes, tail));
        self.seq.push(Expr::case(completion, clauses));
        Flow::Ended
    }

    /// The clauses that pass an abrupt completion on to the enclosing frame.
    fn forward(&mut self, escapes: Escapes, tail: &Tail<'_>) -> Vec<Clause> {
        let mut clauses = Vec::new();
        match tail {
            Tail::Function => {
                let value = self.scope.temp();
                clauses.push(Clause::new(
                    Expr::tagged("return", Expr::var(&value)),
                    vec![Expr::Var(value)],
                ));
            }
            Tail::Branch { .. } => clauses.push(self.pass_on()),
            Tail::SwitchCase { abrupt, .. } => {
                if escapes.brk {
                    let state = self.scope.temp();
                    let exit = if *abrupt {
                        Expr::tagged("next", Expr::var(&state))
                    } else {
                        Expr::var(&state)
                    };
                    clauses.push(Clause::new(
                        Expr::tagged("break", Expr::Var(state)),
                        vec![exit],
                    ));
                }
                if escapes.ret || escapes.cont {
                    clauses.push(self.pass_on());
                }
            }
            Tail::LoopBody => {
                if escapes.cont {
                    let versions = self.scope.versions();
                    let state = self.loop_state();
                    let pattern = Expr::tagged("continue", self.rebind_tuple(&state));
                    let body = self.branch(Self::next_iteration);
                    self.scope.restore(versions);
                    clauses.push(Clause::new(pattern, body));
                }
                if escapes.brk || escapes.ret {
                    clauses.push(self.pass_on());
                }
            }
        }
        clauses
    }

    fn pass_on(&mut self) -> Clause {
        let other = self.scope.temp();
        Clause::new(Expr::var(&other), vec![Expr::Var(other)])
    }
}

/// Expands nested blocks in place. Lexical scoping survives because versions are keyed by
/// symbol.
pub fn flatten<'a>(statements: &[&'a Statement<'a>]) -> Vec<&'a Statement<'a>> {
    let mut flat = Vec::with_capacity(statements.len());
    for statement in statements {
        match statement {
            Statement::BlockStatement(block) => {
                let inner: Vec<&'a Statement<'a>> = block.body.iter().collect();
                flat.extend(flatten(&inner));
            }
            other => flat.push(*other),
        }
    }
    flat
}

/// `erlang:error({'$throw', Value})` (section 7).
pub fn throw(value: Expr) -> Expr {
    Expr::call("erlang", "error", vec![Expr::tagged("$throw", value)])
}

pub fn boolean_case(test: Expr, yes: Vec<Expr>, no: Vec<Expr>) -> Expr {
    Expr::case(
        test,
        vec![
            Clause::new(Expr::atom("true"), yes),
            Clause::new(Expr::atom("false"), no),
        ],
    )
}

/// `true` when `value` is `null` or `undefined`.
pub fn nullish(value: Expr) -> Expr {
    Expr::case(
        value,
        vec![
            Clause::new(Expr::atom("null"), vec![Expr::atom("true")]),
            Clause::new(Expr::undefined(), vec![Expr::atom("true")]),
            Clause::new(Expr::var("_"), vec![Expr::atom("false")]),
        ],
    )
}

fn block_value(body: &mut Vec<Expr>) -> Expr {
    if body.len() == 1 {
        body.pop().unwrap_or_else(Expr::ok)
    } else {
        Expr::Block(std::mem::take(body))
    }
}

fn is_true(test: &Expression<'_>) -> bool {
    matches!(strip(test), Expression::BooleanLiteral(literal) if literal.value)
}

/// A `case` test that can be matched without `buoy_rt:strict_eq/2`, and whether it compares
/// exactly (`=:=`) rather than numerically (`==`).
fn switch_literal(test: &Expression<'_>) -> Option<(Expr, bool)> {
    let literal = super::expr::literal(test)?;
    match literal {
        Expr::Binary(_) | Expr::Atom(_) => Some((literal, true)),
        Expr::Integer(_) | Expr::Float(_) => Some((literal, false)),
        _ => None,
    }
}
