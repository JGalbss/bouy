//! `buoy` invoked as `node`: `buoy [node options] <script> [args...]`, `buoy -e <code>`,
//! `buoy -p <code>`, and the REPL. The program runs on the reference engine, and the node
//! options reach the VM as `process.execArgv`.

use std::env;
use std::ffi::OsString;
use std::fmt::Write as _;
use std::io::{IsTerminal as _, Read as _};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use buoy_compiler::{Code, Diagnostic, Semantics};

/// The node options of an invocation, which the VM reads with `-buoy_exec_argv`, whether
/// the entry is the code of `-e` or `-p`, which has no script in `process.argv`, and
/// whether the VM starts the REPL.
#[derive(Debug, Default)]
pub struct Options {
    exec_argv: Vec<String>,
    pub eval: bool,
    pub repl: bool,
}

impl Options {
    /// `process.execArgv` as a JSON array of strings.
    pub fn exec_argv_json(&self) -> String {
        let items: Vec<String> = self
            .exec_argv
            .iter()
            .map(|item| json_string(item))
            .collect();
        format!("[{}]", items.join(","))
    }
}

/// The node options that take their value as the next argument: the options of
/// `getCLIOptionsInfo()` of node v25.9.0 whose type is a number, a string, a host and
/// port, or a list, and their aliases.
const VALUE_OPTIONS: [&str; 76] = [
    "--allow-fs-read",
    "--allow-fs-write",
    "--build-sea",
    "--build-snapshot-config",
    "-C",
    "--conditions",
    "--cpu-prof-dir",
    "--cpu-prof-interval",
    "--cpu-prof-name",
    "--debug-port",
    "--diagnostic-dir",
    "--disable-proto",
    "--disable-warning",
    "--dns-result-order",
    "--env-file",
    "--env-file-if-exists",
    "--experimental-config-file",
    "--experimental-loader",
    "--experimental-sea-config",
    "--experimental-test-isolation",
    "--heap-prof-dir",
    "--heap-prof-interval",
    "--heap-prof-name",
    "--heapsnapshot-near-heap-limit",
    "--heapsnapshot-signal",
    "--icu-data-dir",
    "--import",
    "--input-type",
    "--inspect-port",
    "--inspect-publish-uid",
    "--loader",
    "--localstorage-file",
    "--max-http-header-size",
    "--max-old-space-size-percentage",
    "--network-family-autoselection-attempt-timeout",
    "--openssl-config",
    "-r",
    "--redirect-warnings",
    "--report-dir",
    "--report-directory",
    "--report-filename",
    "--report-signal",
    "--require",
    "--run",
    "--secure-heap",
    "--secure-heap-min",
    "--security-revert",
    "--security-reverts",
    "--snapshot-blob",
    "--stack-trace-limit",
    "--test-concurrency",
    "--test-coverage-branches",
    "--test-coverage-exclude",
    "--test-coverage-functions",
    "--test-coverage-include",
    "--test-coverage-lines",
    "--test-global-setup",
    "--test-isolation",
    "--test-name-pattern",
    "--test-reporter",
    "--test-reporter-destination",
    "--test-rerun-failures",
    "--test-shard",
    "--test-skip-pattern",
    "--test-timeout",
    "--title",
    "--tls-cipher-list",
    "--tls-keylog",
    "--trace-event-categories",
    "--trace-event-file-pattern",
    "--trace-require-module",
    "--unhandled-rejections",
    "--use-largepages",
    "--v8-pool-size",
    "--watch-kill-signal",
    "--watch-path",
];

/// The options whose value must be one of a list, with the error of
/// `EnvironmentOptions::CheckOptions` in node v25.9.0 for another value. An empty value
/// passes, as Node checks only a value that is set.
const CHOICE_OPTIONS: [(&str, &[&str], &str); 1] = [(
    "--unhandled-rejections",
    &["warn-with-error-code", "throw", "strict", "warn", "none"],
    "invalid value for --unhandled-rejections",
)];

/// The version of Node that `-v` prints, the release that the tests freeze their output at.
const NODE_VERSION: &str = include_str!("../../../.node-version");

/// `ExitCode::kInvalidCommandLineArgument` of Node.
const INVALID_COMMAND_LINE_ARGUMENT: u8 = 9;

