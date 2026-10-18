//! Equivalence tests for the Effect subset (contract section 13): each program in
//! `tests/equivalence/effect/` runs with `buoy run`, and its stdout and exit status must equal
//! what Node printed with the real `effect` package. `scripts/freeze-expectations.sh` recorded
//! that output next to each program: `<name>.stdout`, and `<name>.status` when the status is
//! not 0. The tests never run node.

mod common;

#[test]
fn every_program_has_recorded_output() {
    common::assert_recorded("equivalence/effect", 20);
}

#[test]
fn effect_programs_print_what_node_printed() {
    if common::vm_available() {
        common::assert_matches("equivalence/effect", |_| {});
    }
}
