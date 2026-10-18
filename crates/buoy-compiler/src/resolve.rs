//! Node's module resolution, as Node documents it: `ESM_RESOLVE` for `import` and
//! `import()` (<https://nodejs.org/api/esm.html#resolution-algorithm-specification>), and
//! `require.resolve` for `require` (<https://nodejs.org/api/modules.html#all-together>),
//! with the conditions of Node 25 minus `node-addons`, because Buoy loads no native
//! addon. It also decides the format of each file, as Node's `ESM_FILE_FORMAT` does.
//!
//! Buoy adds one fallback after Node fails: a relative `./x.js` may name `./x.ts`, and a
//! relative path without an extension may name a `.ts` file, as the TypeScript compiler
//! allows. A program that runs on Node never reaches the fallback.

/// The file extension of a native addon, which Node loads with `process.dlopen`.
const ADDON_EXTENSION: &str = "node";

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::rc::Rc;

use serde_json::Value;

/// How a module was requested. The conditions and the algorithm differ.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Mode {
    Import,
    Require,
}

/// What a specifier names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// A file, by its real path.
    File(PathBuf),
    /// A built-in module of Node, by the name that `require('module').builtinModules`
    /// lists, such as `fs` or `node:test`.
    Builtin(String),
}

/// A failed resolution: Node's error code and message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
}

/// The format of a module file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Esm,
    CommonJs,
    Json,
    /// A WebAssembly module, which Node's ESM loader instantiates as a module record.
    Wasm,
    /// A `.js` or `.ts` file outside a package scope with a `type`: ESM when its syntax is
    /// ESM, else `CommonJS` (Node's `--experimental-detect-module`, on by default).
    Detect,
    /// A native addon, which Buoy cannot load.
    Addon,
}

/// The fields of a `package.json` that resolution reads.
#[derive(Debug)]
struct Package {
    dir: PathBuf,
    name: Option<String>,
    main: Option<String>,
    kind: Option<String>,
    exports: Option<Value>,
    imports: Option<Value>,
}

/// Resolves specifiers, with a cache of the `package.json` files it read.
#[derive(Debug, Default)]
pub struct Resolver {
    packages: RefCell<HashMap<PathBuf, Option<Rc<Package>>>>,
}

/// The built-in modules of Node 25.9, from `require('module').builtinModules`. The last
/// four exist only with the `node:` prefix.
const BUILTINS: &[&str] = &[
    "_http_agent",
    "_http_client",
    "_http_common",
    "_http_incoming",
    "_http_outgoing",
    "_http_server",
    "_stream_duplex",
    "_stream_passthrough",
    "_stream_readable",
    "_stream_transform",
    "_stream_wrap",
    "_stream_writable",
    "_tls_common",
    "_tls_wrap",
    "assert",
    "assert/strict",
    "async_hooks",
    "buffer",
    "child_process",
    "cluster",
    "console",
    "constants",
    "crypto",
    "dgram",
    "diagnostics_channel",
    "dns",
    "dns/promises",
    "domain",
    "events",
    "fs",
    "fs/promises",
    "http",
    "http2",
    "https",
    "inspector",
    "inspector/promises",
    "module",
    "net",
    "os",
    "path",
    "path/posix",
    "path/win32",
    "perf_hooks",
    "process",
    "punycode",
    "querystring",
    "readline",
    "readline/promises",
    "repl",
    "stream",
    "stream/consumers",
    "stream/promises",
    "stream/web",
    "string_decoder",
    "sys",
    "timers",
    "timers/promises",
    "tls",
    "trace_events",
    "tty",
    "url",
    "util",
    "util/types",
    "v8",
    "vm",
    "wasi",
    "worker_threads",
    "zlib",
];

const PREFIX_ONLY: &[&str] = &["sea", "sqlite", "test", "test/reporters"];

/// The built-in module that `specifier` names, with or without `node:`.
#[must_use]
pub fn builtin(specifier: &str) -> Option<String> {
    if let Some(name) = specifier.strip_prefix("node:") {
        if BUILTINS.contains(&name) {
            return Some(name.to_owned());
        }
        return PREFIX_ONLY.contains(&name).then(|| format!("node:{name}"));
    }
    BUILTINS.contains(&specifier).then(|| specifier.to_owned())
}

