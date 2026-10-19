//! WebAssembly on Wasmtime for the JavaScript API of `buoy_ref_wasm`.
//!
//! Each Erlang process that uses WebAssembly owns one store, which holds every instance,
//! memory, table, global, and tag of the process, as the JavaScript API puts them in one
//! agent. A driver future owns the store and runs the commands that the process sends.
//! One poll of the driver runs WebAssembly until the next epoch tick, about a millisecond,
//! then the NIF returns `yield` and the process polls again, so BEAM can preempt the
//! process between two polls.
//!
//! A call of a JavaScript import suspends the WebAssembly fiber. The NIF returns
//! `{call, Id, Args, ResultTypes, Grown}`, the process runs the function, and it sends the
//! result as the command `{return, Result}`. While the import runs, the suspended host
//! function executes any other command, such as a read of memory or a nested call, with
//! the store of the suspended call.
//!
//! A handle is the index of an extern in the table of the store. The process refers to
//! funcs, memories, tables, globals, and tags by handle, and to a JavaScript value inside
//! an `externref` by an id that it assigns.

// rustler decodes each argument of a NIF by value.
#![allow(clippy::needless_pass_by_value)]

use std::collections::HashMap;
use std::fmt;
use std::future::{Future, poll_fn};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};

use rustler::types::tuple::{get_tuple, make_tuple};
use rustler::{Binary, Encoder, Env, Error, NewBinary, NifResult, ResourceArc, Term};
use wasmtime::{
    AsContext, AsContextMut, Caller, Config, Engine, Extern, ExternRef, ExternType, Func, FuncType,
    Global, GlobalType, HeapType, Instance, Memory, MemoryType, Module, Mutability, Ref, RefType,
    ResourceLimiter, Store, Table, TableType, Tag, TagType, Trap, UpdateDeadline, Val, ValType,
};

mod atoms {
    rustler::atoms! {
        aborted,
        anyref,
        call,
        done,
        error,
        exnref,
        externref,
        f32,
        f64,
        func,
        func_type,
        funcref,
        global,
        global_get,
        global_new,
        global_set,
        global_type,
        host,
        i32,
        i64,
        instantiate,
        link_error,
        memory,
        memory_grow,
        memory_new,
        memory_read,
        memory_size,
        memory_type,
        memory_write,
        none,
        null,
        ok,
        other,
        range_error,
        return_ = "return",
        runtime_error,
        stack_overflow,
        table,
        table_get,
        table_grow,
        table_new,
        table_set,
        table_size,
        table_type,
        tag,
        tag_new,
        thrown,
        trap,
        type_error,
        v128,
        value,
        yield_ = "yield",
        nan = "NaN",
        infinity = "Infinity",
        negative_infinity = "-Infinity",
    }
}

/// The bytes of linear memory that every store of the VM may hold together. Each new store
/// passes the limit of `BUOY_MAX_MEMORY`, because linear memory is outside the Erlang
/// heaps and allocators that the guard of the VM measures.
static MEMORY_LIMIT: AtomicU64 = AtomicU64::new(4 << 30);
static MEMORY_USED: AtomicU64 = AtomicU64::new(0);

/// V8's limit on the elements of a table.
const MAX_TABLE_ELEMENTS: usize = 10_000_000;

/// The length of an epoch tick: the longest time that one poll runs WebAssembly.
const TICK: Duration = Duration::from_millis(1);

/// The engine of the VM, with a thread that advances its epoch each tick. `None` when
/// Wasmtime cannot run on this machine.
fn engine() -> Option<&'static Engine> {
    static ENGINE: OnceLock<Option<Engine>> = OnceLock::new();
    ENGINE
        .get_or_init(|| {
            let mut config = Config::new();
            config
                .epoch_interruption(true)
                // BEAM owns the signal handlers of the VM, so generated code checks bounds
                // and divisors itself.
                .signals_based_traps(false)
                .wasm_threads(true)
                .wasm_reference_types(true)
                .wasm_function_references(true)
                .wasm_gc(true)
                .wasm_simd(true)
                .wasm_relaxed_simd(true)
                .wasm_bulk_memory(true)
                .wasm_multi_value(true)
                .wasm_multi_memory(true)
                .wasm_memory64(true)
                .wasm_extended_const(true)
                .wasm_tail_call(true)
                .wasm_exceptions(true);
            let engine = Engine::new(&config).ok()?;
            let ticking = engine.clone();
            std::thread::Builder::new()
                .name("buoy-wasm-epoch".into())
                .spawn(move || {
                    loop {
                        std::thread::sleep(TICK);
                        ticking.increment_epoch();
                    }
                })
                .ok()?;
            Some(engine)
        })
        .as_ref()
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A compiled module.
pub struct WasmModule {
    module: Module,
}

#[rustler::resource_impl]
impl rustler::Resource for WasmModule {}

/// The store of one Erlang process and the driver future that owns it.
pub struct WasmStore {
    shared: Arc<Mutex<Shared>>,
    driver: Mutex<Pin<Box<dyn Future<Output = ()> + Send>>>,
}

#[rustler::resource_impl]
impl rustler::Resource for WasmStore {}

/// The state that the NIF and the driver share: the command in flight and its outcome,
/// and the table of handles.
#[derive(Default)]
struct Shared {
    command: Option<Command>,
    reply: Option<Reply>,
    outgoing: Option<Outgoing>,
    /// The memories that grew since the process last heard, by handle.
    grown: Vec<usize>,
    objects: Vec<Extern>,
    handles: HashMap<Identity, usize>,
    /// The id of the JavaScript function of each host func, by the address of its func
    /// ref, so that the func leaves the store as that function.
    hosts: HashMap<usize, u64>,
    /// Each memory with a handle, and its size in bytes when the process last heard.
    memories: Vec<(usize, Memory, usize)>,
}

/// What makes two externs the same object, so that one object keeps one handle.
#[derive(PartialEq, Eq, Hash)]
enum Identity {
    Func(usize),
    Memory(u64),
    Table(u64),
    Global(u64),
    Tag(u64),
}

/// The data of a store: the shared state, and the bytes of linear memory it holds.
struct State {
    shared: Arc<Mutex<Shared>>,
    memory_bytes: u64,
}