/// The options of `exec_argv` as names and values, with `_` read as `-` in a name, as
/// Node reads it. A value option without `=` takes the next item as its value.
fn parse_options(exec_argv: &[String]) -> Vec<(String, Option<&str>)> {
    let mut items = exec_argv.iter();
    let mut options = Vec::new();
    while let Some(item) = items.next() {
        let (name, inline) = item
            .split_once('=')
            .map_or((item.as_str(), None), |(name, value)| (name, Some(value)));
        let name = name.replace('_', "-");
        let value = inline.or_else(|| {
            VALUE_OPTIONS
                .contains(&name.as_str())
                .then(|| items.next().map(String::as_str))
                .flatten()
        });
        options.push((name, value));
    }
    options
}

/// The errors of `PerProcessOptions::CheckOptions` and then of
/// `EnvironmentOptions::CheckOptions` in node v25.9.0 for `exec_argv`. Node prints each
/// one before any JavaScript runs.
fn invalid_options(exec_argv: &[String]) -> Vec<&'static str> {
    let options = parse_options(exec_argv);
    let value = |option: &str| {
        options
            .iter()
            .rev()
            .find(|(name, _)| name == option)
            .and_then(|(_, value)| *value)
    };
    // The last of `--flag` and `--no-flag` wins.
    let is_set = |flag: &str| {
        options
            .iter()
            .rev()
            .find_map(|(name, _)| match name.strip_prefix("--no-") {
                Some(negated) if flag.strip_prefix("--") == Some(negated) => Some(false),
                _ => (name == flag).then_some(true),
            })
            .unwrap_or(false)
    };
    let number = |option: &str| value(option).and_then(|text| text.parse::<i64>().ok());
    let mut errors = Vec::new();
    if is_set("--use-openssl-ca") && is_set("--use-bundled-ca") {
        errors.push("either --use-openssl-ca or --use-bundled-ca can be used, not both");
    }
    if is_set("--use-openssl-ca") && is_set("--use-system-ca") {
        errors.push("either --use-openssl-ca or --use-system-ca can be used, not both");
    }
    // A secure heap below 2 bytes is off.
    let heap = number("--secure-heap").unwrap_or(0);
    if heap >= 2 {
        if heap & (heap - 1) != 0 {
            errors.push("--secure-heap must be a power of 2");
        }
        let min = number("--secure-heap-min")
            .unwrap_or(2)
            .min(heap)
            .min(i64::from(i32::MAX))
            .max(2);
        if min & (min - 1) != 0 {
            errors.push("--secure-heap-min must be a power of 2");
        }
    }
    for (option, choices, error) in CHOICE_OPTIONS {
        if let Some(value) = value(option)
            && !value.is_empty()
            && !choices.contains(&value)
        {
            errors.push(error);
        }
    }
    errors
}

enum Entry {
    Script(String),
    Eval(String),
    Print(String),
    /// `node --test [patterns]`: the arguments are the patterns of the test files.
    TestRunner,
}

