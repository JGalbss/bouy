//! One island: the entry function, everything its code reaches, and the classes, methods,
//! and globals that code uses, lowered to one program of the IR.
//!
//! The types here are those of the checker, which knows interfaces and the classes of
//! the source; the IR keeps only what the machine code needs.

use std::collections::{BTreeSet, HashMap, HashSet};

use buoy_jit_ir as ir;
use oxc::ast::AstKind;
use oxc::ast::ast::{
    BindingPattern, Class, ClassElement, Expression, FormalParameters, Function,
    MethodDefinitionKind, PropertyKey, Statement, TSSignature, TSType, TSTypeAnnotation,
    TSTypeName, TSTypeOperatorOperator,
};
use oxc::semantic::{Semantic, SymbolId};

use super::body::Body;

/// Why code is not part of an island. The text names the construct, for tests and for
/// `BUOY_JIT_TRACE`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reject(pub String);

pub type Checked<T> = Result<T, Reject>;

pub fn reject<T>(why: impl Into<String>) -> Checked<T> {
    Err(Reject(why.into()))
}

/// The type of a value to the checker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum T {
    Void,
    Num,
    Bool,
    /// `null` or `undefined`.
    Null,
    Class(ir::ClassId),
    /// An interface, whose values are instances of island classes.
    Iface(usize),
    Array(Box<T>),
}

impl T {
    pub fn ir(&self) -> ir::Ty {
        match self {
            Self::Void => ir::Ty::Void,
            Self::Num => ir::Ty::Num,
            Self::Bool => ir::Ty::Bool,
            Self::Null => ir::Ty::Null,
            Self::Class(class) => ir::Ty::Object(*class),
            Self::Iface(_) => ir::Ty::Any,
            Self::Array(element) => ir::Ty::Array(Box::new(element.ir())),
        }
    }

    pub fn is_reference(&self) -> bool {
        matches!(
            self,
            Self::Null | Self::Class(_) | Self::Iface(_) | Self::Array(_)
        )
    }
}

/// A method or function signature.
#[derive(Debug, Clone)]
pub struct Signature {
    pub params: Vec<T>,
    /// The literal default of each parameter that has one.
    pub defaults: Vec<Option<ir::Expr>>,
    pub result: T,
}

/// A class of the source that the island uses.
pub struct ClassInfo<'a> {
    pub name: String,
    pub node: &'a Class<'a>,
    pub parent: Option<ir::ClassId>,
    /// The layout: the fields of the parent first.
    pub fields: Vec<(String, T)>,
    /// The fields that the class declares, with their initializers.
    pub own: Vec<(String, T, Option<&'a Expression<'a>>)>,
    pub constructor: Option<ir::FuncId>,
    /// The methods that a dispatch finds, by name.
    pub methods: HashMap<String, ir::FuncId>,
}

pub struct IfaceInfo {
    pub methods: HashMap<String, Signature>,
}

/// What a function is, which decides how its body compiles.
#[derive(Debug, Clone, Copy)]
pub enum Owner<'a> {
    /// A function declaration.
    Plain,
    /// A method of the class: its `this` is the first parameter.
    Method(ir::ClassId),
    /// A static method of a class.
    Static,
    /// The constructor of the class, or its default constructor when `None`.
    Constructor(ir::ClassId, Option<&'a Function<'a>>),
}

/// A function whose body waits to compile.
pub struct Job<'a> {
    pub id: ir::FuncId,
    pub function: Option<&'a Function<'a>>,
    pub owner: Owner<'a>,
    pub signature: Signature,
}

