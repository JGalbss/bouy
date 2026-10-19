//! Compiles a TypeScript subset into Erlang source for the Buoy OTP runtime.
//!
//! `docs/design/beam-runtime.md` is the contract this crate implements: module names
//! (section 2), the value representation (section 3), and the lowering of each construct
//! (sections 4 to 12).

mod diagnostic;
mod erlang;
mod graph;
mod jit;
mod library;
mod lower;
mod oxc_gaps;
mod parse;
mod reference;
mod resolve;

use std::path::{Path, PathBuf};

pub use diagnostic::{Code, Diagnostic};
use graph::{module_name, project_root};
pub use reference::{EvalContext, EvalPlace, EvalSource};
pub use resolve::set_user_conditions;

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
        Ok(resolve::Target::Data(url)) => Err((
            "ERR_UNSUPPORTED_ESM_URL_SCHEME".to_owned(),
            format!("{url} loads through the ESM loader of the program"),
        )),
        Ok(resolve::Target::File(path)) => {
            let root = project_root(main);
            let root = root.canonicalize().unwrap_or(root);
            // An import loads the file with the ESM loader, which reads an extensionless
            // WebAssembly binary as WebAssembly.
            compile_reference_entry(&path, &root, !require)
                .map(|project| Loaded::Program(path, project))
                .map_err(|diagnostics| load_error(&diagnostics))
        }
        Err(failure) => Err((failure.code.to_owned(), failure.message)),
    }
}

/// The error that a running program throws for a module that does not compile: the
/// name `SyntaxError` for a syntax error, as Node's loaders throw one, else the code
/// `ERR_BUOY_COMPILE`, with the message of the first diagnostic.
#[must_use]
pub fn load_error(diagnostics: &[Diagnostic]) -> (String, String) {
    match diagnostics.first() {
        Some(d) if d.code == Code::Syntax => ("SyntaxError".to_owned(), d.message.clone()),
        Some(d) => ("ERR_BUOY_COMPILE".to_owned(), d.message.clone()),
        None => ("ERR_BUOY_COMPILE".to_owned(), String::new()),
    }
}

fn compile_reference(entry: &Path, root: &Path, script: bool) -> Result<Project, Vec<Diagnostic>> {
    compile_reference_text(entry, root, script, None)
}

fn compile_reference_entry(
    entry: &Path,
    root: &Path,
    imported: bool,
) -> Result<Project, Vec<Diagnostic>> {
    let graph = reference::graph::load_imported(entry, root, imported)?;
    compile_graph(&graph, root)
}

fn compile_reference_text(
    entry: &Path,
    root: &Path,
    script: bool,
    text: Option<String>,
) -> Result<Project, Vec<Diagnostic>> {
    let graph = reference::graph::load(entry, root, script, text)?;
    compile_graph(&graph, root)
}

