//! The layout that the instances of a class are expected to have: their own keys in the
//! order the class adds them. The runtime gives an object whose keys are all plain data
//! properties a shape (`buoy_heap`), and the value of the key at position I of the shape
//! is in slot I of the record. Where the code reads or writes `this.k` in the class, the
//! lowering passes the expected position of `k` to `buoy_heap:get_slot/3` and
//! `set_slot/4`, which check the key at that position and fall back to `[[Get]]` and
//! `[[Set]]` when the guess is wrong.
//!
//! Bun: `JavaScriptCore` caches the structure and the offset of a property at each access
//! site and patches the machine code when the cache misses. BEAM code cannot change, so
//! the guess comes from the class body at compile time, and a check of the key replaces
//! the check of the structure, which also lets a subclass instance hit, since its shape
//! starts with the keys of its base class.

use oxc::ast::AstKind;
use oxc::ast::ast::{
    AssignmentExpression, AssignmentOperator, AssignmentTarget, BindingPattern, Class,
    ClassElement, Expression, MethodDefinitionKind, PropertyDefinitionType, PropertyKey, Statement,
};
use oxc::semantic::Semantic;

use super::member::index_of;

/// A class extends classes of the module at most this deep before the layout is unknown.
const MAX_DEPTH: usize = 16;

/// The own keys that the constructor of `class` gives an instance, in order: the keys of
/// its base class when the module declares it, the public fields, the parameter
/// properties, and the `this.k = v` statements of the constructor body. None when the
/// instances cannot keep a shape, such as with a private name, or when the base class
/// is not a class declaration of the module.
pub fn instance_layout<'a>(
    semantic: &'a Semantic<'a>,
    class: &'a Class<'a>,
) -> Option<Vec<String>> {
    layout(semantic, class, 0)
}

fn layout<'a>(
    semantic: &'a Semantic<'a>,
    class: &'a Class<'a>,
    depth: usize,
) -> Option<Vec<String>> {
    if depth > MAX_DEPTH || has_private_instance_member(class) {
        return None;
    }
    let keys = own_keys(semantic, class, depth)?;
    // A key past Latin-1 is a two-byte string, which no shape holds.
    keys.iter()
        .all(|key| key.chars().all(|c| u32::from(c) < 256))
        .then_some(keys)
}

fn own_keys<'a>(
    semantic: &'a Semantic<'a>,
    class: &'a Class<'a>,
    depth: usize,
) -> Option<Vec<String>> {
    let mut keys = match &class.heritage {
        None => Vec::new(),
        Some(heritage) => layout(
            semantic,
            declared_class(semantic, &heritage.expression)?,
            depth + 1,
        )?,
    };
    for element in &class.body.body {
        let ClassElement::PropertyDefinition(field) = element else {
            continue;
        };
        if field.r#static
            || field.declare
            || field.r#type == PropertyDefinitionType::TSAbstractPropertyDefinition
        {
            continue;
        }
        // A computed key takes a place that the code does not know.
        if field.computed || !push(&mut keys, &field.key) {
            return Some(keys);
        }
    }
    let Some(constructor) = class.body.body.iter().find_map(|element| match element {
        ClassElement::MethodDefinition(method)
            if method.kind == MethodDefinitionKind::Constructor =>
        {
            Some(method)
        }
        _ => None,
    }) else {
        return Some(keys);
    };
    if class.heritage.is_none() {
        for param in &constructor.value.params.items {
            if param.accessibility.is_none() && !param.readonly {
                continue;
            }
            // As `constructor_body`, which defines only a plain identifier.
            if let BindingPattern::BindingIdentifier(id) = &param.pattern {
                add(&mut keys, id.name.as_str());
            }
        }
    }
    if let Some(body) = &constructor.value.body {
        for statement in &body.statements {
            if let Some(name) = this_assignment(statement) {
                add(&mut keys, name);
            }
        }
    }
    Some(keys)
}

/// Whether the instances get a private field or method, which the runtime keeps out of
/// shapes.
fn has_private_instance_member(class: &Class<'_>) -> bool {
    class.body.body.iter().any(|element| match element {
        ClassElement::PropertyDefinition(field) => {
            !field.r#static && matches!(field.key, PropertyKey::PrivateIdentifier(_))
        }
        ClassElement::MethodDefinition(method) => {
            !method.r#static && matches!(method.key, PropertyKey::PrivateIdentifier(_))
        }
        ClassElement::AccessorProperty(_) => true,
        _ => false,
    })
}

/// Adds the static name of `key`: false when it has none or is an array index, which
/// the runtime keeps out of shapes.
fn push(keys: &mut Vec<String>, key: &PropertyKey<'_>) -> bool {
    let Some(name) = key.static_name() else {
        return false;
    };
    if index_of(&name).is_some() || matches!(key, PropertyKey::NumericLiteral(_)) {
        return false;
    }
    add(keys, &name);
    true
}

fn add(keys: &mut Vec<String>, name: &str) {
    if !keys.iter().any(|known| known == name) {
        keys.push(name.to_owned());
    }
}

/// The `k` of a statement `this.k = v;`.
fn this_assignment<'s>(statement: &'s Statement<'_>) -> Option<&'s str> {
    let Statement::ExpressionStatement(statement) = statement else {
        return None;
    };
    let Expression::AssignmentExpression(assignment) = &statement.expression else {
        return None;
    };
    this_member(assignment)
}

fn this_member<'s>(assignment: &'s AssignmentExpression<'_>) -> Option<&'s str> {
    if assignment.operator != AssignmentOperator::Assign {
        return None;
    }
    let AssignmentTarget::StaticMemberExpression(member) = &assignment.left else {
        return None;
    };
    if !matches!(member.object, Expression::ThisExpression(_)) {
        return None;
    }
    let name = member.property.name.as_str();
    index_of(name).is_none().then_some(name)
}

/// The class that `expression` names when it is the binding of a class declaration of
/// the module, or a class expression.
pub fn declared_class<'a>(
    semantic: &'a Semantic<'a>,
    expression: &'a Expression<'a>,
) -> Option<&'a Class<'a>> {
    match expression {
        Expression::ClassExpression(class) => Some(class),
        Expression::Identifier(ident) => {
            let scoping = semantic.scoping();
            let symbol = scoping
                .get_reference(ident.reference_id.get()?)
                .symbol_id()?;
            // A binding that code assigns may name another class by the time it runs.
            if scoping.symbol_is_mutated(symbol) {
                return None;
            }
            match semantic
                .nodes()
                .get_node(scoping.symbol_declaration(symbol))
                .kind()
            {
                AstKind::Class(class) => Some(class),
                _ => None,
            }
        }
        _ => None,
    }
}
