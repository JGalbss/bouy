//! Member expressions: property keys, `o.k`, `o[k]`, `o.#k`, optional chains, and the
//! property reads and writes of the runtime.

use oxc::ast::ast::{
    ChainElement, ChainExpression, ComputedMemberExpression, Expression, PrivateFieldExpression,
    PropertyKey, StaticMemberExpression,
};

use super::context::Lowerer;
use super::literal::number;
use crate::erlang::{CatchClause, Clause, Expr};

const CHAIN: &str = "$bouy_chain";

/// The key of a member expression: known at compile time, or a value to convert.
#[derive(Debug, Clone)]
pub enum MemberKey {
    Static(Expr),
    Dynamic(Expr),
}

impl<'a> Lowerer<'a, '_> {
    /// The key of a property definition: a compile-time key, or the converted value.
    pub fn property_key(&mut self, key: &'a PropertyKey<'a>, computed: bool) -> Expr {
        if let PropertyKey::PrivateIdentifier(private) = key {
            return self.private_key(private.name.as_str());
        }
        if !computed && let Some(name) = key.static_name() {
            return static_key(&name);
        }
        match key.as_expression() {
            Some(expression) => {
                let value = self.expr(expression);
                self.bind(Expr::call("bouy_ref", "to_property_key", vec![value]))
            }
            None => Expr::undefined(),
        }
    }

    pub fn private_key(&mut self, name: &str) -> Expr {
        let class = self
            .frame
            .class
            .as_ref()
            .map_or_else(String::new, |class| class.name.clone());
        Expr::Tuple(vec![
            Expr::atom("#"),
            Expr::js_string(&class),
            Expr::js_string(name),
        ])
    }

    pub fn chain(&mut self, chain: &'a ChainExpression<'a>) -> Expr {
        let code = self.branch(|me| match &chain.expression {
            ChainElement::CallExpression(call) => me.call(call),
            ChainElement::TSNonNullExpression(inner) => me.expr(&inner.expression),
            ChainElement::StaticMemberExpression(member) => me.static_member(member),
            ChainElement::ComputedMemberExpression(member) => me.computed_member(member),
            ChainElement::PrivateFieldExpression(member) => me.private_member(member),
        });
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
            return self.super_get(static_key(member.property.name.as_str()));
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
            let key = self.computed_key(&member.expression);
            let key = self.fix_key(key);
            let MemberKey::Static(key) = key else {
                return Expr::undefined();
            };
            return self.super_get(key);
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
        self.get(object, MemberKey::Static(key))
    }

    /// The object and the key of a member expression, lowered in order.
    pub fn member_parts(
        &mut self,
        member: &'a oxc::ast::ast::MemberExpression<'a>,
    ) -> (Expr, MemberKey) {
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
                MemberKey::Static(self.private_key(member.field.name.as_str()))
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
            MemberKey::Static(key) => MemberKey::Static(key),
            MemberKey::Dynamic(value) => {
                MemberKey::Static(self.bind(Expr::call("bouy_ref", "to_property_key", vec![value])))
            }
        }
    }

    pub fn get(&mut self, object: Expr, key: MemberKey) -> Expr {
        let value = match key {
            MemberKey::Static(key) => Expr::call("bouy_ref", "get", vec![object, key]),
            MemberKey::Dynamic(key) => Expr::call("bouy_ref", "get_computed", vec![object, key]),
        };
        self.bind(value)
    }

    /// `o[k] = v`. In sloppy code a failed write does nothing.
    pub fn set(&mut self, object: Expr, key: MemberKey, value: Expr) {
        let (fixed, computed) = if self.frame.sloppy {
            ("sloppy_set", "sloppy_set_computed")
        } else {
            ("set", "set_computed")
        };
        let call = match key {
            MemberKey::Static(key) => Expr::call("bouy_ref", fixed, vec![object, key, value]),
            MemberKey::Dynamic(key) => Expr::call("bouy_ref", computed, vec![object, key, value]),
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
