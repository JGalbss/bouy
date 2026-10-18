//! The body of one function of an island: its statements and expressions, typed and
//! lowered to the IR.
//!
//! The checker is the authority on types: a TypeScript annotation is a claim that it
//! verifies, never a fact it trusts. Every value of an island comes from a literal, an
//! object or array that the island makes, a parameter of the entry, or a global, and the
//! entry checks the types of those last two at run time. So the types hold for every run.

use std::collections::{BTreeSet, HashMap};

use buoy_jit_ir::{self as ir, Bail, Binary as Op, MathFn, Unary};
use oxc::ast::AstKind;
use oxc::ast::ast::{
    Argument, ArrayExpressionElement, AssignmentOperator, AssignmentTarget, BinaryOperator,
    BindingPattern, CallExpression, ComputedMemberExpression, Expression, ForStatementInit,
    ForStatementLeft, IdentifierReference, LogicalOperator, NewExpression, SimpleAssignmentTarget,
    Statement, StaticMemberExpression, SwitchStatement, UnaryOperator, UpdateOperator,
    VariableDeclaration, VariableDeclarationKind,
};
use oxc::semantic::{ScopeId, SymbolId};

use super::island::{Checked, Island, Job, Owner, Reject, Signature, T, reject, statements};

/// The fields that a constructor has not yet assigned, while `this` must not escape.
struct Pending {
    class: ir::ClassId,
    fields: BTreeSet<u32>,
    /// Whether `super(...)` must run before `this` exists.
    needs_super: bool,
}

pub struct Body<'i, 'a, 's> {
    island: &'i mut Island<'a, 's>,
    locals: Vec<T>,
    names: HashMap<SymbolId, u32>,
    result: T,
    /// The class of `this`, which is local 0.
    this: Option<ir::ClassId>,
    /// The enclosing loops, innermost last: whether each takes `continue`.
    loops: Vec<bool>,
    scope: Option<ScopeId>,
    pending: Option<Pending>,
    /// How deep the current statement is in branches and loops.
    depth: usize,
    /// The class of the constructor being compiled.
    constructing: Option<ir::ClassId>,
}

impl<'i, 'a, 's> Body<'i, 'a, 's> {
    pub fn compile(island: &'i mut Island<'a, 's>, job: &Job<'a>) -> Checked<ir::Function> {
        let this = match job.owner {
            Owner::Method(class) | Owner::Constructor(class, _) => Some(class),
            Owner::Plain | Owner::Static => None,
        };
        let mut body = Body {
            island,
            locals: Vec::new(),
            names: HashMap::new(),
            result: job.signature.result.clone(),
            this,
            loops: Vec::new(),
            scope: job.function.and_then(|function| function.scope_id.get()),
            pending: None,
            depth: 0,
            constructing: match job.owner {
                Owner::Constructor(class, _) => Some(class),
                _ => None,
            },
        };
        let mut params = job.signature.params.iter();
        if let Some(class) = this {
            body.locals.push(T::Class(class));
            params.next();
        }
        if let Some(function) = job.function {
            for (param, ty) in function.params.items.iter().zip(params) {
                let BindingPattern::BindingIdentifier(id) = &param.pattern else {
                    return reject("a destructured parameter");
                };
                let symbol = id.symbol_id();
                body.declare(symbol, ty.clone());
            }
        } else {
            // A default constructor: its parameters are those of the parent's.
            for ty in params {
                body.local(ty.clone());
            }
        }
        let count = u32::try_from(body.locals.len()).map_err(|e| Reject(e.to_string()))?;
        let stmts = match job.owner {
            Owner::Constructor(class, declared) => body.constructor(class, declared)?,
            _ => body.stmts(job.function.map_or(&[], statements))?,
        };
        Ok(ir::Function {
            receiver: this.is_some(),
            name: job.name.clone(),
            params: count,
            locals: body.locals.iter().map(T::ir).collect(),
            result: body.result.ir(),
            body: stmts,
        })
    }

    fn local(&mut self, ty: T) -> u32 {
        self.locals.push(ty);
        u32::try_from(self.locals.len() - 1).unwrap_or(u32::MAX)
    }

    fn declare(&mut self, symbol: SymbolId, ty: T) -> u32 {
        let id = self.local(ty);
        self.names.insert(symbol, id);
        id
    }

