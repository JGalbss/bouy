//! Pre-passes over a subtree (section 12): the variables it rebinds, and the completions
//! that escape it.

use std::collections::{BTreeSet, HashSet};

use oxc::ast::ast::{ArrowFunctionExpression, Class, Function};
use oxc::ast::ast::{
    AssignmentExpression, AssignmentTarget, AssignmentTargetMaybeDefault, AssignmentTargetProperty,
    CallExpression, Expression, ForInStatement, ForOfStatement, ForStatementLeft,
    IdentifierReference, SimpleAssignmentTarget, Statement, TSType, TSTypeAnnotation,
    TSTypeParameterDeclaration, TSTypeParameterInstantiation, UnaryExpression, UpdateExpression,
};
use oxc::ast_visit::{Visit, walk};
use oxc::semantic::{Scoping, SymbolId};
use oxc::span::Span;
use oxc::syntax::operator::UnaryOperator;
use oxc::syntax::scope::ScopeFlags;

use super::scope::Target;

/// Method names whose call on a place writes the new receiver back (section 6).
pub const MUTATORS: &[&str] = &[
    "push",
    "pop",
    "shift",
    "unshift",
    "splice",
    "sort",
    "reverse",
    "fill",
    "copyWithin",
    "set",
    "add",
    "delete",
    "clear",
    "next",
];

/// Mutators that return their receiver, so that `m.set(a, 1).set(b, 2)` and
/// `xs.sort().reverse()` change the place `m` or `xs` twice (section 6).
pub const RETURNS_RECEIVER: &[&str] = &["set", "add", "sort", "reverse", "fill", "copyWithin"];

/// The receiver and the name of a method call: `r.m(...)`, `r.#m(...)`, or `r["m"](...)`
/// with a string literal key.
pub fn method_callee<'e, 'a>(callee: &'e Expression<'a>) -> Option<(&'e Expression<'a>, String)> {
    match strip(callee) {
        Expression::StaticMemberExpression(member) if !member.optional => {
            Some((&member.object, member.property.name.to_string()))
        }
        Expression::PrivateFieldExpression(member) if !member.optional => {
            Some((&member.object, format!("#{}", member.field.name)))
        }
        Expression::ComputedMemberExpression(member) if !member.optional => {
            match strip(&member.expression) {
                Expression::StringLiteral(name) => Some((&member.object, name.value.to_string())),
                _ => None,
            }
        }
        _ => None,
    }
}

/// `m.get(key)`: the entry of a Map, which a write changes through `m.set(key, value)`.
pub fn map_entry<'e, 'a>(
    call: &'e CallExpression<'a>,
) -> Option<(&'e Expression<'a>, &'e Expression<'a>)> {
    let Expression::StaticMemberExpression(member) = strip(&call.callee) else {
        return None;
    };
    match call.arguments.as_slice() {
        [key] if !call.optional && !member.optional && member.property.name == "get" => {
            key.as_expression().map(|key| (&member.object, key))
        }
        _ => None,
    }
}

/// The expression at the start of a chain of property reads and Map entry reads.
pub fn chain_base<'e, 'a>(expr: &'e Expression<'a>) -> &'e Expression<'a> {
    match strip(expr) {
        Expression::StaticMemberExpression(member) => chain_base(&member.object),
        Expression::ComputedMemberExpression(member) => chain_base(&member.object),
        Expression::PrivateFieldExpression(member) => chain_base(&member.object),
        Expression::CallExpression(call) => match map_entry(call) {
            Some((object, _)) => chain_base(object),
            None => strip(expr),
        },
        other => other,
    }
}

/// Finds the root variable of places, which section 6 rebinds on a write.
#[derive(Debug)]
pub struct Roots<'c> {
    pub scoping: &'c Scoping,
    /// Symbols that are never places, such as library namespace imports and actor refs.
    pub opaque: &'c HashSet<SymbolId>,
    /// The fields of `this` that hold actor refs, which are not places either, for the
    /// class at each span.
    pub ref_fields: &'c [(Span, HashSet<String>)],
}

