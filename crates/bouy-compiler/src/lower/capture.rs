//! Section 10 checks that need the whole module: `BOUY202` (a module-level value changes
//! after initialization) and `BOUY205` (the closure capture rule).
//!
//! An Erlang fun copies the values it captures. So a closure must not rebind a variable of
//! an enclosing function, and must not read a variable that the enclosing function rebinds
//! after the closure is created or in a loop around it.

use std::collections::{HashMap, HashSet};

use oxc::ast::ast::{
    Argument, ArrowFunctionExpression, AssignmentExpression, BindingIdentifier, BlockStatement,
    CallExpression, Class, ClassElement, DoWhileStatement, Expression, ForInStatement,
    ForOfStatement, ForStatement, ForStatementLeft, Function, FunctionBody, IdentifierReference,
    MethodDefinition, MethodDefinitionKind, Program, PropertyDefinition, ReturnStatement,
    Statement, SwitchCase, TSType, TSTypeAnnotation, TSTypeParameterDeclaration,
    TSTypeParameterInstantiation, ThisExpression, UnaryExpression, UpdateExpression,
    WhileStatement,
};
use oxc::ast_visit::{Visit, walk};
use oxc::semantic::{Semantic, SymbolId};
use oxc::span::{GetSpan, Span};
use oxc::syntax::operator::UnaryOperator;
use oxc::syntax::scope::ScopeFlags;

use super::ModuleContext;
use super::class::{ClassKind, classify, mutating_methods};
use super::hoist;
use super::rebind::{MUTATORS, Rebound, Roots, escapes, method_callee, strip};
use super::scope::Target;
use super::stmt::flatten;
use crate::diagnostic::{Code, Reporter};

/// A variable as the check sees it: a symbol, or the `this` of one method frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Variable {
    Symbol(SymbolId),
    This(usize),
}

#[derive(Debug)]
struct Frame {
    span: Span,
    /// Where the function value comes into existence: its own position, or for a nested
    /// function declaration, the statement before which its group is created.
    created: Span,
    /// The part of the parent frame that can run after this function exists, when a
    /// `return` ends the parent frame first.
    reach: Option<Span>,
    parent: Option<usize>,
    /// The frame whose `this` an expression in this frame means.
    this_owner: Option<usize>,
    /// The loops of the parent frame that enclose this frame.
    loops: Vec<Span>,
}

#[derive(Debug, Clone, Copy)]
struct Site {
    variable: Variable,
    span: Span,
    frame: usize,
}

/// A write: where it takes effect, and the closures that the written value holds.
#[derive(Debug, Clone)]
struct Write {
    site: Site,
    at: u32,
    stores: Vec<Span>,
}

/// The rest of a statement list from one statement on, and whether it always ends the
/// function with `return` or `throw`.
#[derive(Debug, Clone, Copy)]
struct Tail {
    span: Span,
    returns: bool,
}

pub fn check(
    program: &Program<'_>,
    semantic: &Semantic<'_>,
    context: &ModuleContext,
    roots: &Roots<'_>,
    reporter: &mut Reporter<'_>,
) {
    let mut collector = Collector {
        roots,
        semantic,
        context,
        frames: vec![Frame {
            span: program.span,
            created: program.span,
            reach: None,
            parent: None,
            this_owner: None,
            loops: Vec::new(),
        }],
        stack: vec![0],
        loops: vec![Vec::new()],
        tails: vec![Vec::new()],
        tries: vec![0],
        declared: HashMap::new(),
        reads: Vec::new(),
        writes: Vec::new(),
        writing: Vec::new(),
        methods: Vec::new(),
        method_next: false,
        created: HashMap::new(),
        listed: None,
        fields: Vec::new(),
    };
    collector.hoist(&program.body);
    walk::walk_program(&mut collector, program);
    collector.report(semantic, context, reporter);
}

