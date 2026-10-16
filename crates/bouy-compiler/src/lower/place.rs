//! Places and mutation (section 6): assignment, update, `delete`, mutator calls,
//! `Object.assign`, and destructuring.
//!
//! A write reads the property chain from the root variable, sets the new value from the
//! innermost key outward with `bouy_rt:set/3`, and gives the root a new version.

use oxc::ast::ast::{
    Argument, AssignmentExpression, AssignmentTarget, AssignmentTargetMaybeDefault,
    AssignmentTargetProperty, BindingPattern, Expression, IdentifierReference, MemberExpression,
    PropertyKey, SimpleAssignmentTarget, UpdateExpression,
};
use oxc::span::{GetSpan, Span};
use oxc::syntax::operator::{AssignmentOperator, BinaryOperator, LogicalOperator, UpdateOperator};

use super::expr::{Key, argument_expression, field_key, field_write, static_key};
use super::rebind::{RETURNS_RECEIVER, chain_base, map_entry, method_callee, strip};
use super::scope::{Target, base_name};
use super::stmt::boolean_case;
use super::{Binding, Lowerer};
use crate::diagnostic::Code;
use crate::erlang::{Clause, Expr};
use crate::library;

/// A variable or `this`, followed by the steps to the place.
pub struct Place<'a> {
    root: Target,
    steps: Vec<Step<'a>>,
}

/// One step of a place: a property, or the entry `m.get(key)` of a Map.
#[derive(Clone, Copy)]
enum Step<'a> {
    Property(Key<'a>),
    Entry(&'a Expression<'a>),
}

/// A place whose keys are evaluated, each once.
struct Path {
    root: Target,
    accesses: Vec<Access>,
}

#[derive(Clone)]
enum Access {
    Property(Expr),
    /// A private field `#name`, under the atom key `'#name'` (section 9).
    Private(Expr),
    /// A Map entry: read with `get` and written with `set`.
    Entry(Expr),
}

impl Access {
    fn read(&self, object: Expr) -> Expr {
        match self {
            Self::Property(key) => Expr::rt("get", vec![object, key.clone()]),
            Self::Private(key) => {
                Expr::call("maps", "get", vec![key.clone(), object, Expr::undefined()])
            }
            Self::Entry(key) => Expr::rt(
                "call_method",
                vec![object, Expr::binary("get"), Expr::List(vec![key.clone()])],
            ),
        }
    }

    fn write(&self, object: Expr, value: Expr) -> Expr {
        match self {
            Self::Property(key) | Self::Private(key) => field_write(object, key, value),
            Self::Entry(key) => Expr::call(
                "erlang",
                "element",
                vec![
                    Expr::Integer(2),
                    Expr::rt(
                        "mutate",
                        vec![
                            object,
                            Expr::binary("set"),
                            Expr::List(vec![key.clone(), value]),
                        ],
                    ),
                ],
            ),
        }
    }
}

