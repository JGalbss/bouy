//! The module graph of the reference engine: every module that the entry reaches through
//! `import`, `export ... from`, `import()` of a string, and `require()` of a string, with
//! the format of each file and the syntax facts that linking needs.
//!
//! A `CommonJS` file compiles inside Node's wrapper function, so its code reads `exports`,
//! `require`, `module`, `__filename`, and `__dirname` as parameters.

use std::collections::{HashMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};

use oxc::ast::ast::{
    Argument, CallExpression, Declaration, ExportDefaultDeclarationKind, Expression,
    ImportAttributeKey, ImportDeclarationSpecifier, ImportExpression, ModuleExportName,
    ObjectPropertyKind, Program, PropertyKey, SimpleAssignmentTarget, Statement, WithClause,
};
use oxc::ast_visit::{Visit, walk};
use oxc::semantic::Semantic;
use oxc::span::SourceType;

use super::analyze::Suspends;
use crate::diagnostic::{Code, Diagnostic, Reporter};
use crate::graph::{has_value_use, unit_name};
use crate::parse::with_program_as;
use crate::resolve::{Failure, Format, Mode, Resolver, Target, normalize};

/// The wrapper of a `CommonJS` module, as Node writes it. The source starts on its first
/// line, so line numbers stay.
pub const CJS_WRAPPER: &str = "(function (exports, require, module, __filename, __dirname) { ";

#[derive(Debug)]
pub struct Graph {
    /// The modules in discovery order. The entry module comes first.
    pub units: Vec<Unit>,
}

/// One module file.
#[derive(Debug)]
pub struct Unit {
    pub path: PathBuf,
    /// The Erlang module name.
    pub name: String,
    /// The code to compile: the file, or for `CommonJS` the file inside the wrapper.
    pub source: String,
    pub kind: Kind,
    pub record: Record,
    /// Each string specifier of the module, once per mode.
    pub requests: Vec<Request>,
    /// The diagnostics of a module that does not compile. Loading it throws them, as
    /// Node throws a `SyntaxError` when it loads a module that does not parse.
    pub broken: Vec<Diagnostic>,
    /// Whether the module is a classic script, as test262 runs a test without the
    /// `module` flag: an ES module that parses as a script.
    pub script: bool,
}

impl Unit {
    pub fn source_type(&self) -> SourceType {
        let source_type = self.kind.source_type(&self.path);
        if self.script {
            source_type.with_script(true)
        } else {
            source_type
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Esm,
    CommonJs,
    Json,
    /// `with { type: "text" }`: the text of the file as the default export (import-text).
    Text,
    /// `with { type: "bytes" }`: the bytes of the file in a `Uint8Array` over an immutable
    /// `ArrayBuffer` (import-bytes). The source holds them in hexadecimal.
    Bytes,
}

/// The separator of a request key that carries a module type, such as `./a.txt\0text`.
/// A module of another type is a module record of its own, so the requests, the imports,
/// and the units of the graph key by the pair. The runtime forms the same key for an
/// `import()` with the attribute (`buoy_module:dynamic_import/4`).
pub const TYPE_SEPARATOR: char = '\0';

/// The request key of `specifier` under the import attributes `with`: the specifier with
/// the type of a text or bytes module after the separator, else the specifier.
fn typed(specifier: &str, with: Option<&WithClause<'_>>) -> String {
    let module_type = with.and_then(|with| {
        with.with_entries.iter().find_map(|entry| {
            let key = match &entry.key {
                ImportAttributeKey::Identifier(name) => name.name.as_str(),
                ImportAttributeKey::StringLiteral(literal) => literal.value.as_str(),
            };
            (key == "type").then(|| entry.value.value.as_str())
        })
    });
    match module_type {
        Some(module_type @ ("text" | "bytes")) => {
            format!("{specifier}{TYPE_SEPARATOR}{module_type}")
        }
        _ => specifier.to_owned(),
    }
}

/// The specifier of a request key and the kind of module that its type names.
fn untyped(key: &str) -> (&str, Option<Kind>) {
    match key.split_once(TYPE_SEPARATOR) {
        Some((specifier, "text")) => (specifier, Some(Kind::Text)),
        Some((specifier, "bytes")) => (specifier, Some(Kind::Bytes)),
        _ => (key, None),
    }
}

/// The key of a typed module in the index of the graph: the path with the type after the
/// separator, so that the file can be a module of each type.
fn typed_path(path: &Path, kind: Kind) -> PathBuf {
    let module_type = if kind == Kind::Text { "text" } else { "bytes" };
    PathBuf::from(format!("{}{TYPE_SEPARATOR}{module_type}", path.display()))
}

impl Kind {
    pub fn source_type(self, path: &Path) -> SourceType {
        let typescript = path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| matches!(extension, "ts" | "mts" | "cts" | "tsx"));
        let base = if typescript {
            SourceType::ts()
        } else {
            SourceType::mjs()
        };
        match self {
            Self::Esm | Self::Json | Self::Text | Self::Bytes => base.with_module(true),
            Self::CommonJs => base.with_script(true),
        }
    }
}

/// A string specifier and what it names.
#[derive(Debug, Clone)]
pub struct Request {
    pub specifier: String,
    pub mode: Mode,
    pub resolved: Resolved,
}

#[derive(Debug, Clone)]
pub enum Resolved {
    /// A module of the graph, by its index.
    Unit(usize, PathBuf),
    /// A file that the module only resolves.
    Path(PathBuf),
    Builtin(String),
    Missing(Failure),
}

/// What an import or a re-export takes from its module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Imported {
    Name(String),
    Namespace,
    /// `import defer * as ns`: the namespace of a module that evaluates on first use.
    DeferredNamespace,
}