struct Collector<'c, 's> {
    roots: &'c Roots<'c>,
    semantic: &'c Semantic<'s>,
    context: &'c ModuleContext,
    frames: Vec<Frame>,
    stack: Vec<usize>,
    /// The active loops of each frame on the stack.
    loops: Vec<Vec<Span>>,
    /// The statement tails that enclose the visit, for each frame on the stack.
    tails: Vec<Vec<Tail>>,
    /// The number of `try` statements that enclose the visit, for each frame on the stack.
    tries: Vec<usize>,
    declared: HashMap<SymbolId, usize>,
    reads: Vec<Site>,
    writes: Vec<Write>,
    /// The position and the stored closures of each assignment, update, or loop head that
    /// encloses the visit.
    writing: Vec<(u32, Vec<Span>)>,
    /// The methods that rebind `this` of each enclosing class.
    methods: Vec<HashSet<String>>,
    method_next: bool,
    /// The creation point of each nested function declaration, by the span of the function.
    created: HashMap<Span, u32>,
    /// The statement of a list whose visit is starting.
    listed: Option<Span>,
    /// For each field of the enclosing classes, by span: whether `this` changes after its
    /// initializer runs.
    fields: Vec<HashMap<Span, bool>>,
}

impl Collector<'_, '_> {
    fn frame(&self) -> usize {
        self.stack.last().copied().unwrap_or(0)
    }

    fn enter(&mut self, span: Span, this_owner: Option<usize>) -> usize {
        let index = self.frames.len();
        let loops = self.loops.last().cloned().unwrap_or_default();
        let created = self
            .created
            .get(&span)
            .map_or(span, |point| Span::new(*point, *point));
        let reach = (created == span).then(|| self.reach()).flatten();
        self.frames.push(Frame {
            span,
            created,
            reach,
            parent: Some(self.frame()),
            this_owner,
            loops,
        });
        self.stack.push(index);
        self.loops.push(Vec::new());
        self.tails.push(Vec::new());
        self.tries.push(0);
        index
    }

    fn leave(&mut self) {
        self.stack.pop();
        self.loops.pop();
        self.tails.pop();
        self.tries.pop();
    }

    /// The part of the current frame that can run after a closure created here: the rest of
    /// the innermost statement list that always returns, outside every `try`.
    fn reach(&self) -> Option<Span> {
        if self.tries.last().copied().unwrap_or(0) > 0 {
            return None;
        }
        self.tails
            .last()?
            .iter()
            .rev()
            .find(|tail| tail.returns)
            .map(|tail| tail.span)
    }

    fn in_loop(&mut self, span: Span, visit: impl FnOnce(&mut Self)) {
        if let Some(loops) = self.loops.last_mut() {
            loops.push(span);
        }
        visit(self);
        if let Some(loops) = self.loops.last_mut() {
            loops.pop();
        }
    }

    fn variable(&self, target: Target) -> Option<Variable> {
        match target {
            Target::Symbol(symbol) => Some(Variable::Symbol(symbol)),
            Target::This => self.frames[self.frame()].this_owner.map(Variable::This),
        }
    }

    fn write(&mut self, target: Target, span: Span, at: u32, stores: Vec<Span>) {
        if let Some(variable) = self.variable(target) {
            let frame = self.frame();
            self.writes.push(Write {
                site: Site {
                    variable,
                    span,
                    frame,
                },
                at,
                stores,
            });
        }
    }

    /// Records the creation point of the nested function declarations of a statement list,
    /// as lowering creates them (section 12).
    fn hoist<'a>(&mut self, statements: &'a [Statement<'a>]) {
        let list: Vec<&'a Statement<'a>> = statements.iter().collect();
        let flat = flatten(&list);
        let context = self.context;
        let groups = hoist::groups(&flat, self.semantic, |function| {
            function
                .id
                .as_ref()
                .and_then(|id| id.symbol_id.get())
                .is_some_and(|symbol| !context.is_module_scope(symbol))
        });
        for group in groups {
            let point = flat.get(group.position).map_or_else(
                || flat.last().map_or(0, |statement| statement.span().end),
                |statement| statement.span().start,
            );
            for function in group.functions {
                self.created.insert(function.span, point);
            }
        }
    }

