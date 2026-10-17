//! Parsing and semantic analysis of one source file with oxc.

use std::path::Path;

use oxc::allocator::Allocator;
use oxc::ast::ast::Program;
use oxc::diagnostics::{Diagnostics, LabeledSpan};
use oxc::parser::Parser;
use oxc::semantic::{Semantic, SemanticBuilder};
use oxc::span::SourceType;

use crate::diagnostic::{Code, Diagnostic, Reporter};

/// Parses `source`, runs semantic analysis, and hands both to `use_program`.
///
/// Syntax and semantic errors become `BOUY200` diagnostics.
pub fn with_program<R>(
    path: &Path,
    source: &str,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    let source_type = SourceType::from_path(path).unwrap_or_else(|_| SourceType::ts());
    with_program_as(path, source, source_type, use_program)
}

/// `with_program` with an explicit source type, such as a `CommonJS` script.
pub fn with_program_as<R>(
    path: &Path,
    source: &str,
    source_type: SourceType,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, source_type).parse();
    if parsed.fatal_error || parsed.diagnostics.has_errors() {
        return Err(syntax_errors(path, source, &parsed.diagnostics));
    }
    let built = SemanticBuilder::new()
        .with_build_nodes(true)
        .with_check_syntax_error(true)
        .build(&parsed.program);
    if built.diagnostics.has_errors() {
        return Err(syntax_errors(path, source, &built.diagnostics));
    }
    Ok(use_program(&parsed.program, &built.semantic))
}

/// Parses `source` without semantic analysis and hands the program and whether it has
/// `import` or `export` syntax to `inspect`. `None` when it does not parse.
pub fn parses<R>(
    _path: &Path,
    source: &str,
    source_type: SourceType,
    inspect: impl for<'a> FnOnce(&Program<'a>, bool) -> R,
) -> Option<R> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, source_type).parse();
    if parsed.fatal_error || parsed.diagnostics.has_errors() {
        return None;
    }
    Some(inspect(
        &parsed.program,
        parsed.module_record.has_module_syntax,
    ))
}

fn syntax_errors(path: &Path, source: &str, diagnostics: &Diagnostics) -> Vec<Diagnostic> {
    let reporter = Reporter::new(path, source);
    diagnostics
        .errors()
        .map(|error| {
            let offset = error.labels.first().map_or(0, LabeledSpan::offset) as usize;
            // oxc rejects `yield` outside a generator as a reserved word. In Bouy that is a
            // `yield*` in a function nested in an Effect body (section 13).
            if error.message.contains("reserved")
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
