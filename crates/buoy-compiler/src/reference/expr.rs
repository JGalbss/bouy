//! Expressions in A-normal form: each operation binds a fresh variable in `pre`, so the
//! Erlang code runs the operations in the order of JavaScript. This file holds the
//! dispatch and the operators.

use oxc::ast::ast::{
    AssignmentExpression, AssignmentTarget, BinaryExpression, ConditionalExpression, Expression,
    IdentifierReference, LogicalExpression, MemberExpression, SimpleAssignmentTarget,
    UnaryExpression, UpdateExpression,
};
use oxc::span::GetSpan;
use oxc::syntax::operator::{
    AssignmentOperator, BinaryOperator, LogicalOperator, UnaryOperator, UpdateOperator,
};

use super::context::{Kind, Local, Lowerer, Top, boolean_case};
use super::literal::{bigint, js_string_literal, number};
use super::member::{MemberKey, super_parts};
use crate::erlang::{Clause, Expr};

impl<'a> Lowerer<'a, '_> {
    pub fn expr(&mut self, expression: &'a Expression<'a>) -> Expr {
        match expression {
            Expression::BooleanLiteral(literal) => Expr::atom(literal.value.to_string()),
            Expression::NullLiteral(_) => Expr::atom("null"),
            Expression::NumericLiteral(literal) => number(literal.value),
            Expression::StringLiteral(literal) => {
                js_string_literal(literal.value.as_str(), literal.lone_surrogates)
            }
            Expression::TemplateLiteral(template) => self.template(template),
            Expression::TaggedTemplateExpression(tagged) => self.tagged_template(tagged),
            Expression::BigIntLiteral(literal) => bigint(literal.value.as_str()),
            Expression::RegExpLiteral(literal) => self.regexp(literal),
            Expression::Identifier(ident) => self.identifier(ident),
            Expression::ThisExpression(_) => self.this_expr(),
            Expression::NewTarget(_) => self.new_target_expr(),
            Expression::ArrayExpression(array) => self.array(array),
            Expression::ObjectExpression(object) => self.object(object),
            Expression::ArrowFunctionExpression(arrow) => self.arrow(arrow),
            Expression::FunctionExpression(function) => self.function_expression(function),
            Expression::AssignmentExpression(assignment) => self.assign(assignment),
            Expression::UpdateExpression(update) => self.update(update),
            Expression::AwaitExpression(expression) => {
                if !matches!(self.frame.kind, Kind::Async | Kind::AsyncGenerator) {
                    return self.unsupported(expression.span, "`await` outside an async function");
                }
                let value = self.expr(&expression.argument);
                self.marker("await", value)
            }
            Expression::YieldExpression(expression) => {
                let value = match &expression.argument {
                    Some(argument) => self.expr(argument),
                    None => Expr::undefined(),
                };
                let kind = if expression.delegate {
                    "yield_star"
                } else {
                    "yield"
                };
                self.marker(kind, value)
            }
            Expression::ClassExpression(class) => self.class_expression(class, None),
            Expression::PrivateInExpression(expression) => {
                let key = self.private_key(expression.left.name.as_str());
                let object = self.expr(&expression.right);
                self.bind(Expr::call(
                    "buoy_ref_class",
                    "private_in",
                    vec![key, object],
                ))
            }
            Expression::BinaryExpression(binary) => self.binary(binary),
            Expression::LogicalExpression(logical) => self.logical(logical),
            Expression::ConditionalExpression(conditional) => self.conditional(conditional),
            Expression::SequenceExpression(sequence) => {
                let Some((last, init)) = sequence.expressions.split_last() else {
                    return Expr::undefined();
                };
                for item in init {
                    self.effect(item);
                }
                self.expr(last)
            }
            Expression::UnaryExpression(unary) => self.unary(unary),
            Expression::CallExpression(call) => self.call(call),
            Expression::NewExpression(new) => self.new_expression(new),
            Expression::ChainExpression(chain) => self.chain(chain),
            Expression::ParenthesizedExpression(inner) => self.expr(&inner.expression),
            Expression::TSAsExpression(inner) => self.expr(&inner.expression),
            Expression::TSSatisfiesExpression(inner) => self.expr(&inner.expression),
            Expression::TSNonNullExpression(inner) => self.expr(&inner.expression),
            Expression::TSTypeAssertion(inner) => self.expr(&inner.expression),
            Expression::TSInstantiationExpression(inner) => self.expr(&inner.expression),
            Expression::StaticMemberExpression(member) => self.static_member(member),
            Expression::ComputedMemberExpression(member) => self.computed_member(member),
            Expression::PrivateFieldExpression(member) => self.private_member(member),
            Expression::ImportExpression(import) => self.dynamic_import(import),
            Expression::ImportMeta(_) => self.import_meta(),
            other => {
                let what = match other {
                    Expression::Super(_) => "this use of `super`",
                    _ => "this syntax",
                };
                self.unsupported(other.span(), what)
            }
        }
    }

    /// Lowers an expression for its effects only.
    pub fn effect(&mut self, expression: &'a Expression<'a>) {
        let value = self.expr(expression);
        if !value.is_trivial() {
            self.pre.push(value);
        }
    }

    /// The Erlang boolean of a condition: the value itself when it is already a boolean.
    pub fn test(&mut self, expression: &'a Expression<'a>) -> Expr {
        let value = self.expr(expression);
        if is_boolean(expression) {
            return value;
        }
        Expr::call("buoy_ref", "truthy", vec![value])
    }

    pub fn assign(&mut self, assignment: &'a AssignmentExpression<'a>) -> Expr {
        match &assignment.left {
            AssignmentTarget::ArrayAssignmentTarget(_)
            | AssignmentTarget::ObjectAssignmentTarget(_) => {
                let value = self.expr(&assignment.right);
                let value = self.bind(value);
                self.assign_target(&assignment.left, value.clone());
                value
            }
            // `(x) = function () {}`: a parenthesized name is no identifier reference, so
            // the function gets no name (ECMA-262 §13.15.2).
            AssignmentTarget::AssignmentTargetIdentifier(ident)
                if assignment.operator == AssignmentOperator::Assign
                    && self.semantic.source_text()[assignment.span.start as usize..]
                        .starts_with('(') =>
            {
                let value = self.expr(&assignment.right);
                self.assign_name_value(ident, value)
            }
            AssignmentTarget::AssignmentTargetIdentifier(ident)
                if self.semantic.source_text()[assignment.span.start as usize..]
                    .starts_with('(') =>
            {
                self.assign_identifier(ident, assignment.operator, &assignment.right, None)
            }
            other => match other.as_simple_assignment_target() {
                Some(target) => self.assign_simple(target, assignment.operator, &assignment.right),
                None => self.unsupported(assignment.span, "this assignment"),
            },
        }
    }

    pub fn assign_simple(
        &mut self,
        target: &'a SimpleAssignmentTarget<'a>,
        operator: AssignmentOperator,
        right: &'a Expression<'a>,
    ) -> Expr {
        match target {
            SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => {
                let name = Some(Expr::js_string(ident.name.as_str()));
                self.assign_identifier(ident, operator, right, name)
            }
            SimpleAssignmentTarget::TSAsExpression(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            SimpleAssignmentTarget::TSSatisfiesExpression(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            SimpleAssignmentTarget::TSNonNullExpression(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            SimpleAssignmentTarget::TSTypeAssertion(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            other => match other.as_member_expression() {
                Some(member) => {
                    let (object, key) = self.member_parts(member);
                    self.assign_member(object, key, operator, right)
                }
                None => self.unsupported(other.span(), "this assignment target"),
            },
        }
    }

    pub fn assign_expression(
        &mut self,
        target: &'a Expression<'a>,
        operator: AssignmentOperator,
        right: &'a Expression<'a>,
    ) -> Expr {
        match target {
            Expression::StaticMemberExpression(_)
            | Expression::ComputedMemberExpression(_)
            | Expression::PrivateFieldExpression(_) => {
                let Some(member) = target.as_member_expression() else {
                    return Expr::undefined();
                };
                let (object, key) = self.member_parts(member);
                self.assign_member(object, key, operator, right)
            }
            Expression::ParenthesizedExpression(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            Expression::Identifier(ident) => {
                let name = Some(Expr::js_string(ident.name.as_str()));
                self.assign_identifier(ident, operator, right, name)
            }
            other => self.unsupported(other.span(), "this assignment target"),
        }
    }

    /// `x op= right` for an identifier: a local, a module variable, or a global. An
    /// anonymous function gets `name`, the name `x` unless the target is parenthesized.
    pub fn assign_identifier(
        &mut self,
        ident: &'a IdentifierReference<'a>,
        operator: AssignmentOperator,
        right: &'a Expression<'a>,
        name: Option<Expr>,
    ) -> Expr {
        let objects = self.with_objects(ident);
        if !objects.is_empty() {
            let reference = self.with_resolve(&objects, ident.name.as_str());
            if let Some(logical) = logical_operator(operator) {
                let current = self.with_read_ref(ident, &reference);
                return self.logical_write(logical, current, right, name, |me, value| {
                    me.with_write_ref(ident, &reference, value)
                });
            }
            let value = if operator == AssignmentOperator::Assign {
                self.named_expr(right, name)
            } else {
                let current = self.with_read_ref(ident, &reference);
                self.combine(operator, current, right, name)
            };
            return self.with_write_ref(ident, &reference, value);
        }
        let Some(symbol) = self.symbol_of(ident.reference_id.get()) else {
            if operator == AssignmentOperator::Assign && self.is_global_reference(ident) {
                // Strict code resolves the name before the right side runs, which may
                // create it (PutValue, ECMA-262 §6.2.5.6).
                let name_text = Expr::js_string(ident.name.as_str());
                let resolved = self.bind(Expr::call(
                    "buoy_ref_realm",
                    "has_binding",
                    vec![name_text.clone()],
                ));
                let value = self.named_expr(right, name);
                let value = self.bind(value);
                self.pre.push(Expr::call(
                    "buoy_ref_realm",
                    "set_resolved",
                    vec![name_text, value.clone(), resolved],
                ));
                return value;
            }
            if let Some(logical) = logical_operator(operator) {
                let current = self.identifier_read(ident);
                return self.logical_write(logical, current, right, name, |me, value| {
                    me.set_global(ident.name.as_str(), value)
                });
            }
            let value = if operator == AssignmentOperator::Assign {
                self.named_expr(right, name)
            } else {
                let current = self.identifier_read(ident);
                self.combine(operator, current, right, name)
            };
            return self.set_global(ident.name.as_str(), value);
        };
        if operator == AssignmentOperator::Assign {
            let value = self.named_expr(right, name);
            return self.assign_symbol(symbol, value, ident.span);
        }
        let current = self.read_symbol(symbol, ident.span);
        // A version of an Erlang variable takes the write after the case: writing the
        // current value back is not observable, and a write in one clause would not reach
        // the code after the case.
        if let Some(logical) = logical_operator(operator)
            && !self.is_versioned(symbol, ident.span)
        {
            return self.logical_write(logical, current, right, name, |me, value| {
                me.assign_symbol(symbol, value, ident.span)
            });
        }
        let value = self.combine(operator, current, right, name);
        self.assign_symbol(symbol, value, ident.span)
    }

    /// `x &&= right`, `x ||= right`, and `x ??= right`: `write` runs only when the
    /// assignment does not short-circuit, so a constant or a setter sees no write.
    fn logical_write(
        &mut self,
        logical: LogicalOperator,
        current: Expr,
        right: &'a Expression<'a>,
        name: Option<Expr>,
        write: impl FnOnce(&mut Self, Expr) -> Expr,
    ) -> Expr {
        let current = self.bind(current);
        let other = self.branch(|me| {
            let value = me.named_expr(right, name);
            let value = me.bind(value);
            write(me, value)
        });
        self.bind(logical_case(logical, current, other, false))
    }

    /// `typeof x`: "undefined" for a name that nothing declares.
    fn typeof_identifier(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        if self.symbol_of(ident.reference_id.get()).is_none()
            && !matches!(ident.name.as_str(), "undefined" | "NaN" | "Infinity")
            && !(ident.name == "arguments" && self.frame.arguments.is_some())
            && self.eval_binding(ident.name.as_str()).is_none()
        {
            let name = Expr::js_string(ident.name.as_str());
            return self.bind(Expr::call("buoy_ref", "typeof_global", vec![name]));
        }
        let value = self.identifier_plain(ident);
        self.bind(Expr::call("buoy_ref", "typeof", vec![value]))
    }

    /// `delete x` in sloppy code: false for a declared binding, else the delete of the
    /// global object's property, and first a property of a `with` object.
    fn delete_identifier(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        let objects = self.with_objects(ident);
        if !objects.is_empty() {
            let fallback = self.branch(|me| me.delete_binding(ident));
            let name = ident.name.as_str();
            return self.through_withs(
                &objects,
                name,
                |_, object| {
                    vec![Expr::call(
                        "buoy_ref",
                        "sloppy_delete",
                        vec![object, Expr::js_string(name)],
                    )]
                },
                fallback,
            );
        }
        self.delete_binding(ident)
    }

    fn delete_binding(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        let global = match self.symbol_of(ident.reference_id.get()) {
            None => {
                !(ident.name == "arguments" && self.frame.arguments.is_some())
                    && self.eval_binding(ident.name.as_str()).is_none()
            }
            // The binding of a block function in its block is lexical: delete is false.
            Some(symbol) => {
                !self.frame.env.contains_key(&symbol)
                    && matches!(self.tops.get(&symbol), Some(Top::Global(_)))
                    && self.block_binding(symbol, ident.span).is_none()
            }
        };
        if !global {
            return Expr::atom("false");
        }
        self.bind(Expr::call(
            "buoy_ref_realm",
            "delete_global",
            vec![Expr::js_string(ident.name.as_str())],
        ))
    }

    /// Whether strict code writes `ident`, which no scope declares, in the global
    /// environment: no scope of the caller of a direct eval binds it either.
    fn is_global_reference(&self, ident: &IdentifierReference<'a>) -> bool {
        let name = ident.name.as_str();
        !self.frame.sloppy
            && self.eval_binding(name).is_none()
            && self.eval_objects(name).is_empty()
            && !(name == "arguments" && self.frame.arguments.is_some())
    }

    /// Stores `value` in the global `name`, as the mode of the code allows, or in the binding
    /// of the caller of a direct eval, after the objects in front of it there.
    pub fn set_global(&mut self, name: &str, value: Expr) -> Expr {
        let value = self.bind(value);
        // Sloppy code may assign the `arguments` binding of its function.
        if name == "arguments"
            && let Some(Local::Cell(cell)) = &self.frame.arguments
        {
            self.pre.push(super::context::cell_set(cell, value.clone()));
            return value;
        }
        let objects = self.eval_objects(name);
        if objects.is_empty() {
            self.set_binding(name, value.clone());
            return value;
        }
        let fallback = self.branch(|me| {
            me.set_binding(name, value.clone());
            Expr::ok()
        });
        let stored = value.clone();
        let _ = self.through_withs(
            &objects,
            name,
            |me, object| vec![me.with_set(object, name, stored.clone())],
            fallback,
        );
        value
    }

    /// Stores `value` in the binding `name` of the caller of a direct eval, else in the
    /// global.
    fn set_binding(&mut self, name: &str, value: Expr) {
        // A write of a `const` throws in any code, after the read of its dead zone.
        if self.is_eval_const(name) {
            let cell = self.eval_binding(name).unwrap_or_default();
            self.pre.push(Expr::call(
                "buoy_ref_class",
                "initialized",
                vec![super::context::cell_get(&cell), Expr::js_string(name)],
            ));
            self.pre.push(Expr::call("buoy_ref", "const_error", vec![]));
            return;
        }
        // Strict code may not write an immutable binding; sloppy code writes nothing.
        if self.is_eval_constant(name) {
            if !self.frame.sloppy {
                self.pre.push(Expr::call("buoy_ref", "const_error", vec![]));
            }
            return;
        }
        if let Some(cell) = self.eval_binding(name) {
            self.pre.push(super::context::cell_set(&cell, value));
            return;
        }
        let mode = Expr::atom(if self.frame.sloppy {
            "sloppy"
        } else {
            "strict"
        });
        self.pre.push(Expr::call(
            "buoy_ref_realm",
            "set_global",
            vec![Expr::js_string(name), value, mode],
        ));
    }

    pub fn assign_member(
        &mut self,
        object: Expr,
        key: MemberKey,
        operator: AssignmentOperator,
        right: &'a Expression<'a>,
    ) -> Expr {
        if operator == AssignmentOperator::Assign {
            let value = self.expr(right);
            let value = self.bind(value);
            self.set(object, key, value.clone());
            return value;
        }
        let key = self.member_key_of(&object, key);
        let current = self.get(object.clone(), key.clone());
        // A logical assignment that short-circuits writes nothing, so no setter runs.
        if let Some(logical) = logical_operator(operator) {
            let current = self.bind(current);
            let other = self.branch(|me| {
                let value = me.expr(right);
                let value = me.bind(value);
                me.set(object, key, value.clone());
                value
            });
            return self.bind(logical_case(logical, current, other, false));
        }
        let value = self.combine(operator, current, right, None);
        let value = self.bind(value);
        self.set(object, key, value.clone());
        value
    }

    /// The new value of a compound assignment `x op= right`, from the current value.
    pub fn combine(
        &mut self,
        operator: AssignmentOperator,
        current: Expr,
        right: &'a Expression<'a>,
        name: Option<Expr>,
    ) -> Expr {
        if let Some(logical) = logical_operator(operator) {
            let other = self.branch(|me| me.named_expr(right, name));
            return self.bind(logical_case(logical, current, other, false));
        }
        let value = self.expr(right);
        let function = match operator {
            AssignmentOperator::Addition => "add",
            AssignmentOperator::Subtraction => "sub",
            AssignmentOperator::Multiplication => "mul",
            AssignmentOperator::Division => "divide",
            AssignmentOperator::Remainder => "remainder",
            AssignmentOperator::Exponential => "power",
            AssignmentOperator::ShiftLeft => "shift_left",
            AssignmentOperator::ShiftRight => "shift_right",
            AssignmentOperator::ShiftRightZeroFill => "shift_right_unsigned",
            AssignmentOperator::BitwiseOR => "bit_or",
            AssignmentOperator::BitwiseXOR => "bit_xor",
            _ => "bit_and",
        };
        self.bind(Expr::call("buoy_ref", function, vec![current, value]))
    }

    pub fn update(&mut self, update: &'a UpdateExpression<'a>) -> Expr {
        let function = match update.operator {
            UpdateOperator::Increment => "increment",
            UpdateOperator::Decrement => "decrement",
        };
        match &update.argument {
            SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => {
                let objects = self.with_objects(ident);
                if !objects.is_empty() {
                    let reference = self.with_resolve(&objects, ident.name.as_str());
                    let old = self.with_read_ref(ident, &reference);
                    let old = self.bind(Expr::call("buoy_ref", "to_numeric", vec![old]));
                    let new = self.bind(Expr::call("buoy_ref", function, vec![old.clone()]));
                    let new = self.with_write_ref(ident, &reference, new);
                    return if update.prefix { new } else { old };
                }
                let Some(symbol) = self.symbol_of(ident.reference_id.get()) else {
                    let old = self.identifier_read(ident);
                    let old = self.bind(Expr::call("buoy_ref", "to_numeric", vec![old]));
                    let new = self.bind(Expr::call("buoy_ref", function, vec![old.clone()]));
                    let new = self.set_global(ident.name.as_str(), new);
                    return if update.prefix { new } else { old };
                };
                let old = self.read_symbol(symbol, ident.span);
                let old = self.bind(Expr::call("buoy_ref", "to_numeric", vec![old]));
                let new = self.bind(Expr::call("buoy_ref", function, vec![old.clone()]));
                let new = self.assign_symbol(symbol, new, ident.span);
                if update.prefix { new } else { old }
            }
            other => match other.as_member_expression() {
                Some(member) => {
                    let (object, key) = self.member_parts(member);
                    let key = self.member_key_of(&object, key);
                    let old = self.get(object.clone(), key.clone());
                    let old = self.bind(Expr::call("buoy_ref", "to_numeric", vec![old]));
                    let new = self.bind(Expr::call("buoy_ref", function, vec![old.clone()]));
                    self.set(object, key, new.clone());
                    if update.prefix { new } else { old }
                }
                None => self.unsupported(update.span, "this update"),
            },
        }
    }

    /// The key of a member that an update or a compound assignment reads and writes:
    /// converted once, after the check that the base is not undefined or null.
    fn member_key_of(&mut self, object: &Expr, key: MemberKey) -> MemberKey {
        match key {
            MemberKey::Static(key) => MemberKey::Static(key),
            MemberKey::Private(key) => MemberKey::Private(key),
            MemberKey::Dynamic(value) => MemberKey::Static(self.bind(Expr::call(
                "buoy_ref",
                "member_key",
                vec![object.clone(), value],
            ))),
        }
    }

    pub fn binary(&mut self, binary: &'a BinaryExpression<'a>) -> Expr {
        let left = self.expr(&binary.left);
        let right = self.expr(&binary.right);
        let call = |function: &str, args: Vec<Expr>| Expr::call("buoy_ref", function, args);
        let value = match binary.operator {
            BinaryOperator::StrictEquality => strict_eq(left, right),
            BinaryOperator::StrictInequality => Expr::not(strict_eq(left, right)),
            BinaryOperator::Equality => call("loose_eq", vec![left, right]),
            BinaryOperator::Inequality => Expr::not(call("loose_eq", vec![left, right])),
            BinaryOperator::LessThan => call("lt", vec![left, right]),
            BinaryOperator::LessEqualThan => call("le", vec![left, right]),
            BinaryOperator::GreaterThan => call("gt", vec![left, right]),
            BinaryOperator::GreaterEqualThan => call("ge", vec![left, right]),
            BinaryOperator::Addition => call("add", vec![left, right]),
            BinaryOperator::Subtraction => call("sub", vec![left, right]),
            BinaryOperator::Multiplication => call("mul", vec![left, right]),
            BinaryOperator::Division => call("divide", vec![left, right]),
            BinaryOperator::Remainder => call("remainder", vec![left, right]),
            BinaryOperator::Exponential => call("power", vec![left, right]),
            BinaryOperator::ShiftLeft => call("shift_left", vec![left, right]),
            BinaryOperator::ShiftRight => call("shift_right", vec![left, right]),
            BinaryOperator::ShiftRightZeroFill => call("shift_right_unsigned", vec![left, right]),
            BinaryOperator::BitwiseOR => call("bit_or", vec![left, right]),
            BinaryOperator::BitwiseXOR => call("bit_xor", vec![left, right]),
            BinaryOperator::BitwiseAnd => call("bit_and", vec![left, right]),
            BinaryOperator::In => call("in", vec![left, right]),
            BinaryOperator::Instanceof => call("instance_of", vec![left, right]),
        };
        self.bind(value)
    }

    pub fn logical(&mut self, logical: &'a LogicalExpression<'a>) -> Expr {
        let left = self.expr(&logical.left);
        let left = self.bind(left);
        let right = self.branch(|me| me.expr(&logical.right));
        let boolean = is_boolean(&logical.left);
        self.bind(logical_case(logical.operator, left, right, boolean))
    }

    pub fn conditional(&mut self, conditional: &'a ConditionalExpression<'a>) -> Expr {
        let test = self.test(&conditional.test);
        let yes = self.branch(|me| me.expr(&conditional.consequent));
        let no = self.branch(|me| me.expr(&conditional.alternate));
        self.bind(boolean_case(test, yes, no))
    }

    pub fn unary(&mut self, unary: &'a UnaryExpression<'a>) -> Expr {
        match unary.operator {
            UnaryOperator::LogicalNot => {
                let test = self.test(&unary.argument);
                self.bind(Expr::not(test))
            }
            UnaryOperator::UnaryNegation => {
                if let Expression::NumericLiteral(literal) = &unary.argument {
                    return number(-literal.value);
                }
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("buoy_ref", "negate", vec![value]))
            }
            UnaryOperator::UnaryPlus => {
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("buoy_ref", "plus", vec![value]))
            }
            UnaryOperator::BitwiseNot => {
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("buoy_ref", "bit_not", vec![value]))
            }
            UnaryOperator::Typeof => {
                if let Expression::Identifier(ident) = strip(&unary.argument) {
                    let objects = self.with_objects(ident);
                    if !objects.is_empty() {
                        let fallback = self.branch(|me| me.typeof_identifier(ident));
                        let name = ident.name.as_str();
                        return self.through_withs(
                            &objects,
                            name,
                            |me, object| {
                                let value = me.with_get(object, name);
                                vec![Expr::call("buoy_ref", "typeof", vec![value])]
                            },
                            fallback,
                        );
                    }
                    return self.typeof_identifier(ident);
                }
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("buoy_ref", "typeof", vec![value]))
            }
            UnaryOperator::Void => {
                self.effect(&unary.argument);
                Expr::undefined()
            }
            UnaryOperator::Delete => match strip(&unary.argument) {
                Expression::Identifier(ident) => self.delete_identifier(ident),
                // `delete a?.b` deletes `b`, and is true when the chain ends early.
                Expression::ChainExpression(chain)
                    if chain.expression.as_member_expression().is_some() =>
                {
                    let code = self.branch(|me| match chain.expression.as_member_expression() {
                        Some(member) => me.delete_member(member),
                        None => Expr::atom("true"),
                    });
                    self.end_chain(code, &Expr::atom("true"))
                }
                other => match other.as_member_expression() {
                    Some(member) => self.delete_member(member),
                    None => {
                        self.effect(other);
                        Expr::atom("true")
                    }
                },
            },
        }
    }

    /// `delete o.k`: the delete of the property, after the guard of an optional `o?.k`.
    fn delete_member(&mut self, member: &'a MemberExpression<'a>) -> Expr {
        let (object, key) = self.member_parts(member);
        if super_parts(&object).is_some() {
            return self.bind(Expr::call(
                "buoy_heap",
                "throw_error",
                vec![
                    Expr::atom("ReferenceError"),
                    Expr::js_string("Unsupported reference to 'super'"),
                ],
            ));
        }
        if member.optional() {
            self.chain_guard(object.clone());
        }
        let (fixed, computed) = if self.frame.sloppy {
            ("sloppy_delete", "sloppy_delete_computed")
        } else {
            ("delete", "delete_computed")
        };
        let value = match key {
            MemberKey::Static(key) => Expr::call("buoy_ref", fixed, vec![object, key]),
            MemberKey::Dynamic(key) => Expr::call("buoy_ref", computed, vec![object, key]),
            MemberKey::Private(_) => Expr::atom("true"),
        };
        self.bind(value)
    }
}

