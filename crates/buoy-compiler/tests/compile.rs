//! Snapshot tests of the generated Erlang for each construct, an `erlc` check of every
//! snapshot, and the diagnostics of section 10.

use std::path::{Path, PathBuf};
use std::process::Command;

use buoy_compiler::{Diagnostic, Semantics, compile_in, compile_with};

fn tests_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests")
}

fn fixtures() -> PathBuf {
    tests_dir().join("fixtures")
}

/// The generated Erlang of the module that `path` holds.
fn lower(path: &Path) -> String {
    let project = compile_in(path, &fixtures()).unwrap_or_else(|diagnostics| {
        panic!(
            "{} does not compile:\n{}",
            path.display(),
            render(&diagnostics)
        )
    });
    project.modules[0].erlang.clone()
}

fn render(diagnostics: &[Diagnostic]) -> String {
    diagnostics
        .iter()
        .map(|diagnostic| {
            let mut diagnostic = diagnostic.clone();
            diagnostic.path = PathBuf::from(diagnostic.path.file_name().unwrap_or_default());
            diagnostic.to_string()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn lowers_each_construct() {
    insta::glob!("fixtures/*.ts", |path| {
        insta::assert_snapshot!(lower(path));
    });
}

#[test]
fn generated_erlang_compiles_with_erlc() {
    if Command::new("erlc").arg("-help").output().is_err() {
        assert!(
            std::env::var_os("BUOY_SKIP_VM_TESTS").is_some(),
            "erlc is not installed; set BUOY_SKIP_VM_TESTS=1 to skip the VM tests"
        );
        return;
    }
    let output = std::env::temp_dir().join(format!("buoy-compiler-erlc-{}", std::process::id()));
    std::fs::create_dir_all(&output).expect("the temporary directory is writable");
    let mut failures = Vec::new();
    for entry in std::fs::read_dir(fixtures()).expect("the fixtures exist") {
        let path = entry.expect("a directory entry").path();
        if path.extension().is_none_or(|extension| extension != "ts") {
            continue;
        }
        let project = compile_in(&path, &fixtures()).expect("the fixture compiles");
        for module in &project.modules {
            let source = output.join(format!("{}.erl", module.name));
            std::fs::write(&source, &module.erlang).expect("the temporary directory is writable");
            let result = Command::new("erlc")
                .arg("-o")
                .arg(&output)
                .arg(&source)
                .output()
                .expect("erlc runs");
            if !result.status.success() {
                failures.push(format!(
                    "{}:\n{}{}",
                    module.name,
                    String::from_utf8_lossy(&result.stdout),
                    String::from_utf8_lossy(&result.stderr)
                ));
            }
        }
    }
    let _ = std::fs::remove_dir_all(&output);
    assert!(
        failures.is_empty(),
        "erlc rejected generated Erlang:\n{}",
        failures.join("\n")
    );
}

/// Each file in `tests/fixtures/diagnostics` is named after the code it must produce, such as
/// `buoy205-closure-rebinds.ts`, and produces only that code.
#[test]
fn reports_each_diagnostic() {
    let directory = fixtures().join("diagnostics");
    insta::glob!("fixtures/diagnostics/*.ts", |path| {
        let expected = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.split('-').next())
            .map(str::to_uppercase)
            .expect("the fixture name starts with its code");
        let diagnostics = compile_in(path, &directory).err().unwrap_or_else(|| {
            panic!("{} compiles, but it must report {expected}", path.display())
        });
        for diagnostic in &diagnostics {
            assert_eq!(diagnostic.code.as_str(), expected, "{diagnostic}");
        }
        insta::assert_snapshot!(render(&diagnostics));
    });
}

/// The reference lowering names each syntax that it cannot lower yet, so a test262 failure
/// list says what to build.
#[test]
fn reference_lowering_names_unsupported_syntax() {
    let path = fixtures().join("reference/unsupported.ts");
    let Err(diagnostics) = compile_with(&path, Semantics::Reference) else {
        panic!("the fixture uses syntax that the reference lowering lacks, but it compiles");
    };
    let messages: Vec<&str> = diagnostics
        .iter()
        .map(|diagnostic| diagnostic.message.as_str())
        .collect();
    assert_eq!(
        messages,
        [
            "`spawn` of a value that is not a module-level class is not supported by the reference-semantics prototype"
        ]
    );
}

/// Two programs given as text at one path, as concurrent `node -e` runs in one directory
/// give them, compile to two Erlang modules, so that one run never loads the other's code.
#[test]
fn source_programs_at_one_path_compile_to_distinct_modules() {
    let entry = fixtures().join("[eval].cjs");
    let compile = |text: &str| {
        buoy_compiler::compile_source(&entry, text.to_owned())
            .unwrap_or_else(|diagnostics| panic!("does not compile:\n{}", render(&diagnostics)))
    };
    assert_ne!(
        compile("console.log(1);").entry,
        compile("console.log(2);").entry
    );
}
