//! The module graph: the project root, module names, import resolution, and export tables.

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::path::{Component, Path, PathBuf};

use oxc::ast::ast::{
    Declaration, ExportDefaultDeclarationKind, ImportDeclarationSpecifier, Program, Statement,
    VariableDeclarationKind,
};
use oxc::semantic::{Semantic, SymbolId};
use oxc::span::{GetSpan, SourceType, Span};

use crate::Goal;
use crate::diagnostic::{Code, Diagnostic, Reporter};
use crate::library;
use crate::lower::class::{ClassKind, classify, data_imports};
use crate::lower::function::is_function_value;
use crate::parse::{source_type, with_program};

/// One Bouy module of the graph.
#[derive(Debug)]
pub struct Module {
    pub path: PathBuf,
    /// The Erlang module name (section 2).
    pub name: String,
    pub source: String,
    /// The language and the goal symbol that the source parses with.
    pub source_type: SourceType,
    /// The Erlang module name of each relative import specifier.
    pub imports: HashMap<String, String>,
    /// Each exported name and what it refers to, re-exports included.
    pub exports: HashMap<String, Export>,
}

/// What an exported name refers to: a declaration of `module`, by its local name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Export {
    /// The Erlang module that declares the name.
    pub module: String,
    pub local: String,
    pub kind: ExportKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExportKind {
    Function,
    /// A module-level `const`.
    Const,
    Class(ClassKind),
    /// `export * as name from "./m.ts"`: the namespace of `module`.
    Namespace,
}

/// A re-export that names exports of another module.
#[derive(Debug)]
enum Reexport {
    /// `export { imported as exported } from "./m.ts"`
    Named {
        from: String,
        imported: String,
        exported: String,
        span: Span,
    },
    /// `export * from "./m.ts"`
    All { from: String },
    /// `export * as exported from "./m.ts"`
    Namespace { from: String, exported: String },
}

#[derive(Debug)]
pub struct Graph {
    pub root: PathBuf,
    /// The modules in discovery order. The entry module comes first.
    pub modules: Vec<Module>,
}

impl Graph {
    pub fn module(&self, name: &str) -> Option<&Module> {
        self.modules.iter().find(|module| module.name == name)
    }
}

/// The nearest ancestor directory of `entry` that holds a `package.json`, or else the
/// directory of `entry`.
#[must_use]
pub fn project_root(entry: &Path) -> PathBuf {
    let directory = entry.parent().unwrap_or(Path::new("."));
    directory
        .ancestors()
        .find(|candidate| candidate.join("package.json").is_file())
        .unwrap_or(directory)
        .to_path_buf()
}

/// The Erlang module name of the source file `path` in the project at `root`.
#[must_use]
pub fn module_name(root: &Path, path: &Path) -> String {
    let relative = path.strip_prefix(root).unwrap_or(path).with_extension("");
    let parts: Vec<String> = relative
        .components()
        .filter_map(|component| match component {
            Component::Normal(part) => Some(part.to_string_lossy().into_owned()),
            Component::ParentDir => Some("..".to_owned()),
            _ => None,
        })
        .map(|part| {
            part.chars()
                .map(|c| {
                    if c.is_ascii_alphanumeric() || c == '_' {
                        c
                    } else {
                        '_'
                    }
                })
                .collect()
        })
        .collect();
    // A module name is also a file name, which most file systems cap at 255 bytes.
    crate::erlang::shorten(&format!("bouy@{}", parts.join("@")), 200)
}

/// Reads the entry module and every module it imports, transitively, each with `goal`.
pub fn load(entry: &Path, root: &Path, goal: Goal) -> Result<Graph, Vec<Diagnostic>> {
    let mut modules: Vec<Module> = Vec::new();
    let mut reexports: Vec<Vec<Reexport>> = Vec::new();
    let mut diagnostics = Vec::new();
    let mut queue = VecDeque::from([entry.to_path_buf()]);
    while let Some(path) = queue.pop_front() {
        let name = module_name(root, &path);
        if let Some(existing) = modules.iter().find(|module| module.name == name) {
            if existing.path != path {
                diagnostics.push(Reporter::new(&path, "").at(
                    0,
                    Code::BadImport,
                    format!(
                        "{} and {} both map to the Erlang module {name}; rename one of them",
                        existing.path.display(),
                        path.display()
                    ),
                ));
            }
            continue;
        }
        let source = match fs::read_to_string(&path) {
            Ok(source) => source,
            Err(error) => {
                diagnostics.push(Reporter::new(&path, "").at(
                    0,
                    Code::BadImport,
                    format!("cannot read {}: {error}", path.display()),
                ));
                continue;
            }
        };
        let source_type = source_type(&path, goal);
        match scan(&path, &source, source_type, root, &name) {
            Ok(scanned) => {
                queue.extend(scanned.dependencies);
                reexports.push(scanned.reexports);
                modules.push(Module {
                    path,
                    name,
                    source,
                    source_type,
                    imports: scanned.imports,
                    exports: scanned.exports,
                });
            }
            Err(mut found) => diagnostics.append(&mut found),
        }
    }
    if diagnostics.is_empty() {
        diagnostics = resolve_reexports(&mut modules, &reexports);
    }
    if diagnostics.is_empty() {
        Ok(Graph {
            root: root.to_path_buf(),
            modules,
        })
    } else {
        Err(diagnostics)
    }
}

