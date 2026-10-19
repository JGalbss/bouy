//! The native bindings of Node at the tag of `.node-version` (docs/design/node-builtins.md
//! section 3): each name that `internalBinding` takes, and each member that Node's `src/`
//! sets on the binding object. `buoy-suites node-bindings` reads `src/` from a cached checkout
//! of nodejs/node and writes `tests/node/bindings.json` and `runtime/src/node/buoy_node_manifest.erl`,
//! from which `buoy_node:binding/1` gives a binding a stub for each function and class that it
//! lacks. The dashboard counts, for each binding, the members that
//! `runtime/src/node/bindings/buoy_binding_<name>.erl` implements.
//!
//! The reader is a small preprocessor and a match over tokens, not a C++ parser. It expands
//! the function-like macros of a file and the list macros of the headers, and it follows each
//! call that passes the binding object, or an object or a class template that becomes a member,
//! into the function that Node defines.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use std::rc::Rc;

use serde::{Deserialize, Serialize};

/// The manifest, relative to the repository root.
pub const MANIFEST: &str = "tests/node/bindings.json";
/// The Erlang module of the manifest, relative to the repository root.
pub const ERLANG: &str = "runtime/src/node/buoy_node_manifest.erl";
/// The command that writes the two files.
pub const COMMAND: &str = "cargo run --release -p buoy-suites -- node-bindings";

/// The macros that set a member. The reader matches them, so it never expands them.
const PRIMITIVES: [&str; 12] = [
    "NODE_DEFINE_CONSTANT",
    "NODE_DEFINE_HIDDEN_CONSTANT",
    "NODE_DEFINE_STRING_CONSTANT",
    "READONLY_PROPERTY",
    "READONLY_DONT_ENUM_PROPERTY",
    "READONLY_FALSE_PROPERTY",
    "READONLY_TRUE_PROPERTY",
    "READONLY_STRING_PROPERTY",
    "FIXED_ONE_BYTE_STRING",
    "NODE_BINDING_CONTEXT_AWARE_INTERNAL",
    "NODE_BINDING_PER_ISOLATE_INIT",
    "NODE_BINDING_EXTERNAL_REFERENCE",
];

/// The words before `(` that never start a function definition.
const KEYWORDS: [&str; 12] = [
    "if",
    "for",
    "while",
    "switch",
    "catch",
    "return",
    "sizeof",
    "alignof",
    "decltype",
    "static_assert",
    "defined",
    "noexcept",
];

/// The tokens before a name that make `name(...)` a call, not a definition.
const CALL_CONTEXT: [&str; 17] = [
    ".", "->", "=", "(", ",", "return", "new", "!", "&&", "||", "?", "+", "-", "<<", "case",
    "throw", "delete",
];

/// The functions that turn a C string into the V8 string of a property name.
const NAME_FUNCTIONS: [&str; 6] = [
    "FIXED_ONE_BYTE_STRING",
    "OneByteString",
    "NewFromUtf8Literal",
    "NewFromUtf8",
    "NewFromOneByte",
    "Utf8String",
];

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Manifest {
    pub generated_by: String,
    /// The tag of nodejs/node.
    pub node: String,
    pub commit: String,
    pub bindings: BTreeMap<String, Binding>,
}

#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Binding {
    /// The files under `src/` that register the binding.
    pub sources: BTreeSet<String>,
    /// The preprocessor condition under which Node builds the binding, such as `HAVE_OPENSSL`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
    pub members: BTreeMap<String, Member>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Member {
    pub kind: Kind,
    /// Node sets the member only under a preprocessor condition, such as a platform.
    #[serde(default, skip_serializing_if = "is_false")]
    pub conditional: bool,
    /// The methods of the prototype of a class.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub prototype: BTreeSet<String>,
    /// The other properties of the prototype of a class: accessors and values.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub accessors: BTreeSet<String>,
    /// The members of an object, or the static members of a class.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub members: BTreeMap<String, Member>,
}

#[allow(clippy::trivially_copy_pass_by_ref)]
fn is_false(value: &bool) -> bool {
    !value
}

/// What a member holds. The order ranks a guess: a later kind is more specific.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Value,
    Object,
    Function,
    Class,
}

/// The coverage of one binding on the dashboard.
#[derive(Debug, Serialize)]
pub struct Coverage {
    pub binding: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
    pub members: usize,
    pub implemented: usize,
    /// The Erlang module of the binding, when Buoy has one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub module: Option<String>,
}

/// Reads Node's `src/` at the tag of `.node-version` from the cache, fetching it on first use,
/// and writes the manifest and its Erlang module. Returns the manifest.
pub fn update(root: &Path) -> Result<Manifest, String> {
    let version = fs::read_to_string(root.join(".node-version"))
        .map_err(|error| format!(".node-version: {error}"))?;
    let tag = format!("v{}", version.trim());
    let sparse: Vec<String> = SOURCE_DIRECTORIES
        .iter()
        .map(|directory| format!("/{directory}/"))
        .collect();
    let sparse: Vec<&str> = sparse.iter().map(String::as_str).collect();
    let (checkout, commit) = crate::cached_checkout(
        &format!("node-{tag}"),
        "https://github.com/nodejs/node.git",
        &format!("refs/tags/{tag}"),
        &sparse,
    )?;
    let mut manifest = read_sources(&checkout)?;
    manifest.node = tag;
    manifest.commit = commit;
    crate::write(&root.join(MANIFEST), &crate::json(&manifest)?)?;
    crate::write(&root.join(ERLANG), &erlang(&manifest))?;
    Ok(manifest)
}

/// The committed manifest.
pub fn load(root: &Path) -> Result<Manifest, String> {
    let text =
        fs::read_to_string(root.join(MANIFEST)).map_err(|error| format!("{MANIFEST}: {error}"))?;
    serde_json::from_str(&text).map_err(|error| format!("{MANIFEST}: {error}"))
}

/// The Erlang module of the manifest: for each binding, the functions and classes that Node
/// sets on every platform.
#[must_use]
pub fn erlang(manifest: &Manifest) -> String {
    let mut text = format!(
        "%% Generated by `buoy-suites node-bindings` from {MANIFEST}. Do not edit; run\n\
         %% `{COMMAND}`.\n\
         %%\n\
         %% The functions and classes that src/ of Node {} sets on each binding object\n\
         %% on every platform, each class with the methods of its prototype.\n\
         %% buoy_node:binding/1 gives a binding a stub that throws\n\
         %% ERR_BUOY_NOT_IMPLEMENTED for each one that it lacks.\n\
         -module(buoy_node_manifest).\n\n\
         -export([members/1]).\n\n\
         -spec members(binary()) -> [{{binary(), function | {{class, [binary()]}}}}].\n",
        manifest.node
    );
    for (name, binding) in &manifest.bindings {
        let members: Vec<String> = binding
            .members
            .iter()
            .filter(|(_, member)| {
                !member.conditional && matches!(member.kind, Kind::Function | Kind::Class)
            })
            .map(|(key, member)| {
                if member.kind == Kind::Function {
                    return format!("{{{}, function}}", binary(key));
                }
                let methods: Vec<String> =
                    member.prototype.iter().map(|name| binary(name)).collect();
                format!("{{{}, {{class, [{}]}}}}", binary(key), methods.join(", "))
            })
            .collect();
        if members.is_empty() {
            continue;
        }
        let _ = write!(
            text,
            "members({}) ->\n    [{}];\n",
            binary(name),
            members.join(",\n     ")
        );
    }
    text.push_str("members(_) ->\n    [].\n");
    text
}

fn binary(text: &str) -> String {
    format!(
        "<<\"{}\">>",
        text.replace('\\', "\\\\").replace('"', "\\\"")
    )
}

/// The coverage of each binding of the manifest: the members whose name the Erlang module of
/// the binding holds as a binary, apart from the names that it passes to `stubs/2`,
/// `not_implemented/2`, or `missing_constructor/3` of `buoy_node`. A binding without its
/// module, such as one of `buoy_node_stubs`, implements no member.
pub fn coverage(root: &Path) -> Result<Vec<Coverage>, String> {
    let manifest = load(root)?;
    let mut rows = Vec::new();
    for (name, binding) in &manifest.bindings {
        let module = format!("runtime/src/node/bindings/buoy_binding_{name}.erl");
        let (implemented, module) = match fs::read_to_string(root.join(&module)) {
            Ok(text) => {
                let stubbed = erlang_stubs(&text);
                let names = erlang_binaries(&text);
                let implemented = binding
                    .members
                    .keys()
                    .filter(|key| names.contains(*key) && !stubbed.contains(*key))
                    .count();
                (implemented, Some(module))
            }
            Err(_) => (0, None),
        };
        rows.push(Coverage {
            binding: name.clone(),
            condition: binding.condition.clone(),
            members: binding.members.len(),
            implemented,
            module,
        });
    }
    Ok(rows)
}

/// The text of each binary literal `<<"...">>` of Erlang source.
fn erlang_binaries(text: &str) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    let mut rest = text;
    while let Some(start) = rest.find("<<\"") {
        rest = &rest[start + 3..];
        let mut value = String::new();
        let mut chars = rest.char_indices();
        while let Some((index, character)) = chars.next() {
            match character {
                '\\' => {
                    if let Some((_, escaped)) = chars.next() {
                        value.push(escaped);
                    }
                }
                '"' => {
                    rest = &rest[index + 1..];
                    break;
                }
                other => value.push(other),
            }
        }
        found.insert(value);
    }
    found
}