pub struct Island<'a, 's> {
    pub semantic: &'s Semantic<'a>,
    pub classes: Vec<ClassInfo<'a>>,
    class_ids: HashMap<SymbolId, ir::ClassId>,
    pub ifaces: Vec<IfaceInfo>,
    iface_ids: HashMap<SymbolId, usize>,
    pub functions: Vec<Option<ir::Function>>,
    function_ids: HashMap<SymbolId, ir::FuncId>,
    method_ids: HashMap<(ir::ClassId, String, bool), ir::FuncId>,
    pub signatures: Vec<Signature>,
    jobs: Vec<Job<'a>>,
    /// The variables outside the island that its code reads, in the order of the IR.
    pub globals: Vec<(SymbolId, T)>,
    /// The method names that a dispatch calls.
    pub dispatched: BTreeSet<String>,
    pub uses_math: bool,
    /// The classes whose constructors let `this` escape: to a call, a variable, or a
    /// result.
    pub escaping: HashSet<ir::ClassId>,
}

impl<'a, 's> Island<'a, 's> {
    pub fn new(semantic: &'s Semantic<'a>) -> Self {
        Self {
            semantic,
            classes: Vec::new(),
            class_ids: HashMap::new(),
            ifaces: Vec::new(),
            iface_ids: HashMap::new(),
            functions: Vec::new(),
            function_ids: HashMap::new(),
            method_ids: HashMap::new(),
            signatures: Vec::new(),
            jobs: Vec::new(),
            globals: Vec::new(),
            dispatched: BTreeSet::new(),
            uses_math: false,
            escaping: HashSet::new(),
        }
    }

    /// Compiles the island of the entry `function`, whose symbol is `symbol`.
    pub fn compile(mut self, symbol: SymbolId, function: &'a Function<'a>) -> Checked<Built> {
        let entry = self.function(symbol, function)?;
        let signature = &self.signatures[entry as usize];
        let primitive = |ty: &T| matches!(ty, T::Num | T::Bool);
        if !signature.params.iter().all(primitive)
            || !matches!(signature.result, T::Num | T::Bool | T::Void)
        {
            return reject("an entry takes and returns numbers and booleans");
        }
        self.drain()?;
        self.check_escapes()?;
        let mut classes = Vec::with_capacity(self.classes.len());
        for class in &self.classes {
            let mut methods: Vec<ir::Method> = class
                .methods
                .iter()
                .map(|(name, function)| ir::Method {
                    name: name.clone(),
                    function: *function,
                })
                .collect();
            methods.sort_by(|a, b| a.name.cmp(&b.name));
            classes.push(ir::Class {
                name: class.name.clone(),
                parent: class.parent,
                fields: class.fields.iter().map(|(_, ty)| ty.ir()).collect(),
                methods,
            });
        }
        let functions = self
            .functions
            .into_iter()
            .map(|function| function.ok_or_else(|| Reject("a function did not compile".into())))
            .collect::<Checked<Vec<_>>>()?;
        let class_symbols = self.class_ids.into_keys().collect();
        Ok(Built {
            program: ir::Program {
                classes,
                functions,
                entries: vec![entry],
                globals: self.globals.iter().map(|(_, ty)| ty.ir()).collect(),
            },
            globals: self.globals.into_iter().map(|(symbol, _)| symbol).collect(),
            classes: class_symbols,
            uses_math: self.uses_math,
        })
    }

    /// Compiles every waiting body, and every method that a dispatch can reach, until
    /// nothing waits.
    fn drain(&mut self) -> Checked<()> {
        loop {
            while let Some(job) = self.jobs.pop() {
                let function = Body::compile(self, &job)?;
                self.functions[job.id as usize] = Some(function);
            }
            let mut added = false;
            for class in 0..self.classes.len() {
                let class = u32::try_from(class).map_err(|e| Reject(e.to_string()))?;
                for name in self.dispatched.clone() {
                    if self.classes[class as usize].methods.contains_key(&name) {
                        continue;
                    }
                    if let Some(id) = self.find_method(class, &name)? {
                        self.classes[class as usize].methods.insert(name, id);
                        added = true;
                    }
                }
            }
            if !added && self.jobs.is_empty() {
                return Ok(());
            }
        }
    }

