//! Compiles a TypeScript subset into Erlang source for the Buoy OTP runtime.
//!
//! `docs/design/beam-runtime.md` is the contract this crate implements: module names
//! (section 2), the value representation (section 3), and the lowering of each construct
//! (sections 4 to 12).

mod diagnostic;
mod erlang;
mod graph;
mod library;
mod lower;
mod parse;
mod reference;
mod resolve;

use std::path::{Path, PathBuf};

pub use diagnostic::{Code, Diagnostic};
use graph::{module_name, project_root};
pub use reference::{EvalContext, EvalPlace};

/// The Erlang modules of a program.
#[derive(Debug, Clone)]
pub struct Project {
    /// The project root that module names are relative to.
    pub root: PathBuf,
    /// The Erlang name of the entry module.
    pub entry: String,
    /// Every module of the program. The entry module comes first.
    pub modules: Vec<Module>,
    /// The diagnostics of the modules other than the entry that do not compile. Each such
    /// module throws its first diagnostic when the program loads it.
    pub deferred: Vec<Diagnostic>,
}

/// One compiled module.
#[derive(Debug, Clone)]
pub struct Module {
    /// The Erlang module name, such as `buoy@src@app`.
    pub name: String,
    /// The TypeScript source file.
    pub path: PathBuf,
    /// The Erlang source.
    pub erlang: String,
}

/// How the compiled program treats objects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Semantics {
    /// Objects are immutable Erlang terms and mutation rebinds (the contract).
    #[default]
    Value,
    /// Objects live in a per-realm heap and have identity, and the program loads its
    /// modules from `node_modules` too (contract section 17).
    Reference,
}

/// Compiles the program whose entry module is `entry`, in the project that contains it.
pub fn compile(entry: &Path) -> Result<Project, Vec<Diagnostic>> {
    compile_with(entry, Semantics::Value)
}

/// Compiles the program with the given object semantics.
pub fn compile_with(entry: &Path, semantics: Semantics) -> Result<Project, Vec<Diagnostic>> {
    let entry = canonical(entry)?;
    let root = project_root(&entry);
    compile_in_with(&entry, &root, semantics, Goal::Extension)
}

/// The goal symbol that the source files of a program parse with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Goal {
    /// The goal of the file extension: TypeScript for `.ts`, a module for `.js` and `.mjs`.
    Extension,
    /// A JavaScript script, as test262 runs a file without the `module` flag.
    Script,
    /// A JavaScript module.
    Module,
}

/// Compiles the program whose entry module is `entry`, naming modules relative to `root`.
pub fn compile_in(entry: &Path, root: &Path) -> Result<Project, Vec<Diagnostic>> {
    compile_goal(entry, root, Goal::Extension)
}

/// Compiles as `compile_in` does, with every source file parsed with `goal`.
pub fn compile_goal(entry: &Path, root: &Path, goal: Goal) -> Result<Project, Vec<Diagnostic>> {
    compile_in_with(entry, root, Semantics::Value, goal)
}

fn compile_in_with(
    entry: &Path,
    root: &Path,
    semantics: Semantics,
    goal: Goal,
) -> Result<Project, Vec<Diagnostic>> {
    let entry = canonical(entry)?;
    let root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    if semantics == Semantics::Reference {
        return compile_reference(&entry, &root, false);
    }
    let graph = graph::load(&entry, &root, goal)?;
    let mut modules = Vec::with_capacity(graph.modules.len());
    let mut diagnostics = Vec::new();
    for module in &graph.modules {
        match lower::lower_module(module, &graph) {
            Ok(erlang) => modules.push(Module {
                name: module.name.clone(),
                path: module.path.clone(),
                erlang,
            }),
            Err(mut found) => diagnostics.append(&mut found),
        }
    }
    finish(root, module_name(&graph.root, &entry), modules, diagnostics)
}

/// Compiles a classic script with reference semantics, as test262 runs a test without
/// the `module` flag.
pub fn compile_script(entry: &Path) -> Result<Project, Vec<Diagnostic>> {
    let entry = canonical(entry)?;
    let root = project_root(&entry);
    let root = root.canonicalize().unwrap_or(root);
    compile_reference(&entry, &root, true)
}

/// The reference engine: every module that the entry reaches, from `node_modules` too.
/// Compiles, on the reference engine, a program whose entry module is the source `text`,
/// as if it were the file `entry`, which need not exist: the code of `node -e`, which
/// resolves its imports from the directory of `entry`.
pub fn compile_source(entry: &Path, text: String) -> Result<Project, Vec<Diagnostic>> {
    let root = project_root(entry);
    let root = root.canonicalize().unwrap_or(root);
    compile_reference_text(entry, &root, false, Some(text))
}

/// The file that `node <script>` runs: the script itself, or the file that `require` of its
/// absolute path finds, with an extension or as a directory, as Node's `Module.runMain`
/// resolves the main entry.
#[must_use]
pub fn resolve_main(script: &Path) -> Option<PathBuf> {
    if script.is_file() {
        return Some(script.to_path_buf());
    }
    let absolute = std::env::current_dir().ok()?.join(script);
    match resolve::Resolver::default().resolve(
        &absolute.to_string_lossy(),
        &absolute,
        resolve::Mode::Require,
    ) {
        Ok(resolve::Target::File(path)) => Some(path),
        _ => None,
    }
}

/// What a running program loads at run time: a specifier that its static graph did not
/// reach, such as `require(path.join(dir, name))`.
#[derive(Debug)]
pub enum Loaded {
    /// The file, and the program that has it as the entry, named relative to the root of
    /// the running program, so a module it shares with that program has the same name.
    Program(PathBuf, Project),
    /// A built-in module of Node.
    Builtin(String),
}