/// The member names that Erlang source passes to the stub helpers of `buoy_node`.
fn erlang_stubs(text: &str) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    for call in ["not_implemented(", "missing_constructor("] {
        for (start, _) in text.match_indices(call) {
            let arguments = &text[start + call.len()..];
            let end = arguments.find(')').unwrap_or(arguments.len());
            // The arguments are the binding, then the member.
            if let Some(name) = ordered_binaries(&arguments[..end]).into_iter().nth(1) {
                found.insert(name);
            }
        }
    }
    for (start, _) in text.match_indices("stubs(") {
        let arguments = &text[start..];
        let (Some(open), Some(close)) = (arguments.find('['), arguments.find(']')) else {
            continue;
        };
        if open < close {
            found.extend(ordered_binaries(&arguments[open..close]));
        }
    }
    found
}

/// The binary literals of Erlang source in order.
fn ordered_binaries(text: &str) -> Vec<String> {
    text.split("<<\"")
        .skip(1)
        .filter_map(|part| part.split('"').next().map(str::to_owned))
        .collect()
}

// The reader of src/.

/// The source directories of the checkout that the reader reads: Node's own code, and the
/// headers of libuv for the lists of its error codes.
const SOURCE_DIRECTORIES: [&str; 2] = ["src", "deps/uv/include"];

/// The preprocessor branches around a token: for each enclosing `#if` group, outermost first,
/// the group and the index of its branch.
type Branches = Rc<Vec<(usize, usize)>>;

/// One token of preprocessed C++.
#[derive(Debug, Clone)]
struct Tok {
    token: Token,
    branches: Branches,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Token {
    Ident(String),
    Str(String),
    Punct(String),
    Number,
}

impl Tok {
    fn ident(&self) -> Option<&str> {
        match &self.token {
            Token::Ident(name) => Some(name),
            _ => None,
        }
    }

    fn is(&self, text: &str) -> bool {
        match &self.token {
            Token::Punct(punct) => punct == text,
            Token::Ident(name) => name == text,
            _ => false,
        }
    }

    fn text(&self) -> String {
        match &self.token {
            Token::Ident(text) | Token::Punct(text) => text.clone(),
            Token::Str(text) => format!("\"{text}\""),
            Token::Number => "0".to_owned(),
        }
    }
}

/// An `#if` group: its branch count, and whether its last branch is an `#else`.
#[derive(Debug, Clone, Copy)]
struct Group {
    branches: usize,
    has_else: bool,
}

/// A function-like macro.
#[derive(Debug, Clone)]
struct Macro {
    params: Vec<String>,
    variadic: bool,
    body: Vec<Tok>,
}

/// One file of the checkout after preprocessing.
#[derive(Debug)]
struct Unit {
    path: String,
    tokens: Vec<Tok>,
}

/// A function definition of a unit.
#[derive(Debug)]
struct Definition {
    unit: usize,
    name: String,
    /// `X` of a definition written `X::name`.
    qualifier: Option<String>,
    /// The namespaces and classes around the definition, outermost first.
    scope: Vec<String>,
    params: Vec<Param>,
    /// The token indexes of `{` and `}` of the body.
    body: (usize, usize),
}

impl Definition {
    /// Whether `qualifier::name` names this definition.
    fn is_in(&self, qualifier: &str) -> bool {
        match &self.qualifier {
            Some(own) => own == qualifier,
            None => self.scope.last().is_some_and(|scope| scope == qualifier),
        }
    }

    /// The class of a method, for the calls of its body that name no class.
    fn class(&self) -> Option<&str> {
        self.qualifier
            .as_deref()
            .or(self.scope.last().map(String::as_str))
    }
}

#[derive(Debug)]
struct Param {
    name: String,
    types: Vec<String>,
}

/// What the definitions of every unit declare besides functions: the parameters of each class
/// template, each alias of a template class, and each string constant of a class.
#[derive(Debug, Default)]
struct Declarations {
    templates: HashMap<String, Vec<String>>,
    aliases: HashMap<String, (String, Vec<String>)>,
    constants: HashMap<(String, String), String>,
}

/// Reads the source directories of a checkout of nodejs/node and returns the manifest of its
/// bindings.
fn read_sources(checkout: &Path) -> Result<Manifest, String> {
    let mut files = Vec::new();
    for directory in SOURCE_DIRECTORIES {
        if checkout.join(directory).is_dir() {
            collect_files(checkout, directory, &mut files)?;
        }
    }
    files.sort();
    let texts: Vec<(String, String)> = files
        .into_iter()
        .map(|path| {
            fs::read_to_string(checkout.join(&path))
                .map(|text| (path.clone(), join_lines(&strip_comments(&text))))
                .map_err(|error| format!("{path}: {error}"))
        })
        .collect::<Result<_, _>>()?;
    let lists = list_macros(&texts);
    let mut groups = Vec::new();
    let units: Vec<Unit> = texts
        .iter()
        .map(|(path, text)| Unit {
            path: path.clone(),
            tokens: preprocess(text, &lists, &mut groups),
        })
        .collect();
    let strings = texts
        .iter()
        .find(|(path, _)| path == "src/env_properties.h")
        .map(|(_, text)| env_strings(text))
        .unwrap_or_default();
    let conditions = binding_conditions(&texts);
    let mut declarations = Declarations::default();
    let definitions: Vec<Definition> = units
        .iter()
        .enumerate()
        .flat_map(|(index, unit)| definitions(index, &unit.tokens, &mut declarations))
        .collect();
    let mut reader = Reader::new(&units, &definitions, &strings, &declarations);
    let mut roots: BTreeMap<String, (usize, BTreeSet<String>)> = BTreeMap::new();
    for (unit_index, unit) in units.iter().enumerate() {
        for (binding, qualifier, function) in registrations(&unit.tokens) {
            if conditions
                .get(&binding)
                .is_some_and(|condition| condition.as_deref() == Some("DEBUG"))
            {
                continue;
            }
            let Some(definition) = reader.find(unit_index, qualifier.as_deref(), &function, None)
            else {
                continue;
            };
            let Some(target) = definitions[definition]
                .params
                .iter()
                .find(|param| {
                    param
                        .types
                        .iter()
                        .any(|kind| kind == "Object" || kind == "ObjectTemplate")
                })
                .map(|param| param.name.clone())
            else {
                continue;
            };
            let next = reader.nodes.len();
            let (root, sources) = roots
                .entry(binding)
                .or_insert_with(|| (next, BTreeSet::new()));
            if *root == next {
                reader.nodes.push(Node::default());
            }
            sources.insert(unit.path.clone());
            let scope = HashMap::from([(target, Value::Node(*root))]);
            let _ = reader.read(definition, scope, &[]);
        }
    }
    let mut bindings: BTreeMap<String, Binding> = roots
        .into_iter()
        .map(|(name, (root, sources))| {
            let binding = Binding {
                sources,
                condition: conditions.get(&name).cloned().flatten(),
                members: reader.members(root, &groups, 0),
            };
            (name, binding)
        })
        .collect();
    // A listed binding whose registration the reader cannot follow still gets its entry.
    for (name, condition) in conditions {
        if condition.as_deref() != Some("DEBUG") {
            bindings.entry(name).or_insert_with(|| Binding {
                condition,
                ..Binding::default()
            });
        }
    }
    Ok(Manifest {
        generated_by: "buoy-suites node-bindings".to_owned(),
        node: String::new(),
        commit: String::new(),
        bindings,
    })
}

fn collect_files(source: &Path, relative: &str, files: &mut Vec<String>) -> Result<(), String> {
    let directory = source.join(relative);
    for entry in fs::read_dir(&directory)
        .map_err(|error| format!("{}: {error}", directory.display()))?
        .filter_map(Result::ok)
    {
        let name = entry.file_name().to_string_lossy().into_owned();
        let child = format!("{relative}/{name}");
        if entry.path().is_dir() {
            collect_files(source, &child, files)?;
        } else if Path::new(&name)
            .extension()
            .is_some_and(|extension| extension == "cc" || extension == "h")
        {
            files.push(child);
        }
    }
    Ok(())
}

/// The text without its comments. String and character literals stay, and so do the line
/// breaks. A raw string becomes `""`.
fn strip_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < text.len() {
        let rest = &text[index..];
        if rest.starts_with("//") {
            index += rest.find('\n').unwrap_or(rest.len());
            continue;
        }
        if let Some(inner) = rest.strip_prefix("/*") {
            let end = inner.find("*/").map_or(rest.len(), |end| end + 4);
            out.extend(rest[..end].chars().filter(|&character| character == '\n'));
            index += end;
            continue;
        }
        if let Some(end) = raw_string(rest) {
            out.push_str("\"\"");
            out.extend(rest[..end].chars().filter(|&character| character == '\n'));
            index += end;
            continue;
        }
        let character = rest.chars().next().unwrap_or(' ');
        if character == '"' || character == '\'' {
            let mut end = rest.len();
            let mut escaped = false;
            for (offset, next) in rest.char_indices().skip(1) {
                if escaped {
                    escaped = false;
                } else if next == '\\' {
                    escaped = true;
                } else if next == character || next == '\n' {
                    end = offset + next.len_utf8();
                    break;
                }
            }
            out.push_str(&rest[..end]);
            index += end;
            continue;
        }
        out.push(character);
        index += character.len_utf8();
    }
    out
}

/// The length of a raw string `R"delimiter(...)delimiter"` at the start of `text`.
fn raw_string(text: &str) -> Option<usize> {
    let rest = text.strip_prefix("R\"")?;
    let open = rest.find('(')?;
    let close = format!("){}\"", &rest[..open]);
    Some(2 + open + rest[open..].find(&close)? + close.len())
}

