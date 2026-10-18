//! `buoy` invoked as `node`: `buoy [node options] <script> [args...]`, `buoy -e <code>`,
//! and `buoy -p <code>`. The program runs on the reference engine, and the node options
//! reach the VM as `process.execArgv`.

use std::env;
use std::ffi::OsString;
use std::fmt::Write as _;
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

/// `ExitCode::kInvalidCommandLineArgument` of Node.
const INVALID_COMMAND_LINE_ARGUMENT: u8 = 9;

/// The error of the first option of `exec_argv` whose value Node rejects, which Node
/// reports before any JavaScript runs.
fn invalid_option(exec_argv: &[String]) -> Option<&'static str> {
    let mut items = exec_argv.iter();
    while let Some(item) = items.next() {
        let (name, inline) = item
            .split_once('=')
            .map_or((item.as_str(), None), |(name, value)| (name, Some(value)));
        let name = name.replace('_', "-");
        let Some((_, choices, error)) =
            CHOICE_OPTIONS.iter().find(|(option, _, _)| *option == name)
        else {
            continue;
        };
        let value = inline
            .or_else(|| items.next().map(String::as_str))
            .unwrap_or("");
        if !value.is_empty() && !choices.contains(&value) {
            return Some(error);
        }
    }
    None
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
    if let Some(error) = invalid_option(&options.exec_argv) {
        let program = env::args_os().next().map_or_else(
            || "buoy".to_owned(),
            |name| name.to_string_lossy().into_owned(),
        );
        eprintln!("{program}: {error}");
        return ExitCode::from(INVALID_COMMAND_LINE_ARGUMENT);
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
            let project = match super::compile(Path::new(&script), Semantics::Reference) {
                Ok(project) => project,
                Err(code) => return code,
            };
            super::start_program(&project, Path::new(&script), program_arguments, &options)
        }
        Some(Entry::Eval(code)) => {
            options.eval = true;
            let module = is_module(&code, &options.exec_argv);
            run_source(code, module, program_arguments, &options)
        }
        Some(Entry::Print(code)) => {
            options.eval = true;
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
/// imports from there, and starts it.
fn run_source(code: String, module: bool, arguments: &[OsString], options: &Options) -> ExitCode {
    let directory = env::current_dir().unwrap_or_else(|_| Path::new(".").to_path_buf());
    let entry = directory.join(if module { "[eval].mjs" } else { "[eval].cjs" });
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
        assert_eq!(
            invalid_option(&argv(&["--unhandled-rejections=foobar"])),
            Some("invalid value for --unhandled-rejections")
        );
        assert_eq!(
            invalid_option(&argv(&["--unhandled_rejections", "foobar"])),
            Some("invalid value for --unhandled-rejections")
        );
        assert_eq!(
            invalid_option(&argv(&["--unhandled-rejections=strict"])),
            None
        );
        assert_eq!(invalid_option(&argv(&["--unhandled-rejections="])), None);
        assert_eq!(invalid_option(&argv(&["--no-warnings"])), None);
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
