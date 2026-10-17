//! The reference-semantics prototype: each program in `tests/reference/` runs with
//! `bouy run --semantics reference`, and its stdout and exit status must equal the Node
//! output that `scripts/freeze-expectations.sh` recorded next to it.

mod common;

#[test]
fn every_program_has_recorded_output() {
    common::assert_recorded("reference", 25);
}

#[test]
fn programs_print_what_node_printed() {
    if common::vm_available() {
        common::assert_matches("reference", |command| {
            command.args(["--semantics", "reference"]);
        });
    }
}
