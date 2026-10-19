//! Programs of the IR, compiled and run without a VM.

use std::sync::Arc;

use buoy_jit_ir::{Bail, Binary, Class, Expr, Function, MathFn, Method, Program, Stmt, Ty, Unary};

use crate::codegen::compile;
use crate::run::{Context, Finished, Step, Value};

fn local(index: u32) -> Expr {
    Expr::Local(index)
}

fn num(value: f64) -> Expr {
    Expr::Num(value)
}

fn bin(op: Binary, left: Expr, right: Expr) -> Expr {
    Expr::Binary(op, left.into(), right.into())
}

fn set(local: u32, value: Expr) -> Stmt {
    Stmt::Expr(Expr::SetLocal(local, value.into()))
}

/// The step of a run that ends with `result` and gives back nothing else.
fn done(result: Value) -> Step {
    Step::Done(Box::new(Finished {
        result,
        written: vec![],
        items: vec![],
    }))
}

/// Runs the first entry to its end, and counts the slices after the first.
fn run(program: &Program, args: &[Value], globals: &[Value]) -> (Step, usize) {
    let code = Arc::new(compile(program).expect("the program compiles"));
    let mut context = Context::new(64 << 20);
    let mut step = context
        .start(&code, 0, args, globals, &[])
        .expect("the run starts");
    let mut slices = 0;
    while step == Step::Yield {
        slices += 1;
        step = context.resume();
    }
    (step, slices)
}

/// `function sum(n) { let total = 0; for (let i = 0; i < n; i++) total += i * k; return total; }`
/// with `k` a global.
fn sum_program() -> Program {
    Program {
        classes: vec![],
        functions: vec![Function {
            name: "sum".to_owned(),
            receiver: false,
            params: 1,
            locals: vec![Ty::Num, Ty::Num, Ty::Num],
            result: Ty::Num,
            body: vec![
                set(1, num(0.0)),
                set(2, num(0.0)),
                Stmt::Loop {
                    cond: Some(bin(Binary::Lt, local(2), local(0))),
                    body: vec![set(
                        1,
                        bin(
                            Binary::Add,
                            local(1),
                            bin(Binary::Mul, local(2), Expr::Global(0)),
                        ),
                    )],
                    update: vec![set(2, bin(Binary::Add, local(2), num(1.0)))],
                    test_after: false,
                },
                Stmt::Return(Some(Expr::Local(1))),
            ],
        }],
        entries: vec![0],
        globals: vec![Ty::Num],
    }
}

#[test]
fn a_loop_runs_to_its_result_over_many_slices() {
    let (step, slices) = run(&sum_program(), &[Value::Num(2e7)], &[Value::Num(2.0)]);
    let n = 2e7_f64;
    assert_eq!(step, done(Value::Num(n * (n - 1.0))));
    assert!(slices > 0, "a run of 20 million turns yields");
}

#[test]
fn arguments_of_another_type_do_not_start() {
    let code = Arc::new(compile(&sum_program()).expect("the program compiles"));
    let mut context = Context::new(1 << 20);
    assert!(
        context
            .start(&code, 0, &[Value::Bool(true)], &[Value::Num(1.0)], &[])
            .is_none()
    );
    assert!(
        context
            .start(&code, 0, &[], &[Value::Num(1.0)], &[])
            .is_none()
    );
}

fn field(object: Expr, class: u32, index: u32) -> Expr {
    Expr::Field(object.into(), class, index)
}

fn set_field(object: Expr, class: u32, index: u32, value: Expr) -> Stmt {
    Stmt::Expr(Expr::SetField(object.into(), class, index, value.into()))
}

fn counted(count: Expr, body: Vec<Stmt>) -> Stmt {
    Stmt::Loop {
        cond: Some(bin(Binary::Lt, local(2), count)),
        body,
        update: vec![set(2, bin(Binary::Add, local(2), num(1.0)))],
        test_after: false,
    }
}

const POINT: u32 = 0;
const SCALED: u32 = 1;