/// The syntax facts of a module that linking needs.
#[derive(Debug, Default)]
pub struct Record {
    /// The specifiers of `import` and `export ... from` in source order, once for each
    /// phase: `true` for `import defer`.
    pub order: Vec<(String, bool)>,
    /// `(local, specifier, imported)`
    pub imports: Vec<(String, String, Imported)>,
    /// `(export name, local name)`. The local name of `export default <expression>` and
    /// of an anonymous default function or class is `*default*`.
    pub locals: Vec<(String, String)>,
    /// `(export name, specifier, imported)` for `export { x } from` and `export * as`.
    pub indirect: Vec<(String, String, Imported)>,
    /// The specifiers of `export * from`.
    pub stars: Vec<String>,
    /// The names that Node's cjs-module-lexer finds in a `CommonJS` module.
    pub cjs_names: Vec<String>,
    /// The specifiers whose exports a `CommonJS` module re-exports.
    pub cjs_reexports: Vec<String>,
    /// Whether the top-level code awaits.
    pub has_await: bool,
    /// The local names of the top-level function declarations that the code never
    /// assigns: an importer may call such a function as its Erlang function.
    pub functions: Vec<String>,
}

/// Reads the entry module and every module it reaches. A module other than the entry
/// that does not parse becomes a broken unit, which throws when the program loads it.
/// When `script` holds, the entry is a classic script. `text`, when given, is the source of
/// the entry, which then need not exist as a file.
pub fn load(
    entry: &Path,
    root: &Path,
    script: bool,
    mut text: Option<String>,
) -> Result<Graph, Vec<Diagnostic>> {
    let resolver = Resolver::default();
    let mut units: Vec<Unit> = Vec::new();
    let mut index: HashMap<PathBuf, usize> = HashMap::new();
    let mut names: HashMap<String, PathBuf> = HashMap::new();
    let mut queue = VecDeque::from([entry.to_path_buf()]);
    // A classic script is not a module: an import of its own file loads that file again as
    // a module of its own, so the script holds no path that a request can find.
    let entry_key = if script {
        PathBuf::new()
    } else {
        entry.to_path_buf()
    };
    index.insert(entry_key, 0);
    while let Some(path) = queue.pop_front() {
        if let (file, Some(kind)) = untyped(&path.to_string_lossy()) {
            units.push(typed_unit(root, Path::new(file), kind));
            continue;
        }
        let mut name = unit_name(root, &path);
        if script && !units.is_empty() && path == entry {
            name.push_str("@module");
        }
        let scanned = match names.insert(name.clone(), path.clone()) {
            Some(other) => Err(vec![Reporter::new(&path, "").at(
                0,
                Code::BadImport,
                format!(
                    "{} and {} both map to the Erlang module {name}; rename one of them",
                    other.display(),
                    path.display()
                ),
            )]),
            None if units.is_empty() && text.is_some() => {
                scan(&resolver, &path, text.take().unwrap_or_default(), script)
            }
            None => fs::read_to_string(&path)
                .map_err(|error| {
                    vec![Reporter::new(&path, "").at(
                        0,
                        Code::BadImport,
                        format!("cannot read {}: {error}", path.display()),
                    )]
                })
                .and_then(|text| scan(&resolver, &path, text, script && units.is_empty())),
        };
        let scanned = match scanned {
            Ok(scanned) => scanned,
            Err(diagnostics) if units.is_empty() => return Err(diagnostics),
            Err(diagnostics) => {
                units.push(Unit {
                    kind: broken_kind(&resolver, &path),
                    path,
                    name,
                    source: String::new(),
                    record: Record::default(),
                    requests: Vec::new(),
                    broken: diagnostics,
                    script: false,
                });
                continue;
            }
        };
        let requests = requests_of(&resolver, &path, &scanned, &mut index, &mut queue);
        units.push(Unit {
            path,
            name,
            source: scanned.source,
            kind: scanned.kind,
            record: scanned.record,
            requests,
            broken: Vec::new(),
            script: script && units.is_empty(),
        });
    }
    Ok(Graph { units })
}

