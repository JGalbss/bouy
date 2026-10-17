//! DeltaBlue with the objects of `bench/speed/kernels/deltablue.ts` in two arenas: a
//! variable or a constraint is an index. The four constraint classes are one enum, so a
//! method call is a match on the kind, as a backend with whole-program knowledge of the
//! classes would emit. Strength is the integer of its strengthValue.

use std::collections::VecDeque;

const REQUIRED: u8 = 0;
const PREFERRED: u8 = 2;
const STRONG_DEFAULT: u8 = 3;
const NORMAL: u8 = 4;
const WEAKEST: u8 = 6;

const NONE: i8 = 0;
const FORWARD: i8 = 1;
const BACKWARD: i8 = -1;

fn stronger(s1: u8, s2: u8) -> bool {
    s1 < s2
}

fn weaker(s1: u8, s2: u8) -> bool {
    s1 > s2
}

fn weakest_of(s1: u8, s2: u8) -> u8 {
    if weaker(s1, s2) { s1 } else { s2 }
}

// Octane's table: REQUIRED steps to WEAKEST, so incrementalRemove makes one pass.
fn next_weaker(strength: u8) -> u8 {
    match strength {
        0 => WEAKEST,
        1 => 5,
        2 => 4,
        3 => 3,
        4 => 2,
        _ => REQUIRED,
    }
}

struct Variable {
    value: f64,
    constraints: Vec<usize>,
    determined_by: Option<usize>,
    mark: u32,
    walk_strength: u8,
    stay: bool,
    #[allow(dead_code)]
    name: String,
}

#[derive(Clone, Copy)]
enum Kind {
    Stay,
    Edit,
    Equality,
    Scale { scale: usize, offset: usize },
}

/// For a unary constraint, `v1` is the output and `satisfied` holds its state; a binary
/// constraint uses `v1`, `v2`, and `direction`.
struct Constraint {
    kind: Kind,
    strength: u8,
    v1: usize,
    v2: usize,
    direction: i8,
    satisfied: bool,
}

struct Planner {
    variables: Vec<Variable>,
    constraints: Vec<Constraint>,
    current_mark: u32,
}

impl Planner {
    fn new() -> Self {
        Self {
            variables: Vec::new(),
            constraints: Vec::new(),
            current_mark: 0,
        }
    }

    fn variable(&mut self, name: String, value: f64) -> usize {
        self.variables.push(Variable {
            value,
            constraints: Vec::new(),
            determined_by: None,
            mark: 0,
            walk_strength: WEAKEST,
            stay: true,
            name,
        });
        self.variables.len() - 1
    }

    fn constraint(&mut self, kind: Kind, strength: u8, v1: usize, v2: usize) -> usize {
        self.constraints.push(Constraint {
            kind,
            strength,
            v1,
            v2,
            direction: NONE,
            satisfied: false,
        });
        let c = self.constraints.len() - 1;
        self.add_to_graph(c);
        self.incremental_add(c);
        c
    }

    fn unary(&self, c: usize) -> bool {
        matches!(self.constraints[c].kind, Kind::Stay | Kind::Edit)
    }

    fn add_to_graph(&mut self, c: usize) {
        let Constraint { kind, v1, v2, .. } = self.constraints[c];
        self.variables[v1].constraints.push(c);
        if let Kind::Stay | Kind::Edit = kind {
            self.constraints[c].satisfied = false;
            return;
        }
        self.variables[v2].constraints.push(c);
        self.constraints[c].direction = NONE;
        if let Kind::Scale { scale, offset } = kind {
            self.variables[scale].constraints.push(c);
            self.variables[offset].constraints.push(c);
        }
    }

    fn remove_from_graph(&mut self, c: usize) {
        let Constraint { kind, v1, v2, .. } = self.constraints[c];
        self.remove_constraint(v1, c);
        if let Kind::Stay | Kind::Edit = kind {
            self.constraints[c].satisfied = false;
            return;
        }
        self.remove_constraint(v2, c);
        self.constraints[c].direction = NONE;
        if let Kind::Scale { scale, offset } = kind {
            self.remove_constraint(scale, c);
            self.remove_constraint(offset, c);
        }
    }

    fn remove_constraint(&mut self, v: usize, c: usize) {
        let variable = &mut self.variables[v];
        variable.constraints.retain(|&each| each != c);
        if variable.determined_by == Some(c) {
            variable.determined_by = None;
        }
    }

    fn choose_method(&mut self, c: usize, mark: u32) {
        let Constraint {
            strength, v1, v2, ..
        } = self.constraints[c];
        if self.unary(c) {
            let out = &self.variables[v1];
            self.constraints[c].satisfied =
                out.mark != mark && stronger(strength, out.walk_strength);
            return;
        }
        // The first two ifs of Octane's chooseMethod are dead stores: this one always wins.
        let (w1, w2) = (
            self.variables[v1].walk_strength,
            self.variables[v2].walk_strength,
        );
        self.constraints[c].direction = if weaker(w1, w2) {
            if stronger(strength, w1) {
                BACKWARD
            } else {
                NONE
            }
        } else if stronger(strength, w2) {
            FORWARD
        } else {
            BACKWARD
        };
    }

