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
mod early;
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
mod with;

use std::collections::HashMap;

use crate::diagnostic::{Code, Diagnostic, Reporter};
use crate::erlang;
use crate::parse::{with_js_program, with_program_as};

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
    lower(linking, None, &[])
}

/// Lowers the code of an `eval` (`compile_eval` of the crate): a classic script of one
/// module, without imports, named `name`.
pub fn lower_eval(
    source: String,
    name: &str,
    strict: bool,
    function: bool,
    lexical: &[String],
    scope: &[String],
) -> Result<String, Vec<Diagnostic>> {
    let path = std::path::PathBuf::from("eval.js");
    if !lexical.is_empty() && !strict {
        let conflict = with_js_program(&path, &source, |program, semantic| {
            declared_var_names(program, semantic)
                .into_iter()
                .find(|name| lexical.contains(name))
        })?;
        if let Some(name) = conflict {
            let reporter = Reporter::new(&path, &source);
            return Err(vec![reporter.at(
                0,
                Code::Syntax,
                format!("Identifier '{name}' has already been declared"),
            )]);
        }
    }
    if function {
        let complete = with_js_program(&path, &source, |program, _| {
            is_one_function(program, source.len())
        })?;
        if !complete {
            let reporter = Reporter::new(&path, &source);
            return Err(vec![reporter.at(
                0,
                Code::Syntax,
                "the body of a Function closes the function early".to_owned(),
            )]);
        }
    }
    let graph = Graph {
        units: vec![graph::Unit {
            path,
            name: name.to_owned(),
            source,
            kind: Kind::Esm,
            record: graph::Record::default(),
            requests: Vec::new(),
            broken: Vec::new(),
            script: true,
        }],
    };
    let link = Linked::default();
    let linking = Linking {
        graph: &graph,
        unit: 0,
        link: &link,
        entry: false,
    };
    lower(linking, Some(strict), scope)
}

/// The names that sloppy eval code declares in its variable environment: its top-level
/// `var` names and function declarations (`EvalDeclarationInstantiation`).
fn declared_var_names(
    program: &oxc::ast::ast::Program<'_>,
    semantic: &oxc::semantic::Semantic<'_>,
) -> Vec<String> {
    use oxc::ast_visit::Visit;
    let scoping = semantic.scoping();
    if scoping
        .scope_flags(scoping.root_scope_id())
        .is_strict_mode()
    {
        return Vec::new();
    }
    let mut vars = analyze::VarDeclarations::default();
    vars.visit_program(program);
    let mut names: Vec<String> = vars
        .0
        .iter()
        .map(|symbol| scoping.symbol_name(*symbol).to_owned())
        .collect();
    for statement in &program.body {
        if let oxc::ast::ast::Statement::FunctionDeclaration(function) = statement
            && let Some(id) = &function.id
        {
            names.push(id.name.to_string());
        }
    }
    names
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

fn lower(
    linking: Linking<'_>,
    eval: Option<bool>,
    scope: &[String],
) -> Result<String, Vec<Diagnostic>> {
    let module = linking.unit();
    with_program_as(
        &module.path,
        &module.source,
        module.source_type(),
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
                script_globals: Vec::new(),
                script_functions: Vec::new(),
                eval,
                eval_bindings: scope
                    .iter()
                    .enumerate()
                    .map(|(index, name)| (name.clone(), format!("Scope_{index}")))
                    .collect(),
                privates: Vec::new(),
                class_bindings: Vec::new(),
                early: std::collections::HashSet::new(),
                using_stacks: Vec::new(),
                linking,
            };
            let functions = if module.kind == Kind::CommonJs {
                lowerer.commonjs_functions(program)
            } else {
                lowerer.declare(program);
                lowerer.module_functions(program, &module.source)
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
