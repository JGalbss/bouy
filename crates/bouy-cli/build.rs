//! Embeds the runtime sources, `runtime/src/*.erl`, `*.hrl`, and `*.app.src`, in the binary.
//! The build fails when they are missing, because a binary without them cannot run a program.
//!
//! It also compiles the vendored Temporal polyfill into one more runtime source,
//! `bouy_temporal.erl`, with the reference compiler (see `temporal_module`).

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::{env, fs};

fn main() {
    let manifest =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"));
    let runtime = manifest.join("../../runtime/src");
    println!("cargo:rerun-if-changed={}", runtime.display());
    let mut sources: Vec<PathBuf> = fs::read_dir(&runtime)
        .unwrap_or_else(|error| panic!("{} holds the runtime sources: {error}", runtime.display()))
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| is_runtime_source(path))
        .collect();
    assert!(
        !sources.is_empty(),
        "{} holds no runtime sources",
        runtime.display()
    );
    let out = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR"));
    sources.push(temporal_module(
        &manifest.join("../../runtime/vendor/temporal-polyfill/global.js"),
        &out,
    ));
    sources.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
    let mut table = String::from(
        "/// The runtime sources: file name and contents.\npub const SOURCES: &[(&str, &str)] = &[\n",
    );
    for path in &sources {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .expect("a runtime source has a UTF-8 name");
        let absolute = path
            .canonicalize()
            .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
        let _ = writeln!(
            table,
            "    ({name:?}, include_str!({:?})),",
            absolute.display().to_string()
        );
    }
    table.push_str("];\n");
    fs::write(out.join("runtime_sources.rs"), table).expect("OUT_DIR is writable");
}

/// `*.erl`, `*.hrl`, and `*.app.src`.
fn is_runtime_source(path: &Path) -> bool {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("erl" | "hrl") => true,
        Some("src") => path
            .file_stem()
            .map(Path::new)
            .and_then(Path::extension)
            .is_some_and(|extension| extension == "app"),
        _ => false,
    }
}

/// The edits that turn the polyfill's script, temporal-polyfill 1.0.6 `global.js` (MIT,
/// fullcalendar/temporal-polyfill), into strict eval code that reads the realm's
/// `Intl.DateTimeFormat` shim and a nanosecond clock from its `this`, and whose completion
/// value is the `Temporal` namespace instead of writes to globals. The code drops the
/// script's function wrapper, so each top-level function compiles to an Erlang function:
/// erlc lints one function in time that grows with the square of its nested variables.
/// Each `from` must occur exactly once.
const TEMPORAL_EDITS: &[(&str, &str)] = &[
    (
        "!function() {\n  \"use strict\";\n",
        "\"use strict\";\nconst { Intl, nowNanoseconds } = this;\n",
    ),
    // The namespace is a lazy global, so reading it here would load the polyfill again.
    (
        "const NativeTemporal = globalThis.Temporal;",
        "const NativeTemporal = void 0;",
    ),
    (
        "return BigInt(Date.now()) * bigNanoInMilli;",
        "return nowNanoseconds();",
    ),
];

/// The tail of the script, which installs the globals and closes the wrapper. The code ends
/// with the namespace in its place.
const TEMPORAL_TAIL: &str = "  const DateTimeFormat = createDateTimeFormatClass(";

/// Compiles the polyfill at `vendored` into `out/bouy_temporal.erl`, whose `'__eval__'/3`
/// runs the code of `TEMPORAL_EDITS`. `bouy_ref_temporal` calls it the first time a realm
/// reads `Temporal`.
fn temporal_module(vendored: &Path, out: &Path) -> PathBuf {
    println!("cargo:rerun-if-changed={}", vendored.display());
    let script = fs::read_to_string(vendored)
        .unwrap_or_else(|error| panic!("{} holds the polyfill: {error}", vendored.display()));
    let edited = TEMPORAL_EDITS.iter().fold(script, |text, (from, to)| {
        assert_eq!(
            text.matches(from).count(),
            1,
            "the polyfill must hold {from:?} once"
        );
        text.replacen(from, to, 1)
    });
    let tail = edited
        .find(TEMPORAL_TAIL)
        .expect("the polyfill ends by installing its globals");
    let source = format!("{}Temporal;\n", &edited[..tail]);
    let erlang = bouy_compiler::compile_eval(
        &source,
        "bouy_temporal",
        false,
        false,
        &[],
        &[],
        &bouy_compiler::EvalContext::default(),
    )
    .unwrap_or_else(|diagnostics| {
        panic!(
            "the reference compiler rejects the polyfill: {}",
            diagnostics
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join("\n")
        )
    });
    let path = out.join("bouy_temporal.erl");
    fs::write(&path, erlang).expect("OUT_DIR is writable");
    path
}