    fn report(
        &self,
        semantic: &Semantic<'_>,
        context: &ModuleContext,
        reporter: &mut Reporter<'_>,
    ) {
        let scoping = semantic.scoping();
        let name = |variable: Variable| match variable {
            Variable::Symbol(symbol) => format!("`{}`", scoping.symbol_name(symbol)),
            Variable::This(_) => "`this`".to_owned(),
        };
        let mut module_reported = HashSet::new();
        for write in &self.writes {
            let write = &write.site;
            match write.variable {
                Variable::Symbol(symbol) if context.is_module_scope(symbol) => {
                    if module_reported.insert(symbol) {
                        reporter.report(
                            write.span,
                            Code::ModuleState,
                            format!(
                                "module-level {} cannot change after initialization; keep changing state in a function or an actor",
                                name(write.variable)
                            ),
                        );
                    }
                }
                variable => {
                    if self.declaring_frame(variable) != Some(write.frame) {
                        reporter.report(
                            write.span,
                            Code::Capture,
                            format!(
                                "a closure cannot change {}, which belongs to an enclosing function; return the new value from the closure instead",
                                name(variable)
                            ),
                        );
                    }
                }
            }
        }
        let mut warned = HashSet::new();
        for site in &self.reads {
            if let Variable::Symbol(symbol) = site.variable
                && context.is_module_scope(symbol)
            {
                continue;
            }
            let Some(declaring) = self.declaring_frame(site.variable) else {
                continue;
            };
            if declaring == site.frame {
                continue;
            }
            let Some(closure) = self.child_on_path(site.frame, declaring) else {
                continue;
            };
            let declared = match site.variable {
                Variable::Symbol(symbol) => scoping.symbol_span(symbol),
                Variable::This(owner) => self.frames[owner].span,
            };
            let frame = &self.frames[closure];
            let creation = frame.created;
            let later = self.writes.iter().find(|write| {
                write.site.variable == site.variable
                    && write.site.frame == declaring
                    && frame
                        .reach
                        .is_none_or(|reach| contains(reach, write.site.span))
                    && (write.at >= creation.end
                        && (write.site.span.start >= creation.end
                            || write.stores.contains(&frame.span))
                        || frame.loops.iter().any(|around| {
                            contains(*around, write.site.span) && !contains(*around, declared)
                        }))
            });
            if later.is_some() && warned.insert((closure, site.variable)) {
                reporter.report(
                    site.span,
                    Code::Capture,
                    format!(
                        "this closure reads {}, which changes after the closure is created or in a loop around it; the closure would keep the old value, so pass the value in as an argument",
                        name(site.variable)
                    ),
                );
            }
        }
    }

    fn declaring_frame(&self, variable: Variable) -> Option<usize> {
        match variable {
            Variable::Symbol(symbol) => self.declared.get(&symbol).copied(),
            Variable::This(owner) => Some(owner),
        }
    }

    /// The frame directly below `ancestor` on the path from `frame` up to it.
    fn child_on_path(&self, frame: usize, ancestor: usize) -> Option<usize> {
        let mut current = frame;
        loop {
            let parent = self.frames[current].parent?;
            if parent == ancestor {
                return Some(current);
            }
            current = parent;
        }
    }

    /// For each field of `class`: whether `this` changes after the field initializer runs,
    /// through a later field, a parameter property, the constructor body, or a method.
    fn field_changes(&self, class: &Class<'_>) -> HashMap<Span, bool> {
        let kind = classify(class, self.semantic.scoping(), &self.context.data);
        let mutating = mutating_methods(class, self.roots);
        let constructor = class.body.body.iter().find_map(|element| match element {
            ClassElement::MethodDefinition(method)
                if method.kind == MethodDefinitionKind::Constructor
                    && method.value.body.is_some() =>
            {
                Some(&method.value)
            }
            _ => None,
        });
        let constructor_changes = constructor.is_some_and(|constructor| {
            let properties = constructor
                .params
                .items
                .iter()
                .any(|param| param.accessibility.is_some() || param.readonly);
            let mut rebound = Rebound::new(self.roots, Some(&mutating), Span::default());
            if let Some(body) = &constructor.body {
                rebound.visit_function_body(body);
            }
            properties || rebound.finish().contains(&Target::This)
        });
        let fields: Vec<&PropertyDefinition<'_>> = class
            .body
            .body
            .iter()
            .filter_map(|element| match element {
                ClassElement::PropertyDefinition(field) if !field.r#static && !field.declare => {
                    Some(&**field)
                }
                _ => None,
            })
            .collect();
        let actor = matches!(kind, Some(ClassKind::Actor));
        fields
            .iter()
            .enumerate()
            .map(|(index, field)| {
                let later_field = fields[index + 1..]
                    .iter()
                    .any(|later| actor || later.value.is_some());
                (
                    field.span,
                    later_field || constructor_changes || !mutating.is_empty(),
                )
            })
            .collect()
    }
}

