//! Expressions in A-normal form: each operation binds a fresh variable in `pre`, so the
//! Erlang code runs the operations in the order of JavaScript.

use oxc::ast::ast::{
    Argument, ArrayExpression, ArrayExpressionElement, ArrowFunctionExpression,
    AssignmentExpression, AssignmentTarget, BinaryExpression, CallExpression, ChainElement,
    ChainExpression, ComputedMemberExpression, ConditionalExpression, Expression, Function,
    IdentifierReference, LogicalExpression, NewExpression, ObjectExpression, ObjectPropertyKind,
    PrivateFieldExpression, PropertyKey, PropertyKind, SimpleAssignmentTarget,
    StaticMemberExpression, TemplateLiteral, UnaryExpression, UpdateExpression,
};
use oxc::semantic::SymbolId;
use oxc::span::{GetSpan, Span};
use oxc::syntax::operator::{
    AssignmentOperator, BinaryOperator, LogicalOperator, UnaryOperator, UpdateOperator,
};

use super::{Callee, FnBody, Kind, Local, Lowerer, Top, capitalize, cell_get, cell_set, kind_of};
use crate::erlang::{CatchClause, Clause, Expr};

const OBJECT_PROTO: &str = "Object.prototype";
const CHAIN: &str = "$bouy_chain";

/// The key of a member expression: known at compile time, or a value to convert.
#[derive(Debug, Clone)]
pub enum MemberKey {
    Static(Expr),
    Dynamic(Expr),
}

