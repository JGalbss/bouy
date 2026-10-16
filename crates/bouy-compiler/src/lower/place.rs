//! Places and mutation (section 6): assignment, update, `delete`, mutator calls, and
//! destructuring.
//!
//! A write reads the property chain from the root variable, sets the new value from the
//! innermost key outward with `bouy_rt:set/3`, and gives the root a new version.

use oxc::ast::ast::{
    Argument, AssignmentExpression, AssignmentTarget, AssignmentTargetMaybeDefault,
    AssignmentTargetProperty, BindingPattern, Expression, IdentifierReference, MemberExpression,
    PropertyKey, SimpleAssignmentTarget, UpdateExpression,
};
use oxc::span::{GetSpan, Span};
use oxc::syntax::operator::{AssignmentOperator, BinaryOperator, UpdateOperator};

use super::Lowerer;
use super::expr::Key;
use super::rebind::strip;
use super::scope::{Target, base_name};
use super::stmt::boolean_case;
use crate::erlang::{Clause, Expr};

/// A variable or `this`, followed by property keys.
pub struct Place<'a> {
    root: Target,
    keys: Vec<Key<'a>>,
}

/// The left side of an assignment.
enum Lhs<'a> {
    Variable(Target),
    Place(Place<'a>),
}

impl<'a> Lowerer<'a, '_> {
    pub fn assign(&mut self, assignment: &'a AssignmentExpression<'a>, want_value: bool) -> Expr {
        if matches!(
            assignment.left,
            AssignmentTarget::ArrayAssignmentTarget(_)
                | AssignmentTarget::ObjectAssignmentTarget(_)
        ) {
            let value = self.expr(&assignment.right);
            let value = self.trivial(value);
            self.assign_target(&assignment.left, value.clone());
            return value;
        }
        let Some(lhs) = self.lhs(&assignment.left) else {
            return self.expr(&assignment.right);
        };
        match lhs {
            Lhs::Variable(target) => {
                let current = self.current(target);
                let value = self.assigned_value(assignment.operator, current, &assignment.right);
                let name = self.scope.bind(target, &self.base(target));
                self.push_match(Expr::var(&name), value);
                Expr::Var(name)
            }
            Lhs::Place(place) => {
                let keys = self.place_keys(&place);
                let depth = keys.len();
                if assignment.operator == AssignmentOperator::Assign {
                    let value = self.expr(&assignment.right);
                    let value = self.trivial(value);
                    let objects = self.chain_reads(place.root, &keys, depth - 1);
                    self.write_chain(place.root, &objects, &keys, value.clone());
                    return value;
                }
                let objects = self.chain_reads(place.root, &keys, depth);
                let current = objects[depth].clone();
                let value = self.assigned_value(assignment.operator, current, &assignment.right);
                let value = if want_value {
                    self.trivial(value)
                } else {
                    value
                };
                self.write_chain(place.root, &objects[..depth], &keys, value.clone());
                value
            }
        }
    }

    /// The value an assignment operator stores, given the current value.
    fn assigned_value(
        &mut self,
        operator: AssignmentOperator,
        current: Expr,
        right: &'a Expression<'a>,
    ) -> Expr {
        match operator {
            AssignmentOperator::Assign => self.expr(right),
            AssignmentOperator::LogicalOr => {
                let right = self.sub_expr(right);
                let truthy = Expr::rt("truthy", vec![current.clone()]);
                boolean_case(truthy, vec![current], vec![right])
            }
            AssignmentOperator::LogicalAnd => {
                let right = self.sub_expr(right);
                let truthy = Expr::rt("truthy", vec![current.clone()]);
                boolean_case(truthy, vec![right], vec![current])
            }
            AssignmentOperator::LogicalNullish => {
                let right = self.sub_expr(right);
                let absent = self.scope.temp();
                let guards = ["null", "undefined"]
                    .map(|name| Expr::op("=:=", Expr::var(&absent), Expr::atom(name)))
                    .to_vec();
                Expr::case(
                    current.clone(),
                    vec![
                        Clause::guarded(Expr::var(&absent), guards, vec![right]),
                        Clause::new(Expr::var("_"), vec![current]),
                    ],
                )
            }
            arithmetic => {
                let right = self.expr(right);
                let function = arithmetic
                    .to_binary_operator()
                    .and_then(arithmetic_function)
                    .unwrap_or("add");
                Expr::rt(function, vec![current, right])
            }
        }
    }

    pub fn update(&mut self, update: &'a UpdateExpression<'a>, want_value: bool) -> Expr {
        let Some(lhs) = self.simple_lhs(&update.argument) else {
            return Expr::undefined();
        };
        let increment = update.operator == UpdateOperator::Increment;
        let (current, place) = match lhs {
            Lhs::Variable(target) => (self.current(target), Err(target)),
            Lhs::Place(place) => {
                let keys = self.place_keys(&place);
                let objects = self.chain_reads(place.root, &keys, keys.len());
                let current = objects[keys.len()].clone();
                (current, Ok((place.root, objects, keys)))
            }
        };
        let (next, result) = if want_value && !update.prefix {
            let old = self.trivial(Expr::rt("to_number", vec![current]));
            let operator = if increment { "add" } else { "sub" };
            (
                Expr::rt(operator, vec![old.clone(), Expr::Integer(1)]),
                Some(old),
            )
        } else {
            let step = if increment { -1 } else { 1 };
            (Expr::rt("sub", vec![current, Expr::Integer(step)]), None)
        };
        let written = match place {
            Err(target) => {
                let name = self.scope.bind(target, &self.base(target));
                self.push_match(Expr::var(&name), next);
                Expr::Var(name)
            }
            Ok((root, objects, keys)) => {
                let next = self.trivial(next);
                self.write_chain(root, &objects[..keys.len()], &keys, next.clone());
                next
            }
        };
        result.unwrap_or(written)
    }

    /// `delete place.key`: removes the key and yields `true`.
    pub fn delete(&mut self, argument: &'a Expression<'a>, span: Span) -> Expr {
        let place = strip(argument)
            .as_member_expression()
            .and_then(|member| self.member_place(member));
        let Some(place) = place else {
            return self.unsupported(
                span,
                "`delete` is supported only on a property of a variable or of `this`",
            );
        };
        let keys = self.place_keys(&place);
        let depth = keys.len();
        let objects = self.chain_reads(place.root, &keys, depth - 1);
        let removed = Expr::rt(
            "delete",
            vec![objects[depth - 1].clone(), keys[depth - 1].clone()],
        );
        self.write_chain(
            place.root,
            &objects[..depth - 1],
            &keys[..depth - 1],
            removed,
        );
        Expr::atom("true")
    }

    /// `place.m(args)` for a mutator name: `{Result, R1} = bouy_rt:mutate(R, <<"m">>, Args)`,
    /// then `R1` is written back to the place.
    pub fn mutate(
        &mut self,
        object: &'a Expression<'a>,
        name: &str,
        arguments: &'a [Argument<'a>],
    ) -> Expr {
        let Some(place) = self.place_of(object) else {
            let receiver = self.expr(object);
            let arguments = self.arguments(arguments);
            return Expr::rt("call_method", vec![receiver, Expr::binary(name), arguments]);
        };
        let keys = self.place_keys(&place);
        let arguments = self.arguments(arguments);
        let objects = self.chain_reads(place.root, &keys, keys.len());
        let receiver = objects[keys.len()].clone();
        let result = self.scope.temp();
        let call = Expr::rt("mutate", vec![receiver, Expr::binary(name), arguments]);
        if keys.is_empty() {
            let next = self.scope.bind(place.root, &self.base(place.root));
            self.seq.push(Expr::matches(
                Expr::Tuple(vec![Expr::var(&result), Expr::Var(next)]),
                call,
            ));
        } else {
            let updated = self.scope.temp();
            self.seq.push(Expr::matches(
                Expr::Tuple(vec![Expr::var(&result), Expr::var(&updated)]),
                call,
            ));
            self.write_chain(
                place.root,
                &objects[..keys.len()],
                &keys,
                Expr::Var(updated),
            );
        }
        Expr::Var(result)
    }

    /// Binds a declaration pattern to `value` (section 5).
    pub fn bind_pattern(&mut self, pattern: &'a BindingPattern<'a>, value: Expr) {
        match pattern {
            BindingPattern::BindingIdentifier(id) => {
                let Some(symbol) = id.symbol_id.get() else {
                    return;
                };
                let name = self
                    .scope
                    .bind(Target::Symbol(symbol), &base_name(&id.name));
                self.push_match(Expr::Var(name), value);
            }
            BindingPattern::AssignmentPattern(pattern) => {
                let value = self.defaulted(value, &pattern.right);
                self.bind_pattern(&pattern.left, value);
            }
            BindingPattern::ObjectPattern(pattern) => {
                let source = self.trivial(value);
                let mut keys = Vec::new();
                for property in &pattern.properties {
                    let key = self.pattern_key(&property.key, property.computed);
                    keys.push(key.clone());
                    self.bind_pattern(&property.value, Expr::rt("get", vec![source.clone(), key]));
                }
                if let Some(rest) = &pattern.rest {
                    let rest_value = Expr::rt("object_rest", vec![source, Expr::List(keys)]);
                    self.bind_pattern(&rest.argument, rest_value);
                }
            }
            BindingPattern::ArrayPattern(pattern) => {
                let source = self.trivial(Expr::rt("to_list", vec![value]));
                for (index, element) in pattern.elements.iter().enumerate() {
                    if let Some(element) = element {
                        let item = Expr::rt("get", vec![source.clone(), index_expr(index)]);
                        self.bind_pattern(element, item);
                    }
                }
                if let Some(rest) = &pattern.rest {
                    let rest_value = Expr::rt(
                        "array_rest",
                        vec![source, index_expr(pattern.elements.len())],
                    );
                    self.bind_pattern(&rest.argument, rest_value);
                }
            }
        }
    }

    /// Writes `value` to an assignment target, destructuring patterns.
    pub fn assign_target(&mut self, target: &'a AssignmentTarget<'a>, value: Expr) {
        match target {
            AssignmentTarget::ArrayAssignmentTarget(pattern) => {
                let source = self.trivial(Expr::rt("to_list", vec![value]));
                for (index, element) in pattern.elements.iter().enumerate() {
                    if let Some(element) = element {
                        let item = Expr::rt("get", vec![source.clone(), index_expr(index)]);
                        self.assign_maybe_default(element, item);
                    }
                }
                if let Some(rest) = &pattern.rest {
                    let rest_value = Expr::rt(
                        "array_rest",
                        vec![source, index_expr(pattern.elements.len())],
                    );
                    self.assign_target(&rest.target, rest_value);
                }
            }
            AssignmentTarget::ObjectAssignmentTarget(pattern) => {
                let source = self.trivial(value);
                let mut keys = Vec::new();
                for property in &pattern.properties {
                    match property {
                        AssignmentTargetProperty::AssignmentTargetPropertyIdentifier(property) => {
                            let key = Expr::binary(property.binding.name.as_str());
                            keys.push(key.clone());
                            let item = Expr::rt("get", vec![source.clone(), key]);
                            let item = match &property.init {
                                Some(default) => self.defaulted(item, default),
                                None => item,
                            };
                            self.assign_identifier(&property.binding, item);
                        }
                        AssignmentTargetProperty::AssignmentTargetPropertyProperty(property) => {
                            let key = self.pattern_key(&property.name, property.computed);
                            keys.push(key.clone());
                            let item = Expr::rt("get", vec![source.clone(), key]);
                            self.assign_maybe_default(&property.binding, item);
                        }
                    }
                }
                if let Some(rest) = &pattern.rest {
                    let rest_value = Expr::rt("object_rest", vec![source, Expr::List(keys)]);
                    self.assign_target(&rest.target, rest_value);
                }
            }
            simple => match self.lhs(simple) {
                Some(Lhs::Variable(target)) => {
                    let name = self.scope.bind(target, &self.base(target));
                    self.push_match(Expr::Var(name), value);
                }
                Some(Lhs::Place(place)) => {
                    let keys = self.place_keys(&place);
                    let objects = self.chain_reads(place.root, &keys, keys.len() - 1);
                    self.write_chain(place.root, &objects, &keys, value);
                }
                None => {}
            },
        }
    }

    fn assign_maybe_default(&mut self, target: &'a AssignmentTargetMaybeDefault<'a>, value: Expr) {
        match target {
            AssignmentTargetMaybeDefault::AssignmentTargetWithDefault(with_default) => {
                let value = self.defaulted(value, &with_default.init);
                self.assign_target(&with_default.binding, value);
            }
            other => {
                if let Some(target) = other.as_assignment_target() {
                    self.assign_target(target, value);
                }
            }
        }
    }

    fn assign_identifier(&mut self, ident: &'a IdentifierReference<'a>, value: Expr) {
        if let Some(Lhs::Variable(target)) = self.variable_lhs(ident) {
            let name = self.scope.bind(target, &self.base(target));
            self.push_match(Expr::Var(name), value);
        }
    }

    /// A key of a destructuring pattern.
    fn pattern_key(&mut self, key: &'a PropertyKey<'a>, computed: bool) -> Expr {
        if let Some(name) = key.static_name()
            && (!computed
                || key
                    .as_expression()
                    .is_some_and(|key| super::expr::literal(key).is_some()))
        {
            return Expr::binary(name.as_ref());
        }
        match key.as_expression() {
            Some(expression) => {
                let value = self.expr(expression);
                self.trivial(value)
            }
            None => self.unsupported(key.span(), "this destructuring key is not supported"),
        }
    }

    fn current(&mut self, target: Target) -> Expr {
        self.scope
            .current(target)
            .map_or_else(Expr::undefined, Expr::var)
    }

    fn lhs(&mut self, target: &'a AssignmentTarget<'a>) -> Option<Lhs<'a>> {
        match target {
            AssignmentTarget::AssignmentTargetIdentifier(ident) => self.variable_lhs(ident),
            AssignmentTarget::TSAsExpression(inner) => self.expression_lhs(&inner.expression),
            AssignmentTarget::TSSatisfiesExpression(inner) => {
                self.expression_lhs(&inner.expression)
            }
            AssignmentTarget::TSNonNullExpression(inner) => self.expression_lhs(&inner.expression),
            AssignmentTarget::TSTypeAssertion(inner) => self.expression_lhs(&inner.expression),
            other => other
                .as_member_expression()
                .and_then(|member| self.member_place(member))
                .map(Lhs::Place),
        }
    }

    fn simple_lhs(&mut self, target: &'a SimpleAssignmentTarget<'a>) -> Option<Lhs<'a>> {
        match target {
            SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => self.variable_lhs(ident),
            SimpleAssignmentTarget::TSAsExpression(inner) => self.expression_lhs(&inner.expression),
            SimpleAssignmentTarget::TSSatisfiesExpression(inner) => {
                self.expression_lhs(&inner.expression)
            }
            SimpleAssignmentTarget::TSNonNullExpression(inner) => {
                self.expression_lhs(&inner.expression)
            }
            SimpleAssignmentTarget::TSTypeAssertion(inner) => {
                self.expression_lhs(&inner.expression)
            }
            other => other
                .as_member_expression()
                .and_then(|member| self.member_place(member))
                .map(Lhs::Place),
        }
    }

    fn expression_lhs(&mut self, expression: &'a Expression<'a>) -> Option<Lhs<'a>> {
        match strip(expression) {
            Expression::Identifier(ident) => self.variable_lhs(ident),
            other => other
                .as_member_expression()
                .and_then(|member| self.member_place(member))
                .map(Lhs::Place),
        }
    }

    /// A local variable as an assignment target. Writes to module-level names are
    /// reported by the capture check (`BOUY202`).
    fn variable_lhs(&mut self, ident: &IdentifierReference<'_>) -> Option<Lhs<'a>> {
        let symbol = self.symbol_of(ident)?;
        let target = Target::Symbol(symbol);
        self.scope.current(target).map(|_| Lhs::Variable(target))
    }

    fn member_place(&mut self, member: &'a MemberExpression<'a>) -> Option<Place<'a>> {
        let key = match member {
            MemberExpression::StaticMemberExpression(member) => Key::Static(&member.property.name),
            MemberExpression::ComputedMemberExpression(member) => Key::Computed(&member.expression),
            MemberExpression::PrivateFieldExpression(member) => Key::Private(&member.field.name),
        };
        let mut place = self.place_of(member.object())?;
        place.keys.push(key);
        Some(place)
    }

    /// The place `expression` names, when its root is a local variable or `this`.
    pub fn place_of(&mut self, expression: &'a Expression<'a>) -> Option<Place<'a>> {
        match strip(expression) {
            Expression::Identifier(ident) => {
                let symbol = self.symbol_of(ident)?;
                let root = Target::Symbol(symbol);
                self.scope.current(root).map(|_| Place {
                    root,
                    keys: Vec::new(),
                })
            }
            Expression::ThisExpression(_) => self.scope.current(Target::This).map(|_| Place {
                root: Target::This,
                keys: Vec::new(),
            }),
            other => match other.as_member_expression() {
                Some(member) if !member.optional() => self.member_place(member),
                _ => {
                    self.unsupported(
                        other.span(),
                        "this value cannot change: assign to a variable or to a property path that starts at a variable or `this`",
                    );
                    None
                }
            },
        }
    }

    /// The lowered keys of a place, each evaluated once.
    fn place_keys(&mut self, place: &Place<'a>) -> Vec<Expr> {
        place
            .keys
            .iter()
            .map(|key| match key {
                Key::Static(name) => Expr::binary(*name),
                Key::Private(name) => Expr::binary(format!("#{name}")),
                Key::Computed(expression) => {
                    let value = self.expr(expression);
                    self.trivial(value)
                }
            })
            .collect()
    }

    /// The objects along a place: the root's current value, then each property read down to
    /// `depth` keys.
    fn chain_reads(&mut self, root: Target, keys: &[Expr], depth: usize) -> Vec<Expr> {
        let mut objects = vec![self.current(root)];
        for key in &keys[..depth] {
            let holder = objects.last().cloned().unwrap_or_else(Expr::undefined);
            let read = self.trivial(Expr::rt("get", vec![holder, key.clone()]));
            objects.push(read);
        }
        objects
    }

    /// Sets `value` at `keys` from the innermost object outward and rebinds the root.
    fn write_chain(&mut self, root: Target, objects: &[Expr], keys: &[Expr], value: Expr) {
        let updated = objects
            .iter()
            .zip(keys)
            .rev()
            .fold(value, |inner, (object, key)| {
                Expr::rt("set", vec![object.clone(), key.clone(), inner])
            });
        let name = self.scope.bind(root, &self.base(root));
        self.push_match(Expr::Var(name), updated);
    }
}

/// The `bouy_rt` function of an arithmetic or bitwise operator.
pub fn arithmetic_function(operator: BinaryOperator) -> Option<&'static str> {
    Some(match operator {
        BinaryOperator::Addition => "add",
        BinaryOperator::Subtraction => "sub",
        BinaryOperator::Multiplication => "mul",
        BinaryOperator::Division => "divide",
        BinaryOperator::Remainder => "remainder",
        BinaryOperator::Exponential => "power",
        BinaryOperator::ShiftLeft => "shift_left",
        BinaryOperator::ShiftRight => "shift_right",
        BinaryOperator::ShiftRightZeroFill => "shift_right_unsigned",
        BinaryOperator::BitwiseOR => "bit_or",
        BinaryOperator::BitwiseXOR => "bit_xor",
        BinaryOperator::BitwiseAnd => "bit_and",
        _ => return None,
    })
}

fn index_expr(index: usize) -> Expr {
    Expr::Integer(i64::try_from(index).unwrap_or(i64::MAX))
}
