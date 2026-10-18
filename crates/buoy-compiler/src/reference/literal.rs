//! Literals: numbers, template strings, array and object literals, and the intrinsic
//! objects they start from.

use oxc::ast::ast::{
    ArrayExpression, ArrayExpressionElement, Expression, ObjectExpression, ObjectPropertyKind,
    PropertyKey, PropertyKind, RegExpLiteral, Super, TaggedTemplateExpression, TemplateLiteral,
};
use oxc::ast_visit::Visit;
use oxc::syntax::operator::UnaryOperator;

use super::context::Lowerer;
use super::expr::strip;
use super::member::index_of;
use crate::erlang::Expr;

const OBJECT_PROTO: &str = "Object.prototype";

/// The items of an array literal that one list of the generated code holds.
const ARRAY_CHUNK: usize = 256;

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
        self.bind(Expr::call("buoy_ref", "template", vec![Expr::List(parts)]))
    }

    /// A tagged template: the tag gets the template object of the site, which every
    /// evaluation of the site shares, and the substitutions.
    pub fn tagged_template(&mut self, tagged: &'a TaggedTemplateExpression<'a>) -> Expr {
        let quasis = &tagged.quasi.quasis;
        let cooked = quasis
            .iter()
            .map(|quasi| match &quasi.value.cooked {
                Some(cooked) => js_string_literal(cooked.as_str(), quasi.lone_surrogates),
                None => Expr::undefined(),
            })
            .collect();
        let raw = quasis
            .iter()
            .map(|quasi| {
                Expr::js_string(
                    &quasi
                        .value
                        .raw
                        .as_str()
                        .replace("\r\n", "\n")
                        .replace('\r', "\n"),
                )
            })
            .collect();
        let site = Expr::Tuple(vec![
            Expr::atom(self.module.clone()),
            Expr::Integer(i64::from(tagged.quasi.span.start)),
        ]);
        let callee = strip(&tagged.tag);
        let member = callee
            .as_member_expression()
            .filter(|member| !matches!(member.object(), Expression::Super(_)));
        let (function, this) = match member {
            Some(member) => {
                let (object, key) = self.member_parts(member);
                (self.get(object.clone(), key), object)
            }
            None => (self.expr(callee), Expr::undefined()),
        };
        let function = self.bind(function);
        let template = self.bind(Expr::call(
            "buoy_ref",
            "template_object",
            vec![site, Expr::List(cooked), Expr::List(raw)],
        ));
        let mut args = vec![template];
        for expression in &tagged.quasi.expressions {
            let value = self.expr(expression);
            args.push(self.bind(value));
        }
        self.bind(Expr::call(
            "buoy_ref",
            "call",
            vec![function, this, Expr::List(args)],
        ))
    }

    /// A regular expression literal: a new `RegExp` each evaluation. The parser has checked
    /// the pattern for early errors.
    pub fn regexp(&mut self, literal: &'a RegExpLiteral<'a>) -> Expr {
        let flags = literal.regex.flags.to_inline_string();
        self.bind(Expr::call(
            "buoy_ref_regexp",
            "literal",
            vec![
                Expr::js_string(literal.regex.pattern.text.as_str()),
                Expr::js_string(flags.as_str()),
            ],
        ))
    }

    pub fn array(&mut self, array: &'a ArrayExpression<'a>) -> Expr {
        let spread = array
            .elements
            .iter()
            .any(|element| matches!(element, ArrayExpressionElement::SpreadElement(_)));
        let holes = array
            .elements
            .iter()
            .any(|element| matches!(element, ArrayExpressionElement::Elision(_)));
        if !spread {
            // A long literal builds its list in chunks, each bound to a variable, so the
            // values of one chunk stay live at a time: BEAM has 1024 registers.
            let mut chunks = Vec::new();
            let mut items = Vec::new();
            for element in &array.elements {
                items.push(match element.as_expression() {
                    Some(expression) => self.expr(expression),
                    None => Expr::atom("$hole"),
                });
                if items.len() == ARRAY_CHUNK {
                    // A remote call, which the Erlang compiler does not move.
                    let chunk = Expr::call(
                        "buoy_ref",
                        "chunk",
                        vec![Expr::List(std::mem::take(&mut items))],
                    );
                    chunks.push(self.bind(chunk));
                }
            }
            let list = if chunks.is_empty() {
                Expr::List(items)
            } else {
                chunks.push(Expr::List(items));
                Expr::call("lists", "append", vec![Expr::List(chunks)])
            };
            let (module, function) = if holes {
                ("buoy_ref", "array_holes")
            } else {
                ("buoy_heap", "new_array")
            };
            return self.bind(Expr::call(module, function, vec![list]));
        }
        let parts = array
            .elements
            .iter()
            .map(|element| match element {
                ArrayExpressionElement::SpreadElement(spread) => {
                    Expr::tagged("spread", self.expr(&spread.argument))
                }
                ArrayExpressionElement::Elision(_) => Expr::atom("hole"),
                other => match other.as_expression() {
                    Some(expression) => Expr::tagged("item", self.expr(expression)),
                    None => Expr::atom("hole"),
                },
            })
            .collect();
        self.bind(Expr::call(
            "buoy_ref",
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
                    let name = Expr::js_string(key);
                    let value = if property.method {
                        self.method_value(&property.value, name, "method", None, property.span)
                    } else {
                        self.named_expr(&property.value, Some(name))
                    };
                    entries.push((Expr::js_string(key), value));
                }
            }
            let order = keys.iter().rev().map(|key| Expr::js_string(key)).collect();
            return self.bind(Expr::call(
                "buoy_heap",
                "literal",
                vec![proto, Expr::Map(entries), Expr::List(order)],
            ));
        }
        let target = self.bind(Expr::call("buoy_heap", "new_object", vec![proto]));
        for property in &object.properties {
            match property {
                ObjectPropertyKind::SpreadProperty(spread) => {
                    let source = self.expr(&spread.argument);
                    self.pre.push(Expr::call(
                        "buoy_ref",
                        "object_spread",
                        vec![target.clone(), source],
                    ));
                }
                ObjectPropertyKind::ObjectProperty(property) if is_proto_setter(property) => {
                    let value = self.expr(&property.value);
                    self.pre.push(Expr::call(
                        "buoy_ref",
                        "literal_proto",
                        vec![target.clone(), value],
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
                            self.method_value(
                                &property.value,
                                key.clone(),
                                "method",
                                home,
                                property.span,
                            ),
                        ),
                        PropertyKind::Init => (
                            "define_field",
                            self.named_expr(&property.value, Some(key.clone())),
                        ),
                        PropertyKind::Get => (
                            "literal_getter",
                            self.method_value(
                                &property.value,
                                key.clone(),
                                "get",
                                home,
                                property.span,
                            ),
                        ),
                        PropertyKind::Set => (
                            "literal_setter",
                            self.method_value(
                                &property.value,
                                key.clone(),
                                "set",
                                home,
                                property.span,
                            ),
                        ),
                    };
                    self.pre.push(Expr::call(
                        "buoy_ref",
                        function,
                        vec![target.clone(), key, value],
                    ));
                }
            }
        }
        target
    }
}