/// Whether a specifier is relative or absolute: it names a path, not a package.
#[must_use]
pub fn is_path(specifier: &str) -> bool {
    specifier.starts_with("./")
        || specifier.starts_with("../")
        || specifier.starts_with('/')
        || specifier == "."
        || specifier == ".."
}

impl Resolver {
    /// Resolves `specifier` from the module at `importer`.
    pub fn resolve(&self, specifier: &str, importer: &Path, mode: Mode) -> Result<Target, Failure> {
        let found = match mode {
            Mode::Import => self.esm_resolve(specifier, importer),
            Mode::Require => self.require_resolve(specifier, importer),
        }?;
        Ok(match found {
            Target::File(path) => Target::File(path.canonicalize().unwrap_or(path)),
            builtin @ Target::Builtin(_) => builtin,
        })
    }

    /// The format of the file at `path` (`ESM_FILE_FORMAT`). An unknown extension is
    /// `CommonJS`, as `require` treats it.
    pub fn format(&self, path: &Path) -> Format {
        match path.extension().and_then(|extension| extension.to_str()) {
            Some("mjs" | "mts") => Format::Esm,
            Some("json") => Format::Json,
            Some("wasm") => Format::Wasm,
            Some(ADDON_EXTENSION) => Format::Addon,
            Some("js" | "ts" | "jsx" | "tsx") | None => match self.scope_type(path).as_deref() {
                Some("module") => Format::Esm,
                Some("commonjs") => Format::CommonJs,
                _ => Format::Detect,
            },
            // `.cjs`, `.cts`, and every other extension.
            Some(_) => Format::CommonJs,
        }
    }

    /// The `type` of the package scope of `path`.
    pub fn scope_type(&self, path: &Path) -> Option<String> {
        self.scope(path).and_then(|package| package.kind.clone())
    }

    // ESM_RESOLVE

    fn esm_resolve(&self, specifier: &str, importer: &Path) -> Result<Target, Failure> {
        if let Some(name) = builtin(specifier) {
            return Ok(Target::Builtin(name));
        }
        if let Some(path) = specifier.strip_prefix("file://") {
            return finish_esm(PathBuf::from(decode(path)), importer);
        }
        if is_path(specifier) {
            let base = importer.parent().unwrap_or(Path::new("/"));
            return finish_esm(normalize(&base.join(specifier)), importer);
        }
        if specifier.starts_with('#') {
            let target = self.imports_resolve(specifier, importer, Mode::Import)?;
            return self.finish_target(target, specifier, importer, Mode::Import);
        }
        if let Some((scheme, _)) = specifier.split_once(':')
            && scheme.len() > 1
            && scheme
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
        {
            return Err(Failure {
                code: "ERR_UNSUPPORTED_ESM_URL_SCHEME",
                message: format!(
                    "Only URLs with a scheme in: file, data, and node are supported by the default ESM loader. Received protocol '{scheme}:'"
                ),
            });
        }
        let target = self.package_resolve(specifier, importer, Mode::Import)?;
        self.finish_target(target, specifier, importer, Mode::Import)
    }

    fn finish_target(
        &self,
        target: Target,
        specifier: &str,
        importer: &Path,
        mode: Mode,
    ) -> Result<Target, Failure> {
        match (target, mode) {
            (Target::File(path), Mode::Import) => finish_esm(path, importer),
            (Target::File(path), Mode::Require) => self
                .load_file_or_directory(&path)
                .map(Target::File)
                .ok_or_else(|| not_found_require(specifier, importer)),
            (builtin, _) => Ok(builtin),
        }
    }