    /// The body of a constructor. A base class runs its field initializers first; a
    /// derived class runs them right after `super(...)` returns. Until every field without
    /// an initializer is assigned, `this` appears only as the object of such assignments,
    /// so no code can read a field that holds no value yet.
    fn constructor(
        &mut self,
        class: ir::ClassId,
        declared: Option<&'a oxc::ast::ast::Function<'a>>,
    ) -> Checked<Vec<ir::Stmt>> {
        let parent = self.island.classes[class as usize].parent;
        let own = self.island.classes[class as usize].own.clone();
        let base = u32::try_from(own.len()).map_err(|e| Reject(e.to_string()))?;
        let first = u32::try_from(self.island.classes[class as usize].fields.len())
            .map_err(|e| Reject(e.to_string()))?
            - base;
        let fields: BTreeSet<u32> = own
            .iter()
            .enumerate()
            .filter(|(_, (_, _, init))| init.is_none())
            .filter_map(|(index, _)| u32::try_from(index).ok().map(|i| first + i))
            .collect();
        let mut stmts = Vec::new();
        if parent.is_none() {
            stmts.extend(self.field_initializers(class)?);
        }
        let Some(function) = declared else {
            if let Some(parent) = parent {
                let constructor = self.island.constructor(parent)?;
                let count = u32::try_from(self.locals.len()).map_err(|e| Reject(e.to_string()))?;
                let args = (0..count).map(ir::Expr::Local).collect();
                stmts.push(ir::Stmt::Expr(ir::Expr::Call(constructor, args)));
                stmts.extend(self.field_initializers(class)?);
            }
            if !fields.is_empty() {
                return reject("a field that the class never assigns");
            }
            return Ok(stmts);
        };
        self.pending = Some(Pending {
            class,
            fields,
            needs_super: parent.is_some(),
        });
        self.release();
        stmts.extend(self.stmts(statements(function))?);
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| !pending.fields.is_empty() || pending.needs_super)
        {
            return reject("a constructor that does not assign every field");
        }
        Ok(stmts)
    }

    /// The writes of the field initializers of the class itself.
    fn field_initializers(&mut self, class: ir::ClassId) -> Checked<Vec<ir::Stmt>> {
        let own = self.island.classes[class as usize].own.clone();
        let total = self.island.classes[class as usize].fields.len();
        let first = total - own.len();
        let mut stmts = Vec::new();
        for (offset, (_, ty, init)) in own.iter().enumerate() {
            let Some(init) = init else {
                continue;
            };
            if mentions_this(init) {
                return reject("a field initializer that reads this");
            }
            let value = self.expr_to(init, ty)?;
            let index = u32::try_from(first + offset).map_err(|e| Reject(e.to_string()))?;
            stmts.push(ir::Stmt::Expr(ir::Expr::SetField(
                Box::new(ir::Expr::Local(0)),
                class,
                index,
                Box::new(value),
            )));
        }
        Ok(stmts)
    }

    fn stmts(&mut self, statements: &'a [Statement<'a>]) -> Checked<Vec<ir::Stmt>> {
        let mut out = Vec::new();
        for statement in statements {
            out.extend(self.stmt(statement)?);
        }
        Ok(out)
    }

    /// The statements of a nested body: a branch or a loop.
    fn nested(&mut self, statement: &'a Statement<'a>) -> Checked<Vec<ir::Stmt>> {
        self.depth += 1;
        let result = self.stmt(statement);
        self.depth -= 1;
        result
    }

    fn stmt(&mut self, statement: &'a Statement<'a>) -> Checked<Vec<ir::Stmt>> {
        Ok(match statement {
            Statement::EmptyStatement(_) => Vec::new(),
            Statement::BlockStatement(block) => self.stmts(&block.body)?,
            Statement::ExpressionStatement(statement) => {
                vec![ir::Stmt::Expr(self.effect(&statement.expression)?)]
            }
            Statement::VariableDeclaration(declaration) => self.variables(declaration)?,
            Statement::ReturnStatement(statement) => {
                let value = match &statement.argument {
                    Some(argument) => {
                        if self.result == T::Void {
                            return reject("a value returned from a function of type void");
                        }
                        let result = self.result.clone();
                        Some(self.expr_to(argument, &result)?)
                    }
                    None if self.result == T::Void => None,
                    None => return reject("a return without a value"),
                };
                vec![ir::Stmt::Return(value)]
            }
            // The Erlang tier runs the call again and throws the value itself.
            Statement::ThrowStatement(_) => vec![ir::Stmt::Bail(Bail::Throw)],
            Statement::IfStatement(statement) => {
                let test = self.condition(&statement.test)?;
                let then = self.nested(&statement.consequent)?;
                let otherwise = match &statement.alternate {
                    Some(alternate) => self.nested(alternate)?,
                    None => Vec::new(),
                };
                vec![ir::Stmt::If(test, then, otherwise)]
            }
            Statement::WhileStatement(_)
            | Statement::DoWhileStatement(_)
            | Statement::ForStatement(_) => self.loop_stmt(statement)?,
            Statement::ForOfStatement(statement) => self.for_of(statement)?,
            Statement::BreakStatement(statement) => {
                if statement.label.is_some() || self.loops.is_empty() {
                    return reject("a labeled break");
                }
                vec![ir::Stmt::Break(0)]
            }
            Statement::ContinueStatement(statement) => {
                if statement.label.is_some() {
                    return reject("a labeled continue");
                }
                let depth = self
                    .loops
                    .iter()
                    .rev()
                    .position(|takes_continue| *takes_continue)
                    .ok_or_else(|| Reject("a continue outside a loop".into()))?;
                vec![ir::Stmt::Continue(
                    u32::try_from(depth).map_err(|e| Reject(e.to_string()))?,
                )]
            }
            Statement::SwitchStatement(statement) => self.switch(statement)?,
            _ => return reject("a statement that the native tier does not lower"),
        })
    }

    /// `while`, `do...while`, and `for`.
    fn loop_stmt(&mut self, statement: &'a Statement<'a>) -> Checked<Vec<ir::Stmt>> {
        Ok(match statement {
            Statement::WhileStatement(statement) => {
                let cond = self.condition(&statement.test)?;
                let body = self.loop_body(true, |me| me.nested(&statement.body))?;
                vec![ir::Stmt::Loop {
                    cond: Some(cond),
                    body,
                    update: Vec::new(),
                    test_after: false,
                }]
            }
            Statement::DoWhileStatement(statement) => {
                let body = self.loop_body(true, |me| me.nested(&statement.body))?;
                let cond = self.condition(&statement.test)?;
                vec![ir::Stmt::Loop {
                    cond: Some(cond),
                    body,
                    update: Vec::new(),
                    test_after: true,
                }]
            }
            Statement::ForStatement(statement) => {
                let mut out = Vec::new();
                match &statement.init {
                    None => {}
                    Some(ForStatementInit::VariableDeclaration(declaration)) => {
                        out.extend(self.variables(declaration)?);
                    }
                    Some(init) => {
                        let expression = init
                            .as_expression()
                            .ok_or_else(|| Reject("a for initializer".into()))?;
                        out.push(ir::Stmt::Expr(self.effect(expression)?));
                    }
                }
                let cond = match &statement.test {
                    Some(test) => Some(self.condition(test)?),
                    None => None,
                };
                let body = self.loop_body(true, |me| me.nested(&statement.body))?;
                let update = match &statement.update {
                    Some(update) => vec![ir::Stmt::Expr(self.effect(update)?)],
                    None => Vec::new(),
                };
                out.push(ir::Stmt::Loop {
                    cond,
                    body,
                    update,
                    test_after: false,
                });
                out
            }
            _ => return reject("a statement that is not a loop"),
        })
    }

    fn loop_body(
        &mut self,
        takes_continue: bool,
        body: impl FnOnce(&mut Self) -> Checked<Vec<ir::Stmt>>,
    ) -> Checked<Vec<ir::Stmt>> {
        self.loops.push(takes_continue);
        let result = body(self);
        self.loops.pop();
        result
    }

    /// `for (const x of array)`: a loop over the indexes, which reads the length on each
    /// turn as the array iterator does.
    fn for_of(
        &mut self,
        statement: &'a oxc::ast::ast::ForOfStatement<'a>,
    ) -> Checked<Vec<ir::Stmt>> {
        if statement.r#await {
            return reject("for await");
        }
        let ForStatementLeft::VariableDeclaration(declaration) = &statement.left else {
            return reject("a for...of over an existing variable");
        };
        let [declarator] = declaration.declarations.as_slice() else {
            return reject("a for...of with more than one binding");
        };
        let BindingPattern::BindingIdentifier(id) = &declarator.id else {
            return reject("a destructured for...of binding");
        };
        if declaration.kind == VariableDeclarationKind::Var {
            return reject("a for...of over a var");
        }
        let (array, array_ty) = self.expr(&statement.right)?;
        let T::Array(element) = array_ty.clone() else {
            return reject("a for...of over a value that is not an array");
        };
        let held = self.local(array_ty);
        let index = self.local(T::Num);
        let item = self.declare(id.symbol_id(), *element);
        let read = ir::Stmt::Expr(ir::Expr::SetLocal(
            item,
            Box::new(ir::Expr::Index(
                Box::new(ir::Expr::Local(held)),
                Box::new(ir::Expr::Local(index)),
            )),
        ));
        let mut body = vec![read];
        body.extend(self.loop_body(true, |me| me.nested(&statement.body))?);
        Ok(vec![
            ir::Stmt::Expr(ir::Expr::SetLocal(held, Box::new(array))),
            ir::Stmt::Expr(ir::Expr::SetLocal(index, Box::new(ir::Expr::Num(0.0)))),
            ir::Stmt::Loop {
                cond: Some(ir::Expr::Binary(
                    Op::Lt,
                    Box::new(ir::Expr::Local(index)),
                    Box::new(ir::Expr::Length(Box::new(ir::Expr::Local(held)))),
                )),
                body,
                update: vec![ir::Stmt::Expr(ir::Expr::SetLocal(
                    index,
                    Box::new(ir::Expr::Binary(
                        Op::Add,
                        Box::new(ir::Expr::Local(index)),
                        Box::new(ir::Expr::Num(1.0)),
                    )),
                ))],
                test_after: false,
            },
        ])
    }

    /// `switch`: the index of the first case that matches, or of `default`, then each
    /// case body in order that runs when the index is at most its own, inside a loop that
    /// runs once so that `break` leaves it.
    fn switch(&mut self, statement: &'a SwitchStatement<'a>) -> Checked<Vec<ir::Stmt>> {
        let (discriminant, ty) = self.expr(&statement.discriminant)?;
        let held = self.local(ty);
        let selected = self.local(T::Num);
        let mut out = vec![
            ir::Stmt::Expr(ir::Expr::SetLocal(held, Box::new(discriminant))),
            ir::Stmt::Expr(ir::Expr::SetLocal(selected, Box::new(ir::Expr::Num(-1.0)))),
        ];
        let default = statement.cases.iter().position(|case| case.test.is_none());
        let mut chain: Vec<ir::Stmt> = match default {
            Some(index) => vec![set_number(selected, index)],
            None => Vec::new(),
        };
        for (index, case) in statement.cases.iter().enumerate().rev() {
            let Some(test) = &case.test else {
                continue;
            };
            let (value, _) = self.expr(test)?;
            let matched =
                ir::Expr::Binary(Op::Eq, Box::new(ir::Expr::Local(held)), Box::new(value));
            chain = vec![ir::Stmt::If(
                matched,
                vec![set_number(selected, index)],
                chain,
            )];
        }
        out.extend(chain);
        let mut bodies = Vec::new();
        self.loops.push(false);
        self.depth += 1;
        for (index, case) in statement.cases.iter().enumerate() {
            let stmts = self.stmts(&case.consequent);
            let stmts = match stmts {
                Ok(stmts) => stmts,
                Err(error) => {
                    self.loops.pop();
                    self.depth -= 1;
                    return Err(error);
                }
            };
            let runs = ir::Expr::And(
                Box::new(ir::Expr::Binary(
                    Op::Ge,
                    Box::new(ir::Expr::Local(selected)),
                    Box::new(ir::Expr::Num(0.0)),
                )),
                Box::new(ir::Expr::Binary(
                    Op::Le,
                    Box::new(ir::Expr::Local(selected)),
                    Box::new(number(index)),
                )),
            );
            bodies.push(ir::Stmt::If(runs, stmts, Vec::new()));
        }
        self.loops.pop();
        self.depth -= 1;
        bodies.push(ir::Stmt::Break(0));
        out.push(ir::Stmt::Loop {
            cond: None,
            body: bodies,
            update: Vec::new(),
            test_after: false,
        });
        Ok(out)
    }

    fn variables(&mut self, declaration: &'a VariableDeclaration<'a>) -> Checked<Vec<ir::Stmt>> {
        if declaration.kind == VariableDeclarationKind::Var || declaration.declare {
            return reject("a var declaration");
        }
        let mut out = Vec::new();
        for declarator in &declaration.declarations {
            let BindingPattern::BindingIdentifier(id) = &declarator.id else {
                return reject("a destructuring declaration");
            };
            let annotated = match &declarator.type_annotation {
                Some(annotation) => Some(self.island.annotation(annotation)?),
                None => None,
            };
            let (value, ty) = match (&declarator.init, annotated) {
                (Some(init), Some(ty)) => (self.expr_to(init, &ty)?, ty),
                (Some(init), None) => {
                    let (value, ty) = self.expr(init)?;
                    if ty == T::Null || ty == T::Void {
                        return reject("a variable of null without a type");
                    }
                    (value, ty)
                }
                (None, Some(ty)) if ty.is_reference() => (ir::Expr::Undefined, ty),
                _ => return reject("a variable without a value"),
            };
            let local = self.declare(id.symbol_id(), ty);
            out.push(ir::Stmt::Expr(ir::Expr::SetLocal(local, Box::new(value))));
        }
        Ok(out)
    }

    /// An expression whose value is not used.
    fn effect(&mut self, expression: &'a Expression<'a>) -> Checked<ir::Expr> {
        Ok(self.expr(expression)?.0)
    }

    /// The truth value of an expression, as `if` and `while` test it.
    fn condition(&mut self, expression: &'a Expression<'a>) -> Checked<ir::Expr> {
        let (value, ty) = self.expr(expression)?;
        Ok(match ty {
            T::Bool => value,
            T::Num | T::Class(_) | T::Iface(_) | T::Array(_) | T::Null => {
                ir::Expr::Unary(Unary::Truthy, Box::new(value))
            }
            T::Void => return reject("a test of a void value"),
        })
    }

    /// An expression where a value of type `ty` goes.
    fn expr_to(&mut self, expression: &'a Expression<'a>, ty: &T) -> Checked<ir::Expr> {
        if let (Expression::ArrayExpression(array), T::Array(element)) = (expression, ty) {
            return Ok(self.array_literal(array, Some(element))?.0);
        }
        if let (Expression::ParenthesizedExpression(inner), _) = (expression, ty) {
            return self.expr_to(&inner.expression, ty);
        }
        let (value, found) = self.expr(expression)?;
        if !self.island.fits(&found, ty) {
            return reject(format!("a value of {found:?} where {ty:?} goes"));
        }
        Ok(value)
    }

    fn expr(&mut self, expression: &'a Expression<'a>) -> Checked<(ir::Expr, T)> {
        Ok(match expression {
            Expression::NumericLiteral(number) => (ir::Expr::Num(number.value), T::Num),
            Expression::BooleanLiteral(flag) => (ir::Expr::Bool(flag.value), T::Bool),
            Expression::NullLiteral(_) => (ir::Expr::Null, T::Null),
            Expression::ParenthesizedExpression(inner) => self.expr(&inner.expression)?,
            Expression::TSNonNullExpression(inner) => self.expr(&inner.expression)?,
            Expression::TSSatisfiesExpression(inner) => self.expr(&inner.expression)?,
            Expression::Identifier(ident) => self.identifier(ident)?,
            Expression::ThisExpression(_) => self.this_value()?,
            Expression::StaticMemberExpression(member) => self.static_member(member)?,
            Expression::ComputedMemberExpression(member) => self.computed_member(member)?,
            Expression::CallExpression(call) => self.call(call)?,
            Expression::NewExpression(new) => self.new_expr(new, None)?,
            Expression::ArrayExpression(array) => self.array_literal(array, None)?,
            Expression::UnaryExpression(unary) => self.unary(unary.operator, &unary.argument)?,
            Expression::UpdateExpression(update) => self.update(update)?,
            Expression::BinaryExpression(binary) => {
                self.binary(binary.operator, &binary.left, &binary.right)?
            }
            Expression::LogicalExpression(logical) => {
                let left = self.condition_strict(&logical.left)?;
                let right = self.condition_strict(&logical.right)?;
                let value = match logical.operator {
                    LogicalOperator::And => ir::Expr::And(Box::new(left), Box::new(right)),
                    LogicalOperator::Or => ir::Expr::Or(Box::new(left), Box::new(right)),
                    LogicalOperator::Coalesce => return reject("??"),
                };
                (value, T::Bool)
            }
            Expression::ConditionalExpression(conditional) => {
                let test = self.condition(&conditional.test)?;
                let (then, then_ty) = self.expr(&conditional.consequent)?;
                let (otherwise, else_ty) = self.expr(&conditional.alternate)?;
                let ty = self.join(&then_ty, &else_ty)?;
                (
                    ir::Expr::Cond(ty.ir(), Box::new(test), Box::new(then), Box::new(otherwise)),
                    ty,
                )
            }
            Expression::AssignmentExpression(assignment) => self.assignment(assignment)?,
            Expression::SequenceExpression(sequence) => {
                let mut items = Vec::with_capacity(sequence.expressions.len());
                let mut ty = T::Void;
                for item in &sequence.expressions {
                    let (value, item_ty) = self.expr(item)?;
                    items.push(value);
                    ty = item_ty;
                }
                (ir::Expr::Seq(items), ty)
            }
            _ => return reject("an expression that the native tier does not lower"),
        })
    }

    /// A boolean operand of `&&` or `||`, whose result is the operand itself.
    fn condition_strict(&mut self, expression: &'a Expression<'a>) -> Checked<ir::Expr> {
        let (value, ty) = self.expr(expression)?;
        if ty != T::Bool {
            return reject("&& or || on a value that is not a boolean");
        }
        Ok(value)
    }

    /// The type of both branches of a conditional.
    fn join(&mut self, a: &T, b: &T) -> Checked<T> {
        if self.island.fits(a, b) {
            return Ok(b.clone());
        }
        if self.island.fits(b, a) {
            return Ok(a.clone());
        }
        reject("a conditional whose branches have different types")
    }

    fn symbol(&self, ident: &IdentifierReference<'a>) -> Option<SymbolId> {
        self.island
            .semantic
            .scoping()
            .get_reference(ident.reference_id())
            .symbol_id()
    }

    /// Whether the symbol is declared inside the function being compiled.
    fn is_inside(&self, symbol: SymbolId) -> bool {
        let scoping = self.island.semantic.scoping();
        let Some(home) = self.scope else {
            return false;
        };
        let mut scope = Some(scoping.symbol_scope_id(symbol));
        while let Some(id) = scope {
            if id == home {
                return true;
            }
            scope = scoping.scope_parent_id(id);
        }
        false
    }

    fn identifier(&mut self, ident: &'a IdentifierReference<'a>) -> Checked<(ir::Expr, T)> {
        let Some(symbol) = self.symbol(ident) else {
            return Ok(match ident.name.as_str() {
                "undefined" => (ir::Expr::Undefined, T::Null),
                "NaN" => (ir::Expr::Num(f64::NAN), T::Num),
                "Infinity" => (ir::Expr::Num(f64::INFINITY), T::Num),
                _ => return reject(format!("the global {}", ident.name)),
            });
        };
        if let Some(local) = self.names.get(&symbol) {
            return Ok((
                ir::Expr::Local(*local),
                self.locals[*local as usize].clone(),
            ));
        }
        if self.is_inside(symbol) {
            return reject("a variable read before its declaration");
        }
        let ty = self.global_type(symbol)?;
        let index = self.island.global(symbol, ty.clone());
        // The entry still reads a constant, which throws before its declaration runs.
        if ty == T::Num
            && let Some(value) = constant(self.island, symbol, 0)
        {
            return Ok((ir::Expr::Num(value), ty));
        }
        Ok((ir::Expr::Global(index), ty))
    }

    /// The type of a variable outside the island: its annotation, or the type of its
    /// initializer when that is a number or a boolean. The entry checks the value.
    fn global_type(&mut self, symbol: SymbolId) -> Checked<T> {
        let scoping = self.island.semantic.scoping();
        let node = scoping.symbol_declaration(symbol);
        let AstKind::VariableDeclarator(declarator) = self.island.semantic.nodes().kind(node)
        else {
            return reject("a value outside the island that is not a variable");
        };
        if !matches!(declarator.id, BindingPattern::BindingIdentifier(_)) {
            return reject("a destructured variable outside the island");
        }
        let ty = match (&declarator.type_annotation, &declarator.init) {
            (Some(annotation), _) => self.island.annotation(annotation)?,
            (None, Some(init)) => primitive_type(init)?,
            (None, None) => return reject("a variable outside the island without a type"),
        };
        if !matches!(ty, T::Num | T::Bool) {
            return reject("a variable outside the island that is not a number or a boolean");
        }
        Ok(ty)
    }

    fn this_value(&mut self) -> Checked<(ir::Expr, T)> {
        let Some(class) = self.this else {
            return reject("this outside a method");
        };
        if self.pending.is_some() {
            return reject("this before the constructor assigns every field");
        }
        if let Some(constructing) = self.constructing {
            self.island.escaping.insert(constructing);
        }
        Ok((ir::Expr::Local(0), T::Class(class)))
    }

    /// `this` as the object of a field access, which does not let it escape.
    fn this_object(&mut self) -> Checked<(ir::Expr, T)> {
        let Some(class) = self.this else {
            return reject("this outside a method");
        };
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.needs_super)
        {
            return reject("this before super()");
        }
        Ok((ir::Expr::Local(0), T::Class(class)))
    }

    /// The object of a member expression.
    fn object(&mut self, object: &'a Expression<'a>) -> Checked<(ir::Expr, T)> {
        match object {
            Expression::ThisExpression(_) => self.this_object(),
            Expression::ParenthesizedExpression(inner) => self.object(&inner.expression),
            _ => self.expr(object),
        }
    }

    fn is_math(&self, object: &Expression<'a>) -> bool {
        matches!(object, Expression::Identifier(ident)
            if ident.name == "Math" && self.symbol(ident).is_none())
    }

    fn static_member(&mut self, member: &'a StaticMemberExpression<'a>) -> Checked<(ir::Expr, T)> {
        let name = member.property.name.as_str();
        if member.optional {
            return reject("?.");
        }
        if self.is_math(&member.object) {
            self.island.uses_math = true;
            let value = match name {
                "PI" => std::f64::consts::PI,
                "E" => std::f64::consts::E,
                "LN2" => std::f64::consts::LN_2,
                "LN10" => std::f64::consts::LN_10,
                "LOG2E" => std::f64::consts::LOG2_E,
                "LOG10E" => std::f64::consts::LOG10_E,
                "SQRT2" => std::f64::consts::SQRT_2,
                "SQRT1_2" => std::f64::consts::FRAC_1_SQRT_2,
                _ => return reject(format!("Math.{name}")),
            };
            return Ok((ir::Expr::Num(value), T::Num));
        }
        let (object, ty) = self.object(&member.object)?;
        match ty {
            T::Array(_) if name == "length" => Ok((ir::Expr::Length(Box::new(object)), T::Num)),
            T::Class(class) => {
                let (index, field_ty) = self.field(class, name)?;
                Ok((ir::Expr::Field(Box::new(object), class, index), field_ty))
            }
            _ => reject(format!("the property {name}")),
        }
    }

    /// The index and the type of the field `name` in the layout of the class.
    fn field(&self, class: ir::ClassId, name: &str) -> Checked<(u32, T)> {
        let fields = &self.island.classes[class as usize].fields;
        let index = fields
            .iter()
            .position(|(field, _)| field == name)
            .ok_or_else(|| Reject(format!("the property {name} that is not a field")))?;
        Ok((
            u32::try_from(index).map_err(|e| Reject(e.to_string()))?,
            fields[index].1.clone(),
        ))
    }

    fn computed_member(
        &mut self,
        member: &'a ComputedMemberExpression<'a>,
    ) -> Checked<(ir::Expr, T)> {
        if member.optional {
            return reject("?.[]");
        }
        let (object, ty) = self.object(&member.object)?;
        let T::Array(element) = ty else {
            return reject("an index of a value that is not an array");
        };
        let index = self.expr_to(&member.expression, &T::Num)?;
        Ok((ir::Expr::Index(Box::new(object), Box::new(index)), *element))
    }

    fn arguments(
        &mut self,
        args: &'a [Argument<'a>],
        signature: &Signature,
        skip: usize,
    ) -> Checked<Vec<ir::Expr>> {
        let params = &signature.params[skip..];
        if args.len() > params.len() {
            return reject("a call with more arguments than parameters");
        }
        let mut values = Vec::with_capacity(params.len());
        for (index, ty) in params.iter().enumerate() {
            if let Some(arg) = args.get(index) {
                let expression = arg
                    .as_expression()
                    .ok_or_else(|| Reject("a spread argument".into()))?;
                values.push(self.expr_to(expression, ty)?);
                continue;
            }
            let default = signature.defaults[skip + index]
                .clone()
                .ok_or_else(|| Reject("a call without a required argument".into()))?;
            values.push(default);
        }
        Ok(values)
    }

    fn call(&mut self, call: &'a CallExpression<'a>) -> Checked<(ir::Expr, T)> {
        if call.optional {
            return reject("?.()");
        }
        match &call.callee {
            Expression::Identifier(ident) => {
                let symbol = self
                    .symbol(ident)
                    .ok_or_else(|| Reject(format!("a call of the global {}", ident.name)))?;
                let node = self.island.semantic.scoping().symbol_declaration(symbol);
                let AstKind::Function(function) = self.island.semantic.nodes().kind(node) else {
                    return reject("a call of a value that is not a function declaration");
                };
                if !is_top_level_declaration(self.island, node) {
                    return reject("a call of a function declared in a block");
                }
                let id = self.island.function(symbol, function)?;
                let signature = self.island.signatures[id as usize].clone();
                let args = self.arguments(&call.arguments, &signature, 0)?;
                Ok((ir::Expr::Call(id, args), signature.result))
            }
            Expression::StaticMemberExpression(member) => self.method_call(call, member),
            Expression::Super(_) => self.super_call(call),
            _ => reject("a call of an expression"),
        }
    }

    fn method_call(
        &mut self,
        call: &'a CallExpression<'a>,
        member: &'a StaticMemberExpression<'a>,
    ) -> Checked<(ir::Expr, T)> {
        let name = member.property.name.as_str();
        if member.optional {
            return reject("?.");
        }
        if self.is_math(&member.object) {
            self.island.uses_math = true;
            let (function, arity) =
                MathFn::from_name(name).ok_or_else(|| Reject(format!("Math.{name}")))?;
            if call.arguments.len() != arity {
                return reject("a Math call with another count of arguments");
            }
            let mut args = Vec::with_capacity(arity);
            for arg in &call.arguments {
                let expression = arg
                    .as_expression()
                    .ok_or_else(|| Reject("a spread argument".into()))?;
                args.push(self.expr_to(expression, &T::Num)?);
            }
            return Ok((ir::Expr::Math(function, args), T::Num));
        }
        if name == "fill"
            && let Expression::NewExpression(new) = &member.object
        {
            return self.array_fill(new, call, None);
        }
        if let Expression::Super(_) = &member.object {
            return self.super_method(call, name);
        }
        if let Some(class) = self.class_name(&member.object)? {
            let id = self
                .island
                .method(class, name, true)?
                .ok_or_else(|| Reject(format!("the static method {name}")))?;
            let signature = self.island.signatures[id as usize].clone();
            let args = self.arguments(&call.arguments, &signature, 0)?;
            return Ok((ir::Expr::Call(id, args), signature.result));
        }
        let (object, ty) = match &member.object {
            Expression::ThisExpression(_) => self.this_value()?,
            other => self.expr(other)?,
        };
        let signature = match &ty {
            T::Array(element) if name == "push" => {
                let [arg] = call.arguments.as_slice() else {
                    return reject("push of more than one value");
                };
                let expression = arg
                    .as_expression()
                    .ok_or_else(|| Reject("a spread argument".into()))?;
                let element = (**element).clone();
                let value = self.expr_to(expression, &element)?;
                return Ok((ir::Expr::Push(Box::new(object), Box::new(value)), T::Num));
            }
            T::Class(class) => self
                .island
                .method_signature(*class, name)?
                .ok_or_else(|| Reject(format!("the method {name}")))?,
            T::Iface(iface) => {
                let mut signature = self.island.ifaces[*iface]
                    .methods
                    .get(name)
                    .cloned()
                    .ok_or_else(|| Reject(format!("the method {name}")))?;
                signature.params.insert(0, ty.clone());
                signature.defaults.insert(0, None);
                signature
            }
            _ => return reject(format!("the method {name} of a value")),
        };
        let mut args = vec![object];
        args.extend(self.arguments(&call.arguments, &signature, 1)?);
        self.island.dispatched.insert(name.to_owned());
        Ok((
            ir::Expr::Dispatch {
                method: name.to_owned(),
                args,
                result: signature.result.ir(),
            },
            signature.result,
        ))
    }

    /// The class that an identifier names, for a static call.
    fn class_name(&mut self, object: &'a Expression<'a>) -> Checked<Option<ir::ClassId>> {
        let Expression::Identifier(ident) = object else {
            return Ok(None);
        };
        let Some(symbol) = self.symbol(ident) else {
            return Ok(None);
        };
        let node = self.island.semantic.scoping().symbol_declaration(symbol);
        match self.island.semantic.nodes().kind(node) {
            AstKind::Class(class) => Ok(Some(self.island.class(symbol, class)?)),
            _ => Ok(None),
        }
    }

    /// `super.name(...)`: the method of the parent class, called directly.
    fn super_method(&mut self, call: &'a CallExpression<'a>, name: &str) -> Checked<(ir::Expr, T)> {
        let (this, _) = self.this_value()?;
        let class = self
            .this
            .ok_or_else(|| Reject("super outside a method".into()))?;
        let parent = self.island.classes[class as usize]
            .parent
            .ok_or_else(|| Reject("super in a class without a parent".into()))?;
        let id = self
            .island
            .find_method(parent, name)?
            .ok_or_else(|| Reject(format!("super.{name}")))?;
        let signature = self.island.signatures[id as usize].clone();
        let mut args = vec![this];
        args.extend(self.arguments(&call.arguments, &signature, 1)?);
        Ok((ir::Expr::Call(id, args), signature.result))
    }

    /// `super(...)` in a derived constructor: the constructor of the parent, then the
    /// field initializers of the class.
    fn super_call(&mut self, call: &'a CallExpression<'a>) -> Checked<(ir::Expr, T)> {
        let Some(pending) = self.pending.as_ref() else {
            return reject("super() outside a constructor or after this escapes");
        };
        if !pending.needs_super || self.depth > 0 {
            return reject("super() twice or inside a branch");
        }
        let class = pending.class;
        let parent = self.island.classes[class as usize]
            .parent
            .ok_or_else(|| Reject("super() in a base class".into()))?;
        let constructor = self.island.constructor(parent)?;
        let signature = self.island.signatures[constructor as usize].clone();
        let mut args = vec![ir::Expr::Local(0)];
        args.extend(self.arguments(&call.arguments, &signature, 1)?);
        if let Some(pending) = self.pending.as_mut() {
            pending.needs_super = false;
        }
        let mut items = vec![ir::Expr::Call(constructor, args)];
        for stmt in self.field_initializers(class)? {
            if let ir::Stmt::Expr(expr) = stmt {
                items.push(expr);
            }
        }
        self.release();
        Ok((ir::Expr::Seq(items), T::Void))
    }

    /// Ends the restrictions on `this` once the constructor has assigned every field.
    fn release(&mut self) {
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.fields.is_empty() && !pending.needs_super)
        {
            self.pending = None;
        }
    }

    fn new_expr(
        &mut self,
        new: &'a NewExpression<'a>,
        _expected: Option<&T>,
    ) -> Checked<(ir::Expr, T)> {
        let Expression::Identifier(ident) = &new.callee else {
            return reject("new of an expression");
        };
        let symbol = self
            .symbol(ident)
            .ok_or_else(|| Reject(format!("new {}", ident.name)))?;
        let node = self.island.semantic.scoping().symbol_declaration(symbol);
        let AstKind::Class(class) = self.island.semantic.nodes().kind(node) else {
            return reject("new of a value that is not a class declaration");
        };
        if class.r#abstract {
            return reject("new of an abstract class");
        }
        let id = self.island.class(symbol, class)?;
        let constructor = self.island.constructor(id)?;
        let signature = self.island.signatures[constructor as usize].clone();
        let args = self.arguments(&new.arguments, &signature, 1)?;
        Ok((ir::Expr::New(id, constructor, args), T::Class(id)))
    }

    /// `new Array<T>(n).fill(value)`.
    fn array_fill(
        &mut self,
        new: &'a NewExpression<'a>,
        call: &'a CallExpression<'a>,
        expected: Option<&T>,
    ) -> Checked<(ir::Expr, T)> {
        let is_array = matches!(&new.callee, Expression::Identifier(ident)
            if ident.name == "Array" && self.symbol(ident).is_none());
        let ([length], [value]) = (new.arguments.as_slice(), call.arguments.as_slice()) else {
            return reject("new Array(n).fill(v) with other arguments");
        };
        if !is_array {
            return reject("fill on a value that is not new Array(n)");
        }
        let element = match (&new.type_arguments, expected) {
            (Some(arguments), _) => {
                let [argument] = arguments.params.as_slice() else {
                    return reject("Array with more than one type argument");
                };
                self.island.ty(argument)?
            }
            (None, Some(T::Array(element))) => (**element).clone(),
            (None, _) => return reject("new Array(n) without its element type"),
        };
        let length = self.expr_to(
            length
                .as_expression()
                .ok_or_else(|| Reject("a spread argument".into()))?,
            &T::Num,
        )?;
        let value = self.expr_to(
            value
                .as_expression()
                .ok_or_else(|| Reject("a spread argument".into()))?,
            &element,
        )?;
        Ok((
            ir::Expr::ArrayFill(element.ir(), Box::new(length), Box::new(value)),
            T::Array(Box::new(element)),
        ))
    }

    fn array_literal(
        &mut self,
        array: &'a oxc::ast::ast::ArrayExpression<'a>,
        element: Option<&T>,
    ) -> Checked<(ir::Expr, T)> {
        let mut items = Vec::with_capacity(array.elements.len());
        let mut element = element.cloned();
        for item in &array.elements {
            if matches!(
                item,
                ArrayExpressionElement::SpreadElement(_) | ArrayExpressionElement::Elision(_)
            ) {
                return reject("a spread or a hole in an array literal");
            }
            let expression = item
                .as_expression()
                .ok_or_else(|| Reject("an array element".into()))?;
            if let Some(ty) = element.clone() {
                items.push(self.expr_to(expression, &ty)?);
                continue;
            }
            let (value, ty) = self.expr(expression)?;
            if ty == T::Null || ty == T::Void {
                return reject("an array of null without a type");
            }
            element = Some(ty);
            items.push(value);
        }
        let element = element.ok_or_else(|| Reject("an empty array without a type".into()))?;
        Ok((
            ir::Expr::ArrayOf(element.ir(), items),
            T::Array(Box::new(element)),
        ))
    }

    fn unary(
        &mut self,
        operator: UnaryOperator,
        argument: &'a Expression<'a>,
    ) -> Checked<(ir::Expr, T)> {
        Ok(match operator {
            UnaryOperator::UnaryNegation => (
                ir::Expr::Unary(Unary::Neg, Box::new(self.expr_to(argument, &T::Num)?)),
                T::Num,
            ),
            UnaryOperator::UnaryPlus => (self.expr_to(argument, &T::Num)?, T::Num),
            UnaryOperator::BitwiseNot => (
                ir::Expr::Unary(Unary::BitNot, Box::new(self.expr_to(argument, &T::Num)?)),
                T::Num,
            ),
            UnaryOperator::LogicalNot => (
                ir::Expr::Unary(Unary::Not, Box::new(self.condition(argument)?)),
                T::Bool,
            ),
            _ => return reject("typeof, void, or delete"),
        })
    }

    fn binary(
        &mut self,
        operator: BinaryOperator,
        left: &'a Expression<'a>,
        right: &'a Expression<'a>,
    ) -> Checked<(ir::Expr, T)> {
        let arithmetic = |op| Some((op, T::Num));
        let comparison = |op| Some((op, T::Bool));
        let numeric = match operator {
            BinaryOperator::Addition => arithmetic(Op::Add),
            BinaryOperator::Subtraction => arithmetic(Op::Sub),
            BinaryOperator::Multiplication => arithmetic(Op::Mul),
            BinaryOperator::Division => arithmetic(Op::Div),
            BinaryOperator::Remainder => arithmetic(Op::Rem),
            BinaryOperator::Exponential => arithmetic(Op::Pow),
            BinaryOperator::BitwiseAnd => arithmetic(Op::BitAnd),
            BinaryOperator::BitwiseOR => arithmetic(Op::BitOr),
            BinaryOperator::BitwiseXOR => arithmetic(Op::BitXor),
            BinaryOperator::ShiftLeft => arithmetic(Op::Shl),
            BinaryOperator::ShiftRight => arithmetic(Op::Shr),
            BinaryOperator::ShiftRightZeroFill => arithmetic(Op::UShr),
            BinaryOperator::LessThan => comparison(Op::Lt),
            BinaryOperator::LessEqualThan => comparison(Op::Le),
            BinaryOperator::GreaterThan => comparison(Op::Gt),
            BinaryOperator::GreaterEqualThan => comparison(Op::Ge),
            _ => None,
        };
        if let Some((op, ty)) = numeric {
            let a = self.expr_to(left, &T::Num)?;
            let b = self.expr_to(right, &T::Num)?;
            return Ok((ir::Expr::Binary(op, Box::new(a), Box::new(b)), ty));
        }
        let equal = match operator {
            BinaryOperator::StrictEquality | BinaryOperator::Equality => true,
            BinaryOperator::StrictInequality | BinaryOperator::Inequality => false,
            _ => return reject("in or instanceof"),
        };
        let loose = matches!(
            operator,
            BinaryOperator::Equality | BinaryOperator::Inequality
        );
        let (a, a_ty) = self.expr(left)?;
        let (b, b_ty) = self.expr(right)?;
        let value = if loose && (a_ty == T::Null || b_ty == T::Null) {
            // `x == null` holds for null and undefined alike.
            let other = if a_ty == T::Null { b } else { a };
            let nullish = ir::Expr::Unary(Unary::Nullish, Box::new(other));
            if equal {
                nullish
            } else {
                ir::Expr::Unary(Unary::Not, Box::new(nullish))
            }
        } else {
            let same_kind = a_ty == b_ty || (a_ty.is_reference() && b_ty.is_reference());
            if loose && !same_kind {
                return reject("== between values of different types");
            }
            let op = if equal { Op::Eq } else { Op::Ne };
            ir::Expr::Binary(op, Box::new(a), Box::new(b))
        };
        Ok((value, T::Bool))
    }

    /// A place that an assignment or an update writes.
    fn place(&mut self, target: &'a SimpleAssignmentTarget<'a>) -> Checked<Place> {
        match target {
            SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => {
                let symbol = self
                    .symbol(ident)
                    .ok_or_else(|| Reject(format!("a write of the global {}", ident.name)))?;
                let local = *self
                    .names
                    .get(&symbol)
                    .ok_or_else(|| Reject("a write of a variable outside the function".into()))?;
                let scoping = self.island.semantic.scoping();
                if scoping.symbol_flags(symbol).is_const_variable() {
                    return reject("a write of a const");
                }
                Ok(Place::Local(local, self.locals[local as usize].clone()))
            }
            SimpleAssignmentTarget::StaticMemberExpression(member) => {
                let (object, ty) = self.object(&member.object)?;
                let T::Class(class) = ty else {
                    return reject("a write of a property of a value that is not an object");
                };
                let (index, field_ty) = self.field(class, member.property.name.as_str())?;
                Ok(Place::Field(object, class, index, field_ty))
            }
            SimpleAssignmentTarget::ComputedMemberExpression(member) => {
                let (object, ty) = self.object(&member.object)?;
                let T::Array(element) = ty else {
                    return reject("an index of a value that is not an array");
                };
                let index = self.expr_to(&member.expression, &T::Num)?;
                Ok(Place::Element(object, index, *element))
            }
            _ => reject("a write of another place"),
        }
    }

    fn assignment(
        &mut self,
        assignment: &'a oxc::ast::ast::AssignmentExpression<'a>,
    ) -> Checked<(ir::Expr, T)> {
        let target = match &assignment.left {
            AssignmentTarget::AssignmentTargetIdentifier(_)
            | AssignmentTarget::StaticMemberExpression(_)
            | AssignmentTarget::ComputedMemberExpression(_) => assignment
                .left
                .as_simple_assignment_target()
                .ok_or_else(|| Reject("an assignment target".into()))?,
            _ => return reject("a destructuring assignment"),
        };
        let field_of_this = match target {
            SimpleAssignmentTarget::StaticMemberExpression(member)
                if matches!(member.object, Expression::ThisExpression(_)) =>
            {
                Some(member.property.name.as_str())
            }
            _ => None,
        };
        let op = match assignment.operator {
            AssignmentOperator::Assign => None,
            AssignmentOperator::Addition => Some(Op::Add),
            AssignmentOperator::Subtraction => Some(Op::Sub),
            AssignmentOperator::Multiplication => Some(Op::Mul),
            AssignmentOperator::Division => Some(Op::Div),
            AssignmentOperator::Remainder => Some(Op::Rem),
            AssignmentOperator::Exponential => Some(Op::Pow),
            AssignmentOperator::BitwiseAnd => Some(Op::BitAnd),
            AssignmentOperator::BitwiseOR => Some(Op::BitOr),
            AssignmentOperator::BitwiseXOR => Some(Op::BitXor),
            AssignmentOperator::ShiftLeft => Some(Op::Shl),
            AssignmentOperator::ShiftRight => Some(Op::Shr),
            AssignmentOperator::ShiftRightZeroFill => Some(Op::UShr),
            _ => return reject("a logical assignment"),
        };
        if op.is_some() && self.pending.is_some() && field_of_this.is_some() {
            return reject("a compound write of a field before every field is assigned");
        }
        let place = self.place(target)?;
        let ty = place.ty().clone();
        let value = match op {
            None => self.expr_to(&assignment.right, &ty)?,
            Some(op) => {
                if ty != T::Num {
                    return reject("a compound assignment of a value that is not a number");
                }
                let right = self.expr_to(&assignment.right, &T::Num)?;
                return Ok((
                    self.write(place, |current| {
                        ir::Expr::Binary(op, Box::new(current), Box::new(right))
                    }),
                    T::Num,
                ));
            }
        };
        let written = place.store(value);
        if let Some(name) = field_of_this {
            self.assigned(name);
        }
        Ok((written, ty))
    }

    /// Notes that a constructor assigned the field `name` of `this`.
    fn assigned(&mut self, name: &str) {
        if self.depth > 0 {
            return;
        }
        let Some(class) = self.pending.as_ref().map(|pending| pending.class) else {
            return;
        };
        if let Ok((index, _)) = self.field(class, name)
            && let Some(pending) = self.pending.as_mut()
        {
            pending.fields.remove(&index);
        }
        self.release();
    }

    /// Writes `make(current value)` to the place, evaluating its object and index once,
    /// and is the value written.
    fn write(&mut self, place: Place, make: impl FnOnce(ir::Expr) -> ir::Expr) -> ir::Expr {
        match place {
            Place::Local(local, _) => {
                ir::Expr::SetLocal(local, Box::new(make(ir::Expr::Local(local))))
            }
            Place::Field(object, class, index, _) => {
                let held = self.local(T::Class(class));
                let read = ir::Expr::Field(Box::new(ir::Expr::Local(held)), class, index);
                ir::Expr::Seq(vec![
                    ir::Expr::SetLocal(held, Box::new(object)),
                    ir::Expr::SetField(
                        Box::new(ir::Expr::Local(held)),
                        class,
                        index,
                        Box::new(make(read)),
                    ),
                ])
            }
            Place::Element(array, index, element) => {
                let held = self.local(T::Array(Box::new(element)));
                let at = self.local(T::Num);
                let read = ir::Expr::Index(
                    Box::new(ir::Expr::Local(held)),
                    Box::new(ir::Expr::Local(at)),
                );
                ir::Expr::Seq(vec![
                    ir::Expr::SetLocal(held, Box::new(array)),
                    ir::Expr::SetLocal(at, Box::new(index)),
                    ir::Expr::SetIndex(
                        Box::new(ir::Expr::Local(held)),
                        Box::new(ir::Expr::Local(at)),
                        Box::new(make(read)),
                    ),
                ])
            }
        }
    }

    fn update(
        &mut self,
        update: &'a oxc::ast::ast::UpdateExpression<'a>,
    ) -> Checked<(ir::Expr, T)> {
        let place = self.place(&update.argument)?;
        if *place.ty() != T::Num {
            return reject("++ or -- of a value that is not a number");
        }
        let op = match update.operator {
            UpdateOperator::Increment => Op::Add,
            UpdateOperator::Decrement => Op::Sub,
        };
        let step = |current| ir::Expr::Binary(op, Box::new(current), Box::new(ir::Expr::Num(1.0)));
        if update.prefix {
            return Ok((self.write(place, step), T::Num));
        }
        // `x++` is the old value: keep it in a local first.
        let old = self.local(T::Num);
        let written = self.write(place, |current| {
            ir::Expr::Seq(vec![
                ir::Expr::SetLocal(old, Box::new(current)),
                step(ir::Expr::Local(old)),
            ])
        });
        Ok((ir::Expr::Seq(vec![written, ir::Expr::Local(old)]), T::Num))
    }
}

