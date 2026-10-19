//! `buoy`: compiles a TypeScript program to Erlang and runs it on one BEAM VM.

mod node;
mod runtime;

use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::{self, IsTerminal as _};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use buoy_compiler::{Diagnostic, EvalContext, EvalPlace, Project, Semantics};
use clap::{Parser, Subcommand, ValueEnum};

#[derive(Debug, Parser)]
#[command(
    name = "buoy",
    version,
    about = "Compile TypeScript to Erlang and run it on the BEAM"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Compile a program and run it. Every argument after the entry goes to the program.
    Run {
        #[arg(long, value_enum, default_value_t = SemanticsArg::Value)]
        semantics: SemanticsArg,
        /// The entry module.
        entry: PathBuf,
        /// Arguments for the program, available as `process.argv.slice(2)`.
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<OsString>,
    },
    /// Check a program and print its diagnostics.
    Check {
        #[arg(long, value_enum, default_value_t = SemanticsArg::Value)]
        semantics: SemanticsArg,
        /// The entry module.
        entry: PathBuf,
    },
    /// Compile a program to Erlang and print the paths of the Erlang files.
    Build {
        #[arg(long, value_enum, default_value_t = SemanticsArg::Value)]
        semantics: SemanticsArg,
        /// The entry module.
        entry: PathBuf,
    },
    /// Compile the code of an `eval` or of the `Function` constructor for a running VM:
    /// print the Erlang module, or the first diagnostic as `<ErrorName>\t<message>` with
    /// status 2. With `--serve`, answer one framed request after another on stdin (see
    /// `serve_eval`). The runtime calls this through `BUOY_COMPILER`.
    /// Build the runtime cache of this binary and print its directory. A test runner calls
    /// it once before it starts its VMs, so no run spends its deadline on the build.
    #[command(hide = true)]
    Runtime,
    #[command(hide = true)]
    CompileEval {
        /// Answer requests on stdin until it closes.
        #[arg(long)]
        serve: bool,
        /// A condition of `--conditions` of the program, for the resolution of each module
        /// that the server compiles.
        #[arg(long = "condition")]
        conditions: Vec<String>,
        #[command(flatten)]
        request: EvalRequest,
    },
}

/// One compilation of eval code: its options, the Erlang module name, and the file of the
/// source text, which a served request carries instead.
#[derive(Debug, clap::Args)]
struct EvalRequest {
    /// Compile the code as strict code.
    #[arg(long)]
    strict: bool,
    /// The source is the function that the `Function` constructor builds.
    #[arg(long)]
    function: bool,
    /// The source is a classic script of its own, as a host's `evalScript` runs it.
    #[arg(long)]
    script: bool,
    /// The script checks the deadline of its run at each turn of a loop, for the
    /// `timeout` of `vm.Script`.
    #[arg(long)]
    interruptible: bool,
    /// The source is an ES module whose requests the host links at run time, as
    /// `vm.SourceTextModule` compiles it, with this identifier.
    #[arg(long)]
    hosted_module: Option<String>,
    /// The bindings that sloppy direct eval code may not declare with `var`.
    #[arg(long, value_delimiter = ',')]
    lexical: Vec<String>,
    /// The scope of the caller of a direct eval, separated by commas: binding names, with
    /// `!` before an immutable one, and `@with` and `@vars` for the objects of `with`
    /// statements and of the variables of functions.
    #[arg(long, value_delimiter = ',')]
    scope: Vec<String>,
    /// Where the call is: `global`, `function` (the code may read `new.target`), `method`
    /// (and use `super.x`), `field` (a class field initializer, where `arguments` is a
    /// `SyntaxError`), or `constructor` (a derived one, so the code may call `super(...)`).
    #[arg(long, default_value = "global", value_parser = parse_place)]
    place: EvalPlace,
    /// The private names that the call sees, separated by commas.
    #[arg(long, value_delimiter = ',')]
    private: Vec<String>,
    /// The Erlang module name.
    module: Option<String>,
    /// The file that holds the source text.
    source: Option<PathBuf>,
}

fn parse_place(name: &str) -> Result<EvalPlace, String> {
    EvalPlace::from_name(name).ok_or_else(|| format!("no eval place `{name}`"))
}

/// The request of one frame of `serve_eval`.
#[derive(Debug, Parser)]
#[command(name = "compile-eval")]
struct Served {
    #[command(flatten)]
    request: EvalRequest,
}

