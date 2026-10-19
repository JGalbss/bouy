//! The places of the source that stack traces name (contract section 17.4): the function
//! that each Erlang line runs in, the names of functions as V8 infers them, the sites of
//! calls, and the stack check at the entry of each function.
//!
//! A JavaScript call keeps the frame of its caller on the Erlang stack: the code passes
//! the result of the call to `'$r'/1`, so the call is never a tail call. The frames of the
//! Erlang stack are then the frames of the JavaScript stack, and a runaway recursion
//! grows the stack until `buoy_stack:check/1` throws a `RangeError`.

use oxc::ast::AstKind;
use oxc::ast::ast::{
    AssignmentTarget, Expression, MethodDefinitionKind, PropertyKey, PropertyKind,
    SimpleAssignmentTarget,
};
use oxc::semantic::NodeId;

use super::context::Lowerer;
use crate::erlang::{Clause, Expr, FunctionSite, Site};

/// The number of calls between two checks of the stack size: a power of two.
const CHECK_EVERY: i64 = 64;

impl Lowerer<'_, '_> {
    /// Starts a function whose node is `node` and whose source text starts at `start`:
    /// returns its index in the table of functions.
    pub fn enter_function(&mut self, node: NodeId, start: u32) -> u32 {
        let (name, kind, holder) = self.infer_name(node);
        let index = u32::try_from(self.functions.len()).unwrap_or(u32::MAX);
        self.functions.push(FunctionSite {
            name,
            start,
            kind,
            holder,
        });
        index
    }

    /// Starts the default constructor of the class whose node is `class`.
    pub fn enter_constructor(&mut self, class: NodeId, start: u32) -> u32 {
        let index = u32::try_from(self.functions.len()).unwrap_or(u32::MAX);
        self.functions.push(FunctionSite {
            name: self.class_name(class).unwrap_or_default(),
            start,
            kind: "constructor",
            holder: None,
        });
        index
    }

    /// The function of the top-level code of the module, the first of the table.
    pub fn top_function(&mut self) {
        if self.functions.is_empty() {
            self.functions.push(FunctionSite {
                name: String::new(),
                start: 0,
                kind: "top",
                holder: None,
            });
        }
    }

    /// `expr`, which runs at the place `offset` of the function being lowered.
    pub fn at(&self, offset: u32, expr: Expr) -> Expr {
        Expr::Site(
            Site {
                offset,
                function: self.frame.site,
            },
            Box::new(expr),
        )
    }

    /// Binds the result of the JavaScript call `call`, which runs at `offset`, so that the
    /// frame of the caller stays on the stack while the callee runs.
    pub fn bind_call(&mut self, offset: u32, call: Expr) -> Expr {
        let kept = Expr::local_call("$r", vec![call]);
        let site = self.at(offset, kept);
        self.bind(site)
    }

    /// Marks the code that the last step of the expression being lowered binds as
    /// running at `offset`, such as the read of a property, whose getter or whose
    /// `TypeError` names the place.
    pub fn mark_last(&mut self, offset: u32) {
        let site = Site {
            offset,
            function: self.frame.site,
        };
        if let Some(Expr::Match(_, value)) = self.pre.last_mut()
            && !matches!(**value, Expr::Site(..))
        {
            let inner = std::mem::replace(&mut **value, Expr::undefined());
            **value = Expr::Site(site, Box::new(inner));
        }
    }

    /// The check at the entry of a function: every 64th call reads the size of the stack,
    /// and `buoy_stack:check/1` throws a `RangeError` past the limit.
    pub fn stack_check(&mut self, offset: u32) -> Expr {
        let calls = self.fresh("Calls");
        let key = Expr::atom("$buoy_calls");
        let check = Expr::case(
            Expr::call("erlang", "get", vec![key.clone()]),
            vec![
                Clause::guarded(
                    Expr::var(calls.clone()),
                    vec![Expr::op(
                        "=/=",
                        Expr::op(
                            "band",
                            Expr::var(calls.clone()),
                            Expr::Integer(CHECK_EVERY - 1),
                        ),
                        Expr::Integer(0),
                    )],
                    vec![Expr::call(
                        "erlang",
                        "put",
                        vec![
                            key,
                            Expr::op("+", Expr::var(calls.clone()), Expr::Integer(1)),
                        ],
                    )],
                ),
                Clause::new(
                    Expr::var(calls.clone()),
                    vec![Expr::call("buoy_stack", "check", vec![Expr::var(calls)])],
                ),
            ],
        );
        self.at(offset, check)
    }