/// A place that a write goes to.
enum Place {
    Local(u32, T),
    Field(ir::Expr, ir::ClassId, u32, T),
    Element(ir::Expr, ir::Expr, T),
}

impl Place {
    fn ty(&self) -> &T {
        match self {
            Self::Local(_, ty) | Self::Field(_, _, _, ty) | Self::Element(_, _, ty) => ty,
        }
    }

    fn store(self, value: ir::Expr) -> ir::Expr {
        match self {
            Self::Local(local, _) => ir::Expr::SetLocal(local, Box::new(value)),
            Self::Field(object, class, index, _) => {
                ir::Expr::SetField(Box::new(object), class, index, Box::new(value))
            }
            Self::Element(array, index, _) => {
                ir::Expr::SetIndex(Box::new(array), Box::new(index), Box::new(value))
            }
        }
    }
}

fn number(index: usize) -> ir::Expr {
    ir::Expr::Num(f64::from(u32::try_from(index).unwrap_or(u32::MAX)))
}

fn set_number(local: u32, index: usize) -> ir::Stmt {
    ir::Stmt::Expr(ir::Expr::SetLocal(local, Box::new(number(index))))
}

/// The type of an initializer of a variable outside the island, when it is plainly a
/// number or a boolean.
fn primitive_type(init: &Expression<'_>) -> Checked<T> {
    match init {
        // An identifier is a constant of another constant; the entry checks its value.
        Expression::NumericLiteral(_) | Expression::Identifier(_) => Ok(T::Num),
        Expression::BooleanLiteral(_) => Ok(T::Bool),
        Expression::ParenthesizedExpression(inner) => primitive_type(&inner.expression),
        Expression::UnaryExpression(unary)
            if matches!(
                unary.operator,
                UnaryOperator::UnaryNegation | UnaryOperator::BitwiseNot | UnaryOperator::UnaryPlus
            ) =>
        {
            Ok(T::Num)
        }
        Expression::BinaryExpression(binary)
            if !matches!(
                binary.operator,
                BinaryOperator::Addition
                    | BinaryOperator::In
                    | BinaryOperator::Instanceof
                    | BinaryOperator::Equality
                    | BinaryOperator::Inequality
                    | BinaryOperator::StrictEquality
                    | BinaryOperator::StrictInequality
                    | BinaryOperator::LessThan
                    | BinaryOperator::LessEqualThan
                    | BinaryOperator::GreaterThan
                    | BinaryOperator::GreaterEqualThan
            ) =>
        {
            Ok(T::Num)
        }
        Expression::StaticMemberExpression(member) if matches!(&member.object, Expression::Identifier(ident) if ident.name == "Math") => {
            Ok(T::Num)
        }
        Expression::CallExpression(call)
            if matches!(&call.callee, Expression::StaticMemberExpression(member)
                if matches!(&member.object, Expression::Identifier(ident) if ident.name == "Math")) =>
        {
            Ok(T::Num)
        }
        // `a + b` is a number when both sides are; the entry checks the value anyway.
        Expression::BinaryExpression(binary) if binary.operator == BinaryOperator::Addition => {
            match (primitive_type(&binary.left), primitive_type(&binary.right)) {
                (Ok(T::Num), Ok(T::Num)) => Ok(T::Num),
                _ => reject("a sum that may be a string"),
            }
        }
        _ => reject("a variable outside the island whose type is unknown"),
    }
}