struct Scanned {
    imports: HashMap<String, String>,
    dependencies: Vec<PathBuf>,
    exports: HashMap<String, Export>,
    reexports: Vec<Reexport>,
}

fn scan(
    path: &Path,
    source: &str,
    source_type: SourceType,
    root: &Path,
    name: &str,
) -> Result<Scanned, Vec<Diagnostic>> {
    with_program(path, source, source_type, |program, semantic| {
        let mut reporter = Reporter::new(path, source);
        let mut scanned = Scanned {
            imports: HashMap::new(),
            dependencies: Vec::new(),
            exports: exports(program, semantic, name),
            reexports: Vec::new(),
        };
        for statement in &program.body {
            let (source, specifiers) = match statement {
                Statement::ImportDeclaration(import) if import.import_kind.is_value() => {
                    if library::is_library(import.source.value.as_str()) {
                        check_library_names(import, semantic, &mut reporter);
                        continue;
                    }
                    (&import.source, None)
                }
                Statement::ExportFromDeclaration(export)
                    if export.export_kind.is_value() && !is_type_only(&export.specifiers) =>
                {
                    (&export.source, Some(&export.specifiers))
                }
                Statement::ExportAllDeclaration(export) if export.export_kind.is_value() => {
                    (&export.source, None)
                }
                _ => continue,
            };
            let specifier = source.value.as_str();
            if library::is_library(specifier) {
                reporter.report(
                    source.span,
                    Code::BadImport,
                    format!("re-exporting \"{specifier}\" is not supported; import it in the module that uses it"),
                );
                continue;
            }
            let Some(dependency) = resolve(path, specifier) else {
                let message = if specifier.starts_with("./") || specifier.starts_with("../") {
                    format!(
                        "cannot find the module \"{specifier}\"; check the path and the file extension"
                    )
                } else {
                    format!(
                        "cannot import \"{specifier}\": import a relative module (./file.ts) or one of the libraries bouy, effect, ai, and @ai-sdk/openai"
                    )
                };
                reporter.report(source.span, Code::BadImport, message);
                continue;
            };
            let from = module_name(root, &dependency);
            scanned.imports.insert(specifier.to_owned(), from.clone());
            scanned.dependencies.push(dependency);
            match statement {
                Statement::ExportFromDeclaration(_) => {
                    for item in specifiers.into_iter().flatten() {
                        if item.export_kind.is_value() {
                            scanned.reexports.push(Reexport::Named {
                                from: from.clone(),
                                imported: item.local.name().to_string(),
                                exported: item.exported.name().to_string(),
                                span: item.span,
                            });
                        }
                    }
                }
                Statement::ExportAllDeclaration(export) => {
                    scanned.reexports.push(match &export.exported {
                        Some(exported) => Reexport::Namespace {
                            from,
                            exported: exported.name().to_string(),
                        },
                        None => Reexport::All { from },
                    });
                }
                _ => {}
            }
        }
        if reporter.diagnostics.is_empty() {
            Ok(scanned)
        } else {
            Err(reporter.diagnostics)
        }
    })?
}