impl EvalRequest {
    /// The Erlang module of the code, or its first diagnostic as `<ErrorName>\t<message>`.
    fn compile(self, text: &str) -> Result<String, String> {
        let module = self.module.unwrap_or_default();
        let context = EvalContext {
            place: self.place,
            privates: self.private,
        };
        let compiled = if let Some(identifier) = &self.hosted_module {
            buoy_compiler::compile_hosted_module(text, &module, identifier)
        } else if self.script {
            buoy_compiler::compile_eval_script(text, &module, self.interruptible)
        } else {
            buoy_compiler::compile_eval(
                text,
                &module,
                self.strict,
                self.function,
                &self.lexical,
                &self.scope,
                &context,
            )
        };
        compiled.map_err(|diagnostics| {
            let name = if diagnostics
                .iter()
                .any(|d| d.code == buoy_compiler::Code::Syntax)
            {
                "SyntaxError"
            } else {
                "TypeError"
            };
            let message = diagnostics
                .iter()
                .find(|d| name == "TypeError" || d.code == buoy_compiler::Code::Syntax)
                .map_or_else(String::new, |d| d.message.replace('\n', " "));
            format!("{name}\t{message}")
        })
    }
}

/// How the program treats objects: `value` (the contract) or `reference` (a prototype).
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum SemanticsArg {
    Value,
    Reference,
}

impl From<SemanticsArg> for Semantics {
    fn from(arg: SemanticsArg) -> Self {
        match arg {
            SemanticsArg::Value => Self::Value,
            SemanticsArg::Reference => Self::Reference,
        }
    }
}

/// The exit status for compile diagnostics (section 1).
const DIAGNOSTICS: u8 = 2;

fn main() -> ExitCode {
    let arguments: Vec<OsString> = env::args_os().collect();
    // `buoy [node options] <script> [args...]`, `buoy -e <code>`, and `buoy -p <code>` run
    // as `node` does, on the reference engine, so a program that starts `process.execPath`
    // as node starts Buoy.
    if let Some(first) = arguments.get(1)
        && is_node_invocation(first)
    {
        return node::run(&arguments[1..]);
    }
    // `buoy` alone with a script on stdin runs it, as `node` does.
    if arguments.len() == 1 && !io::stdin().is_terminal() {
        return node::run(&[]);
    }
    // `buoy run <entry> [args...]` passes each argument after the entry to the program as
    // it is, `--help` and `--` included, as `node <entry> [args...]` does.
    if let [_, command, entry, program_arguments @ ..] = arguments.as_slice()
        && command == "run"
        && !entry.to_string_lossy().starts_with('-')
    {
        return run(Path::new(entry), program_arguments, Semantics::Value);
    }
    match Cli::parse().command {
        Commands::Run {
            semantics,
            entry,
            args,
        } => run(&entry, &args, semantics.into()),
        // A module that only throws when it loads still fails the check.
        Commands::Check { semantics, entry } => match compile(&entry, semantics.into()) {
            Ok(project) if project.deferred.is_empty() => ExitCode::SUCCESS,
            Ok(project) => {
                for diagnostic in &project.deferred {
                    eprintln!("{}", relative(diagnostic));
                }
                ExitCode::from(DIAGNOSTICS)
            }
            Err(code) => code,
        },
        Commands::Build { semantics, entry } => build(&entry, semantics.into()),
        Commands::Runtime => match runtime::locate() {
            Ok(runtime) => {
                println!("{}", runtime.ebin.display());
                ExitCode::SUCCESS
            }
            Err(error) => fail(&error),
        },
        Commands::CompileEval {
            serve: true,
            conditions,
            ..
        } => {
            buoy_compiler::set_user_conditions(conditions);
            serve_eval()
        }
        Commands::CompileEval { request, .. } => compile_eval(request),
    }
}

/// `buoy compile-eval <module> <file>`: prints the Erlang module of the code in the file,
/// or its first diagnostic with status 2.
fn compile_eval(mut request: EvalRequest) -> ExitCode {
    let (Some(_), Some(source)) = (&request.module, request.source.take()) else {
        return fail("compile-eval needs a module name and the file of the source text");
    };
    let text = match fs::read_to_string(&source) {
        Ok(text) => text,
        Err(error) => return fail(&format!("cannot read {}: {error}", source.display())),
    };
    match request.compile(&text) {
        Ok(erlang) => {
            print!("{erlang}");
            ExitCode::SUCCESS
        }
        Err(diagnostic) => {
            print!("{diagnostic}");
            ExitCode::from(DIAGNOSTICS)
        }
    }
}

