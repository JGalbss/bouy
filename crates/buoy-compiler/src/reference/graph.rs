//! The module graph of the reference engine: every module that the entry reaches through
//! `import`, `export ... from`, `import()` of a string, and `require()` of a string, with
//! the format of each file and the syntax facts that linking needs.
//!
//! A `CommonJS` file compiles inside Node's wrapper function, so its code reads `exports`,
//! `require`, `module`, `__filename`, and `__dirname` as parameters.

use std::collections::{HashMap, VecDeque};
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

use oxc::ast::ast::{
    Argument, CallExpression, Declaration, ExportDefaultDeclarationKind, Expression,
    ImportAttributeKey, ImportDeclarationSpecifier, ImportExpression, ModuleExportName,
    ObjectPropertyKind, Program, PropertyKey, SimpleAssignmentTarget, Statement, WithClause,
};
use oxc::ast_visit::{Visit, walk};
use oxc::semantic::Semantic;
use oxc::span::{GetSpan, SourceType};

use super::analyze::Suspends;
use crate::diagnostic::{Code, Diagnostic, Reporter};
use crate::graph::{has_value_use, unit_name};
use crate::parse::with_program_as;
use crate::resolve::{self, Failure, Format, Mode, Resolver, Target, normalize};

/// The wrapper of a `CommonJS` module, as Node writes it. The source starts on its first
/// line, so line numbers stay.
pub const CJS_WRAPPER: &str = "(function (exports, require, module, __filename, __dirname) { ";

#[derive(Debug)]
pub struct Graph {
    /// The modules in discovery order. The entry module comes first.
    pub units: Vec<Unit>,
    /// Whether the code of the program may read the legacy `caller` or `arguments` of a
    /// function, so that each function records its call (`reflects_calls`).
    pub reflects_calls: bool,
}

/// Whether `source` may read the legacy `caller` or `arguments` of a function. The text
/// test also finds the names in the strings that eval code or `Function` compiles.
#[must_use]
pub fn reflects_calls(source: &str) -> bool {
    source.contains("caller") || source.contains(".arguments")
}

/// One module file.
#[derive(Debug)]
pub struct Unit {
    pub path: PathBuf,
    /// The Erlang module name.
    pub name: String,
    /// The code to compile: the file, or for `CommonJS` the file inside the wrapper.
    pub source: String,
    /// The binary of a WebAssembly module.
    pub bytes: Vec<u8>,
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
    /// A WebAssembly module: a module record whose imports are the namespaces of other
    /// modules and whose exports are the exports of its instance.
    Wasm,
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
        let typescript = !is_data(path)
            && path
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| matches!(extension, "ts" | "mts" | "cts" | "tsx"));
        let base = if typescript {
            SourceType::ts()
        } else {
            SourceType::mjs()
        };
        match self {
            Self::Esm | Self::Json | Self::Text | Self::Bytes | Self::Wasm => {
                base.with_module(true)
            }
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
    /// A request of a module that the host links at run time (`vm.SourceTextModule` and
    /// Node's ESM loader), by its index among the module's requests.
    Hosted(usize),
}

/// What an import or a re-export takes from its module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Imported {
    Name(String),
    Namespace,
    /// `import defer * as ns`: the namespace of a module that evaluates on first use.
    DeferredNamespace,
    /// `import source m`: the source object of a module, which does not evaluate it.
    Source,
}

/// A request of a module: its specifier, its import attributes sorted by key, and whether
/// it imports the source phase (`import source x from`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleRequest {
    pub specifier: String,
    pub attributes: Vec<(String, String)>,
    pub source_phase: bool,
}

/// The syntax facts of a module that linking needs.
#[derive(Debug, Default)]
pub struct Record {
    /// The specifiers of `import` and `export ... from` in source order, once for each
    /// phase: `true` for `import defer`.
    pub order: Vec<(String, bool)>,
    /// The `ModuleRequest`s of ECMA-262 in source order, once for each specifier,
    /// attributes, and phase, as `getModuleRequests` of a `ModuleWrap` lists them.
    pub module_requests: Vec<ModuleRequest>,
    /// `(local, specifier, imported)`
    pub imports: Vec<(String, String, Imported)>,
    /// `(export name, local name)`. The local name of `export default <expression>` and
    /// of an anonymous default function or class is `*default*`.
    pub locals: Vec<(String, String)>,
    /// `(export name, specifier, imported)` for `export { x } from` and `export * as`.
    pub indirect: Vec<(String, String, Imported)>,
    /// The specifiers of `export * from`.
    pub stars: Vec<String>,
    /// The specifiers of `import source`, whose modules link and evaluate on their own.
    pub sources: Vec<String>,
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
    text: Option<String>,
) -> Result<Graph, Vec<Diagnostic>> {
    load_from(entry, root, script, text, false)
}