    /// `PACKAGE_RESOLVE`: a bare specifier, from the package scope or a `node_modules`.
    fn package_resolve(
        &self,
        specifier: &str,
        importer: &Path,
        mode: Mode,
    ) -> Result<Target, Failure> {
        if let Some(name) = builtin(specifier) {
            return Ok(Target::Builtin(name));
        }
        let (name, subpath) = split_package(specifier).ok_or_else(|| Failure {
            code: "ERR_INVALID_MODULE_SPECIFIER",
            message: format!(
                "Invalid module \"{specifier}\" is not a valid package name imported from {}",
                importer.display()
            ),
        })?;
        if let Some(found) = self.self_resolve(name, &subpath, importer, mode)? {
            return Ok(found);
        }
        let mut dir = importer.parent();
        while let Some(current) = dir {
            dir = current.parent();
            if current
                .file_name()
                .is_some_and(|name| name == "node_modules")
            {
                continue;
            }
            let package_dir = current.join("node_modules").join(name);
            if !package_dir.is_dir() {
                continue;
            }
            let package = self.read(&package_dir);
            if let Some(exports) = package
                .as_ref()
                .and_then(|package| package.exports.as_ref())
            {
                return self.exports_resolve(&package_dir, &subpath, exports, mode, importer);
            }
            if subpath == "." {
                let main = package.as_ref().and_then(|package| package.main.clone());
                return match mode {
                    Mode::Import => legacy_main(&package_dir, main.as_deref())
                        .map(Target::File)
                        .ok_or_else(|| Failure {
                            code: "ERR_MODULE_NOT_FOUND",
                            message: format!(
                                "Cannot find package '{}' imported from {}",
                                package_dir.display(),
                                importer.display()
                            ),
                        }),
                    Mode::Require => self
                        .load_directory(&package_dir)
                        .map(Target::File)
                        .ok_or_else(|| not_found_require(specifier, importer)),
                };
            }
            return Ok(Target::File(package_dir.join(&subpath[2..])));
        }
        Err(match mode {
            Mode::Import => Failure {
                code: "ERR_MODULE_NOT_FOUND",
                message: format!(
                    "Cannot find package '{name}' imported from {}",
                    importer.display()
                ),
            },
            Mode::Require => not_found_require(specifier, importer),
        })
    }

    /// `PACKAGE_SELF_RESOLVE`: a package that imports itself by its name.
    fn self_resolve(
        &self,
        name: &str,
        subpath: &str,
        importer: &Path,
        mode: Mode,
    ) -> Result<Option<Target>, Failure> {
        let Some(package) = self.scope(importer) else {
            return Ok(None);
        };
        match (&package.exports, &package.name) {
            (Some(exports), Some(own)) if own == name => self
                .exports_resolve(&package.dir, subpath, exports, mode, importer)
                .map(Some),
            _ => Ok(None),
        }
    }

    /// `PACKAGE_EXPORTS_RESOLVE`
    fn exports_resolve(
        &self,
        package_dir: &Path,
        subpath: &str,
        exports: &Value,
        mode: Mode,
        importer: &Path,
    ) -> Result<Target, Failure> {
        let invalid = || Failure {
            code: "ERR_INVALID_PACKAGE_CONFIG",
            message: format!(
                "Invalid package config {}. \"exports\" cannot contain some keys starting with '.' and some not.",
                package_dir.join("package.json").display()
            ),
        };
        let dotted = match exports {
            Value::Object(map) => {
                let dots = map.keys().filter(|key| key.starts_with('.')).count();
                if dots != 0 && dots != map.len() {
                    return Err(invalid());
                }
                dots != 0
            }
            _ => false,
        };
        let resolved = if subpath == "." {
            let main = match exports {
                Value::Object(map) if dotted => map.get("."),
                other => Some(other),
            };
            match main {
                Some(main) => self.target_resolve(package_dir, main, None, false, mode)?,
                None => Resolution::Null,
            }
        } else if let (Value::Object(map), true) = (exports, dotted) {
            self.match_resolve(subpath, map, package_dir, false, mode)?
        } else {
            Resolution::Null
        };
        match resolved {
            Resolution::Found(target) => Ok(target),
            _ => Err(Failure {
                code: "ERR_PACKAGE_PATH_NOT_EXPORTED",
                message: if subpath == "." {
                    format!(
                        "No \"exports\" main defined in {}",
                        package_dir.join("package.json").display()
                    )
                } else {
                    format!(
                        "Package subpath '{subpath}' is not defined by \"exports\" in {} imported from {}",
                        package_dir.join("package.json").display(),
                        importer.display()
                    )
                },
            }),
        }
    }

    /// `PACKAGE_IMPORTS_RESOLVE`: a `#name` from the `imports` of the package scope.
    fn imports_resolve(
        &self,
        specifier: &str,
        importer: &Path,
        mode: Mode,
    ) -> Result<Target, Failure> {
        let not_defined = || Failure {
            code: "ERR_PACKAGE_IMPORT_NOT_DEFINED",
            message: format!(
                "Package import specifier \"{specifier}\" is not defined imported from {}",
                importer.display()
            ),
        };
        if specifier == "#" || specifier.starts_with("#/") {
            return Err(Failure {
                code: "ERR_INVALID_MODULE_SPECIFIER",
                message: format!(
                    "Invalid module \"{specifier}\" is not a valid internal imports specifier name imported from {}",
                    importer.display()
                ),
            });
        }
        let package = self.scope(importer).ok_or_else(not_defined)?;
        let Some(Value::Object(imports)) = &package.imports else {
            return Err(not_defined());
        };
        match self.match_resolve(specifier, imports, &package.dir, true, mode)? {
            Resolution::Found(target) => Ok(target),
            _ => Err(not_defined()),
        }
    }

