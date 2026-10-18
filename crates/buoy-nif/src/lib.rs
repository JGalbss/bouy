//! The native built-ins of the Buoy runtime: NIFs that the Erlang module `buoy_nif` loads.
//!
//! Each NIF builds the terms of the engine's value representation (section 17 of
//! `docs/design/beam-runtime.md`) and runs in time slices (`slice`): it never holds a
//! scheduler for much more than a slice, so BEAM preemption holds while it runs. The code
//! is safe Rust over rustler's API.

mod json;
mod slice;

rustler::init!("buoy_nif");