/// A text or bytes module of the file at `path`. A file that cannot be read makes a broken
/// unit, which throws when the program loads it.
fn typed_unit(root: &Path, path: &Path, kind: Kind) -> Unit {
    let suffix = if kind == Kind::Text {
        "@text"
    } else {
        "@bytes"
    };
    let (source, broken) = match fs::read(path) {
        Ok(bytes) if kind == Kind::Bytes => (
            bytes.iter().map(|byte| format!("{byte:02x}")).collect(),
            Vec::new(),
        ),
        // UTF-8 decode, which replaces a bad sequence and drops a byte order mark.
        Ok(bytes) => {
            let text = String::from_utf8_lossy(&bytes);
            (
                text.strip_prefix('\u{feff}').unwrap_or(&text).to_owned(),
                Vec::new(),
            )
        }
        Err(error) => (
            String::new(),
            vec![Reporter::new(path, "").at(
                0,
                Code::BadImport,
                format!("cannot read {}: {error}", path.display()),
            )],
        ),
    };
    Unit {
        path: path.to_path_buf(),
        name: format!("{}{suffix}", unit_name(root, path)),
        source,
        kind,
        record: Record::default(),
        requests: Vec::new(),
        broken,
        script: false,
    }
}

/// The requests of a module: its string specifiers, then the bare strings that a
/// computed specifier may be. It queues the files of the program that they name.
fn requests_of(
    resolver: &Resolver,
    path: &Path,
    scanned: &Scanned,
    index: &mut HashMap<PathBuf, usize>,
    queue: &mut VecDeque<PathBuf>,
) -> Vec<Request> {
    let mut specifiers = scanned.specifiers.clone();
    // A module that only `require.resolve` names is not loaded.
    specifiers.sort_by_key(|(_, _, resolve_only)| *resolve_only);
    let mut requests: Vec<Request> = Vec::new();
    for (specifier, mode, resolve_only) in specifiers {
        if requests
            .iter()
            .any(|request| request.specifier == specifier && request.mode == mode)
        {
            continue;
        }
        let (plain, kind) = untyped(&specifier);
        let target = match (resolver.resolve(plain, path, mode), kind) {
            (Ok(Target::File(found)), None) if resolve_only && !index.contains_key(&found) => {
                Resolved::Path(found)
            }
            (Ok(Target::File(found)), Some(kind)) => {
                resolved_of(Ok(Target::File(typed_path(&found, kind))), index, queue)
            }
            (result, _) => resolved_of(result, index, queue),
        };
        requests.push(Request {
            specifier,
            mode,
            resolved: target,
        });
    }
    for found in speculative(path, &scanned.dynamic) {
        enqueue(index, queue, found);
    }
    for (specifier, mode, result) in bare_requests(resolver, path, &scanned.dynamic, &requests) {
        requests.push(Request {
            specifier,
            mode,
            resolved: resolved_of(result, index, queue),
        });
    }
    requests
}

fn resolved_of(
    result: Result<Target, Failure>,
    index: &mut HashMap<PathBuf, usize>,
    queue: &mut VecDeque<PathBuf>,
) -> Resolved {
    match result {
        Ok(Target::File(found)) => Resolved::Unit(enqueue(index, queue, found.clone()), found),
        Ok(Target::Builtin(builtin)) => Resolved::Builtin(builtin),
        Err(failure) => Resolved::Missing(failure),
    }
}

/// Whether a string looks like a bare specifier: a package name, then a subpath.
fn looks_bare(text: &str) -> bool {
    let first = text.chars().next();
    text.len() < 214
        && first.is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '@')
        && text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "@/._-".contains(c))
}

/// The requests of the bare strings of a module that computes a specifier: each that
/// resolves, or fails for a reason other than a missing package, such as a subpath
/// that `exports` does not export.
fn bare_requests(
    resolver: &Resolver,
    path: &Path,
    dynamic: &Dynamic,
    known: &[Request],
) -> Vec<(String, Mode, Result<Target, Failure>)> {
    if !dynamic.computed {
        return Vec::new();
    }
    let mut found = Vec::new();
    for text in &dynamic.bare {
        for mode in [Mode::Require, Mode::Import] {
            if known
                .iter()
                .any(|request| request.specifier == *text && request.mode == mode)
            {
                continue;
            }
            match resolver.resolve(text, path, mode) {
                Err(failure) if failure.code.ends_with("MODULE_NOT_FOUND") => {}
                result => found.push((text.clone(), mode, result)),
            }
        }
    }
    found
}

/// The index of the module at `found`, queued when it is new.
fn enqueue(
    index: &mut HashMap<PathBuf, usize>,
    queue: &mut VecDeque<PathBuf>,
    found: PathBuf,
) -> usize {
    let next = index.len();
    *index.entry(found.clone()).or_insert_with(|| {
        queue.push_back(found);
        next
    })
}