/// `__proto__: value` in an object literal sets the prototype (ECMA-262 §13.2.5.5).
fn is_proto_setter(property: &oxc::ast::ast::ObjectProperty<'_>) -> bool {
    !property.computed
        && !property.shorthand
        && !property.method
        && property.kind == PropertyKind::Init
        && property
            .key
            .static_name()
            .is_some_and(|name| name == "__proto__")
}

/// `{'$o', Name}`: an intrinsic object.
pub fn intrinsic(name: &str) -> Expr {
    Expr::Tuple(vec![Expr::atom("$o"), Expr::atom(name)])
}

/// The keys of an object literal that `buoy_heap:literal/3` can build: every property a
/// plain `key: value` or method with a distinct string key that is not an array index.
pub fn literal_keys(object: &ObjectExpression<'_>) -> Option<Vec<String>> {
    let mut keys: Vec<String> = Vec::new();
    for property in &object.properties {
        let ObjectPropertyKind::ObjectProperty(property) = property else {
            return None;
        };
        if property.computed || property.kind != PropertyKind::Init || is_proto_setter(property) {
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

/// A `BigInt` literal from its base-10 digits: `{'$bigint', Integer}`.
pub fn bigint(digits: &str) -> Expr {
    let value = match digits.parse::<i64>() {
        Ok(value) => Expr::Integer(value),
        Err(_) => Expr::call("erlang", "binary_to_integer", vec![Expr::binary(digits)]),
    };
    Expr::Tuple(vec![Expr::atom("$bigint"), value])
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

/// Whether a method uses `super`, in its own code or in an arrow function inside it, or
/// may through a direct eval.
fn uses_super(value: &Expression<'_>) -> bool {
    struct Finder(bool);
    impl<'a> Visit<'a> for Finder {
        fn visit_super(&mut self, _it: &Super) {
            self.0 = true;
        }
        fn visit_identifier_reference(&mut self, it: &oxc::ast::ast::IdentifierReference<'a>) {
            if it.name == "eval" {
                self.0 = true;
            }
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
