//! Classes: `'Name#make'/0` creates the class once per realm, with `class_create`, the
//! methods and accessors on the prototype or the class, the construct fun, and the static
//! members in order.

use oxc::ast::ast::{
    BindingPattern, Class, ClassElement, MethodDefinitionKind, PropertyDefinition,
};

use super::{ClassFrame, FnBody, Frame, Kind, Lowerer, Ret};
use crate::erlang::{Clause, Expr, Function};

impl<'a> Lowerer<'a, '_> {
    pub fn module_class(&mut self, name: &str, class: &'a Class<'a>) {
        self.classes.push(name.to_owned());
        self.frame = Frame::default();
        self.pre.clear();
        let parent = match &class.heritage {
            Some(heritage) => {
                let value = self.expr(&heritage.expression);
                let var = self.fresh("Parent");
                self.pre.push(Expr::matches(Expr::var(var.clone()), value));
                Some(var)
            }
            None => None,
        };
        let constructor = class.body.body.iter().find_map(|element| match element {
            ClassElement::MethodDefinition(method)
                if method.kind == MethodDefinitionKind::Constructor =>
            {
                Some(&**method)
            }
            _ => None,
        });
        let length = constructor.map_or(0, |method| {
            method
                .value
                .params
                .items
                .iter()
                .take_while(|param| param.initializer.is_none())
                .count()
        });
        let c = self.fresh("C");
        let proto = self.fresh("Proto");
        self.pre.push(Expr::matches(
            Expr::Tuple(vec![Expr::var(c.clone()), Expr::var(proto.clone())]),
            Expr::call(
                "bouy_ref",
                "class_create",
                vec![
                    Expr::binary(name.to_owned()),
                    parent.clone().map_or_else(|| Expr::atom("none"), Expr::var),
                    Expr::Integer(i64::try_from(length).unwrap_or(0)),
                ],
            ),
        ));
        self.pre.push(Expr::call(
            "erlang",
            "put",
            vec![self.class_key(name), Expr::var(c.clone())],
        ));
        let frame = ClassFrame {
            name: name.to_owned(),
            home: proto.clone(),
            parent,
            new_target: None,
            span: class.span,
        };
        self.define_methods(class, &frame, &c);
        let construct = self.construct_fun(class, constructor, &frame);
        self.pre.push(Expr::call(
            "bouy_ref",
            "set_construct",
            vec![Expr::var(c.clone()), construct],
        ));
        self.static_members(
            class,
            ClassFrame {
                home: c.clone(),
                ..frame
            },
        );
        let mut body = std::mem::take(&mut self.pre);
        body.push(Expr::var(c));
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

    /// The methods and accessors: on the prototype, or on the class `c` when static.
    fn define_methods(&mut self, class: &'a Class<'a>, frame: &ClassFrame, c: &str) {
        self.frame.class = Some(frame.clone());
        for element in &class.body.body {
            let ClassElement::MethodDefinition(method) = element else {
                continue;
            };
            if method.kind == MethodDefinitionKind::Constructor || method.value.body.is_none() {
                continue;
            }
            let home = if method.r#static {
                c.to_owned()
            } else {
                frame.home.clone()
            };
            let key = self.property_key(&method.key, method.computed);
            let method_frame = ClassFrame {
                home: home.clone(),
                ..frame.clone()
            };
            let fun = self.function_fun(&method.value, Some(method_frame));
            let value = self.bind(Expr::call("bouy_ref", "fn", vec![fun]));
            let function = match method.kind {
                MethodDefinitionKind::Get => "define_getter",
                MethodDefinitionKind::Set => "define_setter",
                _ => "define_method",
            };
            self.pre.push(Expr::call(
                "bouy_ref",
                function,
                vec![Expr::var(home), key, value],
            ));
        }
    }

    /// The static fields and blocks in order, with `this` the class.
    fn static_members(&mut self, class: &'a Class<'a>, frame: ClassFrame) {
        let c = frame.home.clone();
        self.frame.this = Some(c.clone());
        self.frame.class = Some(frame);
        for element in &class.body.body {
            match element {
                ClassElement::PropertyDefinition(property) if property.r#static => {
                    self.define_field(&c, property);
                }
                ClassElement::StaticBlock(block) => {
                    let code =
                        self.stmts(block.body.iter().collect(), &super::Cont::Value(Expr::ok()));
                    self.pre.extend(code);
                }
                ClassElement::AccessorProperty(accessor) => {
                    self.unsupported(accessor.span, "`accessor` fields");
                }
                _ => {}
            }
        }
    }

    /// `define_field(This, Key, Value)` for a field of the class.
    fn define_field(&mut self, this: &str, property: &'a PropertyDefinition<'a>) {
        let key = self.property_key(&property.key, property.computed);
        let value = match &property.value {
            Some(value) => self.expr(value),
            None => Expr::undefined(),
        };
        self.pre.push(Expr::call(
            "bouy_ref",
            "define_field",
            vec![Expr::var(this.to_owned()), key, value],
        ));
    }

    /// The instance fields of the class, defined on `this`.
    fn init_fields(&mut self, class: &'a Class<'a>, this: &str) {
        for element in &class.body.body {
            if let ClassElement::PropertyDefinition(property) = element
                && !property.r#static
            {
                self.define_field(this, property);
            }
        }
    }

    /// The [[Construct]] of the class: `fun(NewTarget, Args) -> This end`.
    fn construct_fun(
        &mut self,
        class: &'a Class<'a>,
        constructor: Option<&'a oxc::ast::ast::MethodDefinition<'a>>,
        frame: &ClassFrame,
    ) -> Expr {
        let new_target = self.fresh("NewTarget");
        let args = self.fresh("Args");
        let outer = std::mem::take(&mut self.frame);
        let outer_pre = std::mem::take(&mut self.pre);
        let parent = frame.parent.clone();
        self.frame = Frame {
            ret: Ret::Constructor,
            kind: Kind::Sync,
            class: Some(ClassFrame {
                new_target: Some(new_target.clone()),
                ..frame.clone()
            }),
            ..Frame::default()
        };
        let code = match (&parent, constructor) {
            (None, _) => {
                let this = self.fresh("This");
                self.pre.push(Expr::matches(
                    Expr::var(this.clone()),
                    Expr::call("bouy_ref", "new_this", vec![Expr::var(new_target.clone())]),
                ));
                self.frame.this = Some(this.clone());
                self.init_fields(class, &this);
                let mut code = std::mem::take(&mut self.pre);
                if let Some(constructor) = constructor {
                    code.extend(self.constructor_body(constructor, &args));
                } else {
                    code.push(Expr::var(this));
                }
                code
            }
            (Some(parent), None) => {
                let this = self.fresh("This");
                self.pre.push(Expr::matches(
                    Expr::var(this.clone()),
                    Expr::call(
                        "bouy_ref",
                        "super_construct",
                        vec![
                            Expr::var(parent.clone()),
                            Expr::var(args.clone()),
                            Expr::var(new_target.clone()),
                        ],
                    ),
                ));
                self.frame.this = Some(this.clone());
                self.init_fields(class, &this);
                let mut code = std::mem::take(&mut self.pre);
                code.push(Expr::var(this));
                code
            }
            (Some(_), Some(constructor)) => self.constructor_body(constructor, &args),
        };
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

    /// The parameters, the parameter properties, and the body of a constructor.
    fn constructor_body(
        &mut self,
        constructor: &'a oxc::ast::ast::MethodDefinition<'a>,
        args: &str,
    ) -> Vec<Expr> {
        let function = &constructor.value;
        let mut code = self.params(&function.params, args);
        for param in &function.params.items {
            if param.accessibility.is_none() && !param.readonly {
                continue;
            }
            if let BindingPattern::BindingIdentifier(id) = &param.pattern
                && let Some(symbol) = id.symbol_id.get()
            {
                let value = self.read_symbol(symbol, param.span);
                let this = self.this_expr();
                self.pre.push(Expr::call(
                    "bouy_ref",
                    "define_field",
                    vec![this, Expr::binary(id.name.to_string()), value],
                ));
            }
        }
        code.append(&mut self.pre);
        if let Some(body) = &function.body {
            let saved = self.frame.kind;
            code.extend(self.body_of(FnBody::Block(body)));
            self.frame.kind = saved;
        }
        code
    }

    fn body_of(&mut self, body: FnBody<'a>) -> Vec<Expr> {
        match body {
            FnBody::Block(block) => {
                self.stmts(block.statements.iter().collect(), &super::Cont::Return)
            }
            FnBody::Expr(expression) => {
                let value = self.expr(expression);
                let mut code = std::mem::take(&mut self.pre);
                code.push(self.ret(value));
                code
            }
        }
    }

    /// `super(...args)` in a derived constructor: the parent constructs `this`, then the
    /// fields of this class are defined on it.
    pub fn super_constructor_call(&mut self, args: Expr) -> Expr {
        let Some(class) = self.frame.class.clone() else {
            return Expr::undefined();
        };
        let (Some(parent), Some(new_target)) = (class.parent.clone(), class.new_target.clone())
        else {
            self.reporter.report(
                class.span,
                crate::diagnostic::Code::Unsupported,
                "`super(...)` outside a derived constructor is not supported by the reference-semantics prototype",
            );
            return Expr::undefined();
        };
        let this = self.fresh("This");
        self.pre.push(Expr::matches(
            Expr::var(this.clone()),
            Expr::call(
                "bouy_ref",
                "super_construct",
                vec![Expr::var(parent), args, Expr::var(new_target)],
            ),
        ));
        self.frame.this = Some(this.clone());
        if let Some(class_node) = self.class_node(class.span) {
            self.init_fields(class_node, &this);
        }
        Expr::undefined()
    }

    /// The class at `span`, to find its instance fields.
    fn class_node(&self, span: oxc::span::Span) -> Option<&'a Class<'a>> {
        self.semantic
            .nodes()
            .iter()
            .find_map(|node| match node.kind() {
                oxc::ast::AstKind::Class(class) if class.span == span => Some(class),
                _ => None,
            })
    }

    pub fn super_method_call(&mut self, key: Expr, args: Expr) -> Expr {
        let Some(home) = self.frame.class.as_ref().map(|class| class.home.clone()) else {
            return Expr::undefined();
        };
        let this = self.this_expr();
        self.bind(Expr::call(
            "bouy_ref",
            "super_call",
            vec![Expr::var(home), key, this, args],
        ))
    }

    pub fn super_get(&mut self, key: Expr) -> Expr {
        let Some(home) = self.frame.class.as_ref().map(|class| class.home.clone()) else {
            return Expr::undefined();
        };
        let this = self.this_expr();
        self.bind(Expr::call(
            "bouy_ref",
            "super_get",
            vec![Expr::var(home), key, this],
        ))
    }
}
