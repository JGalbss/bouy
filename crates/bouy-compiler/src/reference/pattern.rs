//! Destructuring: declarations (`const { a, b: [c] } = v`) and assignments
//! (`[a, b] = [b, a]`).

use oxc::ast::ast::{
    AssignmentTarget, AssignmentTargetMaybeDefault, AssignmentTargetProperty, BindingPattern,
    Expression, SimpleAssignmentTarget,
};
use oxc::span::GetSpan;

use super::context::Lowerer;
use super::function::binding_name;
use super::member::{MemberKey, static_key};
use crate::erlang::{Clause, Expr};

impl<'a> Lowerer<'a, '_> {
    /// Declares the names of `pattern` from `value`.
    pub fn declare_pattern(&mut self, pattern: &'a BindingPattern<'a>, value: Expr) {
        match pattern {
            BindingPattern::BindingIdentifier(id) => {
                if let Some(symbol) = id.symbol_id.get() {
                    self.declare_symbol(symbol, value);
                }
            }
            BindingPattern::AssignmentPattern(assignment) => {
                let name = binding_name(&assignment.left);
                let value = self.with_default(value, &assignment.right, name);
                self.declare_pattern(&assignment.left, value);
            }
            BindingPattern::ObjectPattern(object) => {
                let source = self.bind(value);
                if object.properties.is_empty() {
                    // RequireObjectCoercible: `const {} = null` throws.
                    self.pre.push(Expr::call(
                        "bouy_ref_object",
                        "require_object",
                        vec![source.clone()],
                    ));
                }
                let mut keys = Vec::new();
                for property in &object.properties {
                    let key = self.property_key(&property.key, property.computed);
                    keys.push(key.clone());
                    let item = self.get(source.clone(), MemberKey::Static(key));
                    self.declare_pattern(&property.value, item);
                }
                if let Some(rest) = &object.rest {
                    let value = self.bind(Expr::call(
                        "bouy_ref",
                        "object_rest",
                        vec![source, Expr::List(keys)],
                    ));
                    self.declare_pattern(&rest.argument, value);
                }
            }
            BindingPattern::ArrayPattern(array) => {
                let source = self.bind(value);
                let (items, state) = self.take(source, array.elements.len());
                for (element, item) in array.elements.iter().zip(items) {
                    if let Some(element) = element {
                        self.declare_pattern(element, item);
                    }
                }
                if let Some(rest) = &array.rest {
                    let value =
                        self.bind(Expr::call("bouy_ref_iterator", "rest_list", vec![state]));
                    self.declare_pattern(&rest.argument, value);
                } else {
                    // The pattern did not exhaust the iterator: IteratorClose.
                    self.pre
                        .push(Expr::call("bouy_ref_iterator", "close", vec![state]));
                }
            }
        }
    }

    /// `value`, or the default when it is undefined.
    fn with_default(
        &mut self,
        value: Expr,
        default: &'a Expression<'a>,
        name: Option<Expr>,
    ) -> Expr {
        let value = self.bind(value);
        let fallback = self.branch(|me| me.named_expr(default, name));
        self.bind(Expr::case(
            value.clone(),
            vec![
                Clause::new(Expr::undefined(), fallback),
                Clause::new(Expr::var("_"), vec![value]),
            ],
        ))
    }

    /// The first `count` values of an iterable, and the iterator state after them.
    fn take(&mut self, source: Expr, count: usize) -> (Vec<Expr>, Expr) {
        let items: Vec<Expr> = (0..count).map(|_| Expr::var(self.fresh("Item"))).collect();
        let state = Expr::var(self.fresh("State"));
        self.pre.push(Expr::matches(
            Expr::Tuple(vec![Expr::List(items.clone()), state.clone()]),
            Expr::call(
                "bouy_ref_iterator",
                "take",
                vec![source, Expr::Integer(i64::try_from(count).unwrap_or(0))],
            ),
        ));
        (items, state)
    }

    /// Assigns `value` to an assignment target, destructuring a pattern.
    pub fn assign_target(&mut self, target: &'a AssignmentTarget<'a>, value: Expr) {
        match target {
            AssignmentTarget::ArrayAssignmentTarget(array) => {
                let source = self.bind(value);
                let (items, state) = self.take(source, array.elements.len());
                for (element, item) in array.elements.iter().zip(items) {
                    if let Some(element) = element {
                        self.assign_maybe_default(element, item);
                    }
                }
                if let Some(rest) = &array.rest {
                    let value =
                        self.bind(Expr::call("bouy_ref_iterator", "rest_list", vec![state]));
                    self.assign_target(&rest.target, value);
                } else {
                    self.pre
                        .push(Expr::call("bouy_ref_iterator", "close", vec![state]));
                }
            }
            AssignmentTarget::ObjectAssignmentTarget(object) => {
                let source = self.bind(value);
                if object.properties.is_empty() {
                    self.pre.push(Expr::call(
                        "bouy_ref_object",
                        "require_object",
                        vec![source.clone()],
                    ));
                }
                let mut keys = Vec::new();
                for property in &object.properties {
                    match property {
                        AssignmentTargetProperty::AssignmentTargetPropertyIdentifier(property) => {
                            let key = static_key(property.binding.name.as_str());
                            keys.push(key.clone());
                            let item = self.get(source.clone(), MemberKey::Static(key));
                            let name = Some(Expr::js_string(property.binding.name.as_str()));
                            let item = match &property.init {
                                Some(default) => self.with_default(item, default, name),
                                None => item,
                            };
                            match self.symbol_of(property.binding.reference_id.get()) {
                                Some(symbol) => {
                                    self.assign_symbol(symbol, item, property.span);
                                }
                                None => {
                                    self.set_global(property.binding.name.as_str(), item);
                                }
                            }
                        }
                        AssignmentTargetProperty::AssignmentTargetPropertyProperty(property) => {
                            let key = self.property_key(&property.name, property.computed);
                            keys.push(key.clone());
                            let item = self.get(source.clone(), MemberKey::Static(key));
                            self.assign_maybe_default(&property.binding, item);
                        }
                    }
                }
                if let Some(rest) = &object.rest {
                    let value = self.bind(Expr::call(
                        "bouy_ref",
                        "object_rest",
                        vec![source, Expr::List(keys)],
                    ));
                    self.assign_target(&rest.target, value);
                }
            }
            other => match other.as_simple_assignment_target() {
                Some(simple) => self.assign_simple_value(simple, value),
                None => {
                    self.unsupported(other.span(), "this assignment target");
                }
            },
        }
    }

    fn assign_maybe_default(&mut self, target: &'a AssignmentTargetMaybeDefault<'a>, value: Expr) {
        match target {
            AssignmentTargetMaybeDefault::AssignmentTargetWithDefault(with_default) => {
                let name = match &with_default.binding {
                    AssignmentTarget::AssignmentTargetIdentifier(ident) => {
                        Some(Expr::js_string(ident.name.as_str()))
                    }
                    _ => None,
                };
                let value = self.with_default(value, &with_default.init, name);
                self.assign_target(&with_default.binding, value);
            }
            other => match other.as_assignment_target() {
                Some(target) => self.assign_target(target, value),
                None => {
                    self.unsupported(other.span(), "this assignment target");
                }
            },
        }
    }

    fn assign_simple_value(&mut self, target: &'a SimpleAssignmentTarget<'a>, value: Expr) {
        match target {
            SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => {
                match self.symbol_of(ident.reference_id.get()) {
                    Some(symbol) => {
                        self.assign_symbol(symbol, value, ident.span);
                    }
                    None => {
                        self.set_global(ident.name.as_str(), value);
                    }
                }
            }
            other => match other.as_member_expression() {
                Some(member) => {
                    let (object, key) = self.member_parts(member);
                    self.set(object, key, value);
                }
                None => {
                    self.unsupported(other.span(), "this assignment target");
                }
            },
        }
    }
}
