//! Classes: `ClassDefinitionEvaluation`. A module-level class is made once per realm by
//! `'Name#make'/0`; a class expression or a class in a function is made each time its
//! code runs. Each evaluation makes new private names, so the methods of two
//! evaluations do not share them.
//!
//! The class code creates the constructor and the prototype, evaluates the elements in
//! order (methods, accessors, and the computed keys of fields), makes the `Init` fun
//! that adds the private methods and the fields to a new instance, sets the
//! [[Construct]] fun, and then runs the static fields and blocks in order.

use oxc::ast::ast::{
    BindingPattern, Class, ClassElement, Expression, MethodDefinition, MethodDefinitionKind,
    PropertyDefinition, PropertyDefinitionType, PropertyKey, StaticBlock,
};
use oxc::ast_visit::Visit;
use oxc::span::GetSpan;

use super::analyze::VarDeclarations;
use super::context::{ClassFrame, Cont, Frame, Kind, Local, Lowerer, Ret};
use super::expr::strip;
use super::function::{Callee, FnBody, length_of};
use super::member::super_object;
use super::module::heritage_suspends;
use crate::erlang::{Clause, Expr, Function};

/// The elements of a class that run after its methods are defined.
struct Elements<'a> {
    instance: Vec<Deferred<'a>>,
    statics: Vec<Deferred<'a>>,
    private_methods: Vec<Expr>,
    static_private_methods: Vec<Expr>,
}

/// A field or a static block, which runs after the methods are defined.
enum Deferred<'a> {
    Field(Expr, &'a PropertyDefinition<'a>, bool),
    Block(&'a StaticBlock<'a>),
}

