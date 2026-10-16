//! Conformance tests: each program in `tests/conformance/` runs with `bouy run`, and its
//! stdout and exit status must equal the Node output that `scripts/freeze-expectations.sh`
//! recorded next to it: `<name>.stdout`, and `<name>.status` when the status is not 0.
//! The tests never run node.

mod common;

#[test]
fn every_program_has_recorded_output() {
    common::assert_recorded("conformance", 45);
}

#[test]
fn programs_print_what_node_printed() {
    if common::vm_available() {
        common::assert_matches("conformance", |_| {});
    }
}
