//! Annex B, Runtime Errors for Function Call Assignment Targets: in sloppy code, a call
//! as the target of an assignment, an update, or the head of a `for-in` or `for-of`
//! loop is no early error. The call runs, then a `ReferenceError` ends the assignment.
//! oxc rejects such a target, so the parser rewrites `f()` to `f()[SENTINEL]` and parses
//! again, and the lowering throws where the key reads the sentinel, as V8 rewrites the
//! target to `f()[throw ReferenceError]` (`RewriteInvalidReferenceExpression`).

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

/// The source with `[SENTINEL]` after each call that oxc rejects as an assignment
/// target, or `None` when another error remains. A source that names the sentinel
/// itself must not be rewritten (`is_free`).
pub fn rewrite(source: &str, diagnostics: &Diagnostics) -> Option<String> {
    let mut ends = Vec::new();
    for error in diagnostics.errors() {
        if error.message != "Cannot assign to this expression" {
            return None;
        }
        let label = error.labels.first()?;
        let start = label.offset() as usize;
        let end = start + label.len() as usize;
        if !is_call(source.get(start..end)?) || is_logical_target(&source[end..]) {
            return None;
        }
        ends.push(end);
    }
    ends.sort_unstable();
    ends.dedup();
    let mut rewritten = source.to_owned();
    for end in ends.iter().rev() {
        rewritten.insert_str(*end, &format!("[{SENTINEL}]"));
    }
    Some(rewritten)
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
        }
        _ => true,
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
}

