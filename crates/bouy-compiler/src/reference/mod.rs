//! The reference-semantics lowering (prototype, `bouy run --semantics reference`).
//!
//! Objects live in the heap of a realm (`bouy_heap`) and have identity. A local variable
//! that a closure changes or sees change, or that a `try` or a conditional expression
//! changes, is a heap cell. Every other local is a single-assignment Erlang variable with
//! versions.
//!
//! Statements lower in continuation-passing style. A compound statement gets the rest of
//! its block as a join fun, whose parameters are the versions of the variables that the
//! statement changes, and every path of the statement ends in a tail call. A loop is a
//! named fun that calls itself. Expressions lower in A-normal form: each step binds a
//! fresh variable, so the Erlang code keeps the evaluation order of JavaScript.
//!
//! `await`, `yield`, and `yield*` leave a marker in the code of a statement. `seal` splits
//! a body at each marker: the rest of the body becomes the fun that a promise reaction or
//! `next()` calls later. A `try` that holds a suspension point, and the body of a
//! `for...of`, are regions: each segment runs inside an Erlang `try` whose handler is the
//! `catch` clause or closes the iterator, and a jump out of the region returns
//! `{'$k', Fun, Args, Level}` so that the wrapper of the level above `Level` calls `Fun`
//! outside the inner Erlang `try`s. A `finally` block, and the closing of an iterator, is
//! a fun that takes the completion (`suspend` and `exception`).
//!
//! The files, by area:
//!
//! - `context`: the lowering state (`Lowerer`, `Frame`, `Cont`) and shared builders.
//! - `module`: module-level names, `'__init__'/0`, `'$class'/1`, and module variables.
//! - `function`, `class`, `suspend`: functions, classes, and `await`/`yield`.
//! - `stmt`, `loops`, `exception`: statements, loops, and `try`.
//! - `expr`, `variable`, `member`, `call`, `literal`, `pattern`: expressions.
//! - `analyze`: the facts the lowering needs before it emits code.

mod analyze;
mod call;
mod class;
mod context;
mod early;
mod exception;
mod expr;
mod function;
mod literal;
mod loops;
mod member;
mod module;
mod pattern;
mod stmt;
mod suspend;
mod variable;

use std::collections::HashMap;

use crate::diagnostic::{Diagnostic, Reporter};
use crate::erlang;
use crate::graph;
use crate::parse::with_js_program;

use context::{Frame, Lowerer};

/// Lowers `module` with reference semantics.
pub fn lower_module(module: &graph::Module) -> Result<String, Vec<Diagnostic>> {
    with_js_program(&module.path, &module.source, |program, semantic| {
        let analysis = analyze::analyze(program, semantic);
        let mut lowerer = Lowerer {
            semantic,
            analysis: &analysis,
            reporter: Reporter::new(&module.path, &module.source),
            module: module.name.clone(),
            tops: HashMap::new(),
            counter: 0,
            extra: Vec::new(),
            frame: Frame::default(),
            pre: Vec::new(),
            classes: Vec::new(),
            privates: Vec::new(),
            class_bindings: Vec::new(),
            early: std::collections::HashSet::new(),
            using_stacks: Vec::new(),
        };
        lowerer.declare(program);
        let functions = lowerer.module_functions(program);
        if lowerer.reporter.diagnostics.is_empty() {
            Ok(erlang::print_module(&erlang::Module {
                name: module.name.clone(),
                functions,
            }))
        } else {
            Err(lowerer.reporter.diagnostics)
        }
    })?
}