/// Runs the invocation whose arguments, after the binary, are `arguments`.
pub fn run(arguments: &[OsString]) -> ExitCode {
    let mut options = Options::default();
    let mut entry = None;
    let mut print_version = false;
    let mut force_repl = false;
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].to_string_lossy().into_owned();
        index += 1;
        match argument.as_str() {
            "--" => break,
            "-e" | "--eval" | "-p" | "--print" | "-pe" | "-ep" => {
                let code = arguments
                    .get(index)
                    .map_or_else(String::new, |code| code.to_string_lossy().into_owned());
                index += 1;
                options.exec_argv.extend([argument.clone(), code.clone()]);
                entry = Some(if argument == "-e" || argument == "--eval" {
                    Entry::Eval(code)
                } else {
                    Entry::Print(code)
                });
                break;
            }
            _ if argument.starts_with("--eval=") || argument.starts_with("--print=") => {
                let (name, code) = argument.split_once('=').unwrap_or((&argument, ""));
                options.exec_argv.push(argument.clone());
                entry = Some(if name == "--eval" {
                    Entry::Eval(code.to_owned())
                } else {
                    Entry::Print(code.to_owned())
                });
                break;
            }
            _ if argument.starts_with('-') && argument.len() > 1 => {
                print_version |= argument == "-v" || argument == "--version";
                force_repl |= argument == "-i" || argument == "--interactive";
                options.exec_argv.push(argument.clone());
                if VALUE_OPTIONS.contains(&argument.as_str())
                    && let Some(value) = arguments.get(index)
                {
                    options.exec_argv.push(value.to_string_lossy().into_owned());
                    index += 1;
                }
            }
            _ if is_test_runner(&options.exec_argv) => {
                index -= 1;
                break;
            }
            _ => {
                entry = Some(Entry::Script(argument));
                break;
            }
        }
    }
    if entry.is_none() && is_test_runner(&options.exec_argv) {
        entry = Some(Entry::TestRunner);
    }
    let errors = invalid_options(&options.exec_argv);
    if !errors.is_empty() {
        let program = env::args_os().next().map_or_else(
            || "buoy".to_owned(),
            |name| name.to_string_lossy().into_owned(),
        );
        for error in errors {
            eprintln!("{program}: {error}");
        }
        return ExitCode::from(INVALID_COMMAND_LINE_ARGUMENT);
    }
    if print_version {
        println!("v{}", NODE_VERSION.trim());
        return ExitCode::SUCCESS;
    }
    buoy_compiler::set_user_conditions(user_conditions(&options.exec_argv));
    let program_arguments = &arguments[index.min(arguments.len())..];
    // node.cc: -i starts the REPL even with -e, and so does a terminal on stdin when no
    // script is named. The REPL evaluates the code of -e first.
    let terminal = std::io::stdin().is_terminal();
    match entry {
        Some(Entry::Eval(_) | Entry::Print(_)) if force_repl => {
            run_repl(program_arguments, options)
        }
        Some(Entry::Script(script)) if script == "-" && (force_repl || terminal) => {
            run_repl(program_arguments, options)
        }
        Some(Entry::Script(script)) if script == "-" => {
            // `node - a b` keeps `-` as process.argv[1].
            let arguments: Vec<OsString> = std::iter::once(OsString::from("-"))
                .chain(program_arguments.iter().cloned())
                .collect();
            run_stdin(&arguments, options)
        }
        Some(Entry::Script(script)) => {
            let Some(entry) = buoy_compiler::resolve_main(Path::new(&script)) else {
                return module_not_found(&script);
            };
            let entry = entry.as_path();
            let place = entry.canonicalize().unwrap_or_else(|_| entry.to_path_buf());
            let source = std::fs::read_to_string(entry).unwrap_or_default();
            let report = |diagnostics: &[Diagnostic]| {
                report(diagnostics, &source, &place.display().to_string())
            };
            let project = match super::compile_reporting(entry, Semantics::Reference, report) {
                Ok(project) => project,
                Err(code) => return code,
            };
            super::start_program(&project, entry, program_arguments, &options)
        }
        Some(Entry::Eval(code)) => {
            options.eval = true;
            let module = is_module(&code, &options.exec_argv);
            let code = if !module && uses_crypto(&code) {
                format!("(crypto=>{{{{{code}}}}})(require('node:crypto'))")
            } else {
                code
            };
            run_source(code, module, "[eval]", program_arguments, &options)
        }
        Some(Entry::Print(code)) => {
            options.eval = true;
            let code = if uses_crypto(&code) {
                format!("let crypto=require(\"node:crypto\");{{{code}}}")
            } else {
                code
            };
            // The completion value of the code, printed at exit as Node's evalScript does.
            let source = format!(
                "globalThis.require = require; globalThis.module = module; globalThis.exports = exports;\n\
                 globalThis.__filename = '[eval]'; globalThis.__dirname = '.';\n\
                 const result = (0, eval)({});\n\
                 process.on('exit', () => console.log(result));\n",
                json_string(&code)
            );
            run_source(source, false, "[eval]", program_arguments, &options)
        }
        Some(Entry::TestRunner) => {
            options.eval = true;
            // The test runner is the main script of the bootstrap (internal/main/buoy),
            // which the first read of `process` runs.
            run_source(
                "process;".to_owned(),
                false,
                "[eval]",
                program_arguments,
                &options,
            )
        }
        None if force_repl || terminal => run_repl(program_arguments, options),
        None => run_stdin(program_arguments, options),
    }
}