    /// `PACKAGE_IMPORTS_EXPORTS_RESOLVE`: an exact key, else the most specific pattern.
    fn match_resolve(
        &self,
        key: &str,
        map: &serde_json::Map<String, Value>,
        package_dir: &Path,
        is_imports: bool,
        mode: Mode,
    ) -> Result<Resolution, Failure> {
        if !key.contains('*')
            && let Some(target) = map.get(key)
        {
            return self.target_resolve(package_dir, target, None, is_imports, mode);
        }
        let mut patterns: Vec<&String> = map
            .keys()
            .filter(|candidate| candidate.matches('*').count() == 1)
            .collect();
        patterns.sort_by(|a, b| pattern_key_compare(a, b));
        for pattern in patterns {
            let Some((base, trailer)) = pattern.split_once('*') else {
                continue;
            };
            if key.starts_with(base)
                && key != base
                && (trailer.is_empty() || (key.ends_with(trailer) && key.len() >= pattern.len()))
            {
                let matched = &key[base.len()..key.len() - trailer.len()];
                return self.target_resolve(
                    package_dir,
                    &map[pattern.as_str()],
                    Some(matched),
                    is_imports,
                    mode,
                );
            }
        }
        Ok(Resolution::Null)
    }

    /// `PACKAGE_TARGET_RESOLVE`
    fn target_resolve(
        &self,
        package_dir: &Path,
        target: &Value,
        pattern: Option<&str>,
        is_imports: bool,
        mode: Mode,
    ) -> Result<Resolution, Failure> {
        let invalid = |target: &str| Failure {
            code: "ERR_INVALID_PACKAGE_TARGET",
            message: format!(
                "Invalid \"{}\" target \"{target}\" defined in the package config {}",
                if is_imports { "imports" } else { "exports" },
                package_dir.join("package.json").display()
            ),
        };
        match target {
            Value::String(text) => {
                if !text.starts_with("./") {
                    if !is_imports
                        || text.starts_with("../")
                        || text.starts_with('/')
                        || text.contains("://")
                    {
                        return Err(invalid(text));
                    }
                    let specifier = match pattern {
                        Some(matched) => text.replace('*', matched),
                        None => text.clone(),
                    };
                    let importer = package_dir.join("package.json");
                    return self
                        .package_resolve(&specifier, &importer, mode)
                        .map(Resolution::Found);
                }
                if text[2..]
                    .split(['/', '\\'])
                    .any(|segment| matches!(segment, "" | "." | ".." | "node_modules"))
                {
                    return Err(invalid(text));
                }
                let resolved = match pattern {
                    Some(matched) => {
                        if matched
                            .split(['/', '\\'])
                            .any(|segment| matches!(segment, "." | ".." | "node_modules"))
                        {
                            return Err(invalid(text));
                        }
                        text.replace('*', matched)
                    }
                    None => text.clone(),
                };
                Ok(Resolution::Found(Target::File(
                    package_dir.join(&resolved[2..]),
                )))
            }
            Value::Object(map) => {
                for (condition, value) in map {
                    if matches(mode, condition) {
                        match self.target_resolve(package_dir, value, pattern, is_imports, mode)? {
                            Resolution::Undefined => {}
                            found => return Ok(found),
                        }
                    }
                }
                Ok(Resolution::Undefined)
            }
            Value::Array(items) => {
                let mut last = Ok(Resolution::Null);
                for item in items {
                    match self.target_resolve(package_dir, item, pattern, is_imports, mode) {
                        Ok(Resolution::Found(target)) => return Ok(Resolution::Found(target)),
                        Ok(Resolution::Undefined) => {}
                        other => last = other,
                    }
                }
                last
            }
            Value::Null => Ok(Resolution::Null),
            other => Err(invalid(&other.to_string())),
        }
    }

    // require.resolve

