//! Compiles a TypeScript subset into Erlang source for the Bouy OTP runtime.
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
    /// The Erlang module name, such as `bouy@src@app`.
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
    compile_in_with(&entry, &root, semantics)
}

/// Compiles the program whose entry module is `entry`, naming modules relative to `root`.
pub fn compile_in(entry: &Path, root: &Path) -> Result<Project, Vec<Diagnostic>> {
    compile_in_with(entry, root, Semantics::Value)
}

fn compile_in_with(
    entry: &Path,
    root: &Path,
    semantics: Semantics,
) -> Result<Project, Vec<Diagnostic>> {
    let entry = canonical(entry)?;
    let root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    if semantics == Semantics::Reference {
        return compile_reference(&entry, &root, false);
    }
    let graph = graph::load(&entry, &root)?;
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
fn compile_reference(entry: &Path, root: &Path, script: bool) -> Result<Project, Vec<Diagnostic>> {
    let graph = reference::graph::load(entry, root, script)?;
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
/// semantics) into the Erlang module `name`, whose `'__eval__'/1` runs the code in the
/// current realm with a `this` and returns its completion value. Strict code keeps its `var` names to
/// itself; sloppy code makes them properties of the global object. With `function`, the
/// source must be one parenthesized function expression, as the `Function` constructor
/// builds it, so a body cannot close the function early. `lexical` names the bindings that
/// sloppy direct eval code may not declare with `var`. `scope` names the
/// local bindings of the caller of a direct eval, which `'__eval__'/2` gets as cells.
pub fn compile_eval(
    source: &str,
    name: &str,
    strict: bool,
    function: bool,
    lexical: &[String],
    scope: &[String],
) -> Result<String, Vec<Diagnostic>> {
    let source = if strict {
        format!("\"use strict\";\n{source}")
    } else {
        source.to_owned()
    };
    reference::lower_eval(source, name, strict, function, lexical, scope)
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
