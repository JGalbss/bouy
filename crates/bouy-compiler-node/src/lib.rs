//! Node.js binding for the Bouy compiler.
#![allow(
    unsafe_code,
    reason = "napi-derive expands into FFI glue that needs unsafe blocks"
)]

use std::path::Path;

use napi::Either;
use napi_derive::napi;

/// JavaScript produced from one TypeScript module.
#[napi(object)]
#[derive(Debug)]
pub struct CompiledModule {
    #[napi(ts_type = "'compiled'")]
    pub kind: String,
    pub code: String,
    pub source_map: Option<String>,
    pub preemption_points: u32,
    pub located_classes: Vec<String>,
}

/// The diagnostics that stopped one module from compiling.
#[napi(object)]
#[derive(Debug)]
pub struct CompileFailure {
    #[napi(ts_type = "'failed'")]
    pub kind: String,
    pub diagnostics: Vec<CompileDiagnostic>,
}

/// One problem, positioned in the original source.
#[napi(object)]
#[derive(Debug)]
pub struct CompileDiagnostic {
    pub message: String,
    pub line: u32,
    pub column: u32,
}

/// Compiles one TypeScript module read from `path`.
#[napi]
#[must_use]
#[allow(
    clippy::needless_pass_by_value,
    reason = "napi-rs hands JavaScript strings to Rust as owned values"
)]
pub fn compile(path: String, source: String) -> Either<CompiledModule, CompileFailure> {
    match bouy_compiler::compile(Path::new(&path), &source) {
        Ok(output) => Either::A(CompiledModule {
            kind: "compiled".to_owned(),
            code: output.code,
            source_map: output.source_map,
            preemption_points: saturating_u32(output.preemption_points),
            located_classes: output.located_classes,
        }),
        Err(diagnostics) => Either::B(CompileFailure {
            kind: "failed".to_owned(),
            diagnostics: diagnostics
                .into_iter()
                .map(|diagnostic| CompileDiagnostic {
                    message: diagnostic.message,
                    line: saturating_u32(diagnostic.line),
                    column: saturating_u32(diagnostic.column),
                })
                .collect(),
        }),
    }
}

fn saturating_u32(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}