    fn is_satisfied(&self, c: usize) -> bool {
        if self.unary(c) {
            self.constraints[c].satisfied
        } else {
            self.constraints[c].direction != NONE
        }
    }

    fn input(&self, c: usize) -> usize {
        let constraint = &self.constraints[c];
        if constraint.direction == FORWARD {
            constraint.v1
        } else {
            constraint.v2
        }
    }

    fn output(&self, c: usize) -> usize {
        let constraint = &self.constraints[c];
        if self.unary(c) || constraint.direction != FORWARD {
            constraint.v1
        } else {
            constraint.v2
        }
    }

    fn mark_inputs(&mut self, c: usize, mark: u32) {
        if self.unary(c) {
            return;
        }
        let input = self.input(c);
        self.variables[input].mark = mark;
        if let Kind::Scale { scale, offset } = self.constraints[c].kind {
            self.variables[scale].mark = mark;
            self.variables[offset].mark = mark;
        }
    }

    fn mark_unsatisfied(&mut self, c: usize) {
        self.constraints[c].satisfied = false;
        self.constraints[c].direction = NONE;
    }

    fn inputs_known(&self, c: usize, mark: u32) -> bool {
        if self.unary(c) {
            return true;
        }
        let input = &self.variables[self.input(c)];
        input.mark == mark || input.stay || input.determined_by.is_none()
    }

    fn recalculate(&mut self, c: usize) {
        let Constraint {
            kind, strength, v1, ..
        } = self.constraints[c];
        match kind {
            Kind::Stay | Kind::Edit => {
                let out = &mut self.variables[v1];
                out.walk_strength = strength;
                out.stay = matches!(kind, Kind::Stay);
            }
            Kind::Equality | Kind::Scale { .. } => {
                let (input, out) = (self.input(c), self.output(c));
                let walk = weakest_of(strength, self.variables[input].walk_strength);
                let stay = match kind {
                    Kind::Scale { scale, offset } => {
                        self.variables[input].stay
                            && self.variables[scale].stay
                            && self.variables[offset].stay
                    }
                    _ => self.variables[input].stay,
                };
                self.variables[out].walk_strength = walk;
                self.variables[out].stay = stay;
                if stay {
                    self.execute(c);
                }
            }
        }
    }

    fn execute(&mut self, c: usize) {
        let Constraint {
            kind,
            v1,
            v2,
            direction,
            ..
        } = self.constraints[c];
        match kind {
            Kind::Stay | Kind::Edit => {}
            Kind::Equality => {
                let value = self.variables[self.input(c)].value;
                let out = self.output(c);
                self.variables[out].value = value;
            }
            Kind::Scale { scale, offset } => {
                let (scale, offset) = (self.variables[scale].value, self.variables[offset].value);
                if direction == FORWARD {
                    self.variables[v2].value = self.variables[v1].value * scale + offset;
                } else {
                    self.variables[v1].value = (self.variables[v2].value - offset) / scale;
                }
            }
        }
    }

    fn satisfy(&mut self, c: usize, mark: u32) -> Option<usize> {
        self.choose_method(c, mark);
        if !self.is_satisfied(c) {
            assert!(
                self.constraints[c].strength != REQUIRED,
                "required constraint unsatisfied"
            );
            return None;
        }
        self.mark_inputs(c, mark);
        let out = self.output(c);
        let overridden = self.variables[out].determined_by;
        if let Some(previous) = overridden {
            self.mark_unsatisfied(previous);
        }
        self.variables[out].determined_by = Some(c);
        assert!(self.add_propagate(c, mark), "cycle encountered");
        self.variables[out].mark = mark;
        overridden
    }

    fn destroy_constraint(&mut self, c: usize) {
        if self.is_satisfied(c) {
            self.incremental_remove(c);
        } else {
            self.remove_from_graph(c);
        }
    }

    fn new_mark(&mut self) -> u32 {
        self.current_mark += 1;
        self.current_mark
    }

    fn incremental_add(&mut self, c: usize) {
        let mark = self.new_mark();
        let mut overridden = self.satisfy(c, mark);
        while let Some(next) = overridden {
            overridden = self.satisfy(next, mark);
        }
    }

    fn incremental_remove(&mut self, c: usize) {
        let out = self.output(c);
        self.mark_unsatisfied(c);
        self.remove_from_graph(c);
        let unsatisfied = self.remove_propagate_from(out);
        let mut strength = REQUIRED;
        loop {
            for &u in &unsatisfied {
                if self.constraints[u].strength == strength {
                    self.incremental_add(u);
                }
            }
            strength = next_weaker(strength);
            if strength == WEAKEST {
                break;
            }
        }
    }

    fn make_plan(&mut self, mut todo: VecDeque<usize>) -> Vec<usize> {
        let mark = self.new_mark();
        let mut plan = Vec::new();
        while let Some(c) = todo.pop_front() {
            let out = self.output(c);
            if self.variables[out].mark != mark && self.inputs_known(c, mark) {
                plan.push(c);
                self.variables[out].mark = mark;
                self.add_constraints_consuming_to(out, &mut todo);
            }
        }
        plan
    }

