//! Embeds the runtime sources, `runtime/src/*.erl`, `*.hrl`, and `*.app.src`, in the binary.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::{env, fs};

fn main() {
    let manifest =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"));
    let runtime = manifest.join("../../runtime/src");
    println!("cargo:rerun-if-changed={}", runtime.display());
    let mut sources: Vec<PathBuf> = fs::read_dir(&runtime)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| is_runtime_source(path))
                .collect()
        })
        .unwrap_or_default();
    sources.sort();
    let mut table = String::from(
        "/// The runtime sources: file name and contents.\npub const SOURCES: &[(&str, &str)] = &[\n",
    );
    for path in &sources {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default();
        let absolute = path.canonicalize().unwrap_or_else(|_| path.clone());
        let _ = writeln!(
            table,
            "    ({name:?}, include_str!({:?})),",
            absolute.display().to_string()
        );
    }
    table.push_str("];\n");
    let out = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR"));
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
