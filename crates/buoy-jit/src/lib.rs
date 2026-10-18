//! The native tier (section 17.10 of the contract): the NIF library `buoy_jit`, which
//! compiles the typed IR of an island with Cranelift and runs its entries in time slices
//! inside the calling BEAM process.
//!
//! The Erlang side is `buoy_jit.erl`. Its NIFs:
//!
//! - `compile(Bytes)`: `{ok, Code}` with the machine code of the program in `Bytes`, or
//!   `{error, Message}`.
//! - `context(HeapLimit)`: a new context, which holds the stack and the heap of the runs
//!   of one process.
//! - `run(Code, Context, Entry, Args, Globals)`: runs the entry. The result is
//!   `{ok, Value}`, `{bail, Reason}` when the Erlang tier must run the call instead, or
//!   `badtype` when an argument or a global does not have the type of the entry. A run
//!   that outlasts a slice yields to the scheduler and continues in `run_slice`.

mod codegen;
#[cfg(not(test))]
mod nif;
mod run;
#[cfg(test)]
mod tests;

#[cfg(not(test))]
#[allow(unsafe_code)]
mod erlang {
    use std::ffi::{c_int, c_void};
    use std::panic::{AssertUnwindSafe, catch_unwind};
    use std::sync::{Arc, Mutex, OnceLock};

    use buoy_jit_ir::Program;

    use crate::codegen::{self, Code};
    use crate::nif::{Entry, Env, Func, NifFn, RawEnv, ResourceType, Term, is_identical};
    use crate::run::{Context, SLICE, Step, Value};

    struct Types {
        code: ResourceType<Arc<Code>>,
        context: ResourceType<Mutex<Context>>,
    }

    static TYPES: OnceLock<Types> = OnceLock::new();

