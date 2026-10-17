//! Calls: argument lists with spread, method calls, calls of module functions and of
//! the functions of "bouy", and `new`.

use oxc::ast::ast::{Argument, CallExpression, Expression, NewExpression};

use super::context::{Lowerer, Top};
use super::expr::strip;
use super::member::MemberKey;
use crate::erlang::Expr;

impl<'a> Lowerer<'a, '_> {
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
                    self.bind(Expr::call("bouy_ref_iterator", "to_list", vec![value]))
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
            if !call.arguments.iter().all(is_pure) {
                // The method is read before the arguments run (ECMA-262 §13.3.6.1).
                let key = self.fix_key(key);
                let method = self.get(object.clone(), key.clone());
                let args = self.args(&call.arguments);
                let MemberKey::Static(key) = key else {
                    return Expr::undefined();
                };
                return self.bind(Expr::call(
                    "bouy_ref",
                    "call_method_value",
                    vec![method, object, key, args],
                ));
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
            && !call.optional
            && !self.with_objects(ident).is_empty()
        {
            let objects = self.with_objects(ident);
            let (function, this) = self.with_callee(ident, &objects);
            let args = self.args(&call.arguments);
            return self.bind(Expr::call("bouy_ref", "call", vec![function, this, args]));
        }
        if let Expression::Identifier(ident) = callee
            && ident.name == "eval"
            && !call.optional
            && self.symbol_of(ident.reference_id.get()).is_none()
        {
            // A direct eval. The runtime checks that `eval` is still the intrinsic.
            let eval = self.identifier_read(ident);
            let args = self.args(&call.arguments);
            let mode = Expr::atom(if self.frame.sloppy {
                "sloppy"
            } else {
                "strict"
            });
            let this = self.this_expr();
            return self.bind(Expr::call(
                "bouy_ref_eval",
                "direct",
                vec![eval, args, mode, this],
            ));
        }
        if let Expression::Identifier(ident) = callee
            && let Some(symbol) = self.symbol_of(ident.reference_id.get())
            && !self.frame.env.contains_key(&symbol)
        {
            match self.tops.get(&symbol).cloned() {
                Some(Top::Function { name, .. }) if !call.optional => {
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
    pub fn bouy_call(&mut self, name: &str, call: &'a CallExpression<'a>) -> Expr {
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

    pub fn new_expression(&mut self, new: &'a NewExpression<'a>) -> Expr {
        let constructor = self.expr(&new.callee);
        let args = self.args(&new.arguments);
        self.bind(Expr::call("bouy_ref", "construct", vec![constructor, args]))
    }
}

/// Whether an argument has no effect that the read of the method could observe: a literal,
/// a name, `this`, or a function.
fn is_pure(argument: &Argument<'_>) -> bool {
    match argument.as_expression().map(strip) {
        Some(
            Expression::NumericLiteral(_)
            | Expression::StringLiteral(_)
            | Expression::BooleanLiteral(_)
            | Expression::NullLiteral(_)
            | Expression::Identifier(_)
            | Expression::ThisExpression(_)
            | Expression::ArrowFunctionExpression(_)
            | Expression::FunctionExpression(_),
        ) => true,
        Some(Expression::TemplateLiteral(template)) => template.expressions.is_empty(),
        _ => false,
    }
}
