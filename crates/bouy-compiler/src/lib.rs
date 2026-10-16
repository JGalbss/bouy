//! Compiles one TypeScript module into JavaScript that the Bouy runtime can schedule.
//!
//! The compiler strips TypeScript syntax and applies two actor-aware lowerings:
//!
//! - Every loop inside an `async` function gets a preemption point at the top of its body.
//!   The runtime decides at run time whether the point yields, so code outside an actor
//!   turn keeps its ordinary semantics.
//! - Every exported class records where it is defined, so the runtime can construct it
//!   in another thread from its module URL and export name.

mod lower;

use std::path::Path;

use oxc::allocator::Allocator;
use oxc::codegen::{Codegen, CodegenOptions, CodegenReturn};
use oxc::diagnostics::Diagnostics;
use oxc::parser::Parser;
use oxc::semantic::SemanticBuilder;
use oxc::span::SourceType;
use oxc::transformer::{TransformOptions, Transformer};

/// The module specifier that compiled code imports runtime intrinsics from.
pub const INTRINSICS_MODULE: &str = "bouy/intrinsics";

/// JavaScript produced from one module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub code: String,
    pub source_map: Option<String>,
    pub preemption_points: usize,
    pub located_classes: Vec<String>,
}

/// A problem that stopped compilation, positioned in the original source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnostic {
    pub message: String,
    pub line: usize,
    pub column: usize,
}

/// Compiles `source`, read from `path`, into JavaScript with a source map.
///
/// # Errors
///
/// Returns every parse, semantic, or transform diagnostic when the module cannot compile.
pub fn compile(path: &Path, source: &str) -> Result<Output, Vec<Diagnostic>> {
    let allocator = Allocator::default();
    let source_type = SourceType::from_path(path).unwrap_or_else(|_| SourceType::ts());
    let parsed = Parser::new(&allocator, source, source_type).parse();
    if parsed.diagnostics.has_errors() {
        return Err(positioned(source, &parsed.diagnostics));
    }
    let mut program = parsed.program;

    let semantic = SemanticBuilder::new().build(&program);
    if semantic.diagnostics.has_errors() {
        return Err(positioned(source, &semantic.diagnostics));
    }
    let scoping = semantic.semantic.into_scoping();

    let transformed = Transformer::new(&allocator, path, &TransformOptions::default())
        .build_with_scoping(scoping, &mut program);
    if transformed.diagnostics.has_errors() {
        return Err(positioned(source, &transformed.diagnostics));
    }

    let lowering = lower::lower(&allocator, &mut program);

    let options = CodegenOptions {
        source_map_path: Some(path.to_path_buf()),
        ..CodegenOptions::default()
    };
    let CodegenReturn { code, map, .. } = Codegen::new().with_options(options).build(&program);
    Ok(Output {
        code,
        source_map: map.map(|map| map.to_json_string()),
        preemption_points: lowering.preemption_points,
        located_classes: lowering.located_classes,
    })
}

fn positioned(source: &str, diagnostics: &Diagnostics) -> Vec<Diagnostic> {
    diagnostics
        .errors()
        .map(|diagnostic| {
            let offset = diagnostic
                .labels
                .first()
                .map_or(0, oxc::diagnostics::LabeledSpan::offset);
            let (line, column) = line_and_column(source, offset as usize);
            Diagnostic {
                message: diagnostic.message.to_string(),
                line,
                column,
            }
        })
        .collect()
}

fn line_and_column(source: &str, offset: usize) -> (usize, usize) {
    let before = &source[..offset.min(source.len())];
    let line = before.matches('\n').count() + 1;
    let column = before
        .rfind('\n')
        .map_or(before.len(), |newline| before.len() - newline - 1)
        + 1;
    (line, column)
}
