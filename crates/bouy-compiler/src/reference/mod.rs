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
//! `await` and `yield` leave a marker in the code of a statement. `seal` splits a body at
//! each marker: the rest of the body becomes the fun that a promise reaction or `next()`
//! calls later. A `try` that holds a suspension point is a region: each segment of its
//! body runs inside an Erlang `try` whose handler is the `catch` clause, and a jump out of
//! the region returns `{'$k', Fun, Args}` so that the wrapper calls `Fun` outside the
//! Erlang `try`.
//!
//! The files, by area:
//!
//! - `context`: the lowering state (`Lowerer`, `Frame`, `Cont`) and shared builders.
//! - `graph`, `link`: the modules of the program and what their imports refer to.
//! - `linking`: the interface of a module to the loader of the runtime.
//! - `module`: module-level names, `'$body'/0`, `'$class'/1`, and module variables.
//! - `function`, `class`, `suspend`: functions, classes, and `await`/`yield`.
//! - `stmt`, `loops`, `exception`: statements, loops, and `try`.
//! - `expr`, `variable`, `member`, `call`, `literal`, `pattern`: expressions.
//! - `analyze`: the facts the lowering needs before it emits code.

mod analyze;
mod call;
mod class;
mod context;
mod exception;
mod expr;
mod function;
pub mod graph;
pub mod link;
mod linking;
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
use crate::parse::with_program_as;

use context::{Frame, Lowerer};
use graph::{Graph, Kind};
use link::Linked;
pub use linking::Linking;

/// Lowers the module `unit` of `graph` with reference semantics.
pub fn lower_unit(
    graph: &Graph,
    unit: usize,
    link: &Linked,
    entry: bool,
) -> Result<String, Vec<Diagnostic>> {
    let linking = Linking {
        graph,
        unit,
        link,
        entry,
    };
    let module = linking.unit();
    if !module.broken.is_empty() {
        return Ok(broken_module(linking, &module.broken));
    }
    if module.kind == Kind::Json {
        return Ok(erlang::print_module(&erlang::Module {
            name: module.name.clone(),
            functions: linking.json_functions(),
        }));
    }
    let source_type = module.source_type();
    with_program_as(
        &module.path,
        &module.source,
        source_type,
        |program, semantic| {
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
                linking,
            };
            let functions = if module.kind == Kind::CommonJs {
                lowerer.commonjs_functions(program)
            } else {
                lowerer.declare(program);
                lowerer.module_functions(program)
            };
            if lowerer.reporter.diagnostics.is_empty() {
                Ok(erlang::print_module(&erlang::Module {
                    name: module.name.clone(),
                    functions,
                }))
            } else {
                Err(lowerer.reporter.diagnostics)
            }
        },
    )?
}

/// The Erlang module of a module that does not compile.
pub fn broken_module(linking: Linking<'_>, diagnostics: &[Diagnostic]) -> String {
    erlang::print_module(&erlang::Module {
        name: linking.unit().name.clone(),
        functions: linking.broken_functions(diagnostics),
    })
}