impl<'a> Lowerer<'a, '_> {
    pub fn expr(&mut self, expression: &'a Expression<'a>) -> Expr {
        match expression {
            Expression::BooleanLiteral(literal) => Expr::atom(literal.value.to_string()),
            Expression::NullLiteral(_) => Expr::atom("null"),
            Expression::NumericLiteral(literal) => number(literal.value),
            Expression::StringLiteral(literal) => Expr::binary(literal.value.as_str()),
            Expression::TemplateLiteral(template) => self.template(template),
            Expression::Identifier(ident) => self.identifier(ident),
            Expression::ThisExpression(_) => self.this_expr(),
            Expression::ArrayExpression(array) => self.array(array),
            Expression::ObjectExpression(object) => self.object(object),
            Expression::ArrowFunctionExpression(arrow) => self.arrow(arrow),
            Expression::FunctionExpression(function) => self.function_expression(function),
            Expression::AssignmentExpression(assignment) => self.assign(assignment),
            Expression::UpdateExpression(update) => self.update(update),
            Expression::AwaitExpression(expression) => {
                if self.frame.kind != Kind::Async {
                    return self.unsupported(expression.span, "`await` outside an async function");
                }
                let value = self.expr(&expression.argument);
                self.marker("await", value)
            }
            Expression::YieldExpression(expression) => {
                if expression.delegate {
                    return self.unsupported(expression.span, "`yield*`");
                }
                let value = match &expression.argument {
                    Some(argument) => self.expr(argument),
                    None => Expr::undefined(),
                };
                self.marker("yield", value)
            }
            Expression::BinaryExpression(binary) => self.binary(binary),
            Expression::LogicalExpression(logical) => self.logical(logical),
            Expression::ConditionalExpression(conditional) => self.conditional(conditional),
            Expression::SequenceExpression(sequence) => {
                let Some((last, init)) = sequence.expressions.split_last() else {
                    return Expr::undefined();
                };
                for item in init {
                    self.effect(item);
                }
                self.expr(last)
            }
            Expression::UnaryExpression(unary) => self.unary(unary),
            Expression::CallExpression(call) => self.call(call),
            Expression::NewExpression(new) => self.new_expression(new),
            Expression::ChainExpression(chain) => self.chain(chain),
            Expression::ParenthesizedExpression(inner) => self.expr(&inner.expression),
            Expression::TSAsExpression(inner) => self.expr(&inner.expression),
            Expression::TSSatisfiesExpression(inner) => self.expr(&inner.expression),
            Expression::TSNonNullExpression(inner) => self.expr(&inner.expression),
            Expression::TSTypeAssertion(inner) => self.expr(&inner.expression),
            Expression::TSInstantiationExpression(inner) => self.expr(&inner.expression),
            Expression::StaticMemberExpression(member) => self.static_member(member),
            Expression::ComputedMemberExpression(member) => self.computed_member(member),
            Expression::PrivateFieldExpression(member) => self.private_member(member),
            other => self.unsupported(other.span(), "this syntax"),
        }
    }

    /// Lowers an expression for its effects only.
    pub fn effect(&mut self, expression: &'a Expression<'a>) {
        let value = self.expr(expression);
        if !value.is_trivial() {
            self.pre.push(value);
        }
    }

    /// The Erlang boolean of a condition: the value itself when it is already a boolean.
    pub fn test(&mut self, expression: &'a Expression<'a>) -> Expr {
        let value = self.expr(expression);
        if is_boolean(expression) {
            return value;
        }
        Expr::call("bouy_ref", "truthy", vec![value])
    }

    fn template(&mut self, template: &'a TemplateLiteral<'a>) -> Expr {
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

    pub fn identifier(&mut self, ident: &'a IdentifierReference<'a>) -> Expr {
        match self.symbol_of(ident.reference_id.get()) {
            Some(symbol) => self.read_symbol(symbol, ident.span),
            None => match ident.name.as_str() {
                "undefined" => Expr::undefined(),
                "NaN" => Expr::atom("NaN"),
                "Infinity" => Expr::atom("Infinity"),
                name => self.bind(Expr::call(
                    "bouy_ref",
                    "global",
                    vec![Expr::binary(name.to_owned())],
                )),
            },
        }
    }

    pub fn read_symbol(&mut self, symbol: SymbolId, span: Span) -> Expr {
        if let Some(local) = self.frame.env.get(&symbol) {
            return match local.clone() {
                Local::Var(name) => Expr::var(name),
                Local::Cell(name) => self.bind(cell_get(&name)),
            };
        }
        match self.tops.get(&symbol).cloned() {
            Some(Top::Function(name)) => self.static_function(&name),
            Some(Top::Class(name)) => {
                self.bind(Expr::local_call("$class", vec![Expr::binary(name)]))
            }
            Some(Top::Var(name)) => self.bind(Expr::local_call(&format!("$get_{name}"), vec![])),
            Some(Top::Literal(value)) => value,
            Some(Top::Bouy(_)) => self.unsupported(span, "a function of \"bouy\" used as a value"),
            None => self.unsupported(
                span,
                "a reference to a local variable before its declaration",
            ),
        }
    }

    /// Stores `value` in the variable `symbol` and returns the stored value.
    pub fn assign_symbol(&mut self, symbol: SymbolId, value: Expr, span: Span) -> Expr {
        if let Some(local) = self.frame.env.get(&symbol).cloned() {
            return match local {
                Local::Var(_) => {
                    let name = self.symbol_var(symbol);
                    self.pre.push(Expr::matches(Expr::var(name.clone()), value));
                    self.frame.env.insert(symbol, Local::Var(name.clone()));
                    Expr::var(name)
                }
                Local::Cell(cell) => self.bind(cell_set(&cell, value)),
            };
        }
        match self.tops.get(&symbol).cloned() {
            Some(Top::Var(name)) => {
                let value = self.bind(value);
                let key = self.var_key(&name);
                self.pre.push(Expr::call(
                    "erlang",
                    "put",
                    vec![key, Expr::tagged("v", value.clone())],
                ));
                value
            }
            _ => self.unsupported(span, "an assignment to this name"),
        }
    }

    /// Declares `symbol` with `value`: a version, a cell, or a module variable.
    pub fn declare_symbol(&mut self, symbol: SymbolId, value: Expr) {
        match self.tops.get(&symbol).cloned() {
            Some(Top::Var(name)) => {
                let value = self.bind(value);
                let key = self.var_key(&name);
                self.pre.push(Expr::call(
                    "erlang",
                    "put",
                    vec![key, Expr::tagged("v", value)],
                ));
                return;
            }
            Some(Top::Literal(_)) => return,
            _ => {}
        }
        if self.analysis.cells.contains(&symbol) {
            let cell = self.fresh("Cell");
            self.pre.push(Expr::matches(
                Expr::var(cell.clone()),
                Expr::call("bouy_heap", "cell", vec![value]),
            ));
            self.frame.env.insert(symbol, Local::Cell(cell));
            return;
        }
        if let Expr::Var(name) = &value {
            self.frame.env.insert(symbol, Local::Var(name.clone()));
            return;
        }
        let name = self.symbol_var(symbol);
        self.pre.push(Expr::matches(Expr::var(name.clone()), value));
        self.frame.env.insert(symbol, Local::Var(name));
    }

    fn symbol_var(&mut self, symbol: SymbolId) -> String {
        let name = self.semantic.scoping().symbol_name(symbol).to_owned();
        self.fresh(&capitalize(&name))
    }

    fn array(&mut self, array: &'a ArrayExpression<'a>) -> Expr {
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

    fn object(&mut self, object: &'a ObjectExpression<'a>) -> Expr {
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

    /// The function value of an object literal method: its own `this`.
    fn method_value(&mut self, value: &'a Expression<'a>) -> Expr {
        match value {
            Expression::FunctionExpression(function) => {
                let fun = self.function_fun(function, None);
                self.bind(Expr::call("bouy_ref", "fn", vec![fun]))
            }
            other => self.expr(other),
        }
    }

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
            Expr::binary(class),
            Expr::binary(name.to_owned()),
        ])
    }

    fn arrow(&mut self, arrow: &'a ArrowFunctionExpression<'a>) -> Expr {
        let body = match (arrow.get_expression(), arrow.get_function_body()) {
            (Some(expression), _) => FnBody::Expr(expression),
            (None, Some(body)) => FnBody::Block(body),
            (None, None) => return Expr::undefined(),
        };
        let (this_param, args, code) = self.function_code(
            &arrow.params,
            body,
            kind_of(arrow.r#async, false),
            Callee::Arrow,
        );
        let fun = fun2(this_param, args, code);
        self.bind(Expr::call("bouy_ref", "fn", vec![fun]))
    }

    fn function_expression(&mut self, function: &'a Function<'a>) -> Expr {
        let fun = self.function_fun(function, None);
        let name = function
            .id
            .as_ref()
            .map_or_else(String::new, |id| id.name.to_string());
        let length = function
            .params
            .items
            .iter()
            .take_while(|param| param.initializer.is_none())
            .count();
        self.bind(Expr::call(
            "bouy_ref",
            "named_fn",
            vec![
                fun,
                Expr::binary(name),
                Expr::Integer(i64::try_from(length).unwrap_or(0)),
            ],
        ))
    }

    /// The Erlang fun of a non-arrow function: `fun(This, Args) -> ... end`.
    pub fn function_fun(
        &mut self,
        function: &'a Function<'a>,
        class: Option<super::ClassFrame>,
    ) -> Expr {
        let Some(body) = &function.body else {
            return Expr::undefined();
        };
        let (this_param, args, code) = self.function_code(
            &function.params,
            FnBody::Block(body),
            kind_of(function.r#async, function.generator),
            Callee::Function(class),
        );
        fun2(this_param, args, code)
    }

    fn assign(&mut self, assignment: &'a AssignmentExpression<'a>) -> Expr {
        match &assignment.left {
            AssignmentTarget::ArrayAssignmentTarget(_)
            | AssignmentTarget::ObjectAssignmentTarget(_) => {
                let value = self.expr(&assignment.right);
                let value = self.bind(value);
                self.assign_target(&assignment.left, value.clone());
                value
            }
            other => match other.as_simple_assignment_target() {
                Some(target) => self.assign_simple(target, assignment.operator, &assignment.right),
                None => self.unsupported(assignment.span, "this assignment"),
            },
        }
    }

    fn assign_simple(
        &mut self,
        target: &'a SimpleAssignmentTarget<'a>,
        operator: AssignmentOperator,
        right: &'a Expression<'a>,
    ) -> Expr {
        match target {
            SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => {
                let Some(symbol) = self.symbol_of(ident.reference_id.get()) else {
                    return self.unsupported(ident.span, "an assignment to a global");
                };
                if operator == AssignmentOperator::Assign {
                    let value = self.expr(right);
                    return self.assign_symbol(symbol, value, ident.span);
                }
                let current = self.read_symbol(symbol, ident.span);
                let value = self.combine(operator, current, right);
                self.assign_symbol(symbol, value, ident.span)
            }
            SimpleAssignmentTarget::TSAsExpression(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            SimpleAssignmentTarget::TSSatisfiesExpression(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            SimpleAssignmentTarget::TSNonNullExpression(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            SimpleAssignmentTarget::TSTypeAssertion(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            other => match other.as_member_expression() {
                Some(member) => {
                    let (object, key) = self.member_parts(member);
                    self.assign_member(object, key, operator, right)
                }
                None => self.unsupported(other.span(), "this assignment target"),
            },
        }
    }

    fn assign_expression(
        &mut self,
        target: &'a Expression<'a>,
        operator: AssignmentOperator,
        right: &'a Expression<'a>,
    ) -> Expr {
        match target {
            Expression::StaticMemberExpression(_)
            | Expression::ComputedMemberExpression(_)
            | Expression::PrivateFieldExpression(_) => {
                let Some(member) = target.as_member_expression() else {
                    return Expr::undefined();
                };
                let (object, key) = self.member_parts(member);
                self.assign_member(object, key, operator, right)
            }
            Expression::ParenthesizedExpression(inner) => {
                self.assign_expression(&inner.expression, operator, right)
            }
            Expression::Identifier(ident) => {
                let Some(symbol) = self.symbol_of(ident.reference_id.get()) else {
                    return self.unsupported(ident.span, "an assignment to a global");
                };
                if operator == AssignmentOperator::Assign {
                    let value = self.expr(right);
                    return self.assign_symbol(symbol, value, ident.span);
                }
                let current = self.read_symbol(symbol, ident.span);
                let value = self.combine(operator, current, right);
                self.assign_symbol(symbol, value, ident.span)
            }
            other => self.unsupported(other.span(), "this assignment target"),
        }
    }

    fn assign_member(
        &mut self,
        object: Expr,
        key: MemberKey,
        operator: AssignmentOperator,
        right: &'a Expression<'a>,
    ) -> Expr {
        if operator == AssignmentOperator::Assign {
            let value = self.expr(right);
            let value = self.bind(value);
            self.set(object, key, value.clone());
            return value;
        }
        let key = self.fix_key(key);
        let current = self.get(object.clone(), key.clone());
        let value = self.combine(operator, current, right);
        let value = self.bind(value);
        self.set(object, key, value.clone());
        value
    }

    /// The new value of a compound assignment `x op= right`, from the current value.
    fn combine(
        &mut self,
        operator: AssignmentOperator,
        current: Expr,
        right: &'a Expression<'a>,
    ) -> Expr {
        let logical = match operator {
            AssignmentOperator::LogicalAnd => Some(LogicalOperator::And),
            AssignmentOperator::LogicalOr => Some(LogicalOperator::Or),
            AssignmentOperator::LogicalNullish => Some(LogicalOperator::Coalesce),
            _ => None,
        };
        if let Some(logical) = logical {
            let other = self.branch(|me| me.expr(right));
            return self.bind(logical_case(logical, current, other, false));
        }
        let value = self.expr(right);
        let function = match operator {
            AssignmentOperator::Addition => "add",
            AssignmentOperator::Subtraction => "sub",
            AssignmentOperator::Multiplication => "mul",
            AssignmentOperator::Division => "divide",
            AssignmentOperator::Remainder => "remainder",
            AssignmentOperator::Exponential => "power",
            AssignmentOperator::ShiftLeft => "shift_left",
            AssignmentOperator::ShiftRight => "shift_right",
            AssignmentOperator::ShiftRightZeroFill => "shift_right_unsigned",
            AssignmentOperator::BitwiseOR => "bit_or",
            AssignmentOperator::BitwiseXOR => "bit_xor",
            _ => "bit_and",
        };
        self.bind(Expr::call("bouy_ref", function, vec![current, value]))
    }

    fn update(&mut self, update: &'a UpdateExpression<'a>) -> Expr {
        let function = match update.operator {
            UpdateOperator::Increment => "increment",
            UpdateOperator::Decrement => "decrement",
        };
        match &update.argument {
            SimpleAssignmentTarget::AssignmentTargetIdentifier(ident) => {
                let Some(symbol) = self.symbol_of(ident.reference_id.get()) else {
                    return self.unsupported(ident.span, "an update of a global");
                };
                let old = self.read_symbol(symbol, ident.span);
                let old = self.bind(old);
                let new = self.bind(Expr::call("bouy_ref", function, vec![old.clone()]));
                let new = self.assign_symbol(symbol, new, ident.span);
                if update.prefix { new } else { old }
            }
            other => match other.as_member_expression() {
                Some(member) => {
                    let (object, key) = self.member_parts(member);
                    let key = self.fix_key(key);
                    let old = self.get(object.clone(), key.clone());
                    let new = self.bind(Expr::call("bouy_ref", function, vec![old.clone()]));
                    self.set(object, key, new.clone());
                    if update.prefix { new } else { old }
                }
                None => self.unsupported(update.span, "this update"),
            },
        }
    }

    fn binary(&mut self, binary: &'a BinaryExpression<'a>) -> Expr {
        let left = self.expr(&binary.left);
        let right = self.expr(&binary.right);
        let call = |function: &str, args: Vec<Expr>| Expr::call("bouy_ref", function, args);
        let value = match binary.operator {
            BinaryOperator::StrictEquality => strict_eq(left, right),
            BinaryOperator::StrictInequality => Expr::not(strict_eq(left, right)),
            BinaryOperator::Equality => call("loose_eq", vec![left, right]),
            BinaryOperator::Inequality => Expr::not(call("loose_eq", vec![left, right])),
            BinaryOperator::LessThan => call("lt", vec![left, right]),
            BinaryOperator::LessEqualThan => call("le", vec![left, right]),
            BinaryOperator::GreaterThan => call("gt", vec![left, right]),
            BinaryOperator::GreaterEqualThan => call("ge", vec![left, right]),
            BinaryOperator::Addition => call("add", vec![left, right]),
            BinaryOperator::Subtraction => call("sub", vec![left, right]),
            BinaryOperator::Multiplication => call("mul", vec![left, right]),
            BinaryOperator::Division => call("divide", vec![left, right]),
            BinaryOperator::Remainder => call("remainder", vec![left, right]),
            BinaryOperator::Exponential => call("power", vec![left, right]),
            BinaryOperator::ShiftLeft => call("shift_left", vec![left, right]),
            BinaryOperator::ShiftRight => call("shift_right", vec![left, right]),
            BinaryOperator::ShiftRightZeroFill => call("shift_right_unsigned", vec![left, right]),
            BinaryOperator::BitwiseOR => call("bit_or", vec![left, right]),
            BinaryOperator::BitwiseXOR => call("bit_xor", vec![left, right]),
            BinaryOperator::BitwiseAnd => call("bit_and", vec![left, right]),
            BinaryOperator::In => call("in", vec![left, right]),
            BinaryOperator::Instanceof => call("instance_of", vec![left, right]),
        };
        self.bind(value)
    }

    fn logical(&mut self, logical: &'a LogicalExpression<'a>) -> Expr {
        let left = self.expr(&logical.left);
        let left = self.bind(left);
        let right = self.branch(|me| me.expr(&logical.right));
        let boolean = is_boolean(&logical.left);
        self.bind(logical_case(logical.operator, left, right, boolean))
    }

    fn conditional(&mut self, conditional: &'a ConditionalExpression<'a>) -> Expr {
        let test = self.test(&conditional.test);
        let yes = self.branch(|me| me.expr(&conditional.consequent));
        let no = self.branch(|me| me.expr(&conditional.alternate));
        self.bind(super::boolean_case(test, yes, no))
    }

    fn unary(&mut self, unary: &'a UnaryExpression<'a>) -> Expr {
        match unary.operator {
            UnaryOperator::LogicalNot => {
                let test = self.test(&unary.argument);
                self.bind(Expr::not(test))
            }
            UnaryOperator::UnaryNegation => {
                if let Expression::NumericLiteral(literal) = &unary.argument {
                    return number(-literal.value);
                }
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("bouy_ref", "negate", vec![value]))
            }
            UnaryOperator::UnaryPlus => {
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("bouy_ref", "plus", vec![value]))
            }
            UnaryOperator::BitwiseNot => {
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("bouy_ref", "bit_not", vec![value]))
            }
            UnaryOperator::Typeof => {
                if let Expression::Identifier(ident) = &unary.argument
                    && self.symbol_of(ident.reference_id.get()).is_none()
                    && !matches!(ident.name.as_str(), "undefined" | "NaN" | "Infinity")
                {
                    let name = Expr::binary(ident.name.to_string());
                    return self.bind(Expr::call("bouy_ref", "typeof_global", vec![name]));
                }
                let value = self.expr(&unary.argument);
                self.bind(Expr::call("bouy_ref", "typeof", vec![value]))
            }
            UnaryOperator::Void => {
                self.effect(&unary.argument);
                Expr::undefined()
            }
            UnaryOperator::Delete => match unary.argument.as_member_expression() {
                Some(member) => {
                    let (object, key) = self.member_parts(member);
                    let value = match key {
                        MemberKey::Static(key) => {
                            Expr::call("bouy_ref", "delete", vec![object, key])
                        }
                        MemberKey::Dynamic(key) => {
                            Expr::call("bouy_ref", "delete_computed", vec![object, key])
                        }
                    };
                    self.bind(value)
                }
                None => Expr::atom("true"),
            },
        }
    }

    pub fn args(&mut self, arguments: &'a [Argument<'a>]) -> Expr {
        let spread = arguments
            .iter()
            .any(|argument| matches!(argument, Argument::SpreadElement(_)));
        if !spread {
            let items = arguments
                .iter()
                .map(|argument| match argument.as_expression() {
                    Some(expression) => self.expr(expression),
                    None => Expr::undefined(),
                })
                .collect();
            return Expr::List(items);
        }
        let parts = arguments
            .iter()
            .map(|argument| match argument {
                Argument::SpreadElement(spread) => {
                    let value = self.expr(&spread.argument);
                    self.bind(Expr::call("bouy_ref", "to_list", vec![value]))
                }
                other => match other.as_expression() {
                    Some(expression) => Expr::List(vec![self.expr(expression)]),
                    None => Expr::List(vec![]),
                },
            })
            .collect();
        self.bind(Expr::call("lists", "append", vec![Expr::List(parts)]))
    }

    pub fn call(&mut self, call: &'a CallExpression<'a>) -> Expr {
        let callee = strip(&call.callee);
        if let Expression::Super(_) = callee {
            let args = self.args(&call.arguments);
            return self.super_constructor_call(args);
        }
        if let Some(member) = callee.as_member_expression() {
            if let Expression::Super(_) = member.object() {
                let key = match self.member_key(member) {
                    MemberKey::Static(key) => key,
                    MemberKey::Dynamic(value) => {
                        self.bind(Expr::call("bouy_ref", "to_property_key", vec![value]))
                    }
                };
                let args = self.args(&call.arguments);
                return self.super_method_call(key, args);
            }
            let (object, key) = self.member_parts(member);
            if call.optional {
                let key = self.fix_key(key);
                let method = self.get(object.clone(), key);
                self.chain_guard(method.clone());
                let args = self.args(&call.arguments);
                return self.bind(Expr::call("bouy_ref", "call", vec![method, object, args]));
            }
            let args = self.args(&call.arguments);
            let value = match key {
                MemberKey::Static(key) => {
                    Expr::call("bouy_ref", "call_method", vec![object, key, args])
                }
                MemberKey::Dynamic(key) => {
                    Expr::call("bouy_ref", "call_method_computed", vec![object, key, args])
                }
            };
            return self.bind(value);
        }
        if let Expression::Identifier(ident) = callee
            && let Some(symbol) = self.symbol_of(ident.reference_id.get())
            && !self.frame.env.contains_key(&symbol)
        {
            match self.tops.get(&symbol).cloned() {
                Some(Top::Function(name)) if !call.optional => {
                    let args = self.args(&call.arguments);
                    return self.bind(Expr::local_call(&name, vec![Expr::undefined(), args]));
                }
                Some(Top::Bouy(name)) => return self.bouy_call(&name, call),
                _ => {}
            }
        }
        let function = self.expr(callee);
        if call.optional {
            self.chain_guard(function.clone());
        }
        let args = self.args(&call.arguments);
        self.bind(Expr::call(
            "bouy_ref",
            "call",
            vec![function, Expr::undefined(), args],
        ))
    }

    /// A function imported from "bouy".
    fn bouy_call(&mut self, name: &str, call: &'a CallExpression<'a>) -> Expr {
        match name {
            "spawn" => {
                let class = match call.arguments.first().and_then(Argument::as_expression) {
                    Some(Expression::Identifier(ident)) => self
                        .symbol_of(ident.reference_id.get())
                        .and_then(|symbol| self.tops.get(&symbol).cloned()),
                    _ => None,
                };
                let Some(Top::Class(class)) = class else {
                    return self.unsupported(
                        call.span,
                        "`spawn` of a value that is not a module-level class",
                    );
                };
                let options = match call.arguments.get(1).and_then(Argument::as_expression) {
                    Some(options) => self.expr(options),
                    None => Expr::undefined(),
                };
                self.bind(Expr::call(
                    "bouy_jobs",
                    "spawn_actor",
                    vec![
                        Expr::Tuple(vec![Expr::atom(self.module.clone()), Expr::binary(class)]),
                        Expr::call("bouy_ref", "spawn_args", vec![options]),
                    ],
                ))
            }
            "stop" => {
                let args = self.args(&call.arguments);
                self.bind(Expr::call("bouy_ref", "stop_actor", vec![args]))
            }
            "heapStats" => self.bind(Expr::call("bouy_ref", "heap_stats", vec![])),
            "vmMemory" => self.bind(Expr::call("bouy_ref", "vm_memory", vec![])),
            other => self.unsupported(call.span, &format!("`{other}` from \"bouy\"")),
        }
    }

    fn new_expression(&mut self, new: &'a NewExpression<'a>) -> Expr {
        let constructor = self.expr(&new.callee);
        let args = self.args(&new.arguments);
        self.bind(Expr::call("bouy_ref", "construct", vec![constructor, args]))
    }

    fn chain(&mut self, chain: &'a ChainExpression<'a>) -> Expr {
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
    fn chain_guard(&mut self, value: Expr) {
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

    fn member_key(&mut self, member: &'a oxc::ast::ast::MemberExpression<'a>) -> MemberKey {
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

    fn computed_key(&mut self, expression: &'a Expression<'a>) -> MemberKey {
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

    pub fn set(&mut self, object: Expr, key: MemberKey, value: Expr) {
        let call = match key {
            MemberKey::Static(key) => Expr::call("bouy_ref", "set", vec![object, key, value]),
            MemberKey::Dynamic(key) => {
                Expr::call("bouy_ref", "set_computed", vec![object, key, value])
            }
        };
        self.pre.push(call);
    }
}

/// `{'$o', Name}`: an intrinsic object.
pub fn intrinsic(name: &str) -> Expr {
    Expr::Tuple(vec![Expr::atom("$o"), Expr::atom(name)])
}

fn fun2(this: String, args: String, body: Vec<Expr>) -> Expr {
    Expr::Fun {
        name: None,
        clauses: vec![Clause {
            patterns: vec![Expr::var(this), Expr::var(args)],
            guards: vec![],
            body,
        }],
    }
}

/// The keys of an object literal that `bouy_heap:literal/3` can build: every property a
/// plain `key: value` or method with a distinct string key that is not an array index.
fn literal_keys(object: &ObjectExpression<'_>) -> Option<Vec<String>> {
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

/// A property key known at compile time: an array index is an integer.
pub fn static_key(name: &str) -> Expr {
    match index_of(name) {
        Some(index) => Expr::Integer(index),
        None => Expr::binary(name.to_owned()),
    }
}

fn index_of(name: &str) -> Option<i64> {
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

/// `===`: inline for atoms and binaries, whose equality is term equality.
fn strict_eq(left: Expr, right: Expr) -> Expr {
    let simple =
        |e: &Expr| matches!(e, Expr::Atom(name) if name != "NaN") || matches!(e, Expr::Binary(_));
    if simple(&left) || simple(&right) {
        return Expr::op("=:=", left, right);
    }
    Expr::call("bouy_ref", "strict_eq", vec![left, right])
}

fn logical_case(operator: LogicalOperator, left: Expr, right: Vec<Expr>, boolean: bool) -> Expr {
    let truthy = if boolean {
        left.clone()
    } else {
        Expr::call("bouy_ref", "truthy", vec![left.clone()])
    };
    match operator {
        LogicalOperator::And => super::boolean_case(truthy, right, vec![left]),
        LogicalOperator::Or => super::boolean_case(truthy, vec![left], right),
        LogicalOperator::Coalesce => Expr::case(
            left.clone(),
            vec![
                Clause::new(Expr::undefined(), right.clone()),
                Clause::new(Expr::atom("null"), right),
                Clause::new(Expr::var("_"), vec![left]),
            ],
        ),
    }
}

/// Whether the expression always yields an Erlang boolean.
pub fn is_boolean(expression: &Expression<'_>) -> bool {
    match expression {
        Expression::BooleanLiteral(_) => true,
        Expression::BinaryExpression(binary) => matches!(
            binary.operator,
            BinaryOperator::StrictEquality
                | BinaryOperator::StrictInequality
                | BinaryOperator::Equality
                | BinaryOperator::Inequality
                | BinaryOperator::LessThan
                | BinaryOperator::LessEqualThan
                | BinaryOperator::GreaterThan
                | BinaryOperator::GreaterEqualThan
                | BinaryOperator::In
                | BinaryOperator::Instanceof
        ),
        Expression::UnaryExpression(unary) => unary.operator == UnaryOperator::LogicalNot,
        Expression::LogicalExpression(logical) => {
            logical.operator != LogicalOperator::Coalesce
                && is_boolean(&logical.left)
                && is_boolean(&logical.right)
        }
        Expression::ParenthesizedExpression(inner) => is_boolean(&inner.expression),
        _ => false,
    }
}

/// The expression without parentheses and type assertions.
pub fn strip<'r, 'a>(expression: &'r Expression<'a>) -> &'r Expression<'a> {
    match expression {
        Expression::ParenthesizedExpression(inner) => strip(&inner.expression),
        Expression::TSAsExpression(inner) => strip(&inner.expression),
        Expression::TSSatisfiesExpression(inner) => strip(&inner.expression),
        Expression::TSNonNullExpression(inner) => strip(&inner.expression),
        Expression::TSTypeAssertion(inner) => strip(&inner.expression),
        Expression::TSInstantiationExpression(inner) => strip(&inner.expression),
        other => other,
    }
}