/// A class `Point { x; y }` with a method `norm`, a subclass `Scaled` that overrides it,
/// and an array of both, summed through a dispatch.
fn shapes_program() -> Program {
    let method = |function| {
        vec![Method {
            name: "norm".to_owned(),
            function,
        }]
    };
    Program {
        classes: vec![
            Class {
                name: "Point".to_owned(),
                parent: None,
                fields: vec![Ty::Num, Ty::Num],
                methods: method(1),
            },
            Class {
                name: "Scaled".to_owned(),
                parent: Some(POINT),
                fields: vec![Ty::Num, Ty::Num, Ty::Num],
                methods: method(3),
            },
        ],
        functions: vec![
            shapes_entry(),
            point_norm(),
            constructor("Point", POINT, 2),
            scaled_norm(),
            constructor("Scaled", SCALED, 3),
        ],
        entries: vec![0],
        globals: vec![],
    }
}

/// `entry(n)`: an array of n points and n scaled points, and the sum of their norms.
fn shapes_entry() -> Function {
    let point = |args: Vec<Expr>| Box::new(Expr::New(POINT, 2, args));
    let scaled = |args: Vec<Expr>| Box::new(Expr::New(SCALED, 4, args));
    Function {
        name: "entry".to_owned(),
        receiver: false,
        params: 1,
        locals: vec![
            Ty::Num,
            Ty::Array(Box::new(Ty::Object(POINT))),
            Ty::Num,
            Ty::Num,
        ],
        result: Ty::Num,
        body: vec![
            set(1, Expr::ArrayOf(Ty::Object(POINT), vec![])),
            set(2, num(0.0)),
            counted(
                local(0),
                vec![
                    Stmt::Expr(Expr::Push(local(1).into(), point(vec![num(3.0), num(4.0)]))),
                    Stmt::Expr(Expr::Push(
                        local(1).into(),
                        scaled(vec![num(3.0), num(4.0), num(2.0)]),
                    )),
                ],
            ),
            set(3, num(0.0)),
            set(2, num(0.0)),
            counted(
                Expr::Length(local(1).into()),
                vec![set(
                    3,
                    bin(
                        Binary::Add,
                        local(3),
                        Expr::Dispatch {
                            method: "norm".to_owned(),
                            args: vec![Expr::Index(local(1).into(), local(2).into())],
                            result: Ty::Num,
                        },
                    ),
                )],
            ),
            Stmt::Return(Some(local(3))),
        ],
    }
}

fn point_norm() -> Function {
    let square = |index| {
        bin(
            Binary::Mul,
            field(local(0), POINT, index),
            field(local(0), POINT, index),
        )
    };
    Function {
        name: "Point.norm".to_owned(),
        receiver: true,
        params: 1,
        locals: vec![Ty::Object(POINT)],
        result: Ty::Num,
        body: vec![Stmt::Return(Some(Expr::Math(
            MathFn::Sqrt,
            vec![bin(Binary::Add, square(0), square(1))],
        )))],
    }
}

/// The norm of the point times the factor.
fn scaled_norm() -> Function {
    Function {
        name: "Scaled.norm".to_owned(),
        receiver: true,
        params: 1,
        locals: vec![Ty::Object(SCALED)],
        result: Ty::Num,
        body: vec![Stmt::Return(Some(bin(
            Binary::Mul,
            Expr::Call(1, vec![local(0)]),
            field(local(0), SCALED, 2),
        )))],
    }
}

/// `constructor(this, ...fields)`: a subclass calls the constructor of its parent first.
fn constructor(name: &str, class: u32, fields: u32) -> Function {
    let mut body = Vec::new();
    let own = if class == SCALED {
        body.push(Stmt::Expr(Expr::Call(
            2,
            vec![local(0), local(1), local(2)],
        )));
        2
    } else {
        0
    };
    for index in own..fields {
        body.push(set_field(local(0), class, index, local(index + 1)));
    }
    let mut locals = vec![Ty::Object(class)];
    locals.extend((0..fields).map(|_| Ty::Num));
    Function {
        name: name.to_owned(),
        receiver: true,
        params: fields + 1,
        locals,
        result: Ty::Void,
        body,
    }
}

#[test]
fn objects_arrays_and_dispatch_compute_in_the_heap() {
    let (step, _) = run(&shapes_program(), &[Value::Num(10_000.0)], &[]);
    assert_eq!(step, done(Value::Num(10_000.0 * (5.0 + 10.0))));
}