/// The number of a `const` whose initializer is an expression of number literals and other
/// such constants, which the code may use in place of a read of the variable.
fn constant(island: &Island<'_, '_>, symbol: SymbolId, depth: u32) -> Option<f64> {
    let nodes = island.semantic.nodes();
    let node = island.semantic.scoping().symbol_declaration(symbol);
    let AstKind::VariableDeclarator(declarator) = nodes.kind(node) else {
        return None;
    };
    let AstKind::VariableDeclaration(declaration) = nodes.parent_kind(node) else {
        return None;
    };
    if declaration.kind != VariableDeclarationKind::Const || depth > 8 {
        return None;
    }
    fold(island, declarator.init.as_ref()?, depth)
}

/// The number of a constant expression, with the operators of ECMA-262 §13.
fn fold(island: &Island<'_, '_>, expression: &Expression<'_>, depth: u32) -> Option<f64> {
    let int = ir::to_int32;
    let uint = |value: f64| ir::to_int32(value).cast_unsigned();
    Some(match expression {
        Expression::NumericLiteral(literal) => literal.value,
        Expression::ParenthesizedExpression(inner) => fold(island, &inner.expression, depth)?,
        Expression::Identifier(ident) => {
            let symbol = island
                .semantic
                .scoping()
                .get_reference(ident.reference_id())
                .symbol_id()?;
            constant(island, symbol, depth + 1)?
        }
        Expression::UnaryExpression(unary) => {
            let value = fold(island, &unary.argument, depth)?;
            match unary.operator {
                UnaryOperator::UnaryNegation => -value,
                UnaryOperator::UnaryPlus => value,
                UnaryOperator::BitwiseNot => f64::from(!int(value)),
                _ => return None,
            }
        }
        Expression::BinaryExpression(binary) => {
            let a = fold(island, &binary.left, depth)?;
            let b = fold(island, &binary.right, depth)?;
            let shift = uint(b) & 31;
            match binary.operator {
                BinaryOperator::Addition => a + b,
                BinaryOperator::Subtraction => a - b,
                BinaryOperator::Multiplication => a * b,
                BinaryOperator::Division => a / b,
                BinaryOperator::Remainder => a % b,
                BinaryOperator::BitwiseOR => f64::from(int(a) | int(b)),
                BinaryOperator::BitwiseAnd => f64::from(int(a) & int(b)),
                BinaryOperator::BitwiseXOR => f64::from(int(a) ^ int(b)),
                BinaryOperator::ShiftLeft => f64::from(int(a).wrapping_shl(shift)),
                BinaryOperator::ShiftRight => f64::from(int(a) >> shift),
                BinaryOperator::ShiftRightZeroFill => f64::from(uint(a) >> shift),
                _ => return None,
            }
        }
        _ => return None,
    })
}

/// Whether the expression reads `this`, outside nested functions.
fn mentions_this(expression: &Expression<'_>) -> bool {
    use oxc::ast_visit::Visit;
    struct Finder(bool);
    impl<'a> Visit<'a> for Finder {
        fn visit_this_expression(&mut self, _: &oxc::ast::ast::ThisExpression) {
            self.0 = true;
        }
        fn visit_function(
            &mut self,
            _: &oxc::ast::ast::Function<'a>,
            _: oxc::semantic::ScopeFlags,
        ) {
        }
    }
    let mut finder = Finder(false);
    finder.visit_expression(expression);
    finder.0
}

/// Whether the function declaration at `node` is a statement of a function body or of the
/// program, not of a block, where sloppy code gives it other bindings.
fn is_top_level_declaration(island: &Island<'_, '_>, node: oxc::semantic::NodeId) -> bool {
    let nodes = island.semantic.nodes();
    matches!(
        nodes.parent_kind(node),
        AstKind::Program(_) | AstKind::FunctionBody(_)
    ) || matches!(nodes.parent_kind(node), AstKind::ExportNamedDeclaration(_))
}