    fn require_resolve(&self, specifier: &str, importer: &Path) -> Result<Target, Failure> {
        if let Some(name) = builtin(specifier) {
            return Ok(Target::Builtin(name));
        }
        let base = importer.parent().unwrap_or(Path::new("/"));
        if is_path(specifier) {
            let path = normalize(&base.join(specifier));
            return self
                .load_file_or_directory(&path)
                .or_else(|| ts_fallback(&path))
                .map(Target::File)
                .ok_or_else(|| not_found_require(specifier, importer));
        }
        if specifier.starts_with('#') {
            let target = self.imports_resolve(specifier, importer, Mode::Require)?;
            return self.finish_target(target, specifier, importer, Mode::Require);
        }
        let Some((name, subpath)) = split_package(specifier) else {
            return Err(not_found_require(specifier, importer));
        };
        if let Some(found) = self.self_resolve(name, &subpath, importer, Mode::Require)? {
            return self.finish_target(found, specifier, importer, Mode::Require);
        }
        let mut dir = Some(base);
        while let Some(current) = dir {
            dir = current.parent();
            if current
                .file_name()
                .is_some_and(|name| name == "node_modules")
            {
                continue;
            }
            let modules = current.join("node_modules");
            let package_dir = modules.join(name);
            if let Some(exports) = self
                .read(&package_dir)
                .as_ref()
                .and_then(|package| package.exports.clone())
            {
                let target = self.exports_resolve(
                    &package_dir,
                    &subpath,
                    &exports,
                    Mode::Require,
                    importer,
                )?;
                return self.finish_target(target, specifier, importer, Mode::Require);
            }
            if let Some(found) = self.load_file_or_directory(&modules.join(specifier)) {
                return Ok(Target::File(found));
            }
        }
        Err(not_found_require(specifier, importer))
    }

    /// `LOAD_AS_FILE`, then `LOAD_AS_DIRECTORY`.
    fn load_file_or_directory(&self, path: &Path) -> Option<PathBuf> {
        load_file(path).or_else(|| self.load_directory(path))
    }

    /// `LOAD_AS_DIRECTORY`: the `main` of its `package.json`, else its index.
    fn load_directory(&self, path: &Path) -> Option<PathBuf> {
        if !path.is_dir() {
            return None;
        }
        if let Some(main) = self.read(path).and_then(|package| package.main.clone())
            && !main.is_empty()
        {
            let main_path = normalize(&path.join(&main));
            if let Some(found) = load_file(&main_path).or_else(|| load_index(&main_path)) {
                return Some(found);
            }
        }
        load_index(path)
    }

    /// `LOOKUP_PACKAGE_SCOPE`: the nearest `package.json` above `path`, stopping at a
    /// `node_modules` directory.
    fn scope(&self, path: &Path) -> Option<Rc<Package>> {
        let mut dir = path.parent();
        while let Some(current) = dir {
            if current
                .file_name()
                .is_some_and(|name| name == "node_modules")
            {
                return None;
            }
            if let Some(package) = self.read(current) {
                return Some(package);
            }
            dir = current.parent();
        }
        None
    }

    /// The `package.json` of `dir`, read once.
    fn read(&self, dir: &Path) -> Option<Rc<Package>> {
        if let Some(cached) = self.packages.borrow().get(dir) {
            return cached.clone();
        }
        let package = fs::read_to_string(dir.join("package.json"))
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .map(|json| {
                let text = |key: &str| json.get(key).and_then(Value::as_str).map(str::to_owned);
                let field = |key: &str| json.get(key).filter(|value| !value.is_null()).cloned();
                Rc::new(Package {
                    dir: dir.to_path_buf(),
                    name: text("name"),
                    main: text("main"),
                    kind: text("type"),
                    exports: field("exports"),
                    imports: field("imports"),
                })
            });
        self.packages
            .borrow_mut()
            .insert(dir.to_path_buf(), package.clone());
        package
    }
}

/// The result of `PACKAGE_TARGET_RESOLVE`: a target, `null`, or `undefined`, which differ
/// in how an array of fallbacks and the conditions treat them.
enum Resolution {
    Found(Target),
    Null,
    Undefined,
}

/// Whether a condition of an `exports` or `imports` object applies: `default`, or a
/// condition of Node for the mode.
fn matches(mode: Mode, condition: &str) -> bool {
    condition == "default" || conditions(mode).contains(&condition)
}

/// The conditions of Node 25 for each mode, without `node-addons`.
fn conditions(mode: Mode) -> &'static [&'static str] {
    match mode {
        Mode::Import => &["node", "import", "module-sync"],
        Mode::Require => &["node", "require", "module-sync"],
    }
}

