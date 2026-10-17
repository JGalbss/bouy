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
//! - `module`: module-level names, `'__init__'/0`, `'$class'/1`, and module variables.
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
mod literal;
mod loops;
mod member;
mod module;
mod pattern;
mod stmt;
mod suspend;
mod variable;

use std::collections::HashMap;

use crate::diagnostic::{Code, Diagnostic, Reporter};
use crate::erlang;
use crate::graph;
use crate::parse::with_program;

use context::{Frame, Lowerer};

/// Lowers `module` with reference semantics.
pub fn lower_module(module: &graph::Module) -> Result<String, Vec<Diagnostic>> {
    lower(module, None)
}

/// Lowers the code of an `eval` (`compile_eval` of the crate).
pub fn lower_eval(
    module: &graph::Module,
    strict: bool,
    function: bool,
) -> Result<String, Vec<Diagnostic>> {
    if function {
        let complete = with_program(&module.path, &module.source, |program, _| {
            is_one_function(program, module.source.len())
        })?;
        if !complete {
            let reporter = Reporter::new(&module.path, &module.source);
            return Err(vec![reporter.at(
                0,
                Code::Syntax,
                "the body of a Function closes the function early".to_owned(),
            )]);
        }
    }
    lower(module, Some(strict))
}

/// Whether the program is one parenthesized function expression that ends where the source
/// does, before its closing parenthesis.
fn is_one_function(program: &oxc::ast::ast::Program<'_>, length: usize) -> bool {
    use oxc::ast::ast::{Expression, Statement};
    let [Statement::ExpressionStatement(statement)] = program.body.as_slice() else {
        return false;
    };
    let Expression::ParenthesizedExpression(inner) = &statement.expression else {
        return false;
    };
    matches!(&inner.expression, Expression::FunctionExpression(function)
        if function.span.end as usize + 1 == length)
}

fn lower(module: &graph::Module, eval: Option<bool>) -> Result<String, Vec<Diagnostic>> {
    with_program(&module.path, &module.source, |program, semantic| {
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
            script_globals: Vec::new(),
            script_functions: Vec::new(),
            eval,
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