fn compile_graph(graph: &reference::graph::Graph, root: &Path) -> Result<Project, Vec<Diagnostic>> {
    let links = reference::link::link(graph);
    let mut modules = Vec::with_capacity(graph.units.len());
    let mut diagnostics = Vec::new();
    let mut deferred: Vec<Diagnostic> = graph
        .units
        .iter()
        .flat_map(|unit| unit.broken.iter().cloned())
        .collect();
    for ((index, unit), lowered) in graph.units.iter().enumerate().zip(lower_units(graph, &links)) {
        let erlang = match lowered {
            Ok(erlang) => erlang,
            Err(mut found) if index == 0 => {
                diagnostics.append(&mut found);
                continue;
            }
            // Another module that does not compile throws when the program loads it.
            Err(mut found) => {
                let erlang = reference::broken_module(
                    reference::Linking {
                        graph,
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

/// The stack of a thread that lowers a module. The lowering recurses over the syntax tree,
/// and minified code nests deeply.
const LOWER_STACK_BYTES: usize = 256 << 20;

/// Lowers each unit of `graph` on up to eight threads, which take the largest sources first,
/// so that one large module does not finish last. The results keep the order of the units.
fn lower_units(
    graph: &reference::graph::Graph,
    links: &[reference::link::Linked],
) -> Vec<Result<String, Vec<Diagnostic>>> {
    let count = graph.units.len();
    let mut order: Vec<usize> = (0..count).collect();
    order.sort_by_key(|&index| std::cmp::Reverse(graph.units[index].source.len()));
    let next = std::sync::atomic::AtomicUsize::new(0);
    let threads = std::thread::available_parallelism()
        .map_or(1, usize::from)
        .clamp(1, 8)
        .min(count);
    let lower = || {
        let mut lowered = Vec::new();
        while let Some(&index) = order.get(next.fetch_add(1, std::sync::atomic::Ordering::Relaxed)) {
            lowered.push((
                index,
                reference::lower_unit(graph, index, &links[index], index == 0),
            ));
        }
        lowered
    };
    let mut results: Vec<Option<Result<String, Vec<Diagnostic>>>> =
        std::iter::repeat_with(|| None).take(count).collect();
    std::thread::scope(|scope| {
        let workers: Vec<_> = (0..threads)
            .map(|_| {
                std::thread::Builder::new()
                    .stack_size(LOWER_STACK_BYTES)
                    .spawn_scoped(scope, lower)
                    .expect("the lowering thread starts")
            })
            .collect();
        for worker in workers {
            let lowered = worker
                .join()
                .unwrap_or_else(|panic| std::panic::resume_unwind(panic));
            for (index, result) in lowered {
                results[index] = Some(result);
            }
        }
    });
    results
        .into_iter()
        .map(|result| result.expect("each unit is lowered"))
        .collect()
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
/// builds it, whose parameter list ends at the byte offset `function` names (after its
/// closing parenthesis), so neither the parameters nor the body can close the function
/// early. `lexical` names the bindings that
/// sloppy direct eval code may not declare with `var`. `scope` names the
/// local bindings of the caller of a direct eval, which `'__eval__'/3` gets as cells, and
/// `context` what the place of the call permits, such as `super.x` in a method.
pub fn compile_eval(
    source: &str,
    name: &str,
    strict: bool,
    function: Option<usize>,
    lexical: &[String],
    scope: &[String],
    context: &EvalContext,
) -> Result<String, Vec<Diagnostic>> {
    let directed = eval_text(source, strict);
    let function = function.map(|end| end + directed.len() - source.len());
    reference::lower_eval(directed, name, strict, function, lexical, scope, context)
}

/// The text that `compile_eval` compiles: strict code gets the directive first, and a
/// hashbang comment stays a comment after it. The spans of the module index this text.
#[must_use]
pub fn eval_text(source: &str, strict: bool) -> String {
    match (strict, source.strip_prefix("#!")) {
        (true, Some(rest)) => format!("\"use strict\";\n//{rest}"),
        (true, None) => format!("\"use strict\";\n{source}"),
        (false, _) => source.to_owned(),
    }
}

/// Compiles a classic script at run time (reference semantics) into the Erlang module
/// `name`, as a host's `evalScript` runs it: its `'$body'/0` declares the script's
/// top-level names in the global environment of the current realm and runs its code.
pub fn compile_eval_script(
    source: &str,
    name: &str,
    interruptible: bool,
) -> Result<String, Vec<Diagnostic>> {
    reference::lower_script(source.to_owned(), name, interruptible)
}

/// Compiles an ES module from source text at run time (reference semantics) into the
/// Erlang module `name`, as `vm.SourceTextModule` and Node's ESM loader compile a
/// `ModuleWrap`: the host links each request of `import` and `export ... from` at run time
/// (`buoy_module:hosted_import/3`). `identifier` is the module's URL or name.
pub fn compile_hosted_module(
    source: &str,
    name: &str,
    identifier: &str,
) -> Result<String, Vec<Diagnostic>> {
    reference::lower_hosted_module(source.to_owned(), name, PathBuf::from(identifier))
}

/// The export names and the re-exported specifiers of `CommonJS` source text, as Node's
/// cjs-module-lexer finds them: `None` for text that does not parse.
#[must_use]
pub fn cjs_lexer(source: &str) -> Option<(Vec<String>, Vec<String>)> {
    reference::graph::cjs_lexer(source.to_owned()).ok()
}

/// Node's `containsModuleSyntax`: whether source text that does not compile as a `CommonJS`
/// function body, with or without the wrapper's variables, is an ES module by its syntax.
#[must_use]
pub fn contains_module_syntax(source: &str, cjs_variables: bool) -> bool {
    reference::graph::contains_module_syntax(source, cjs_variables)
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
