//! Literals: numbers, template strings, array and object literals, and the intrinsic
//! objects they start from.

use oxc::ast::ast::{
    ArrayExpression, ArrayExpressionElement, Expression, ObjectExpression, ObjectPropertyKind,
    PropertyKey, PropertyKind, Super, TemplateLiteral,
};
use oxc::ast_visit::Visit;
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
                parts.push(js_string_literal(cooked.as_str(), quasi.lone_surrogates));
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
                        self.method_value(&property.value, Expr::js_string(key), "method", None)
                    } else {
                        self.named_expr(&property.value, Expr::js_string(key))
                    };
                    entries.push((Expr::js_string(key), value));
                }
            }
            let order = keys.iter().rev().map(|key| Expr::js_string(key)).collect();
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
                    let home = match &target {
                        Expr::Var(name) => Some(name.clone()),
                        _ => None,
                    };
                    let (function, value) = match property.kind {
                        PropertyKind::Init if property.method => (
                            "define_field",
                            self.method_value(&property.value, key.clone(), "method", home),
                        ),
                        PropertyKind::Init
                            if !property.shorthand
                                && !property.computed
                                && property.key.static_name().as_deref() == Some("__proto__") =>
                        {
                            ("set_literal_proto", self.expr(&property.value))
                        }
                        PropertyKind::Init if property.shorthand => {
                            ("define_field", self.expr(&property.value))
                        }
                        PropertyKind::Init => (
                            "define_field",
                            self.named_expr(&property.value, key.clone()),
                        ),
                        PropertyKind::Get => (
                            "literal_getter",
                            self.method_value(&property.value, key.clone(), "get", home),
                        ),
                        PropertyKind::Set => (
                            "literal_setter",
                            self.method_value(&property.value, key.clone(), "set", home),
                        ),
                    };
                    let module = if function == "set_literal_proto" {
                        "bouy_ref_class"
                    } else {
                        "bouy_ref"
                    };
                    self.pre.push(Expr::call(
                        module,
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
        // A method that uses `super` needs the object as its home before it exists.
        if property.method && uses_super(&property.value) {
            return None;
        }
        if let PropertyKey::NumericLiteral(literal) = &property.key
            && literal.value.fract() != 0.0
        {
            return None;
        }
        let name = property.key.static_name()?.into_owned();
        if index_of(&name).is_some() || keys.contains(&name) || name == "__proto__" {
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

/// The JavaScript string of a literal. With lone surrogates, oxc writes each one as U+FFFD
/// and the four hex digits of the code unit, and U+FFFD itself as U+FFFD `fffd`.
pub fn js_string_literal(value: &str, lone_surrogates: bool) -> Expr {
    if !lone_surrogates {
        return Expr::js_string(value);
    }
    let mut units = Vec::new();
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c == '\u{FFFD}' {
            let hex: String = chars.by_ref().take(4).collect();
            units.push(u16::from_str_radix(&hex, 16).unwrap_or(0xFFFD));
            continue;
        }
        let mut buffer = [0; 2];
        units.extend_from_slice(c.encode_utf16(&mut buffer));
    }
    Expr::JsString(units)
}

/// The value of a module-level `const` initializer that can be inlined.
pub fn literal(expression: &Expression<'_>) -> Option<Expr> {
    match expression {
        Expression::NumericLiteral(literal) => Some(number(literal.value)),
        Expression::StringLiteral(literal) => Some(js_string_literal(
            literal.value.as_str(),
            literal.lone_surrogates,
        )),
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

/// Whether a method uses `super`, in its own code or in an arrow function inside it.
fn uses_super(value: &Expression<'_>) -> bool {
    struct Finder(bool);
    impl Visit<'_> for Finder {
        fn visit_super(&mut self, _it: &Super) {
            self.0 = true;
        }
    }
    let Expression::FunctionExpression(function) = value else {
        return false;
    };
    let mut finder = Finder(false);
    if let Some(body) = &function.body {
        finder.visit_function_body(body);
    }
    finder.visit_formal_parameters(&function.params);
    finder.0
}