/// The text with each continuation line joined to the line before it.
fn join_lines(text: &str) -> String {
    text.replace("\\\r\n", " ").replace("\\\n", " ")
}

/// The tokens of a line of C++.
fn tokenize(text: &str, branches: &Branches) -> Vec<Tok> {
    const PUNCTS: [&str; 10] = ["::", "->", "##", "&&", "||", "==", "!=", "<=", "+=", "-="];
    let mut tokens: Vec<Tok> = Vec::new();
    let mut chars = text.char_indices().peekable();
    let tok = |token| Tok {
        token,
        branches: Rc::clone(branches),
    };
    while let Some(&(start, character)) = chars.peek() {
        if character.is_whitespace() {
            chars.next();
            continue;
        }
        if character.is_ascii_alphabetic() || character == '_' {
            let mut end = start;
            while let Some(&(index, next)) = chars.peek() {
                if !(next.is_ascii_alphanumeric() || next == '_') {
                    break;
                }
                end = index + next.len_utf8();
                chars.next();
            }
            tokens.push(tok(Token::Ident(text[start..end].to_owned())));
            continue;
        }
        if character.is_ascii_digit() {
            while chars.peek().is_some_and(|&(_, next)| {
                next.is_ascii_alphanumeric() || next == '.' || next == '\''
            }) {
                chars.next();
            }
            tokens.push(tok(Token::Number));
            continue;
        }
        if character == '"' || character == '\'' {
            chars.next();
            let mut value = String::new();
            while let Some((_, next)) = chars.next() {
                if next == '\\' {
                    if let Some((_, escaped)) = chars.next() {
                        value.push('\\');
                        value.push(escaped);
                    }
                    continue;
                }
                if next == character {
                    break;
                }
                value.push(next);
            }
            if character == '\'' {
                tokens.push(tok(Token::Number));
            } else {
                tokens.push(tok(Token::Str(value)));
            }
            continue;
        }
        let rest = &text[start..];
        let punct = PUNCTS
            .iter()
            .find(|punct| rest.starts_with(**punct))
            .map_or_else(|| character.to_string(), |punct| (*punct).to_owned());
        for _ in 0..punct.chars().count() {
            chars.next();
        }
        tokens.push(tok(Token::Punct(punct)));
    }
    concatenate(tokens)
}

/// The tokens with each run of adjacent string literals joined into one, as C++ joins them.
fn concatenate(tokens: Vec<Tok>) -> Vec<Tok> {
    let mut out: Vec<Tok> = Vec::with_capacity(tokens.len());
    for token in tokens {
        if let (
            Token::Str(next),
            Some(Tok {
                token: Token::Str(previous),
                ..
            }),
        ) = (&token.token, out.last_mut())
        {
            previous.push_str(next);
            continue;
        }
        out.push(token);
    }
    out
}

/// A directive line: its name and the rest, as `("define", "X(a) a")`.
fn directive(line: &str) -> Option<(&str, &str)> {
    let rest = line.trim_start().strip_prefix('#')?.trim_start();
    let end = rest
        .find(|character: char| !character.is_ascii_alphanumeric() && character != '_')
        .unwrap_or(rest.len());
    Some((&rest[..end], rest[end..].trim()))
}

/// The macro of a `#define` line when it is function-like: its name and the macro.
fn define(rest: &str) -> Option<(String, Macro)> {
    let open = rest.find('(')?;
    let name = &rest[..open];
    if name.is_empty()
        || !name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_')
    {
        return None;
    }
    let close = rest[open..].find(')')? + open;
    let mut params = Vec::new();
    let mut variadic = false;
    for param in rest[open + 1..close].split(',').map(str::trim) {
        if param == "..." {
            variadic = true;
        } else if let Some(named) = param.strip_suffix("...") {
            variadic = true;
            params.push(named.trim().to_owned());
        } else if !param.is_empty() {
            params.push(param.to_owned());
        }
    }
    let body = tokenize(&rest[close + 1..], &Rc::new(Vec::new()));
    Some((
        name.to_owned(),
        Macro {
            params,
            variadic,
            body,
        },
    ))
}

/// The list macros of every file, such as `PER_ISOLATE_STRING_PROPERTIES(V)`: one parameter,
/// and a body of `V(...)` items and other lists of `V`. A list defined twice keeps its longest
/// body, as the definitions differ by build condition.
fn list_macros(texts: &[(String, String)]) -> HashMap<String, Macro> {
    let mut lists: HashMap<String, Macro> = HashMap::new();
    for (_, text) in texts {
        for line in text.lines() {
            let Some(("define", rest)) = directive(line) else {
                continue;
            };
            let Some((name, found)) = define(rest) else {
                continue;
            };
            if found.params.len() != 1 || found.variadic || !is_list(&found) {
                continue;
            }
            if lists
                .get(&name)
                .is_none_or(|known| known.body.len() < found.body.len())
            {
                lists.insert(name, found);
            }
        }
    }
    lists
}

fn is_list(candidate: &Macro) -> bool {
    let param = &candidate.params[0];
    let body = &candidate.body;
    let mut index = 0;
    while index < body.len() {
        if body[index].is(";") {
            index += 1;
            continue;
        }
        let Some(name) = body[index].ident() else {
            return false;
        };
        if !body.get(index + 1).is_some_and(|next| next.is("(")) {
            return false;
        }
        let Some(close) = matching(body, index + 1) else {
            return false;
        };
        let is_item = name == param;
        let is_nested = close == index + 3 && body[index + 2].is(param);
        if !is_item && !is_nested {
            return false;
        }
        index = close + 1;
    }
    !body.is_empty()
}

/// The index of the token that closes the bracket at `open`.
fn matching(tokens: &[Tok], open: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (index, token) in tokens.iter().enumerate().skip(open) {
        if token.is("(") || token.is("[") || token.is("{") {
            depth += 1;
        } else if token.is(")") || token.is("]") || token.is("}") {
            depth = depth.checked_sub(1)?;
            if depth == 0 {
                return Some(index);
            }
        }
    }
    None
}

/// The index of the `>` that closes the `<` at `open`.
fn matching_angle(tokens: &[Tok], open: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (index, token) in tokens.iter().enumerate().skip(open) {
        if token.is("<") {
            depth += 1;
        } else if token.is(">") {
            depth = depth.checked_sub(1)?;
            if depth == 0 {
                return Some(index);
            }
        } else if token.is(";") || token.is("{") {
            return None;
        }
    }
    None
}

/// The arguments between the bracket at `open` and its match, split at the top-level commas.
fn arguments(tokens: &[Tok], open: usize) -> Option<(Vec<&[Tok]>, usize)> {
    let close = matching(tokens, open)?;
    let mut parts = Vec::new();
    let mut depth = 0usize;
    let mut start = open + 1;
    for index in open + 1..close {
        let token = &tokens[index];
        if token.is("(") || token.is("[") || token.is("{") {
            depth += 1;
        } else if token.is(")") || token.is("]") || token.is("}") {
            depth = depth.saturating_sub(1);
        } else if token.is(",") && depth == 0 {
            parts.push(&tokens[start..index]);
            start = index + 1;
        }
    }
    if start < close || !parts.is_empty() {
        parts.push(&tokens[start..close]);
    }
    Some((parts, close))
}

/// The tokens of a file, with the function-like macros of the file, at the point of each use,
/// and the list macros expanded. Each `#if` group of the file gets an entry of `groups`.
fn preprocess(text: &str, lists: &HashMap<String, Macro>, groups: &mut Vec<Group>) -> Vec<Tok> {
    let mut out = Vec::new();
    let mut local: HashMap<String, Macro> = HashMap::new();
    let mut pending: Vec<Tok> = Vec::new();
    let mut stack: Vec<(usize, usize)> = Vec::new();
    let mut branches: Branches = Rc::new(Vec::new());
    for line in text.lines() {
        let Some((name, rest)) = directive(line) else {
            pending.extend(tokenize(line, &branches));
            continue;
        };
        out.extend(expand(
            &concatenate(std::mem::take(&mut pending)),
            &local,
            lists,
            0,
        ));
        match name {
            "if" | "ifdef" | "ifndef" => {
                groups.push(Group {
                    branches: 1,
                    has_else: false,
                });
                stack.push((groups.len() - 1, 0));
            }
            "elif" | "else" => {
                if let Some((group, branch)) = stack.last_mut() {
                    *branch += 1;
                    groups[*group].branches += 1;
                    groups[*group].has_else = name == "else";
                }
            }
            "endif" => {
                stack.pop();
            }
            "define" => {
                if let Some((name, found)) = define(rest) {
                    // An empty alternative of another build keeps the definition that has a body.
                    let keep = found.body.is_empty()
                        && local.get(&name).is_some_and(|known| !known.body.is_empty());
                    if !keep {
                        local.insert(name, found);
                    }
                }
            }
            "undef" => {
                local.remove(rest.trim());
            }
            _ => {}
        }
        if matches!(name, "if" | "ifdef" | "ifndef" | "elif" | "else" | "endif") {
            branches = Rc::new(stack.clone());
        }
    }
    out.extend(expand(&concatenate(pending), &local, lists, 0));
    out
}