impl ResourceLimiter for State {
    fn memory_growing(
        &mut self,
        current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        if maximum.is_some_and(|maximum| desired > maximum) {
            return Ok(false);
        }
        let delta = u64::try_from(desired.saturating_sub(current)).unwrap_or(u64::MAX);
        let limit = MEMORY_LIMIT.load(Ordering::Relaxed);
        let granted = MEMORY_USED
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
                used.checked_add(delta).filter(|total| *total <= limit)
            })
            .is_ok();
        if granted {
            self.memory_bytes += delta;
        }
        Ok(granted)
    }

    fn table_growing(
        &mut self,
        _current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        Ok(desired <= MAX_TABLE_ELEMENTS && maximum.is_none_or(|maximum| desired <= maximum))
    }
}

impl Drop for State {
    fn drop(&mut self) {
        MEMORY_USED.fetch_sub(self.memory_bytes, Ordering::Relaxed);
    }
}

/// A value from the process, before the store makes it a `Val`.
#[derive(Clone, Copy)]
enum Arg {
    I32(i32),
    I64(i64),
    F32(u32),
    F64(u64),
    Func(Option<Func>),
    Extern(Option<u64>),
}

/// A value for the process.
#[derive(Clone, Copy)]
enum Out {
    I32(i32),
    I64(i64),
    F32(u32),
    F64(u64),
    V128,
    Null,
    Func(Func, usize),
    Extern(u64),
    Other,
}

/// What the process gives for one import of a module.
enum Import {
    Extern(Extern),
    /// A JavaScript function, by the id of the process.
    Host(u64),
    /// A number or reference for an immutable global.
    Value(Arg),
}

enum Command {
    Instantiate(Module, Vec<Import>),
    Call(Func, Vec<Arg>),
    Return(Returned),
    Memory(MemoryCommand),
    Table(TableCommand),
    GlobalNew(GlobalType, Arg),
    GlobalGet(Global),
    GlobalSet(Global, Arg),
    TagNew(Vec<ValType>),
    Type(Extern),
}

enum MemoryCommand {
    New(MemoryType),
    Grow(Memory, u64),
    Size(Memory),
    Read(Memory, u64, u64),
    Write(Memory, u64, Vec<u8>),
}

enum TableCommand {
    New(TableType, Arg),
    Get(Table, u64),
    Set(Table, u64, Arg),
    Grow(Table, u64, Arg),
    Size(Table),
}

/// The result of a JavaScript import.
enum Returned {
    Values(Vec<Arg>),
    /// The import threw the JavaScript value with this id.
    Thrown(u64),
    /// The process failed in a way that is not a JavaScript exception.
    Aborted,
}

enum Reply {
    Unit,
    Values(Vec<Out>),
    Externs(Vec<(String, Extern, ExternType, Option<Identity>)>),
    Extern(Extern, ExternType, Option<Identity>),
    Int(u64),
    Bytes(Vec<u8>),
    Trap(String),
    StackOverflow,
    Thrown(u64),
    Aborted,
    Error(ErrorKind, String),
}

#[derive(Clone, Copy)]
enum ErrorKind {
    Link,
    Range,
    Type,
    Runtime,
}

/// A call of a JavaScript import that waits for the process.
struct Outgoing {
    id: u64,
    args: Vec<Out>,
    results: Vec<ValType>,
}

/// The error that unwinds WebAssembly when a JavaScript import throws.
#[derive(Debug)]
struct JsException(u64);

impl fmt::Display for JsException {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "JavaScript exception {}", self.0)
    }
}

impl std::error::Error for JsException {}

#[derive(Debug)]
struct Abort;

impl fmt::Display for Abort {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("the process abandoned the call")
    }
}

impl std::error::Error for Abort {}

/// The next command, once the process sends one.
async fn next_command(shared: &Mutex<Shared>) -> Command {
    poll_fn(|_| {
        lock(shared)
            .command
            .take()
            .map_or(Poll::Pending, Poll::Ready)
    })
    .await
}

/// The driver of a store: it runs each command at the top level, when no WebAssembly call
/// is suspended.
async fn drive(mut store: Store<State>, shared: Arc<Mutex<Shared>>) {
    loop {
        let command = next_command(&shared).await;
        let reply = execute(&mut store, command).await;
        note_growth(&mut store, &shared);
        lock(&shared).reply = Some(reply);
    }
}

/// A host function that calls the JavaScript function `id` of the process.
fn host_func(ctx: impl AsContextMut<Data = State>, ty: FuncType, id: u64) -> Func {
    let results: Arc<[ValType]> = ty.results().collect();
    Func::new_async(ctx, ty, move |caller, params, outputs| {
        Box::new(call_host(caller, id, params, outputs, Arc::clone(&results)))
    })
}

async fn call_host(
    mut caller: Caller<'_, State>,
    id: u64,
    params: &[Val],
    outputs: &mut [Val],
    results: Arc<[ValType]>,
) -> wasmtime::Result<()> {
    let shared = Arc::clone(&caller.data().shared);
    let args = params.iter().map(|value| out(&mut caller, value)).collect();
    note_growth(&mut caller, &shared);
    lock(&shared).outgoing = Some(Outgoing {
        id,
        args,
        results: results.to_vec(),
    });
    loop {
        match next_command(&shared).await {
            Command::Return(Returned::Values(values)) => {
                if values.len() != outputs.len() {
                    return Err(wasmtime::Error::msg("wrong number of results"));
                }
                for ((slot, value), ty) in outputs.iter_mut().zip(values).zip(results.iter()) {
                    *slot = to_val(&mut caller, value, ty)?;
                }
                return Ok(());
            }
            Command::Return(Returned::Thrown(thrown)) => {
                return Err(wasmtime::Error::new(JsException(thrown)));
            }
            Command::Return(Returned::Aborted) => return Err(wasmtime::Error::new(Abort)),
            command => {
                let reply = Box::pin(execute(&mut caller, command)).await;
                note_growth(&mut caller, &shared);
                lock(&shared).reply = Some(reply);
            }
        }
    }
}