#[test]
fn a_heap_past_its_limit_bails() {
    let code = Arc::new(compile(&shapes_program()).expect("the program compiles"));
    let mut context = Context::new(4 << 20);
    let mut step = context
        .start(&code, 0, &[Value::Num(1e7)], &[], &[])
        .expect("the run starts");
    while step == Step::Yield {
        step = context.resume();
    }
    assert_eq!(step, Step::Bail(Bail::Memory));
    // The context runs again after a bail.
    let mut step = context
        .start(&code, 0, &[Value::Num(2.0)], &[], &[])
        .expect("the run starts");
    while step == Step::Yield {
        step = context.resume();
    }
    assert_eq!(step, done(Value::Num(30.0)));
}

/// `function f(n) { const a = [1, 2]; return a[n] + (null).x; }` without the null part when
/// `n` is not 7.
fn bails_program() -> Program {
    Program {
        classes: vec![Class {
            name: "Box".to_owned(),
            parent: None,
            fields: vec![Ty::Num],
            methods: vec![],
        }],
        functions: vec![Function {
            name: "f".to_owned(),
            receiver: false,
            params: 1,
            locals: vec![Ty::Num, Ty::Array(Box::new(Ty::Num)), Ty::Object(0)],
            result: Ty::Num,
            body: vec![
                set(1, Expr::ArrayOf(Ty::Num, vec![num(1.0), num(2.0)])),
                Stmt::If(
                    bin(Binary::Eq, local(0), num(7.0)),
                    vec![Stmt::Return(Some(field(local(2), 0, 0)))],
                    vec![],
                ),
                Stmt::If(
                    bin(Binary::Eq, local(0), num(8.0)),
                    vec![Stmt::Bail(Bail::Throw)],
                    vec![],
                ),
                Stmt::Return(Some(Expr::Index(local(1).into(), local(0).into()))),
            ],
        }],
        entries: vec![0],
        globals: vec![],
    }
}

#[test]
fn reads_outside_the_heap_bail() {
    let program = bails_program();
    assert_eq!(
        run(&program, &[Value::Num(1.0)], &[]).0,
        done(Value::Num(2.0))
    );
    assert_eq!(
        run(&program, &[Value::Num(-0.0)], &[]).0,
        done(Value::Num(1.0))
    );
    assert_eq!(
        run(&program, &[Value::Num(2.0)], &[]).0,
        Step::Bail(Bail::Index)
    );
    assert_eq!(
        run(&program, &[Value::Num(0.5)], &[]).0,
        Step::Bail(Bail::Index)
    );
    assert_eq!(
        run(&program, &[Value::Num(7.0)], &[]).0,
        Step::Bail(Bail::Nullish)
    );
    assert_eq!(
        run(&program, &[Value::Num(8.0)], &[]).0,
        Step::Bail(Bail::Throw)
    );
}

#[test]
fn deep_recursion_bails_with_the_stack() {
    // function down(n) { return n === 0 ? 0 : 1 + down(n - 1); }
    let program = Program {
        classes: vec![],
        functions: vec![Function {
            name: "down".to_owned(),
            receiver: false,
            params: 1,
            locals: vec![Ty::Num],
            result: Ty::Num,
            body: vec![Stmt::Return(Some(Expr::Cond(
                Ty::Num,
                bin(Binary::Eq, local(0), num(0.0)).into(),
                num(0.0).into(),
                bin(
                    Binary::Add,
                    num(1.0),
                    Expr::Call(0, vec![bin(Binary::Sub, local(0), num(1.0))]),
                )
                .into(),
            )))],
        }],
        entries: vec![0],
        globals: vec![],
    };
    assert_eq!(
        run(&program, &[Value::Num(1000.0)], &[]).0,
        done(Value::Num(1000.0))
    );
    assert_eq!(
        run(&program, &[Value::Num(1e9)], &[]).0,
        Step::Bail(Bail::Stack)
    );
}