/// The tokens with each use of a macro of `local` or `lists` replaced by its expansion.
fn expand(
    tokens: &[Tok],
    local: &HashMap<String, Macro>,
    lists: &HashMap<String, Macro>,
    level: usize,
) -> Vec<Tok> {
    let mut out = Vec::with_capacity(tokens.len());
    let mut index = 0;
    while index < tokens.len() {
        let token = &tokens[index];
        let found = token
            .ident()
            .filter(|name| !PRIMITIVES.contains(name))
            .and_then(|name| local.get(name).or_else(|| lists.get(name)))
            .filter(|_| level < 24 && tokens.get(index + 1).is_some_and(|next| next.is("(")));
        let expansion = found.and_then(|found| {
            let (args, close) = arguments(tokens, index + 1)?;
            Some((substitute(found, &args, &token.branches), close))
        });
        let Some((substituted, close)) = expansion else {
            out.push(token.clone());
            index += 1;
            continue;
        };
        out.extend(expand(&substituted, local, lists, level + 1));
        index = close + 1;
    }
    out
}

/// The body of a macro with its arguments: `#param` gives a string, and `##` pastes.
fn substitute(found: &Macro, args: &[&[Tok]], branches: &Branches) -> Vec<Tok> {
    let tok = |token| Tok {
        token,
        branches: Rc::clone(branches),
    };
    let argument = |name: &str| -> Option<Vec<Tok>> {
        if name == "__VA_ARGS__" && found.variadic {
            let mut joined = Vec::new();
            for (index, arg) in args.iter().enumerate().skip(found.params.len()) {
                if index > found.params.len() {
                    joined.push(tok(Token::Punct(",".to_owned())));
                }
                joined.extend(arg.iter().cloned());
            }
            return Some(joined);
        }
        let position = found.params.iter().position(|param| param == name)?;
        Some(
            args.get(position)
                .map(|arg| arg.to_vec())
                .unwrap_or_default(),
        )
    };
    let mut out: Vec<Tok> = Vec::new();
    let mut index = 0;
    let mut paste = false;
    while index < found.body.len() {
        let token = &found.body[index];
        index += 1;
        if token.is("##") {
            paste = true;
            continue;
        }
        let mut pieces = if token.is("#") {
            let text = found
                .body
                .get(index)
                .and_then(Tok::ident)
                .and_then(argument)
                .map(|arg| arg.iter().map(Tok::text).collect::<String>())
                .unwrap_or_default();
            index += 1;
            vec![tok(Token::Str(text))]
        } else if let Some(arg) = token.ident().and_then(argument) {
            arg
        } else {
            vec![tok(token.token.clone())]
        };
        for piece in &mut pieces {
            piece.branches = Rc::clone(branches);
        }
        if paste && !pieces.is_empty() {
            paste = false;
            if let Some(previous) = out.pop() {
                let first = pieces.remove(0);
                out.push(tok(Token::Ident(format!(
                    "{}{}",
                    previous.text(),
                    first.text()
                ))));
            }
        }
        out.extend(pieces);
    }
    concatenate(out)
}

/// The text of each `V(name, "text")` of `env_properties.h`: the strings, the symbols, and the
/// private symbols of an `Environment`.
fn env_strings(text: &str) -> HashMap<String, String> {
    let tokens = tokenize(text, &Rc::new(Vec::new()));
    tokens
        .windows(5)
        .filter_map(|window| match window {
            [
                open,
                Tok {
                    token: Token::Ident(name),
                    ..
                },
                comma,
                Tok {
                    token: Token::Str(value),
                    ..
                },
                close,
            ] if open.is("(") && comma.is(",") && close.is(")") => {
                Some((name.clone(), value.clone()))
            }
            _ => None,
        })
        .collect()
}

/// Each binding of the `NODE_BUILTIN_*_BINDINGS` lists of `node_binding.h` and `node_binding.cc`,
/// with the build condition of its list, such as `HAVE_OPENSSL` for `crypto`.
fn binding_conditions(texts: &[(String, String)]) -> BTreeMap<String, Option<String>> {
    let mut conditions = BTreeMap::new();
    for (path, text) in texts {
        if path != "src/node_binding.h" && path != "src/node_binding.cc" {
            continue;
        }
        let mut stack: Vec<String> = Vec::new();
        for line in text.lines() {
            let Some((name, rest)) = directive(line) else {
                continue;
            };
            match name {
                "if" | "ifdef" | "ifndef" => stack.push(rest.to_owned()),
                "endif" => {
                    stack.pop();
                }
                "define" if rest.starts_with("NODE_BUILTIN_") => {
                    let Some((_, found)) = define(rest) else {
                        continue;
                    };
                    let condition = stack
                        .iter()
                        .rev()
                        .find(|condition| {
                            !condition.starts_with("SRC_")
                                && !condition.contains("NODE_WANT_INTERNALS")
                        })
                        .cloned();
                    for window in found.body.windows(4) {
                        if let [
                            v,
                            open,
                            Tok {
                                token: Token::Ident(binding),
                                ..
                            },
                            close,
                        ] = window
                            && v.is("V")
                            && open.is("(")
                            && close.is(")")
                        {
                            conditions.insert(binding.clone(), condition.clone());
                        }
                    }
                }
                _ => {}
            }
        }
    }
    conditions
}

/// Each `NODE_BINDING_CONTEXT_AWARE_INTERNAL(name, function)` and
/// `NODE_BINDING_PER_ISOLATE_INIT(name, function)` of a unit: the binding, and the qualifier
/// and the name of its function.
fn registrations(tokens: &[Tok]) -> Vec<(String, Option<String>, String)> {
    let mut found = Vec::new();
    for (index, token) in tokens.iter().enumerate() {
        if !(token.is("NODE_BINDING_CONTEXT_AWARE_INTERNAL")
            || token.is("NODE_BINDING_PER_ISOLATE_INIT"))
        {
            continue;
        }
        let Some((args, _)) = arguments(tokens, index + 1) else {
            continue;
        };
        let (Some(binding), Some(function)) = (args.first(), args.get(1)) else {
            continue;
        };
        let (Some(binding), Some(name)) = (
            binding.first().and_then(Tok::ident),
            function.last().and_then(Tok::ident),
        ) else {
            continue;
        };
        let qualifier = function
            .len()
            .checked_sub(3)
            .and_then(|position| function[position].ident().map(str::to_owned));
        found.push((binding.to_owned(), qualifier, name.to_owned()));
    }
    found
}

/// The function definitions of a unit. It records the other declarations of the unit in
/// `declarations`.
fn definitions(unit: usize, tokens: &[Tok], declarations: &mut Declarations) -> Vec<Definition> {
    let mut found = Vec::new();
    // The scope that each open brace opened, and the name that the next brace opens.
    let mut braces: Vec<Option<String>> = Vec::new();
    let mut pending: Option<String> = None;
    for index in 0..tokens.len() {
        let token = &tokens[index];
        if token.is("{") {
            braces.push(pending.take());
            continue;
        }
        if token.is("}") {
            braces.pop();
            continue;
        }
        if token.is(";") || token.is(")") {
            pending = None;
            continue;
        }
        if token.is("template") {
            template_parameters(tokens, index, declarations);
            continue;
        }
        if token.is("using") {
            alias(tokens, index, declarations);
            continue;
        }
        if ["namespace", "class", "struct"]
            .iter()
            .any(|word| token.is(word))
        {
            // `namespace node::worker::locks {` opens the last name of the chain.
            let mut at = index + 1;
            while token.is("namespace")
                && tokens.get(at + 1).is_some_and(|next| next.is("::"))
                && tokens.get(at + 2).and_then(Tok::ident).is_some()
            {
                at += 2;
            }
            if let Some(name) = tokens.get(at).and_then(Tok::ident) {
                pending = Some(name.to_owned());
            }
            continue;
        }
        let Some(name) = token.ident() else {
            continue;
        };
        let class = braces.iter().rev().find_map(Option::as_ref);
        if let (Some(class), Some(equals), Some(Token::Str(value))) = (
            class,
            tokens.get(index + 1),
            tokens.get(index + 2).map(|next| &next.token),
        ) && equals.is("=")
        {
            declarations
                .constants
                .insert((class.clone(), name.to_owned()), value.clone());
        }
        if let Some(definition) = definition(unit, tokens, index, &braces) {
            found.push(definition);
        }
    }
    found
}

/// The definition of a function whose name is at `index`, when the tokens there define one.
fn definition(
    unit: usize,
    tokens: &[Tok],
    index: usize,
    braces: &[Option<String>],
) -> Option<Definition> {
    let name = tokens[index].ident()?;
    if KEYWORDS.contains(&name) || !tokens.get(index + 1)?.is("(") {
        return None;
    }
    let mut start = index;
    let mut qualifier = None;
    if index >= 2 && tokens[index - 1].is("::") {
        qualifier = tokens[index - 2].ident().map(str::to_owned);
        start = index - 2;
        while start >= 2 && tokens[start - 1].is("::") && tokens[start - 2].ident().is_some() {
            start -= 2;
        }
    } else if index >= 1 && tokens[index - 1].is("~") {
        return None;
    }
    if start > 0
        && let Token::Punct(previous) | Token::Ident(previous) = &tokens[start - 1].token
        && CALL_CONTEXT.contains(&previous.as_str())
    {
        return None;
    }
    let (params, close) = arguments(tokens, index + 1)?;
    let body = body_start(tokens, close + 1)?;
    let end = matching(tokens, body)?;
    Some(Definition {
        unit,
        name: name.to_owned(),
        qualifier,
        scope: braces.iter().flatten().cloned().collect(),
        params: params.iter().filter_map(|param| parameter(param)).collect(),
        body: (body, end),
    })
}