/// The format of a module that does not compile, from its extension and package scope.
fn broken_kind(resolver: &Resolver, path: &Path) -> Kind {
    match resolver.format(path) {
        Format::CommonJs => Kind::CommonJs,
        Format::Json => Kind::Json,
        _ => Kind::Esm,
    }
}

/// The files that an `import()` or `require()` of a computed specifier may name: each
/// relative path that a string of the module names, and the files that a template such
/// as `./locales/${name}.js` matches in its directory.
fn speculative(path: &Path, dynamic: &Dynamic) -> Vec<PathBuf> {
    if !dynamic.computed {
        return Vec::new();
    }
    let base = path.parent().unwrap_or(Path::new("/"));
    let mut found = Vec::new();
    let mut patterns = dynamic.patterns.clone();
    for text in &dynamic.strings {
        let candidate = normalize(&base.join(text));
        if candidate.is_file() {
            if is_module_file(&candidate) {
                found.push(candidate);
            }
        } else {
            // A string that names no file may be the start of a specifier that the code
            // concatenates, such as `'./locales/' + name`.
            patterns.push(format!("{text}*"));
        }
    }
    for pattern in &patterns {
        let Some((head, tail)) = pattern.split_once('*') else {
            continue;
        };
        let (dir, prefix) = match head.rfind('/') {
            Some(slash) => (&head[..=slash], &head[slash + 1..]),
            None => continue,
        };
        // A wildcard that spans directories is not followed.
        if tail.contains('/') || tail.contains('*') {
            continue;
        }
        let Ok(entries) = fs::read_dir(normalize(&base.join(dir))) else {
            continue;
        };
        // shortcut: a pattern stops at 200 files of a directory, so that a short prefix
        // does not load a whole tree; a bundler-style context map would lift the limit.
        for entry in entries.filter_map(Result::ok).take(200) {
            let name = entry.file_name().to_string_lossy().into_owned();
            let candidate = entry.path();
            if name.starts_with(prefix)
                && name.ends_with(tail)
                && name.len() >= prefix.len() + tail.len()
                && candidate.is_file()
                && is_module_file(&candidate)
            {
                found.push(candidate);
            }
        }
    }
    found
        .into_iter()
        .filter_map(|candidate| candidate.canonicalize().ok())
        .collect()
}

fn is_module_file(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            matches!(
                extension,
                "js" | "mjs" | "cjs" | "ts" | "mts" | "cts" | "json"
            )
        })
}

struct Scanned {
    source: String,
    kind: Kind,
    record: Record,
    /// `(specifier, mode, resolve only)` in source order.
    specifiers: Vec<(String, Mode, bool)>,
    dynamic: Dynamic,
}

/// What a module tells about the specifiers that it computes.
#[derive(Debug, Default)]
struct Dynamic {
    /// Whether an `import()` or `require()` has a specifier that is not a string.
    computed: bool,
    /// The strings of the module that look like relative paths.
    strings: Vec<String>,
    /// The strings of the module that look like bare specifiers, such as `pkg/sub`.
    bare: Vec<String>,
    /// The templates of computed specifiers, each expression as `*`.
    patterns: Vec<String>,
}

/// Decides the format of a file and reads its syntax facts.
fn scan(
    resolver: &Resolver,
    path: &Path,
    text: String,
    script: bool,
) -> Result<Scanned, Vec<Diagnostic>> {
    let format = if script {
        Format::Esm
    } else {
        resolver.format(path)
    };
    let kind = match format {
        Format::Esm => Kind::Esm,
        Format::CommonJs => Kind::CommonJs,
        Format::Json => {
            return Ok(Scanned {
                source: text,
                kind: Kind::Json,
                record: Record::default(),
                specifiers: Vec::new(),
                dynamic: Dynamic::default(),
            });
        }
        Format::Addon => {
            return Err(vec![Reporter::new(path, "").at(
                0,
                Code::HostApi,
                format!(
                    "{} is a native addon, which runs only on Node; use the package's WebAssembly or pure-JavaScript build",
                    path.display()
                ),
            )]);
        }
        Format::Detect => detect(path, &text),
    };
    let source = match kind {
        Kind::CommonJs => wrap(&text),
        _ => text,
    };
    let source_type = if script {
        kind.source_type(path).with_script(true)
    } else {
        kind.source_type(path)
    };
    let typescript = source_type.is_typescript();
    let facts = with_program_as(path, &source, source_type, |program, semantic| {
        let mut facts = Facts {
            semantic,
            typescript,
            record: Record::default(),
            specifiers: Vec::new(),
        };
        // A CommonJS module has no static requests.
        if kind == Kind::Esm {
            facts.module(program);
        }
        let mut requests = Requests {
            found: Vec::new(),
            names: Vec::new(),
            reexports: Vec::new(),
            dynamic: Dynamic::default(),
            required: Vec::new(),
        };
        requests.visit_program(program);
        facts.specifiers.append(&mut requests.found);
        if kind == Kind::CommonJs {
            facts.record.cjs_names = requests.names;
            facts.record.cjs_reexports = requests.reexports;
        }
        (facts.record, facts.specifiers, requests.dynamic)
    })?;
    Ok(Scanned {
        source,
        kind,
        record: facts.0,
        specifiers: facts.1,
        dynamic: facts.2,
    })
}