#[test]
fn bitwise_operators_wrap_like_javascript() {
    // function f(a, b) { return ((a | 0) ^ ~b) >>> 1 << 3 >> 2; }
    let expr = bin(
        Binary::Shr,
        bin(
            Binary::Shl,
            bin(
                Binary::UShr,
                bin(
                    Binary::BitXor,
                    bin(Binary::BitOr, local(0), num(0.0)),
                    Expr::Unary(Unary::BitNot, local(1).into()),
                ),
                num(1.0),
            ),
            num(3.0),
        ),
        num(2.0),
    );
    let program = Program {
        classes: vec![],
        functions: vec![Function {
            name: "f".to_owned(),
            receiver: false,
            params: 2,
            locals: vec![Ty::Num, Ty::Num],
            result: Ty::Num,
            body: vec![Stmt::Return(Some(expr))],
        }],
        entries: vec![0],
        globals: vec![],
    };
    let reference = |a: f64, b: f64| -> f64 {
        let x = buoy_jit_ir::to_int32(a) ^ !buoy_jit_ir::to_int32(b);
        let unsigned = u32::from_ne_bytes(x.to_ne_bytes()) >> 1;
        let shifted = i32::from_ne_bytes(unsigned.to_ne_bytes()).wrapping_shl(3);
        f64::from(shifted >> 2)
    };
    for (a, b) in [
        (5.0, 9.0),
        (-1.5, 3e10),
        (1e20, f64::NAN),
        (4_294_967_296.5, -7.0),
    ] {
        assert_eq!(
            run(&program, &[Value::Num(a), Value::Num(b)], &[]).0,
            done(Value::Num(reference(a, b))),
            "{a} {b}"
        );
    }
}

/// Counts the `i` in `[0, n)` with `(i & 3) === 1 || !((i | 0) >= 5 && (i >> 1) < 4)`: the
/// comparisons of int32s and the jumps of `&&`, `||`, and `!` give what doubles give.
#[test]
fn int_compares_and_short_circuits_agree_with_doubles() {
    let int = |op, value: Expr, by: f64| bin(op, value, num(by));
    let test = Expr::Or(
        Box::new(bin(
            Binary::Eq,
            int(Binary::BitAnd, local(2), 3.0),
            num(1.0),
        )),
        Box::new(Expr::Unary(
            Unary::Not,
            Box::new(Expr::And(
                Box::new(bin(Binary::Ge, int(Binary::BitOr, local(2), 0.0), num(5.0))),
                Box::new(bin(Binary::Lt, int(Binary::Shr, local(2), 1.0), num(4.0))),
            )),
        )),
    );
    let program = Program {
        classes: vec![],
        functions: vec![Function {
            name: "count".to_owned(),
            receiver: false,
            params: 1,
            locals: vec![Ty::Num, Ty::Num, Ty::Num],
            result: Ty::Num,
            body: vec![
                counted(
                    local(0),
                    vec![Stmt::If(
                        test,
                        vec![set(1, bin(Binary::Add, local(1), num(1.0)))],
                        vec![],
                    )],
                ),
                Stmt::Return(Some(local(1))),
            ],
        }],
        entries: vec![0],
        globals: vec![],
    };
    let expected = (0..40)
        .filter(|i| i & 3 == 1 || !(*i >= 5 && (i >> 1) < 4))
        .count();
    let (step, _) = run(&program, &[Value::Num(40.0)], &[]);
    assert_eq!(
        step,
        done(Value::Num(f64::from(u32::try_from(expected).unwrap_or(0))))
    );
}

fn text(value: &str) -> Vec<u16> {
    value.encode_utf16().collect()
}