/// The closures that the value of `expression` holds: the expression itself when it is a
/// function, and the functions in the object literals, array literals, and branches that
/// make up its value.
fn stored_closures(expression: &Expression<'_>, found: &mut Vec<Span>) {
    match strip(expression) {
        Expression::ArrowFunctionExpression(arrow) => found.push(arrow.span),
        Expression::FunctionExpression(function) => found.push(function.span),
        Expression::ObjectExpression(object) => {
            for property in &object.properties {
                match property {
                    oxc::ast::ast::ObjectPropertyKind::ObjectProperty(property) => {
                        stored_closures(&property.value, found);
                    }
                    oxc::ast::ast::ObjectPropertyKind::SpreadProperty(spread) => {
                        stored_closures(&spread.argument, found);
                    }
                }
            }
        }
        Expression::ArrayExpression(array) => {
            for element in &array.elements {
                if let Some(element) = element.as_expression() {
                    stored_closures(element, found);
                }
            }
        }
        Expression::ConditionalExpression(conditional) => {
            stored_closures(&conditional.consequent, found);
            stored_closures(&conditional.alternate, found);
        }
        Expression::LogicalExpression(logical) => {
            stored_closures(&logical.left, found);
            stored_closures(&logical.right, found);
        }
        Expression::SequenceExpression(sequence) => {
            if let Some(last) = sequence.expressions.last() {
                stored_closures(last, found);
            }
        }
        Expression::AssignmentExpression(assignment) => stored_closures(&assignment.right, found),
        _ => {}
    }
}

