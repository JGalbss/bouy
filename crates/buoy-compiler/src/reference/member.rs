//! Member expressions: property keys, `o.k`, `o[k]`, `o.#k`, optional chains, and the
//! property reads and writes of the runtime.

use oxc::ast::ast::{
    ChainElement, ChainExpression, ComputedMemberExpression, Expression, PrivateFieldExpression,
    PropertyKey, StaticMemberExpression,
};

use super::context::Lowerer;
use super::literal::number;
use super::suspend::holds_marker;
use crate::erlang::{CatchClause, Clause, Expr};

const CHAIN: &str = "$buoy_chain";

/// The key of a member expression: known at compile time, a value to convert, or a
/// private name.
#[derive(Debug, Clone)]
pub enum MemberKey {
    Static(Expr),
    Dynamic(Expr),
    Private(Expr),
}

/// The object of a `super.k` member expression: the prototype of the home object, read
/// when the reference is made, and `this`. `get` and `set` look the key up there.
pub fn super_object(base: Expr, this: Expr) -> Expr {
    Expr::Tuple(vec![Expr::atom("$super"), base, this])
}

/// The base and `this` of a `super.k` object.
pub fn super_parts(object: &Expr) -> Option<(Expr, Expr)> {
    match object {
        Expr::Tuple(parts) if parts.len() == 3 && parts[0] == Expr::atom("$super") => {
            Some((parts[1].clone(), parts[2].clone()))
        }
        _ => None,
    }
}

impl<'a> Lowerer<'a, '_> {
    /// The key of a property definition: a compile-time key, or the converted value.
    pub fn property_key(&mut self, key: &'a PropertyKey<'a>, computed: bool) -> Expr {
        if let PropertyKey::PrivateIdentifier(private) = key {
            return self.private_key(private.name.as_str());
        }
        // A number key is the string of the number, which the runtime prints.
        if !computed
            && let PropertyKey::NumericLiteral(literal) = key
            && !matches!(number(literal.value), Expr::Integer(index) if index >= 0)
        {
            return self.bind(Expr::call(
                "buoy_ref",
                "to_property_key",
                vec![number(literal.value)],
            ));
        }
        if !computed && let Some(name) = key.static_name() {
            return static_key(&name);
        }
        match key.as_expression() {
            Some(expression) => {
                let value = self.expr(expression);
                self.bind(Expr::call("buoy_ref", "to_property_key", vec![value]))
            }
            None => Expr::undefined(),
        }
    }

    pub fn chain(&mut self, chain: &'a ChainExpression<'a>) -> Expr {
        let code = self.branch(|me| match &chain.expression {
            ChainElement::CallExpression(call) => me.call(call),
            ChainElement::TSNonNullExpression(inner) => me.expr(&inner.expression),
            ChainElement::StaticMemberExpression(member) => me.static_member(member),
            ChainElement::ComputedMemberExpression(member) => me.computed_member(member),
            ChainElement::PrivateFieldExpression(member) => me.private_member(member),
        });
        if code.iter().any(holds_marker) {
            // An `await` or a `yield` cannot split an Erlang `try`, so each guard of this
            // chain becomes a case whose last clause holds the rest of the chain.
            let mut code = nest_guards(code);
            let value = code.pop().unwrap_or_else(Expr::undefined);
            self.pre.extend(code);
            return self.bind(value);
        }
        self.bind(Expr::Try {
            body: code,
            catches: vec![CatchClause {
                class: Expr::atom("throw"),
                reason: Expr::atom(CHAIN),
                stack: "_".to_owned(),
                body: vec![Expr::undefined()],
            }],
            after: vec![],
        })
    }

    /// Ends the optional chain with `undefined` when `value` is null or undefined.
    pub fn chain_guard(&mut self, value: Expr) {
        let out = vec![Expr::call("erlang", "throw", vec![Expr::atom(CHAIN)])];
        self.pre.push(Expr::case(
            value,
            vec![
                Clause::new(Expr::undefined(), out.clone()),
                Clause::new(Expr::atom("null"), out),
                Clause::new(Expr::var("_"), vec![Expr::ok()]),
            ],
        ));
    }

    pub fn static_member(&mut self, member: &'a StaticMemberExpression<'a>) -> Expr {
        if let Expression::Super(_) = member.object {
            let object = self.super_reference();
            return self.get(
                object,
                MemberKey::Static(static_key(member.property.name.as_str())),
            );
        }
        let object = self.expr(&member.object);
        if member.optional {
            self.chain_guard(object.clone());
        }
        self.get(
            object,
            MemberKey::Static(static_key(member.property.name.as_str())),
        )
    }

    pub fn computed_member(&mut self, member: &'a ComputedMemberExpression<'a>) -> Expr {
        if let Expression::Super(_) = member.object {
            let this = self.this_expr();
            let this = self.bind(this);
            let key = self.computed_key(&member.expression);
            let object = self.super_base(this);
            return self.get(object, key);
        }
        let object = self.expr(&member.object);
        if member.optional {
            self.chain_guard(object.clone());
        }
        let key = self.computed_key(&member.expression);
        self.get(object, key)
    }

    pub fn private_member(&mut self, member: &'a PrivateFieldExpression<'a>) -> Expr {
        let object = self.expr(&member.object);
        if member.optional {
            self.chain_guard(object.clone());
        }
        let key = self.private_key(member.field.name.as_str());
        self.get(object, MemberKey::Private(key))
    }

    /// The object and the key of a member expression, lowered in order.
    pub fn member_parts(
        &mut self,
        member: &'a oxc::ast::ast::MemberExpression<'a>,
    ) -> (Expr, MemberKey) {
        if let Expression::Super(_) = member.object() {
            let this = self.this_expr();
            let this = self.bind(this);
            let key = self.member_key(member);
            return (self.super_base(this), key);
        }
        let object = self.expr(member.object());
        let object = self.bind(object);
        let key = self.member_key(member);
        (object, key)
    }

    pub fn member_key(&mut self, member: &'a oxc::ast::ast::MemberExpression<'a>) -> MemberKey {
        match member {
            oxc::ast::ast::MemberExpression::StaticMemberExpression(member) => {
                MemberKey::Static(static_key(member.property.name.as_str()))
            }
            oxc::ast::ast::MemberExpression::ComputedMemberExpression(member) => {
                self.computed_key(&member.expression)
            }
            oxc::ast::ast::MemberExpression::PrivateFieldExpression(member) => {
                MemberKey::Private(self.private_key(member.field.name.as_str()))
            }
        }
    }

    pub fn computed_key(&mut self, expression: &'a Expression<'a>) -> MemberKey {
        match expression {
            Expression::StringLiteral(literal) => {
                MemberKey::Static(static_key(literal.value.as_str()))
            }
            Expression::NumericLiteral(literal)
                if literal.value.fract() == 0.0
                    && literal.value >= 0.0
                    && literal.value < 4_294_967_295.0 =>
            {
                MemberKey::Static(number(literal.value))
            }
            other => MemberKey::Dynamic(self.expr(other)),
        }
    }

    /// A key that a compound operation uses twice: converted once.
    pub fn fix_key(&mut self, key: MemberKey) -> MemberKey {
        match key {
            MemberKey::Dynamic(value) => {
                MemberKey::Static(self.bind(Expr::call("buoy_ref", "to_property_key", vec![value])))
            }
            other => other,
        }
    }

    pub fn get(&mut self, object: Expr, key: MemberKey) -> Expr {
        if let Some((base, this)) = super_parts(&object) {
            let key = match key {
                MemberKey::Static(key) | MemberKey::Private(key) => key,
                MemberKey::Dynamic(value) => Expr::call("buoy_ref", "to_property_key", vec![value]),
            };
            return self.bind(Expr::call(
                "buoy_ref_class",
                "super_get",
                vec![base, key, this],
            ));
        }
        let value = match key {
            MemberKey::Static(key) => Expr::call("buoy_ref", "get", vec![object, key]),
            MemberKey::Dynamic(key) => Expr::call("buoy_ref", "get_computed", vec![object, key]),
            MemberKey::Private(key) => {
                Expr::call("buoy_ref_class", "private_get", vec![object, key])
            }
        };
        self.bind(value)
    }

    /// `o[k] = v`. In sloppy code a failed write does nothing.
    pub fn set(&mut self, object: Expr, key: MemberKey, value: Expr) {
        let (fixed, computed, sup) = if self.frame.sloppy {
            ("sloppy_set", "sloppy_set_computed", "sloppy_super_set")
        } else {
            ("set", "set_computed", "super_set")
        };
        if let Some((base, this)) = super_parts(&object) {
            let key = match key {
                MemberKey::Static(key) | MemberKey::Private(key) => key,
                MemberKey::Dynamic(value) => {
                    self.bind(Expr::call("buoy_ref", "to_property_key", vec![value]))
                }
            };
            self.pre.push(Expr::call(
                "buoy_ref_class",
                sup,
                vec![base, key, value, this],
            ));
            return;
        }
        let call = match key {
            MemberKey::Static(key) => Expr::call("buoy_ref", fixed, vec![object, key, value]),
            MemberKey::Dynamic(key) => Expr::call("buoy_ref", computed, vec![object, key, value]),
            MemberKey::Private(key) => {
                Expr::call("buoy_ref_class", "private_set", vec![object, key, value])
            }
        };
        self.pre.push(call);
    }
}

