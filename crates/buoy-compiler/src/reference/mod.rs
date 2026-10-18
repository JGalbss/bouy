//! The reference-semantics lowering (prototype, `buoy run --semantics reference`).
//!
//! Objects live in the heap of a realm (`buoy_heap`) and have identity. A local variable
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
use crate::parse::{with_js_program, with_program_allowing};

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
    // A JSON, text, or bytes module holds its source as a constant for the runtime.
    if matches!(module.kind, Kind::Json | Kind::Text | Kind::Bytes) {
        return Ok(erlang::print_module(&erlang::Module {
            name: module.name.clone(),
            functions: linking.json_functions(),
        }));
    }
    lower(linking, None, &[])
}

/// What the code of a direct eval may use from the place of its call (ECMA-262 §19.2.1.1,
/// `PerformEval`). The runtime passes the values in the context map of `'__eval__'/3`.
#[derive(Debug, Default, Clone)]
pub struct EvalContext {
    pub place: EvalPlace,
    /// The private names that the call sees (`privates`, their keys in this order).
    pub privates: Vec<String>,
    /// The code is part of the runtime, such as the Temporal polyfill: a static member of
    /// a standard global, such as `Math.sign`, reads the value that the runtime installed,
    /// and an array iterates without its user-visible iterator. Node's lib gets the same
    /// from its primordials, and Bun's builtin modules from their intrinsics.
    pub internal: bool,
}

/// Where a direct eval is called, which decides what its code may use.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum EvalPlace {
    /// Outside functions, or in an arrow outside them.
    #[default]
    Global,
    /// In a function other than an arrow, or in an arrow inside one: the code may read
    /// `new.target` (`new_target`).
    Function,
    /// In a method, which has a home object: the code may use `super.x` (`home`).
    Method,
    /// In a class field initializer, where `arguments` is a `SyntaxError`.
    Field,
    /// In a derived constructor: the code may call `super(...)` (`this_cell`, `class`, and
    /// `init`).
    Constructor,
}

impl EvalPlace {
    /// The place that the `--place` option of `buoy compile-eval` names.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "global" => Self::Global,
            "function" => Self::Function,
            "method" => Self::Method,
            "field" => Self::Field,
            "constructor" => Self::Constructor,
            _ => return None,
        })
    }

    #[must_use]
    pub fn has_new_target(self) -> bool {
        self != Self::Global
    }

    #[must_use]
    pub fn has_home(self) -> bool {
        matches!(self, Self::Method | Self::Field | Self::Constructor)
    }
}

impl EvalContext {
    /// Whether the context permits the early error `message` at `offset` of `program`.
    fn allows(&self, program: &oxc::ast::ast::Program<'_>, message: &str, offset: usize) -> bool {
        if let Some(name) = message
            .strip_prefix("Private identifier '#")
            .or_else(|| message.strip_prefix("Private field '#"))
            .and_then(|rest| rest.split('\'').next())
        {
            return self.privates.iter().any(|private| private == name);
        }
        let place = self.place;
        let permitted = (place.has_new_target() && message == "Unexpected new.target expression")
            || (place.has_home() && message.starts_with("'super' can only be referenced"))
            || (place == EvalPlace::Constructor
                && message.starts_with("Super calls are not permitted"));
        permitted && !in_function(program, offset)
    }
}

/// Whether `offset` lies in a function of `program` other than an arrow, which has its own
/// `super`, `new.target`, and `arguments`.
fn in_function(program: &oxc::ast::ast::Program<'_>, offset: usize) -> bool {
    use oxc::ast_visit::{Visit, walk};
    struct Functions(Vec<oxc::span::Span>);
    impl<'a> Visit<'a> for Functions {
        fn visit_function(
            &mut self,
            it: &oxc::ast::ast::Function<'a>,
            flags: oxc::semantic::ScopeFlags,
        ) {
            self.0.push(it.span);
            walk::walk_function(self, it, flags);
        }
    }
    let mut functions = Functions(Vec::new());
    functions.visit_program(program);
    functions
        .0
        .iter()
        .any(|span| (span.start as usize) <= offset && offset < span.end as usize)
}

/// The offset of the first `arguments` of eval code outside its functions other than
/// arrows: a `SyntaxError` in a class field initializer.
fn arguments_offset(program: &oxc::ast::ast::Program<'_>) -> Option<u32> {
    use oxc::ast_visit::Visit;
    struct Arguments(Option<u32>);
    impl<'a> Visit<'a> for Arguments {
        fn visit_identifier_reference(&mut self, it: &oxc::ast::ast::IdentifierReference<'a>) {
            if it.name == "arguments" && self.0.is_none() {
                self.0 = Some(it.span.start);
            }
        }
        fn visit_function(
            &mut self,
            _it: &oxc::ast::ast::Function<'a>,
            _flags: oxc::semantic::ScopeFlags,
        ) {
        }
    }
    let mut found = Arguments(None);
    found.visit_program(program);
    found.0
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
    context: &EvalContext,
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
    lower_one_script(path, name, source, Some((strict, context)), scope)
}

/// Lowers a classic script of its own (`compile_script` of the crate), named `name`.
pub fn lower_script(source: String, name: &str) -> Result<String, Vec<Diagnostic>> {
    lower_one_script(
        std::path::PathBuf::from("script.js"),
        name,
        source,
        None,
        &[],
    )
}

/// Lowers source text that no module imports: eval code, or a script.
fn lower_one_script(
    path: std::path::PathBuf,
    name: &str,
    source: String,
    eval: Option<(bool, &EvalContext)>,
    scope: &[String],
) -> Result<String, Vec<Diagnostic>> {
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
    lower(linking, eval, scope)
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
    eval: Option<(bool, &EvalContext)>,
    scope: &[String],
) -> Result<String, Vec<Diagnostic>> {
    let module = linking.unit();
    let context = eval.map(|(_, context)| context.clone()).unwrap_or_default();
    let allowed = |program: &oxc::ast::ast::Program<'_>, message: &str, offset: usize| {
        context.allows(program, message, offset)
    };
    with_program_allowing(
        &module.path,
        &module.source,
        module.source_type(),
        &allowed,
        |program, semantic| {
            if context.place == EvalPlace::Field
                && let Some(offset) = arguments_offset(program)
            {
                let mut reporter = Reporter::new(&module.path, &module.source);
                reporter.report(
                    oxc::span::Span::new(offset, offset),
                    Code::Syntax,
                    "'arguments' is not allowed in class field initializer or static initialization block".to_owned(),
                );
                return Err(reporter.diagnostics);
            }
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
                eval: eval.map(|(strict, _)| strict),
                eval_context: context.clone(),
                eval_bindings: scope
                    .iter()
                    .enumerate()
                    .map(|(index, name)| (name.clone(), format!("Scope_{index}")))
                    .collect(),
                privates: Vec::new(),
                class_bindings: Vec::new(),
                early: std::collections::HashSet::new(),
                using_stacks: Vec::new(),
                hoisted: std::collections::HashSet::new(),
                linking,
            };
            let functions = if module.kind == Kind::CommonJs {
                lowerer.commonjs_functions(program, &module.source)
            } else if lowerer.eval.is_some() {
                lowerer.eval_module_functions(program, &module.source)
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
