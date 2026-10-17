//! Destructuring: declarations (`const { a, b: [c] } = v`) and assignments
//! (`[a, b] = [b, a]`).

use oxc::ast::ast::{
    AssignmentTarget, AssignmentTargetMaybeDefault, AssignmentTargetProperty, BindingPattern,
    Expression, SimpleAssignmentTarget,
};
use oxc::span::GetSpan;

use std::collections::HashMap;

use oxc::semantic::SymbolId;

use oxc::ast_visit::Visit;

use super::analyze::Suspends;
use super::context::{Cont, FinallyFrame, Local, Lowerer, throw_value};
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
                let name = match &assignment.left {
                    BindingPattern::BindingIdentifier(id) => Some(id.name.as_str()),
                    _ => None,
                };
                let value = self.with_default(value, &assignment.right, name);
                self.declare_pattern(&assignment.left, value);
            }
            BindingPattern::ObjectPattern(object) => {
                let source = self.bind(value);
                self.require_coercible(&source);
                let mut keys = Vec::new();
                for property in &object.properties {
                    let key = self.property_key(&property.key, property.computed);
                    keys.push(key.clone());
                    let item = self.get(source.clone(), MemberKey::Static(key));
                    self.declare_pattern(&property.value, item);
                }
                if let Some(rest) = &object.rest {
                    let value = self.bind(Expr::call(
                        "bouy_ref_iterator",
                        "object_rest",
                        vec![source, Expr::List(keys)],
                    ));
                    self.declare_pattern(&rest.argument, value);
                }
            }
            BindingPattern::ArrayPattern(array) => {
                let elements = array
                    .elements
                    .iter()
                    .map(|element| element.as_ref().map(Element::Binding))
                    .collect();
                let rest = array
                    .rest
                    .as_ref()
                    .map(|rest| Rest::Binding(&rest.argument));
                self.array_pattern(value, elements, rest);
            }
        }
    }

    /// `value`, or the default when it is undefined.
    /// `value`, or the default when it is undefined. A default that is an anonymous
    /// function or class takes the `name` of its target.
    fn with_default(
        &mut self,
        value: Expr,
        default: &'a Expression<'a>,
        name: Option<&str>,
    ) -> Expr {
        let value = self.bind(value);
        let fallback = self.branch(|me| match name {
            Some(name) => me.named_expr(default, Expr::js_string(name)),
            None => me.expr(default),
        });
        self.bind(Expr::case(
            value.clone(),
            vec![
                Clause::new(Expr::undefined(), fallback),
                Clause::new(Expr::var("_"), vec![value]),
            ],
        ))
    }

    /// An object pattern throws a `TypeError` for null and undefined, even without
    /// properties.
    fn require_coercible(&mut self, source: &Expr) {
        self.pre.push(Expr::call(
            "bouy_ref_iterator",
            "require_coercible",
            vec![source.clone()],
        ));
    }

    /// An array pattern: the elements bind in order, each after its step of the
    /// iterator, and the iterator closes when the pattern ends before it is done. When an
    /// element can throw (a default, a nested pattern, or a member target), the elements
    /// bind inside an Erlang `try` that closes the iterator before the throw goes on; the
    /// variables they bind come out of the `try` in a tuple.
    fn array_pattern(
        &mut self,
        value: Expr,
        elements: Vec<Option<Element<'a>>>,
        rest: Option<Rest<'a>>,
    ) {
        let source = self.bind(value);
        let simple = elements.iter().flatten().all(Element::is_simple)
            && rest.as_ref().is_none_or(Rest::is_simple);
        if simple {
            let (items, state) = self.take(source, elements.len());
            for (element, item) in elements.into_iter().zip(items) {
                if let Some(element) = element {
                    self.bind_element(element, item);
                }
            }
            match rest {
                Some(rest) => {
                    let value =
                        self.bind(Expr::call("bouy_ref_iterator", "rest_list", vec![state]));
                    self.bind_rest(rest, value);
                }
                None => self
                    .pre
                    .push(Expr::call("bouy_ref_iterator", "finish", vec![state])),
            }
            return;
        }
        self.array_pattern_guarded(source, elements, rest);
    }

    /// An array pattern whose elements can throw: they bind inside an Erlang `try`, and
    /// the variables they bind come out of it in a tuple.
    fn array_pattern_guarded(
        &mut self,
        source: Expr,
        elements: Vec<Option<Element<'a>>>,
        rest: Option<Rest<'a>>,
    ) {
        let suspends = {
            let mut suspends = Suspends::default();
            for element in elements.iter().flatten() {
                element.visit(&mut suspends);
            }
            if let Some(rest) = &rest {
                rest.visit(&mut suspends);
            }
            suspends.0
        };
        let cell = self.fresh("Iteration");
        self.pre.push(Expr::matches(
            Expr::var(cell.clone()),
            Expr::call("bouy_ref_iterator", "pattern_cell", vec![source]),
        ));
        let handler = self.pattern_handler(&cell, suspends);
        let level = self.frame.region + 1;
        // A generator that returns at a `yield` in the pattern closes the iterator too.
        let close = suspends.then(|| {
            let close = self.fresh("PatternClose");
            let order = self.next_order();
            self.frame.finally.push(FinallyFrame {
                fun: close.clone(),
                order,
                base: self.frame.targets.len(),
                region: level - 1,
                jumps: Vec::new(),
                stays: None,
            });
            close
        });
        let saved_env = self.frame.env.clone();
        let saved = std::mem::take(&mut self.pre);
        self.frame.region += 1;
        self.frame.handlers.push(handler.clone());
        self.pattern_elements(&cell, elements, rest);
        self.frame.handlers.pop();
        self.frame.region -= 1;
        let mut body = std::mem::replace(&mut self.pre, saved);
        if let Some(close) = close
            && let Some(frame) = self.frame.finally.pop()
        {
            let completion = self.fresh("Completion");
            let env = std::mem::replace(&mut self.frame.env, saved_env.clone());
            let mut close_body = vec![Expr::call(
                "bouy_ref_iterator",
                "finish_cell",
                vec![Expr::var(cell.clone())],
            )];
            close_body.extend(self.completion_dispatch(&completion, &frame, &Cont::Return));
            self.frame.env = env;
            self.pre.push(Expr::matches(
                Expr::var(close),
                Expr::Fun {
                    name: None,
                    clauses: vec![Clause::new(Expr::var(completion), close_body)],
                },
            ));
        }
        let (inside, outside) = self.carry_out(saved_env);
        body.push(inside);
        let region = if suspends {
            // `seal` makes the code after the pattern the join fun of the region.
            Expr::call(
                "$region",
                "enter",
                vec![
                    Expr::var(handler),
                    Expr::Integer(i64::try_from(level).unwrap_or(0)),
                    Expr::Block(body),
                ],
            )
        } else {
            self.wrap_level(body, &handler, level)
        };
        self.pre.push(Expr::matches(outside, region));
        self.pre.push(Expr::call(
            "bouy_ref_iterator",
            "finish_cell",
            vec![Expr::var(cell)],
        ));
    }

    /// The handler of an array pattern: closes the iterator, unless it is done, and
    /// throws again. Inline, the throw goes to the Erlang `try`s around the pattern; a
    /// region that suspends runs its handler outside them, under the chain of handlers.
    fn pattern_handler(&mut self, cell: &str, suspends: bool) -> String {
        let handler = self.fresh("PatternHandler");
        let error = self.fresh("E");
        let rethrow = if suspends {
            let outer = self.handler_chain();
            self.wrap_chain(vec![throw_value(Expr::var(error.clone()))], &outer)
        } else {
            throw_value(Expr::var(error.clone()))
        };
        self.pre.push(Expr::matches(
            Expr::var(handler.clone()),
            Expr::Fun {
                name: None,
                clauses: vec![Clause::new(
                    Expr::var(error),
                    vec![
                        Expr::call(
                            "bouy_ref_iterator",
                            "abort",
                            vec![Expr::var(cell.to_owned())],
                        ),
                        rethrow,
                    ],
                )],
            },
        ));
        handler
    }

    /// The elements of a guarded array pattern, each after its step of the iterator in
    /// `cell`.
    fn pattern_elements(
        &mut self,
        cell: &str,
        elements: Vec<Option<Element<'a>>>,
        rest: Option<Rest<'a>>,
    ) {
        let step = |function: &'static str| {
            let cell = cell.to_owned();
            move |me: &mut Self| {
                me.bind(Expr::call(
                    "bouy_ref_iterator",
                    function,
                    vec![Expr::var(cell)],
                ))
            }
        };
        for element in elements {
            let next = step("next_value");
            match element {
                Some(Element::Target(target)) => self.assign_element_with(target, next),
                Some(Element::Binding(pattern)) => {
                    let item = next(self);
                    self.declare_pattern(pattern, item);
                }
                None => {
                    next(self);
                }
            }
        }
        if let Some(rest) = rest {
            let drain = step("rest_value");
            match rest {
                Rest::Target(target) => self.assign_target_with(target, drain),
                Rest::Binding(pattern) => {
                    let value = drain(self);
                    self.declare_pattern(pattern, value);
                }
            }
        }
    }

    /// The variables that the code since `saved_env` bound: the tuple of their values
    /// inside a `try`, and the pattern that binds them again after it.
    fn carry_out(&mut self, saved_env: HashMap<SymbolId, Local>) -> (Expr, Expr) {
        let changed: Vec<(SymbolId, Local)> = self
            .frame
            .env
            .iter()
            .filter(|(symbol, local)| {
                saved_env
                    .get(symbol)
                    .is_none_or(|old| local_name(old) != local_name(local))
            })
            .map(|(symbol, local)| (*symbol, local.clone()))
            .collect();
        let mut inside = vec![Expr::atom("ok")];
        inside.extend(
            changed
                .iter()
                .map(|(_, local)| Expr::var(local_name(local))),
        );
        self.frame.env = saved_env;
        let mut outside = vec![Expr::atom("ok")];
        for (symbol, local) in &changed {
            let name = self.symbol_var(*symbol);
            outside.push(Expr::var(name.clone()));
            let local = match local {
                Local::Var(_) => Local::Var(name),
                Local::Cell(_) => Local::Cell(name),
            };
            self.frame.env.insert(*symbol, local);
        }
        (Expr::Tuple(inside), Expr::Tuple(outside))
    }

    fn bind_element(&mut self, element: Element<'a>, value: Expr) {
        match element {
            Element::Binding(pattern) => self.declare_pattern(pattern, value),
            Element::Target(target) => self.assign_maybe_default(target, value),
        }
    }

    fn bind_rest(&mut self, rest: Rest<'a>, value: Expr) {
        match rest {
            Rest::Binding(pattern) => self.declare_pattern(pattern, value),
            Rest::Target(target) => self.assign_target(target, value),
        }
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
                let elements = array
                    .elements
                    .iter()
                    .map(|element| element.as_ref().map(Element::Target))
                    .collect();
                let rest = array.rest.as_ref().map(|rest| Rest::Target(&rest.target));
                self.array_pattern(value, elements, rest);
            }
            AssignmentTarget::ObjectAssignmentTarget(object) => {
                let source = self.bind(value);
                self.require_coercible(&source);
                let mut keys = Vec::new();
                for property in &object.properties {
                    match property {
                        AssignmentTargetProperty::AssignmentTargetPropertyIdentifier(property) => {
                            let key = static_key(property.binding.name.as_str());
                            keys.push(key.clone());
                            let item = self.get(source.clone(), MemberKey::Static(key));
                            let item = match &property.init {
                                Some(default) => self.with_default(
                                    item,
                                    default,
                                    Some(property.binding.name.as_str()),
                                ),
                                None => item,
                            };
                            match self.symbol_of(property.binding.reference_id.get()) {
                                Some(symbol) => {
                                    self.assign_symbol(symbol, item, property.span);
                                }
                                None => {
                                    self.unsupported(property.span, "an assignment to a global");
                                }
                            }
                        }
                        AssignmentTargetProperty::AssignmentTargetPropertyProperty(property) => {
                            let key = self.property_key(&property.name, property.computed);
                            keys.push(key.clone());
                            let source = source.clone();
                            self.assign_element_with(&property.binding, |me| {
                                me.get(source, MemberKey::Static(key))
                            });
                        }
                    }
                }
                if let Some(rest) = &object.rest {
                    let value = self.bind(Expr::call(
                        "bouy_ref_iterator",
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

    /// An element of an assignment pattern: a member target is evaluated before the value
    /// that it gets, as `DestructuringAssignmentTarget` is.
    fn assign_element_with(
        &mut self,
        target: &'a AssignmentTargetMaybeDefault<'a>,
        value: impl FnOnce(&mut Self) -> Expr,
    ) {
        let (binding, init) = match target {
            AssignmentTargetMaybeDefault::AssignmentTargetWithDefault(with_default) => {
                (&with_default.binding, Some(&with_default.init))
            }
            other => {
                let Some(binding) = other.as_assignment_target() else {
                    self.unsupported(other.span(), "this assignment target");
                    return;
                };
                (binding, None)
            }
        };
        let member = binding
            .as_simple_assignment_target()
            .and_then(SimpleAssignmentTarget::as_member_expression);
        let Some(member) = member else {
            let item = value(self);
            self.assign_maybe_default(target, item);
            return;
        };
        let (object, key) = self.member_parts(member);
        let item = value(self);
        let item = match init {
            Some(init) => self.with_default(item, init, None),
            None => item,
        };
        self.set(object, key, item);
    }

    /// A rest target: a member target is evaluated before the iterator is drained.
    fn assign_target_with(
        &mut self,
        target: &'a AssignmentTarget<'a>,
        value: impl FnOnce(&mut Self) -> Expr,
    ) {
        let member = target
            .as_simple_assignment_target()
            .and_then(SimpleAssignmentTarget::as_member_expression);
        if let Some(member) = member {
            let (object, key) = self.member_parts(member);
            let item = value(self);
            self.set(object, key, item);
        } else {
            let item = value(self);
            self.assign_target(target, item);
        }
    }

    fn assign_maybe_default(&mut self, target: &'a AssignmentTargetMaybeDefault<'a>, value: Expr) {
        match target {
            AssignmentTargetMaybeDefault::AssignmentTargetWithDefault(with_default) => {
                let name = match &with_default.binding {
                    AssignmentTarget::AssignmentTargetIdentifier(ident) => {
                        Some(ident.name.as_str())
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
                        self.unsupported(ident.span, "an assignment to a global");
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

/// An element of an array pattern.
#[derive(Clone, Copy)]
enum Element<'a> {
    Binding(&'a BindingPattern<'a>),
    Target(&'a AssignmentTargetMaybeDefault<'a>),
}

impl Element<'_> {
    fn visit(&self, visitor: &mut Suspends) {
        match self {
            Element::Binding(pattern) => visitor.visit_binding_pattern(pattern),
            Element::Target(target) => visitor.visit_assignment_target_maybe_default(target),
        }
    }

    /// Whether binding the element cannot throw: a plain name.
    fn is_simple(&self) -> bool {
        match self {
            Element::Binding(pattern) => matches!(pattern, BindingPattern::BindingIdentifier(_)),
            Element::Target(target) => matches!(
                target,
                AssignmentTargetMaybeDefault::AssignmentTargetIdentifier(_)
            ),
        }
    }
}

/// The rest element of an array pattern.
#[derive(Clone, Copy)]
enum Rest<'a> {
    Binding(&'a BindingPattern<'a>),
    Target(&'a AssignmentTarget<'a>),
}

impl Rest<'_> {
    fn visit(&self, visitor: &mut Suspends) {
        match self {
            Rest::Binding(pattern) => visitor.visit_binding_pattern(pattern),
            Rest::Target(target) => visitor.visit_assignment_target(target),
        }
    }

    fn is_simple(&self) -> bool {
        match self {
            Rest::Binding(pattern) => matches!(pattern, BindingPattern::BindingIdentifier(_)),
            Rest::Target(target) => {
                matches!(target, AssignmentTarget::AssignmentTargetIdentifier(_))
            }
        }
    }
}

fn local_name(local: &Local) -> String {
    match local {
        Local::Var(name) | Local::Cell(name) => name.clone(),
    }
}
