use std::path::Path;

use bouy_compiler::compile;

fn compiled(fixture: &str) -> bouy_compiler::Output {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(fixture);
    let source = std::fs::read_to_string(&path).expect("fixture exists");
    compile(&path, &source).expect("fixture compiles")
}

#[test]
fn lowers_an_actor_module() {
    let output = compiled("research-agent.ts");
    insta::assert_snapshot!(output.code);
    assert_eq!(output.preemption_points, 2);
    assert_eq!(output.located_classes, ["ResearchAgent", "Hidden"]);
}

#[test]
fn leaves_a_module_without_async_loops_or_exported_classes_unchanged_in_shape() {
    let path = Path::new("plain.ts");
    let output = compile(
        path,
        "const total: number = [1, 2].reduce((a, b) => a + b, 0);\n",
    )
    .expect("plain module compiles");
    assert_eq!(
        output.code,
        "const total = [1, 2].reduce((a, b) => a + b, 0);\n"
    );
    assert_eq!(output.preemption_points, 0);
}

#[test]
fn reports_syntax_errors_with_positions() {
    let diagnostics = compile(Path::new("broken.ts"), "const a = ;\n").expect_err("syntax error");
    assert_eq!(diagnostics.len(), 1);
    assert_eq!((diagnostics[0].line, diagnostics[0].column), (1, 11));
}
