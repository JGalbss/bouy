//! Source that JavaScript allows and oxc rejects. The parser rewrites each such place that
//! oxc reports into source with the same meaning that oxc accepts, then parses again.
//!
//! - Annex B, Runtime Errors for Function Call Assignment Targets: in sloppy code, a call
//!   as the target of an assignment, an update, or the head of a `for-in` or `for-of`
//!   loop is no early error. The call runs, then a `ReferenceError` ends the assignment.
//!   `f()` becomes `f()[SENTINEL]`, and the lowering throws where the key reads the
//!   sentinel, as V8 rewrites the target to `f()[throw ReferenceError]`
//!   (`RewriteInvalidReferenceExpression`).
//! - A label named `let` in sloppy code, `let: x`, which oxc reads as the start of a
//!   declaration. `let` becomes `l\u0065t`, the same name, which oxc reads as a label and
//!   still rejects in strict code.

use oxc::allocator::Allocator;
use oxc::ast::AstKind;
use oxc::ast::ast::{Expression, Statement};
use oxc::diagnostics::Diagnostics;
use oxc::parser::Parser;
use oxc::semantic::Semantic;
use oxc::span::SourceType;

// shortcut: the rewritten text is the source of the program, so the toString of a
// function around such a target shows the sentinel and later columns of its line shift;
// map spans back to the original text if a program ever depends on either.

/// The name that stands for the key of a rewritten target.
pub const SENTINEL: &str = "__buoy_invalid_assignment_target";

/// The message of a `ReferenceError` from a rewritten target.
pub const MESSAGE: &str = "Invalid left-hand side in assignment";

/// The source with each place that oxc reported rewritten, or `None` when an error is no
/// such place. A source that names the sentinel itself must not be rewritten
/// (`is_free`).
pub fn rewrite(source: &str, diagnostics: &Diagnostics) -> Option<String> {
    let mut edits = Vec::new();
    for error in diagnostics.errors() {
        let label = error.labels.first()?;
        let start = label.offset() as usize;
        let end = start + label.len() as usize;
        let edit = match error.message.as_ref() {
            "Cannot assign to this expression" => call_target(source, start, end)?,
            _ => let_label(source, start)?,
        };
        edits.push(edit);
    }
    edits.sort_unstable();
    edits.dedup();
    let mut rewritten = source.to_owned();
    for (at, removed, text) in edits.iter().rev() {
        rewritten.replace_range(*at..*at + *removed, text);
    }
    Some(rewritten)
}

/// The edit `(offset, removed length, text)` that makes the call at `start..end` a
/// member target whose key throws.
fn call_target(source: &str, start: usize, end: usize) -> Option<(usize, usize, String)> {
    let is_target = is_call(source.get(start..end)?) && !is_logical_target(&source[end..]);
    is_target.then(|| (end, 0, format!("[{SENTINEL}]")))
}

/// The edit that escapes the `let` before the colon at or after `at`, when the error is
/// oxc's reading of a `let` label as a declaration.
fn let_label(source: &str, at: usize) -> Option<(usize, usize, String)> {
    let rest = source.get(at..)?;
    let colon = at + rest.len() - rest.trim_start().len();
    if !source[colon..].starts_with(':') {
        return None;
    }
    let before = source[..colon].trim_end();
    let word = before.strip_suffix("let")?;
    let separate = !word
        .chars()
        .next_back()
        .is_some_and(|c| c.is_alphanumeric() || c == '_' || c == '$' || c == '\\');
    separate.then(|| (word.len(), 3, "l\\u0065t".to_owned()))
}

/// Whether `source` leaves the sentinel free for a rewrite.
pub fn is_free(source: &str) -> bool {
    !source.contains(SENTINEL)
}

/// Whether the target that `rest` follows is the target of `&&=`, `||=`, or `??=`, which
/// is an early error for a call in any code.
fn is_logical_target(rest: &str) -> bool {
    let operator = rest.trim_start_matches(|c: char| c == ')' || c.is_whitespace());
    ["&&=", "||=", "??="].iter().any(|logical| operator.starts_with(logical))
}

/// Whether `text` is one call, perhaps in parentheses: no tagged template, no optional
/// call, no `super()` or `import()`.
fn is_call(text: &str) -> bool {
    let allocator = Allocator::default();
    let wrapped = format!("({text})");
    let parsed = Parser::new(&allocator, &wrapped, SourceType::script()).parse();
    if parsed.fatal_error || parsed.diagnostics.has_errors() {
        return false;
    }
    let [Statement::ExpressionStatement(statement)] = parsed.program.body.as_slice() else {
        return false;
    };
    let mut expression = &statement.expression;
    while let Expression::ParenthesizedExpression(inner) = expression {
        expression = &inner.expression;
    }
    matches!(expression, Expression::CallExpression(call) if !call.optional)
}

/// Whether every rewritten target is in sloppy code; in strict code the target stays an
/// early error.
pub fn are_sloppy(semantic: &Semantic<'_>) -> bool {
    let scoping = semantic.scoping();
    semantic.nodes().iter().all(|node| match node.kind() {
        AstKind::IdentifierReference(reference) if reference.name == SENTINEL => {
            !scoping.scope_flags(node.scope_id()).is_strict_mode()
                && !is_destructured(semantic, node.id())
        }
        _ => true,
    })
}

/// Whether the rewritten target of the sentinel `id` is an element of a destructuring
/// pattern, where a call stays an early error in sloppy code too: Annex B covers only the
/// target of an assignment, an update, and the head of a `for-in` or `for-of` loop.
fn is_destructured(semantic: &Semantic<'_>, id: oxc::semantic::NodeId) -> bool {
    semantic
        .nodes()
        .ancestor_kinds(id)
        .find(|kind| {
            !matches!(
                kind,
                AstKind::ComputedMemberExpression(_) | AstKind::ParenthesizedExpression(_)
            )
        })
        .is_some_and(|kind| {
            matches!(
                kind,
                AstKind::ArrayAssignmentTarget(_)
                    | AstKind::ObjectAssignmentTarget(_)
                    | AstKind::AssignmentTargetWithDefault(_)
                    | AstKind::AssignmentTargetPropertyProperty(_)
                    | AstKind::AssignmentTargetRest(_)
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rewritten(source: &str) -> Option<String> {
        let allocator = Allocator::default();
        let parsed = Parser::new(&allocator, source, SourceType::script()).parse();
        rewrite(source, &parsed.diagnostics)
    }

    #[test]
    fn rewrites_a_call_target_but_not_a_logical_one() {
        assert_eq!(
            rewritten("f() = 1;").as_deref(),
            Some("f()[__buoy_invalid_assignment_target] = 1;")
        );
        assert_eq!(
            rewritten("(async()) += 1;").as_deref(),
            Some("(async()[__buoy_invalid_assignment_target]) += 1;")
        );
        assert_eq!(rewritten("f() &&= 1;"), None);
        assert_eq!(rewritten("f`x` = 1;"), None);
    }

    #[test]
    fn escapes_a_let_label() {
        assert_eq!(rewritten("let: 42").as_deref(), Some("l\\u0065t: 42"));
        assert_eq!(rewritten("while (0) let \n : 1").as_deref(), Some("while (0) l\\u0065t \n : 1"));
        assert_eq!(rewritten("x = 1 2;"), None);
    }
}