/// Node's syntax detection for a file without a package `type`: ESM when it parses as a
/// module and has `import`, `export`, `import.meta`, or a top-level `await`.
fn detect(path: &Path, text: &str) -> Kind {
    let source_type = Kind::Esm.source_type(path);
    let esm = crate::parse::parses(path, text, source_type, |program, module_syntax| {
        if module_syntax {
            return true;
        }
        let mut suspends = Suspends::default();
        let mut meta = HasImportMeta(false);
        for statement in &program.body {
            suspends.visit_statement(statement);
            meta.visit_statement(statement);
        }
        suspends.0 || meta.0
    });
    if esm.unwrap_or(false) {
        Kind::Esm
    } else {
        Kind::CommonJs
    }
}

struct HasImportMeta(bool);

impl Visit<'_> for HasImportMeta {
    fn visit_import_meta(&mut self, _it: &oxc::ast::ast::ImportMeta) {
        self.0 = true;
    }
}

/// The source of a `CommonJS` module inside Node's wrapper. A hashbang line becomes a
/// comment of the same length.
fn wrap(text: &str) -> String {
    let body = match text.strip_prefix("#!") {
        Some(rest) => format!("//{rest}"),
        None => text.to_owned(),
    };
    format!("{CJS_WRAPPER}{body}\n}})")
}

struct Facts<'s, 'a> {
    semantic: &'s Semantic<'a>,
    typescript: bool,
    record: Record,
    specifiers: Vec<(String, Mode, bool)>,
}

