//! The entries of the islands of the native tier (contract section 17.10): a function that
//! `crate::jit` found to be an island starts with
//!
//! ```erlang
//! case buoy_jit:enter(Module, Index, Args, fun() -> Checks, [Global...] end) of
//!     {ok, Value} -> Value;
//!     _ -> <the Erlang code of the function>
//! end
//! ```
//!
//! The fun reads the variables outside the island that its code reads, in the realm of
//! the call, and throws when a class or an intrinsic that the island relies on changed.

use super::context::Lowerer;
use super::function::FnBody;
use crate::erlang::{Clause, Expr, Function};

impl Lowerer<'_, '_> {
    /// The call of `buoy_jit:enter/4` when `body` starts an island.
    pub fn jit_entry(&mut self, body: FnBody<'_>, args: &str) -> Option<Expr> {
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
        for class in &entry.classes {
            let value = self.read_symbol(*class, block.span);
            checks.extend(std::mem::take(&mut self.pre));
            checks.push(Expr::call("buoy_jit", "pristine", vec![value]));
        }
        let mut values = Vec::with_capacity(entry.globals.len());
        for global in &entry.globals {
            let value = self.read_symbol(*global, block.span);
            checks.extend(std::mem::take(&mut self.pre));
            values.push(value);
        }
        checks.push(Expr::List(values));
        self.pre = saved;
        let prepare = Expr::Fun {
            name: None,
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body: checks,
            }],
        };
        Some(Expr::call(
            "buoy_jit",
            "enter",
            vec![
                Expr::atom(self.module.clone()),
                Expr::Integer(i64::try_from(entry.index).unwrap_or(0)),
                Expr::var(args),
                prepare,
            ],
        ))
    }

    /// The class value `c`, sealed first when an island relies on the class `binding`.
    pub fn jit_seal(&mut self, binding: Option<oxc::semantic::SymbolId>, c: String) -> Expr {
        if binding.is_some_and(|symbol| self.jit.sealed.contains(&symbol)) {
            self.pre
                .push(Expr::call("buoy_jit", "seal", vec![Expr::var(c.clone())]));
        }
        Expr::var(c)
    }

    /// The body of an island's function: the native run, else the Erlang code.
    pub fn jit_switch(&mut self, enter: Expr, code: Vec<Expr>) -> Vec<Expr> {
        let value = self.fresh("Native");
        vec![Expr::case(
            enter,
            vec![
                Clause::new(
                    Expr::Tuple(vec![Expr::atom("ok"), Expr::var(value.clone())]),
                    vec![Expr::var(value)],
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
