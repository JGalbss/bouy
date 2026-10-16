# Conformance corpus

Each program in this directory uses only language features and globals: no actors and no imports. Node is the oracle. `crates/bouy-cli/tests/conformance.rs` runs every program with `node <file>` and with `bouy run <file>`, and asserts that stdout and the exit status are equal. A program avoids the documented differences of section 3 of `docs/design/beam-runtime.md`: it prints objects with a single key or with keys in sorted order, and it uses integers below 2^53.

Run the corpus with `cargo test -p bouy-cli --test conformance`. The test needs `node` and `erl` on `PATH`, and skips with a notice when either is missing. On a failure it prints, for each program, the exit statuses and the lines that differ: `-` for Node and `+` for Bouy.
