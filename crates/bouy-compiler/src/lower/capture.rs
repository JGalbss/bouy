//! Section 10 checks that need the whole module: `BOUY202` (a module-level value changes
//! after initialization) and `BOUY205` (the closure capture rule).
//!
//! An Erlang fun copies the values it captures. So a closure must not rebind a variable of
//! an enclosing function, and must not read a variable that the enclosing function rebinds
//! after the closure is created or in a loop around it.

use std::collections::{HashMap, HashSet};

use oxc::ast::ast::{
    ArrowFunctionExpression, AssignmentExpression, BindingIdentifier, CallExpression, Class,
    DoWhileStatement, ForInStatement, ForOfStatement, ForStatement, Function, IdentifierReference,
    MethodDefinition, Program, PropertyDefinition, TSType, TSTypeAnnotation,
    TSTypeParameterDeclaration, TSTypeParameterInstantiation, ThisExpression, UnaryExpression,
    UpdateExpression, WhileStatement,
};
use oxc::ast_visit::{Visit, walk};
use oxc::semantic::{Semantic, SymbolId};
use oxc::span::{GetSpan, Span};
use oxc::syntax::operator::UnaryOperator;
use oxc::syntax::scope::ScopeFlags;

use super::ModuleContext;
use super::rebind::{Roots, strip};
use super::scope::Target;
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

pub fn check(
    program: &Program<'_>,
    semantic: &Semantic<'_>,
    context: &ModuleContext,
    roots: &Roots<'_>,
    reporter: &mut Reporter<'_>,
) {
    let mut collector = Collector {
        roots,
        frames: vec![Frame {
            span: program.span,
            parent: None,
            this_owner: None,
            loops: Vec::new(),
        }],
        stack: vec![0],
        loops: vec![Vec::new()],
        declared: HashMap::new(),
        reads: Vec::new(),
        writes: Vec::new(),
        methods: Vec::new(),
        method_next: false,
    };
    walk::walk_program(&mut collector, program);
    collector.report(semantic, context, reporter);
}

struct Collector<'c> {
    roots: &'c Roots<'c>,
    frames: Vec<Frame>,
    stack: Vec<usize>,
    /// The active loops of each frame on the stack.
    loops: Vec<Vec<Span>>,
    declared: HashMap<SymbolId, usize>,
    reads: Vec<Site>,
    writes: Vec<Site>,
    /// The methods that rebind `this` of each enclosing class.
    methods: Vec<HashSet<String>>,
    method_next: bool,
}

impl Collector<'_> {
    fn frame(&self) -> usize {
        self.stack.last().copied().unwrap_or(0)
    }

    fn enter(&mut self, span: Span, this_owner: Option<usize>) -> usize {
        let index = self.frames.len();
        let loops = self.loops.last().cloned().unwrap_or_default();
        self.frames.push(Frame {
            span,
            parent: Some(self.frame()),
            this_owner,
            loops,
        });
        self.stack.push(index);
        self.loops.push(Vec::new());
        index
    }

    fn leave(&mut self) {
        self.stack.pop();
        self.loops.pop();
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

    fn write(&mut self, target: Target, span: Span) {
        if let Some(variable) = self.variable(target) {
            let frame = self.frame();
            self.writes.push(Site {
                variable,
                span,
                frame,
            });
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
            let creation = self.frames[closure].span;
            let later = self.writes.iter().find(|write| {
                write.variable == site.variable
                    && write.frame == declaring
                    && (write.span.start >= creation.end
                        || self.frames[closure].loops.iter().any(|around| {
                            contains(*around, write.span) && !contains(*around, declared)
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
}

fn contains(outer: Span, inner: Span) -> bool {
    outer.start <= inner.start && inner.end <= outer.end
}

impl<'a> Visit<'a> for Collector<'_> {
    fn visit_ts_type(&mut self, _ty: &TSType<'a>) {}

    fn visit_ts_type_annotation(&mut self, _annotation: &TSTypeAnnotation<'a>) {}

    fn visit_ts_type_parameter_declaration(&mut self, _it: &TSTypeParameterDeclaration<'a>) {}

    fn visit_ts_type_parameter_instantiation(&mut self, _it: &TSTypeParameterInstantiation<'a>) {}

    fn visit_class(&mut self, class: &Class<'a>) {
        let mutating = super::class::mutating_methods(class, self.roots);
        self.methods.push(mutating);
        walk::walk_class(self, class);
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
            walk::walk_for_of_statement(collector, it);
        });
    }

    fn visit_for_in_statement(&mut self, it: &ForInStatement<'a>) {
        self.in_loop(it.span, |collector| {
            walk::walk_for_in_statement(collector, it);
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
            self.writes.push(site);
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
        for root in self.roots.assigned(&it.left) {
            self.write(root, it.left.span());
        }
        walk::walk_assignment_expression(self, it);
    }

    fn visit_update_expression(&mut self, it: &UpdateExpression<'a>) {
        if let Some(member) = it.argument.as_member_expression()
            && let Some(root) = self.roots.place(member.object())
        {
            self.write(root, it.span);
        }
        walk::walk_update_expression(self, it);
    }

    fn visit_unary_expression(&mut self, it: &UnaryExpression<'a>) {
        if it.operator == UnaryOperator::Delete
            && let Some(member) = strip(&it.argument).as_member_expression()
            && let Some(root) = self.roots.place(member.object())
        {
            self.write(root, it.span);
        }
        walk::walk_unary_expression(self, it);
    }

    fn visit_call_expression(&mut self, it: &CallExpression<'a>) {
        if let Some(root) = self.roots.called(it, self.methods.last()) {
            self.write(root, it.span);
        }
        walk::walk_call_expression(self, it);
    }
}