/// Records each memory whose size changed, for the process to detach its buffer.
fn note_growth(ctx: &mut impl AsContextMut<Data = State>, shared: &Mutex<Shared>) {
    let mut guard = lock(shared);
    let Shared {
        memories, grown, ..
    } = &mut *guard;
    for (handle, memory, size) in memories.iter_mut() {
        let now = memory.data_size(ctx.as_context());
        if now != *size {
            *size = now;
            grown.push(*handle);
        }
    }
}

async fn execute<C: AsContextMut<Data = State>>(ctx: &mut C, command: Command) -> Reply {
    match command {
        Command::Instantiate(module, imports) => instantiate(ctx, &module, imports).await,
        Command::Call(func, args) => call(ctx, func, args).await,
        Command::Return(_) => Reply::Error(
            ErrorKind::Type,
            "no WebAssembly call waits for a result".into(),
        ),
        Command::Memory(command) => memory_command(ctx, command).await,
        Command::Table(command) => table_command(ctx, command).await,
        Command::GlobalNew(ty, value) => match to_val(ctx, value, ty.content())
            .and_then(|value| Global::new(&mut *ctx, ty, value))
        {
            Ok(global) => {
                let ty = ExternType::Global(global.ty(&*ctx));
                extern_reply(ctx, Extern::Global(global), ty)
            }
            Err(error) => Reply::Error(ErrorKind::Type, error.to_string()),
        },
        Command::GlobalGet(global) => {
            let value = global.get(&mut *ctx);
            Reply::Values(vec![out(ctx, &value)])
        }
        Command::GlobalSet(global, value) => {
            let ty = global.ty(&*ctx);
            match to_val(ctx, value, ty.content()).and_then(|value| global.set(&mut *ctx, value)) {
                Ok(()) => Reply::Unit,
                Err(error) => Reply::Error(ErrorKind::Type, error.to_string()),
            }
        }
        Command::TagNew(params) => {
            let engine = ctx.as_context().engine().clone();
            let ty = TagType::new(FuncType::new(&engine, params, []));
            match Tag::new(&mut *ctx, &ty) {
                Ok(tag) => {
                    let ty = ExternType::Tag(tag.ty(&*ctx));
                    extern_reply(ctx, Extern::Tag(tag), ty)
                }
                Err(error) => Reply::Error(ErrorKind::Type, error.to_string()),
            }
        }
        Command::Type(object) => {
            let ty = object.ty(&*ctx);
            extern_reply(ctx, object, ty)
        }
    }
}

async fn memory_command<C: AsContextMut<Data = State>>(
    ctx: &mut C,
    command: MemoryCommand,
) -> Reply {
    match command {
        MemoryCommand::New(ty) => match Memory::new_async(&mut *ctx, ty).await {
            Ok(memory) => {
                let ty = ExternType::Memory(memory.ty(&*ctx));
                extern_reply(ctx, Extern::Memory(memory), ty)
            }
            Err(_) => Reply::Error(
                ErrorKind::Range,
                "WebAssembly.Memory(): could not allocate memory".into(),
            ),
        },
        MemoryCommand::Grow(memory, delta) => match memory.grow_async(&mut *ctx, delta).await {
            Ok(old) => Reply::Int(old),
            Err(_) => Reply::Error(
                ErrorKind::Range,
                "WebAssembly.Memory.grow(): Maximum memory size exceeded".into(),
            ),
        },
        MemoryCommand::Size(memory) => Reply::Int(memory.data_size(&*ctx) as u64),
        MemoryCommand::Read(memory, offset, length) => {
            let data = memory.data(&*ctx);
            usize::try_from(offset)
                .ok()
                .zip(usize::try_from(length).ok())
                .and_then(|(offset, length)| data.get(offset..offset.checked_add(length)?))
                .map_or_else(
                    || Reply::Error(ErrorKind::Range, "memory access out of bounds".into()),
                    |bytes| Reply::Bytes(bytes.to_vec()),
                )
        }
        MemoryCommand::Write(memory, offset, bytes) => {
            let written = usize::try_from(offset)
                .is_ok_and(|offset| memory.write(&mut *ctx, offset, &bytes).is_ok());
            if written {
                Reply::Unit
            } else {
                Reply::Error(ErrorKind::Range, "memory access out of bounds".into())
            }
        }
    }
}

async fn table_command<C: AsContextMut<Data = State>>(ctx: &mut C, command: TableCommand) -> Reply {
    match command {
        TableCommand::New(ty, init) => table_new(ctx, ty, init).await,
        TableCommand::Get(table, index) => match table.get(&mut *ctx, index) {
            Some(element) => Reply::Values(vec![out(ctx, &element.into())]),
            None => Reply::Error(
                ErrorKind::Range,
                "WebAssembly.Table.get(): invalid address".into(),
            ),
        },
        TableCommand::Set(table, index, value) => {
            let ty = table.ty(&*ctx).element().clone();
            match to_ref(ctx, value, &ty) {
                Ok(element) => match table.set(&mut *ctx, index, element) {
                    Ok(()) => Reply::Unit,
                    Err(_) => Reply::Error(
                        ErrorKind::Range,
                        "WebAssembly.Table.set(): invalid address".into(),
                    ),
                },
                Err(error) => Reply::Error(ErrorKind::Type, error.to_string()),
            }
        }
        TableCommand::Grow(table, delta, init) => {
            let ty = table.ty(&*ctx).element().clone();
            match to_ref(ctx, init, &ty) {
                Ok(element) => match table.grow_async(&mut *ctx, delta, element).await {
                    Ok(old) => Reply::Int(old),
                    Err(_) => Reply::Error(
                        ErrorKind::Range,
                        "WebAssembly.Table.grow(): failed to grow table".into(),
                    ),
                },
                Err(error) => Reply::Error(ErrorKind::Type, error.to_string()),
            }
        }
        TableCommand::Size(table) => Reply::Int(table.size(&*ctx)),
    }
}

