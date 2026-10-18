//! The minimizer: it deletes statements and simplifies expressions while the mismatch stays.

use crate::program::Program;

/// The smallest program that `reproduces` accepts, found from `program`, which it accepts.
/// It deletes halves, then quarters, and so on, of the statements, then replaces one
/// expression at a time with a simpler one until no simpler program reproduces. It repeats
/// both steps until neither changes the program, because a run that timed out under load
/// can refuse a deletion that the run of a simpler program accepts.
pub fn minimize(program: Program, mut reproduces: impl FnMut(&Program) -> bool) -> Program {
    let mut current = program;
    loop {
        let before = current.clone();
        current = simplify(delete(current, &mut reproduces), &mut reproduces);
        if current == before {
            return current;
        }
    }
}

fn delete(mut current: Program, reproduces: &mut impl FnMut(&Program) -> bool) -> Program {
    let mut chunk = current.0.len() / 2;
    while chunk > 0 {
        let mut start = 0;
        while start < current.0.len() {
            let mut candidate = current.clone();
            candidate
                .0
                .drain(start..(start + chunk).min(current.0.len()));
            if !candidate.0.is_empty() && reproduces(&candidate) {
                current = candidate;
            } else {
                start += chunk;
            }
        }
        chunk /= 2;
    }
    current
}

fn simplify(mut current: Program, reproduces: &mut impl FnMut(&Program) -> bool) -> Program {
    while let Some(simpler) = current
        .simpler()
        .into_iter()
        .find(|candidate| reproduces(candidate))
    {
        current = simpler;
    }
    current
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::program::Expr;

    fn number(text: &str) -> Expr {
        Expr::Number(text.to_owned())
    }

    #[test]
    fn the_statement_and_the_expression_that_mismatch_remain() {
        let fixed = Expr::Method(
            Box::new(Expr::Binary(
                "+",
                Box::new(number("1.005")),
                Box::new(number("7")),
            )),
            "toFixed",
            vec![number("2")],
        );
        let program = Program(vec![
            number("1"),
            Expr::string("a"),
            fixed,
            Expr::Atom("NaN".to_owned()),
        ]);
        let mut checks = 0;
        let minimized = minimize(program, |candidate| {
            checks += 1;
            let source = candidate.source();
            source.contains("toFixed") && source.contains("1.005")
        });
        assert_eq!(minimized.source(), "console.log((1.005).toFixed());\n");
        assert!(checks < 30, "{checks} checks");
    }

    #[test]
    fn a_deletion_refused_once_is_tried_again_after_the_simplification() {
        let program = Program(vec![number("12"), number("34")]);
        // The first two one-statement runs time out, as under load.
        let mut refusals = 2;
        let minimized = minimize(program, |candidate| {
            if candidate.0.len() == 1 && refusals > 0 {
                refusals -= 1;
                return false;
            }
            candidate.source().contains("12")
        });
        assert_eq!(minimized.source(), "console.log(12);\n");
    }
}