/// Whether the code names `crypto`, as `/\bcrypto\b/` finds it: eval_string.js then binds
/// the name to `node:crypto` in place of Web Crypto, for backward compatibility.
fn uses_crypto(code: &str) -> bool {
    let is_word = |byte: Option<&u8>| byte.is_some_and(|b| b.is_ascii_alphanumeric() || *b == b'_');
    let bytes = code.as_bytes();
    code.match_indices("crypto").any(|(start, word)| {
        let end = start + word.len();
        !is_word(start.checked_sub(1).and_then(|i| bytes.get(i))) && !is_word(bytes.get(end))
    })
}

/// The REPL: an empty program whose bootstrap runs `internal/main/repl` after
/// `internal/main/buoy`, as node.cc picks it for the main script.
fn run_repl(arguments: &[OsString], mut options: Options) -> ExitCode {
    options.eval = true;
    options.repl = true;
    run_source(String::new(), false, "[eval]", arguments, &options)
}

/// The values of `--conditions` and `-C`, in order.
fn user_conditions(exec_argv: &[String]) -> Vec<String> {
    let mut conditions = Vec::new();
    let mut items = exec_argv.iter();
    while let Some(item) = items.next() {
        let (name, inline) = match item.split_once('=') {
            Some((name, value)) => (name, Some(value.to_owned())),
            None => (item.as_str(), None),
        };
        if matches!(name, "--conditions" | "-C")
            && let Some(value) = inline.or_else(|| items.next().cloned())
        {
            conditions.push(value);
        }
    }
    conditions
}

/// Whether the node options select the test runner, as `--test` does.
fn is_test_runner(exec_argv: &[String]) -> bool {
    exec_argv.iter().any(|option| option == "--test")
}

/// `buoy -` and `buoy` with piped stdin: the script is the text of stdin.
fn run_stdin(arguments: &[OsString], mut options: Options) -> ExitCode {
    let mut code = String::new();
    if let Err(error) = std::io::stdin().read_to_string(&mut code) {
        return super::fail(&format!("buoy: cannot read the script from stdin: {error}"));
    }
    options.eval = true;
    let module = is_module(&code, &options.exec_argv);
    run_source(code, module, "[stdin]", arguments, &options)
}

/// Compiles the code as the module `[eval]` of the working directory, so it resolves its
/// imports from there, and starts it. `place` names the code in the report of a syntax error.
fn run_source(
    code: String,
    module: bool,
    place: &str,
    arguments: &[OsString],
    options: &Options,
) -> ExitCode {
    let directory = env::current_dir().unwrap_or_else(|_| Path::new(".").to_path_buf());
    let entry = directory.join(if module { "[eval].mjs" } else { "[eval].cjs" });
    match buoy_compiler::compile_source(&entry, code.clone()) {
        Ok(project) => super::start_program(&project, &entry, arguments, options),
        Err(diagnostics) => ExitCode::from(report(&diagnostics, &code, place)),
    }
}

/// The diagnostics of the entry. A syntax error prints as Node prints the `SyntaxError`
/// that V8 throws when the loader compiles the entry: the place and line, the source line,
/// a caret, the error, and the version, with status 1. Others print as buoy prints them.
fn report(diagnostics: &[Diagnostic], source: &str, place: &str) -> u8 {
    let Some(error) = diagnostics.iter().find(|d| d.code == Code::Syntax) else {
        return super::print_diagnostics(diagnostics);
    };
    let line = source
        .lines()
        .nth(error.line.saturating_sub(1))
        .unwrap_or_default();
    let caret = " ".repeat(error.column.saturating_sub(1));
    eprintln!(
        "{place}:{}\n{line}\n{caret}^\n\nSyntaxError: {}\n\nNode.js v{}",
        error.line,
        error.message,
        NODE_VERSION.trim()
    );
    1
}

/// Node's report of a main script that does not exist, which `Module._resolveFilename`
/// throws with the absolute path, and status 1.
fn module_not_found(script: &str) -> ExitCode {
    let path: PathBuf = env::current_dir()
        .map(|directory| directory.join(script))
        .unwrap_or_else(|_| PathBuf::from(script))
        .components()
        .filter(|component| !matches!(component, std::path::Component::CurDir))
        .collect();
    eprintln!(
        "node:internal/modules/cjs/loader:1478\n  throw err;\n  ^\n\nError: Cannot find module '{}'\n    at Module._resolveFilename (node:internal/modules/cjs/loader:1475:15) {{\n  code: 'MODULE_NOT_FOUND',\n  requireStack: []\n}}\n\nNode.js v{}",
        path.display(),
        NODE_VERSION.trim()
    );
    ExitCode::from(1)
}

