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
    /// Objects live in a per-realm heap and have identity (a prototype: one module,
    /// imports only from "bouy").
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
    let graph = match semantics {
        Semantics::Value => graph::load(&entry, &root)?,
        Semantics::Reference => graph::single(&entry, &root)?,
    };
    let mut modules = Vec::with_capacity(graph.modules.len());
    let mut diagnostics = Vec::new();
    for module in &graph.modules {
        let lowered = match semantics {
            Semantics::Value => lower::lower_module(module, &graph),
            Semantics::Reference => reference::lower_module(module),
        };
        match lowered {
            Ok(erlang) => modules.push(Module {
                name: module.name.clone(),
                path: module.path.clone(),
                erlang,
            }),
            Err(mut found) => diagnostics.append(&mut found),
        }
    }
    if !diagnostics.is_empty() {
        diagnostics.sort_by(|a, b| (&a.path, a.line, a.column).cmp(&(&b.path, b.line, b.column)));
        return Err(diagnostics);
    }
    Ok(Project {
        root,
        entry: module_name(&graph.root, &entry),
        modules,
    })
}

/// Compiles the code of an `eval` or of the `Function` constructor at run time (reference
/// semantics) into the Erlang module `name`, whose `'__eval__'/1` runs the code in the
/// current realm with a `this` and returns its completion value. Strict code keeps its `var` names to
/// itself; sloppy code makes them properties of the global object. With `function`, the
/// source must be one parenthesized function expression, as the `Function` constructor
/// builds it, so a body cannot close the function early. With `parameters`, the code is a
/// direct eval in a parameter default, which may not declare `arguments`.
pub fn compile_eval(
    source: &str,
    name: &str,
    strict: bool,
    function: bool,
    parameters: bool,
) -> Result<String, Vec<Diagnostic>> {
    let source = if strict {
        format!("\"use strict\";\n{source}")
    } else {
        source.to_owned()
    };
    let module = graph::Module {
        path: PathBuf::from("eval.js"),
        name: name.to_owned(),
        source,
        imports: std::collections::HashMap::new(),
        exports: std::collections::HashMap::new(),
    };
    reference::lower_eval(&module, strict, function, parameters)
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