    fn extract_plan(&mut self, constraints: &[usize]) -> Vec<usize> {
        let sources = constraints
            .iter()
            .copied()
            .filter(|&c| matches!(self.constraints[c].kind, Kind::Edit) && self.is_satisfied(c))
            .collect();
        self.make_plan(sources)
    }

    fn add_propagate(&mut self, c: usize, mark: u32) -> bool {
        let mut todo = VecDeque::from([c]);
        while let Some(d) = todo.pop_front() {
            if self.variables[self.output(d)].mark == mark {
                self.incremental_remove(c);
                return false;
            }
            self.recalculate(d);
            let out = self.output(d);
            self.add_constraints_consuming_to(out, &mut todo);
        }
        true
    }

    fn remove_propagate_from(&mut self, out: usize) -> Vec<usize> {
        let variable = &mut self.variables[out];
        variable.determined_by = None;
        variable.walk_strength = WEAKEST;
        variable.stay = true;
        let mut unsatisfied = Vec::new();
        let mut todo = VecDeque::from([out]);
        while let Some(v) = todo.pop_front() {
            for i in 0..self.variables[v].constraints.len() {
                let c = self.variables[v].constraints[i];
                if !self.is_satisfied(c) {
                    unsatisfied.push(c);
                }
            }
            let determining = self.variables[v].determined_by;
            for i in 0..self.variables[v].constraints.len() {
                let next = self.variables[v].constraints[i];
                if Some(next) != determining && self.is_satisfied(next) {
                    self.recalculate(next);
                    todo.push_back(self.output(next));
                }
            }
        }
        unsatisfied
    }

    fn add_constraints_consuming_to(&self, v: usize, todo: &mut VecDeque<usize>) {
        let determining = self.variables[v].determined_by;
        for &c in &self.variables[v].constraints {
            if Some(c) != determining && self.is_satisfied(c) {
                todo.push_back(c);
            }
        }
    }

    fn execute_plan(&mut self, plan: &[usize]) {
        for &c in plan {
            self.execute(c);
        }
    }

    fn change(&mut self, v: usize, value: f64) {
        let edit = self.constraint(Kind::Edit, PREFERRED, v, v);
        let plan = self.extract_plan(&[edit]);
        for _ in 0..10 {
            self.variables[v].value = value;
            self.execute_plan(&plan);
        }
        self.destroy_constraint(edit);
    }
}

fn chain_test(n: usize) -> f64 {
    let mut planner = Planner::new();
    let variables: Vec<usize> = (0..=n)
        .map(|i| planner.variable(format!("v{i}"), 0.0))
        .collect();
    for pair in variables.windows(2) {
        planner.constraint(Kind::Equality, REQUIRED, pair[0], pair[1]);
    }
    let (first, last) = (variables[0], variables[n]);
    planner.constraint(Kind::Stay, STRONG_DEFAULT, last, last);
    let edit = planner.constraint(Kind::Edit, PREFERRED, first, first);
    let plan = planner.extract_plan(&[edit]);
    for i in 0..100 {
        let value = f64::from(i);
        planner.variables[first].value = value;
        planner.execute_plan(&plan);
        assert!(planner.variables[last].value == value, "chain test failed");
    }
    planner.variables[last].value
}

fn projection_test(n: usize) -> f64 {
    let mut planner = Planner::new();
    let scale = planner.variable("scale".to_string(), 10.0);
    let offset = planner.variable("offset".to_string(), 1000.0);
    let mut dests = Vec::with_capacity(n);
    let (mut src, mut dst) = (scale, offset);
    for i in 0..n {
        let value = f64::from(u32::try_from(i).unwrap_or_default());
        src = planner.variable(format!("src{i}"), value);
        dst = planner.variable(format!("dst{i}"), value);
        dests.push(dst);
        planner.constraint(Kind::Stay, NORMAL, src, src);
        planner.constraint(Kind::Scale { scale, offset }, REQUIRED, src, dst);
    }
    planner.change(src, 17.0);
    assert!(
        planner.variables[dst].value == 1170.0,
        "projection 1 failed"
    );
    planner.change(dst, 1050.0);
    assert!(planner.variables[src].value == 5.0, "projection 2 failed");
    planner.change(scale, 5.0);
    for (i, &d) in dests.iter().enumerate().take(n - 1) {
        let expected = f64::from(u32::try_from(i * 5 + 1000).unwrap_or_default());
        assert!(
            planner.variables[d].value == expected,
            "projection 3 failed"
        );
    }
    planner.change(offset, 2000.0);
    for (i, &d) in dests.iter().enumerate().take(n - 1) {
        let expected = f64::from(u32::try_from(i * 5 + 2000).unwrap_or_default());
        assert!(
            planner.variables[d].value == expected,
            "projection 4 failed"
        );
    }
    planner.variables[dst].value
}

/// One run of the benchmark: chainTest(100) plus projectionTest(100), 1149.
pub fn run() -> f64 {
    chain_test(100) + projection_test(100)
}