/// Reads the graph of a module that a running program loads: by `import` when
/// `imported` holds, else by `require`.
pub fn load_imported(entry: &Path, root: &Path, imported: bool) -> Result<Graph, Vec<Diagnostic>> {
    load_from(entry, root, false, None, imported)
}

fn load_from(
    entry: &Path,
    root: &Path,
    script: bool,
    mut text: Option<String>,
    imported: bool,
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
        // Source text without a file, such as `-e` code, names its module after the text
        // too: two VMs that start from one directory must not load each other's entry.
        let mut name = match &text {
            Some(source) if units.is_empty() => {
                format!(
                    "{}_{:016x}",
                    unit_name(root, &path),
                    crate::erlang::fnv1a(source)
                )
            }
            _ => unit_name(root, &path),
        };
        // The module of the file keeps the name that any program gives it, because a VM
        // loads a module once for all its programs; the script takes a name of its own.
        if script && units.is_empty() {
            name.push_str("@script");
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
            None if is_data(&path) => scan_data(&path),
            None => read(&resolver, &path, units.is_empty() && !imported).and_then(|contents| {
                match contents {
                    Contents::Text(text) => {
                        scan(&resolver, &path, text, script && units.is_empty())
                    }
                    Contents::Wasm(bytes) => Ok(scan_wasm(bytes)),
                }
            }),
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
                    bytes: Vec::new(),
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
            bytes: scanned.bytes,
            kind: scanned.kind,
            record: scanned.record,
            requests,
            broken: Vec::new(),
            script: script && units.is_empty(),
        });
    }
    let reflects_calls = units.iter().any(|unit| reflects_calls(&unit.source));
    Ok(Graph {
        units,
        reflects_calls,
    })
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
            bytes.iter().fold(String::new(), |mut hex, byte| {
                let _ = write!(hex, "{byte:02x}");
                hex
            }),
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

/// The graph of one ES module from source text whose requests the host links at run
/// time, as V8 compiles the source of a `ModuleWrap`: each specifier of `import` and
/// `export ... from` is a `Resolved::Hosted` request, in source order.
pub fn hosted(text: String, name: &str, path: PathBuf) -> Result<Graph, Vec<Diagnostic>> {
    let scanned = scan_as(&path, text, Kind::Esm, false)?;
    let mut requests: Vec<Request> = Vec::new();
    for (specifier, _) in &scanned.record.order {
        if requests
            .iter()
            .all(|request| &request.specifier != specifier)
        {
            requests.push(Request {
                specifier: specifier.clone(),
                mode: Mode::Import,
                resolved: Resolved::Hosted(requests.len()),
            });
        }
    }
    Ok(Graph {
        units: vec![Unit {
            path,
            name: name.to_owned(),
            source: scanned.source,
            kind: Kind::Esm,
            record: scanned.record,
            requests,
            broken: Vec::new(),
            script: false,
        }],
        reflects_calls: false,
    })
}

/// The export names and the re-exported specifiers of `CommonJS` source text, as Node's
/// cjs-module-lexer finds them for `internalBinding('cjs_lexer').parse`.
pub fn cjs_lexer(text: String) -> Result<(Vec<String>, Vec<String>), Vec<Diagnostic>> {
    let scanned = scan_as(Path::new("[cjs].cjs"), text, Kind::CommonJs, false)?;
    Ok((scanned.record.cjs_names, scanned.record.cjs_reexports))
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
        Ok(Target::Data(url)) => {
            let found = PathBuf::from(url);
            Resolved::Unit(enqueue(index, queue, found.clone()), found)
        }
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
        Format::Wasm => Kind::Wasm,
        _ => Kind::Esm,
    }
}

/// The contents of a module file: text, or the binary of a WebAssembly module.
enum Contents {
    Text(String),
    Wasm(Vec<u8>),
}

/// The magic number that starts every WebAssembly binary.
const WASM_MAGIC: &[u8] = b"\0asm";