/// `export { type A, type B } from "./m.ts"`: nothing but types, which are erased.
fn is_type_only(specifiers: &[oxc::ast::ast::ExportSpecifier<'_>]) -> bool {
    specifiers
        .iter()
        .all(|specifier| specifier.export_kind.is_type())
}

/// Adds the re-exports of each module to its export table, following chains of re-exports,
/// and reports a named re-export that its module does not export.
fn resolve_reexports(modules: &mut [Module], reexports: &[Vec<Reexport>]) -> Vec<Diagnostic> {
    let position =
        |modules: &[Module], name: &str| modules.iter().position(|module| module.name == name);
    loop {
        let mut changed = false;
        for (index, pending) in reexports.iter().enumerate() {
            for reexport in pending {
                let found: Vec<(String, Export)> = match reexport {
                    Reexport::Named {
                        from,
                        imported,
                        exported,
                        ..
                    } => position(modules, from)
                        .and_then(|from| modules[from].exports.get(imported))
                        .map(|export| vec![(exported.clone(), export.clone())])
                        .unwrap_or_default(),
                    Reexport::All { from } => position(modules, from)
                        .map(|from| {
                            modules[from]
                                .exports
                                .iter()
                                .filter(|(name, _)| *name != "default")
                                .map(|(name, export)| (name.clone(), export.clone()))
                                .collect()
                        })
                        .unwrap_or_default(),
                    Reexport::Namespace { from, exported } => vec![(
                        exported.clone(),
                        Export {
                            module: from.clone(),
                            local: String::new(),
                            kind: ExportKind::Namespace,
                        },
                    )],
                };
                for (name, export) in found {
                    if let Entry::Vacant(slot) = modules[index].exports.entry(name) {
                        slot.insert(export);
                        changed = true;
                    }
                }
            }
        }
        if !changed {
            break;
        }
    }
    let mut diagnostics = Vec::new();
    for (module, pending) in modules.iter().zip(reexports) {
        for reexport in pending {
            if let Reexport::Named {
                from,
                imported,
                exported,
                span,
            } = reexport
                && !module.exports.contains_key(exported)
            {
                diagnostics.push(Reporter::new(&module.path, &module.source).at(
                    span.start as usize,
                    Code::MissingExport,
                    format!("the module {from} does not export `{imported}`"),
                ));
            }
        }
    }
    diagnostics
}

fn check_library_names(
    import: &oxc::ast::ast::ImportDeclaration<'_>,
    semantic: &Semantic<'_>,
    reporter: &mut Reporter<'_>,
) {
    let specifier = import.source.value.as_str();
    for item in import.specifiers.iter().flatten() {
        if !has_value_use(semantic, item.local()) {
            continue;
        }
        let binding = match item {
            ImportDeclarationSpecifier::ImportSpecifier(named) => {
                library::named_import(specifier, named.imported.name().as_str())
            }
            ImportDeclarationSpecifier::ImportNamespaceSpecifier(_) => {
                library::namespace_import(specifier)
            }
            ImportDeclarationSpecifier::ImportDefaultSpecifier(_) => None,
        };
        if binding.is_none() {
            reporter.report(
                item.span(),
                Code::BadImport,
                format!(
                    "\"{specifier}\" has no export \"{}\" that Bouy provides; section 11 of docs/design/beam-runtime.md lists the supported names",
                    item.local().name
                ),
            );
        }
    }
}

/// Whether an import binding is used as a value. Imports used only as types are erased.
pub fn has_value_use(
    semantic: &Semantic<'_>,
    local: &oxc::ast::ast::BindingIdentifier<'_>,
) -> bool {
    local.symbol_id.get().is_some_and(|symbol| {
        semantic
            .scoping()
            .get_resolved_references(symbol)
            .any(|reference| reference.is_value() && !reference.flags().is_value_as_type())
    })
}

/// The file a relative import specifier names, if it exists.
pub fn resolve(importer: &Path, specifier: &str) -> Option<PathBuf> {
    if !(specifier.starts_with("./") || specifier.starts_with("../")) {
        return None;
    }
    let base = importer.parent()?.join(specifier);
    let text = base.to_string_lossy().into_owned();
    let candidates: Vec<PathBuf> = match base.extension().and_then(|extension| extension.to_str()) {
        Some("ts" | "mts") => vec![base.clone()],
        Some("js") => vec![base.with_extension("ts"), base.clone()],
        Some("mjs") => vec![base.with_extension("mts"), base.clone()],
        _ => vec![
            PathBuf::from(format!("{text}.ts")),
            PathBuf::from(format!("{text}.mts")),
            base.join("index.ts"),
        ],
    };
    candidates
        .into_iter()
        .find(|candidate| candidate.is_file())
        .and_then(|found| found.canonicalize().ok())
}

/// The declarations at module level, exported or not, without default exports.
pub fn module_declarations<'p>(
    program: &'p Program<'p>,
) -> impl Iterator<Item = &'p Declaration<'p>> {
    program.body.iter().filter_map(|statement| match statement {
        Statement::ExportDeclaration(export) => Some(&export.declaration),
        other => other.as_declaration(),
    })
}