/// `PATTERN_KEY_COMPARE`: the longer base first, then the longer key.
fn pattern_key_compare(a: &str, b: &str) -> std::cmp::Ordering {
    let base = |key: &str| key.find('*').map_or(0, |index| index + 1);
    base(b).cmp(&base(a)).then_with(|| b.len().cmp(&a.len()))
}

/// `name` and `./subpath` of a bare specifier such as `@scope/pkg/sub`.
fn split_package(specifier: &str) -> Option<(&str, String)> {
    let end = if specifier.starts_with('@') {
        let slash = specifier.find('/')?;
        specifier[slash + 1..]
            .find('/')
            .map_or(specifier.len(), |next| slash + 1 + next)
    } else {
        specifier.find('/').unwrap_or(specifier.len())
    };
    let name = &specifier[..end];
    if name.is_empty() || name.starts_with('.') || name.contains('\\') || name.contains('%') {
        return None;
    }
    Some((name, format!(".{}", &specifier[end..])))
}

/// The end of ESM resolution: the file must exist and must not be a directory.
fn finish_esm(path: PathBuf, importer: &Path) -> Result<Target, Failure> {
    if path.is_file() {
        return Ok(Target::File(path));
    }
    if let Some(found) = ts_fallback(&path) {
        return Ok(Target::File(found));
    }
    if path.is_dir() {
        return Err(Failure {
            code: "ERR_UNSUPPORTED_DIR_IMPORT",
            message: format!(
                "Directory import '{}' is not supported resolving ES modules imported from {}",
                path.display(),
                importer.display()
            ),
        });
    }
    Err(Failure {
        code: "ERR_MODULE_NOT_FOUND",
        message: format!(
            "Cannot find module '{}' imported from {}",
            path.display(),
            importer.display()
        ),
    })
}

fn not_found_require(specifier: &str, importer: &Path) -> Failure {
    Failure {
        code: "MODULE_NOT_FOUND",
        message: format!(
            "Cannot find module '{specifier}'\nRequire stack:\n- {}",
            importer.display()
        ),
    }
}

/// `LOAD_AS_FILE`: the path itself, then with `.js`, `.json`, and `.node`.
fn load_file(path: &Path) -> Option<PathBuf> {
    if path.is_file() {
        return Some(path.to_path_buf());
    }
    let text = path.as_os_str().to_string_lossy();
    ["js", "json", "node"]
        .iter()
        .map(|extension| PathBuf::from(format!("{text}.{extension}")))
        .find(|candidate| candidate.is_file())
}

/// `LOAD_INDEX`
fn load_index(path: &Path) -> Option<PathBuf> {
    ["index.js", "index.json", "index.node"]
        .iter()
        .map(|index| path.join(index))
        .find(|candidate| candidate.is_file())
}

/// Node's legacy main resolution for `import` of a package without `exports`.
fn legacy_main(package_dir: &Path, main: Option<&str>) -> Option<PathBuf> {
    if let Some(main) = main {
        let base = normalize(&package_dir.join(main));
        let text = base.as_os_str().to_string_lossy().into_owned();
        let candidates = [
            base.clone(),
            PathBuf::from(format!("{text}.js")),
            PathBuf::from(format!("{text}.json")),
            PathBuf::from(format!("{text}.node")),
            base.join("index.js"),
            base.join("index.json"),
            base.join("index.node"),
        ];
        if let Some(found) = candidates.into_iter().find(|candidate| candidate.is_file()) {
            return Some(found);
        }
    }
    load_index(package_dir)
}

/// Buoy's TypeScript fallback for a relative path that Node does not find.
fn ts_fallback(path: &Path) -> Option<PathBuf> {
    let text = path.as_os_str().to_string_lossy().into_owned();
    let candidates: Vec<PathBuf> = match path.extension().and_then(|extension| extension.to_str()) {
        Some("js") => vec![path.with_extension("ts")],
        Some("mjs") => vec![path.with_extension("mts")],
        Some("cjs") => vec![path.with_extension("cts")],
        Some("ts" | "mts" | "cts" | "json") => vec![],
        _ => vec![
            PathBuf::from(format!("{text}.ts")),
            PathBuf::from(format!("{text}.mts")),
            path.join("index.ts"),
        ],
    };
    candidates.into_iter().find(|candidate| candidate.is_file())
}