/// Reads a module file. A `.wasm` file is WebAssembly, and so is an extensionless file
/// that starts with the magic number, as Node's `getFormatOfExtensionlessFile` decides:
/// in a `module` package scope, or imported from outside a package scope. Node runs an
/// extensionless entry outside a `module` scope with the `CommonJS` loader, which reads it
/// as text.
fn read(resolver: &Resolver, path: &Path, entry: bool) -> Result<Contents, Vec<Diagnostic>> {
    let cannot = |error: &dyn std::fmt::Display| {
        vec![Reporter::new(path, "").at(
            0,
            Code::BadImport,
            format!("cannot read {}: {error}", path.display()),
        )]
    };
    let bytes = fs::read(path).map_err(|error| cannot(&error))?;
    let scope = resolver.scope_type(path);
    let extensionless_wasm = path.extension().is_none()
        && bytes.starts_with(WASM_MAGIC)
        && match scope.as_deref() {
            Some("module") => true,
            Some(_) => false,
            None => !entry,
        };
    if resolver.format(path) == Format::Wasm || extensionless_wasm {
        return Ok(Contents::Wasm(bytes));
    }
    String::from_utf8(bytes)
        .map(Contents::Text)
        .map_err(|_| cannot(&"stream did not contain valid UTF-8"))
}

/// The module names that V8 links to its JS String Builtins instead of a module, with
/// the options of Node's wasm translator.
const STRING_BUILTINS: [&str; 2] = ["wasm:js-string", "wasm:js/string-constants"];

/// The record of a WebAssembly module: a request for each module that it imports from,
/// and an export for each of its exports. A binary that does not decode keeps an empty
/// record, and the runtime throws its `CompileError` when it loads it.
fn scan_wasm(bytes: Vec<u8>) -> Scanned {
    let (record, specifiers) = wasm_record(&bytes).unwrap_or_default();
    Scanned {
        source: String::new(),
        bytes,
        kind: Kind::Wasm,
        record,
        specifiers,
        dynamic: Dynamic::default(),
    }
}

type Specifiers = Vec<(String, Mode, bool)>;

fn wasm_record(bytes: &[u8]) -> Result<(Record, Specifiers), wasmparser::BinaryReaderError> {
    let mut record = Record::default();
    let mut specifiers = Vec::new();
    for payload in wasmparser::Parser::new(0).parse_all(bytes) {
        match payload? {
            wasmparser::Payload::ImportSection(reader) => {
                for import in reader.into_imports() {
                    let module = import?.module;
                    if STRING_BUILTINS.contains(&module)
                        || record.order.iter().any(|(known, _)| known == module)
                    {
                        continue;
                    }
                    record.order.push((module.to_owned(), false));
                    specifiers.push((module.to_owned(), Mode::Import, false));
                }
            }
            wasmparser::Payload::ExportSection(reader) => {
                for export in reader {
                    let name = export?.name.to_owned();
                    record.locals.push((name.clone(), name));
                }
            }
            _ => {}
        }
    }
    Ok((record, specifiers))
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
                "js" | "mjs" | "cjs" | "ts" | "mts" | "cts" | "json" | "wasm"
            )
        })
}