/// `buoy compile-eval --serve`: one compiler process for every eval of a VM. Each request
/// and each answer is a frame: a 4-byte big-endian length, then the bytes, as Erlang's
/// `{packet, 4}` port option writes and reads them. A request is the options of a
/// compilation and the module name, one on each line, then an empty line and the source
/// text. An answer is a status byte, 0 with the Erlang module or 2 with the diagnostic,
/// then the text.
fn serve_eval() -> ExitCode {
    use std::io::{Read, Write};
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    loop {
        let mut length = [0; 4];
        if input.read_exact(&mut length).is_err() {
            return ExitCode::SUCCESS;
        }
        let mut frame = vec![0; u32::from_be_bytes(length) as usize];
        if input.read_exact(&mut frame).is_err() {
            return ExitCode::SUCCESS;
        }
        let frame = String::from_utf8_lossy(&frame);
        let (header, text) = frame.split_once("\n\n").unwrap_or((&frame, ""));
        let arguments = std::iter::once("compile-eval").chain(header.split('\n'));
        let answer = if let Some(request) = header.strip_prefix("@load\n") {
            load_answer(request)
        } else if header == "@cjs-lexer" {
            cjs_lexer_answer(text)
        } else if let Some(variables) = header.strip_prefix("@module-syntax") {
            module_syntax_answer(text, variables != "\nno-cjs-variables")
        } else {
            match Served::try_parse_from(arguments) {
                Ok(Served { request }) => match request.compile(text) {
                    Ok(erlang) => [&[0], erlang.as_bytes()].concat(),
                    Err(diagnostic) => [&[DIAGNOSTICS], diagnostic.as_bytes()].concat(),
                },
                Err(error) => [&[1], error.to_string().as_bytes()].concat(),
            }
        };
        let Ok(size) = u32::try_from(answer.len()) else {
            return fail("an eval module is larger than 4 GB");
        };
        if output.write_all(&size.to_be_bytes()).is_err()
            || output.write_all(&answer).is_err()
            || output.flush().is_err()
        {
            return ExitCode::SUCCESS;
        }
    }
}

/// The answer to `@module-syntax`, with the line `no-cjs-variables` for text without the
/// variables of the `CommonJS` wrapper: status 0 and the byte 1 when the text is an ES
/// module by its syntax (`containsModuleSyntax`), else 0.
fn module_syntax_answer(text: &str, cjs_variables: bool) -> Vec<u8> {
    vec![
        0,
        u8::from(buoy_compiler::contains_module_syntax(text, cjs_variables)),
    ]
}

/// The answer to `@cjs-lexer`, the export names of `CommonJS` source text: status 0, the
/// names one on each line, an empty line, and the re-exported specifiers one on each line.
/// Text that does not parse has none.
fn cjs_lexer_answer(text: &str) -> Vec<u8> {
    let (names, reexports) = buoy_compiler::cjs_lexer(text).unwrap_or_default();
    [
        &[0],
        format!("{}\n\n{}", names.join("\n"), reexports.join("\n")).as_bytes(),
    ]
    .concat()
}

/// The answer to `@load`, a module that a running program loads at run time. The request
/// is the entry of the program, the importer, the specifier, and `require` or `import`,
/// one on each line. The answer is status 0 with `builtin` and the name, or `program` and
/// the path of the target, then each module as its name, its path, and the byte length of
/// its Erlang source, one on each line, then the source; or status 2 with
/// `<code>\t<message>`.
fn load_answer(request: &str) -> Vec<u8> {
    let mut lines = request.split('\n');
    let (Some(main), Some(importer), Some(specifier), Some(mode)) =
        (lines.next(), lines.next(), lines.next(), lines.next())
    else {
        return [&[1], b"a load request has four lines".as_slice()].concat();
    };
    match buoy_compiler::compile_loaded(
        Path::new(main),
        Path::new(importer),
        specifier,
        mode == "require",
    ) {
        Ok(buoy_compiler::Loaded::Builtin(name)) => {
            [&[0], format!("builtin\n{name}").as_bytes()].concat()
        }
        Ok(buoy_compiler::Loaded::Program(path, project)) => {
            let mut answer = vec![0];
            answer.extend_from_slice(format!("program\n{}\n", path.display()).as_bytes());
            for module in &project.modules {
                answer.extend_from_slice(
                    format!(
                        "{}\n{}\n{}\n",
                        module.name,
                        module.path.display(),
                        module.erlang.len()
                    )
                    .as_bytes(),
                );
                answer.extend_from_slice(module.erlang.as_bytes());
            }
            answer
        }
        Err((code, message)) => [&[DIAGNOSTICS], format!("{code}\t{message}").as_bytes()].concat(),
    }
}