/// `path` without `.` and `..` components, as URL resolution leaves it.
#[must_use]
pub fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// The path of a `file://` URL, with its percent escapes decoded.
fn decode(path: &str) -> String {
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && let Some(byte) = path
                .get(index + 1..index + 3)
                .and_then(|hex| u8::from_str_radix(hex, 16).ok())
        {
            out.push(byte);
            index += 3;
            continue;
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap_or(path)).expect("a scratch directory");
        fs::write(path, text).expect("a scratch file");
    }

    #[test]
    fn splits_package_names() {
        assert_eq!(split_package("pkg"), Some(("pkg", ".".to_owned())));
        assert_eq!(split_package("pkg/a/b"), Some(("pkg", "./a/b".to_owned())));
        assert_eq!(
            split_package("@s/pkg/a"),
            Some(("@s/pkg", "./a".to_owned()))
        );
        assert_eq!(split_package(".x"), None);
    }

    #[test]
    fn orders_patterns_by_specificity() {
        let mut keys = vec!["./*", "./a/*.js", "./a/*", "./a/b"];
        keys.sort_by(|a, b| pattern_key_compare(a, b));
        assert_eq!(keys, ["./a/*.js", "./a/*", "./*", "./a/b"]);
    }

    #[test]
    fn resolves_exports_conditions_patterns_and_main() {
        let root = std::env::temp_dir().join(format!("buoy-resolve-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let modules = root.join("node_modules");
        write(
            &modules.join("dual/package.json"),
            r#"{"name":"dual","exports":{".":{"import":"./esm.mjs","require":"./cjs.js"},"./feature/*":"./lib/*.js","./hidden/*":null}}"#,
        );
        write(&modules.join("dual/esm.mjs"), "");
        write(&modules.join("dual/cjs.js"), "");
        write(&modules.join("dual/lib/x.js"), "");
        write(&modules.join("old/package.json"), r#"{"main":"lib/main"}"#);
        write(
            &modules.join("browser-first/package.json"),
            r#"{"name":"browser-first","exports":{".":{"browser":"./browser.js","import":"./node.js"}}}"#,
        );
        write(&modules.join("browser-first/browser.js"), "");
        write(&modules.join("browser-first/node.js"), "");
        write(&modules.join("old/lib/main.js"), "");
        write(
            &root.join("package.json"),
            r##"{"name":"app","type":"module","imports":{"#util":"./util.js"},"exports":"./app.js"}"##,
        );
        write(&root.join("util.js"), "");
        write(&root.join("app.js"), "");
        let importer = root.join("app.js");
        let resolver = Resolver::default();
        let file = |specifier: &str, mode| match resolver.resolve(specifier, &importer, mode) {
            Ok(Target::File(path)) => path
                .strip_prefix(root.canonicalize().unwrap_or_default())
                .map(Path::to_path_buf)
                .unwrap_or(path),
            other => panic!("{specifier}: {other:?}"),
        };
        assert_eq!(
            file("dual", Mode::Import),
            Path::new("node_modules/dual/esm.mjs")
        );
        assert_eq!(
            file("dual", Mode::Require),
            Path::new("node_modules/dual/cjs.js")
        );
        assert_eq!(
            file("dual/feature/x", Mode::Import),
            Path::new("node_modules/dual/lib/x.js")
        );
        assert_eq!(
            file("old", Mode::Import),
            Path::new("node_modules/old/lib/main.js")
        );
        assert_eq!(
            file("old", Mode::Require),
            Path::new("node_modules/old/lib/main.js")
        );
        assert_eq!(file("#util", Mode::Import), Path::new("util.js"));
        assert_eq!(
            file("browser-first", Mode::Import),
            Path::new("node_modules/browser-first/node.js")
        );
        assert_eq!(file("app", Mode::Import), Path::new("app.js"));
        assert_eq!(
            resolver
                .resolve("dual/hidden/x", &importer, Mode::Import)
                .map_err(|failure| failure.code),
            Err("ERR_PACKAGE_PATH_NOT_EXPORTED")
        );
        assert_eq!(
            resolver.resolve("node:fs", &importer, Mode::Import),
            Ok(Target::Builtin("fs".to_owned()))
        );
        assert_eq!(resolver.format(&importer), Format::Esm);
        assert_eq!(
            resolver.format(&modules.join("old/lib/main.js")),
            Format::Detect
        );
        let _ = fs::remove_dir_all(&root);
    }
}