    fn types() -> Option<&'static Types> {
        TYPES.get()
    }

    unsafe extern "C" fn load(raw: *mut RawEnv, _priv: *mut *mut c_void, _info: Term) -> c_int {
        // SAFETY: the VM passes the env of the load call.
        let env = unsafe { Env::new(raw) };
        let opened = (|| {
            Some(Types {
                code: ResourceType::open(env, c"buoy_jit_code")?,
                context: ResourceType::open(env, c"buoy_jit_context")?,
            })
        })();
        match opened {
            Some(types) => {
                let _ = TYPES.set(types);
                0
            }
            None => 1,
        }
    }

    /// Runs a NIF body, and turns a panic into the error `nif_panicked`.
    fn guarded(raw: *mut RawEnv, body: impl FnOnce(Env) -> Term) -> Term {
        // SAFETY: the VM passes the env of the running call.
        let env = unsafe { Env::new(raw) };
        catch_unwind(AssertUnwindSafe(|| body(env))).unwrap_or_else(|_| env.badarg())
    }

    /// The arguments of a NIF call.
    ///
    /// # Safety
    ///
    /// `argv` must hold `argc` terms.
    unsafe fn arguments<'a>(count: c_int, terms: *const Term) -> &'a [Term] {
        let count = usize::try_from(count).unwrap_or(0);
        if count == 0 || terms.is_null() {
            return &[];
        }
        // SAFETY: as the caller promises.
        unsafe { std::slice::from_raw_parts(terms, count) }
    }

    unsafe extern "C" fn compile(raw: *mut RawEnv, count: c_int, terms: *const Term) -> Term {
        // SAFETY: the VM passes `count` terms.
        let given = unsafe { arguments(count, terms) };
        guarded(raw, |env| {
            let (Some(types), Some(bytes)) = (types(), given.first().and_then(|t| env.binary(*t)))
            else {
                return env.badarg();
            };
            let compiled = Program::decode(bytes)
                .map_err(|error| error.to_string())
                .and_then(|program| codegen::compile(&program));
            match compiled {
                Ok(code) => {
                    let term = types.code.make(env, Arc::new(code));
                    env.tuple(&[env.atom(c"ok"), term])
                }
                Err(message) => {
                    let text = env.binary_from(message.as_bytes());
                    env.tuple(&[env.atom(c"error"), text])
                }
            }
        })
    }

    unsafe extern "C" fn context(raw: *mut RawEnv, count: c_int, terms: *const Term) -> Term {
        // SAFETY: the VM passes `count` terms.
        let given = unsafe { arguments(count, terms) };
        guarded(raw, |env| {
            let (Some(types), Some(limit)) =
                (types(), given.first().and_then(|t| env.get_long(*t)))
            else {
                return env.badarg();
            };
            let limit = usize::try_from(limit).unwrap_or(0);
            types.context.make(env, Mutex::new(Context::new(limit)))
        })
    }

    /// The value of a term of the engine: a number in its canonical form, or a boolean.
    fn value_of(env: Env, term: Term) -> Option<Value> {
        if let Some(integer) = env.get_long(term) {
            // The engine keeps integers within 2^53, which a double holds exactly.
            #[allow(clippy::cast_precision_loss)]
            return Some(Value::Num(integer as f64));
        }
        if let Some(number) = env.get_double(term) {
            return Some(Value::Num(number));
        }
        let atoms: [(&std::ffi::CStr, Value); 5] = [
            (c"true", Value::Bool(true)),
            (c"false", Value::Bool(false)),
            (c"NaN", Value::Num(f64::NAN)),
            (c"Infinity", Value::Num(f64::INFINITY)),
            (c"-Infinity", Value::Num(f64::NEG_INFINITY)),
        ];
        atoms
            .iter()
            .find(|(name, _)| is_identical(term, env.atom(name)))
            .map(|(_, value)| *value)
    }

    /// The canonical term of a result (contract section 17.1).
    fn term_of(env: Env, value: Value) -> Term {
        const SAFE: f64 = 9_007_199_254_740_992.0;
        match value {
            Value::Bool(true) => env.atom(c"true"),
            Value::Bool(false) => env.atom(c"false"),
            Value::Undefined => env.atom(c"undefined"),
            Value::Num(number) if number.is_nan() => env.atom(c"NaN"),
            Value::Num(number) if number == f64::INFINITY => env.atom(c"Infinity"),
            Value::Num(number) if number == f64::NEG_INFINITY => env.atom(c"-Infinity"),
            Value::Num(number) if number == 0.0 && number.is_sign_negative() => env.double(-0.0),
            Value::Num(number) if number.fract() == 0.0 && number.abs() <= SAFE => {
                // An integral double within 2^53 converts to an integer exactly.
                #[allow(clippy::cast_possible_truncation)]
                env.long(number as i64)
            }
            Value::Num(number) => env.double(number),
        }
    }

    /// The values of the first `limit` terms of a list.
    fn values(env: Env, list: Term, limit: usize) -> Option<Vec<Value>> {
        env.list(list)?
            .into_iter()
            .take(limit)
            .map(|term| value_of(env, term))
            .collect()
    }

    unsafe extern "C" fn run(raw: *mut RawEnv, count: c_int, terms: *const Term) -> Term {
        // SAFETY: the VM passes `count` terms.
        let given = unsafe { arguments(count, terms) };
        guarded(raw, |env| {
            let [code_term, context_term, entry, call_args, globals] = given else {
                return env.badarg();
            };
            let Some(types) = types() else {
                return env.badarg();
            };
            let (Some(code), Some(context), Some(entry)) = (
                types.code.get(env, *code_term),
                types.context.get(env, *context_term),
                env.get_long(*entry).and_then(|e| usize::try_from(e).ok()),
            ) else {
                return env.badarg();
            };
            let Some(function) = code.entry(entry) else {
                return env.badarg();
            };
            let (Some(call_args), Some(globals)) = (
                values(env, *call_args, function.params.len()),
                values(env, *globals, usize::MAX),
            ) else {
                return env.atom(c"badtype");
            };
            let Ok(mut context_guard) = context.lock() else {
                return env.atom(c"busy");
            };
            let started = std::time::Instant::now();
            let Some(step) = context_guard.start(code, entry, &call_args, &globals) else {
                return env.atom(c"badtype");
            };
            drop(context_guard);
            finish(env, step, started, *code_term, *context_term)
        })
    }

    unsafe extern "C" fn run_slice(raw: *mut RawEnv, count: c_int, terms: *const Term) -> Term {
        // SAFETY: the VM passes `count` terms.
        let given = unsafe { arguments(count, terms) };
        guarded(raw, |env| {
            let [code_term, context_term] = given else {
                return env.badarg();
            };
            let Some(context) = types().and_then(|types| types.context.get(env, *context_term))
            else {
                return env.badarg();
            };
            let Ok(mut context_guard) = context.lock() else {
                return env.atom(c"busy");
            };
            let started = std::time::Instant::now();
            let step = context_guard.resume();
            drop(context_guard);
            finish(env, step, started, *code_term, *context_term)
        })
    }

    /// The result of a slice: the value, the bail, or the next slice.
    fn finish(
        env: Env,
        step: Step,
        started: std::time::Instant,
        code: Term,
        context: Term,
    ) -> Term {
        let micros = started.elapsed().as_micros();
        let percent = i32::try_from(micros * 100 / SLICE.as_micros().max(1)).unwrap_or(100);
        let spent = env.consume_timeslice(percent);
        match step {
            Step::Done(value) => env.tuple(&[env.atom(c"ok"), term_of(env, value)]),
            Step::Bail(reason) => {
                let name = std::ffi::CString::new(reason.name()).unwrap_or_default();
                env.tuple(&[env.atom(c"bail"), env.atom(&name)])
            }
            Step::Yield => {
                let _ = spent;
                env.schedule(c"buoy_jit_run_slice", run_slice as NifFn, &[code, context])
            }
        }
    }

    struct EntryCell(Entry);

    // SAFETY: the entry and the tables it points to are immutable statics.
    unsafe impl Sync for EntryCell {}

    struct FuncsCell([Func; 3]);

    // SAFETY: as above.
    unsafe impl Sync for FuncsCell {}

    // `run_slice` needs no entry: `enif_schedule_nif` takes its address.
    static FUNCS: FuncsCell = FuncsCell([
        Func {
            name: c"compile".as_ptr(),
            arity: 1,
            fptr: compile,
            flags: 0,
        },
        Func {
            name: c"context".as_ptr(),
            arity: 1,
            fptr: context,
            flags: 0,
        },
        Func {
            name: c"run".as_ptr(),
            arity: 5,
            fptr: run,
            flags: 0,
        },
    ]);

    static ENTRY: EntryCell = EntryCell(Entry {
        major: 2,
        minor: 16,
        name: c"buoy_jit".as_ptr(),
        num_of_funcs: 3,
        funcs: FUNCS.0.as_ptr(),
        load: Some(load),
        reload: std::ptr::null(),
        upgrade: std::ptr::null(),
        unload: std::ptr::null(),
        vm_variant: c"beam.vanilla".as_ptr(),
        options: 1,
        // sizeof(ErlNifResourceTypeInit): three pointers, an int with its padding, a pointer.
        sizeof_resource_type_init: 40,
        min_erts: c"erts-12.0".as_ptr(),
    });

    /// The entry point that `erlang:load_nif/2` looks up.
    #[unsafe(no_mangle)]
    pub extern "C" fn nif_init() -> *const Entry {
        &raw const ENTRY.0
    }
}