/// `template <typename P, ...> class Name`: the parameters of the class template `Name`.
fn template_parameters(tokens: &[Tok], index: usize, declarations: &mut Declarations) {
    let open = index + 1;
    if !tokens.get(open).is_some_and(|token| token.is("<")) {
        return;
    }
    let Some(close) = matching_angle(tokens, open) else {
        return;
    };
    let params: Vec<String> = tokens[open + 1..close]
        .split(|token| token.is(","))
        .filter_map(|param| {
            let end = param
                .iter()
                .position(|token| token.is("="))
                .unwrap_or(param.len());
            param[..end]
                .iter()
                .rev()
                .find_map(Tok::ident)
                .map(str::to_owned)
        })
        .collect();
    let is_class = tokens
        .get(close + 1)
        .is_some_and(|token| token.is("class") || token.is("struct"));
    if let (true, Some(name)) = (is_class, tokens.get(close + 2).and_then(Tok::ident)) {
        declarations.templates.insert(name.to_owned(), params);
    }
}

/// `using Alias = Template<Arguments>;`.
fn alias(tokens: &[Tok], index: usize, declarations: &mut Declarations) {
    let (Some(name), Some(equals), Some(template), Some(open)) = (
        tokens.get(index + 1).and_then(Tok::ident),
        tokens.get(index + 2),
        tokens.get(index + 3).and_then(Tok::ident),
        tokens.get(index + 4),
    ) else {
        return;
    };
    if !equals.is("=") || !open.is("<") {
        return;
    }
    let Some(close) = matching_angle(tokens, index + 4) else {
        return;
    };
    declarations.aliases.insert(
        name.to_owned(),
        (
            template.to_owned(),
            type_arguments(&tokens[index + 5..close]),
        ),
    );
}

/// The type names of the arguments of a template, the last name of each.
fn type_arguments(tokens: &[Tok]) -> Vec<String> {
    tokens
        .split(|token| token.is(","))
        .filter_map(|argument| {
            argument
                .iter()
                .rev()
                .find_map(Tok::ident)
                .map(str::to_owned)
        })
        .collect()
}

/// The index of the `{` that opens a body after the parameter list, past qualifiers such as
/// `const` and a constructor's initializer list.
fn body_start(tokens: &[Tok], mut index: usize) -> Option<usize> {
    while tokens.get(index).is_some_and(|token| {
        [
            "const", "override", "noexcept", "final", "volatile", "&", "&&",
        ]
        .iter()
        .any(|word| token.is(word))
    }) {
        index += 1;
    }
    let token = tokens.get(index)?;
    if token.is("{") {
        return Some(index);
    }
    if !token.is(":") {
        return None;
    }
    index += 1;
    while let Some(token) = tokens.get(index) {
        if token.is(";") {
            return None;
        }
        if token.is("(") {
            index = matching(tokens, index)? + 1;
            continue;
        }
        if token.is("{") {
            if tokens[index - 1].is(")") || tokens[index - 1].is("}") {
                return Some(index);
            }
            index = matching(tokens, index)? + 1;
            continue;
        }
        index += 1;
    }
    None
}

fn parameter(tokens: &[Tok]) -> Option<Param> {
    let end = tokens
        .iter()
        .position(|token| token.is("="))
        .unwrap_or(tokens.len());
    let idents: Vec<String> = tokens[..end]
        .iter()
        .filter_map(|token| token.ident().map(str::to_owned))
        .collect();
    let (name, types) = idents.split_last()?;
    if name == "void" && types.is_empty() {
        return None;
    }
    Some(Param {
        name: name.clone(),
        types: types.to_vec(),
    })
}

/// Whether the branches of the places that set a member hold on every build: one place
/// outside any `#if` of the function, or an `#if` group with an `#else` whose every branch
/// holds a place.
fn always(places: &[&[(usize, usize)]], groups: &[Group]) -> bool {
    // The rest of each place, by its outermost group and branch.
    type ByBranch<'a> = BTreeMap<usize, Vec<&'a [(usize, usize)]>>;
    if places.iter().any(|place| place.is_empty()) {
        return true;
    }
    let mut by_group: BTreeMap<usize, ByBranch> = BTreeMap::new();
    for place in places {
        let (group, branch) = place[0];
        by_group
            .entry(group)
            .or_default()
            .entry(branch)
            .or_default()
            .push(&place[1..]);
    }
    by_group.iter().any(|(group, branches)| {
        let Group {
            branches: count,
            has_else,
        } = groups[*group];
        has_else
            && (0..count).all(|branch| {
                branches
                    .get(&branch)
                    .is_some_and(|inner| always(inner, groups))
            })
    })
}

/// An object or a class template that the reader follows.
#[derive(Debug, Default)]
struct Node {
    members: BTreeMap<String, Slot>,
    prototype: BTreeSet<String>,
    accessors: BTreeSet<String>,
    template: bool,
}

#[derive(Debug)]
struct Slot {
    kind: Kind,
    /// The branches of each place that sets the member, relative to the binding's function.
    places: Vec<Vec<(usize, usize)>>,
    node: Option<usize>,
}

/// What a variable of a function holds.
#[derive(Debug, Clone)]
enum Value {
    Node(usize),
    Text(String),
    /// A type that a template parameter stands for.
    Type(String),
}

type Scope = HashMap<String, Value>;

/// The reader of the function bodies.
struct Reader<'a> {
    units: &'a [Unit],
    definitions: &'a [Definition],
    by_name: HashMap<&'a str, Vec<usize>>,
    strings: &'a HashMap<String, String>,
    declarations: &'a Declarations,
    nodes: Vec<Node>,
    /// The definitions that the reader is inside, to stop a recursion.
    active: Vec<usize>,
    /// The unit and the class of the definition that the reader is inside.
    context: Vec<(usize, Option<String>)>,
}

impl<'a> Reader<'a> {
    fn new(
        units: &'a [Unit],
        definitions: &'a [Definition],
        strings: &'a HashMap<String, String>,
        declarations: &'a Declarations,
    ) -> Self {
        let mut by_name: HashMap<&str, Vec<usize>> = HashMap::new();
        for (index, definition) in definitions.iter().enumerate() {
            by_name
                .entry(definition.name.as_str())
                .or_default()
                .push(index);
        }
        Self {
            units,
            definitions,
            by_name,
            strings,
            declarations,
            nodes: Vec::new(),
            active: Vec::new(),
            context: Vec::new(),
        }
    }

    /// The definition that a call of `qualifier::name` from `unit` with `arity` arguments
    /// reaches. With a qualifier, it is a definition in that class or namespace. Without one,
    /// it prefers the class `class` of the caller. Then it prefers the unit of the caller and
    /// the exact arity.
    fn find_from(
        &self,
        unit: usize,
        qualifier: Option<&str>,
        class: Option<&str>,
        name: &str,
        arity: Option<usize>,
    ) -> Option<usize> {
        self.by_name
            .get(name)?
            .iter()
            .copied()
            .filter(|index| {
                let definition = &self.definitions[*index];
                // A definition that the reader is inside is an overload that calls another.
                !self.active.contains(index)
                    && arity.is_none_or(|arity| definition.params.len() >= arity)
                    && qualifier.is_none_or(|qualifier| definition.is_in(qualifier))
            })
            .min_by_key(|index| {
                let definition = &self.definitions[*index];
                let in_class = class.is_some_and(|class| definition.is_in(class));
                let exact = arity.is_some_and(|arity| definition.params.len() == arity);
                (!in_class, definition.unit != unit, !exact)
            })
    }

    fn find(
        &self,
        unit: usize,
        qualifier: Option<&str>,
        name: &str,
        arity: Option<usize>,
    ) -> Option<usize> {
        self.find_from(unit, qualifier, None, name, arity)
    }

    /// Reads the body of a definition with the variables of `scope`. `prefix` holds the
    /// branches of the call that reached it, relative to the binding's function.
    /// Returns the object or the template of the first `return name` whose `name` holds one.
    fn read(
        &mut self,
        definition: usize,
        mut scope: Scope,
        prefix: &[(usize, usize)],
    ) -> Option<usize> {
        if self.active.contains(&definition) || self.active.len() > 12 {
            return None;
        }
        self.active.push(definition);
        let found = &self.definitions[definition];
        let unit = found.unit;
        let class = found.class().map(str::to_owned);
        self.context.push((unit, class.clone()));
        let tokens = &self.units[unit].tokens[found.body.0 + 1..found.body.1];
        let base = self.units[unit].tokens[found.body.0].branches.len();
        let mut returned = None;
        for index in 0..tokens.len() {
            let mut place = prefix.to_vec();
            place.extend(tokens[index].branches.iter().skip(base));
            self.declaration(tokens, index, &mut scope);
            Self::to_local(tokens, index, &mut scope);
            self.setter(tokens, index, &scope, &place);
            self.call(unit, class.as_deref(), tokens, index, &scope, &place);
            if returned.is_none() && tokens[index].is("return") {
                returned = Self::target(&tokens[index + 1..=index + 1], &scope);
            }
        }
        self.context.pop();
        self.active.pop();
        returned
    }