async fn instantiate<C: AsContextMut<Data = State>>(
    ctx: &mut C,
    module: &Module,
    imports: Vec<Import>,
) -> Reply {
    let mut externs = Vec::with_capacity(imports.len());
    for (ty, import) in module.imports().zip(imports) {
        let made = match (import, ty.ty()) {
            (Import::Extern(object), _) => Ok(object),
            (Import::Host(id), ExternType::Func(func)) => {
                let func = host_func(&mut *ctx, func, id);
                let key = func.to_raw(&mut *ctx).addr();
                let shared = Arc::clone(&ctx.as_context().data().shared);
                lock(&shared).hosts.insert(key, id);
                Ok(Extern::Func(func))
            }
            (Import::Value(value), ExternType::Global(global)) => {
                to_val(ctx, value, global.content())
                    .and_then(|value| Global::new(&mut *ctx, global, value))
                    .map(Extern::Global)
            }
            _ => Err(wasmtime::Error::msg("import kind mismatch")),
        };
        match made {
            Ok(object) => externs.push(object),
            Err(error) => return Reply::Error(ErrorKind::Link, error.to_string()),
        }
    }
    match Instance::new_async(&mut *ctx, module, &externs).await {
        Ok(instance) => {
            let exports: Vec<(String, Extern)> = instance
                .exports(&mut *ctx)
                .map(|export| (export.name().to_owned(), export.into_extern()))
                .collect();
            Reply::Externs(
                exports
                    .into_iter()
                    .map(|(name, object)| {
                        let ty = object.ty(&*ctx);
                        let identity = identity(ctx, &object);
                        (name, object, ty, identity)
                    })
                    .collect(),
            )
        }
        Err(error) => failure(&error, ErrorKind::Link),
    }
}

async fn call<C: AsContextMut<Data = State>>(ctx: &mut C, func: Func, args: Vec<Arg>) -> Reply {
    let ty = func.ty(&*ctx);
    let mut params = Vec::with_capacity(args.len());
    for (arg, ty) in args.into_iter().zip(ty.params()) {
        match to_val(ctx, arg, &ty) {
            Ok(value) => params.push(value),
            Err(error) => return Reply::Error(ErrorKind::Type, error.to_string()),
        }
    }
    let mut results = vec![Val::I32(0); ty.results().len()];
    match func.call_async(&mut *ctx, &params, &mut results).await {
        Ok(()) => Reply::Values(results.iter().map(|value| out(ctx, value)).collect()),
        Err(error) => failure(&error, ErrorKind::Runtime),
    }
}

async fn table_new<C: AsContextMut<Data = State>>(ctx: &mut C, ty: TableType, init: Arg) -> Reply {
    let element = ty.element().clone();
    match to_ref(ctx, init, &element) {
        Ok(init) => match Table::new_async(&mut *ctx, ty, init).await {
            Ok(table) => {
                let ty = ExternType::Table(table.ty(&*ctx));
                extern_reply(ctx, Extern::Table(table), ty)
            }
            Err(_) => Reply::Error(
                ErrorKind::Range,
                "WebAssembly.Table(): could not allocate table".into(),
            ),
        },
        Err(error) => Reply::Error(ErrorKind::Type, error.to_string()),
    }
}

/// The reply for an error of Wasmtime: a trap, an exception of JavaScript, or an error of
/// the kind `otherwise`.
fn failure(error: &wasmtime::Error, otherwise: ErrorKind) -> Reply {
    if let Some(JsException(id)) = error.downcast_ref::<JsException>() {
        return Reply::Thrown(*id);
    }
    if error.downcast_ref::<Abort>().is_some() {
        return Reply::Aborted;
    }
    match error.downcast_ref::<Trap>() {
        Some(Trap::StackOverflow) => Reply::StackOverflow,
        Some(trap) => Reply::Trap(trap_message(*trap)),
        None => Reply::Error(otherwise, format!("{error:#}")),
    }
}

/// V8's message for a trap.
fn trap_message(trap: Trap) -> String {
    match trap {
        Trap::MemoryOutOfBounds => "memory access out of bounds",
        Trap::HeapMisaligned => "operation does not support unaligned accesses",
        Trap::TableOutOfBounds => "table index is out of bounds",
        Trap::IndirectCallToNull | Trap::BadSignature => {
            "null function or function signature mismatch"
        }
        Trap::IntegerOverflow => "divide result unrepresentable",
        Trap::IntegerDivisionByZero => "divide by zero",
        Trap::BadConversionToInteger => "float unrepresentable in integer range",
        Trap::UnreachableCodeReached => "unreachable",
        Trap::NullReference => "dereferencing a null pointer",
        Trap::ArrayOutOfBounds => "array element access out of bounds",
        Trap::AllocationTooLarge => "requested new array is too large",
        Trap::CastFailure => "illegal cast",
        Trap::AtomicWaitNonSharedMemory => "expected shared memory",
        other => return other.to_string(),
    }
    .to_owned()
}

/// A value of the process as a `Val` of the type `ty`.
fn to_val(
    ctx: &mut impl AsContextMut<Data = State>,
    arg: Arg,
    ty: &ValType,
) -> wasmtime::Result<Val> {
    Ok(match (arg, ty) {
        (Arg::I32(value), ValType::I32) => Val::I32(value),
        (Arg::I64(value), ValType::I64) => Val::I64(value),
        (Arg::F32(bits), ValType::F32) => Val::F32(bits),
        (Arg::F64(bits), ValType::F64) => Val::F64(bits),
        (arg, ValType::Ref(ty)) => to_ref(ctx, arg, ty)?.into(),
        _ => {
            return Err(wasmtime::Error::msg(
                "type incompatibility when transforming from/to JS",
            ));
        }
    })
}

fn to_ref(
    ctx: &mut impl AsContextMut<Data = State>,
    arg: Arg,
    ty: &RefType,
) -> wasmtime::Result<Ref> {
    let reference = match arg {
        Arg::Func(func) => Ref::Func(func),
        Arg::Extern(None) => match ty.heap_type() {
            HeapType::Func | HeapType::ConcreteFunc(_) | HeapType::NoFunc => Ref::Func(None),
            HeapType::Exn | HeapType::ConcreteExn(_) => Ref::Exn(None),
            HeapType::Extern | HeapType::NoExtern => Ref::Extern(None),
            _ => Ref::Any(None),
        },
        Arg::Extern(Some(id)) => Ref::Extern(Some(ExternRef::new(&mut *ctx, id)?)),
        _ => {
            return Err(wasmtime::Error::msg(
                "type incompatibility when transforming from/to JS",
            ));
        }
    };
    if !ty.is_nullable() && reference.is_null() {
        return Err(wasmtime::Error::msg(
            "type incompatibility when transforming from/to JS",
        ));
    }
    Ok(reference)
}

