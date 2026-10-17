//! Literals: numbers, template strings, array and object literals, and the intrinsic
//! objects they start from.

use oxc::ast::ast::{
    ArrayExpression, ArrayExpressionElement, Expression, ObjectExpression, ObjectPropertyKind,
    PropertyKind, TemplateLiteral,
};
use oxc::syntax::operator::UnaryOperator;

use super::context::Lowerer;
use super::member::index_of;
use crate::erlang::Expr;

const OBJECT_PROTO: &str = "Object.prototype";

impl<'a> Lowerer<'a, '_> {
    pub fn template(&mut self, template: &'a TemplateLiteral<'a>) -> Expr {
        let mut parts = Vec::new();
        for (index, quasi) in template.quasis.iter().enumerate() {
            if let Some(cooked) = &quasi.value.cooked
                && !cooked.is_empty()
            {
                parts.push(Expr::binary(cooked.as_str()));
            }
            if let Some(expression) = template.expressions.get(index) {
                parts.push(self.expr(expression));
            }
        }
        self.bind(Expr::call("bouy_ref", "template", vec![Expr::List(parts)]))
    }

    pub fn array(&mut self, array: &'a ArrayExpression<'a>) -> Expr {
        let spread = array
            .elements
            .iter()
            .any(|element| matches!(element, ArrayExpressionElement::SpreadElement(_)));
        if !spread {
            let items = array
                .elements
                .iter()
                .map(|element| match element.as_expression() {
                    Some(expression) => self.expr(expression),
                    None => Expr::undefined(),
                })
                .collect();
            return self.bind(Expr::call(
                "bouy_heap",
                "new_array",
                vec![Expr::List(items)],
            ));
        }
        let parts = array
            .elements
            .iter()
            .map(|element| match element {
                ArrayExpressionElement::SpreadElement(spread) => {
                    Expr::tagged("spread", self.expr(&spread.argument))
                }
                other => match other.as_expression() {
                    Some(expression) => Expr::tagged("item", self.expr(expression)),
                    None => Expr::tagged("item", Expr::undefined()),
                },
            })
            .collect();
        self.bind(Expr::call(
            "bouy_ref",
            "array_spread",
            vec![Expr::List(parts)],
        ))
    }

    pub fn object(&mut self, object: &'a ObjectExpression<'a>) -> Expr {
        let proto = intrinsic(OBJECT_PROTO);
        if let Some(keys) = literal_keys(object) {
            let mut entries = Vec::new();
            for (property, key) in object.properties.iter().zip(&keys) {
                if let ObjectPropertyKind::ObjectProperty(property) = property {
                    let value = if property.method {
                        self.method_value(&property.value)
                    } else {
                        self.expr(&property.value)
                    };
                    entries.push((Expr::binary(key.clone()), value));
                }
            }
            let order = keys
                .iter()
                .rev()
                .map(|key| Expr::binary(key.clone()))
                .collect();
            return self.bind(Expr::call(
                "bouy_heap",
                "literal",
                vec![proto, Expr::Map(entries), Expr::List(order)],
            ));
        }
        let target = self.bind(Expr::call("bouy_heap", "new_object", vec![proto]));
        for property in &object.properties {
            match property {
                ObjectPropertyKind::SpreadProperty(spread) => {
                    let source = self.expr(&spread.argument);
                    self.pre.push(Expr::call(
                        "bouy_ref",
                        "object_spread",
                        vec![target.clone(), source],
                    ));
                }
                ObjectPropertyKind::ObjectProperty(property) => {
                    let key = self.property_key(&property.key, property.computed);
                    let (function, value) = match property.kind {
                        PropertyKind::Init if property.method => {
                            ("define_field", self.method_value(&property.value))
                        }
                        PropertyKind::Init => ("define_field", self.expr(&property.value)),
                        PropertyKind::Get => ("literal_getter", self.method_value(&property.value)),
                        PropertyKind::Set => ("literal_setter", self.method_value(&property.value)),
                    };
                    self.pre.push(Expr::call(
                        "bouy_ref",
                        function,
                        vec![target.clone(), key, value],
                    ));
                }
            }
        }
        target
    }
}

/// `{'$o', Name}`: an intrinsic object.
pub fn intrinsic(name: &str) -> Expr {
    Expr::Tuple(vec![Expr::atom("$o"), Expr::atom(name)])
}

/// The keys of an object literal that `bouy_heap:literal/3` can build: every property a
/// plain `key: value` or method with a distinct string key that is not an array index.
pub fn literal_keys(object: &ObjectExpression<'_>) -> Option<Vec<String>> {
    let mut keys: Vec<String> = Vec::new();
    for property in &object.properties {
        let ObjectPropertyKind::ObjectProperty(property) = property else {
            return None;
        };
        if property.computed || property.kind != PropertyKind::Init {
            return None;
        }
        let name = property.key.static_name()?.into_owned();
        if index_of(&name).is_some() || keys.contains(&name) {
            return None;
        }
        keys.push(name);
    }
    Some(keys)
}

/// A JavaScript number: an Erlang integer when it is one exactly.
pub fn number(value: f64) -> Expr {
    if value.is_nan() {
        return Expr::atom("NaN");
    }
    if value.is_infinite() {
        return Expr::atom(if value > 0.0 { "Infinity" } else { "-Infinity" });
    }
    if value.fract() == 0.0
        && value.abs() < 9_007_199_254_740_992.0
        && !(value == 0.0 && value.is_sign_negative())
    {
        #[allow(clippy::cast_possible_truncation)]
        return Expr::Integer(value as i64);
    }
    Expr::Float(value)
}

/// The value of a module-level `const` initializer that can be inlined.
pub fn literal(expression: &Expression<'_>) -> Option<Expr> {
    match expression {
        Expression::NumericLiteral(literal) => Some(number(literal.value)),
        Expression::StringLiteral(literal) => Some(Expr::binary(literal.value.as_str())),
        Expression::BooleanLiteral(literal) => Some(Expr::atom(literal.value.to_string())),
        Expression::NullLiteral(_) => Some(Expr::atom("null")),
        Expression::UnaryExpression(unary) if unary.operator == UnaryOperator::UnaryNegation => {
            match &unary.argument {
                Expression::NumericLiteral(literal) => Some(number(-literal.value)),
                _ => None,
            }
        }
        Expression::TSAsExpression(inner) => literal(&inner.expression),
        _ => None,
    }
}
