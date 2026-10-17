//! The `with` statement of sloppy code: a name that no declaration inside the statement
//! binds resolves through the object first (ECMA-262 §9.1.1.2, object environments).
//!
//! Each `with` statement binds its object to an Erlang variable and pushes it on the frame.
//! A read, a write, a call, `typeof`, or `delete` of such a name tests
//! `bouy_ref:with_has/2` on each object, innermost first, and falls back to the binding
//! that the name has without the `with`.

use oxc::ast::ast::{IdentifierReference, WithStatement};
use oxc::semantic::SymbolId;
use oxc::span::{GetSpan, Span};

use super::analyze::contains;
use super::context::{Cont, Lowerer, boolean_case};
use crate::erlang::{Clause, Expr};

/// A `with` statement around the code: the variable of its object and its span.
#[derive(Debug, Clone)]
pub struct WithScope {
    pub object: String,
    pub span: Span,
}

impl<'a> Lowerer<'a, '_> {
    pub fn with_statement(&mut self, statement: &'a WithStatement<'a>, k: &Cont<'a>) -> Vec<Expr> {
        let value = self.expr(&statement.object);
        let object = self.fresh("With");
        self.pre.push(Expr::matches(
            Expr::var(object.clone()),
            Expr::call("bouy_ref", "with_object", vec![value]),
        ));
        let mut code = std::mem::take(&mut self.pre);
        self.frame.withs.push(WithScope {
            object,
            span: statement.span,
        });
        code.extend(self.stmt(&statement.body, k));
        self.frame.withs.pop();
        code
    }

    /// The objects of the `with` statements that `ident` resolves through, innermost first:
    /// those around the reference that do not hold the declaration of its binding.
    pub fn with_objects(&self, ident: &IdentifierReference<'a>) -> Vec<String> {
        self.with_objects_for(self.symbol_of(ident.reference_id.get()))
    }

    /// The objects of the `with` statements that a name bound to `symbol` resolves through:
    /// those that do not hold the scope of the binding. A `var` belongs to its function, so
    /// a `with` inside the function holds its declaration but not its scope.
    pub fn with_objects_for(&self, symbol: Option<SymbolId>) -> Vec<String> {
        if self.frame.withs.is_empty() {
            return Vec::new();
        }
        let scoping = self.semantic.scoping();
        let bound = symbol.map(|symbol| {
            let scope = scoping.symbol_scope_id(symbol);
            self.semantic
                .nodes()
                .get_node(scoping.get_node_id(scope))
                .span()
        });
        let mut objects = Vec::new();
        for scope in self.frame.withs.iter().rev() {
            if bound.is_some_and(|bound| contains(scope.span, bound)) {
                break;
            }
            objects.push(scope.object.clone());
        }
        objects
    }

    /// `var name = value` inside a `with` statement: the name resolves through the objects
    /// first, and the value runs after.
    pub fn with_var_initializer(
        &mut self,
        name: &str,
        symbol: SymbolId,
        objects: &[String],
        init: &'a oxc::ast::ast::Expression<'a>,
    ) {
        let reference = self.with_resolve(objects, name);
        let value = self.named_expr(init, Some(Expr::js_string(name)));
        let value = self.bind(value);
        let fallback = self.branch(|me| {
            me.declare_symbol(symbol, value.clone());
            value.clone()
        });
        let object = self.fresh("O");
        let set = Expr::call(
            "bouy_ref",
            "sloppy_set",
            vec![Expr::var(object.clone()), Expr::js_string(name), value],
        );
        self.pre.push(Expr::case(
            reference,
            vec![
                Clause::new(Expr::tagged("with", Expr::var(object)), vec![set]),
                Clause::new(Expr::atom("none"), fallback),
            ],
        ));
    }

    /// The value of `found(Object)` for the innermost object that has `name`, else of
    /// `fallback`.
    pub fn through_withs(
        &mut self,
        objects: &[String],
        name: &str,
        mut found: impl FnMut(&mut Self, Expr) -> Vec<Expr>,
        fallback: Vec<Expr>,
    ) -> Expr {
        let mut otherwise = fallback;
        for object in objects.iter().rev() {
            let object = Expr::var(object.clone());
            let test = Expr::call(
                "bouy_ref",
                "with_has",
                vec![object.clone(), Expr::js_string(name)],
            );
            let yes = found(self, object);
            otherwise = vec![boolean_case(test, yes, otherwise)];
        }
        self.bind(super::context::block(otherwise))
    }

    /// A read of `ident` through the `with` objects.
    pub fn with_read(&mut self, ident: &'a IdentifierReference<'a>, objects: &[String]) -> Expr {
        let fallback = self.branch(|me| me.identifier_plain(ident));
        let name = ident.name.as_str();
        self.through_withs(
            objects,
            name,
            |_, object| {
                vec![Expr::call(
                    "bouy_ref",
                    "get",
                    vec![object, Expr::js_string(name)],
                )]
            },
            fallback,
        )
    }

    /// Resolves `ident` through the `with` objects before the value of a write runs: the
    /// term `{with, Object}` for the object that has the name, else `none`
    /// (ECMA-262 §13.15.2: the reference comes first).
    pub fn with_resolve(&mut self, objects: &[String], name: &str) -> Expr {
        self.through_withs(
            objects,
            name,
            |_, object| vec![Expr::tagged("with", object)],
            vec![Expr::atom("none")],
        )
    }

    /// A read through a reference from `with_resolve`.
    pub fn with_read_ref(&mut self, ident: &'a IdentifierReference<'a>, reference: &Expr) -> Expr {
        let fallback = self.branch(|me| me.identifier_plain(ident));
        let object = self.fresh("O");
        let get = Expr::call(
            "bouy_ref",
            "get",
            vec![
                Expr::var(object.clone()),
                Expr::js_string(ident.name.as_str()),
            ],
        );
        self.bind(Expr::case(
            reference.clone(),
            vec![
                Clause::new(Expr::tagged("with", Expr::var(object)), vec![get]),
                Clause::new(Expr::atom("none"), fallback),
            ],
        ))
    }

    /// A write of `value` through a reference from `with_resolve`.
    pub fn with_write_ref(
        &mut self,
        ident: &'a IdentifierReference<'a>,
        reference: &Expr,
        value: Expr,
    ) -> Expr {
        let value = self.bind(value);
        let fallback = self.branch(|me| me.assign_name_value(ident, value.clone()));
        let object = self.fresh("O");
        let set = Expr::call(
            "bouy_ref",
            "sloppy_set",
            vec![
                Expr::var(object.clone()),
                Expr::js_string(ident.name.as_str()),
                value.clone(),
            ],
        );
        self.bind(Expr::case(
            reference.clone(),
            vec![
                Clause::new(Expr::tagged("with", Expr::var(object)), vec![set]),
                Clause::new(Expr::atom("none"), fallback),
            ],
        ));
        value
    }

    /// The function and the `this` of a call of `ident` through the `with` objects: the
    /// object is the `this` of a function that it holds.
    pub fn with_callee(
        &mut self,
        ident: &'a IdentifierReference<'a>,
        objects: &[String],
    ) -> (Expr, Expr) {
        let fallback = self.branch(|me| {
            let function = me.identifier_plain(ident);
            Expr::Tuple(vec![function, Expr::undefined()])
        });
        let name = ident.name.as_str();
        let pair = self.through_withs(
            objects,
            name,
            |_, object| {
                let function = Expr::call(
                    "bouy_ref",
                    "get",
                    vec![object.clone(), Expr::js_string(name)],
                );
                vec![Expr::Tuple(vec![function, object])]
            },
            fallback,
        );
        let function = self.fresh("F");
        let this = self.fresh("This");
        self.pre.push(Expr::matches(
            Expr::Tuple(vec![Expr::var(function.clone()), Expr::var(this.clone())]),
            pair,
        ));
        (Expr::var(function), Expr::var(this))
    }
}