    /// The name, the kind, and the holder of the function whose node is `node`, from its
    /// own name or from where it stands, as V8 infers the name that a stack trace shows.
    fn infer_name(&self, node: NodeId) -> (String, &'static str, Option<String>) {
        let nodes = self.semantic.nodes();
        let own = match nodes.kind(node) {
            AstKind::Function(function) => function.id.as_ref().map(|id| id.name.to_string()),
            _ => None,
        };
        let parent = self.outer(node);
        match nodes.kind(parent) {
            AstKind::MethodDefinition(method) => {
                let class = self.class_name(nodes.parent_id(nodes.parent_id(parent)));
                let key = key_name(&method.key);
                match method.kind {
                    MethodDefinitionKind::Constructor => {
                        (class.unwrap_or_default(), "constructor", None)
                    }
                    MethodDefinitionKind::Get => (format!("get {key}"), "get", None),
                    MethodDefinitionKind::Set => (format!("set {key}"), "set", None),
                    MethodDefinitionKind::Method => (key, "method", class),
                }
            }
            AstKind::ObjectProperty(property) => {
                let key = key_name(&property.key);
                match property.kind {
                    PropertyKind::Get => (format!("get {key}"), "get", None),
                    PropertyKind::Set => (format!("set {key}"), "set", None),
                    PropertyKind::Init => (
                        own.unwrap_or(key),
                        "method",
                        Some("Object".to_owned()),
                    ),
                }
            }
            AstKind::PropertyDefinition(field) => {
                let class = self.class_name(nodes.parent_id(nodes.parent_id(parent)));
                (own.unwrap_or_else(|| key_name(&field.key)), "method", class)
            }
            _ if own.is_some() => (own.unwrap_or_default(), "function", None),
            _ if self.is_wrapper(node, parent) => (String::new(), "wrapper", self.wrapper_holder()),
            _ => (self.context_name(parent).unwrap_or_default(), "function", None),
        }
    }

    /// The node around `node`, past parentheses and TypeScript-only wrappers.
    fn outer(&self, node: NodeId) -> NodeId {
        let nodes = self.semantic.nodes();
        let mut parent = nodes.parent_id(node);
        while matches!(
            nodes.kind(parent),
            AstKind::ParenthesizedExpression(_)
                | AstKind::TSAsExpression(_)
                | AstKind::TSSatisfiesExpression(_)
                | AstKind::TSNonNullExpression(_)
                | AstKind::TSTypeAssertion(_)
        ) && parent != nodes.parent_id(parent)
        {
            parent = nodes.parent_id(parent);
        }
        parent
    }

    /// The name that an anonymous function or class takes from the node around it: a
    /// variable, the target of an assignment, a default export, or a parameter default.
    fn context_name(&self, parent: NodeId) -> Option<String> {
        match self.semantic.nodes().kind(parent) {
            AstKind::VariableDeclarator(declarator) => declarator
                .id
                .get_binding_identifier()
                .map(|id| id.name.to_string()),
            AstKind::AssignmentExpression(assignment) => target_name(&assignment.left),
            AstKind::AssignmentPattern(pattern) => pattern
                .left
                .get_binding_identifier()
                .map(|id| id.name.to_string()),
            AstKind::ExportDefaultDeclaration(_) => Some("default".to_owned()),
            _ => None,
        }
    }

    /// The name of the class whose body is `body`: its own, or the one it takes from where
    /// it stands.
    fn class_name(&self, class: NodeId) -> Option<String> {
        match self.semantic.nodes().kind(class) {
            AstKind::Class(node) => node
                .id
                .as_ref()
                .map(|id| id.name.to_string())
                .or_else(|| self.context_name(self.outer(class))),
            _ => None,
        }
    }

    /// Whether the function is the wrapper around the code of a `CommonJS` module or of a
    /// built-in module of Node: an anonymous function expression that is all of the code.
    fn is_wrapper(&self, node: NodeId, parent: NodeId) -> bool {
        let nodes = self.semantic.nodes();
        let wrapped = self.linking.unit().kind == super::graph::Kind::CommonJs
            || self.eval_context.code_column > 0;
        wrapped
            && matches!(nodes.kind(node), AstKind::Function(_))
            && matches!(nodes.kind(parent), AstKind::ExpressionStatement(_))
    }

    /// The object that the wrapper of a `CommonJS` module runs with as `this`: its
    /// `exports`, an Object. A built-in module of Node runs with no `this`.
    fn wrapper_holder(&self) -> Option<String> {
        (self.linking.unit().kind == super::graph::Kind::CommonJs).then(|| "Object".to_owned())
    }
}

/// The text of a property key in a stack trace: `#name` for a private name, the text of a
/// computed key in brackets.
fn key_name(key: &PropertyKey<'_>) -> String {
    match key {
        PropertyKey::PrivateIdentifier(id) => format!("#{}", id.name),
        _ => key.static_name().map_or_else(String::new, |name| name.to_string()),
    }
}

/// The name that an assignment gives an anonymous function: the target, as `a.b.c`, with
/// `prototype` left out, as V8 infers `Module._compile` from `Module.prototype._compile`.
fn target_name(target: &AssignmentTarget<'_>) -> Option<String> {
    let simple = target.as_simple_assignment_target()?;
    match simple {
        SimpleAssignmentTarget::AssignmentTargetIdentifier(id) => Some(id.name.to_string()),
        _ => {
            let member = simple.as_member_expression()?;
            let mut parts = vec![member.static_property_name()?.to_owned()];
            let mut object = member.object();
            loop {
                match object {
                    Expression::Identifier(id) => {
                        parts.push(id.name.to_string());
                        break;
                    }
                    Expression::ThisExpression(_) => break,
                    Expression::StaticMemberExpression(inner) => {
                        parts.push(inner.property.name.to_string());
                        object = &inner.object;
                    }
                    _ => return None,
                }
            }
            parts.retain(|part| part != "prototype");
            parts.reverse();
            Some(parts.join("."))
        }
    }
}