impl<'a> Facts<'_, 'a> {
    fn request(&mut self, specifier: &str) {
        self.add_request(specifier, false);
    }

    /// A request of `import defer`, which evaluates only the modules with top-level
    /// await that it reaches.
    fn deferred_request(&mut self, specifier: &str) {
        self.add_request(specifier, true);
    }

    fn add_request(&mut self, specifier: &str, deferred: bool) {
        let entry = (specifier.to_owned(), deferred);
        if !self.record.order.contains(&entry) {
            self.record.order.push(entry);
        }
        self.specifiers
            .push((specifier.to_owned(), Mode::Import, false));
    }

    /// The imports and exports of an ES module.
    fn module(&mut self, program: &Program<'a>) {
        for statement in &program.body {
            match statement {
                Statement::ImportDeclaration(import) => {
                    if !import.import_kind.is_value() {
                        continue;
                    }
                    if import.source.value == "buoy" {
                        continue;
                    }
                    let key = typed(import.source.value.as_str(), import.with_clause.as_deref());
                    let specifier = key.as_str();
                    let deferred = matches!(import.phase, Some(oxc::ast::ast::ImportPhase::Defer));
                    let mut kept = import.specifiers.is_none();
                    for item in import.specifiers.iter().flatten() {
                        // TypeScript erases an import that no value reads.
                        if self.typescript && !has_value_use(self.semantic, item.local()) {
                            continue;
                        }
                        kept = true;
                        let imported = match item {
                            ImportDeclarationSpecifier::ImportSpecifier(named) => {
                                if !named.import_kind.is_value() {
                                    continue;
                                }
                                Imported::Name(named.imported.name().to_string())
                            }
                            ImportDeclarationSpecifier::ImportDefaultSpecifier(_) => {
                                Imported::Name("default".to_owned())
                            }
                            ImportDeclarationSpecifier::ImportNamespaceSpecifier(_) => {
                                if deferred {
                                    Imported::DeferredNamespace
                                } else {
                                    Imported::Namespace
                                }
                            }
                        };
                        self.record.imports.push((
                            item.local().name.to_string(),
                            specifier.to_owned(),
                            imported,
                        ));
                    }
                    if (kept || !self.typescript) && deferred {
                        self.deferred_request(specifier);
                    } else if kept || !self.typescript {
                        self.request(specifier);
                    }
                }
                _ => self.export(statement),
            }
        }
        let mut suspends = Suspends::default();
        for statement in &program.body {
            suspends.visit_statement(statement);
        }
        self.record.has_await = suspends.0;
        self.record.functions = self.functions(program);
    }

    /// The top-level function declarations that no code assigns.
    fn functions(&self, program: &Program<'a>) -> Vec<String> {
        use oxc::ast::ast::ExportDefaultDeclarationKind as Default;
        let scoping = self.semantic.scoping();
        let fixed = |function: &oxc::ast::ast::Function<'_>| {
            function.body.is_some()
                && function.id.as_ref().is_none_or(|id| {
                    id.symbol_id.get().is_some_and(|symbol| {
                        !scoping
                            .get_resolved_references(symbol)
                            .any(oxc::semantic::Reference::is_write)
                    })
                })
        };
        program
            .body
            .iter()
            .filter_map(|statement| {
                let function = match statement {
                    Statement::FunctionDeclaration(function) => function,
                    Statement::ExportDeclaration(export) => match &export.declaration {
                        Declaration::FunctionDeclaration(function) => function,
                        _ => return None,
                    },
                    Statement::ExportDefaultDeclaration(export) => match &export.declaration {
                        Default::FunctionDeclaration(function) => function,
                        _ => return None,
                    },
                    _ => return None,
                };
                fixed(function).then(|| {
                    function
                        .id
                        .as_ref()
                        .map_or_else(|| "*default*".to_owned(), |id| id.name.to_string())
                })
            })
            .collect()
    }

    /// The export entries of an export statement.
    fn export(&mut self, statement: &Statement<'a>) {
        match statement {
            Statement::ExportDeclaration(export) => {
                for name in declared_names(&export.declaration) {
                    self.record.locals.push((name.clone(), name));
                }
            }
            Statement::ExportFromDeclaration(export) => {
                if !export.export_kind.is_value() {
                    return;
                }
                let key = typed(export.source.value.as_str(), export.with_clause.as_deref());
                let specifier = key.as_str();
                let mut any = false;
                for item in &export.specifiers {
                    if !item.export_kind.is_value() {
                        continue;
                    }
                    any = true;
                    self.record.indirect.push((
                        export_name(&item.exported),
                        specifier.to_owned(),
                        Imported::Name(export_name(&item.local)),
                    ));
                }
                if any || export.specifiers.is_empty() || !self.typescript {
                    self.request(specifier);
                }
            }
            Statement::ExportNamedDeclaration(export) => {
                if !export.export_kind.is_value() {
                    return;
                }
                for item in &export.specifiers {
                    if !item.export_kind.is_value() || !self.is_value(&item.local) {
                        continue;
                    }
                    self.record
                        .locals
                        .push((export_name(&item.exported), export_name(&item.local)));
                }
            }
            Statement::ExportDefaultDeclaration(export) => {
                let local = match &export.declaration {
                    ExportDefaultDeclarationKind::FunctionDeclaration(function) => function
                        .id
                        .as_ref()
                        .map_or_else(|| "*default*".to_owned(), |id| id.name.to_string()),
                    ExportDefaultDeclarationKind::ClassDeclaration(class) => class
                        .id
                        .as_ref()
                        .map_or_else(|| "*default*".to_owned(), |id| id.name.to_string()),
                    ExportDefaultDeclarationKind::TSInterfaceDeclaration(_) => return,
                    _ => "*default*".to_owned(),
                };
                self.record.locals.push(("default".to_owned(), local));
            }
            Statement::ExportAllDeclaration(export) => {
                if !export.export_kind.is_value() {
                    return;
                }
                let key = typed(export.source.value.as_str(), export.with_clause.as_deref());
                let specifier = key.as_str();
                match &export.exported {
                    Some(exported) => self.record.indirect.push((
                        export_name(exported),
                        specifier.to_owned(),
                        Imported::Namespace,
                    )),
                    None => self.record.stars.push(specifier.to_owned()),
                }
                self.request(specifier);
            }
            _ => {}
        }
    }

    /// Whether the local name of `export { x }` is a value: TypeScript erases a type.
    fn is_value(&self, local: &ModuleExportName<'a>) -> bool {
        if !self.typescript {
            return true;
        }
        let ModuleExportName::IdentifierReference(reference) = local else {
            return true;
        };
        let Some(reference) = reference.reference_id.get() else {
            return true;
        };
        let scoping = self.semantic.scoping();
        match scoping.get_reference(reference).symbol_id() {
            Some(symbol) => {
                let flags = scoping.symbol_flags(symbol);
                flags.is_value()
                    || (flags.is_import() && has_value_use_symbol(self.semantic, symbol))
            }
            None => true,
        }
    }
}

fn has_value_use_symbol(semantic: &Semantic<'_>, symbol: oxc::semantic::SymbolId) -> bool {
    semantic
        .scoping()
        .get_resolved_references(symbol)
        .any(|reference| reference.is_value() && !reference.flags().is_value_as_type())
}

pub fn export_name(name: &ModuleExportName<'_>) -> String {
    name.name().to_string()
}

/// The value names that an exported declaration binds. TypeScript-only declarations bind
/// none.
fn declared_names(declaration: &Declaration<'_>) -> Vec<String> {
    match declaration {
        Declaration::VariableDeclaration(variables) if !variables.declare => variables
            .declarations
            .iter()
            .flat_map(|declarator| declarator.id.get_binding_identifiers())
            .map(|id| id.name.to_string())
            .collect(),
        Declaration::FunctionDeclaration(function) if !function.declare => {
            function.id.iter().map(|id| id.name.to_string()).collect()
        }
        Declaration::ClassDeclaration(class) if !class.declare => {
            class.id.iter().map(|id| id.name.to_string()).collect()
        }
        _ => Vec::new(),
    }
}

