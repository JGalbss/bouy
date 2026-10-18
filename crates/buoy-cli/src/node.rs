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

/// The node options that take their value as the next argument.
const VALUE_OPTIONS: [&str; 22] = [
    "-r",
    "--require",
    "--import",
    "--loader",
    "--experimental-loader",
    "-C",
    "--conditions",
    "--title",
    "--env-file",
    "--env-file-if-exists",
    "--input-type",
    "--inspect-port",
    "--redirect-warnings",
    "--unhandled-rejections",
    "--dns-result-order",
    "--diagnostic-dir",
    "--report-dir",
    "--test-name-pattern",
    "--test-reporter",
    "--test-reporter-destination",
    "--watch-path",
    "--localstorage-file",
];

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
    fn encodes_exec_argv_as_json() {
        let options = Options {
            exec_argv: vec!["-e".to_owned(), "say(\"hi\")\n".to_owned()],
            eval: true,
        };
        assert_eq!(options.exec_argv_json(), r#"["-e","say(\"hi\")\n"]"#);
    }
}