    /// The template that the call `value` returns, such as `KeyObjectHandle::Initialize(env)`
    /// whose body ends with `return templ->GetFunction(...)`.
    fn returned_template(&mut self, value: &[Tok]) -> Option<usize> {
        let open = value.iter().position(|token| token.is("("))?;
        let name = value.get(open.checked_sub(1)?)?.ident()?;
        let qualifier = open
            .checked_sub(3)
            .filter(|&at| value[at + 1].is("::"))
            .and_then(|at| value[at].ident());
        let (args, _) = arguments(value, open)?;
        let (unit, class) = self.context.last().cloned()?;
        let definition = match qualifier {
            Some(qualifier) => self.find(unit, Some(qualifier), name, Some(args.len())),
            None => self.find_from(unit, None, class.as_deref(), name, Some(args.len())),
        }?;
        self.read(definition, Scope::new(), &[])
            .filter(|&node| self.nodes[node].template)
    }

    /// A variable that starts at `index`: `Local<T> name = value;`, `auto name = value;`, or
    /// `name = value;`.
    fn declaration(&mut self, tokens: &[Tok], index: usize, scope: &mut Scope) {
        let starts_statement = index == 0
            || [";", "{", "}"]
                .iter()
                .any(|word| tokens[index - 1].is(word));
        let mut declared = Vec::new();
        let mut position = index;
        if tokens[index].is("Local") && tokens.get(index + 1).is_some_and(|next| next.is("<")) {
            let Some(close) = matching_angle(tokens, index + 1) else {
                return;
            };
            declared.extend(
                tokens[index + 2..close]
                    .iter()
                    .filter_map(|token| token.ident().map(str::to_owned)),
            );
            position = close + 1;
        } else if tokens[index].is("auto") {
            position = index + 1;
        } else if !starts_statement {
            return;
        }
        let Some(name) = tokens.get(position).and_then(Tok::ident) else {
            return;
        };
        if !tokens.get(position + 1).is_some_and(|next| next.is("=")) {
            return;
        }
        let start = position + 2;
        let mut end = start;
        let mut depth = 0usize;
        while let Some(token) = tokens.get(end) {
            if token.is("(") || token.is("{") || token.is("[") {
                depth += 1;
            } else if token.is(")") || token.is("}") || token.is("]") {
                if depth == 0 {
                    break;
                }
                depth -= 1;
            } else if token.is(";") && depth == 0 {
                break;
            }
            end += 1;
        }
        match self.evaluate(&declared, &tokens[start..end], scope) {
            Some(value) => {
                scope.insert(name.to_owned(), value);
            }
            None => {
                scope.remove(name);
            }
        }
    }

    /// `t->GetFunction(context).ToLocal(&name)` at `index`: `name` holds the function of the
    /// template `t`.
    fn to_local(tokens: &[Tok], index: usize, scope: &mut Scope) {
        let Some(Value::Node(node)) = tokens[index].ident().and_then(|name| scope.get(name)) else {
            return;
        };
        let node = *node;
        let is = |at: usize, word: &str| tokens.get(at).is_some_and(|token| token.is(word));
        if !(is(index + 1, "->") && is(index + 2, "GetFunction") && is(index + 3, "(")) {
            return;
        }
        let Some(close) = matching(tokens, index + 3) else {
            return;
        };
        let local = close + 1;
        if !(is(local, ".") && is(local + 1, "ToLocal") && is(local + 2, "(") && is(local + 3, "&"))
        {
            return;
        }
        if let Some(name) = tokens.get(local + 4).and_then(Tok::ident) {
            scope.insert(name.to_owned(), Value::Node(node));
        }
    }

    fn evaluate(&mut self, declared: &[String], init: &[Tok], scope: &Scope) -> Option<Value> {
        if let [single] = init
            && let Some(value) = single.ident().and_then(|name| scope.get(name))
        {
            return Some(value.clone());
        }
        let starts = |words: &[&str]| {
            init.len() >= words.len() && words.iter().zip(init).all(|(word, token)| token.is(word))
        };
        if starts(&["Object", "::", "New"]) || starts(&["ObjectTemplate", "::", "New"]) {
            return Some(Value::Node(self.node(false)));
        }
        // `Local<Function> fn = t->GetFunction(context).ToLocalChecked();`
        if init.iter().any(|token| token.is("GetFunction"))
            && let Some(Value::Node(node)) = init
                .first()
                .and_then(Tok::ident)
                .and_then(|name| scope.get(name))
        {
            return Some(Value::Node(*node));
        }
        let template = declared.iter().any(|kind| kind == "FunctionTemplate")
            || starts(&["NewFunctionTemplate"])
            || starts(&["FunctionTemplate", "::", "New"]);
        if template {
            return Some(Value::Node(self.node(true)));
        }
        self.name(init, scope).map(Value::Text)
    }

    fn node(&mut self, template: bool) -> usize {
        self.nodes.push(Node {
            template,
            ..Node::default()
        });
        self.nodes.len() - 1
    }

    /// The object or the template that an argument names.
    fn target(tokens: &[Tok], scope: &Scope) -> Option<usize> {
        let tokens = match tokens.first() {
            Some(first) if first.is("&") || first.is("*") => &tokens[1..],
            _ => tokens,
        };
        let words: Vec<String> = tokens.iter().map(Tok::text).collect();
        let key = match words
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>()
            .as_slice()
        {
            [name] | [name, ".", "As", ..] => (*name).to_owned(),
            ["object", "(", ")"] | ["this", "->", "object", "(", ")"] => "object()".to_owned(),
            _ => return None,
        };
        match scope.get(&key) {
            Some(Value::Node(node)) => Some(*node),
            _ => None,
        }
    }

    /// The property name that an argument gives.
    fn name(&self, tokens: &[Tok], scope: &Scope) -> Option<String> {
        if let [single] = tokens {
            return match &single.token {
                Token::Str(text) => Some(text.clone()),
                Token::Ident(name) => match scope.get(name) {
                    Some(Value::Text(text)) => Some(text.clone()),
                    _ => None,
                },
                _ => None,
            };
        }
        // `Traits::JobName`, where a template parameter stands for `Traits`.
        if let [parameter, colons, constant] = tokens
            && colons.is("::")
            && let (Some(Value::Type(class)), Some(constant)) = (
                parameter.ident().and_then(|name| scope.get(name)),
                constant.ident(),
            )
        {
            return self
                .declarations
                .constants
                .get(&(class.clone(), constant.to_owned()))
                .cloned();
        }
        let converts = tokens.iter().any(|token| {
            token
                .ident()
                .is_some_and(|name| NAME_FUNCTIONS.contains(&name))
        });
        if converts {
            return tokens.iter().find_map(|token| match &token.token {
                Token::Str(text) => Some(text.clone()),
                _ => None,
            });
        }
        // `env->name_string()`, and the description of `env->name_symbol()`.
        tokens.windows(3).find_map(|window| match window {
            [name, open, close] if open.is("(") && close.is(")") => {
                let name = name.ident()?;
                let described = tokens.iter().any(|token| token.is("Description"));
                if name.ends_with("_string") || described {
                    self.strings.get(name).cloned()
                } else {
                    None
                }
            }
            _ => None,
        })
    }

    fn add(
        &mut self,
        node: usize,
        name: String,
        kind: Kind,
        place: &[(usize, usize)],
        child: Option<usize>,
    ) {
        let slot = self.nodes[node].members.entry(name).or_insert(Slot {
            kind,
            places: Vec::new(),
            node: child,
        });
        slot.kind = slot.kind.max(kind);
        slot.places.push(place.to_vec());
        if slot.node.is_none() {
            slot.node = child;
        }
    }

    /// A call that sets a member at `index`: the `Set*Method` helpers of util.h,
    /// `SetConstructorFunction`, `object->Set(...)` and its kin, and the constant macros.
    fn setter(&mut self, tokens: &[Tok], index: usize, scope: &Scope, place: &[(usize, usize)]) {
        let Some(word) = tokens[index].ident() else {
            return;
        };
        let open = index + 1;
        if !tokens.get(open).is_some_and(|next| next.is("(")) {
            self.property(tokens, index, scope, place);
            return;
        }
        let Some((args, _)) = arguments(tokens, open) else {
            return;
        };
        let member_call = index > 0 && (tokens[index - 1].is("->") || tokens[index - 1].is("."));
        let shift = usize::from(!member_call);
        let object = args.get(shift).and_then(|arg| Self::target(arg, scope));
        let named = args.get(shift + 1).and_then(|arg| self.name(arg, scope));
        match word {
            "SetMethod"
            | "SetMethodNoSideEffect"
            | "SetFastMethod"
            | "SetFastMethodNoSideEffect" => {
                if let (Some(node), Some(name)) = (object, named) {
                    self.add(node, name, Kind::Function, place, None);
                }
            }
            "SetProtoMethod"
            | "SetProtoMethodNoSideEffect"
            | "SetFastProtoMethod"
            | "SetFastProtoMethodNoSideEffect" => {
                if let (Some(node), Some(name)) = (object, named) {
                    self.nodes[node].prototype.insert(name);
                }
            }
            "SetConstructorFunction" => {
                let class = args.get(shift + 2).and_then(|template| {
                    Self::target(template, scope).or_else(|| self.returned_template(template))
                });
                if let (Some(node), Some(name)) = (object, named) {
                    self.add(node, name, Kind::Class, place, class);
                }
            }
            "NODE_DEFINE_CONSTANT" | "NODE_DEFINE_HIDDEN_CONSTANT" => {
                let (Some(object), Some(name)) = (args.first(), args.get(1)) else {
                    return;
                };
                let name = name.iter().map(Tok::text).collect::<String>();
                if let Some(node) = Self::target(object, scope) {
                    self.add(node, name, Kind::Value, place, None);
                }
            }
            "NODE_DEFINE_STRING_CONSTANT"
            | "READONLY_PROPERTY"
            | "READONLY_DONT_ENUM_PROPERTY"
            | "READONLY_FALSE_PROPERTY"
            | "READONLY_TRUE_PROPERTY"
            | "READONLY_STRING_PROPERTY" => {
                let (Some(object), Some(name)) = (args.first(), args.get(1)) else {
                    return;
                };
                let value = args.get(2).copied().unwrap_or_default();
                let (kind, child) = self.classify(value, scope);
                if let (Some(node), Some(name)) =
                    (Self::target(object, scope), self.name(name, scope))
                {
                    self.add(node, name, kind, place, child);
                }
            }
            _ => {}
        }
    }

