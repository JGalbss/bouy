//! `bouy`: compiles a TypeScript program to Erlang and runs it on one BEAM VM.

mod runtime;

use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, ExitStatus};

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
    /// Compile a program and run it.
    Run {
        /// The entry module.
        entry: PathBuf,
        /// Arguments for the program, available as `process.argv.slice(2)`.
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
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
    match Cli::parse().command {
        Commands::Run { entry, args } => run(&entry, &args),
        Commands::Check { entry } => match compile(&entry) {
            Ok(_) => ExitCode::SUCCESS,
            Err(code) => code,
        },
        Commands::Build { entry } => build(&entry),
    }
}

fn run(entry: &Path, args: &[String]) -> ExitCode {
    let project = match compile(entry) {
        Ok(project) => project,
        Err(code) => return code,
    };
    let build = match write(&project) {
        Ok(build) => build,
        Err(error) => return fail(&format!("cannot write the build: {error}")),
    };
    let ebin = match runtime::ebin() {
        Ok(ebin) => ebin,
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
    let status = Command::new(runtime::erl())
        .args(["-noshell", "-noinput", "-pa"])
        .arg(&ebin)
        .args(["-eval", "bouy_main:start()", "-extra"])
        .arg(&build)
        .arg(&project.entry)
        .arg(&entry_path)
        .arg(modules.join(","))
        .args(args)
        .status();
    match status {
        Ok(status) => ExitCode::from(exit_status(status)),
        Err(error) => fail(&format!(
            "cannot start erl: {error}; install Erlang/OTP or set BOUY_ERL"
        )),
    }
}

/// The status of the VM, or 128 plus the signal that killed it, as a shell reports it.
fn exit_status(status: ExitStatus) -> u8 {
    #[cfg(unix)]
    let signal = std::os::unix::process::ExitStatusExt::signal(&status).map(|signal| 128 + signal);
    #[cfg(not(unix))]
    let signal = None;
    status
        .code()
        .or(signal)
        .and_then(|code| u8::try_from(code).ok())
        .unwrap_or(1)
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
        Err(error) => fail(&format!("cannot write the build: {error}")),
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
fn write(project: &Project) -> io::Result<PathBuf> {
    let build = project.root.join(".bouy").join("build");
    fs::create_dir_all(build.join("src"))?;
    for module in &project.modules {
        let path = source_path(&build, &module.name);
        if fs::read_to_string(&path).is_ok_and(|current| current == module.erlang) {
            continue;
        }
        let staging = path.with_extension(format!("erl.{}", std::process::id()));
        fs::write(&staging, &module.erlang)?;
        fs::rename(&staging, &path)?;
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
