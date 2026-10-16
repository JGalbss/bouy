//! The module graph: the project root, module names, import resolution, and export tables.

use std::collections::{HashMap, VecDeque};
use std::fs;
use std::path::{Component, Path, PathBuf};

use oxc::ast::ast::{
    Declaration, ExportDefaultDeclarationKind, ImportDeclarationSpecifier, Program, Statement,
    VariableDeclarationKind,
};
use oxc::semantic::Semantic;
use oxc::span::GetSpan;

use crate::diagnostic::{Code, Diagnostic, Reporter};
use crate::library;
use crate::lower::class::{ClassKind, classify};
use crate::lower::function::is_function_value;
use crate::parse::with_program;

/// One Bouy module of the graph.
#[derive(Debug)]
pub struct Module {
    pub path: PathBuf,
    /// The Erlang module name (section 2).
    pub name: String,
    pub source: String,
    /// The Erlang module name of each relative import specifier.
    pub imports: HashMap<String, String>,
    /// Each exported name and what it refers to.
    pub exports: HashMap<String, Export>,
}

/// What an exported name refers to in its module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Export {
    /// A function, by its local (Erlang) name.
    Function(String),
    /// A module-level `const`, by its local name.
    Const(String),
    /// A class, by its local name.
    Class(String, ClassKind),
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
    format!("bouy@{}", parts.join("@"))
}

/// Reads the entry module and every module it imports, transitively.
pub fn load(entry: &Path, root: &Path) -> Result<Graph, Vec<Diagnostic>> {
    let mut modules: Vec<Module> = Vec::new();
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
        match scan(&path, &source, root) {
            Ok(scanned) => {
                queue.extend(scanned.dependencies);
                modules.push(Module {
                    path,
                    name,
                    source,
                    imports: scanned.imports,
                    exports: scanned.exports,
                });
            }
            Err(mut found) => diagnostics.append(&mut found),
        }
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
}

fn scan(path: &Path, source: &str, root: &Path) -> Result<Scanned, Vec<Diagnostic>> {
    with_program(path, source, |program, semantic| {
        let mut reporter = Reporter::new(path, source);
        let mut scanned = Scanned {
            imports: HashMap::new(),
            dependencies: Vec::new(),
            exports: exports(program),
        };
        for statement in &program.body {
            if let Statement::ImportDeclaration(import) = statement
                && import.import_kind.is_value()
            {
                let specifier = import.source.value.as_str();
                if library::is_library(specifier) {
                    check_library_names(import, semantic, &mut reporter);
                    continue;
                }
                match resolve(path, specifier) {
                    Some(dependency) => {
                        scanned
                            .imports
                            .insert(specifier.to_owned(), module_name(root, &dependency));
                        scanned.dependencies.push(dependency);
                    }
                    None if specifier.starts_with("./") || specifier.starts_with("../") => {
                        reporter.report(
                            import.source.span,
                            Code::BadImport,
                            format!("cannot find the module \"{specifier}\"; check the path and the file extension"),
                        );
                    }
                    None => reporter.report(
                        import.source.span,
                        Code::BadImport,
                        format!(
                            "cannot import \"{specifier}\": import a relative module (./file.ts) or one of the libraries bouy, effect, ai, and @ai-sdk/openai"
                        ),
                    ),
                }
            }
        }
        if reporter.diagnostics.is_empty() {
            Ok(scanned)
        } else {
            Err(reporter.diagnostics)
        }
    })?
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

fn exports(program: &Program<'_>) -> HashMap<String, Export> {
    let mut exports = HashMap::new();
    for statement in &program.body {
        match statement {
            Statement::ExportDeclaration(export) => {
                for (name, kind) in declared(&export.declaration) {
                    exports.insert(name.clone(), kind);
                }
            }
            Statement::ExportNamedDeclaration(export) if export.export_kind.is_value() => {
                for specifier in &export.specifiers {
                    let local = specifier.local.name();
                    if let Some(kind) = local_export(program, local.as_str()) {
                        exports.insert(specifier.exported.name().to_string(), kind);
                    }
                }
            }
            Statement::ExportDefaultDeclaration(export) => {
                if let ExportDefaultDeclarationKind::FunctionDeclaration(function) =
                    &export.declaration
                    && let Some(id) = &function.id
                {
                    exports.insert(id.name.to_string(), Export::Function(id.name.to_string()));
                }
            }
            _ => {}
        }
    }
    exports
}

fn local_export(program: &Program<'_>, name: &str) -> Option<Export> {
    program.body.iter().find_map(|statement| {
        let declaration = match statement {
            Statement::ExportDeclaration(export) => &export.declaration,
            other => other.as_declaration()?,
        };
        declared(declaration)
            .into_iter()
            .find(|(declared, _)| declared == name)
            .map(|(_, kind)| kind)
    })
}

/// The names a module-level declaration introduces, and what each one is.
fn declared(declaration: &Declaration<'_>) -> Vec<(String, Export)> {
    match declaration {
        Declaration::FunctionDeclaration(function) => function
            .id
            .iter()
            .map(|id| (id.name.to_string(), Export::Function(id.name.to_string())))
            .collect(),
        Declaration::ClassDeclaration(class) => class
            .id
            .iter()
            .map(|id| {
                let kind = classify(class).unwrap_or(ClassKind::Actor);
                (
                    id.name.to_string(),
                    Export::Class(id.name.to_string(), kind),
                )
            })
            .collect(),
        Declaration::VariableDeclaration(variables)
            if variables.kind == VariableDeclarationKind::Const =>
        {
            variables
                .declarations
                .iter()
                .flat_map(|declarator| {
                    let function = declarator.init.as_ref().is_some_and(is_function_value)
                        && declarator.id.get_binding_identifier().is_some();
                    declarator
                        .id
                        .get_binding_identifiers()
                        .into_iter()
                        .map(move |id| {
                            let name = id.name.to_string();
                            let export = if function {
                                Export::Function(name.clone())
                            } else {
                                Export::Const(name.clone())
                            };
                            (name, export)
                        })
                })
                .collect()
        }
        _ => Vec::new(),
    }
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
    }
}