    /// `object->Set(context, name, value)` and its kin at `index`, also written
    /// `(object)->Set(...)`, and `template->PrototypeTemplate()->Set(...)`.
    fn property(&mut self, tokens: &[Tok], index: usize, scope: &Scope, place: &[(usize, usize)]) {
        let Some(Value::Node(node)) = tokens[index].ident().and_then(|name| scope.get(name)) else {
            return;
        };
        let node = *node;
        let mut position = index + 1;
        if index > 0
            && tokens[index - 1].is("(")
            && tokens.get(position).is_some_and(|token| token.is(")"))
        {
            position += 1;
        }
        let chain = |position: usize, word: &str| {
            tokens.get(position).is_some_and(|token| token.is("->"))
                && tokens.get(position + 1).is_some_and(|token| token.is(word))
                && tokens.get(position + 2).is_some_and(|token| token.is("("))
                && tokens.get(position + 3).is_some_and(|token| token.is(")"))
        };
        let prototype = chain(position, "PrototypeTemplate");
        if prototype {
            position += 4;
        } else if chain(position, "InstanceTemplate") {
            return;
        }
        if !tokens.get(position).is_some_and(|token| token.is("->")) {
            return;
        }
        let Some(method) = tokens.get(position + 1).and_then(Tok::ident) else {
            return;
        };
        let accessor = matches!(
            method,
            "SetLazyDataProperty"
                | "SetNativeDataProperty"
                | "SetAccessor"
                | "SetAccessorProperty"
                | "SetIntrinsicDataProperty"
        );
        if !accessor && !matches!(method, "Set" | "DefineOwnProperty" | "CreateDataProperty") {
            return;
        }
        let Some((args, _)) = arguments(tokens, position + 2) else {
            return;
        };
        let Some((at, name)) = args
            .iter()
            .enumerate()
            .find_map(|(at, arg)| self.name(arg, scope).map(|name| (at, name)))
        else {
            return;
        };
        let (kind, child) = if accessor {
            (Kind::Value, None)
        } else {
            self.classify(args.get(at + 1).copied().unwrap_or_default(), scope)
        };
        match (prototype, kind) {
            (true, Kind::Function) => {
                self.nodes[node].prototype.insert(name);
            }
            (true, _) => {
                self.nodes[node].accessors.insert(name);
            }
            (false, _) => self.add(node, name, kind, place, child),
        }
    }

    /// The kind of a member from the expression of its value.
    fn classify(&mut self, value: &[Tok], scope: &Scope) -> (Kind, Option<usize>) {
        let first = value
            .first()
            .and_then(Tok::ident)
            .and_then(|name| match scope.get(name) {
                Some(Value::Node(node)) => Some(*node),
                _ => None,
            });
        if value.iter().any(|token| token.is("GetFunction")) {
            return match first {
                Some(node) if self.nodes[node].template => (Kind::Class, Some(node)),
                _ => (Kind::Function, None),
            };
        }
        match first {
            Some(node) if value.len() == 1 || value.get(1).is_some_and(|next| next.is("->")) => {
                if self.nodes[node].template {
                    (Kind::Class, Some(node))
                } else {
                    (Kind::Object, Some(node))
                }
            }
            Some(_) => (Kind::Value, None),
            None => match self.returned_template(value) {
                Some(node) => (Kind::Class, Some(node)),
                None => (Kind::Value, None),
            },
        }
    }

    /// The class that a call names before `::`, at `before`, the index of `::`: `X`,
    /// `X<Arguments>`, or an alias of a template class. Returns the class and, for a template,
    /// what each of its parameters stands for.
    fn qualifier(&self, tokens: &[Tok], before: usize, scope: &Scope) -> Option<(String, Scope)> {
        let resolve = |name: &String| match scope.get(name) {
            Some(Value::Type(bound)) => bound.clone(),
            _ => name.clone(),
        };
        let (class, arguments) = if tokens.get(before.checked_sub(1)?)?.is(">") {
            let close = before - 1;
            let open = (0..close)
                .rev()
                .find(|&at| matching_angle(tokens, at).is_some_and(|found| found == close))?;
            let class = tokens.get(open.checked_sub(1)?)?.ident()?.to_owned();
            (class, type_arguments(&tokens[open + 1..close]))
        } else {
            let name = tokens.get(before.checked_sub(1)?)?.ident()?.to_owned();
            match self.declarations.aliases.get(&name) {
                Some((template, arguments)) => (template.clone(), arguments.clone()),
                None => (name, Vec::new()),
            }
        };
        let bound = self
            .declarations
            .templates
            .get(&class)
            .map(|params| {
                params
                    .iter()
                    .zip(&arguments)
                    .map(|(param, argument)| (param.clone(), Value::Type(resolve(argument))))
                    .collect()
            })
            .unwrap_or_default();
        Some((class, bound))
    }

    /// A call at `index` that passes a followed object or template: the reader follows it
    /// into the definition, with each string argument as well. `realm->AddBindingData<T>(object)`
    /// reaches the constructor of `T`, whose `object()` is that object.
    fn call(
        &mut self,
        unit: usize,
        class: Option<&str>,
        tokens: &[Tok],
        index: usize,
        scope: &Scope,
        place: &[(usize, usize)],
    ) {
        let Some(name) = tokens[index].ident() else {
            return;
        };
        if KEYWORDS.contains(&name) || PRIMITIVES.contains(&name) {
            return;
        }
        let mut open = index + 1;
        let mut template = None;
        if tokens.get(open).is_some_and(|next| next.is("<")) {
            let Some(close) = matching_angle(tokens, open) else {
                return;
            };
            template = tokens.get(open + 1).and_then(Tok::ident).map(str::to_owned);
            open = close + 1;
        }
        if !tokens.get(open).is_some_and(|next| next.is("(")) {
            return;
        }
        let member_call = index > 0 && (tokens[index - 1].is("->") || tokens[index - 1].is("."));
        let constructor = name == "AddBindingData";
        if member_call && !constructor {
            return;
        }
        let Some((args, _)) = arguments(tokens, open) else {
            return;
        };
        let passed: Vec<Option<Value>> = args
            .iter()
            .map(|arg| {
                Self::target(arg, scope)
                    .map(Value::Node)
                    .or_else(|| match arg {
                        [
                            Tok {
                                token: Token::Str(text),
                                ..
                            },
                        ] => Some(Value::Text(text.clone())),
                        _ => None,
                    })
            })
            .collect();
        if !passed
            .iter()
            .any(|value| matches!(value, Some(Value::Node(_))))
        {
            return;
        }
        let mut callee = Scope::new();
        let (definition, shift) = if constructor {
            let Some(template) = template else {
                return;
            };
            let Some(found) = self.find(unit, Some(&template), &template, Some(args.len() + 1))
            else {
                return;
            };
            (found, 1)
        } else {
            let qualified = index >= 1 && tokens[index - 1].is("::");
            let resolved = if qualified {
                self.qualifier(tokens, index - 1, scope)
            } else {
                None
            };
            let found = match &resolved {
                Some((class_name, bound)) => {
                    callee.extend(bound.clone());
                    self.find(unit, Some(class_name), name, Some(args.len()))
                }
                None if qualified => None,
                None => self.find_from(unit, None, class, name, Some(args.len())),
            };
            let Some(found) = found else {
                return;
            };
            (found, 0)
        };
        // A method of a class template sees the bindings of its parameters in the caller.
        for (key, value) in scope {
            if matches!(value, Value::Type(_)) {
                callee.entry(key.clone()).or_insert_with(|| value.clone());
            }
        }
        let params = &self.definitions[definition].params;
        for (position, value) in passed.into_iter().enumerate() {
            let (Some(value), Some(param)) = (value, params.get(position + shift)) else {
                continue;
            };
            if constructor && position == 0 {
                callee.insert("object()".to_owned(), value.clone());
            }
            callee.insert(param.name.clone(), value);
        }
        let _ = self.read(definition, callee, place);
    }