    /// A class with fields of its own initializes them after the constructor of its parent
    /// returns, so that constructor must not let `this` escape: code that it calls could
    /// read a field that holds no value yet.
    fn check_escapes(&self) -> Checked<()> {
        for class in &self.classes {
            if class.own.is_empty() {
                continue;
            }
            let mut ancestor = class.parent;
            while let Some(id) = ancestor {
                if self.escaping.contains(&id) {
                    return reject(
                        "a constructor that lets this escape before a subclass sets its fields",
                    );
                }
                ancestor = self.classes[id as usize].parent;
            }
        }
        Ok(())
    }

    fn reserve(
        &mut self,
        signature: Signature,
        function: Option<&'a Function<'a>>,
        owner: Owner<'a>,
    ) -> Checked<ir::FuncId> {
        let id = ir::FuncId::try_from(self.functions.len()).map_err(|e| Reject(e.to_string()))?;
        self.functions.push(None);
        self.signatures.push(signature.clone());
        self.jobs.push(Job {
            id,
            function,
            owner,
            signature,
        });
        Ok(id)
    }

    /// The function of a declaration, compiled once.
    pub fn function(
        &mut self,
        symbol: SymbolId,
        function: &'a Function<'a>,
    ) -> Checked<ir::FuncId> {
        if let Some(id) = self.function_ids.get(&symbol) {
            return Ok(*id);
        }
        if function.r#async || function.generator || function.body.is_none() {
            return reject("an async function, a generator, or a declaration without a body");
        }
        if self.is_written(symbol) {
            return reject("a function whose name the code assigns");
        }
        let signature = self.signature(&function.params, function)?;
        let id = self.reserve(signature, Some(function), Owner::Plain)?;
        self.function_ids.insert(symbol, id);
        Ok(id)
    }

    /// Whether the code writes to the binding.
    pub fn is_written(&self, symbol: SymbolId) -> bool {
        self.semantic
            .scoping()
            .get_resolved_references(symbol)
            .any(oxc::semantic::Reference::is_write)
    }

    /// The signature from the annotations of the parameters and the result. A function
    /// without a result annotation must return nothing.
    pub fn signature(
        &mut self,
        params: &'a FormalParameters<'a>,
        function: &'a Function<'a>,
    ) -> Checked<Signature> {
        if params.rest.is_some() {
            return reject("a rest parameter");
        }
        let mut types = Vec::with_capacity(params.items.len());
        let mut defaults = Vec::with_capacity(params.items.len());
        for param in &params.items {
            if param.optional || !matches!(param.pattern, BindingPattern::BindingIdentifier(_)) {
                return reject("an optional or destructured parameter");
            }
            let ty = match &param.type_annotation {
                Some(annotation) => self.annotation(annotation)?,
                None => match param.initializer.as_deref() {
                    Some(Expression::NumericLiteral(_)) => T::Num,
                    Some(Expression::BooleanLiteral(_)) => T::Bool,
                    _ => return reject("a parameter without a type"),
                },
            };
            let default = match param.initializer.as_deref() {
                None => None,
                Some(Expression::NumericLiteral(number)) if ty == T::Num => {
                    Some(ir::Expr::Num(number.value))
                }
                Some(Expression::BooleanLiteral(flag)) if ty == T::Bool => {
                    Some(ir::Expr::Bool(flag.value))
                }
                Some(Expression::NullLiteral(_)) if ty.is_reference() => Some(ir::Expr::Null),
                Some(_) => return reject("a parameter default that is not a literal"),
            };
            types.push(ty);
            defaults.push(default);
        }
        let result = match &function.return_type {
            Some(annotation) => self.annotation(annotation)?,
            None if returns_value(function) => return reject("a result without a type"),
            None => T::Void,
        };
        Ok(Signature {
            params: types,
            defaults,
            result,
        })
    }

    pub fn annotation(&mut self, annotation: &'a TSTypeAnnotation<'a>) -> Checked<T> {
        self.ty(&annotation.type_annotation)
    }

    /// The checker type of a TypeScript type.
    pub fn ty(&mut self, ty: &'a TSType<'a>) -> Checked<T> {
        Ok(match ty {
            TSType::TSNumberKeyword(_) => T::Num,
            TSType::TSBooleanKeyword(_) => T::Bool,
            TSType::TSVoidKeyword(_) => T::Void,
            TSType::TSNullKeyword(_) | TSType::TSUndefinedKeyword(_) => T::Null,
            TSType::TSParenthesizedType(inner) => self.ty(&inner.type_annotation)?,
            TSType::TSArrayType(array) => T::Array(Box::new(self.ty(&array.element_type)?)),
            TSType::TSTypeOperatorType(operator)
                if operator.operator == TSTypeOperatorOperator::Readonly =>
            {
                self.ty(&operator.type_annotation)?
            }
            TSType::TSUnionType(union) => {
                let mut found: Option<T> = None;
                for member in &union.types {
                    let member = self.ty(member)?;
                    match (&found, member) {
                        (_, T::Null) => {}
                        (None, other) if other.is_reference() => found = Some(other),
                        _ => return reject("a union other than a reference or null"),
                    }
                }
                found.unwrap_or(T::Null)
            }
            TSType::TSTypeReference(reference) => {
                let TSTypeName::IdentifierReference(name) = &reference.type_name else {
                    return reject("a qualified type name");
                };
                if name.name == "Array" {
                    let argument = reference
                        .type_arguments
                        .as_ref()
                        .and_then(|arguments| arguments.params.first())
                        .ok_or_else(|| Reject("Array without its element type".into()))?;
                    return Ok(T::Array(Box::new(self.ty(argument)?)));
                }
                if reference.type_arguments.is_some() {
                    return reject("a generic type");
                }
                let symbol = self
                    .semantic
                    .scoping()
                    .get_reference(name.reference_id())
                    .symbol_id()
                    .ok_or_else(|| Reject(format!("the type {}", name.name)))?;
                self.named_type(symbol)?
            }
            _ => return reject("a type that the native tier does not lower"),
        })
    }

    /// The type that a class or an interface declaration names.
    fn named_type(&mut self, symbol: SymbolId) -> Checked<T> {
        let node = self.semantic.scoping().symbol_declaration(symbol);
        match self.semantic.nodes().kind(node) {
            AstKind::Class(class) => Ok(T::Class(self.class(symbol, class)?)),
            AstKind::TSInterfaceDeclaration(_) => Ok(T::Iface(self.iface(symbol)?)),
            _ => reject("a type that is not a class or an interface"),
        }
    }

    fn iface(&mut self, symbol: SymbolId) -> Checked<usize> {
        if let Some(id) = self.iface_ids.get(&symbol) {
            return Ok(*id);
        }
        let node = self.semantic.scoping().symbol_declaration(symbol);
        let AstKind::TSInterfaceDeclaration(declaration) = self.semantic.nodes().kind(node) else {
            return reject("not an interface");
        };
        if !declaration.extends.is_empty() || declaration.type_parameters.is_some() {
            return reject("an interface that extends or is generic");
        }
        let id = self.ifaces.len();
        self.iface_ids.insert(symbol, id);
        self.ifaces.push(IfaceInfo {
            methods: HashMap::new(),
        });
        let mut methods = HashMap::new();
        for member in &declaration.body.body {
            let TSSignature::TSMethodSignature(method) = member else {
                return reject("an interface member other than a method");
            };
            let PropertyKey::StaticIdentifier(key) = &method.key else {
                return reject("an interface method with a computed name");
            };
            if method.optional || method.type_parameters.is_some() {
                return reject("an optional or generic interface method");
            }
            let mut params = Vec::new();
            for param in &method.params.items {
                let annotation = param
                    .type_annotation
                    .as_ref()
                    .ok_or_else(|| Reject("an interface parameter without a type".into()))?;
                params.push(self.annotation(annotation)?);
            }
            let result = match &method.return_type {
                Some(annotation) => self.annotation(annotation)?,
                None => T::Void,
            };
            let defaults = vec![None; params.len()];
            methods.insert(
                key.name.to_string(),
                Signature {
                    params,
                    defaults,
                    result,
                },
            );
        }
        self.ifaces[id].methods = methods;
        Ok(id)
    }

    /// The class of a declaration, with its layout. Its methods compile when a call needs
    /// them.
    pub fn class(&mut self, symbol: SymbolId, class: &'a Class<'a>) -> Checked<ir::ClassId> {
        if let Some(id) = self.class_ids.get(&symbol) {
            return Ok(*id);
        }
        if self.is_written(symbol) || class.declare || class.type_parameters.is_some() {
            return reject("a class that the code assigns, declares, or makes generic");
        }
        let parent = match &class.heritage {
            None => None,
            Some(heritage) => {
                let Expression::Identifier(name) = &heritage.expression else {
                    return reject("a superclass that is not a class name");
                };
                let parent_symbol = self
                    .semantic
                    .scoping()
                    .get_reference(name.reference_id())
                    .symbol_id()
                    .ok_or_else(|| Reject("a superclass that no scope declares".into()))?;
                let node = self.semantic.scoping().symbol_declaration(parent_symbol);
                let AstKind::Class(parent_class) = self.semantic.nodes().kind(node) else {
                    return reject("a superclass that is not a class declaration");
                };
                Some(self.class(parent_symbol, parent_class)?)
            }
        };
        let id = ir::ClassId::try_from(self.classes.len()).map_err(|e| Reject(e.to_string()))?;
        self.class_ids.insert(symbol, id);
        let name = class
            .id
            .as_ref()
            .map_or_else(String::new, |id| id.name.to_string());
        let mut fields = parent.map_or_else(Vec::new, |p| self.classes[p as usize].fields.clone());
        self.classes.push(ClassInfo {
            name,
            node: class,
            parent,
            fields: Vec::new(),
            own: Vec::new(),
            constructor: None,
            methods: HashMap::new(),
        });
        let mut own = Vec::new();
        for element in &class.body.body {
            match element {
                ClassElement::MethodDefinition(method) => {
                    if method.computed
                        || !matches!(method.key, PropertyKey::StaticIdentifier(_))
                        || !matches!(
                            method.kind,
                            MethodDefinitionKind::Method | MethodDefinitionKind::Constructor
                        )
                    {
                        return reject("an accessor or a method with a computed or private name");
                    }
                }
                ClassElement::PropertyDefinition(property) => {
                    let PropertyKey::StaticIdentifier(key) = &property.key else {
                        return reject("a field with a computed or private name");
                    };
                    if property.r#static {
                        return reject("a static field");
                    }
                    if property.declare || property.optional {
                        return reject("a declared or optional field");
                    }
                    let name = key.name.to_string();
                    if fields.iter().any(|(field, _)| *field == name) {
                        return reject("a field that redeclares a field of the parent");
                    }
                    let ty = match &property.type_annotation {
                        Some(annotation) => self.annotation(annotation)?,
                        None => field_type(property.value.as_ref())?,
                    };
                    if ty == T::Void {
                        return reject("a field of type void");
                    }
                    fields.push((name.clone(), ty.clone()));
                    own.push((name, ty, property.value.as_ref()));
                }
                ClassElement::TSIndexSignature(_) => {
                    return reject("an index signature");
                }
                ClassElement::StaticBlock(_) | ClassElement::AccessorProperty(_) => {
                    return reject("a static block or an accessor property");
                }
            }
        }
        let info = &mut self.classes[id as usize];
        info.fields = fields;
        info.own = own;
        Ok(id)
    }

    /// The method definition named `name` of the class itself.
    pub fn own_method(
        &self,
        class: ir::ClassId,
        name: &str,
        is_static: bool,
    ) -> Option<&'a Function<'a>> {
        let node = self.classes[class as usize].node;
        node.body.body.iter().find_map(|element| match element {
            ClassElement::MethodDefinition(method)
                if method.kind == MethodDefinitionKind::Method
                    && method.r#static == is_static
                    && matches!(&method.key, PropertyKey::StaticIdentifier(key) if key.name == name) =>
            {
                Some(&*method.value)
            }
            _ => None,
        })
    }

    /// The function of a method of the class itself, compiled once. `None` when the class
    /// declares no such method, or declares it abstract.
    pub fn method(
        &mut self,
        class: ir::ClassId,
        name: &str,
        is_static: bool,
    ) -> Checked<Option<ir::FuncId>> {
        let key = (class, name.to_owned(), is_static);
        if let Some(id) = self.method_ids.get(&key) {
            return Ok(Some(*id));
        }
        let Some(function) = self.own_method(class, name, is_static) else {
            return Ok(None);
        };
        if function.body.is_none() {
            return Ok(None);
        }
        if function.r#async || function.generator {
            return reject("an async or generator method");
        }
        let mut signature = self.signature(&function.params, function)?;
        let owner = if is_static {
            Owner::Static
        } else {
            signature.params.insert(0, T::Class(class));
            signature.defaults.insert(0, None);
            Owner::Method(class)
        };
        let id = self.reserve(signature, Some(function), owner)?;
        self.method_ids.insert(key, id);
        Ok(Some(id))
    }

    /// The method `name` that an instance of the class calls: its own or an inherited one.
    pub fn find_method(&mut self, class: ir::ClassId, name: &str) -> Checked<Option<ir::FuncId>> {
        let mut current = Some(class);
        while let Some(id) = current {
            if self.own_method(id, name, false).is_some() {
                return self.method(id, name, false);
            }
            current = self.classes[id as usize].parent;
        }
        Ok(None)
    }

    /// The signature of the method `name` of instances of the class, declared on it or on
    /// a parent, with `this` first.
    pub fn method_signature(
        &mut self,
        class: ir::ClassId,
        name: &str,
    ) -> Checked<Option<Signature>> {
        let mut current = Some(class);
        while let Some(id) = current {
            if let Some(function) = self.own_method(id, name, false) {
                let mut signature = self.signature(&function.params, function)?;
                signature.params.insert(0, T::Class(id));
                signature.defaults.insert(0, None);
                return Ok(Some(signature));
            }
            current = self.classes[id as usize].parent;
        }
        Ok(None)
    }

    /// The constructor function of the class, compiled once.
    pub fn constructor(&mut self, class: ir::ClassId) -> Checked<ir::FuncId> {
        if let Some(id) = self.classes[class as usize].constructor {
            return Ok(id);
        }
        let node = self.classes[class as usize].node;
        let declared = node.body.body.iter().find_map(|element| match element {
            ClassElement::MethodDefinition(method)
                if method.kind == MethodDefinitionKind::Constructor =>
            {
                Some(&*method.value)
            }
            _ => None,
        });
        let mut signature = match declared {
            Some(function) => {
                if function
                    .params
                    .items
                    .iter()
                    .any(|param| param.accessibility.is_some() || param.readonly)
                {
                    return reject("a parameter property");
                }
                let mut signature = self.signature(&function.params, function)?;
                signature.result = T::Void;
                signature
            }
            // A derived class without a constructor passes its arguments to the parent.
            None => match self.classes[class as usize].parent {
                Some(parent) => {
                    let parent_id = self.constructor(parent)?;
                    let mut signature = self.signatures[parent_id as usize].clone();
                    signature.params.remove(0);
                    signature.defaults.remove(0);
                    signature
                }
                None => Signature {
                    params: Vec::new(),
                    defaults: Vec::new(),
                    result: T::Void,
                },
            },
        };
        signature.params.insert(0, T::Class(class));
        signature.defaults.insert(0, None);
        let id = self.reserve(signature, declared, Owner::Constructor(class, declared))?;
        self.classes[class as usize].constructor = Some(id);
        Ok(id)
    }

    /// Whether `class` is `ancestor` or one of its subclasses.
    pub fn is_subclass(&self, class: ir::ClassId, ancestor: ir::ClassId) -> bool {
        let mut current = Some(class);
        while let Some(id) = current {
            if id == ancestor {
                return true;
            }
            current = self.classes[id as usize].parent;
        }
        false
    }

    /// Whether a value of type `from` may go where `to` is.
    pub fn fits(&mut self, from: &T, to: &T) -> bool {
        match (from, to) {
            (T::Null, T::Class(_) | T::Iface(_) | T::Array(_)) => true,
            (T::Class(a), T::Class(b)) => self.is_subclass(*a, *b),
            (T::Class(class), T::Iface(iface)) => self.implements(*class, *iface),
            _ => from == to,
        }
    }

    /// Whether every method of the interface exists on the class with as many parameters.
    fn implements(&mut self, class: ir::ClassId, iface: usize) -> bool {
        let wanted: Vec<(String, usize)> = self.ifaces[iface]
            .methods
            .iter()
            .map(|(name, signature)| (name.clone(), signature.params.len()))
            .collect();
        wanted.iter().all(|(name, count)| {
            matches!(self.method_signature(class, name), Ok(Some(signature)) if signature.params.len() == count + 1)
        })
    }

    /// The index of a global, added on first use.
    pub fn global(&mut self, symbol: SymbolId, ty: T) -> u32 {
        let index = self
            .globals
            .iter()
            .position(|(found, _)| *found == symbol)
            .unwrap_or_else(|| {
                self.globals.push((symbol, ty));
                self.globals.len() - 1
            });
        u32::try_from(index).unwrap_or(u32::MAX)
    }
}