impl Roots<'_> {
    /// The root of the place `expr`: a variable or `this` reached through property reads.
    pub fn place(&self, expr: &Expression<'_>) -> Option<Target> {
        match strip(expr) {
            Expression::Identifier(ident) => self.symbol(ident).map(Target::Symbol),
            Expression::ThisExpression(_) => Some(Target::This),
            Expression::StaticMemberExpression(member) if !member.optional => {
                if self.is_ref_field(&member.object, member.property.name.as_str(), member.span) {
                    return None;
                }
                self.place(&member.object)
            }
            Expression::ComputedMemberExpression(member) if !member.optional => {
                self.place(&member.object)
            }
            Expression::PrivateFieldExpression(member) if !member.optional => {
                if self.is_ref_field(
                    &member.object,
                    &format!("#{}", member.field.name),
                    member.span,
                ) {
                    return None;
                }
                self.place(&member.object)
            }
            Expression::CallExpression(call) => {
                map_entry(call).and_then(|(object, _)| self.place(object))
            }
            _ => None,
        }
    }

    /// The root of the place that a mutator call on `expr` writes back: a place, a call of a
    /// mutator that returns its receiver on such a place, such as `m.set(a, 1)`, or an
    /// assignment to a place, such as `(groups[k] ??= [])`.
    pub fn receiver(&self, expr: &Expression<'_>) -> Option<Target> {
        match strip(expr) {
            Expression::CallExpression(call) if !call.optional => {
                match method_callee(&call.callee) {
                    Some((object, name)) if RETURNS_RECEIVER.contains(&name.as_str()) => {
                        self.receiver(object)
                    }
                    _ => self.place(expr),
                }
            }
            Expression::AssignmentExpression(assignment) => {
                match assignment.left.as_simple_assignment_target()? {
                    SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => {
                        self.symbol(ident).map(Target::Symbol)
                    }
                    target => self.place(target.as_member_expression()?.object()),
                }
            }
            _ => self.place(expr),
        }
    }

    /// Whether `this.<key>` at `at` reads a field that the innermost enclosing class
    /// declares with the type `Ref`.
    fn is_ref_field(&self, object: &Expression<'_>, key: &str, at: Span) -> bool {
        matches!(strip(object), Expression::ThisExpression(_))
            && self
                .ref_fields
                .iter()
                .filter(|(class, _)| class.start <= at.start && at.end <= class.end)
                .min_by_key(|(class, _)| class.size())
                .is_some_and(|(_, fields)| fields.contains(key))
    }

    fn symbol(&self, ident: &IdentifierReference<'_>) -> Option<SymbolId> {
        let reference = self.scoping.get_reference(ident.reference_id.get()?);
        reference
            .symbol_id()
            .filter(|symbol| !self.opaque.contains(symbol))
    }

    /// The roots of the property paths that an assignment target writes, including the
    /// paths inside a destructuring pattern. Variables are write references instead.
    pub fn assigned(&self, target: &AssignmentTarget<'_>) -> Vec<Target> {
        let mut roots = Vec::new();
        self.collect_assigned(target, &mut roots);
        roots
    }

    fn collect_assigned(&self, target: &AssignmentTarget<'_>, roots: &mut Vec<Target>) {
        match target {
            AssignmentTarget::ArrayAssignmentTarget(pattern) => {
                for element in pattern.elements.iter().flatten() {
                    self.collect_maybe_default(element, roots);
                }
                if let Some(rest) = &pattern.rest {
                    self.collect_assigned(&rest.target, roots);
                }
            }
            AssignmentTarget::ObjectAssignmentTarget(pattern) => {
                for property in &pattern.properties {
                    if let AssignmentTargetProperty::AssignmentTargetPropertyProperty(property) =
                        property
                    {
                        self.collect_maybe_default(&property.binding, roots);
                    }
                }
                if let Some(rest) = &pattern.rest {
                    self.collect_assigned(&rest.target, roots);
                }
            }
            simple => {
                if let Some(member) = simple.as_member_expression()
                    && let Some(root) = self.place(member.object())
                {
                    roots.push(root);
                }
            }
        }
    }

    fn collect_maybe_default(
        &self,
        target: &AssignmentTargetMaybeDefault<'_>,
        roots: &mut Vec<Target>,
    ) {
        match target {
            AssignmentTargetMaybeDefault::AssignmentTargetWithDefault(with_default) => {
                self.collect_assigned(&with_default.binding, roots);
            }
            other => {
                if let Some(target) = other.as_assignment_target() {
                    self.collect_assigned(target, roots);
                }
            }
        }
    }

    /// The root that a call rebinds: a mutator on a place, `Object.assign(place, ...)`, or
    /// `this.m()` for a class method.
    pub fn called(
        &self,
        call: &CallExpression<'_>,
        methods: Option<&HashSet<String>>,
    ) -> Option<Target> {
        if let Some(target) = self.assigned_object(call) {
            return self.place(target);
        }
        // `this[name](args)` may call any method, so it may change `this`.
        if let Expression::ComputedMemberExpression(member) = strip(&call.callee)
            && matches!(strip(&member.object), Expression::ThisExpression(_))
            && !matches!(strip(&member.expression), Expression::StringLiteral(_))
            && methods.is_some()
        {
            return Some(Target::This);
        }
        let (object, name) = method_callee(&call.callee)?;
        let is_this = matches!(strip(object), Expression::ThisExpression(_));
        if is_this && methods.is_some_and(|methods| methods.contains(&name)) {
            return Some(Target::This);
        }
        if MUTATORS.contains(&name.as_str()) && !call.optional {
            return self.receiver(object);
        }
        None
    }

    /// The target of `Object.assign(target, ...sources)` with the global `Object`, which
    /// changes its first argument.
    pub fn assigned_object<'e, 'a>(
        &self,
        call: &'e CallExpression<'a>,
    ) -> Option<&'e Expression<'a>> {
        let Expression::StaticMemberExpression(member) = strip(&call.callee) else {
            return None;
        };
        let Expression::Identifier(object) = strip(&member.object) else {
            return None;
        };
        let global = object
            .reference_id
            .get()
            .is_some_and(|id| self.scoping.get_reference(id).symbol_id().is_none());
        if !(global && object.name == "Object" && member.property.name == "assign") {
            return None;
        }
        call.arguments.first()?.as_expression()
    }
}