fn out(ctx: &mut impl AsContextMut<Data = State>, value: &Val) -> Out {
    match value {
        Val::I32(value) => Out::I32(*value),
        Val::I64(value) => Out::I64(*value),
        Val::F32(bits) => Out::F32(*bits),
        Val::F64(bits) => Out::F64(*bits),
        Val::V128(_) => Out::V128,
        Val::FuncRef(Some(func)) => Out::Func(*func, func.to_raw(&mut *ctx).addr()),
        Val::ExternRef(Some(reference)) => reference
            .data(ctx.as_context())
            .ok()
            .flatten()
            .and_then(|data| data.downcast_ref::<u64>())
            .map_or(Out::Other, |id| Out::Extern(*id)),
        Val::FuncRef(None) | Val::ExternRef(None) | Val::AnyRef(None) | Val::ExnRef(None) => {
            Out::Null
        }
        _ => Out::Other,
    }
}

// The NIFs.

/// A new store for the calling process, under the memory limit `limit` in bytes.
#[rustler::nif]
fn wasm_store(limit: u64) -> NifResult<ResourceArc<WasmStore>> {
    MEMORY_LIMIT.store(limit, Ordering::Relaxed);
    let engine = engine().ok_or(Error::Atom("no_engine"))?;
    let shared = Arc::new(Mutex::new(Shared::default()));
    let mut store = Store::new(
        engine,
        State {
            shared: Arc::clone(&shared),
            memory_bytes: 0,
        },
    );
    store.limiter(|state| state);
    store.set_epoch_deadline(1);
    store.epoch_deadline_callback(|_| Ok(UpdateDeadline::Yield(1)));
    let driver = Box::pin(drive(store, Arc::clone(&shared)));
    Ok(ResourceArc::new(WasmStore {
        shared,
        driver: Mutex::new(driver),
    }))
}

/// Compiles the bytes of a module: `{ok, Module}` or `{error, Message}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn wasm_compile<'a>(env: Env<'a>, bytes: Binary<'a>) -> NifResult<Term<'a>> {
    let engine = engine().ok_or(Error::Atom("no_engine"))?;
    Ok(match Module::new(engine, bytes.as_slice()) {
        Ok(module) => (atoms::ok(), ResourceArc::new(WasmModule { module })).encode(env),
        Err(error) => (atoms::error(), format!("{error:#}")).encode(env),
    })
}

/// Whether the bytes are a valid module.
#[rustler::nif(schedule = "DirtyCpu")]
fn wasm_validate(bytes: Binary<'_>) -> NifResult<bool> {
    let engine = engine().ok_or(Error::Atom("no_engine"))?;
    Ok(Module::validate(engine, bytes.as_slice()).is_ok())
}

/// The imports of a module: `[{Module, Name, Type}]`.
#[rustler::nif]
fn wasm_imports(env: Env<'_>, module: ResourceArc<WasmModule>) -> Vec<Term<'_>> {
    module
        .module
        .imports()
        .map(|import| {
            make_tuple(
                env,
                &[
                    import.module().encode(env),
                    import.name().encode(env),
                    encode_type(env, &import.ty(), None, None),
                ],
            )
        })
        .collect()
}

/// The exports of a module: `[{Name, Type}]`.
#[rustler::nif]
fn wasm_exports(env: Env<'_>, module: ResourceArc<WasmModule>) -> Vec<Term<'_>> {
    module
        .module
        .exports()
        .map(|export| {
            make_tuple(
                env,
                &[
                    export.name().encode(env),
                    encode_type(env, &export.ty(), None, None),
                ],
            )
        })
        .collect()
}

/// Sends a command to the store, and runs it for one time slice.
#[rustler::nif]
fn wasm_command<'a>(
    env: Env<'a>,
    store: ResourceArc<WasmStore>,
    command: Term<'a>,
) -> NifResult<Term<'a>> {
    let command = decode_command(&lock(&store.shared), command)?;
    lock(&store.shared).command = Some(command);
    Ok(poll(env, &store))
}

/// Runs the command in flight for one more time slice.
#[rustler::nif]
fn wasm_poll(env: Env<'_>, store: ResourceArc<WasmStore>) -> Term<'_> {
    poll(env, &store)
}

/// Polls the driver once: `{done, Reply, Grown}`, `{call, Id, Args, ResultTypes, Grown}`,
/// or `yield`.
fn poll<'a>(env: Env<'a>, store: &WasmStore) -> Term<'a> {
    let started = Instant::now();
    let _ = lock(&store.driver)
        .as_mut()
        .poll(&mut Context::from_waker(Waker::noop()));
    let used = started.elapsed().as_micros() * 100 / TICK.as_micros();
    rustler::schedule::consume_timeslice(env, i32::try_from(used.clamp(1, 100)).unwrap_or(100));
    let mut shared = lock(&store.shared);
    let grown = std::mem::take(&mut shared.grown);
    if let Some(reply) = shared.reply.take() {
        let reply = encode_reply(env, &mut shared, reply);
        return make_tuple(env, &[atoms::done().encode(env), reply, grown.encode(env)]);
    }
    if let Some(Outgoing { id, args, results }) = shared.outgoing.take() {
        let args: Vec<Term<'a>> = args
            .into_iter()
            .map(|value| encode_out(env, &mut shared, value))
            .collect();
        let results: Vec<Term<'a>> = results.iter().map(|ty| encode_val_type(env, ty)).collect();
        return make_tuple(
            env,
            &[
                atoms::call().encode(env),
                id.encode(env),
                args.encode(env),
                results.encode(env),
                grown.encode(env),
            ],
        );
    }
    shared.grown = grown;
    atoms::yield_().encode(env)
}

// Decoding the terms of the process.

fn bad() -> Error {
    Error::BadArg
}