fn run(entry: &Path, args: &[OsString], semantics: Semantics) -> ExitCode {
    let project = match compile(entry, semantics) {
        Ok(project) => project,
        Err(code) => return code,
    };
    start_program(&project, entry, args, &node::Options::default())
}

/// Whether the first argument starts a run as `node` does: a script or a node option, not
/// a subcommand of buoy.
fn is_node_invocation(first: &OsString) -> bool {
    let first = first.to_string_lossy();
    !matches!(
        first.as_ref(),
        "run"
            | "check"
            | "build"
            | "runtime"
            | "compile-eval"
            | "help"
            | "--help"
            | "-h"
            | "--version"
            | "-V"
    )
}

/// Starts the VM on a compiled program, with the node options of the invocation.
fn start_program(
    project: &Project,
    entry: &Path,
    args: &[OsString],
    options: &node::Options,
) -> ExitCode {
    let build = match write(project) {
        Ok(build) => build,
        Err(error) => return fail(&error),
    };
    let runtime = match runtime::locate() {
        Ok(runtime) => runtime,
        Err(error) => return fail(&error),
    };
    let entry_path = project
        .modules
        .first()
        .map_or_else(|| entry.to_path_buf(), |module| module.path.clone());
    let modules: Vec<&str> = project
        .modules
        .iter()
        .map(|module| module.name.as_str())
        .collect();
    // `Bd`: Ctrl-C ends the VM, as it ends Node, instead of opening the BREAK menu. A
    // failure to boot leaves no erl_crash.dump in the working directory. `-mode minimal`
    // starts the kernel without distribution and the resolver, which buoy_ai_openai starts
    // on its first request, and the boot script of the runtime, `no_dot_erlang` with
    // SIGTERM at its default action, skips the `.erlang` files of the user.
    let mut vm = runtime.vm(&["Bd"]);
    vm.args([
        "-noshell",
        "-noinput",
        "-mode",
        "minimal",
        "-boot",
        &runtime.boot,
        "-pa",
    ])
    .arg(&runtime.ebin)
    .args(["-buoy_exec_argv", &options.exec_argv_json()])
    .args(
        options
            .eval
            .then_some(["-buoy_eval", "true"])
            .into_iter()
            .flatten(),
    )
    .args(["-eval", "buoy_main:start()", "-extra"])
    .arg(&build)
    .arg(&project.entry)
    // Node reads each invalid UTF-8 sequence of `process.argv` as one U+FFFD, as
    // `to_string_lossy` does. OTP would hand the VM a tuple in place of the string.
    .arg(&*entry_path.to_string_lossy())
    .arg(modules.join(","))
    .args(args.iter().map(|arg| arg.to_string_lossy().into_owned()))
    .env("ERL_CRASH_DUMP_SECONDS", "0");
    // The runtime compiles the code of `eval` and `new Function` with this binary, and
    // `process.execPath` names it, as an absolute path without symbolic links, as Node's does.
    if let Ok(compiler) = env::current_exe().and_then(|path| path.canonicalize()) {
        vm.env("BUOY_COMPILER", compiler);
    }
    start(vm)
}

/// Replaces this process with the VM, so that a signal to the CLI reaches the VM and the
/// shell reports the status of the VM, or 128 plus the signal that ended it.
#[cfg(unix)]
fn start(mut vm: Command) -> ExitCode {
    use std::os::unix::process::CommandExt;
    let error = vm.exec();
    fail(&format!(
        "cannot start erl: {error}; install Erlang/OTP or set BUOY_ERL"
    ))
}