/// `class Node { value: number; next: Node | null; name: string }` and an entry that pushes
/// a new node onto the list in the global `head`, renames the old head, and reports
/// facts about the strings it builds.
fn nodes_program() -> Program {
    const NODE: u32 = 0;
    let node = Ty::Object(NODE);
    let this = local(0);
    let constructor = Function {
        name: "Node.constructor".to_owned(),
        receiver: true,
        params: 4,
        locals: vec![node.clone(), Ty::Num, node.clone(), Ty::Str],
        result: Ty::Void,
        body: vec![
            set_field(this.clone(), NODE, 0, local(1)),
            set_field(this.clone(), NODE, 1, local(2)),
            set_field(this, NODE, 2, local(3)),
        ],
    };
    let label = Expr::Text(vec![Expr::Str(text("n")), local(0), Expr::Bool(true)]);
    let pushed = Expr::SetGlobal(
        0,
        Box::new(Expr::New(
            NODE,
            1,
            vec![local(0), Expr::Global(0), label.clone()],
        )),
    );
    let entry = Function {
        name: "push".to_owned(),
        receiver: false,
        params: 1,
        locals: vec![Ty::Num, Ty::Array(Box::new(Ty::Str)), Ty::Str],
        result: Ty::Num,
        body: vec![
            Stmt::Expr(pushed),
            // The old head, now `head.next`, gets a new name: the global string twice.
            set_field(
                field(Expr::Global(0), NODE, 1),
                NODE,
                2,
                Expr::Text(vec![Expr::Global(1), Expr::Global(1)]),
            ),
            set(
                1,
                Expr::ArrayOf(
                    Ty::Str,
                    vec![Expr::Str(text("a")), Expr::Str(text("")), Expr::Null],
                ),
            ),
            set(2, Expr::Shift(Box::new(local(1)))),
            // 1 when the label is equal to a new string of the same units, 2 when the
            // shifted string is "a", 4 when the remaining first string is falsy.
            Stmt::Return(Some(bin(
                Binary::Add,
                Expr::Cond(
                    Ty::Num,
                    Box::new(bin(
                        Binary::Eq,
                        field(Expr::Global(0), NODE, 2),
                        Expr::Text(vec![Expr::Str(text("n5true"))]),
                    )),
                    Box::new(num(1.0)),
                    Box::new(num(0.0)),
                ),
                bin(
                    Binary::Add,
                    Expr::Cond(
                        Ty::Num,
                        Box::new(bin(Binary::Eq, local(2), Expr::Str(text("a")))),
                        Box::new(num(2.0)),
                        Box::new(num(0.0)),
                    ),
                    Expr::Cond(
                        Ty::Num,
                        Box::new(Expr::Unary(
                            Unary::Truthy,
                            Box::new(Expr::Index(Box::new(local(1)), Box::new(num(0.0)))),
                        )),
                        Box::new(num(0.0)),
                        Box::new(num(4.0)),
                    ),
                ),
            ))),
        ],
    };
    Program {
        classes: vec![Class {
            name: "Node".to_owned(),
            parent: None,
            fields: vec![Ty::Num, node.clone(), Ty::Str],
            methods: vec![],
        }],
        functions: vec![entry, constructor],
        entries: vec![0],
        globals: vec![node, Ty::Str],
    }
}

#[test]
fn objects_cross_by_copy_and_come_back_with_their_changes() {
    use crate::boundary::Item;
    let code = Arc::new(compile(&nodes_program()).expect("the program compiles"));
    let mut context = Context::new(1 << 20);
    let first = Item::Object {
        class: 0,
        fields: vec![Value::Num(1.0), Value::Null, Value::Str(text("first"))],
    };
    let step = context
        .start(
            &code,
            0,
            &[Value::Num(5.0)],
            &[Value::Ref(0), Value::Str(text("hé☃"))],
            &[first],
        )
        .expect("the run starts");
    let expected = Finished {
        result: Value::Num(7.0),
        written: vec![Value::Ref(1)],
        items: vec![
            Item::Object {
                class: 0,
                fields: vec![Value::Num(1.0), Value::Null, Value::Str(text("hé☃hé☃"))],
            },
            Item::Object {
                class: 0,
                fields: vec![Value::Num(5.0), Value::Ref(0), Value::Str(text("n5true"))],
            },
        ],
    };
    assert_eq!(step, Step::Done(Box::new(expected)));
}

#[test]
fn items_of_another_type_do_not_start() {
    use crate::boundary::Item;
    let code = Arc::new(compile(&nodes_program()).expect("the program compiles"));
    let mut context = Context::new(1 << 20);
    let wrong_field = Item::Object {
        class: 0,
        fields: vec![Value::Str(text("1")), Value::Null, Value::Str(text("x"))],
    };
    let globals = [Value::Ref(0), Value::Str(text(""))];
    assert!(
        context
            .start(&code, 0, &[Value::Num(1.0)], &globals, &[wrong_field])
            .is_none()
    );
    let array = Item::Array(vec![]);
    assert!(
        context
            .start(&code, 0, &[Value::Num(1.0)], &globals, &[array])
            .is_none()
    );
    let unreached = Item::Array(vec![]);
    assert!(
        context
            .start(
                &code,
                0,
                &[Value::Num(1.0)],
                &[Value::Null, Value::Null],
                &[unreached]
            )
            .is_none()
    );
}