/// `expr` without parentheses and TypeScript-only wrappers.
pub fn strip<'e, 'a>(expr: &'e Expression<'a>) -> &'e Expression<'a> {
    match expr {
        Expression::ParenthesizedExpression(inner) => strip(&inner.expression),
        Expression::TSAsExpression(inner) => strip(&inner.expression),
        Expression::TSSatisfiesExpression(inner) => strip(&inner.expression),
        Expression::TSNonNullExpression(inner) => strip(&inner.expression),
        Expression::TSTypeAssertion(inner) => strip(&inner.expression),
        Expression::TSInstantiationExpression(inner) => strip(&inner.expression),
        _ => expr,
    }
}

/// Collects the variables a subtree rebinds that are declared outside `exclude`.
pub struct Rebound<'c> {
    roots: &'c Roots<'c>,
    methods: Option<&'c HashSet<String>>,
    exclude: Span,
    found: BTreeSet<Target>,
}

impl<'c> Rebound<'c> {
    pub fn new(roots: &'c Roots<'c>, methods: Option<&'c HashSet<String>>, exclude: Span) -> Self {
        Self {
            roots,
            methods,
            exclude,
            found: BTreeSet::new(),
        }
    }

    /// Adds the roots that writing to `target` rebinds, as in a `for...of` head.
    pub fn assigned(&mut self, target: &AssignmentTarget<'_>) {
        for root in self.roots.assigned(target) {
            self.add(root);
        }
    }

    pub fn finish(self) -> Vec<Target> {
        self.found.into_iter().collect()
    }

    fn add(&mut self, target: Target) {
        if let Target::Symbol(symbol) = target {
            let declared = self.roots.scoping.symbol_span(symbol);
            if self.exclude.start <= declared.start && declared.end <= self.exclude.end {
                return;
            }
        }
        self.found.insert(target);
    }
}