struct Scanned {
    source: String,
    bytes: Vec<u8>,
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
        // read() keeps the binary of a .wasm file; only a script names one as text.
        Format::Esm | Format::Wasm => Kind::Esm,
        Format::CommonJs => Kind::CommonJs,
        Format::Json => {
            return Ok(Scanned {
                source: text,
                bytes: Vec::new(),
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
    scan_as(path, text, kind, script)
}

/// Whether `path` stands for a `data:` URL, which names a module without a file.
pub fn is_data(path: &Path) -> bool {
    path.to_string_lossy().starts_with("data:")
}

/// Reads the module of a `data:` URL, which the resolver accepted.
fn scan_data(path: &Path) -> Result<Scanned, Vec<Diagnostic>> {
    let url = path.to_string_lossy();
    match resolve::data_source(&url) {
        Some((Format::Json, text)) => Ok(Scanned {
            source: text,
            kind: Kind::Json,
            record: Record::default(),
            specifiers: Vec::new(),
            dynamic: Dynamic::default(),
        }),
        Some((_, text)) => scan_as(path, text, Kind::Esm, false),
        None => Err(vec![Reporter::new(path, "").at(
            0,
            Code::BadImport,
            format!("cannot decode {url}"),
        )]),
    }
}

/// Reads the syntax facts of a module of a known format.
fn scan_as(
    path: &Path,
    text: String,
    kind: Kind,
    script: bool,
) -> Result<Scanned, Vec<Diagnostic>> {
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
            source: program.source_text,
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
    })
    .map_err(|mut diagnostics| {
        // The wrapper shares the first line of a CommonJS module.
        if kind == Kind::CommonJs {
            for diagnostic in diagnostics.iter_mut().filter(|d| d.line == 1) {
                diagnostic.column = diagnostic.column.saturating_sub(CJS_WRAPPER.len()).max(1);
            }
        }
        diagnostics
    })?;
    Ok(Scanned {
        source,
        bytes: Vec::new(),
        kind,
        record: facts.0,
        specifiers: facts.1,
        dynamic: facts.2,
    })
}

/// Node's syntax detection for a file without a package `type`.
fn detect(path: &Path, text: &str) -> Kind {
    if is_module(path, text, true) {
        Kind::Esm
    } else {
        Kind::CommonJs
    }
}

/// Node's `containsModuleSyntax` for source text without a file, such as `--eval` code,
/// which compiles without the variables of the `CommonJS` wrapper.
pub fn contains_module_syntax(text: &str, cjs_variables: bool) -> bool {
    is_module(Path::new("[detect].js"), text, cjs_variables)
}

/// `ShouldRetryAsESM` of Node: text is a module when it parses as one with `import`,
/// `export`, `import.meta`, or a top-level `await`, or a top-level `let`, `const`, or
/// `class` of a variable of the wrapper, and fails as a `CommonJS` function body. oxc's
/// parser does not check redeclarations, so such a declaration stands for V8's error.
fn is_module(path: &Path, text: &str, cjs_variables: bool) -> bool {
    let candidate = crate::parse::parses(
        path,
        text,
        Kind::Esm.source_type(path),
        |program, module_syntax| {
            let redeclares = cjs_variables && program.body.iter().any(declares_cjs_variable);
            let mut suspends = Suspends::default();
            let mut meta = HasImportMeta(false);
            for statement in &program.body {
                suspends.visit_statement(statement);
                meta.visit_statement(statement);
            }
            (module_syntax || suspends.0 || meta.0, redeclares)
        },
    );
    match candidate {
        Some((_, true)) => true,
        Some((true, false)) => {
            let body = if cjs_variables {
                wrap(text)
            } else {
                format!("(function () {{{text}\n}})")
            };
            crate::parse::parses(path, &body, Kind::CommonJs.source_type(path), |_, _| ()).is_none()
        }
        _ => false,
    }
}

/// Whether a top-level statement declares a parameter of the `CommonJS` wrapper lexically.
fn declares_cjs_variable(statement: &Statement) -> bool {
    let is_wrapper_name =
        |name: &str| ["exports", "require", "module", "__filename", "__dirname"].contains(&name);
    match statement {
        Statement::VariableDeclaration(declaration) if declaration.kind.is_lexical() => declaration
            .declarations
            .iter()
            .flat_map(|declarator| declarator.id.get_binding_identifiers())
            .any(|id| is_wrapper_name(&id.name)),
        Statement::ClassDeclaration(class) => class
            .id
            .as_ref()
            .is_some_and(|id| is_wrapper_name(&id.name)),
        _ => false,
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

    fn module_request(
        &mut self,
        specifier: &str,
        clause: Option<&WithClause<'a>>,
        source_phase: bool,
    ) {
        let mut attributes: Vec<(String, String)> = clause
            .map(|clause| {
                clause
                    .with_entries
                    .iter()
                    .map(|entry| {
                        let key = match &entry.key {
                            ImportAttributeKey::Identifier(name) => name.name.to_string(),
                            ImportAttributeKey::StringLiteral(text) => text.value.to_string(),
                        };
                        (key, entry.value.value.to_string())
                    })
                    .collect()
            })
            .unwrap_or_default();
        attributes.sort();
        let request = ModuleRequest {
            specifier: specifier.to_owned(),
            attributes,
            source_phase,
        };
        if !self.record.module_requests.contains(&request) {
            self.record.module_requests.push(request);
        }
    }

    /// `import source m from 'x'`: its module loads, and only its source object binds.
    fn source_import(&mut self, import: &oxc::ast::ast::ImportDeclaration<'a>) {
        let specifier = import.source.value.as_str();
        for item in import.specifiers.iter().flatten() {
            self.record.imports.push((
                item.local().name.to_string(),
                specifier.to_owned(),
                Imported::Source,
            ));
        }
        if !self.record.sources.iter().any(|known| known == specifier) {
            self.record.sources.push(specifier.to_owned());
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
                    if matches!(import.phase, Some(oxc::ast::ast::ImportPhase::Source)) {
                        self.source_import(import);
                        self.module_request(specifier, import.with_clause.as_deref(), true);
                        continue;
                    }
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
                    if kept || !self.typescript {
                        self.module_request(specifier, import.with_clause.as_deref(), false);
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
                    self.module_request(specifier, export.with_clause.as_deref(), false);
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
                self.module_request(specifier, export.with_clause.as_deref(), false);
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
struct Requests<'s> {
    /// The source text, whose characters the export analysis reads as Node's lexer does.
    source: &'s str,
    found: Vec<(String, Mode, bool)>,
    names: Vec<String>,
    reexports: Vec<String>,
    dynamic: Dynamic,
    /// `var ID = require('x')`, by `ID`, for Babel's re-export of `x`.
    required: Vec<(String, String)>,
}

impl Requests<'_> {
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

/// The text of a string literal or of a template without expressions. A text with a
/// surrogate that pairs with none is no string of Rust, so it has none.
fn string_of(expression: &Expression<'_>) -> Option<String> {
    match expression {
        Expression::StringLiteral(literal) => {
            decoded(literal.value.as_str(), literal.lone_surrogates)
        }
        Expression::TemplateLiteral(template) if template.expressions.is_empty() => {
            template.quasis.first().and_then(|quasi| {
                quasi
                    .value
                    .cooked
                    .as_ref()
                    .and_then(|cooked| decoded(cooked.as_str(), quasi.lone_surrogates))
            })
        }
        Expression::ParenthesizedExpression(inner) => string_of(&inner.expression),
        _ => None,
    }
}

/// The text of a literal value whose surrogates oxc writes as U+FFFD and four hex
/// digits, as `literal::js_string_literal` reads them: a pair joins into its character.
fn decoded(value: &str, lone_surrogates: bool) -> Option<String> {
    if !lone_surrogates {
        return Some(value.to_owned());
    }
    let mut units = Vec::new();
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c == '\u{FFFD}' {
            let hex: String = chars.by_ref().take(4).collect();
            units.push(u16::from_str_radix(&hex, 16).ok()?);
            continue;
        }
        let mut buffer = [0; 2];
        units.extend_from_slice(c.encode_utf16(&mut buffer));
    }
    String::from_utf16(&units).ok()
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

impl<'a> Visit<'a> for Requests<'_> {
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

impl Requests<'_> {
    /// `module.exports = { a, b: c, ...require('x') }` and `module.exports = require('x')`.
    fn module_exports(&mut self, value: &Expression<'_>) {
        if let Some(specifier) = required(value) {
            self.reexports.push(specifier);
            return;
        }
        let Expression::ObjectExpression(object) = value.without_parentheses() else {
            return;
        };
        // cjs-module-lexer reads a key only when an identifier starts its value, and
        // stops at the first property that it cannot read: `{ a, b: c }` exports a and b,
        // `{ a: f(), b }` exports a, and `{ a: 'x', b }` exports nothing.
        for property in &object.properties {
            match property {
                ObjectPropertyKind::ObjectProperty(property) if !property.computed => {
                    let name = match &property.key {
                        PropertyKey::StaticIdentifier(ident) => ident.name.to_string(),
                        PropertyKey::StringLiteral(literal) => {
                            match decoded(literal.value.as_str(), literal.lone_surrogates) {
                                Some(name) => name,
                                None => return,
                            }
                        }
                        _ => return,
                    };
                    if property.shorthand || matches!(property.value, Expression::Identifier(_)) {
                        self.name(&name);
                        continue;
                    }
                    let start = property.value.span().start as usize;
                    if self
                        .source
                        .get(start..)
                        .and_then(|rest| rest.chars().next())
                        .is_some_and(|first| first.is_alphabetic() || first == '_' || first == '$')
                    {
                        self.name(&name);
                    }
                    return;
                }
                ObjectPropertyKind::SpreadProperty(spread) => {
                    if let Some(specifier) = required(&spread.argument) {
                        self.reexports.push(specifier);
                    } else if !matches!(spread.argument, Expression::Identifier(_)) {
                        return;
                    }
                }
                ObjectPropertyKind::ObjectProperty(_) => return,
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

#[cfg(test)]
mod tests {
    use super::cjs_lexer;

    fn names(source: &str) -> Vec<String> {
        cjs_lexer(source.to_owned())
            .map(|(names, _)| names)
            .unwrap_or_default()
    }

    #[test]
    fn reads_object_exports_as_cjs_module_lexer_does() {
        assert_eq!(names("module.exports = { a, b: c, ...d };"), ["a", "b"]);
        assert_eq!(names("module.exports = { a: f(), b };"), ["a"]);
        assert_eq!(
            names("module.exports = { a: 'x', b };"),
            Vec::<String>::new()
        );
        assert_eq!(
            names("exports['\\u{D83C}\\u{DF10}'] = 1; exports['\\u{D83C}'] = 2;"),
            ["🌐"]
        );
    }
}