fn decode_command(shared: &Shared, term: Term<'_>) -> NifResult<Command> {
    let items = get_tuple(term)?;
    let (tag, rest) = items.split_first().ok_or_else(bad)?;
    let tag: rustler::Atom = tag.decode()?;
    let arg = |index: usize| rest.get(index).copied().ok_or_else(bad);
    let global = |index: usize| match handle(shared, arg(index)?)? {
        Extern::Global(global) => Ok(global),
        _ => Err(bad()),
    };
    Ok(if tag == atoms::instantiate() {
        let module: ResourceArc<WasmModule> = arg(0)?.decode()?;
        let imports = arg(1)?
            .decode::<Vec<Term<'_>>>()?
            .into_iter()
            .map(|import| decode_import(shared, import))
            .collect::<NifResult<_>>()?;
        Command::Instantiate(module.module.clone(), imports)
    } else if tag == atoms::call() {
        let Extern::Func(func) = handle(shared, arg(0)?)? else {
            return Err(bad());
        };
        Command::Call(func, decode_args(shared, arg(1)?)?)
    } else if tag == atoms::return_() {
        Command::Return(decode_returned(shared, arg(0)?)?)
    } else if let Some(command) = decode_memory_command(shared, tag, rest)? {
        Command::Memory(command)
    } else if let Some(command) = decode_table_command(shared, tag, rest)? {
        Command::Table(command)
    } else if tag == atoms::global_new() {
        let content = decode_val_type(arg(0)?)?;
        let mutability = if arg(1)?.decode::<bool>()? {
            Mutability::Var
        } else {
            Mutability::Const
        };
        Command::GlobalNew(
            GlobalType::new(content, mutability),
            decode_arg(shared, arg(2)?)?,
        )
    } else if tag == atoms::global_get() {
        Command::GlobalGet(global(0)?)
    } else if tag == atoms::global_set() {
        Command::GlobalSet(global(0)?, decode_arg(shared, arg(1)?)?)
    } else if tag == atoms::tag_new() {
        let params = arg(0)?
            .decode::<Vec<Term<'_>>>()?
            .into_iter()
            .map(decode_val_type)
            .collect::<NifResult<_>>()?;
        Command::TagNew(params)
    } else if tag == atoms::memory_type()
        || tag == atoms::table_type()
        || tag == atoms::global_type()
        || tag == atoms::func_type()
    {
        Command::Type(handle(shared, arg(0)?)?)
    } else {
        return Err(bad());
    })
}