    /// The members of a node for the manifest.
    fn members(&self, node: usize, groups: &[Group], level: usize) -> BTreeMap<String, Member> {
        self.nodes[node]
            .members
            .iter()
            .map(|(name, slot)| {
                let child = slot.node.filter(|_| level < 4);
                let places: Vec<&[(usize, usize)]> =
                    slot.places.iter().map(Vec::as_slice).collect();
                let member = Member {
                    kind: slot.kind,
                    conditional: !always(&places, groups),
                    prototype: child
                        .map(|child| self.nodes[child].prototype.clone())
                        .unwrap_or_default(),
                    accessors: child
                        .map(|child| self.nodes[child].accessors.clone())
                        .unwrap_or_default(),
                    members: child
                        .map(|child| self.members(child, groups, level + 1))
                        .unwrap_or_default(),
                };
                (name.clone(), member)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(name: &str, files: &[(&str, &str)]) -> Manifest {
        let directory =
            std::env::temp_dir().join(format!("buoy-node-bindings-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        for (path, text) in files {
            crate::write(&directory.join("src").join(path), text).expect("write");
        }
        let manifest = read_sources(&directory).expect("read");
        let _ = fs::remove_dir_all(&directory);
        manifest
    }

    #[test]
    fn members_come_from_the_setters_macros_and_helpers() {
        let manifest = read(
            "setters",
            &[
                (
                    "env_properties.h",
                    "#define PER_ISOLATE_STRING_PROPERTIES(V) V(constants_string, \"constants\")\n",
                ),
                (
                    "node_binding.cc",
                    "#if HAVE_OPENSSL\n#define NODE_BUILTIN_OPENSSL_BINDINGS(V) V(demo)\n#endif\n",
                ),
                (
                    "demo.cc",
                    r#"
#define LIST(V) V(Alpha) V(Beta)
namespace node {
static void Helper(Environment* env, Local<Object> obj) {
  SetMethod(env->context(), obj, "fromHelper", Fn);
}
template <typename T>
struct MakeClass {
  static void Make(Environment* env, Local<Object> target, const char* name) {
    Local<FunctionTemplate> z = NewFunctionTemplate(isolate, T::New);
    SetConstructorFunction(env->context(), target, name, z);
  }
};
void Initialize(Local<Object> target, Local<Value> unused, Local<Context> context, void* priv) {
  Environment* env = Environment::GetCurrent(context);
  SetMethod(context, target, "open", Open);  // a comment
#define V(name) SetMethod(context, target, "is" #name, Is##name);
  LIST(V)
#undef V
#ifdef __linux__
  SetMethod(context, target, "linuxOnly", LinuxOnly);
#endif
#if DEBUG
  READONLY_TRUE_PROPERTY(target, "isDebugBuild");
#else
  READONLY_FALSE_PROPERTY(target, "isDebugBuild");
#endif
  Local<FunctionTemplate> t = NewFunctionTemplate(isolate, New);
  SetProtoMethod(isolate, t, "close", Close);
  SetConstructorFunction(context, target, "Handle", t);
  Local<Object> constants = Object::New(isolate);
  NODE_DEFINE_CONSTANT(constants, O_RDONLY);
  target->Set(context, env->constants_string(), constants).Check();
  (target)->DefineOwnProperty(context, FIXED_ONE_BYTE_STRING(isolate, "isBigEndian"), True(isolate)).Check();
  Helper(env, target);
  MakeClass<Stream>::Make(env, target, "Zlib");
}
}
NODE_BINDING_CONTEXT_AWARE_INTERNAL(demo, node::Initialize)
"#,
                ),
            ],
        );
        let demo = &manifest.bindings["demo"];
        assert_eq!(demo.condition.as_deref(), Some("HAVE_OPENSSL"));
        let kinds: Vec<(&str, Kind, bool)> = demo
            .members
            .iter()
            .map(|(name, member)| (name.as_str(), member.kind, member.conditional))
            .collect();
        assert_eq!(
            kinds,
            [
                ("Handle", Kind::Class, false),
                ("Zlib", Kind::Class, false),
                ("constants", Kind::Object, false),
                ("fromHelper", Kind::Function, false),
                ("isAlpha", Kind::Function, false),
                ("isBeta", Kind::Function, false),
                ("isBigEndian", Kind::Value, false),
                ("isDebugBuild", Kind::Value, false),
                ("linuxOnly", Kind::Function, true),
                ("open", Kind::Function, false),
            ]
        );
        assert_eq!(
            demo.members["Handle"].prototype,
            BTreeSet::from(["close".to_owned()])
        );
        assert!(demo.members["constants"].members.contains_key("O_RDONLY"));
        let erlang = erlang(&manifest);
        assert!(
            erlang.contains("{<<\"Handle\">>, {class, [<<\"close\">>]}}"),
            "{erlang}"
        );
        assert!(!erlang.contains("linuxOnly"), "{erlang}");
    }

    #[test]
    fn template_parameters_name_the_classes_of_their_traits() {
        let manifest = read(
            "traits",
            &[(
                "jobs.cc",
                r#"
namespace node {
template <typename Traits>
class Job {
 public:
  static void Initialize(Environment* env, Local<Object> target) {
    Local<FunctionTemplate> job = NewFunctionTemplate(isolate, New);
    SetConstructorFunction(context, target, Traits::JobName, job);
  }
};
struct HashTraits final {
  static constexpr const char* JobName = "HashJob";
};
using HashJob = Job<HashTraits>;
void Initialize(Local<Object> target, Local<Value> unused, Local<Context> context, void* priv) {
  HashJob::Initialize(env, target);
}
}
NODE_BINDING_CONTEXT_AWARE_INTERNAL(jobs, node::Initialize)
"#,
            )],
        );
        let members: Vec<&String> = manifest.bindings["jobs"].members.keys().collect();
        assert_eq!(members, ["HashJob"]);
    }

    #[test]
    fn the_templates_that_calls_return_are_classes() {
        let manifest = read(
            "returned",
            &[(
                "returned.cc",
                r#"
namespace node {
void AddMethods(Environment* env, Local<FunctionTemplate> t) {
  AddMethods(env->isolate_data(), t);
}
void AddMethods(IsolateData* data, Local<FunctionTemplate> t) {
  SetProtoMethod(isolate, t, "readStart", ReadStart);
}
Local<FunctionTemplate> Lock::GetConstructorTemplate(Environment* env) {
  Local<FunctionTemplate> tmpl = NewFunctionTemplate(isolate, NewLock);
  SetProtoMethod(isolate, tmpl, "release", Release);
  AddMethods(env, tmpl);
  return tmpl;
}
Local<Function> MakeKey(Environment* env) {
  auto templ = env->key_constructor();
  if (templ.IsEmpty()) {
    templ = NewFunctionTemplate(isolate, NewKey);
    SetProtoMethod(isolate, templ, "export", Export);
  }
  return templ->GetFunction(env->context()).ToLocalChecked();
}
void Initialize(Local<Object> target, Local<Value> unused, Local<Context> context, void* priv) {
  target->Set(context, FIXED_ONE_BYTE_STRING(isolate, "Key"), MakeKey(env)).Check();
  SetConstructorFunction(context, target, "Lock", Lock::GetConstructorTemplate(env));
  Local<FunctionTemplate> s = NewFunctionTemplate(isolate, NewSocket);
  Local<Function> fn = s->GetFunction(context).ToLocalChecked();
  target->Set(context, FIXED_ONE_BYTE_STRING(isolate, "Socket"), fn).Check();
  Local<FunctionTemplate> w = NewFunctionTemplate(isolate, NewWindow);
  SetProtoMethod(isolate, w, "resize", Resize);
  Local<Value> func;
  if (w->GetFunction(context).ToLocal(&func) &&
      target->Set(context, FIXED_ONE_BYTE_STRING(isolate, "Window"), func).IsJust()) {
  }
}
}
NODE_BINDING_CONTEXT_AWARE_INTERNAL(returned, node::Initialize)
"#,
            )],
        );
        let classes: Vec<(&str, Kind, Vec<&str>)> = manifest.bindings["returned"]
            .members
            .iter()
            .map(|(name, member)| {
                let methods = member.prototype.iter().map(String::as_str).collect();
                (name.as_str(), member.kind, methods)
            })
            .collect();
        assert_eq!(
            classes,
            [
                ("Key", Kind::Class, vec!["export"]),
                ("Lock", Kind::Class, vec!["readStart", "release"]),
                ("Socket", Kind::Class, vec![]),
                ("Window", Kind::Class, vec!["resize"]),
            ]
        );
    }

    #[test]
    fn a_qualified_registration_reaches_the_function_of_its_namespace() {
        let manifest = read(
            "namespaces",
            &[(
                "nested.cc",
                r#"
namespace node::worker::nested {
void BindingData::Init(IsolateData* data, Local<ObjectTemplate> target) {
  SetMethod(isolate, target, "fromClass", F);
}
static void Init(IsolateData* data, Local<ObjectTemplate> target) {
  SetMethod(isolate, target, "fromNamespace", G);
  BindingData::Init(data, target);
}
}
NODE_BINDING_PER_ISOLATE_INIT(nested, node::worker::nested::Init)
"#,
            )],
        );
        let members: Vec<&String> = manifest.bindings["nested"].members.keys().collect();
        assert_eq!(members, ["fromClass", "fromNamespace"]);
    }

    #[test]
    fn the_committed_erlang_module_matches_the_manifest() {
        let root = crate::repository();
        let manifest = load(&root).expect("the manifest loads");
        let committed = fs::read_to_string(root.join(ERLANG)).expect("the module exists");
        assert!(
            committed == erlang(&manifest),
            "{ERLANG} differs from {MANIFEST}; run `{COMMAND}`"
        );
    }

    #[test]
    fn coverage_skips_the_names_of_stubs() {
        let module = r#"binding() -> buoy_node:object([{<<"open">>, fn(<<"open">>, 1, F)}]
            ++ buoy_node:stubs(<<"demo">>, [<<"close">>, <<"read">>])
            ++ [{<<"Handle">>, buoy_node:missing_constructor(<<"demo">>, <<"Handle">>, 0)}])."#;
        let names = erlang_binaries(module);
        let stubs = erlang_stubs(module);
        assert!(names.contains("open") && names.contains("close"));
        assert_eq!(
            stubs,
            BTreeSet::from(["Handle".to_owned(), "close".to_owned(), "read".to_owned()])
        );
    }
}
