//! Expressions in A-normal form: each operation binds a fresh variable in `pre`, so the
//! Erlang code runs the operations in the order of JavaScript. This file holds the
//! dispatch and the operators.

use oxc::ast::ast::{
    AssignmentExpression, AssignmentTarget, BinaryExpression, ConditionalExpression, Expression,
    IdentifierReference, LogicalExpression, SimpleAssignmentTarget, UnaryExpression,
    UpdateExpression,
};
use oxc::span::GetSpan;
use oxc::syntax::operator::{
    AssignmentOperator, BinaryOperator, LogicalOperator, UnaryOperator, UpdateOperator,
};

use super::context::{Kind, Lowerer, Top, boolean_case};
use super::literal::{js_string_literal, number};
use super::member::MemberKey;
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
                if self.frame.kind != Kind::Async {
                    return self.unsupported(expression.span, "`await` outside an async function");
                }
                let value = self.expr(&expression.argument);
                self.marker("await", value)
            }
            Expression::YieldExpression(expression) => {
                if expression.delegate {
                    return self.unsupported(expression.span, "`yield*`");
                }
                let value = match &expression.argument {
                    Some(argument) => self.expr(argument),
                    None => Expr::undefined(),
                };
                self.marker("yield", value)
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
            other => {
                let what = match other {
                    Expression::BigIntLiteral(_) => "a BigInt literal",
                    Expression::RegExpLiteral(_) => "a regular expression literal",
                    Expression::ClassExpression(_) => "a class expression",
                    Expression::TaggedTemplateExpression(_) => "a tagged template",
                    Expression::ImportExpression(_) => "`import()`",
                    Expression::ImportMeta(_) => "`import.meta`",
                    Expression::PrivateInExpression(_) => "`#name in`",
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
        Expr::call("bouy_ref", "truthy", vec![value])
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
                self.assign_identifier(ident, operator, right)
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
            Expression::Identifier(ident) => self.assign_identifier(ident, operator, right),
            other => self.unsupported(other.span(), "this assignment target"),
        }
    }

    /// `x op= right` for an identifier: a local, a module variable, or a global. An
    /// anonymous function gets the name `x`.
    pub fn assign_identifier(
        &mut self,
        ident: &'a IdentifierReference<'a>,
        operator: AssignmentOperator,
        right: &'a Expression<'a>,
    ) -> Expr {
        let name = Some(Expr::js_string(ident.name.as_str()));
        let Some(symbol) = self.symbol_of(ident.reference_id.get()) else {
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
        let value = self.combine(operator, current, right, name);
        self.assign_symbol(symbol, value, ident.span)
    }

    /// `delete x` in sloppy code: false for a declared binding, else the delete of the
    /// global object's property.
    fn delete_identifier(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        let global = match self.symbol_of(ident.reference_id.get()) {
            None => true,
            Some(symbol) => {
                !self.frame.env.contains_key(&symbol)
                    && matches!(self.tops.get(&symbol), Some(Top::Global(_)))
            }
        };
        if !global {
            return Expr::atom("false");
        }
        self.bind(Expr::call(
            "bouy_ref_realm",
            "delete_global",
            vec![Expr::js_string(ident.name.as_str())],
        ))
    }

    /// Stores `value` in the global `name`, as the mode of the code allows.
    pub fn set_global(&mut self, name: &str, value: Expr) -> Expr {
        let value = self.bind(value);
        let mode = Expr::atom(if self.frame.sloppy {
            "sloppy"
        } else {
            "strict"
        });
        self.pre.push(Expr::call(
            "bouy_ref_realm",
            "set_global",
            vec![Expr::js_string(name), value.clone(), mode],
        ));
        value
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
        let key = self.fix_key(key);
        let current = self.get(object.clone(), key.clone());
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
        let logical = match operator {
            AssignmentOperator::LogicalAnd => Some(LogicalOperator::And),
            AssignmentOperator::LogicalOr => Some(LogicalOperator::Or),
            AssignmentOperator::LogicalNullish => Some(LogicalOperator::Coalesce),
            _ => None,
        };
        if let Some(logical) = logical {
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
        self.bind(Expr::call("bouy_ref", function, vec![current, value]))
    }

    pub fn update(&mut self, update: &'a UpdateExpression<'a>) -> Expr {
        let function = match update.operator {
            UpdateOperator::Increment => "increment",
            UpdateOperator::Decrement => "decrement",
        };
        match &update.argument {
            SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => {
                let Some(symbol) = self.symbol_of(ident.reference_id.get()) else {
                    let old = self.identifier_read(ident);
                    let old = self.bind(Expr::call("bouy_ref", "to_numeric", vec![old]));
                    let new = self.bind(Expr::call("bouy_ref", function, vec![old.clone()]));
                    let new = self.set_global(ident.name.as_str(), new);
                    return if update.prefix { new } else { old };
                };
                let old = self.read_symbol(symbol, ident.span);
                let old = self.bind(old);
                let new = self.bind(Expr::call("bouy_ref", function, vec![old.clone()]));
                let new = self.assign_symbol(symbol, new, ident.span);
                if update.prefix { new } else { old }
            }
            other => match other.as_member_expression() {
                Some(member) => {
                    let (object, key) = self.member_parts(member);
                    let key = self.fix_key(key);
                    let old = self.get(object.clone(), key.clone());
                    let new = self.bind(Expr::call("bouy_ref", function, vec![old.clone()]));
                    self.set(object, key, new.clone());
                    if update.prefix { new } else { old }
                }
                None => self.unsupported(update.span, "this update"),
            },
        }
    }

    pub fn binary(&mut self, binary: &'a BinaryExpression<'a>) -> Expr {
        let left = self.expr(&binary.left);
        let right = self.expr(&binary.right);
        let call = |function: &str, args: Vec<Expr>| Expr::call("bouy_ref", function, args);
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
                self.bind(Expr::call("bouy_ref", "negate", vec![value]))
            }
            UnaryOperator::UnaryPlus => {
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("bouy_ref", "plus", vec![value]))
            }
            UnaryOperator::BitwiseNot => {
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("bouy_ref", "bit_not", vec![value]))
            }
            UnaryOperator::Typeof => {
                if let Expression::Identifier(ident) = &unary.argument
                    && self.symbol_of(ident.reference_id.get()).is_none()
                    && !matches!(ident.name.as_str(), "undefined" | "NaN" | "Infinity")
                    && !(ident.name == "arguments" && self.frame.arguments.is_some())
                {
                    let name = Expr::js_string(ident.name.as_str());
                    return self.bind(Expr::call("bouy_ref", "typeof_global", vec![name]));
                }
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("bouy_ref", "typeof", vec![value]))
            }
            UnaryOperator::Void => {
                self.effect(&unary.argument);
                Expr::undefined()
            }
            UnaryOperator::Delete => match unary.argument.as_member_expression() {
                Some(member) => {
                    let (object, key) = self.member_parts(member);
                    let (fixed, computed) = if self.frame.sloppy {
                        ("sloppy_delete", "sloppy_delete_computed")
                    } else {
                        ("delete", "delete_computed")
                    };
                    let value = match key {
                        MemberKey::Static(key) => Expr::call("bouy_ref", fixed, vec![object, key]),
                        MemberKey::Dynamic(key) => {
                            Expr::call("bouy_ref", computed, vec![object, key])
                        }
                    };
                    self.bind(value)
                }
                None => match strip(&unary.argument) {
                    Expression::Identifier(ident) => self.delete_identifier(ident),
                    other => {
                        self.effect(other);
                        Expr::atom("true")
                    }
                },
            },
        }
    }
}

/// `===`: inline for atoms and strings, whose equality is term equality.
pub fn strict_eq(left: Expr, right: Expr) -> Expr {
    let simple =
        |e: &Expr| matches!(e, Expr::Atom(name) if name != "NaN") || matches!(e, Expr::JsString(_));
    if simple(&left) || simple(&right) {
        return Expr::op("=:=", left, right);
    }
    Expr::call("bouy_ref", "strict_eq", vec![left, right])
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
        Expr::call("bouy_ref", "truthy", vec![left.clone()])
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
