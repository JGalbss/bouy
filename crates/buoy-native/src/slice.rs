//! Time slices. A NIF must not hold a scheduler for more than about 1 ms ("Long-running
//! NIFs" in the `erl_nif` manual). Each NIF of `json` and `regexp` counts its work, reports
//! the time it took with `enif_consume_timeslice`, and stops when the slice of its process
//! is over.
//! It then returns a continuation, which the Erlang caller passes to its next call. The
//! process takes the reductions of the work, so the scheduler switches it out between the
//! two calls, as it does an Erlang function that runs as long.

use std::time::Instant;

use rustler::Env;
use rustler::schedule::consume_timeslice;

/// The units of work between two reads of the clock.
const CHECK: usize = 1024;

/// The time and work of one NIF call.
#[derive(Debug)]
pub struct Slice {
    since: Instant,
    work: usize,
}

impl Slice {
    pub fn new() -> Self {
        Self {
            since: Instant::now(),
            work: 0,
        }
    }

    /// Counts `units` of work and tells whether the slice of the process is over.
    pub fn is_over(&mut self, env: Env, units: usize) -> bool {
        self.work += units;
        if self.work < CHECK {
            return false;
        }
        self.work = 0;
        // A process slice of Erlang code is about 4,000 reductions, well under 1 ms, so a
        // NIF counts each microsecond as 1 percent and yields after about 100 µs.
        let percent = self.since.elapsed().as_micros();
        if percent == 0 {
            return false;
        }
        self.since = Instant::now();
        consume_timeslice(env, i32::try_from(percent.min(100)).unwrap_or(100))
    }
}