fn arguments_closures(arguments: &[Argument<'_>]) -> Vec<Span> {
    let mut found = Vec::new();
    for argument in arguments {
        match argument {
            Argument::SpreadElement(spread) => stored_closures(&spread.argument, &mut found),
            other => stored_closures(other.to_expression(), &mut found),
        }
    }
    found
}

/// Whether control that enters `statements` always leaves the function through `return`
/// or `throw` before the end of the list.
fn always_returns(statements: &[Statement<'_>]) -> bool {
    for statement in statements {
        if returns(statement) {
            return true;
        }
        let jumps = escapes(statement);
        if jumps.brk || jumps.cont {
            return false;
        }
    }
    false
}

fn returns(statement: &Statement<'_>) -> bool {
    match statement {
        Statement::ReturnStatement(_) | Statement::ThrowStatement(_) => true,
        Statement::BlockStatement(block) => always_returns(&block.body),
        Statement::IfStatement(branch) => {
            returns(&branch.consequent) && branch.alternate.as_ref().is_some_and(returns)
        }
        _ => false,
    }
}

fn contains(outer: Span, inner: Span) -> bool {
    outer.start <= inner.start && inner.end <= outer.end
}

impl<'a> Visit<'a> for Collector<'_, '_> {
    fn visit_ts_type(&mut self, _ty: &TSType<'a>) {}

    fn visit_ts_type_annotation(&mut self, _annotation: &TSTypeAnnotation<'a>) {}

    fn visit_ts_type_parameter_declaration(&mut self, _it: &TSTypeParameterDeclaration<'a>) {}

    fn visit_ts_type_parameter_instantiation(&mut self, _it: &TSTypeParameterInstantiation<'a>) {}

    fn visit_statements(&mut self, statements: &oxc::allocator::Vec<'a, Statement<'a>>) {
        let end = statements
            .last()
            .map_or(0, |statement| statement.span().end);
        for (index, statement) in statements.iter().enumerate() {
            let tail = Tail {
                span: Span::new(statement.span().start, end),
                returns: always_returns(&statements[index..]),
            };
            if let Some(tails) = self.tails.last_mut() {
                tails.push(tail);
            }
            self.listed = Some(statement.span());
            self.visit_statement(statement);
            if let Some(tails) = self.tails.last_mut() {
                tails.pop();
            }
        }
    }

    fn visit_return_statement(&mut self, it: &ReturnStatement<'a>) {
        if let Some(tails) = self.tails.last_mut() {
            tails.push(Tail {
                span: it.span,
                returns: true,
            });
        }
        walk::walk_return_statement(self, it);
        if let Some(tails) = self.tails.last_mut() {
            tails.pop();
        }
    }

    fn visit_try_statement(&mut self, it: &oxc::ast::ast::TryStatement<'a>) {
        if let Some(tries) = self.tries.last_mut() {
            *tries += 1;
        }
        walk::walk_try_statement(self, it);
        if let Some(tries) = self.tries.last_mut() {
            *tries -= 1;
        }
    }

    fn visit_function_body(&mut self, body: &FunctionBody<'a>) {
        self.hoist(&body.statements);
        walk::walk_function_body(self, body);
    }

    fn visit_block_statement(&mut self, block: &BlockStatement<'a>) {
        // A block that is a statement of a list is part of that list (`flatten`).
        if self.listed != Some(block.span) {
            self.hoist(&block.body);
        }
        walk::walk_block_statement(self, block);
    }

    fn visit_switch_case(&mut self, case: &SwitchCase<'a>) {
        self.hoist(&case.consequent);
        walk::walk_switch_case(self, case);
    }

    fn visit_class(&mut self, class: &Class<'a>) {
        let mutating = mutating_methods(class, self.roots);
        let fields = self.field_changes(class);
        self.methods.push(mutating);
        self.fields.push(fields);
        walk::walk_class(self, class);
        self.fields.pop();
        self.methods.pop();
    }

    fn visit_method_definition(&mut self, method: &MethodDefinition<'a>) {
        self.method_next = true;
        walk::walk_method_definition(self, method);
    }

    fn visit_property_definition(&mut self, property: &PropertyDefinition<'a>) {
        let Some(value) = &property.value else {
            return;
        };
        let index = self.frames.len();
        self.enter(property.span, Some(index));
        // A closure in a field initializer keeps the `this` of that moment, so a later change
        // of `this` makes it stale.
        let changes = self
            .fields
            .last()
            .and_then(|fields| fields.get(&property.span))
            .copied()
            .unwrap_or(false);
        if changes {
            self.writes.push(Write {
                site: Site {
                    variable: Variable::This(index),
                    span: Span::new(u32::MAX, u32::MAX),
                    frame: index,
                },
                at: u32::MAX,
                stores: Vec::new(),
            });
        }
        self.visit_expression(value);
        self.leave();
    }

    fn visit_function(&mut self, function: &Function<'a>, flags: ScopeFlags) {
        if let Some(symbol) = function.id.as_ref().and_then(|id| id.symbol_id.get()) {
            let frame = self.frame();
            self.declared.entry(symbol).or_insert(frame);
        }
        let index = self.frames.len();
        let owner = std::mem::take(&mut self.method_next).then_some(index);
        self.enter(function.span, owner);
        walk::walk_function(self, function, flags);
        self.leave();
    }

    fn visit_arrow_function_expression(&mut self, arrow: &ArrowFunctionExpression<'a>) {
        let owner = self.frames[self.frame()].this_owner;
        self.enter(arrow.span, owner);
        walk::walk_arrow_function_expression(self, arrow);
        self.leave();
    }

    fn visit_for_statement(&mut self, it: &ForStatement<'a>) {
        self.in_loop(it.span, |collector| walk::walk_for_statement(collector, it));
    }

    fn visit_for_of_statement(&mut self, it: &ForOfStatement<'a>) {
        self.in_loop(it.span, |collector| {
            collector.head(&it.left);
            walk::walk_for_of_statement(collector, it);
            collector.writing.pop();
        });
    }

    fn visit_for_in_statement(&mut self, it: &ForInStatement<'a>) {
        self.in_loop(it.span, |collector| {
            collector.head(&it.left);
            walk::walk_for_in_statement(collector, it);
            collector.writing.pop();
        });
    }

    fn visit_while_statement(&mut self, it: &WhileStatement<'a>) {
        self.in_loop(it.span, |collector| {
            walk::walk_while_statement(collector, it);
        });
    }

    fn visit_do_while_statement(&mut self, it: &DoWhileStatement<'a>) {
        self.in_loop(it.span, |collector| {
            walk::walk_do_while_statement(collector, it);
        });
    }

    fn visit_binding_identifier(&mut self, id: &BindingIdentifier<'a>) {
        if let Some(symbol) = id.symbol_id.get() {
            let frame = self.frame();
            self.declared.entry(symbol).or_insert(frame);
        }
    }

    fn visit_identifier_reference(&mut self, ident: &IdentifierReference<'a>) {
        let Some(id) = ident.reference_id.get() else {
            return;
        };
        let reference = self.roots.scoping.get_reference(id);
        let Some(symbol) = reference.symbol_id() else {
            return;
        };
        if !reference.is_value() || reference.flags().is_value_as_type() {
            return;
        }
        let site = Site {
            variable: Variable::Symbol(symbol),
            span: ident.span,
            frame: self.frame(),
        };
        if reference.is_write() {
            let (at, stores) = self
                .writing
                .last()
                .cloned()
                .unwrap_or((ident.span.start, Vec::new()));
            self.writes.push(Write { site, at, stores });
        }
        if reference.is_read() {
            self.reads.push(site);
        }
    }

    fn visit_this_expression(&mut self, this: &ThisExpression) {
        if let Some(owner) = self.frames[self.frame()].this_owner {
            self.reads.push(Site {
                variable: Variable::This(owner),
                span: this.span,
                frame: self.frame(),
            });
        }
    }

    fn visit_assignment_expression(&mut self, it: &AssignmentExpression<'a>) {
        // The write takes effect after the right side runs, and stores what it holds.
        let mut stores = Vec::new();
        stored_closures(&it.right, &mut stores);
        for root in self.roots.assigned(&it.left) {
            self.write(root, it.left.span(), it.span.end, stores.clone());
        }
        self.writing.push((it.span.end, stores));
        walk::walk_assignment_expression(self, it);
        self.writing.pop();
    }

    fn visit_update_expression(&mut self, it: &UpdateExpression<'a>) {
        if let Some(member) = it.argument.as_member_expression()
            && let Some(root) = self.roots.place(member.object())
        {
            self.write(root, it.span, it.span.end, Vec::new());
        }
        self.writing.push((it.span.end, Vec::new()));
        walk::walk_update_expression(self, it);
        self.writing.pop();
    }

    fn visit_unary_expression(&mut self, it: &UnaryExpression<'a>) {
        if it.operator == UnaryOperator::Delete
            && let Some(member) = strip(&it.argument).as_member_expression()
            && let Some(root) = self.roots.place(member.object())
        {
            self.write(root, it.span, it.span.end, Vec::new());
        }
        walk::walk_unary_expression(self, it);
    }

    fn visit_call_expression(&mut self, it: &CallExpression<'a>) {
        if let Some(root) = self.roots.called(it, self.methods.last()) {
            // A mutator such as `push` or `set`, and `Object.assign`, stores its arguments.
            let stores = self.roots.assigned_object(it).is_some()
                || method_callee(&it.callee)
                    .is_some_and(|(_, name)| MUTATORS.contains(&name.as_str()));
            let stores = if stores {
                arguments_closures(&it.arguments)
            } else {
                Vec::new()
            };
            self.write(root, it.span, it.span.end, stores);
        }
        walk::walk_call_expression(self, it);
    }
}

impl Collector<'_, '_> {
    /// A `for...of` or `for...in` head writes its target on each iteration, before the body.
    fn head(&mut self, left: &ForStatementLeft<'_>) {
        let at = left.span().end;
        if let Some(target) = left.as_assignment_target() {
            for root in self.roots.assigned(target) {
                self.write(root, left.span(), at, Vec::new());
            }
        }
        self.writing.push((at, Vec::new()));
    }
}
