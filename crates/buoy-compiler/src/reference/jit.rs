//! The entries of the islands of the native tier (contract section 17.10): a function that
//! `crate::jit` found to be an island starts with
//!
//! ```erlang
//! case buoy_jit:enter(Module, Index, Args, fun() -> Checks, {Classes, [Global...]} end) of
//!     {ok, Value, [Written...]} -> <assign each written variable>, Value;
//!     _ -> <the Erlang code of the function>
//! end
//! ```
//!
//! The fun reads the values outside the island that its code uses, in the realm of the
//! call, and throws when a class or an intrinsic that the island relies on changed.
//! `Classes` lists each class of the island with the keys of its fields, so the entry can
//! copy the objects that the globals reach.

use oxc::span::Span;

use super::context::Lowerer;
use super::function::FnBody;
use crate::erlang::{Clause, Expr, Function};
use crate::jit::Global;

/// The call of `buoy_jit:enter/4` that starts an island, and the variables that a run
/// writes back.
pub struct JitEntry {
    enter: Expr,
    written: Vec<oxc::semantic::SymbolId>,
    span: Span,
}

impl Lowerer<'_, '_> {
    /// The call of `buoy_jit:enter/4` when `body` starts an island.
    pub fn jit_entry(&mut self, body: FnBody<'_>, args: &str) -> Option<JitEntry> {
        let FnBody::Block(block) = body else {
            return None;
        };
        let entry = self.jit.entries.get(&block.span.start)?.clone();
        let saved = std::mem::take(&mut self.pre);
        let mut checks = vec![Expr::call("buoy_jit", "intrinsics", vec![])];
        if entry.uses_math {
            let math = self.bind(Expr::call(
                "buoy_ref",
                "global",
                vec![Expr::js_string("Math")],
            ));
            checks.extend(std::mem::take(&mut self.pre));
            checks.push(Expr::call(
                "buoy_jit",
                "intrinsic",
                vec![math, Expr::atom("Math")],
            ));
        }
        let mut classes = Vec::with_capacity(entry.classes.len());
        let mut class_values = std::collections::HashMap::new();
        for (class, keys) in &entry.classes {
            let value = self.read_symbol(*class, block.span);
            checks.extend(std::mem::take(&mut self.pre));
            checks.push(Expr::call("buoy_jit", "pristine", vec![value.clone()]));
            class_values.insert(*class, value.clone());
            let keys = keys.iter().map(|key| Expr::js_string(key)).collect();
            classes.push(Expr::Tuple(vec![value, Expr::List(keys)]));
        }
        let mut values = Vec::with_capacity(entry.globals.len());
        for global in &entry.globals {
            let value = match global {
                Global::Variable(symbol) => self.read_symbol(*symbol, block.span),
                Global::Static(class, name) => {
                    let class = match class_values.get(class) {
                        Some(value) => value.clone(),
                        None => self.read_symbol(*class, block.span),
                    };
                    let read = Expr::call("buoy_heap", "get", vec![class, Expr::js_string(name)]);
                    self.bind(read)
                }
            };
            checks.extend(std::mem::take(&mut self.pre));
            values.push(value);
        }
        checks.push(Expr::Tuple(vec![Expr::List(classes), Expr::List(values)]));
        self.pre = saved;
        let prepare = Expr::Fun {
            name: None,
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body: checks,
            }],
        };
        let enter = Expr::call(
            "buoy_jit",
            "enter",
            vec![
                Expr::atom(self.module.clone()),
                Expr::Integer(i64::try_from(entry.index).unwrap_or(0)),
                Expr::var(args),
                prepare,
            ],
        );
        let written = entry
            .written
            .iter()
            .filter_map(|global| match global {
                Global::Variable(symbol) => Some(*symbol),
                Global::Static(..) => None,
            })
            .collect();
        Some(JitEntry {
            enter,
            written,
            span: block.span,
        })
    }

    /// The class value `c`, sealed first when an island relies on the class `binding`.
    pub fn jit_seal(&mut self, binding: Option<oxc::semantic::SymbolId>, c: String) -> Expr {
        if binding.is_some_and(|symbol| self.jit.sealed.contains(&symbol)) {
            self.pre
                .push(Expr::call("buoy_jit", "seal", vec![Expr::var(c.clone())]));
        }
        Expr::var(c)
    }

    /// The body of an island's function: the native run, which writes back the variables
    /// it wrote, else the Erlang code.
    pub fn jit_switch(&mut self, entry: JitEntry, code: Vec<Expr>) -> Vec<Expr> {
        let value = self.fresh("Native");
        let saved = std::mem::take(&mut self.pre);
        let mut names = Vec::with_capacity(entry.written.len());
        let mut body = Vec::new();
        for symbol in &entry.written {
            let name = self.fresh("Written");
            let assigned = self.assign_symbol(*symbol, Expr::var(name.clone()), entry.span);
            body.extend(std::mem::take(&mut self.pre));
            body.push(assigned);
            names.push(Expr::var(name));
        }
        self.pre = saved;
        body.push(Expr::var(value.clone()));
        vec![Expr::case(
            entry.enter,
            vec![
                Clause::new(
                    Expr::Tuple(vec![Expr::atom("ok"), Expr::var(value), Expr::List(names)]),
                    body,
                ),
                Clause::new(Expr::var("_"), code),
            ],
        )]
    }

    /// `'$jit'/1`: the encoded IR of each island of the module.
    pub fn jit_programs(&self) -> Vec<Function> {
        if self.jit.programs.is_empty() {
            return Vec::new();
        }
        let clauses = self
            .jit
            .programs
            .iter()
            .enumerate()
            .map(|(index, bytes)| {
                Clause::new(
                    Expr::Integer(i64::try_from(index).unwrap_or(0)),
                    vec![Expr::JsString(
                        bytes.iter().map(|byte| u16::from(*byte)).collect(),
                    )],
                )
            })
            .collect();
        vec![Function {
            name: "$jit".to_owned(),
            clauses,
        }]
    }
}