/// Resolves `specifier` from the module file `importer` as `require` (or `import`) does
/// and compiles the target with the reference semantics, in the project of the running
/// program whose entry is `main`. The error is Node's code and message.
pub fn compile_loaded(
    main: &Path,
    importer: &Path,
    specifier: &str,
    require: bool,
) -> Result<Loaded, (String, String)> {
    let mode = if require {
        resolve::Mode::Require
    } else {
        resolve::Mode::Import
    };
    match resolve::Resolver::default().resolve(specifier, importer, mode) {
        Ok(resolve::Target::Builtin(name)) => Ok(Loaded::Builtin(name)),
        Ok(resolve::Target::File(path)) => {
            let root = project_root(main);
            let root = root.canonicalize().unwrap_or(root);
            compile_reference(&path, &root, false)
                .map(|project| Loaded::Program(path, project))
                .map_err(|diagnostics| {
                    let message = diagnostics
                        .first()
                        .map_or_else(String::new, |d| d.message.clone());
                    ("ERR_BUOY_COMPILE".to_owned(), message)
                })
        }
        Err(failure) => Err((failure.code.to_owned(), failure.message)),
    }
}

fn compile_reference(entry: &Path, root: &Path, script: bool) -> Result<Project, Vec<Diagnostic>> {
    compile_reference_text(entry, root, script, None)
}

fn compile_reference_text(
    entry: &Path,
    root: &Path,
    script: bool,
    text: Option<String>,
) -> Result<Project, Vec<Diagnostic>> {
    let graph = reference::graph::load(entry, root, script, text)?;
    let links = reference::link::link(&graph);
    let mut modules = Vec::with_capacity(graph.units.len());
    let mut diagnostics = Vec::new();
    let mut deferred: Vec<Diagnostic> = graph
        .units
        .iter()
        .flat_map(|unit| unit.broken.iter().cloned())
        .collect();
    for (index, unit) in graph.units.iter().enumerate() {
        let erlang = match reference::lower_unit(&graph, index, &links[index], index == 0) {
            Ok(erlang) => erlang,
            Err(mut found) if index == 0 => {
                diagnostics.append(&mut found);
                continue;
            }
            // Another module that does not compile throws when the program loads it.
            Err(mut found) => {
                let erlang = reference::broken_module(
                    reference::Linking {
                        graph: &graph,
                        unit: index,
                        link: &links[index],
                        entry: false,
                    },
                    &found,
                );
                deferred.append(&mut found);
                erlang
            }
        };
        modules.push(Module {
            name: unit.name.clone(),
            path: unit.path.clone(),
            erlang,
        });
    }
    let entry_name = graph
        .units
        .first()
        .map_or_else(String::new, |unit| unit.name.clone());
    let mut project = finish(root.to_path_buf(), entry_name, modules, diagnostics)?;
    project.deferred = deferred;
    Ok(project)
}

fn finish(
    root: PathBuf,
    entry: String,
    modules: Vec<Module>,
    mut diagnostics: Vec<Diagnostic>,
) -> Result<Project, Vec<Diagnostic>> {
    if !diagnostics.is_empty() {
        diagnostics.sort_by(|a, b| (&a.path, a.line, a.column).cmp(&(&b.path, b.line, b.column)));
        return Err(diagnostics);
    }
    Ok(Project {
        root,
        entry,
        modules,
        deferred: Vec::new(),
    })
}

/// Compiles the code of an `eval` or of the `Function` constructor at run time (reference
/// semantics) into the Erlang module `name`, whose `'__eval__'/3` runs the code in the
/// current realm with a `this`, the caller's scope, and a context map, and returns its
/// completion value. Strict code keeps its `var` names to
/// itself; sloppy code makes them properties of the global object. With `function`, the
/// source must be one parenthesized function expression, as the `Function` constructor
/// builds it, so a body cannot close the function early. `lexical` names the bindings that
/// sloppy direct eval code may not declare with `var`. `scope` names the
/// local bindings of the caller of a direct eval, which `'__eval__'/3` gets as cells, and
/// `context` what the place of the call permits, such as `super.x` in a method.
pub fn compile_eval(
    source: &str,
    name: &str,
    strict: bool,
    function: bool,
    lexical: &[String],
    scope: &[String],
    context: &EvalContext,
) -> Result<String, Vec<Diagnostic>> {
    // The directive goes first, and a hashbang comment stays a comment after it.
    let source = match (strict, source.strip_prefix("#!")) {
        (true, Some(rest)) => format!("\"use strict\";\n//{rest}"),
        (true, None) => format!("\"use strict\";\n{source}"),
        (false, _) => source.to_owned(),
    };
    reference::lower_eval(source, name, strict, function, lexical, scope, context)
}

/// Compiles a classic script at run time (reference semantics) into the Erlang module
/// `name`, as a host's `evalScript` runs it: its `'$body'/0` declares the script's
/// top-level names in the global environment of the current realm and runs its code.
pub fn compile_eval_script(source: &str, name: &str) -> Result<String, Vec<Diagnostic>> {
    reference::lower_script(source.to_owned(), name)
}

fn canonical(path: &Path) -> Result<PathBuf, Vec<Diagnostic>> {
    path.canonicalize().map_err(|error| {
        vec![Diagnostic {
            path: path.to_path_buf(),
            line: 1,
            column: 1,
            code: Code::BadImport,
            message: format!("cannot read {}: {error}", path.display()),
        }]
    })
}
