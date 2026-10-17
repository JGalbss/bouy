//! The native tier of the speed spike. NBody, Richards, and DeltaBlue run as Rust, and
//! Erlang calls them as NIFs. A sliced NIF does a bounded chunk of work, reports the time
//! it took with `enif_consume_timeslice`, and when the slice is used up it returns to the
//! scheduler through `enif_schedule_nif` with its state in the arguments. So a long
//! computation yields to other processes, as Erlang code does. The `_blocking` NIFs run
//! to the end in one call: they are the control of the preemption test. The `json_` and
//! `regex_` NIFs are native built-ins.
//!
//! The bindings to `erl_nif.h` (NIF version 2.18, OTP 29) are written out by hand, so the
//! spike needs no binding crate.

use std::ffi::{c_char, c_int, c_long, c_uint, c_void};
use std::time::Instant;

mod deltablue;
mod json;
mod nbody;
mod regex;
mod richards;

type Term = usize;

#[repr(C)]
struct Env {
    _private: [u8; 0],
}

type NifFn = unsafe extern "C" fn(*mut Env, c_int, *const Term) -> Term;

#[repr(C)]
struct Func {
    name: *const c_char,
    arity: c_uint,
    fptr: NifFn,
    flags: c_uint,
}

#[repr(C)]
struct Entry {
    major: c_int,
    minor: c_int,
    name: *const c_char,
    num_of_funcs: c_int,
    funcs: *const Func,
    load: *const c_void,
    reload: *const c_void,
    upgrade: *const c_void,
    unload: *const c_void,
    vm_variant: *const c_char,
    options: c_uint,
    sizeof_resource_type_init: usize,
    min_erts: *const c_char,
}

#[repr(C)]
struct Binary {
    size: usize,
    data: *mut u8,
    ref_bin: *mut c_void,
    spare: [*mut c_void; 2],
}

unsafe extern "C" {
    fn enif_get_long(env: *mut Env, term: Term, value: *mut c_long) -> c_int;
    fn enif_make_long(env: *mut Env, value: c_long) -> Term;
    fn enif_make_double(env: *mut Env, value: f64) -> Term;
    fn enif_make_badarg(env: *mut Env) -> Term;
    fn enif_inspect_binary(env: *mut Env, term: Term, binary: *mut Binary) -> c_int;
    fn enif_make_new_binary(env: *mut Env, size: usize, term: *mut Term) -> *mut u8;
    fn enif_consume_timeslice(env: *mut Env, percent: c_int) -> c_int;
    fn enif_make_atom(env: *mut Env, name: *const c_char) -> Term;
    fn enif_get_atom(
        env: *mut Env,
        atom: Term,
        buffer: *mut c_char,
        size: c_uint,
        encoding: c_int,
    ) -> c_int;
    fn enif_get_double(env: *mut Env, term: Term, value: *mut f64) -> c_int;
    fn enif_get_tuple(
        env: *mut Env,
        term: Term,
        arity: *mut c_int,
        array: *mut *const Term,
    ) -> c_int;
    fn enif_get_list_cell(env: *mut Env, term: Term, head: *mut Term, tail: *mut Term) -> c_int;
    fn enif_term_type(env: *mut Env, term: Term) -> c_int;
    fn enif_make_sub_binary(env: *mut Env, binary: Term, at: usize, size: usize) -> Term;
    fn enif_make_tuple_from_array(env: *mut Env, array: *const Term, count: c_uint) -> Term;
    fn enif_make_list_from_array(env: *mut Env, array: *const Term, count: c_uint) -> Term;
    fn enif_schedule_nif(
        env: *mut Env,
        name: *const c_char,
        flags: c_int,
        fptr: NifFn,
        argc: c_int,
        argv: *const Term,
    ) -> Term;
}

/// The work between two yields. The VM calls 1 ms a full timeslice, but an Erlang process
/// spends its 4000 reductions in about 0.1 to 0.3 ms, so a NIF that counts 1 ms per slice
/// holds the scheduler several times longer than Erlang code does.
const SLICE_MICROS: u128 = 200;

