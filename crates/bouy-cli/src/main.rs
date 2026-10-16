//! `bouy`: compiles a TypeScript program to Erlang and runs it on one BEAM VM.

mod runtime;

use std::env;
use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use bouy_compiler::{Diagnostic, Project};
use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(
    name = "bouy",
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
        /// The entry module.
        entry: PathBuf,
        /// Arguments for the program, available as `process.argv.slice(2)`.
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<OsString>,
    },
    /// Check a program and print its diagnostics.
    Check {
        /// The entry module.
        entry: PathBuf,
    },
    /// Compile a program to Erlang and print the paths of the Erlang files.
    Build {
        /// The entry module.
        entry: PathBuf,
    },
}

/// The exit status for compile diagnostics (section 1).
const DIAGNOSTICS: u8 = 2;

fn main() -> ExitCode {
    let arguments: Vec<OsString> = env::args_os().collect();
    // `bouy run <entry> [args...]` passes each argument after the entry to the program as
    // it is, `--help` and `--` included, as `node <entry> [args...]` does.
    if let [_, command, entry, program_arguments @ ..] = arguments.as_slice()
        && command == "run"
        && !entry.to_string_lossy().starts_with('-')
    {
        return run(Path::new(entry), program_arguments);
    }
    match Cli::parse().command {
        Commands::Run { entry, args } => run(&entry, &args),
        Commands::Check { entry } => match compile(&entry) {
            Ok(_) => ExitCode::SUCCESS,
            Err(code) => code,
        },
        Commands::Build { entry } => build(&entry),
    }
}

fn run(entry: &Path, args: &[OsString]) -> ExitCode {
    let project = match compile(entry) {
        Ok(project) => project,
        Err(code) => return code,
    };
    let build = match write(&project) {
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
    let mut vm = runtime.vm();
    // `+Bd`: Ctrl-C ends the VM, as it ends Node, instead of opening the BREAK menu. A
    // failure to boot leaves no erl_crash.dump in the working directory. `-mode minimal`
    // starts the kernel without distribution and the resolver, which bouy_ai_openai starts
    // on its first request, and `no_dot_erlang` skips the `.erlang` files of the user.
    vm.args([
        "+Bd",
        "-noshell",
        "-noinput",
        "-mode",
        "minimal",
        "-boot",
        "no_dot_erlang",
        "-pa",
    ])
    .arg(&runtime.ebin)
    .args(["-eval", "bouy_main:start()", "-extra"])
    .arg(&build)
    .arg(&project.entry)
    // Node reads each invalid UTF-8 sequence of `process.argv` as one U+FFFD, as
    // `to_string_lossy` does. OTP would hand the VM a tuple in place of the string.
    .arg(&*entry_path.to_string_lossy())
    .arg(modules.join(","))
    .args(args.iter().map(|arg| arg.to_string_lossy().into_owned()))
    .env("ERL_CRASH_DUMP_SECONDS", "0");
    start(vm)
}

/// Replaces this process with the VM, so that a signal to the CLI reaches the VM and the
/// shell reports the status of the VM, or 128 plus the signal that ended it.
#[cfg(unix)]
fn start(mut vm: Command) -> ExitCode {
    use std::os::unix::process::CommandExt;
    let error = vm.exec();
    fail(&format!(
        "cannot start erl: {error}; install Erlang/OTP or set BOUY_ERL"
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
            "cannot start erl: {error}; install Erlang/OTP or set BOUY_ERL"
        )),
    }
}

fn build(entry: &Path) -> ExitCode {
    let project = match compile(entry) {
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
fn compile(entry: &Path) -> Result<Project, ExitCode> {
    if !entry.is_file() {
        eprintln!("bouy: cannot find the file {}", entry.display());
        return Err(ExitCode::from(DIAGNOSTICS));
    }
    bouy_compiler::compile(entry).map_err(|diagnostics| {
        for diagnostic in &diagnostics {
            eprintln!("{}", relative(diagnostic));
        }
        ExitCode::from(DIAGNOSTICS)
    })
}

/// Writes each module to `<project>/.bouy/build/src/` and returns the build directory.
/// A file whose contents are unchanged is left alone.
fn write(project: &Project) -> Result<PathBuf, String> {
    let build = project.root.join(".bouy").join("build");
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
    eprintln!("bouy: {message}");
    ExitCode::FAILURE
}