impl<'a> Lowerer<'a, '_> {
    /// `'Name#make'/0`: the class of a module-level class declaration in this realm.
    pub fn module_class(&mut self, name: &str, class: &'a Class<'a>) {
        self.classes.push(name.to_owned());
        self.frame = Frame::default();
        self.pre.clear();
        let key = self.class_key(name);
        // A superclass expression that awaits runs in the top-level code, which leaves
        // its value under the heritage key.
        let heritage = heritage_suspends(class).then(|| self.heritage_key(name));
        let c = self.class_value(class, Expr::js_string(name), Some((key, heritage)));
        let mut body = std::mem::take(&mut self.pre);
        body.push(c);
        self.extra.push(Function {
            name: format!("{name}#make"),
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body,
            }],
        });
        self.frame = Frame::default();
    }

    /// A class declaration in a function or a block: its value, bound to its name. A
    /// module-level class is `declare_class`.
    pub fn class_declaration(&mut self, class: &'a Class<'a>) {
        let name = class
            .id
            .as_ref()
            .map_or_else(String::new, |id| id.name.to_string());
        let c = self.class_value(class, Expr::js_string(&name), None);
        if let Some(symbol) = class.id.as_ref().and_then(|id| id.symbol_id.get()) {
            self.declare_symbol(symbol, c);
        }
    }

    /// A class expression. `name` is the key that `NamedEvaluation` names an anonymous
    /// class after.
    pub fn class_expression(&mut self, class: &'a Class<'a>, name: Option<Expr>) -> Expr {
        let name = match (&class.id, name) {
            (Some(id), _) => Expr::js_string(id.name.as_str()),
            (None, Some(name)) => name,
            (None, None) => Expr::js_string(""),
        };
        self.class_value(class, name, None)
    }

    /// `ClassDefinitionEvaluation`: the code goes to `pre`, and the value is the class.
    /// `register` holds, for a module-level class, the key under which the class is stored
    /// in the realm before its static elements run, and the key of the value of its
    /// superclass expression when the top-level code evaluated it.
    pub fn class_value(
        &mut self,
        class: &'a Class<'a>,
        name: Expr,
        register: Option<(Expr, Option<Expr>)>,
    ) -> Expr {
        let (register, heritage_key) = match register {
            Some((key, heritage)) => (Some(key), heritage),
            None => (None, None),
        };
        self.declare_privates(class);
        if let (Some(symbol), Some(heritage)) = (
            class.id.as_ref().and_then(|id| id.symbol_id.get()),
            &class.heritage,
        ) {
            self.heritage_binding(symbol, heritage.expression.span());
        }
        let parent = class.heritage.as_ref().map(|heritage| {
            let value = match heritage_key {
                Some(key) => Expr::call("erlang", "get", vec![key]),
                None => self.expr(&heritage.expression),
            };
            self.bind(value)
        });
        let constructor = class.body.body.iter().find_map(|element| match element {
            ClassElement::MethodDefinition(method)
                if method.kind == MethodDefinitionKind::Constructor
                    && method.value.body.is_some() =>
            {
                Some(&**method)
            }
            _ => None,
        });
        let length = constructor.map_or(0, |method| length_of(&method.value.params));
        let c = self.fresh("C");
        let proto = self.fresh("Proto");
        let source = self.source_span(class.span);
        self.pre.push(Expr::matches(
            Expr::Tuple(vec![Expr::var(c.clone()), Expr::var(proto.clone())]),
            Expr::call(
                "bouy_ref_class",
                "create",
                vec![
                    name,
                    parent.clone().unwrap_or_else(|| Expr::atom("none")),
                    int(length),
                    source,
                ],
            ),
        ));
        if let Some(key) = register {
            self.pre
                .push(Expr::call("erlang", "put", vec![key, Expr::var(c.clone())]));
        }
        // The class binding inside the body is the class itself.
        let binding = class.id.as_ref().and_then(|id| id.symbol_id.get());
        let saved = binding.map(|symbol| (symbol, self.frame.env.get(&symbol).cloned()));
        if let Some(symbol) = binding {
            self.frame.env.insert(symbol, Local::Var(c.clone()));
            self.class_bindings.push(symbol);
        }
        let Elements {
            instance,
            statics,
            private_methods,
            static_private_methods,
        } = self.class_elements(class, &c, &proto);
        let init = self.init_fun(&c, &proto, private_methods, instance);
        let frame = ClassFrame {
            home: proto.clone(),
            class: Some(c.clone()),
            init,
        };
        let construct = self.construct_fun(constructor, &frame, parent.is_some());
        self.pre.push(Expr::call(
            "bouy_ref_class",
            "set_construct",
            vec![Expr::var(c.clone()), construct],
        ));
        if !static_private_methods.is_empty() {
            self.pre.push(Expr::call(
                "bouy_ref_class",
                "add_private_methods",
                vec![Expr::var(c.clone()), Expr::List(static_private_methods)],
            ));
        }
        for element in statics {
            let this = self.fresh("This");
            let frame = ClassFrame {
                home: c.clone(),
                class: Some(c.clone()),
                init: None,
            };
            let fun = self.class_closure(&this, frame, |me| me.deferred(&this, element));
            self.pre
                .push(Expr::Apply(Box::new(fun), vec![Expr::var(c.clone())]));
        }
        if let Some((symbol, previous)) = saved {
            self.class_bindings.pop();
            match previous {
                Some(local) => self.frame.env.insert(symbol, local),
                None => self.frame.env.remove(&symbol),
            };
        }
        self.privates.pop();
        Expr::var(c)
    }

    /// `ClassElementEvaluation` in order: defines the methods and accessors, and evaluates
    /// the keys of the fields, which run later.
    fn class_elements(&mut self, class: &'a Class<'a>, c: &str, proto: &str) -> Elements<'a> {
        let mut elements = Elements {
            instance: Vec::new(),
            statics: Vec::new(),
            private_methods: Vec::new(),
            static_private_methods: Vec::new(),
        };
        for element in &class.body.body {
            match element {
                ClassElement::MethodDefinition(method) => {
                    if method.kind == MethodDefinitionKind::Constructor
                        || method.value.body.is_none()
                    {
                        continue;
                    }
                    let home = if method.r#static { c } else { proto };
                    if let Some(private) = self.define_method(method, home, c) {
                        if method.r#static {
                            elements.static_private_methods.push(private);
                        } else {
                            elements.private_methods.push(private);
                        }
                    }
                }
                ClassElement::PropertyDefinition(property) => {
                    if property.declare
                        || property.r#type == PropertyDefinitionType::TSAbstractPropertyDefinition
                    {
                        continue;
                    }
                    let private = matches!(property.key, PropertyKey::PrivateIdentifier(_));
                    let key = self.property_key(&property.key, property.computed);
                    let field = Deferred::Field(key, property, private);
                    if property.r#static {
                        elements.statics.push(field);
                    } else {
                        elements.instance.push(field);
                    }
                }
                ClassElement::StaticBlock(block) => elements.statics.push(Deferred::Block(block)),
                ClassElement::AccessorProperty(accessor) => {
                    self.unsupported(accessor.span, "`accessor` fields");
                }
                ClassElement::TSIndexSignature(_) => {}
            }
        }
        elements
    }

    /// A new private name for each `#name` that the class body declares.
    fn declare_privates(&mut self, class: &'a Class<'a>) {
        let mut seen = std::collections::HashSet::new();
        let mut names: Vec<String> = Vec::new();
        for element in &class.body.body {
            let key = match element {
                ClassElement::MethodDefinition(method) => &method.key,
                ClassElement::PropertyDefinition(property) => &property.key,
                ClassElement::AccessorProperty(accessor) => &accessor.key,
                _ => continue,
            };
            if let PropertyKey::PrivateIdentifier(private) = key
                && seen.insert(private.name.as_str())
            {
                names.push(private.name.to_string());
            }
        }
        // A fun can close over at most 255 variables, so many names share one tuple.
        let scope = if names.len() <= 32 {
            names
                .into_iter()
                .map(|name| {
                    let var = self.fresh("Private");
                    self.pre.push(Expr::matches(
                        Expr::var(var.clone()),
                        Expr::call(
                            "bouy_ref_class",
                            "private_name",
                            vec![Expr::js_string(&name)],
                        ),
                    ));
                    (name, Expr::var(var))
                })
                .collect()
        } else {
            let var = self.fresh("Privates");
            self.pre.push(Expr::matches(
                Expr::var(var.clone()),
                Expr::call(
                    "bouy_ref_class",
                    "private_names",
                    vec![Expr::List(
                        names.iter().map(|name| Expr::js_string(name)).collect(),
                    )],
                ),
            ));
            names
                .into_iter()
                .enumerate()
                .map(|(index, name)| {
                    let position = Expr::Integer(i64::try_from(index + 1).unwrap_or(0));
                    let key =
                        Expr::call("erlang", "element", vec![position, Expr::var(var.clone())]);
                    (name, key)
                })
                .collect()
        };
        self.privates.push(scope);
    }

    /// The key of a private name: the variable of the innermost class that declares it.
    pub fn private_key(&mut self, name: &str) -> Expr {
        let found = self.privates.iter().rev().find_map(|scope| {
            scope
                .iter()
                .find(|(known, _)| known == name)
                .map(|(_, key)| key.clone())
        });
        match found {
            Some(key) => key,
            None => self.unsupported(
                oxc::span::Span::default(),
                &format!("the private name `#{name}` outside its class"),
            ),
        }
    }

    /// The source text of a method for `Function.prototype.toString`: the
    /// `MethodDefinition`, which starts after `static` and the comments that follow it.
    fn method_span(&self, method: &MethodDefinition<'_>) -> oxc::span::Span {
        let text = self.semantic.source_text();
        let mut start = method.span.start as usize;
        if method.r#static {
            start += "static".len();
            loop {
                let rest = &text[start..];
                let trimmed = rest.trim_start();
                start += rest.len() - trimmed.len();
                if trimmed.starts_with("//") {
                    start += trimmed.find('\n').unwrap_or(trimmed.len());
                } else if trimmed.starts_with("/*") {
                    start += trimmed.find("*/").map_or(trimmed.len(), |end| end + 2);
                } else {
                    break;
                }
            }
        }
        oxc::span::Span::new(
            u32::try_from(start).unwrap_or(method.span.start),
            method.span.end,
        )
    }

    /// Defines a method or an accessor on `home`. A private one is returned as
    /// `{Name, Kind, Function}` for `add_private_methods`.
    fn define_method(
        &mut self,
        method: &'a MethodDefinition<'a>,
        home: &str,
        class: &str,
    ) -> Option<Expr> {
        let private = matches!(method.key, PropertyKey::PrivateIdentifier(_));
        let key = self.property_key(&method.key, method.computed);
        let frame = ClassFrame {
            home: home.to_owned(),
            class: Some(class.to_owned()),
            init: None,
        };
        let kind = match method.kind {
            MethodDefinitionKind::Get => "get",
            MethodDefinitionKind::Set => "set",
            _ => method_kind(method.value.r#async, method.value.generator),
        };
        let fun = self.function_fun(&method.value, Callee::Method(Some(frame)));
        let source = self.source_span(self.method_span(method));
        let value = self.bind(Expr::call(
            "bouy_ref_class",
            "method",
            vec![
                fun,
                key.clone(),
                int(length_of(&method.value.params)),
                Expr::atom(kind),
                source,
            ],
        ));
        let slot = match method.kind {
            MethodDefinitionKind::Get => "get",
            MethodDefinitionKind::Set => "set",
            _ => "method",
        };
        if private {
            return Some(Expr::Tuple(vec![key, Expr::atom(slot), value]));
        }
        self.pre.push(Expr::call(
            "bouy_ref_class",
            "define_method",
            vec![Expr::var(home.to_owned()), key, value, Expr::atom(slot)],
        ));
        None
    }

    /// The `Init` fun of the class: adds the private methods and the fields to `this`.
    fn init_fun(
        &mut self,
        class: &str,
        proto: &str,
        private_methods: Vec<Expr>,
        fields: Vec<Deferred<'a>>,
    ) -> Option<String> {
        if private_methods.is_empty() && fields.is_empty() {
            return None;
        }
        let this = self.fresh("This");
        let frame = ClassFrame {
            home: proto.to_owned(),
            class: Some(class.to_owned()),
            init: None,
        };
        let fun = self.class_closure(&this, frame, |me| {
            let mut code = Vec::new();
            if !private_methods.is_empty() {
                code.push(Expr::call(
                    "bouy_ref_class",
                    "add_private_methods",
                    vec![Expr::var(this.clone()), Expr::List(private_methods)],
                ));
            }
            for field in fields {
                code.extend(me.deferred(&this, field));
            }
            code
        });
        let name = self.fresh("Init");
        self.pre.push(Expr::matches(Expr::var(name.clone()), fun));
        Some(name)
    }

    /// The code of a field or a static block, with `this` the instance or the class.
    fn deferred(&mut self, this: &str, element: Deferred<'a>) -> Vec<Expr> {
        match element {
            Deferred::Field(key, property, private) => {
                self.frame.in_field = true;
                let value = match &property.value {
                    Some(value) => self.named_expr(value, Some(key.clone())),
                    None => Expr::undefined(),
                };
                self.frame.in_field = false;
                let function = if private {
                    "private_add"
                } else {
                    "define_field"
                };
                let mut code = std::mem::take(&mut self.pre);
                code.push(Expr::call(
                    "bouy_ref_class",
                    function,
                    vec![Expr::var(this.to_owned()), key, value],
                ));
                code
            }
            Deferred::Block(block) => {
                let mut vars = VarDeclarations::default();
                for statement in &block.body {
                    vars.visit_statement(statement);
                }
                for symbol in vars.0 {
                    if !self.frame.env.contains_key(&symbol) {
                        self.declare_symbol(symbol, Expr::undefined());
                    }
                }
                let mut code = std::mem::take(&mut self.pre);
                code.extend(self.stmts(block.body.iter().collect(), &Cont::Return));
                code
            }
        }
    }

    /// `fun(This) -> Code end` for code that the class definition runs with its own
    /// `this`: the field initializers and the static elements.
    fn class_closure(
        &mut self,
        this: &str,
        class: ClassFrame,
        build: impl FnOnce(&mut Self) -> Vec<Expr>,
    ) -> Expr {
        let outer = std::mem::take(&mut self.frame);
        let outer_pre = std::mem::take(&mut self.pre);
        self.frame = Frame {
            env: outer.env.clone(),
            this: Some(this.to_owned()),
            kind: Kind::Sync,
            class: Some(class),
            in_function: true,
            withs: outer.withs.clone(),
            ..Frame::default()
        };
        let mut code = build(self);
        code.push(Expr::ok());
        self.frame = outer;
        self.pre = outer_pre;
        Expr::Fun {
            name: None,
            clauses: vec![Clause::new(Expr::var(this.to_owned()), code)],
        }
    }

    /// The [[Construct]] of the class: `fun(NewTarget, Args) -> This end`. A base class
    /// creates `this` from new.target and initializes it before its parameters; a derived
    /// class gets `this` from `super(...)`.
    fn construct_fun(
        &mut self,
        constructor: Option<&'a MethodDefinition<'a>>,
        class: &ClassFrame,
        derived: bool,
    ) -> Expr {
        let new_target = self.fresh("NewTarget");
        let args = self.fresh("Args");
        let outer = std::mem::take(&mut self.frame);
        let outer_pre = std::mem::take(&mut self.pre);
        self.frame = Frame {
            env: outer.env.clone(),
            ret: Ret::Constructor,
            kind: Kind::Sync,
            class: Some(class.clone()),
            new_target: Some(new_target.clone()),
            in_function: true,
            withs: outer.withs.clone(),
            ..Frame::default()
        };
        let mut code = Vec::new();
        if derived {
            let Some(c) = &class.class else {
                return Expr::undefined();
            };
            if let Some(constructor) = constructor {
                let cell = self.fresh("ThisCell");
                code.push(Expr::matches(
                    Expr::var(cell.clone()),
                    Expr::call("bouy_heap", "cell", vec![Expr::atom("$uninitialized")]),
                ));
                self.frame.this_cell = Some(cell);
                code.extend(self.constructor_body(constructor, &args));
            } else {
                // The default constructor passes its arguments on as they are.
                let this = self.fresh("This");
                code.push(Expr::matches(
                    Expr::var(this.clone()),
                    Expr::call(
                        "bouy_ref_class",
                        "super_construct",
                        vec![
                            Expr::var(c.clone()),
                            Expr::var(args.clone()),
                            Expr::var(new_target.clone()),
                        ],
                    ),
                ));
                if let Some(init) = &class.init {
                    code.push(Expr::Apply(
                        Box::new(Expr::var(init.clone())),
                        vec![Expr::var(this.clone())],
                    ));
                }
                code.push(Expr::var(this));
            }
        } else {
            let this = self.fresh("This");
            code.push(Expr::matches(
                Expr::var(this.clone()),
                Expr::call("bouy_ref", "new_this", vec![Expr::var(new_target.clone())]),
            ));
            if let Some(init) = &class.init {
                code.push(Expr::Apply(
                    Box::new(Expr::var(init.clone())),
                    vec![Expr::var(this.clone())],
                ));
            }
            self.frame.this = Some(this.clone());
            match constructor {
                Some(constructor) => code.extend(self.constructor_body(constructor, &args)),
                None => code.push(Expr::var(this)),
            }
        }
        self.frame = outer;
        self.pre = outer_pre;
        Expr::Fun {
            name: None,
            clauses: vec![Clause {
                patterns: vec![Expr::var(new_target), Expr::var(args)],
                guards: vec![],
                body: code,
            }],
        }
    }

    /// The `arguments` object, the parameters, the parameter properties, the `var`
    /// names, and the body of a constructor.
    fn constructor_body(&mut self, constructor: &'a MethodDefinition<'a>, args: &str) -> Vec<Expr> {
        let function = &constructor.value;
        let Some(body) = &function.body else {
            return vec![];
        };
        let mut code = self.entry(&function.params, FnBody::Block(body), args, true, None);
        for param in &function.params.items {
            if param.accessibility.is_none() && !param.readonly {
                continue;
            }
            if let BindingPattern::BindingIdentifier(id) = &param.pattern
                && let Some(symbol) = id.symbol_id.get()
            {
                let value = self.read_symbol(symbol, param.span);
                let this = self.this_expr();
                let this = self.bind(this);
                self.pre.push(Expr::call(
                    "bouy_ref_class",
                    "define_field",
                    vec![this, Expr::js_string(id.name.as_str()), value],
                ));
            }
        }
        code.append(&mut self.pre);
        code.extend(self.body(FnBody::Block(body)));
        code
    }

    /// `super(...args)` in a derived constructor. The parent is the prototype of the
    /// class, read before the arguments, as `GetSuperConstructor`.
    pub fn super_constructor(&mut self) -> Option<Expr> {
        let class = self.frame.class.clone()?.class?;
        Some(self.bind(Expr::call(
            "bouy_heap",
            "prototype_of",
            vec![Expr::var(class)],
        )))
    }

    /// Constructs `this` with the parent, binds it, and initializes it.
    pub fn super_constructor_call(&mut self, parent: Option<Expr>, args: Expr) -> Expr {
        let (Some(parent), Some(cell), Some(new_target)) = (
            parent,
            self.frame.this_cell.clone(),
            self.frame.new_target.clone(),
        ) else {
            return self.unsupported(
                oxc::span::Span::default(),
                "`super(...)` outside a derived constructor",
            );
        };
        let init = self
            .frame
            .class
            .as_ref()
            .and_then(|class| class.init.clone());
        let this = self.bind(Expr::call(
            "bouy_ref_class",
            "construct_parent",
            vec![parent, args, Expr::var(new_target)],
        ));
        self.pre.push(Expr::call(
            "bouy_ref_class",
            "bind_this",
            vec![Expr::var(cell), this.clone()],
        ));
        if let Some(init) = init {
            self.pre
                .push(Expr::Apply(Box::new(Expr::var(init)), vec![this.clone()]));
        }
        this
    }

    fn home(&self) -> Option<String> {
        self.frame.class.as_ref().map(|class| class.home.clone())
    }

    /// The object of `super.k`, with `this` read first: the base is the prototype of
    /// the home object.
    pub fn super_reference(&mut self) -> Expr {
        let this = self.this_expr();
        let this = self.bind(this);
        self.super_base(this)
    }

    /// `GetSuperBase`, after `this` and the key: the prototype of the home object.
    pub fn super_base(&mut self, this: Expr) -> Expr {
        let Some(home) = self.home() else {
            return self.unsupported(oxc::span::Span::default(), "`super` outside a method");
        };
        let base = self.bind(Expr::call(
            "bouy_heap",
            "prototype_of",
            vec![Expr::var(home)],
        ));
        super_object(base, this)
    }

    /// `NamedEvaluation` (ECMA-262 §8.4.5): an anonymous function or class gets its name
    /// from `key`, the property key or the binding name. Without a key it is `expr`.
    pub fn named_expr(&mut self, expression: &'a Expression<'a>, key: Option<Expr>) -> Expr {
        let Some(key) = key else {
            return self.expr(expression);
        };
        match strip(expression) {
            Expression::FunctionExpression(function) if function.id.is_none() => {
                self.function_value(function, Some(key))
            }
            Expression::ArrowFunctionExpression(arrow) => self.arrow_value(arrow, Some(key)),
            Expression::ClassExpression(class) if class.id.is_none() => {
                self.class_expression(class, Some(key))
            }
            other => self.expr(other),
        }
    }
}

/// The kind of a method for `bouy_ref_class:method/4`.
pub fn method_kind(is_async: bool, generator: bool) -> &'static str {
    match (is_async, generator) {
        (false, false) => "method",
        (true, false) => "async",
        (false, true) => "generator",
        (true, true) => "async_generator",
    }
}

fn int(value: usize) -> Expr {
    Expr::Integer(i64::try_from(value).unwrap_or(0))
}