/// The string specifiers of `import()`, `require()`, and `require.resolve()`, and the
/// export names of a `CommonJS` module, as Node's cjs-module-lexer finds them.
struct Requests {
    found: Vec<(String, Mode, bool)>,
    names: Vec<String>,
    reexports: Vec<String>,
    dynamic: Dynamic,
    /// `var ID = require('x')`, by `ID`, for Babel's re-export of `x`.
    required: Vec<(String, String)>,
}

impl Requests {
    /// A specifier that is not a string: a template becomes a pattern.
    fn computed(&mut self, specifier: Option<&Expression<'_>>) {
        self.dynamic.computed = true;
        if let Some(Expression::TemplateLiteral(template)) =
            specifier.map(Expression::without_parentheses)
        {
            let parts: Vec<String> = template
                .quasis
                .iter()
                .map(|quasi| quasi.value.raw.to_string())
                .collect();
            self.dynamic.patterns.push(parts.join("*"));
        }
    }

    fn name(&mut self, name: &str) {
        if !self.names.iter().any(|known| known == name) {
            self.names.push(name.to_owned());
        }
    }
}

/// The text of a string literal or of a template without expressions.
fn string_of(expression: &Expression<'_>) -> Option<String> {
    match expression {
        Expression::StringLiteral(literal) => Some(literal.value.to_string()),
        Expression::TemplateLiteral(template) if template.expressions.is_empty() => template
            .quasis
            .first()
            .and_then(|quasi| quasi.value.cooked.as_ref())
            .map(ToString::to_string),
        Expression::ParenthesizedExpression(inner) => string_of(&inner.expression),
        _ => None,
    }
}

/// The specifier of `require('x')`.
fn required(expression: &Expression<'_>) -> Option<String> {
    let Expression::CallExpression(call) = expression.without_parentheses() else {
        return None;
    };
    match &call.callee {
        Expression::Identifier(callee) if callee.name == "require" => call
            .arguments
            .first()
            .and_then(Argument::as_expression)
            .and_then(string_of),
        _ => None,
    }
}

/// Whether an expression is `exports` or `module.exports`.
fn is_exports(expression: &Expression<'_>) -> bool {
    match expression.without_parentheses() {
        Expression::Identifier(ident) => ident.name == "exports",
        Expression::StaticMemberExpression(member) => {
            member.property.name == "exports"
                && matches!(&member.object, Expression::Identifier(object) if object.name == "module")
        }
        _ => false,
    }
}

impl<'a> Visit<'a> for Requests {
    fn visit_import_expression(&mut self, it: &ImportExpression<'a>) {
        match string_of(&it.source) {
            Some(specifier) => {
                let key = match it.options.as_ref().and_then(options_type) {
                    Some(module_type) => format!("{specifier}{TYPE_SEPARATOR}{module_type}"),
                    None => specifier,
                };
                self.found.push((key, Mode::Import, false));
            }
            None => self.computed(Some(&it.source)),
        }
        walk::walk_import_expression(self, it);
    }

    fn visit_string_literal(&mut self, it: &oxc::ast::ast::StringLiteral<'a>) {
        let text = it.value.as_str();
        if (text.starts_with("./") || text.starts_with("../")) && text.len() < 256 {
            self.dynamic.strings.push(text.to_owned());
        } else if looks_bare(text) {
            self.dynamic.bare.push(text.to_owned());
        }
    }

    fn visit_variable_declarator(&mut self, it: &oxc::ast::ast::VariableDeclarator<'a>) {
        if let (Some(id), Some(init)) = (it.id.get_binding_identifier(), &it.init) {
            // Babel wraps the require: `_interopRequireWildcard(require('x'))`.
            let specifier = required(init).or_else(|| match init.without_parentheses() {
                Expression::CallExpression(call) => call
                    .arguments
                    .first()
                    .and_then(Argument::as_expression)
                    .and_then(required),
                _ => None,
            });
            if let Some(specifier) = specifier {
                self.required.push((id.name.to_string(), specifier));
            }
        }
        walk::walk_variable_declarator(self, it);
    }