/// A property key known at compile time: an array index is an integer.
pub fn static_key(name: &str) -> Expr {
    match index_of(name) {
        Some(index) => Expr::Integer(index),
        None => Expr::js_string(name),
    }
}

pub fn index_of(name: &str) -> Option<i64> {
    if name.is_empty() || name.len() > 10 || !name.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if name.len() > 1 && name.starts_with('0') {
        return None;
    }
    name.parse::<i64>()
        .ok()
        .filter(|index| *index <= 4_294_967_294)
}

/// The code of an optional chain with each guard as a case: `undefined` for a nullish
/// value, else the rest of the chain.
fn nest_guards(mut code: Vec<Expr>) -> Vec<Expr> {
    let Some(index) = code.iter().position(is_guard) else {
        return code;
    };
    let rest = nest_guards(code.split_off(index + 1));
    let Some(Expr::Case(subject, _)) = code.pop() else {
        return code;
    };
    code.push(Expr::Case(
        subject,
        vec![
            Clause::new(Expr::undefined(), vec![Expr::undefined()]),
            Clause::new(Expr::atom("null"), vec![Expr::undefined()]),
            Clause::new(Expr::var("_"), rest),
        ],
    ));
    code
}

/// Whether the expression is the guard of `chain_guard`.
fn is_guard(expr: &Expr) -> bool {
    let throw = Expr::call("erlang", "throw", vec![Expr::atom(CHAIN)]);
    matches!(expr, Expr::Case(_, clauses) if clauses.first().is_some_and(|clause| clause.body == [throw.clone()]))
}