/// The operator of a logical assignment (`&&=`, `||=`, `??=`).
fn logical_operator(operator: AssignmentOperator) -> Option<LogicalOperator> {
    match operator {
        AssignmentOperator::LogicalAnd => Some(LogicalOperator::And),
        AssignmentOperator::LogicalOr => Some(LogicalOperator::Or),
        AssignmentOperator::LogicalNullish => Some(LogicalOperator::Coalesce),
        _ => None,
    }
}

/// `===`: inline for atoms and strings, whose equality is term equality.
pub fn strict_eq(left: Expr, right: Expr) -> Expr {
    let simple =
        |e: &Expr| matches!(e, Expr::Atom(name) if name != "NaN") || matches!(e, Expr::JsString(_));
    if simple(&left) || simple(&right) {
        return Expr::op("=:=", left, right);
    }
    Expr::call("buoy_ref", "strict_eq", vec![left, right])
}

pub fn logical_case(
    operator: LogicalOperator,
    left: Expr,
    right: Vec<Expr>,
    boolean: bool,
) -> Expr {
    let truthy = if boolean {
        left.clone()
    } else {
        Expr::call("buoy_ref", "truthy", vec![left.clone()])
    };
    match operator {
        LogicalOperator::And => boolean_case(truthy, right, vec![left]),
        LogicalOperator::Or => boolean_case(truthy, vec![left], right),
        LogicalOperator::Coalesce => Expr::case(
            left.clone(),
            vec![
                Clause::new(Expr::undefined(), right.clone()),
                Clause::new(Expr::atom("null"), right),
                Clause::new(Expr::var("_"), vec![left]),
            ],
        ),
    }
}

