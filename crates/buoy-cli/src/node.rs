//! `buoy` invoked as `node`: `buoy [node options] <script> [args...]`, `buoy -e <code>`,
//! and `buoy -p <code>`. The program runs on the reference engine, and the node options
//! reach the VM as `process.execArgv`.

use std::collections::hash_map::DefaultHasher;
use std::env;
use std::ffi::OsString;
use std::fmt::Write as _;
use std::hash::{Hash as _, Hasher as _};
use std::io::{IsTerminal as _, Read as _};
use std::path::Path;
use std::process::ExitCode;

use buoy_compiler::Semantics;

/// The node options of an invocation, which the VM reads with `-buoy_exec_argv`, and
/// whether the entry is the code of `-e` or `-p`, which has no script in `process.argv`.
#[derive(Debug, Default)]
pub struct Options {
    exec_argv: Vec<String>,
    pub eval: bool,
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
}

/// Runs the invocation whose arguments, after the binary, are `arguments`.
pub fn run(arguments: &[OsString]) -> ExitCode {
    let mut options = Options::default();
    let mut entry = None;
    let mut print_version = false;
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
                options.exec_argv.push(argument.clone());
                if VALUE_OPTIONS.contains(&argument.as_str())
                    && let Some(value) = arguments.get(index)
                {
                    options.exec_argv.push(value.to_string_lossy().into_owned());
                    index += 1;
                }
            }
            _ => {
                entry = Some(Entry::Script(argument));
                break;
            }
        }
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
    let program_arguments = &arguments[index.min(arguments.len())..];
    match entry {
        Some(Entry::Script(script)) if script == "-" => {
            // `node - a b` keeps `-` as process.argv[1].
            let arguments: Vec<OsString> = std::iter::once(OsString::from("-"))
                .chain(program_arguments.iter().cloned())
                .collect();
            run_stdin(&arguments, options)
        }
        Some(Entry::Script(script)) => {
            let script = buoy_compiler::resolve_main(Path::new(&script))
                .map_or(script, |path| path.to_string_lossy().into_owned());
            let project = match super::compile(Path::new(&script), Semantics::Reference) {
                Ok(project) => project,
                Err(code) => return code,
            };
            super::start_program(&project, Path::new(&script), program_arguments, &options)
        }
        Some(Entry::Eval(code)) => {
            options.eval = true;
            let module = is_module(&code, &options.exec_argv);
            let code = if !module && uses_crypto(&code) {
                format!("(crypto=>{{{{{code}}}}})(require('node:crypto'))")
            } else {
                code
            };
            run_source(code, module, program_arguments, &options)
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
            run_source(source, false, program_arguments, &options)
        }
        None if std::io::stdin().is_terminal() => super::fail(
            "buoy: a REPL without a script is not supported yet; pass a script, -e, or -p",
        ),
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

/// `buoy -` and `buoy` with piped stdin: the script is the text of stdin.
fn run_stdin(arguments: &[OsString], mut options: Options) -> ExitCode {
    let mut code = String::new();
    if let Err(error) = std::io::stdin().read_to_string(&mut code) {
        return super::fail(&format!("buoy: cannot read the script from stdin: {error}"));
    }
    options.eval = true;
    let module = is_module(&code, &options.exec_argv);
    run_source(code, module, arguments, &options)
}

/// Compiles the code as the module `[eval]` of the working directory, so it resolves its
/// imports from there, and starts it. The name carries a hash of the code: runs of other
/// code in the same directory at the same time write other files of the build.
fn run_source(code: String, module: bool, arguments: &[OsString], options: &Options) -> ExitCode {
    let directory = env::current_dir().unwrap_or_else(|_| Path::new(".").to_path_buf());
    let mut hasher = DefaultHasher::new();
    code.hash(&mut hasher);
    let extension = if module { "mjs" } else { "cjs" };
    let entry = directory.join(format!("[eval-{:016x}].{extension}", hasher.finish()));
    match buoy_compiler::compile_source(&entry, code) {
        Ok(project) => super::start_program(&project, &entry, arguments, options),
        Err(diagnostics) => {
            for diagnostic in &diagnostics {
                eprintln!("{}", super::relative(diagnostic));
            }
            ExitCode::from(super::DIAGNOSTICS)
        }
    }
}

/// Whether the code of `-e` is an ES module: `--input-type=module`, or a line that starts
/// with `import` or `export`, as Node's detection of module syntax finds it.
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
        None => code.lines().any(|line| {
            let line = line.trim_start();
            line.starts_with("import ")
                || line.starts_with("import{")
                || line.starts_with("import*")
                || line.starts_with("import'")
                || line.starts_with("import\"")
                || line.starts_with("export ")
                || line.contains("import.meta")
        }),
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
        };
        assert_eq!(options.exec_argv_json(), r#"["-e","say(\"hi\")\n"]"#);
    }
}
