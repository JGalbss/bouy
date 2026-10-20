//! The class whose instance an expression holds, as the TypeScript annotations of the
//! module say: the class of `this` in instance code, of `new C()`, of a parameter or a
//! variable annotated with a class, of a field or a method result annotated with one, and
//! of an element of an array of a class. The lowering uses it only to guess the slot of a
//! property (`layout`), and the runtime checks every guess, so an annotation that lies,
//! such as one behind an `as any`, costs speed and never changes behaviour.

use std::rc::Rc;

use oxc::ast::AstKind;
use oxc::ast::ast::{
    BindingPattern, Class, ClassElement, Expression, ForStatementLeft, MethodDefinitionKind,
    PropertyKey, TSType, TSTypeName,
};
use oxc::semantic::NodeId;
use oxc::span::GetSpan;

use super::context::Lowerer;
use super::layout::{declared_class, instance_layout};

/// An expression names a class through at most this many steps before the lowering
/// stops looking.
const MAX_STEPS: usize = 8;

impl<'a> Lowerer<'a, '_> {
    /// The position that the layout of the class of `object` expects `name` at, from 1.
    pub fn slot_position(&mut self, object: &'a Expression<'a>, name: &str) -> Option<i64> {
        let class = self.instance_class(object, 0)?;
        let layout = self.layout_of(class)?;
        let index = layout.iter().position(|known| known == name)?;
        i64::try_from(index + 1).ok()
    }

    /// Whether the annotations name the class of `object`, as for a slot read.
    pub fn is_class_instance(&self, object: &'a Expression<'a>) -> bool {
        self.instance_class(object, 0).is_some()
    }

    fn layout_of(&mut self, class: &'a Class<'a>) -> Option<Rc<[String]>> {
        let id = class.node_id.get();
        if let Some(known) = self.layouts.get(&id) {
            return known.clone();
        }
        let layout: Option<Rc<[String]>> = instance_layout(self.semantic, class).map(Into::into);
        self.layouts.insert(id, layout.clone());
        layout
    }

    fn instance_class(
        &self,
        expression: &'a Expression<'a>,
        steps: usize,
    ) -> Option<&'a Class<'a>> {
        if steps > MAX_STEPS {
            return None;
        }
        match expression {
            Expression::ThisExpression(_) => {
                let id = self.frame.class.as_ref()?.instance?;
                self.class_node(id)
            }
            Expression::ParenthesizedExpression(inner) => {
                self.instance_class(&inner.expression, steps + 1)
            }
            Expression::TSAsExpression(inner) => self.type_class(&inner.type_annotation, steps + 1),
            Expression::TSSatisfiesExpression(inner) => {
                self.instance_class(&inner.expression, steps + 1)
            }
            Expression::TSNonNullExpression(inner) => {
                self.instance_class(&inner.expression, steps + 1)
            }
            Expression::NewExpression(new) => declared_class(self.semantic, &new.callee),
            Expression::AssignmentExpression(assignment) => {
                self.instance_class(&assignment.right, steps + 1)
            }
            Expression::Identifier(ident) => {
                let scoping = self.semantic.scoping();
                let symbol = scoping
                    .get_reference(ident.reference_id.get()?)
                    .symbol_id()?;
                self.binding_class(scoping.symbol_declaration(symbol), steps + 1)
            }
            Expression::StaticMemberExpression(member) => {
                let owner = self.instance_class(&member.object, steps + 1)?;
                let field = self.field_type(owner, member.property.name.as_str(), 0)?;
                self.type_class(field, steps + 1)
            }
            Expression::ComputedMemberExpression(member) => {
                let array = self.annotation_of(&member.object, steps + 1)?;
                self.element_class(array, steps + 1)
            }
            Expression::CallExpression(call) => {
                let Expression::StaticMemberExpression(callee) = &call.callee else {
                    return None;
                };
                let owner = self.instance_class(&callee.object, steps + 1)?;
                let result = self.method_result(owner, callee.property.name.as_str(), 0)?;
                self.type_class(result, steps + 1)
            }
            _ => None,
        }
    }

    /// The type annotation of an expression that names a typed binding or field.
    fn annotation_of(
        &self,
        expression: &'a Expression<'a>,
        steps: usize,
    ) -> Option<&'a TSType<'a>> {
        if steps > MAX_STEPS {
            return None;
        }
        match expression {
            Expression::Identifier(ident) => {
                let scoping = self.semantic.scoping();
                let symbol = scoping
                    .get_reference(ident.reference_id.get()?)
                    .symbol_id()?;
                match self
                    .semantic
                    .nodes()
                    .kind(scoping.symbol_declaration(symbol))
                {
                    AstKind::FormalParameter(param) => {
                        Some(&param.type_annotation.as_ref()?.type_annotation)
                    }
                    AstKind::VariableDeclarator(declarator) => {
                        Some(&declarator.type_annotation.as_ref()?.type_annotation)
                    }
                    _ => None,
                }
            }
            Expression::StaticMemberExpression(member) => {
                let owner = self.instance_class(&member.object, steps + 1)?;
                self.field_type(owner, member.property.name.as_str(), 0)
            }
            _ => None,
        }
    }

    /// The class of the value of the binding that the node `id` declares.
    fn binding_class(&self, id: NodeId, steps: usize) -> Option<&'a Class<'a>> {
        match self.semantic.nodes().kind(id) {
            AstKind::FormalParameter(param) => {
                self.type_class(&param.type_annotation.as_ref()?.type_annotation, steps)
            }
            AstKind::VariableDeclarator(declarator)
                if matches!(declarator.id, BindingPattern::BindingIdentifier(_)) =>
            {
                match (&declarator.type_annotation, &declarator.init) {
                    (Some(annotation), _) => self.type_class(&annotation.type_annotation, steps),
                    // Without an annotation, TypeScript gives the variable the type of its
                    // initializer, and every later assignment must fit it.
                    (None, Some(init)) => self.instance_class(init, steps),
                    (None, None) => self.for_of_element(id, steps),
                }
            }
            _ => None,
        }
    }

    /// The class of the elements of the array that `for (const x of array)` walks, where
    /// the node `id` declares `x`.
    fn for_of_element(&self, id: NodeId, steps: usize) -> Option<&'a Class<'a>> {
        let nodes = self.semantic.nodes();
        let declaration = nodes.parent_id(id);
        let AstKind::ForOfStatement(statement) = nodes.parent_kind(declaration) else {
            return None;
        };
        let ForStatementLeft::VariableDeclaration(left) = &statement.left else {
            return None;
        };
        // A `var` declaration in the body of the loop has the loop as its parent too.
        if statement.r#await || left.span != nodes.kind(declaration).span() {
            return None;
        }
        let array = self.annotation_of(&statement.right, steps + 1)?;
        self.element_class(array, steps + 1)
    }

    /// The class of the instances of a type: a class of the module, alone or with
    /// `null` and `undefined`.
    fn type_class(&self, ty: &'a TSType<'a>, steps: usize) -> Option<&'a Class<'a>> {
        if steps > MAX_STEPS {
            return None;
        }
        match ty {
            TSType::TSTypeReference(reference) => {
                let TSTypeName::IdentifierReference(name) = &reference.type_name else {
                    return None;
                };
                let scoping = self.semantic.scoping();
                let symbol = scoping
                    .get_reference(name.reference_id.get()?)
                    .symbol_id()?;
                match self
                    .semantic
                    .nodes()
                    .kind(scoping.symbol_declaration(symbol))
                {
                    AstKind::Class(class) => Some(class),
                    _ => None,
                }
            }
            TSType::TSParenthesizedType(inner) => {
                self.type_class(&inner.type_annotation, steps + 1)
            }
            TSType::TSUnionType(union) => {
                let mut classes = union.types.iter().filter(|member| {
                    !matches!(
                        member,
                        TSType::TSNullKeyword(_) | TSType::TSUndefinedKeyword(_)
                    )
                });
                let only = classes.next()?;
                if classes.next().is_some() {
                    return None;
                }
                self.type_class(only, steps + 1)
            }
            _ => None,
        }
    }

    /// The class of the elements of an array type: `C[]`, `(C | null)[]`, or `Array<C>`.
    fn element_class(&self, ty: &'a TSType<'a>, steps: usize) -> Option<&'a Class<'a>> {
        match ty {
            TSType::TSArrayType(array) => self.type_class(&array.element_type, steps + 1),
            TSType::TSParenthesizedType(inner) => {
                self.element_class(&inner.type_annotation, steps + 1)
            }
            TSType::TSTypeReference(reference) => {
                let TSTypeName::IdentifierReference(name) = &reference.type_name else {
                    return None;
                };
                if name.name != "Array" && name.name != "ReadonlyArray" {
                    return None;
                }
                let arguments = reference.type_arguments.as_ref()?;
                self.type_class(arguments.params.first()?, steps + 1)
            }
            _ => None,
        }
    }

    /// The annotation of the instance field `name` of `class` or of a class it extends.
    fn field_type(&self, class: &'a Class<'a>, name: &str, depth: usize) -> Option<&'a TSType<'a>> {
        if depth > MAX_STEPS {
            return None;
        }
        for element in &class.body.body {
            match element {
                ClassElement::PropertyDefinition(field)
                    if !field.r#static && !field.computed && is_named(&field.key, name) =>
                {
                    return Some(&field.type_annotation.as_ref()?.type_annotation);
                }
                ClassElement::MethodDefinition(method)
                    if method.kind == MethodDefinitionKind::Constructor =>
                {
                    let property = method.value.params.items.iter().find(|param| {
                        (param.accessibility.is_some() || param.readonly)
                            && param
                                .pattern
                                .get_binding_identifier()
                                .is_some_and(|id| id.name == name)
                    });
                    if let Some(param) = property {
                        return Some(&param.type_annotation.as_ref()?.type_annotation);
                    }
                }
                _ => {}
            }
        }
        let parent = declared_class(self.semantic, &class.heritage.as_ref()?.expression)?;
        self.field_type(parent, name, depth + 1)
    }

    /// The result annotation of the instance method `name` of `class` or of a class it
    /// extends.
    fn method_result(
        &self,
        class: &'a Class<'a>,
        name: &str,
        depth: usize,
    ) -> Option<&'a TSType<'a>> {
        if depth > MAX_STEPS {
            return None;
        }
        for element in &class.body.body {
            if let ClassElement::MethodDefinition(method) = element
                && !method.r#static
                && method.kind == MethodDefinitionKind::Method
                && !method.computed
                && is_named(&method.key, name)
            {
                return Some(&method.value.return_type.as_ref()?.type_annotation);
            }
        }
        let parent = declared_class(self.semantic, &class.heritage.as_ref()?.expression)?;
        self.method_result(parent, name, depth + 1)
    }

    fn class_node(&self, id: NodeId) -> Option<&'a Class<'a>> {
        match self.semantic.nodes().kind(id) {
            AstKind::Class(class) => Some(class),
            _ => None,
        }
    }
}

fn is_named(key: &PropertyKey<'_>, name: &str) -> bool {
    !matches!(key, PropertyKey::PrivateIdentifier(_))
        && key.static_name().is_some_and(|known| known == name)
}
