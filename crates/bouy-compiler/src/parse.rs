//! Parsing and semantic analysis of one source file with oxc.

use std::path::Path;

use oxc::allocator::Allocator;
use oxc::ast::ast::Program;
use oxc::diagnostics::{Diagnostics, LabeledSpan};
use oxc::parser::Parser;
use oxc::semantic::{Semantic, SemanticBuilder};
use oxc::span::SourceType;

use crate::Goal;
use crate::diagnostic::{Code, Diagnostic, Reporter};

/// The source type that `path` parses with under `goal`.
pub fn source_type(path: &Path, goal: Goal) -> SourceType {
    match goal {
        Goal::Extension => SourceType::from_path(path).unwrap_or_else(|_| SourceType::ts()),
        Goal::Script => SourceType::script(),
        Goal::Module => SourceType::mjs(),
    }
}

/// Parses `source`, runs semantic analysis, and hands both to `use_program`.
///
/// Syntax and semantic errors become `BOUY200` diagnostics.
pub fn with_program<R>(
    path: &Path,
    source: &str,
    source_type: SourceType,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, source_type).parse();
    if parsed.fatal_error || parsed.diagnostics.has_errors() {
        return Err(syntax_errors(
            path,
            source,
            source_type,
            &parsed.diagnostics,
        ));
    }
    let built = SemanticBuilder::new()
        .with_build_nodes(true)
        .with_check_syntax_error(true)
        .build(&parsed.program);
    if built.diagnostics.has_errors() {
        return Err(syntax_errors(path, source, source_type, &built.diagnostics));
    }
    Ok(use_program(&parsed.program, &built.semantic))
}

fn syntax_errors(
    path: &Path,
    source: &str,
    source_type: SourceType,
    diagnostics: &Diagnostics,
) -> Vec<Diagnostic> {
    let reporter = Reporter::new(path, source);
    diagnostics
        .errors()
        .map(|error| {
            let offset = error.labels.first().map_or(0, LabeledSpan::offset) as usize;
            // oxc rejects `yield` outside a generator as a reserved word. In Bouy that is a
            // `yield*` in a function nested in an Effect body (section 13). In JavaScript it
            // stays a syntax error, as test262 expects.
            if source_type.is_typescript()
                && error.message.contains("reserved")
                && source.get(offset..).is_some_and(|rest| rest.starts_with("yield"))
            {
                return reporter.at(
                    offset,
                    Code::Unsupported,
                    "`yield*` runs an Effect only directly in a generator function; a nested function cannot yield, so make it return an Effect, such as `Effect.gen(function* () { ... })`, and `yield*` that".to_owned(),
                );
            }
            reporter.at(offset, Code::Syntax, error.message.to_string())
        })
        .collect()
}