/// The share of a timeslice that a chunk of `micros` used.
fn percent_of_slice(micros: u128) -> c_int {
    c_int::try_from((micros * 100 / SLICE_MICROS).clamp(1, 100)).unwrap_or(100)
}

/// Reports the time since `start` to the scheduler, and returns true when the slice is
/// spent and the NIF must yield.
unsafe fn slice_spent(env: *mut Env, start: Instant) -> bool {
    unsafe { enif_consume_timeslice(env, percent_of_slice(start.elapsed().as_micros())) != 0 }
}

unsafe fn get_long(env: *mut Env, term: Term) -> Option<c_long> {
    let mut value: c_long = 0;
    (unsafe { enif_get_long(env, term, &raw mut value) } != 0).then_some(value)
}

unsafe fn argument(env: *mut Env, argv: *const Term, index: usize) -> Option<c_long> {
    unsafe { get_long(env, *argv.add(index)) }
}

/// A new binary term with a copy of `data`.
unsafe fn binary_term(env: *mut Env, data: &[u8]) -> Term {
    let mut term: Term = 0;
    unsafe {
        let target = enif_make_new_binary(env, data.len(), &raw mut term);
        std::ptr::copy_nonoverlapping(data.as_ptr(), target, data.len());
    }
    term
}

/// The bytes of a binary term, which live as long as the term.
unsafe fn bytes<'a>(env: *mut Env, term: Term) -> Option<&'a [u8]> {
    let mut binary = Binary {
        size: 0,
        data: std::ptr::null_mut(),
        ref_bin: std::ptr::null_mut(),
        spare: [std::ptr::null_mut(); 2],
    };
    unsafe {
        (enif_inspect_binary(env, term, &raw mut binary) != 0).then_some(())?;
        Some(std::slice::from_raw_parts(binary.data, binary.size))
    }
}

// NBody: the state between slices is a binary of the 35 floats of the five bodies.

const NBODY_CHUNK: c_long = 1000;

unsafe fn nbody_state_term(env: *mut Env, system: &nbody::System) -> Term {
    unsafe { binary_term(env, &system.to_bytes()) }
}

unsafe extern "C" fn nbody_start(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        let Some(steps) = argument(env, argv, 0).filter(|steps| *steps >= 0) else {
            return enif_make_badarg(env);
        };
        let args = [
            nbody_state_term(env, &nbody::System::new()),
            enif_make_long(env, steps),
        ];
        enif_schedule_nif(
            env,
            c"nbody_slice".as_ptr(),
            0,
            nbody_slice,
            2,
            args.as_ptr(),
        )
    }
}

unsafe extern "C" fn nbody_slice(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        let (Some(mut remaining), Some(mut system)) = (
            argument(env, argv, 1),
            bytes(env, *argv).and_then(nbody::System::from_bytes),
        ) else {
            return enif_make_badarg(env);
        };
        let mut start = Instant::now();
        loop {
            let chunk = remaining.min(NBODY_CHUNK);
            for _ in 0..chunk {
                system.advance(0.01);
            }
            remaining -= chunk;
            if remaining == 0 {
                return enif_make_double(env, system.energy());
            }
            if slice_spent(env, start) {
                let args = [
                    nbody_state_term(env, &system),
                    enif_make_long(env, remaining),
                ];
                return enif_schedule_nif(
                    env,
                    c"nbody_slice".as_ptr(),
                    0,
                    nbody_slice,
                    2,
                    args.as_ptr(),
                );
            }
            start = Instant::now();
        }
    }
}

unsafe extern "C" fn nbody_blocking(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        let Some(steps) = argument(env, argv, 0).filter(|steps| *steps >= 0) else {
            return enif_make_badarg(env);
        };
        let mut system = nbody::System::new();
        for _ in 0..steps {
            system.advance(0.01);
        }
        enif_make_double(env, system.energy())
    }
}