    fn visit_call_expression(&mut self, it: &CallExpression<'a>) {
        // Babel's re-export: `Object.keys(_x).forEach(...)` over `var _x = require('x')`.
        if let Expression::StaticMemberExpression(member) = &it.callee
            && member.property.name == "forEach"
            && let Expression::CallExpression(keys) = &member.object
            && let Expression::StaticMemberExpression(callee) = &keys.callee
            && callee.property.name == "keys"
            && matches!(&callee.object, Expression::Identifier(object) if object.name == "Object")
            && let Some(Expression::Identifier(source)) =
                keys.arguments.first().and_then(Argument::as_expression)
            && let Some((_, specifier)) = self
                .required
                .iter()
                .find(|(name, _)| name == source.name.as_str())
        {
            self.reexports.push(specifier.clone());
        }
        let first = it.arguments.first().and_then(Argument::as_expression);
        match &it.callee {
            Expression::Identifier(callee) if callee.name == "require" => {
                match first.and_then(string_of) {
                    Some(specifier) => self.found.push((specifier, Mode::Require, false)),
                    None if first.is_some() => self.computed(first),
                    None => {}
                }
            }
            Expression::StaticMemberExpression(member) => {
                let object = &member.object;
                let property = member.property.name.as_str();
                if property == "resolve"
                    && matches!(object, Expression::Identifier(ident) if ident.name == "require")
                    && let Some(specifier) = first.and_then(string_of)
                {
                    self.found.push((specifier, Mode::Require, true));
                }
                if property == "resolve"
                    && matches!(object, Expression::ImportMeta(_))
                    && let Some(specifier) = first.and_then(string_of)
                {
                    self.found.push((specifier, Mode::Import, true));
                }
                // Object.defineProperty(exports, 'name', ...)
                if property == "defineProperty"
                    && matches!(object, Expression::Identifier(ident) if ident.name == "Object")
                    && first.is_some_and(is_exports)
                    && let Some(name) = it
                        .arguments
                        .get(1)
                        .and_then(Argument::as_expression)
                        .and_then(string_of)
                {
                    self.name(&name);
                }
                // __exportStar(require('x'), exports) and tslib's __export(require('x'))
            }
            Expression::Identifier(callee)
                if matches!(callee.name.as_str(), "__exportStar" | "__export") =>
            {
                if let Some(specifier) = first.and_then(required) {
                    self.reexports.push(specifier);
                }
            }
            _ => {}
        }
        walk::walk_call_expression(self, it);
    }

    fn visit_assignment_expression(&mut self, it: &oxc::ast::ast::AssignmentExpression<'a>) {
        if let Some(target) = it.left.as_simple_assignment_target() {
            match target {
                // exports.name = ... and module.exports.name = ...
                SimpleAssignmentTarget::StaticMemberExpression(member)
                    if is_exports(&member.object) =>
                {
                    self.name(member.property.name.as_str());
                }
                SimpleAssignmentTarget::ComputedMemberExpression(member)
                    if is_exports(&member.object) =>
                {
                    if let Some(name) = string_of(&member.expression) {
                        self.name(&name);
                    }
                }
                // module.exports = ...
                SimpleAssignmentTarget::StaticMemberExpression(member)
                    if member.property.name == "exports"
                        && matches!(&member.object, Expression::Identifier(object) if object.name == "module") =>
                {
                    self.module_exports(&it.right);
                }
                _ => {}
            }
        }
        walk::walk_assignment_expression(self, it);
    }
}

impl Requests {
    /// `module.exports = { a, b: c, ...require('x') }` and `module.exports = require('x')`.
    fn module_exports(&mut self, value: &Expression<'_>) {
        if let Some(specifier) = required(value) {
            self.reexports.push(specifier);
            return;
        }
        let Expression::ObjectExpression(object) = value.without_parentheses() else {
            return;
        };
        for property in &object.properties {
            match property {
                ObjectPropertyKind::ObjectProperty(property) if !property.computed => {
                    let name = match &property.key {
                        PropertyKey::StaticIdentifier(ident) => Some(ident.name.to_string()),
                        PropertyKey::StringLiteral(literal) => Some(literal.value.to_string()),
                        _ => None,
                    };
                    if let Some(name) = name {
                        self.name(&name);
                    }
                }
                ObjectPropertyKind::SpreadProperty(spread) => {
                    if let Some(specifier) = required(&spread.argument) {
                        self.reexports.push(specifier);
                    }
                }
                ObjectPropertyKind::ObjectProperty(_) => {}
            }
        }
    }
}

/// The text or bytes type of the options of an `import()` that names it literally, such as
/// `{ with: { type: "text" } }`.
fn options_type<'b>(options: &'b Expression<'_>) -> Option<&'b str> {
    let Expression::ObjectExpression(options) = options.without_parentheses() else {
        return None;
    };
    let with = options
        .properties
        .iter()
        .find_map(|property| match property {
            ObjectPropertyKind::ObjectProperty(property)
                if !property.computed && property.key.static_name().as_deref() == Some("with") =>
            {
                Some(&property.value)
            }
            _ => None,
        })?;
    let Expression::ObjectExpression(with) = with.without_parentheses() else {
        return None;
    };
    with.properties.iter().find_map(|property| match property {
        ObjectPropertyKind::ObjectProperty(property)
            if !property.computed && property.key.static_name().as_deref() == Some("type") =>
        {
            match &property.value {
                Expression::StringLiteral(literal)
                    if matches!(literal.value.as_str(), "text" | "bytes") =>
                {
                    Some(literal.value.as_str())
                }
                _ => None,
            }
        }
        _ => None,
    })
}