fn decode_memory_command(
    shared: &Shared,
    tag: rustler::Atom,
    rest: &[Term<'_>],
) -> NifResult<Option<MemoryCommand>> {
    let arg = |index: usize| rest.get(index).copied().ok_or_else(bad);
    let memory = |index: usize| match handle(shared, arg(index)?)? {
        Extern::Memory(memory) => Ok(memory),
        _ => Err(bad()),
    };
    Ok(Some(if tag == atoms::memory_new() {
        let minimum: u64 = arg(0)?.decode()?;
        let maximum = decode_maximum(arg(1)?)?;
        let shared_memory: bool = arg(2)?.decode()?;
        let ty = MemoryType::builder()
            .min(minimum)
            .max(maximum)
            .shared(shared_memory)
            .build()
            .map_err(|_| bad())?;
        MemoryCommand::New(ty)
    } else if tag == atoms::memory_grow() {
        MemoryCommand::Grow(memory(0)?, arg(1)?.decode()?)
    } else if tag == atoms::memory_size() {
        MemoryCommand::Size(memory(0)?)
    } else if tag == atoms::memory_read() {
        MemoryCommand::Read(memory(0)?, arg(1)?.decode()?, arg(2)?.decode()?)
    } else if tag == atoms::memory_write() {
        let bytes: Binary<'_> = arg(2)?.decode()?;
        MemoryCommand::Write(memory(0)?, arg(1)?.decode()?, bytes.as_slice().to_vec())
    } else {
        return Ok(None);
    }))
}

fn decode_table_command(
    shared: &Shared,
    tag: rustler::Atom,
    rest: &[Term<'_>],
) -> NifResult<Option<TableCommand>> {
    let arg = |index: usize| rest.get(index).copied().ok_or_else(bad);
    let table = |index: usize| match handle(shared, arg(index)?)? {
        Extern::Table(table) => Ok(table),
        _ => Err(bad()),
    };
    Ok(Some(if tag == atoms::table_new() {
        let element = decode_ref_type(arg(0)?)?;
        let minimum: u32 = arg(1)?.decode()?;
        let maximum = decode_maximum(arg(2)?)?
            .map(u32::try_from)
            .transpose()
            .map_err(|_| bad())?;
        TableCommand::New(
            TableType::new(element, minimum, maximum),
            decode_arg(shared, arg(3)?)?,
        )
    } else if tag == atoms::table_get() {
        TableCommand::Get(table(0)?, arg(1)?.decode()?)
    } else if tag == atoms::table_set() {
        TableCommand::Set(table(0)?, arg(1)?.decode()?, decode_arg(shared, arg(2)?)?)
    } else if tag == atoms::table_grow() {
        TableCommand::Grow(table(0)?, arg(1)?.decode()?, decode_arg(shared, arg(2)?)?)
    } else if tag == atoms::table_size() {
        TableCommand::Size(table(0)?)
    } else {
        return Ok(None);
    }))
}

fn handle(shared: &Shared, term: Term<'_>) -> NifResult<Extern> {
    let index: usize = term.decode()?;
    shared.objects.get(index).cloned().ok_or_else(bad)
}

fn decode_maximum(term: Term<'_>) -> NifResult<Option<u64>> {
    if term
        .decode::<rustler::Atom>()
        .is_ok_and(|atom| atom == atoms::none())
    {
        Ok(None)
    } else {
        Ok(Some(term.decode()?))
    }
}

fn decode_import(shared: &Shared, term: Term<'_>) -> NifResult<Import> {
    let items = get_tuple(term)?;
    let [tag, value] = items.as_slice() else {
        return Err(bad());
    };
    let tag: rustler::Atom = tag.decode()?;
    if tag == atoms::host() {
        Ok(Import::Host(value.decode()?))
    } else if tag == atoms::value() {
        Ok(Import::Value(decode_arg(shared, *value)?))
    } else {
        Ok(Import::Extern(handle(shared, *value)?))
    }
}

fn decode_args(shared: &Shared, term: Term<'_>) -> NifResult<Vec<Arg>> {
    term.decode::<Vec<Term<'_>>>()?
        .into_iter()
        .map(|value| decode_arg(shared, value))
        .collect()
}

fn decode_returned(shared: &Shared, term: Term<'_>) -> NifResult<Returned> {
    if term
        .decode::<rustler::Atom>()
        .is_ok_and(|atom| atom == atoms::aborted())
    {
        return Ok(Returned::Aborted);
    }
    let items = get_tuple(term)?;
    let [tag, value] = items.as_slice() else {
        return Err(bad());
    };
    let tag: rustler::Atom = tag.decode()?;
    if tag == atoms::thrown() {
        Ok(Returned::Thrown(value.decode()?))
    } else {
        Ok(Returned::Values(decode_args(shared, *value)?))
    }
}

/// `{i32, I}`, `{i64, I}`, `{f32, N}`, `{f64, N}`, `{funcref, null | Handle}`, or
/// `{externref, null | Id}`.
fn decode_arg(shared: &Shared, term: Term<'_>) -> NifResult<Arg> {
    let items = get_tuple(term)?;
    let [tag, value] = items.as_slice() else {
        return Err(bad());
    };
    let tag: rustler::Atom = tag.decode()?;
    let is_null = value
        .decode::<rustler::Atom>()
        .is_ok_and(|atom| atom == atoms::null());
    Ok(if tag == atoms::i32() {
        Arg::I32(value.decode()?)
    } else if tag == atoms::i64() {
        Arg::I64(value.decode()?)
    } else if tag == atoms::f32() {
        #[allow(clippy::cast_possible_truncation)]
        Arg::F32((decode_number(*value)? as f32).to_bits())
    } else if tag == atoms::f64() {
        Arg::F64(decode_number(*value)?.to_bits())
    } else if tag == atoms::funcref() {
        if is_null {
            Arg::Func(None)
        } else {
            let Extern::Func(func) = handle(shared, *value)? else {
                return Err(bad());
            };
            Arg::Func(Some(func))
        }
    } else if tag == atoms::externref() {
        Arg::Extern(if is_null { None } else { Some(value.decode()?) })
    } else {
        return Err(bad());
    })
}

/// A JavaScript number: a float, an integer, or the atom of a value that a float of
/// Erlang cannot hold.
fn decode_number(term: Term<'_>) -> NifResult<f64> {
    if let Ok(value) = term.decode::<f64>() {
        return Ok(value);
    }
    if let Ok(value) = term.decode::<i64>() {
        #[allow(clippy::cast_precision_loss)]
        return Ok(value as f64);
    }
    let atom: rustler::Atom = term.decode()?;
    if atom == atoms::nan() {
        Ok(f64::NAN)
    } else if atom == atoms::infinity() {
        Ok(f64::INFINITY)
    } else if atom == atoms::negative_infinity() {
        Ok(f64::NEG_INFINITY)
    } else {
        Err(bad())
    }
}

fn decode_val_type(term: Term<'_>) -> NifResult<ValType> {
    let atom: rustler::Atom = term.decode()?;
    Ok(if atom == atoms::i32() {
        ValType::I32
    } else if atom == atoms::i64() {
        ValType::I64
    } else if atom == atoms::f32() {
        ValType::F32
    } else if atom == atoms::f64() {
        ValType::F64
    } else if atom == atoms::v128() {
        ValType::V128
    } else {
        ValType::Ref(decode_ref_type(term)?)
    })
}

fn decode_ref_type(term: Term<'_>) -> NifResult<RefType> {
    let atom: rustler::Atom = term.decode()?;
    Ok(if atom == atoms::funcref() {
        RefType::FUNCREF
    } else if atom == atoms::externref() {
        RefType::EXTERNREF
    } else if atom == atoms::anyref() {
        RefType::ANYREF
    } else if atom == atoms::exnref() {
        RefType::EXNREF
    } else {
        return Err(bad());
    })
}

// Encoding terms for the process.

fn encode_number(env: Env<'_>, value: f64) -> Term<'_> {
    if value.is_nan() {
        atoms::nan().encode(env)
    } else if value == f64::INFINITY {
        atoms::infinity().encode(env)
    } else if value == f64::NEG_INFINITY {
        atoms::negative_infinity().encode(env)
    } else {
        value.encode(env)
    }
}

fn encode_out<'a>(env: Env<'a>, shared: &mut Shared, value: Out) -> Term<'a> {
    match value {
        Out::I32(value) => (atoms::i32(), value).encode(env),
        Out::I64(value) => (atoms::i64(), value).encode(env),
        Out::F32(bits) => (
            atoms::f32(),
            encode_number(env, f64::from(f32::from_bits(bits))),
        )
            .encode(env),
        Out::F64(bits) => (atoms::f64(), encode_number(env, f64::from_bits(bits))).encode(env),
        Out::V128 => atoms::v128().encode(env),
        Out::Null => atoms::null().encode(env),
        Out::Func(func, key) => {
            if let Some(id) = shared.hosts.get(&key) {
                return (atoms::host(), *id).encode(env);
            }
            let handle = intern(shared, Identity::Func(key), Extern::Func(func));
            (atoms::funcref(), handle).encode(env)
        }
        Out::Extern(id) => (atoms::externref(), id).encode(env),
        Out::Other => atoms::other().encode(env),
    }
}

/// The handle of an extern, the same one each time for one object.
fn intern(shared: &mut Shared, identity: Identity, object: Extern) -> usize {
    if let Some(handle) = shared.handles.get(&identity) {
        return *handle;
    }
    let handle = shared.objects.len();
    if let Extern::Memory(memory) = &object {
        // The size is unknown here; the first check after this records it.
        shared.memories.push((handle, *memory, usize::MAX));
    }
    shared.objects.push(object);
    shared.handles.insert(identity, handle);
    handle
}

/// What makes an extern the object it is: the address of a func ref, as V8 caches one
/// wrapper for each function, or the index of the definition in the store.
fn identity(ctx: &mut impl AsContextMut<Data = State>, object: &Extern) -> Option<Identity> {
    match object {
        Extern::Func(func) => Some(Identity::Func(func.to_raw(&mut *ctx).addr())),
        Extern::Memory(memory) => Some(Identity::Memory(memory.debug_index_in_store())),
        Extern::Table(table) => Some(Identity::Table(table.debug_index_in_store())),
        Extern::Global(global) => Some(Identity::Global(global.debug_index_in_store())),
        Extern::Tag(tag) => Some(Identity::Tag(tag.debug_index_in_store())),
        Extern::SharedMemory(_) => None,
    }
}

fn extern_reply(
    ctx: &mut impl AsContextMut<Data = State>,
    object: Extern,
    ty: ExternType,
) -> Reply {
    let identity = identity(ctx, &object);
    Reply::Extern(object, ty, identity)
}

/// The handle of an extern that a reply names: the same one for one object.
fn extern_handle(shared: &mut Shared, object: Extern, identity: Option<Identity>) -> usize {
    if let Some(identity) = identity {
        return intern(shared, identity, object);
    }
    let handle = shared.objects.len();
    shared.objects.push(object);
    handle
}

/// The id of the JavaScript function of a host func.
fn host_of(shared: &Shared, identity: Option<&Identity>) -> Option<u64> {
    match identity {
        Some(Identity::Func(key)) => shared.hosts.get(key).copied(),
        _ => None,
    }
}

fn encode_reply<'a>(env: Env<'a>, shared: &mut Shared, reply: Reply) -> Term<'a> {
    match reply {
        Reply::Unit => atoms::ok().encode(env),
        Reply::Values(values) => {
            let values: Vec<Term<'a>> = values
                .into_iter()
                .map(|value| encode_out(env, shared, value))
                .collect();
            (atoms::ok(), values).encode(env)
        }
        Reply::Externs(exports) => {
            let exports: Vec<Term<'a>> = exports
                .into_iter()
                .map(|(name, object, ty, identity)| {
                    let host = host_of(shared, identity.as_ref());
                    let handle = extern_handle(shared, object, identity);
                    make_tuple(
                        env,
                        &[name.encode(env), encode_type(env, &ty, Some(handle), host)],
                    )
                })
                .collect();
            (atoms::ok(), exports).encode(env)
        }
        Reply::Extern(object, ty, identity) => {
            let host = host_of(shared, identity.as_ref());
            let handle = extern_handle(shared, object, identity);
            (atoms::ok(), encode_type(env, &ty, Some(handle), host)).encode(env)
        }
        Reply::Int(value) => (atoms::ok(), value).encode(env),
        Reply::Bytes(bytes) => {
            let binary: Binary<'a> = NewBinary::from_slice(env, &bytes).into();
            (atoms::ok(), binary).encode(env)
        }
        Reply::Trap(message) => (atoms::trap(), message).encode(env),
        Reply::StackOverflow => atoms::stack_overflow().encode(env),
        Reply::Thrown(id) => (atoms::thrown(), id).encode(env),
        Reply::Aborted => atoms::aborted().encode(env),
        Reply::Error(kind, message) => {
            let kind = match kind {
                ErrorKind::Link => atoms::link_error(),
                ErrorKind::Range => atoms::range_error(),
                ErrorKind::Type => atoms::type_error(),
                ErrorKind::Runtime => atoms::runtime_error(),
            };
            (atoms::error(), kind, message).encode(env)
        }
    }
}