// Richards and DeltaBlue: one chunk is one run of the benchmark, tens of microseconds. The
// state between slices is the count of runs left and the sum of the results so far.

trait Runs {
    const SLICE: &'static std::ffi::CStr;
    fn run() -> f64;
}

struct Richards;

impl Runs for Richards {
    const SLICE: &'static std::ffi::CStr = c"richards_slice";
    #[allow(clippy::cast_precision_loss)]
    fn run() -> f64 {
        richards::run() as f64
    }
}

struct DeltaBlue;

impl Runs for DeltaBlue {
    const SLICE: &'static std::ffi::CStr = c"deltablue_slice";
    fn run() -> f64 {
        deltablue::run()
    }
}

unsafe fn schedule_runs<K: Runs>(env: *mut Env, remaining: c_long, check: f64) -> Term {
    unsafe {
        let args = [enif_make_long(env, remaining), enif_make_double(env, check)];
        enif_schedule_nif(env, K::SLICE.as_ptr(), 0, runs_slice::<K>, 2, args.as_ptr())
    }
}

unsafe extern "C" fn runs_start<K: Runs>(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        match argument(env, argv, 0).filter(|runs| *runs >= 0) {
            Some(runs) => schedule_runs::<K>(env, runs, 0.0),
            None => enif_make_badarg(env),
        }
    }
}

unsafe extern "C" fn runs_slice<K: Runs>(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        let mut check = 0.0;
        let (Some(mut remaining), true) = (
            argument(env, argv, 0),
            enif_get_double(env, *argv.add(1), &raw mut check) != 0,
        ) else {
            return enif_make_badarg(env);
        };
        let mut start = Instant::now();
        loop {
            if remaining == 0 {
                return enif_make_double(env, check);
            }
            check += K::run();
            remaining -= 1;
            if slice_spent(env, start) {
                return schedule_runs::<K>(env, remaining, check);
            }
            start = Instant::now();
        }
    }
}

unsafe extern "C" fn runs_blocking<K: Runs>(
    env: *mut Env,
    _argc: c_int,
    argv: *const Term,
) -> Term {
    unsafe {
        match argument(env, argv, 0).filter(|runs| *runs >= 0) {
            Some(runs) => enif_make_double(env, (0..runs).map(|_| K::run()).sum()),
            None => enif_make_badarg(env),
        }
    }
}

// JSON: a native built-in, not a kernel of the native tier. It runs on a dirty CPU
// scheduler, so it does not hold a normal scheduler while it parses 1 MB.

const DIRTY_CPU: c_uint = 1;

unsafe extern "C" fn json_parse(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        bytes(env, *argv)
            .and_then(|input| json::parse(env, *argv, input))
            .unwrap_or_else(|| enif_make_badarg(env))
    }
}

unsafe extern "C" fn json_stringify(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe { json::stringify(env, *argv).unwrap_or_else(|| enif_make_badarg(env)) }
}

// Regex: a native built-in. The calls over the whole text run on a dirty CPU scheduler, and
// the test of one line runs on a normal one.

unsafe fn pattern_and_text<'a>(
    env: *mut Env,
    argv: *const Term,
) -> Option<(std::sync::Arc<::regex::bytes::Regex>, &'a [u8])> {
    unsafe {
        Some((
            regex::compiled(bytes(env, *argv)?)?,
            bytes(env, *argv.add(1))?,
        ))
    }
}

unsafe extern "C" fn regex_match(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        match pattern_and_text(env, argv) {
            Some((pattern, text)) => regex::matches(env, &pattern, *argv.add(1), text),
            None => enif_make_badarg(env),
        }
    }
}