/// Whether the expression always yields an Erlang boolean.
pub fn is_boolean(expression: &Expression<'_>) -> bool {
    match expression {
        Expression::BooleanLiteral(_) => true,
        Expression::BinaryExpression(binary) => matches!(
            binary.operator,
            BinaryOperator::StrictEquality
                | BinaryOperator::StrictInequality
                | BinaryOperator::Equality
                | BinaryOperator::Inequality
                | BinaryOperator::LessThan
                | BinaryOperator::LessEqualThan
                | BinaryOperator::GreaterThan
                | BinaryOperator::GreaterEqualThan
                | BinaryOperator::In
                | BinaryOperator::Instanceof
        ),
        Expression::UnaryExpression(unary) => unary.operator == UnaryOperator::LogicalNot,
        Expression::LogicalExpression(logical) => {
            logical.operator != LogicalOperator::Coalesce
                && is_boolean(&logical.left)
                && is_boolean(&logical.right)
        }
        Expression::ParenthesizedExpression(inner) => is_boolean(&inner.expression),
        _ => false,
    }
}

/// The expression without parentheses and type assertions.
pub fn strip<'r, 'a>(expression: &'r Expression<'a>) -> &'r Expression<'a> {
    match expression {
        Expression::ParenthesizedExpression(inner) => strip(&inner.expression),
        Expression::TSAsExpression(inner) => strip(&inner.expression),
        Expression::TSSatisfiesExpression(inner) => strip(&inner.expression),
        Expression::TSNonNullExpression(inner) => strip(&inner.expression),
        Expression::TSTypeAssertion(inner) => strip(&inner.expression),
        Expression::TSInstantiationExpression(inner) => strip(&inner.expression),
        other => other,
    }
}