/// Whether the code of `-e` or stdin is an ES module: `--input-type=module`, or, without
/// `--input-type`, module syntax that `containsModuleSyntax` finds without the `CommonJS`
/// variables, as Node's `shouldUseModuleEntryPoint` asks.
fn is_module(code: &str, exec_argv: &[String]) -> bool {
    let input_type = exec_argv
        .iter()
        .zip(
            exec_argv
                .iter()
                .skip(1)
                .chain(std::iter::once(&String::new())),
        )
        .find_map(|(option, next)| match option.split_once('=') {
            Some(("--input-type", value)) => Some(value.to_owned()),
            _ if option == "--input-type" => Some(next.clone()),
            _ => None,
        });
    match input_type.as_deref() {
        Some("module") => true,
        Some(_) => false,
        None => buoy_compiler::contains_module_syntax(code, false),
    }
}

fn json_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_module_code() {
        assert!(is_module("import fs from 'fs';", &[]));
        assert!(!is_module("require('fs')", &[]));
        assert!(is_module("x", &["--input-type=module".to_owned()]));
        assert!(!is_module(
            "import x from 'y'",
            &["--input-type".to_owned(), "commonjs".to_owned()]
        ));
    }

    #[test]
    fn rejects_a_value_that_node_rejects() {
        let argv = |items: &[&str]| {
            items
                .iter()
                .map(|item| (*item).to_owned())
                .collect::<Vec<_>>()
        };
        let unhandled = vec!["invalid value for --unhandled-rejections"];
        assert_eq!(
            invalid_options(&argv(&["--unhandled-rejections=foobar"])),
            unhandled
        );
        assert_eq!(
            invalid_options(&argv(&["--unhandled_rejections", "foobar"])),
            unhandled
        );
        assert!(invalid_options(&argv(&["--unhandled-rejections=strict"])).is_empty());
        assert!(invalid_options(&argv(&["--unhandled-rejections="])).is_empty());
        assert!(invalid_options(&argv(&["--no-warnings"])).is_empty());
    }

    /// The per-process checks of test-openssl-ca-options and test-crypto-secure-heap.
    #[test]
    fn rejects_conflicting_ca_stores_and_a_secure_heap_off_powers_of_2() {
        let argv = |items: &[&str]| {
            items
                .iter()
                .map(|item| (*item).to_owned())
                .collect::<Vec<_>>()
        };
        assert_eq!(
            invalid_options(&argv(&["--use-bundled-ca", "--use-openssl-ca"])),
            vec!["either --use-openssl-ca or --use-bundled-ca can be used, not both"]
        );
        assert!(
            invalid_options(&argv(&[
                "--use-bundled-ca",
                "--use-openssl-ca",
                "--no-use-openssl-ca"
            ]))
            .is_empty()
        );
        assert_eq!(
            invalid_options(&argv(&["--secure-heap=3", "--secure-heap-min=3"])),
            vec![
                "--secure-heap must be a power of 2",
                "--secure-heap-min must be a power of 2"
            ]
        );
        assert!(
            invalid_options(&argv(&["--secure-heap", "65536", "--secure-heap-min=4"])).is_empty()
        );
        assert!(invalid_options(&argv(&["--secure-heap=1", "--secure-heap-min=3"])).is_empty());
    }

    #[test]
    fn finds_the_crypto_name_as_node_does() {
        assert!(uses_crypto("crypto.constants"));
        assert!(uses_crypto("x = (crypto)"));
        assert!(!uses_crypto("webcrypto.subtle"));
        assert!(!uses_crypto("crypto_x + cryptography"));
        assert!(uses_crypto("$crypto"));
    }

    #[test]
    fn encodes_exec_argv_as_json() {
        let options = Options {
            exec_argv: vec!["-e".to_owned(), "say(\"hi\")\n".to_owned()],
            eval: true,
            repl: false,
        };
        assert_eq!(options.exec_argv_json(), r#"["-e","say(\"hi\")\n"]"#);
    }
}