unsafe extern "C" fn regex_captures(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        let mut groups = Vec::new();
        let (mut head, mut tail) = (0, *argv.add(2));
        while enif_get_list_cell(env, tail, &raw mut head, &raw mut tail) != 0 {
            match get_long(env, head).and_then(|group| usize::try_from(group).ok()) {
                Some(group) => groups.push(group),
                None => return enif_make_badarg(env),
            }
        }
        match pattern_and_text(env, argv) {
            Some((pattern, text)) => regex::captures(env, &pattern, *argv.add(1), text, &groups),
            None => enif_make_badarg(env),
        }
    }
}

unsafe extern "C" fn regex_test(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        match pattern_and_text(env, argv) {
            Some((pattern, text)) if pattern.is_match(text) => {
                enif_make_atom(env, c"true".as_ptr())
            }
            Some(_) => enif_make_atom(env, c"false".as_ptr()),
            None => enif_make_badarg(env),
        }
    }
}

unsafe extern "C" fn regex_replace(env: *mut Env, _argc: c_int, argv: *const Term) -> Term {
    unsafe {
        let (Some((pattern, text)), Some(replacement)) =
            (pattern_and_text(env, argv), bytes(env, *argv.add(2)))
        else {
            return enif_make_badarg(env);
        };
        let replaced = pattern.replace_all(text, ::regex::bytes::NoExpand(replacement));
        binary_term(env, &replaced)
    }
}

static FUNCS: [Func; 11] = [
    Func {
        name: c"nbody".as_ptr(),
        arity: 1,
        fptr: nbody_start,
        flags: 0,
    },
    Func {
        name: c"nbody_blocking".as_ptr(),
        arity: 1,
        fptr: nbody_blocking,
        flags: 0,
    },
    Func {
        name: c"richards".as_ptr(),
        arity: 1,
        fptr: runs_start::<Richards>,
        flags: 0,
    },
    Func {
        name: c"richards_blocking".as_ptr(),
        arity: 1,
        fptr: runs_blocking::<Richards>,
        flags: 0,
    },
    Func {
        name: c"deltablue".as_ptr(),
        arity: 1,
        fptr: runs_start::<DeltaBlue>,
        flags: 0,
    },
    Func {
        name: c"json_parse".as_ptr(),
        arity: 1,
        fptr: json_parse,
        flags: DIRTY_CPU,
    },
    Func {
        name: c"json_stringify".as_ptr(),
        arity: 1,
        fptr: json_stringify,
        flags: DIRTY_CPU,
    },
    Func {
        name: c"regex_match".as_ptr(),
        arity: 2,
        fptr: regex_match,
        flags: DIRTY_CPU,
    },
    Func {
        name: c"regex_captures".as_ptr(),
        arity: 3,
        fptr: regex_captures,
        flags: DIRTY_CPU,
    },
    Func {
        name: c"regex_test".as_ptr(),
        arity: 2,
        fptr: regex_test,
        flags: 0,
    },
    Func {
        name: c"regex_replace".as_ptr(),
        arity: 3,
        fptr: regex_replace,
        flags: DIRTY_CPU,
    },
];

struct EntryCell(Entry);

// The entry and the function table are read-only after the VM loads them.
unsafe impl Sync for EntryCell {}
unsafe impl Sync for Func {}

static ENTRY: EntryCell = EntryCell(Entry {
    major: 2,
    minor: 18,
    name: c"speed_native".as_ptr(),
    num_of_funcs: 11,
    funcs: FUNCS.as_ptr(),
    load: std::ptr::null(),
    reload: std::ptr::null(),
    upgrade: std::ptr::null(),
    unload: std::ptr::null(),
    vm_variant: c"beam.vanilla".as_ptr(),
    options: 1,
    // sizeof(ErlNifResourceTypeInit): three pointers, an int with its padding, a pointer.
    sizeof_resource_type_init: 40,
    min_erts: c"erts-14.0".as_ptr(),
});

/// The entry point that `erlang:load_nif/2` looks up.
#[unsafe(no_mangle)]
pub extern "C" fn nif_init() -> *const c_void {
    (&raw const ENTRY.0).cast()
}
