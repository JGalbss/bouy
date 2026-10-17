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
    parse_program(path, source, true, use_program)
}

/// As `with_program`, for the JavaScript engine (`--semantics reference`): a `yield`
/// outside a generator is a syntax error there, not a `yield*` of an Effect.
pub fn with_js_program<R>(
    path: &Path,
    source: &str,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    parse_program(path, source, false, use_program)
}

fn parse_program<R>(
    path: &Path,
    source: &str,
    effect_hint: bool,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    let allocator = Allocator::default();
    let source_type = SourceType::from_path(path).unwrap_or_else(|_| SourceType::ts());
    let parsed = Parser::new(&allocator, source, source_type).parse();
    if parsed.fatal_error || parsed.diagnostics.has_errors() {
        return Err(syntax_errors(
            path,
            source,
            &parsed.diagnostics,
            effect_hint,
        ));
    }
    let built = SemanticBuilder::new()
        .with_build_nodes(true)
        .with_check_syntax_error(true)
        .build(&parsed.program);
    if built.diagnostics.has_errors() {
        return Err(syntax_errors(path, source, &built.diagnostics, effect_hint));
    }
    Ok(use_program(&parsed.program, &built.semantic))
}

fn syntax_errors(
    path: &Path,
    source: &str,
    diagnostics: &Diagnostics,
    effect_hint: bool,
) -> Vec<Diagnostic> {
    let reporter = Reporter::new(path, source);
    diagnostics
        .errors()
        .map(|error| {
            let offset = error.labels.first().map_or(0, LabeledSpan::offset) as usize;
            // oxc rejects `yield` outside a generator as a reserved word. In Bouy that is a
            // `yield*` in a function nested in an Effect body (section 13).
            if effect_hint
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