/// The function or class of `export default`, when it is a named declaration.
pub fn default_export<'p>(program: &'p Program<'p>) -> Option<DefaultExport<'p>> {
    program.body.iter().find_map(|statement| match statement {
        Statement::ExportDefaultDeclaration(export) => match &export.declaration {
            ExportDefaultDeclarationKind::FunctionDeclaration(function)
                if function.id.is_some() && function.body.is_some() =>
            {
                Some(DefaultExport::Function(function))
            }
            ExportDefaultDeclarationKind::ClassDeclaration(class) if class.id.is_some() => {
                Some(DefaultExport::Class(class))
            }
            _ => None,
        },
        _ => None,
    })
}

/// A named declaration that `export default` exports.
#[derive(Debug, Clone, Copy)]
pub enum DefaultExport<'p> {
    Function(&'p oxc::ast::ast::Function<'p>),
    Class(&'p oxc::ast::ast::Class<'p>),
}

fn exports(
    program: &Program<'_>,
    semantic: &Semantic<'_>,
    module: &str,
) -> HashMap<String, Export> {
    let data = data_imports(program);
    let local: HashMap<String, Export> = module_declarations(program)
        .flat_map(|declaration| declared(declaration, semantic, &data, module))
        .collect();
    let mut exports = HashMap::new();
    for statement in &program.body {
        match statement {
            Statement::ExportDeclaration(export) => {
                exports.extend(declared(&export.declaration, semantic, &data, module));
            }
            Statement::ExportNamedDeclaration(export) if export.export_kind.is_value() => {
                for specifier in &export.specifiers {
                    if let Some(export) = local.get(specifier.local.name().as_str()) {
                        exports.insert(specifier.exported.name().to_string(), export.clone());
                    }
                }
            }
            _ => {}
        }
    }
    let default = default_export(program).map(|default| match default {
        DefaultExport::Function(function) => (function.id.as_ref(), ExportKind::Function),
        DefaultExport::Class(class) => (
            class.id.as_ref(),
            ExportKind::Class(
                classify(class, semantic.scoping(), &data).unwrap_or(ClassKind::Unsupported),
            ),
        ),
    });
    if let Some((Some(id), kind)) = default {
        exports.insert(
            "default".to_owned(),
            Export {
                module: module.to_owned(),
                local: id.name.to_string(),
                kind,
            },
        );
    }
    exports
}

/// The names a module-level declaration introduces, and what each one is.
fn declared(
    declaration: &Declaration<'_>,
    semantic: &Semantic<'_>,
    data: &HashSet<SymbolId>,
    module: &str,
) -> Vec<(String, Export)> {
    let export = |name: &str, kind: ExportKind| {
        (
            name.to_owned(),
            Export {
                module: module.to_owned(),
                local: name.to_owned(),
                kind,
            },
        )
    };
    match declaration {
        Declaration::FunctionDeclaration(function) => function
            .id
            .iter()
            .map(|id| export(&id.name, ExportKind::Function))
            .collect(),
        Declaration::ClassDeclaration(class) => class
            .id
            .iter()
            .map(|id| {
                let kind =
                    classify(class, semantic.scoping(), data).unwrap_or(ClassKind::Unsupported);
                export(&id.name, ExportKind::Class(kind))
            })
            .collect(),
        Declaration::VariableDeclaration(variables)
            if variables.kind == VariableDeclarationKind::Const =>
        {
            variables
                .declarations
                .iter()
                .flat_map(|declarator| {
                    let kind = if is_function_const(declarator) {
                        ExportKind::Function
                    } else {
                        ExportKind::Const
                    };
                    declarator
                        .id
                        .get_binding_identifiers()
                        .into_iter()
                        .map(move |id| export(&id.name, kind.clone()))
                        .collect::<Vec<_>>()
                })
                .collect()
        }
        _ => Vec::new(),
    }
}

/// Whether a module-level `const` declarator holds a function: `const f = (args) => body`
/// compiles as `function f(args) { body }` (section 2).
pub fn is_function_const(declarator: &oxc::ast::ast::VariableDeclarator<'_>) -> bool {
    declarator.init.as_ref().is_some_and(is_function_value)
        && declarator.id.get_binding_identifier().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_modules_from_the_project_root() {
        let root = Path::new("/project");
        assert_eq!(
            module_name(root, Path::new("/project/src/agents/team.ts")),
            "bouy@src@agents@team"
        );
        assert_eq!(
            module_name(root, Path::new("/project/my-app.v2.ts")),
            "bouy@my_app_v2"
        );
        let deep = format!("/project/{}/m.ts", vec!["d".repeat(60); 4].join("/"));
        assert!(module_name(root, Path::new(&deep)).len() <= 200);
    }
}