/// What a call does to its receiver.
#[derive(Clone, Copy)]
enum Mutation<'n> {
    /// A mutator method: `bouy_rt:mutate(R, <<"m">>, Args)` returns `{Result, R1}`.
    Method(&'n str),
    /// `Object.assign(R, ...)`: the merged object is the result and the new receiver.
    Assign,
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
        let Some(place) = self.lhs(&assignment.left) else {
            if let Some(target) = assignment.left.as_simple_assignment_target() {
                self.unwritable(target);
            }
            return self.expr(&assignment.right);
        };
        let path = self.path(&place);
        self.assign_path(
            &path,
            assignment.operator,
            &assignment.right,
            assignment.span,
            want_value,
        )
    }

    /// `path op= right`, with the keys of `path` already evaluated.
    fn assign_path(
        &mut self,
        path: &Path,
        operator: AssignmentOperator,
        right: &'a Expression<'a>,
        span: Span,
        want_value: bool,
    ) -> Expr {
        let depth = path.accesses.len();
        if depth == 0 {
            let current = self.current(path.root);
            let value = self.assigned_value(operator, current, right, span);
            let name = self.scope.bind(path.root, &self.base(path.root));
            self.push_match(Expr::var(&name), value);
            return Expr::Var(name);
        }
        // JavaScript fixes the object before the right side runs: when the right side
        // assigns the root variable, the write lands in the old object, which no variable
        // holds any more.
        let orphaned = self.reassigns(path.root, right.span());
        if operator == AssignmentOperator::Assign {
            let before = orphaned.then(|| self.read_path(path, depth - 1));
            let value = self.expr(right);
            let value = self.trivial(value);
            let objects = match before {
                Some(objects) => {
                    self.drop_write(path, &objects, value.clone());
                    return value;
                }
                None => self.read_path(path, depth - 1),
            };
            self.write_path(path, &objects, value.clone());
            return value;
        }
        let objects = self.read_path(path, depth);
        let current = objects[depth].clone();
        let rebinds = self.emits(right);
        let value = self.assigned_value(operator, current, right, span);
        let value = if want_value {
            self.trivial(value)
        } else {
            value
        };
        if orphaned {
            self.drop_write(path, &objects[..depth], value.clone());
        } else if rebinds {
            let objects = self.read_path(path, depth - 1);
            self.write_path(path, &objects, value.clone());
        } else {
            self.write_path(path, &objects[..depth], value.clone());
        }
        value
    }

    /// The value an assignment operator stores, given the current value.
    fn assigned_value(
        &mut self,
        operator: AssignmentOperator,
        current: Expr,
        right: &'a Expression<'a>,
        span: Span,
    ) -> Expr {
        let logical = match operator {
            AssignmentOperator::Assign => return self.expr(right),
            AssignmentOperator::LogicalOr => LogicalOperator::Or,
            AssignmentOperator::LogicalAnd => LogicalOperator::And,
            AssignmentOperator::LogicalNullish => LogicalOperator::Coalesce,
            arithmetic => {
                let right = self.expr(right);
                let function = arithmetic
                    .to_binary_operator()
                    .and_then(arithmetic_function)
                    .unwrap_or("add");
                return Expr::rt(function, vec![current, right]);
            }
        };
        if self.emits(right) {
            let current = self.trivial(current);
            return self.short_circuit(logical, &current, right, span);
        }
        let right = self.sub_expr(right);
        match logical {
            LogicalOperator::Or => {
                let truthy = Expr::rt("truthy", vec![current.clone()]);
                boolean_case(truthy, vec![current], vec![right])
            }
            LogicalOperator::And => {
                let truthy = Expr::rt("truthy", vec![current.clone()]);
                boolean_case(truthy, vec![right], vec![current])
            }
            LogicalOperator::Coalesce => {
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
        }
    }

    pub fn update(&mut self, update: &'a UpdateExpression<'a>, want_value: bool) -> Expr {
        let Some(place) = self.simple_lhs(&update.argument) else {
            self.unwritable(&update.argument);
            return Expr::undefined();
        };
        let path = self.path(&place);
        let depth = path.accesses.len();
        let objects = self.read_path(&path, depth);
        let current = objects[depth].clone();
        let increment = update.operator == UpdateOperator::Increment;
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
        let written = if depth == 0 {
            let name = self.scope.bind(path.root, &self.base(path.root));
            self.push_match(Expr::var(&name), next);
            Expr::Var(name)
        } else {
            let next = self.trivial(next);
            self.write_path(&path, &objects[..depth], next.clone());
            next
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
        let path = self.path(&place);
        let depth = path.accesses.len();
        let objects = self.read_path(&path, depth - 1);
        let Some(Access::Property(key)) = path.accesses.last() else {
            return self.unsupported(span, "`delete` is supported only on a property");
        };
        let removed = Expr::rt("delete", vec![objects[depth - 1].clone(), key.clone()]);
        let outer = Path {
            root: path.root,
            accesses: path.accesses[..depth - 1].to_vec(),
        };
        self.write_path(&outer, &objects[..depth - 1], removed);
        Expr::atom("true")
    }

    /// `r.m(args)` for a mutator name: `{Result, R1} = bouy_rt:mutate(R, <<"m">>, Args)`,
    /// then `R1` is written back to the place that `r` denotes.
    pub fn mutate(
        &mut self,
        object: &'a Expression<'a>,
        name: &str,
        arguments: &'a [Argument<'a>],
    ) -> Expr {
        let Some(path) = self.receiver_path(object) else {
            let receiver = self.expr(object);
            let arguments = self.arguments(arguments);
            return Expr::rt("call_method", vec![receiver, Expr::binary(name), arguments]);
        };
        self.mutate_path(&path, Mutation::Method(name), arguments)
    }

    /// `Object.assign(target, ...sources)` where `target` is a place: the merged object is
    /// written back to the place.
    pub fn assign_object(
        &mut self,
        target: &'a Expression<'a>,
        sources: &'a [Argument<'a>],
    ) -> Option<Expr> {
        let place = self.place_of(target)?;
        let path = self.path(&place);
        Some(self.mutate_path(&path, Mutation::Assign, sources))
    }

    /// The evaluated place that a mutator call on `expression` writes back (section 6). A
    /// mutator that returns its receiver, such as `m.set(k, v)` or `xs.sort()`, and an
    /// assignment, such as `(groups[k] ??= [])`, denote the place they change, after their
    /// own effects.
    fn receiver_path(&mut self, expression: &'a Expression<'a>) -> Option<Path> {
        self.roots.receiver(expression)?;
        match strip(expression) {
            Expression::CallExpression(call) if map_entry(call).is_none() => {
                let (object, name) = method_callee(&call.callee)?;
                let name = RETURNS_RECEIVER.iter().find(|known| **known == name)?;
                let path = self.receiver_path(object)?;
                self.mutate_path(&path, Mutation::Method(name), &call.arguments);
                Some(path)
            }
            Expression::AssignmentExpression(assignment) => {
                let place = self.lhs(&assignment.left)?;
                let path = self.path(&place);
                self.assign_path(
                    &path,
                    assignment.operator,
                    &assignment.right,
                    assignment.span,
                    false,
                );
                Some(path)
            }
            other => {
                let place = self.place_of(other)?;
                Some(self.path(&place))
            }
        }
    }

    /// The call that applies `mutation` to `receiver`: an expression of `{Result, Receiver1}`.
    fn mutation_call(&mut self, mutation: Mutation<'_>, receiver: Expr, arguments: Expr) -> Expr {
        match mutation {
            Mutation::Method(name) => {
                Expr::rt("mutate", vec![receiver, Expr::binary(name), arguments])
            }
            Mutation::Assign => {
                let arguments = match arguments {
                    Expr::List(mut sources) => {
                        sources.insert(0, receiver);
                        Expr::List(sources)
                    }
                    spread => Expr::Cons(vec![receiver], Box::new(spread)),
                };
                let merged = self.trivial(Expr::call("bouy_object", "assign", vec![arguments]));
                Expr::Tuple(vec![merged.clone(), merged])
            }
        }
    }

    /// Runs `mutation` on the value at `path` and writes the new value back.
    fn mutate_path(
        &mut self,
        path: &Path,
        mutation: Mutation<'_>,
        arguments: &'a [Argument<'a>],
    ) -> Expr {
        let depth = path.accesses.len();
        let orphaned = arguments
            .iter()
            .any(|argument| self.reassigns(path.root, argument.span()));
        let before = orphaned.then(|| self.read_path(path, depth));
        let arguments = self.arguments(arguments);
        let objects = match before {
            Some(objects) => {
                // The arguments assigned the root variable: the call changes the old value,
                // which no variable holds any more.
                let call = self.mutation_call(mutation, objects[depth].clone(), arguments);
                return Expr::call("erlang", "element", vec![Expr::Integer(1), call]);
            }
            None => self.read_path(path, depth),
        };
        let call = self.mutation_call(mutation, objects[depth].clone(), arguments);
        let result = self.scope.temp();
        if depth == 0 {
            let next = self.scope.bind(path.root, &self.base(path.root));
            self.push_match(Expr::Tuple(vec![Expr::var(&result), Expr::Var(next)]), call);
        } else {
            let updated = self.scope.temp();
            self.push_match(
                Expr::Tuple(vec![Expr::var(&result), Expr::var(&updated)]),
                call,
            );
            self.write_path(path, &objects[..depth], Expr::Var(updated));
        }
        Expr::Var(result)
    }

    /// `r?.m(args)` for a mutator name, where `r` is a place: `undefined` when the value at
    /// the place is `null` or `undefined`, else the mutator call, written back.
    pub fn optional_mutate(
        &mut self,
        object: &'a Expression<'a>,
        name: &str,
        arguments: &'a [Argument<'a>],
        span: Span,
    ) -> Option<Expr> {
        use oxc::ast_visit::Visit;
        let path = self.receiver_path(object)?;
        let depth = path.accesses.len();
        let objects = self.read_path(&path, depth);
        let receiver = self.trivial(objects[depth].clone());
        let mut vars = self.rebound(span, |found| {
            for argument in arguments {
                found.visit_expression(argument_expression(argument));
            }
        });
        if !vars.contains(&path.root) {
            vars.push(path.root);
        }
        let absent = vec![Expr::Tuple(vec![
            Expr::undefined(),
            self.scope.tuple(&vars),
        ])];
        let present = self.branch(|lowerer| {
            let arguments = lowerer.arguments(arguments);
            let call = Expr::rt(
                "mutate",
                vec![receiver.clone(), Expr::binary(name), arguments],
            );
            let result = lowerer.scope.temp();
            let updated = lowerer.scope.temp();
            lowerer.push_match(
                Expr::Tuple(vec![Expr::var(&result), Expr::var(&updated)]),
                call,
            );
            lowerer.write_path(&path, &objects[..depth], Expr::Var(updated));
            let tuple = lowerer.scope.tuple(&vars);
            lowerer
                .seq
                .push(Expr::Tuple(vec![Expr::Var(result), tuple]));
        });
        let present_name = self.scope.temp();
        let choice = Expr::case(
            receiver,
            vec![
                Clause::new(Expr::atom("null"), absent.clone()),
                Clause::new(Expr::undefined(), absent),
                Clause::new(Expr::var(&present_name), present),
            ],
        );
        let result = self.scope.temp();
        let tuple = self.rebind_tuple(&vars);
        self.push_match(Expr::Tuple(vec![Expr::var(&result), tuple]), choice);
        Some(Expr::Var(result))
    }

    /// Whether code in `span` assigns the variable `root` itself, rather than a property.
    fn reassigns(&self, root: Target, span: Span) -> bool {
        let Target::Symbol(symbol) = root else {
            return false;
        };
        self.semantic
            .scoping()
            .get_resolved_references(symbol)
            .any(|reference| {
                let at = self.semantic.reference_span(reference);
                reference.is_write() && span.start <= at.start && at.end <= span.end
            })
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
                Some(place) => {
                    let path = self.path(&place);
                    let depth = path.accesses.len();
                    if depth == 0 {
                        let name = self.scope.bind(path.root, &self.base(path.root));
                        self.push_match(Expr::Var(name), value);
                    } else {
                        let objects = self.read_path(&path, depth - 1);
                        self.write_path(&path, &objects, value);
                    }
                }
                None => {
                    if let Some(target) = simple.as_simple_assignment_target() {
                        self.unwritable(target);
                    }
                }
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
        match self.variable_lhs(ident) {
            Some(place) => {
                let name = self.scope.bind(place.root, &self.base(place.root));
                self.push_match(Expr::Var(name), value);
            }
            None => self.unwritable_identifier(ident),
        }
    }

    /// A key of a destructuring pattern.
    fn pattern_key(&mut self, key: &'a PropertyKey<'a>, computed: bool) -> Expr {
        if let Some(name) = static_key(key)
            && (!computed
                || key
                    .as_expression()
                    .is_some_and(|key| super::expr::literal(key).is_some()))
        {
            return Expr::binary(name);
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

    fn lhs(&mut self, target: &'a AssignmentTarget<'a>) -> Option<Place<'a>> {
        match target.as_simple_assignment_target() {
            Some(simple) => self.simple_lhs(simple),
            None => None,
        }
    }

    fn simple_lhs(&mut self, target: &'a SimpleAssignmentTarget<'a>) -> Option<Place<'a>> {
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
                .and_then(|member| self.member_place(member)),
        }
    }

    fn expression_lhs(&mut self, expression: &'a Expression<'a>) -> Option<Place<'a>> {
        match strip(expression) {
            Expression::Identifier(ident) => self.variable_lhs(ident),
            other => other
                .as_member_expression()
                .and_then(|member| self.member_place(member)),
        }
    }

    /// A local variable as an assignment target. Writes to module-level names are
    /// reported by the capture check (`BOUY202`).
    fn variable_lhs(&mut self, ident: &IdentifierReference<'_>) -> Option<Place<'a>> {
        let symbol = self.symbol_of(ident)?;
        let root = Target::Symbol(symbol);
        self.scope.current(root).map(|_| Place {
            root,
            steps: Vec::new(),
        })
    }

    fn member_place(&mut self, member: &'a MemberExpression<'a>) -> Option<Place<'a>> {
        let key = match member {
            MemberExpression::StaticMemberExpression(member) => Key::Static(&member.property.name),
            MemberExpression::ComputedMemberExpression(member) => Key::Computed(&member.expression),
            MemberExpression::PrivateFieldExpression(member) => Key::Private(&member.field.name),
        };
        let mut place = self.place_of(member.object())?;
        place.steps.push(Step::Property(key));
        Some(place)
    }

    /// The place `expression` names, when its root is a local variable or `this`.
    pub fn place_of(&mut self, expression: &'a Expression<'a>) -> Option<Place<'a>> {
        match strip(expression) {
            Expression::Identifier(ident) => self.variable_lhs(ident),
            Expression::ThisExpression(_) => self.scope.current(Target::This).map(|_| Place {
                root: Target::This,
                steps: Vec::new(),
            }),
            Expression::CallExpression(call) if let Some((object, key)) = map_entry(call) => {
                let mut place = self.place_of(object)?;
                place.steps.push(Step::Entry(key));
                Some(place)
            }
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

    /// Evaluates the keys of a place, each once.
    fn path(&mut self, place: &Place<'a>) -> Path {
        let accesses = place
            .steps
            .iter()
            .map(|step| match step {
                Step::Property(Key::Static(name)) => Access::Property(Expr::binary(*name)),
                Step::Property(Key::Private(name)) => {
                    Access::Private(field_key(&format!("#{name}")))
                }
                Step::Property(Key::Computed(expression)) => {
                    let value = self.expr(expression);
                    Access::Property(self.trivial(value))
                }
                Step::Entry(expression) => {
                    let value = self.expr(expression);
                    Access::Entry(self.trivial(value))
                }
            })
            .collect();
        Path {
            root: place.root,
            accesses,
        }
    }

    /// The objects along a path: the root's current value, then each read down to `depth`
    /// steps.
    fn read_path(&mut self, path: &Path, depth: usize) -> Vec<Expr> {
        let mut objects = vec![self.current(path.root)];
        for access in &path.accesses[..depth] {
            let holder = objects.last().cloned().unwrap_or_else(Expr::undefined);
            let read = self.trivial(access.read(holder));
            objects.push(read);
        }
        objects
    }

    /// Sets `value` at the end of `path` from the innermost object outward, and rebinds the
    /// root.
    fn write_path(&mut self, path: &Path, objects: &[Expr], value: Expr) {
        let updated = nested_write(path, objects, value);
        let name = self.scope.bind(path.root, &self.base(path.root));
        self.push_match(Expr::Var(name), updated);
    }

    /// A write to an object that no variable holds any more: it runs for its errors, and the
    /// root keeps its version.
    fn drop_write(&mut self, path: &Path, objects: &[Expr], value: Expr) {
        let updated = nested_write(path, objects, value);
        self.push(updated);
    }

    /// Reports a write to a target that no place reaches: a global, an import, an actor
    /// ref, or `this` outside a class. A module-level `const` of this module is `BOUY202`,
    /// which the capture check reports, and a root that is not a variable is reported where
    /// the place is resolved.
    fn unwritable(&mut self, target: &'a SimpleAssignmentTarget<'a>) {
        match target {
            SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => {
                self.unwritable_identifier(ident);
            }
            SimpleAssignmentTarget::TSAsExpression(inner) => {
                self.unwritable_root(&inner.expression);
            }
            SimpleAssignmentTarget::TSSatisfiesExpression(inner) => {
                self.unwritable_root(&inner.expression);
            }
            SimpleAssignmentTarget::TSNonNullExpression(inner) => {
                self.unwritable_root(&inner.expression);
            }
            SimpleAssignmentTarget::TSTypeAssertion(inner) => {
                self.unwritable_root(&inner.expression);
            }
            member => {
                if let Some(member) = member.as_member_expression() {
                    self.unwritable_root(member.object());
                }
            }
        }
    }

    /// Reports a mutation of the value that `expression` reads when its root is not a place.
    pub fn unwritable_root(&mut self, expression: &'a Expression<'a>) {
        match chain_base(expression) {
            Expression::Identifier(ident) => self.unwritable_identifier(ident),
            Expression::ThisExpression(this) if self.scope.current(Target::This).is_none() => {
                self.unsupported(
                    this.span,
                    "`this` is supported only inside class methods and the arrow functions in them",
                );
            }
            _ => {}
        }
    }

    fn unwritable_identifier(&mut self, ident: &IdentifierReference<'_>) {
        let name = ident.name.as_str();
        let Some(symbol) = self.symbol_of(ident) else {
            if name == "process" {
                self.report(
                    ident.span,
                    Code::HostApi,
                    "`process` cannot change in Bouy; read process.env.NAME or process.argv, and throw an error to exit with status 1",
                );
            } else if library::global(name).is_some() {
                self.unsupported(
                    ident.span,
                    format!("`{name}` is a global of Bouy and cannot change"),
                );
            } else {
                self.unsupported(
                    ident.span,
                    format!("`{name}` is not declared; declare it with `let` or `const`"),
                );
            }
            return;
        };
        match self.module.bindings.get(&symbol) {
            Some(Binding::ImportedModule(_)) => self.report(
                ident.span,
                Code::ModuleState,
                format!(
                    "`{name}` is another module, whose module-level values cannot change after initialization; call a function of that module instead"
                ),
            ),
            Some(Binding::Library(_)) => {
                self.unsupported(ident.span, format!("the import `{name}` cannot change"));
            }
            None if self.module.opaque.contains(&symbol) => {
                self.unsupported(
                    ident.span,
                    format!(
                        "`{name}` is an actor ref, which has no fields to change; call a method of the actor instead"
                    ),
                );
            }
            Some(_) | None => {}
        }
    }
}

/// `bouy_rt:set/3` from the innermost object of `path` outward.
fn nested_write(path: &Path, objects: &[Expr], value: Expr) -> Expr {
    objects
        .iter()
        .zip(&path.accesses)
        .rev()
        .fold(value, |inner, (object, access)| {
            access.write(object.clone(), inner)
        })
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