/// `{func, H, Params, Results, Host}`, `{memory, H, Min, Max, Shared, Is64}`,
/// `{table, H, Element, Min, Max}`, `{global, H, Type, Mutable}`, or `{tag, H, Params}`,
/// where H is the handle, or `none` for the type of an import or an export, and Host is
/// the id of the JavaScript function of a host func, or `none`.
fn encode_type<'a>(
    env: Env<'a>,
    ty: &ExternType,
    handle: Option<usize>,
    host: Option<u64>,
) -> Term<'a> {
    let handle = handle.map_or_else(|| atoms::none().encode(env), |handle| handle.encode(env));
    let host = host.map_or_else(|| atoms::none().encode(env), |id| id.encode(env));
    let maximum = |maximum: Option<u64>| {
        maximum.map_or_else(|| atoms::none().encode(env), |maximum| maximum.encode(env))
    };
    match ty {
        ExternType::Func(func) => make_tuple(
            env,
            &[
                atoms::func().encode(env),
                handle,
                encode_types(env, func.params()),
                encode_types(env, func.results()),
                host,
            ],
        ),
        ExternType::Memory(memory) => make_tuple(
            env,
            &[
                atoms::memory().encode(env),
                handle,
                memory.minimum().encode(env),
                maximum(memory.maximum()),
                memory.is_shared().encode(env),
                memory.is_64().encode(env),
            ],
        ),
        ExternType::Table(table) => make_tuple(
            env,
            &[
                atoms::table().encode(env),
                handle,
                encode_ref_type(env, table.element()),
                table.minimum().encode(env),
                maximum(table.maximum()),
            ],
        ),
        ExternType::Global(global) => make_tuple(
            env,
            &[
                atoms::global().encode(env),
                handle,
                encode_val_type(env, global.content()),
                (global.mutability() == Mutability::Var).encode(env),
            ],
        ),
        ExternType::Tag(tag) => make_tuple(
            env,
            &[
                atoms::tag().encode(env),
                handle,
                encode_types(env, tag.ty().params()),
            ],
        ),
    }
}

fn encode_types(env: Env<'_>, types: impl Iterator<Item = ValType>) -> Term<'_> {
    types
        .map(|ty| encode_val_type(env, &ty))
        .collect::<Vec<_>>()
        .encode(env)
}

fn encode_val_type<'a>(env: Env<'a>, ty: &ValType) -> Term<'a> {
    match ty {
        ValType::I32 => atoms::i32().encode(env),
        ValType::I64 => atoms::i64().encode(env),
        ValType::F32 => atoms::f32().encode(env),
        ValType::F64 => atoms::f64().encode(env),
        ValType::V128 => atoms::v128().encode(env),
        ValType::Ref(reference) => encode_ref_type(env, reference),
    }
}

fn encode_ref_type<'a>(env: Env<'a>, ty: &RefType) -> Term<'a> {
    match ty.heap_type() {
        HeapType::Func | HeapType::ConcreteFunc(_) | HeapType::NoFunc => atoms::funcref(),
        HeapType::Extern | HeapType::NoExtern => atoms::externref(),
        HeapType::Exn | HeapType::ConcreteExn(_) => atoms::exnref(),
        _ => atoms::anyref(),
    }
    .encode(env)
}