impl<'a> Visit<'a> for Rebound<'_> {
    fn visit_function(&mut self, _function: &Function<'a>, _flags: ScopeFlags) {}

    fn visit_arrow_function_expression(&mut self, _arrow: &ArrowFunctionExpression<'a>) {}

    fn visit_class(&mut self, _class: &Class<'a>) {}

    fn visit_ts_type(&mut self, _ty: &TSType<'a>) {}

    fn visit_ts_type_annotation(&mut self, _annotation: &TSTypeAnnotation<'a>) {}

    fn visit_ts_type_parameter_declaration(&mut self, _it: &TSTypeParameterDeclaration<'a>) {}

    fn visit_ts_type_parameter_instantiation(&mut self, _it: &TSTypeParameterInstantiation<'a>) {}

    fn visit_identifier_reference(&mut self, ident: &IdentifierReference<'a>) {
        let Some(id) = ident.reference_id.get() else {
            return;
        };
        let reference = self.roots.scoping.get_reference(id);
        if reference.is_write()
            && let Some(symbol) = reference.symbol_id()
        {
            self.add(Target::Symbol(symbol));
        }
    }

    fn visit_assignment_expression(&mut self, it: &AssignmentExpression<'a>) {
        for root in self.roots.assigned(&it.left) {
            self.add(root);
        }
        walk::walk_assignment_expression(self, it);
    }

    fn visit_update_expression(&mut self, it: &UpdateExpression<'a>) {
        if let Some(member) = it.argument.as_member_expression()
            && let Some(root) = self.roots.place(member.object())
        {
            self.add(root);
        }
        walk::walk_update_expression(self, it);
    }

    fn visit_unary_expression(&mut self, it: &UnaryExpression<'a>) {
        if it.operator == UnaryOperator::Delete
            && let Some(member) = strip(&it.argument).as_member_expression()
            && let Some(root) = self.roots.place(member.object())
        {
            self.add(root);
        }
        walk::walk_unary_expression(self, it);
    }

    fn visit_call_expression(&mut self, it: &CallExpression<'a>) {
        if let Some(root) = self.roots.called(it, self.methods) {
            self.add(root);
        }
        walk::walk_call_expression(self, it);
    }

    fn visit_for_of_statement(&mut self, it: &ForOfStatement<'a>) {
        self.head(&it.left);
        walk::walk_for_of_statement(self, it);
    }

    fn visit_for_in_statement(&mut self, it: &ForInStatement<'a>) {
        self.head(&it.left);
        walk::walk_for_in_statement(self, it);
    }
}

impl Rebound<'_> {
    /// A `for...of` or `for...in` head such as `this.cur` writes its place on each iteration.
    fn head(&mut self, left: &ForStatementLeft<'_>) {
        if let Some(target) = left.as_assignment_target() {
            self.assigned(target);
        }
    }
}

/// The completions that escape a statement: `return`, and a `break` or `continue` whose
/// target lies outside it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Escapes {
    pub ret: bool,
    pub brk: bool,
    pub cont: bool,
}

impl Escapes {
    pub fn any(self) -> bool {
        self.ret || self.brk || self.cont
    }

    pub fn union(self, other: Self) -> Self {
        Self {
            ret: self.ret || other.ret,
            brk: self.brk || other.brk,
            cont: self.cont || other.cont,
        }
    }

    /// What escapes a loop whose body has these escapes: only `return`.
    pub fn out_of_loop(self) -> Self {
        Self {
            ret: self.ret,
            brk: false,
            cont: false,
        }
    }
}

/// Whether a subtree reads any of `targets`, outside nested functions.
pub fn reads_any(
    scoping: &Scoping,
    targets: &[Target],
    visit: impl FnOnce(&mut Reads<'_>),
) -> bool {
    let mut reads = Reads {
        scoping,
        targets,
        found: false,
    };
    visit(&mut reads);
    reads.found
}

pub struct Reads<'c> {
    scoping: &'c Scoping,
    targets: &'c [Target],
    found: bool,
}

impl<'a> Visit<'a> for Reads<'_> {
    fn visit_function(&mut self, _function: &Function<'a>, _flags: ScopeFlags) {}

    fn visit_class(&mut self, _class: &Class<'a>) {}

    fn visit_this_expression(&mut self, _this: &oxc::ast::ast::ThisExpression) {
        self.found |= self.targets.contains(&Target::This);
    }

    fn visit_identifier_reference(&mut self, ident: &IdentifierReference<'a>) {
        let symbol = ident
            .reference_id
            .get()
            .and_then(|id| self.scoping.get_reference(id).symbol_id());
        if let Some(symbol) = symbol {
            self.found |= self.targets.contains(&Target::Symbol(symbol));
        }
    }
}

pub fn escapes(statement: &Statement<'_>) -> Escapes {
    match statement {
        Statement::ReturnStatement(_) => Escapes {
            ret: true,
            ..Escapes::default()
        },
        Statement::BreakStatement(_) => Escapes {
            brk: true,
            ..Escapes::default()
        },
        Statement::ContinueStatement(_) => Escapes {
            cont: true,
            ..Escapes::default()
        },
        Statement::BlockStatement(block) => escapes_all(&block.body),
        Statement::IfStatement(branch) => escapes(&branch.consequent).union(
            branch
                .alternate
                .as_ref()
                .map_or_else(Escapes::default, escapes),
        ),
        Statement::SwitchStatement(switch) => {
            let inner = switch.cases.iter().fold(Escapes::default(), |found, case| {
                found.union(escapes_all(&case.consequent))
            });
            Escapes {
                brk: false,
                ..inner
            }
        }
        Statement::ForStatement(each) => escapes(&each.body).out_of_loop(),
        Statement::ForInStatement(each) => escapes(&each.body).out_of_loop(),
        Statement::ForOfStatement(each) => escapes(&each.body).out_of_loop(),
        Statement::WhileStatement(each) => escapes(&each.body).out_of_loop(),
        Statement::DoWhileStatement(each) => escapes(&each.body).out_of_loop(),
        Statement::TryStatement(attempt) => {
            let handler = attempt
                .handler
                .as_ref()
                .map_or_else(Escapes::default, |handler| escapes_all(&handler.body.body));
            let finalizer = attempt
                .finalizer
                .as_ref()
                .map_or_else(Escapes::default, |finalizer| escapes_all(&finalizer.body));
            escapes_all(&attempt.block.body)
                .union(handler)
                .union(finalizer)
        }
        Statement::LabeledStatement(labeled) => escapes(&labeled.body),
        _ => Escapes::default(),
    }
}

pub fn escapes_all(statements: &[Statement<'_>]) -> Escapes {
    statements
        .iter()
        .fold(Escapes::default(), |found, statement| {
            found.union(escapes(statement))
        })
}

/// Whether control can reach the end of a block whose last statement is `last`. A `false`
/// answer is always right; `true` may be conservative.
pub fn falls_through(last: Option<&Statement<'_>>) -> bool {
    last.is_none_or(|last| match last {
        Statement::ReturnStatement(_)
        | Statement::BreakStatement(_)
        | Statement::ContinueStatement(_)
        | Statement::ThrowStatement(_) => false,
        Statement::BlockStatement(block) => falls_through(block.body.last()),
        Statement::IfStatement(branch) => branch.alternate.as_ref().is_none_or(|alternate| {
            falls_through(Some(&branch.consequent)) || falls_through(Some(alternate))
        }),
        Statement::TryStatement(attempt) => {
            let body = falls_through(attempt.block.body.last());
            let handled = attempt
                .handler
                .as_ref()
                .is_some_and(|handler| falls_through(handler.body.body.last()));
            let finished = attempt
                .finalizer
                .as_ref()
                .is_none_or(|finalizer| falls_through(finalizer.body.last()));
            (body || handled) && finished
        }
        Statement::SwitchStatement(switch) => {
            let has_default = switch.cases.iter().any(|case| case.test.is_none());
            !has_default
                || switch.cases.iter().any(|case| {
                    escapes_all(&case.consequent).brk
                        || (!case.consequent.is_empty() && falls_through(case.consequent.last()))
                })
                || switch
                    .cases
                    .last()
                    .is_some_and(|case| case.consequent.is_empty())
        }
        _ => true,
    })
}