/// The type of a field without an annotation, from its initializer.
fn field_type(value: Option<&Expression<'_>>) -> Checked<T> {
    match value {
        Some(Expression::NumericLiteral(_)) => Ok(T::Num),
        Some(Expression::BooleanLiteral(_)) => Ok(T::Bool),
        Some(Expression::UnaryExpression(unary))
            if matches!(unary.argument, Expression::NumericLiteral(_)) =>
        {
            Ok(T::Num)
        }
        _ => reject("a field without a type"),
    }
}

/// Whether a `return` with a value appears in the body, outside nested functions.
fn returns_value(function: &Function<'_>) -> bool {
    use oxc::ast_visit::Visit;
    struct Finder(bool);
    impl<'a> Visit<'a> for Finder {
        fn visit_return_statement(&mut self, it: &oxc::ast::ast::ReturnStatement<'a>) {
            if it.argument.is_some() {
                self.0 = true;
            }
        }
        fn visit_function(&mut self, _: &Function<'a>, _: oxc::semantic::ScopeFlags) {}
        fn visit_arrow_function_expression(
            &mut self,
            _: &oxc::ast::ast::ArrowFunctionExpression<'a>,
        ) {
        }
    }
    let mut finder = Finder(false);
    if let Some(body) = &function.body {
        for statement in &body.statements {
            finder.visit_statement(statement);
        }
    }
    finder.0
}

/// An island, lowered.
pub struct Built {
    pub program: ir::Program,
    /// The variables whose values the entry passes, in the order of the IR globals.
    pub globals: Vec<SymbolId>,
    /// The classes whose definitions the entry checks.
    pub classes: Vec<SymbolId>,
    pub uses_math: bool,
}

/// The statements of a function body.
pub fn statements<'a>(function: &'a Function<'a>) -> &'a [Statement<'a>] {
    function
        .body
        .as_ref()
        .map_or(&[], |body| body.statements.as_slice())
}
