//! Parsing and semantic analysis of one source file with oxc.

use std::path::Path;

use oxc::allocator::Allocator;
use oxc::ast::ast::Program;
use oxc::diagnostics::{Diagnostics, LabeledSpan};
use oxc::parser::{ParseOptions, Parser};
use oxc::semantic::{Semantic, SemanticBuilder};
use oxc::span::SourceType;

use crate::Goal;
use crate::oxc_gaps;
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
/// Syntax and semantic errors become `BUOY200` diagnostics.
pub fn with_program<R>(
    path: &Path,
    source: &str,
    source_type: SourceType,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    parse_program(
        path,
        source,
        source_type,
        source_type.is_typescript(),
        use_program,
    )
}

/// As `with_program`, for the JavaScript engine (`--semantics reference`): a `yield`
/// outside a generator is a syntax error there, not a `yield*` of an Effect.
pub fn with_js_program<R>(
    path: &Path,
    source: &str,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    let source_type = SourceType::from_path(path).unwrap_or_else(|_| SourceType::ts());
    parse_program(path, source, source_type, false, use_program)
}

/// `with_js_program` with an explicit source type, such as a `CommonJS` script.
pub fn with_program_as<R>(
    path: &Path,
    source: &str,
    source_type: SourceType,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    parse_program(path, source, source_type, false, use_program)
}

/// `with_program_as` for the code of a direct eval: `allowed` drops each error that the
/// context of the call permits, such as `super.x` in a method, given the program, the
/// message, and its offset.
pub fn with_program_allowing<R>(
    path: &Path,
    source: &str,
    source_type: SourceType,
    allowed: &dyn Fn(&Program<'_>, &str, usize) -> bool,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    parse_filtered(path, source, source_type, false, allowed, use_program)
}

fn parse_program<R>(
    path: &Path,
    source: &str,
    source_type: SourceType,
    effect_hint: bool,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    parse_filtered(
        path,
        source,
        source_type,
        effect_hint,
        &|_, _, _| false,
        use_program,
    )
}

fn parse_filtered<R>(
    path: &Path,
    source: &str,
    source_type: SourceType,
    effect_hint: bool,
    allowed: &dyn Fn(&Program<'_>, &str, usize) -> bool,
    use_program: impl for<'a> FnOnce(&Program<'a>, &Semantic<'a>) -> R,
) -> Result<R, Vec<Diagnostic>> {
    // Source that JavaScript allows and oxc rejects (`oxc_gaps`): each pass rewrites the
    // places that oxc reported, which it reports one at a time, and parses again. The
    // errors of the source stand when a place is no such gap.
    let mut rewritten: Option<String> = None;
    let mut errors = Vec::new();
    for _ in 0..=MAX_REWRITES {
        let text = rewritten.as_deref().unwrap_or(source);
        let next = {
            let allocator = Allocator::default();
            let parsed = parse_allowing(&allocator, text, source_type, allowed);
            if !parsed.fatal_error && !parsed.diagnostics.has_errors() {
                return match (analyze(&parsed.program, allowed), rewritten.is_some()) {
                    (Ok(built), false) => Ok(use_program(&parsed.program, &built.semantic)),
                    (Ok(built), true) if oxc_gaps::are_sloppy(&built.semantic) => {
                        Ok(use_program(&parsed.program, &built.semantic))
                    }
                    (Err(diagnostics), false) => {
                        Err(syntax_errors(path, source, &diagnostics, effect_hint))
                    }
                    _ => Err(errors),
                };
            }
            if rewritten.is_none() {
                errors = syntax_errors(path, source, &parsed.diagnostics, effect_hint);
            }
            oxc_gaps::rewrite(text, &parsed.diagnostics)
                .filter(|_| oxc_gaps::is_free(source))
        };
        match next {
            Some(next) => rewritten = Some(next),
            None => return Err(errors),
        }
    }
    Err(errors)
}

/// The most passes of `oxc_gaps` rewrites over one source.
const MAX_REWRITES: usize = 64;

/// Parses `source` and drops each error that `allowed` permits.
fn parse_allowing<'a>(
    allocator: &'a Allocator,
    source: &'a str,
    source_type: SourceType,
    allowed: &dyn Fn(&Program<'_>, &str, usize) -> bool,
) -> oxc::parser::ParserReturn<'a> {
    // Parsing each regular expression pattern reports its early errors as syntax errors.
    let options = ParseOptions {
        parse_regular_expression: true,
        ..ParseOptions::default()
    };
    let mut parsed = Parser::new(allocator, source, source_type)
        .with_options(options)
        .parse();
    let program = &parsed.program;
    let kept: Vec<_> = parsed
        .diagnostics
        .iter()
        .filter(|error| {
            let offset = error.labels.first().map_or(0, LabeledSpan::offset) as usize;
            !allowed(program, &error.message, offset)
        })
        .cloned()
        .collect();
    parsed.diagnostics = kept.into();
    parsed
}

/// The semantic analysis of `program`, or its errors that `allowed` does not permit.
fn analyze<'a>(
    program: &'a Program<'a>,
    allowed: &dyn Fn(&Program<'_>, &str, usize) -> bool,
) -> Result<oxc::semantic::SemanticBuilderReturn<'a>, Diagnostics> {
    let mut built = SemanticBuilder::new()
        .with_build_nodes(true)
        .with_check_syntax_error(true)
        .build(program);
    built.diagnostics.retain(|error| {
        let offset = error.labels.first().map_or(0, LabeledSpan::offset) as usize;
        !allowed(program, &error.message, offset)
    });
    if built.diagnostics.has_errors() {
        return Err(std::mem::take(&mut built.diagnostics));
    }
    Ok(built)
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
            // oxc rejects `yield` outside a generator as a reserved word. In Buoy that is a
            // `yield*` in a function nested in an Effect body (section 13). In JavaScript it
            // stays a syntax error, as test262 expects.
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