#[cfg(not(unix))]
fn start(mut vm: Command) -> ExitCode {
    match vm.status() {
        Ok(status) => ExitCode::from(
            status
                .code()
                .and_then(|code| u8::try_from(code).ok())
                .unwrap_or(1),
        ),
        Err(error) => fail(&format!(
            "cannot start erl: {error}; install Erlang/OTP or set BUOY_ERL"
        )),
    }
}

fn build(entry: &Path, semantics: Semantics) -> ExitCode {
    let project = match compile(entry, semantics) {
        Ok(project) => project,
        Err(code) => return code,
    };
    match write(&project) {
        Ok(build) => {
            for module in &project.modules {
                println!("{}", display(&source_path(&build, &module.name)));
            }
            ExitCode::SUCCESS
        }
        Err(error) => fail(&error),
    }
}

/// Compiles the program, printing diagnostics to stderr.
fn compile(entry: &Path, semantics: Semantics) -> Result<Project, ExitCode> {
    compile_reporting(entry, semantics, print_diagnostics)
}

/// Compiles the program, and on diagnostics records them and returns the status that
/// `report` gives after printing them.
fn compile_reporting(
    entry: &Path,
    semantics: Semantics,
    report: impl FnOnce(&[Diagnostic]) -> ExitCode,
) -> Result<Project, ExitCode> {
    if !entry.is_file() {
        eprintln!("buoy: cannot find the file {}", entry.display());
        return Err(ExitCode::from(DIAGNOSTICS));
    }
    buoy_compiler::compile_with(entry, semantics).map_err(|diagnostics| {
        write_result(&diagnostics);
        report(&diagnostics)
    })
}

fn print_diagnostics(diagnostics: &[Diagnostic]) -> ExitCode {
    for diagnostic in diagnostics {
        eprintln!("{}", relative(diagnostic));
    }
    ExitCode::from(DIAGNOSTICS)
}

/// Writes the facts of a run that stopped at its diagnostics to `BUOY_RESULT_FILE`, as
/// the VM writes the facts of a run (section 1 of the contract).
fn write_result(diagnostics: &[Diagnostic]) {
    let Some(path) = env::var_os("BUOY_RESULT_FILE").filter(|path| !path.is_empty()) else {
        return;
    };
    let codes: Vec<String> = diagnostics
        .iter()
        .map(|diagnostic| format!("\"{}\"", diagnostic.code.as_str()))
        .collect();
    let facts = format!(
        "{{\"status\":{DIAGNOSTICS},\"diagnostics\":[{}]}}",
        codes.join(",")
    );
    if let Err(error) = fs::write(&path, facts) {
        eprintln!("buoy: cannot write {}: {error}", Path::new(&path).display());
    }
}

/// Writes each module to `<project>/.buoy/build/src/` and returns the build directory.
/// A file whose contents are unchanged is left alone.
fn write(project: &Project) -> Result<PathBuf, String> {
    let build = project.root.join(".buoy").join("build");
    let failed = |path: &Path, error: io::Error| {
        format!("cannot write the build in {}: {error}", path.display())
    };
    let sources = build.join("src");
    fs::create_dir_all(&sources).map_err(|error| failed(&sources, error))?;
    for module in &project.modules {
        let path = source_path(&build, &module.name);
        if fs::read_to_string(&path).is_ok_and(|current| current == module.erlang) {
            continue;
        }
        let staging = path.with_extension(format!("erl.{}", std::process::id()));
        fs::write(&staging, &module.erlang).map_err(|error| failed(&staging, error))?;
        fs::rename(&staging, &path).map_err(|error| failed(&path, error))?;
    }
    Ok(build)
}

fn source_path(build: &Path, module: &str) -> PathBuf {
    build.join("src").join(format!("{module}.erl"))
}

fn relative(diagnostic: &Diagnostic) -> String {
    let mut diagnostic = diagnostic.clone();
    diagnostic.path = PathBuf::from(display(&diagnostic.path));
    diagnostic.to_string()
}

/// `path` relative to the working directory when it lies under it.
fn display(path: &Path) -> String {
    env::current_dir()
        .ok()
        .and_then(|cwd| cwd.canonicalize().ok())
        .and_then(|cwd| path.strip_prefix(cwd).ok().map(Path::to_path_buf))
        .unwrap_or_else(|| path.to_path_buf())
        .display()
        .to_string()
}

fn fail(message: &str) -> ExitCode {
    eprintln!("buoy: {message}");
    ExitCode::FAILURE
}
