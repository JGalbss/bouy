//! Runs compiled code in time slices, on a stack of its own, over a heap of its own.
//!
//! A run is a coroutine (`corosensei`). The machine code spends one unit of fuel at the
//! start of each function and on each turn of a loop. When the fuel is gone it calls
//! [`buoy_tick`], which refills it, and suspends the coroutine once the slice has run for
//! [`SLICE`]: the NIF then returns to the BEAM scheduler with `enif_schedule_nif`, and
//! resumes the coroutine when the scheduler calls it again. So a long run yields as an
//! Erlang process does, and the process can be killed between two slices.
//!
//! A bail suspends the coroutine for the last time: the caller drops the run, and the
//! Erlang tier runs the call again from its start. Nothing outside the run sees the
//! state that the run built, so that second run is exact.
//!
//! Each run allocates its objects in a [`Heap`]: chunks of memory that the run fills from
//! the front and that are all free again when the run ends. A context, one per BEAM
//! process, keeps its stack and its heap between runs. The objects that a run receives
//! and gives back cross by copy (`crate::boundary`).

#![allow(unsafe_code)]

use std::sync::Arc;
use std::time::{Duration, Instant};

use buoy_jit_ir::{Bail, Ty};

use crate::boundary::{self, Item};
use corosensei::stack::{DefaultStack, Stack};
use corosensei::{Coroutine, CoroutineResult, Yielder};

use crate::codegen::Code;

/// How long a slice runs before the coroutine yields. An Erlang process spends its 4000
/// reductions in about 0.1 to 0.3 ms, and the speed spike measured this slice.
pub const SLICE: Duration = Duration::from_micros(200);

/// The fuel between two calls of [`buoy_tick`]: loop turns and function entries.
const FUEL: i64 = 4096;

/// The size of the stack of a run. The memory is reserved, and the system backs a page
/// only when the code first touches it.
const STACK_SIZE: usize = 8 << 20;

/// The room below the limit of the stack that the machine code checks against, for the
/// frames of the helpers and of the coroutine switch.
const STACK_MARGIN: usize = 64 << 10;

/// The size of a chunk of the heap.
const CHUNK: usize = 1 << 20;

/// The chunks that a context keeps for its next run.
const KEPT_CHUNKS: usize = 4;

/// The state that the machine code reads and writes, at the offsets of
/// [`crate::codegen::frame`]. The coroutine and the helpers find the rest of the run from
/// it.
#[repr(C)]
#[derive(Debug)]
pub struct Frame {
    pub fuel: i64,
    pub heap_next: u64,
    pub heap_end: u64,
    pub stack_limit: u64,
    pub result: u64,
    pub globals: u64,
    yielder: *const Yielder<(), Event>,
    slice_start: Instant,
    heap: Heap,
}

/// What a suspended coroutine tells the caller.
#[derive(Debug, Clone, Copy)]
pub enum Event {
    Slice,
    Bail(u8),
}

/// A value outside the heap of a run: an argument, a global, a field of an item, or a
/// result.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Num(f64),
    Bool(bool),
    Null,
    Undefined,
    /// A string, as its UTF-16 code units.
    Str(Vec<u16>),
    /// The object or the array at this index of the items.
    Ref(u32),
}

/// What a run that ends gives back.
#[derive(Debug, Clone, PartialEq)]
pub struct Finished {
    pub result: Value,
    /// The values of the globals that the code writes, in the order of
    /// [`crate::codegen::Layout::written`].
    pub written: Vec<Value>,
    /// The items that the run received, as it leaves them, and then the objects and arrays
    /// that the run made and that the globals it writes or the items reach.
    pub items: Vec<Item>,
}

/// The end of a slice.
#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    Done(Box<Finished>),
    Bail(Bail),
    /// The slice is spent, and the run continues in the next one.
    Yield,
}

/// The chunks of memory of a run. The machine code allocates from the front of the last
/// chunk, between `heap_next` and `heap_end` of the frame, and calls [`buoy_alloc`] when
/// the chunk is full.
#[derive(Debug, Default)]
pub struct Heap {
    chunks: Vec<Box<[u64]>>,
    /// The chunks in use by the run: the others wait for reuse.
    used: usize,
    /// The bytes that the run may allocate.
    limit: usize,
}

impl Heap {
    /// A chunk of at least `bytes`, made the current chunk of the frame.
    fn next_chunk(&mut self, bytes: usize) -> Option<(u64, u64)> {
        let words = bytes.div_ceil(8).max(CHUNK / 8);
        let reusable = self
            .chunks
            .get(self.used)
            .is_some_and(|chunk| chunk.len() >= words);
        if !reusable {
            let total: usize = self.chunks.iter().map(|chunk| chunk.len() * 8).sum();
            if total + words * 8 > self.limit {
                return None;
            }
            let chunk = vec![0u64; words].into_boxed_slice();
            self.chunks.insert(self.used, chunk);
        }
        let chunk = self.chunks.get_mut(self.used)?;
        self.used += 1;
        let start = chunk.as_mut_ptr() as u64;
        Some((start, start + (chunk.len() * 8) as u64))
    }
}

impl Frame {
    /// The address of `words` new words of the heap, outside the machine code. `None` when
    /// the run would pass its limit.
    pub fn allocate_words(&mut self, words: usize) -> Option<*mut u64> {
        let bytes = u64::try_from(words.checked_mul(8)?).ok()?;
        let next = self.heap_next;
        if let Some(end) = next.checked_add(bytes)
            && end <= self.heap_end
        {
            self.heap_next = end;
            return Some(next as *mut u64);
        }
        let (start, end) = self.heap.next_chunk(usize::try_from(bytes).ok()?)?;
        self.heap_next = start + bytes;
        self.heap_end = end;
        Some(start as *mut u64)
    }
}

/// A run between two slices.
struct Running {
    coroutine: Coroutine<(), Event, (), DefaultStack>,
    /// Keeps the machine code alive while the run uses it.
    code: Arc<Code>,
    entry: usize,
    /// The addresses of the items that the run received.
    items: boundary::Imported,
}

// SAFETY: the coroutine runs only machine code of `Code` and the helpers of this module,
// which keep nothing on its stack that belongs to one thread, so a slice may resume on
// another scheduler thread.
unsafe impl Send for Running {}

/// The stack, heap, and run of one BEAM process.
pub struct Context {
    stack: Option<DefaultStack>,
    frame: Box<Frame>,
    running: Option<Running>,
    /// The words of the arguments and the globals of the run, which the machine code reads
    /// and writes.
    words: Vec<u64>,
}

// SAFETY: see `Running`; the frame holds raw pointers into the run, which only the thread
// that holds the context uses.
unsafe impl Send for Context {}

impl std::fmt::Debug for Context {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Context")
            .field("running", &self.running.is_some())
            .finish_non_exhaustive()
    }
}

impl Context {
    /// A context whose runs may allocate `heap_limit` bytes.
    #[must_use]
    pub fn new(heap_limit: usize) -> Self {
        Self {
            stack: None,
            frame: Box::new(Frame {
                fuel: FUEL,
                heap_next: 0,
                heap_end: 0,
                stack_limit: 0,
                result: 0,
                globals: 0,
                yielder: std::ptr::null(),
                slice_start: Instant::now(),
                heap: Heap {
                    limit: heap_limit,
                    ..Heap::default()
                },
            }),
            running: None,
            words: Vec::new(),
        }
    }

    /// Starts the entry `entry` of `code` with `args`, `globals`, and the `items` that
    /// they refer to, and runs its first slice. `None` when a value does not have the type
    /// of its place, or a run is in progress.
    pub fn start(
        &mut self,
        code: &Arc<Code>,
        entry: usize,
        args: &[Value],
        globals: &[Value],
        items: &[Item],
    ) -> Option<Step> {
        if self.running.is_some() {
            return None;
        }
        let function = code.entry(entry)?;
        let args = args.get(..function.params.len())?;
        if globals.len() != function.globals.len() {
            return None;
        }
        let frame = &mut *self.frame;
        frame.fuel = FUEL;
        frame.result = 0;
        frame.heap.used = 0;
        let (next, end) = frame.heap.next_chunk(0)?;
        frame.heap_next = next;
        frame.heap_end = end;
        let places = function.params.iter().chain(&function.globals);
        let values = args.iter().chain(globals);
        let (words, imported) = boundary::import(frame, code.layout(), places.zip(values), items)?;
        self.words = words;
        let stack = match self.stack.take() {
            Some(stack) => stack,
            None => DefaultStack::new(STACK_SIZE).ok()?,
        };
        let limit = stack.limit().get() + STACK_MARGIN;
        let frame = &mut *self.frame;
        frame.stack_limit = limit as u64;
        let frame_ptr: *mut Frame = frame;
        let words_ptr = self.words.as_ptr();
        let address = function.address;
        let coroutine = Coroutine::with_stack(stack, move |yielder: &Yielder<(), Event>, ()| {
            // SAFETY: the frame and the words outlive the coroutine, and `address` is an
            // entry of the code that the run keeps alive, of the signature that `codegen`
            // gives it.
            unsafe {
                (*frame_ptr).yielder = yielder;
                let entry: extern "C" fn(*mut Frame, *const u64) =
                    std::mem::transmute::<*const u8, _>(address);
                entry(frame_ptr, words_ptr);
            }
        });
        self.running = Some(Running {
            coroutine,
            code: Arc::clone(code),
            entry,
            items: imported,
        });
        Some(self.resume())
    }

    /// Runs the next slice of the run.
    pub fn resume(&mut self) -> Step {
        let Some(running) = self.running.as_mut() else {
            return Step::Bail(Bail::Throw);
        };
        self.frame.slice_start = Instant::now();
        match running.coroutine.resume(()) {
            CoroutineResult::Yield(Event::Slice) => Step::Yield,
            CoroutineResult::Yield(Event::Bail(code)) => {
                self.finish();
                Step::Bail(Bail::from_code(code).unwrap_or(Bail::Throw))
            }
            CoroutineResult::Return(()) => {
                let finished = self.export();
                self.finish();
                finished.map_or(Step::Bail(Bail::Memory), |finished| {
                    Step::Done(Box::new(finished))
                })
            }
        }
    }

    /// The result, the written globals, and the items of a run that returned, read from
    /// its heap before the heap is reused.
    fn export(&self) -> Option<Finished> {
        let running = self.running.as_ref()?;
        let function = running.code.entry(running.entry)?;
        let bits = self.frame.result;
        let result = match function.result {
            Ty::Num => Value::Num(f64::from_bits(bits)),
            Ty::Bool => Value::Bool(bits & 0xff != 0),
            _ => Value::Undefined,
        };
        let layout = running.code.layout();
        let params = function.params.len();
        let written = layout.written.iter().map(|&index| {
            let index = index as usize;
            (self.words[params + index], &function.globals[index])
        });
        // SAFETY: the run returned, so the words of the written globals and the fields of
        // the items hold values of their types in its heap, which nothing has reused.
        let (written, items) = unsafe { boundary::export(layout, written, &running.items) };
        Some(Finished {
            result,
            written,
            items,
        })
    }

    /// Drops the run and keeps its stack for the next one.
    fn finish(&mut self) {
        if let Some(mut running) = self.running.take() {
            // SAFETY: a suspended run holds only frames of machine code and of the
            // helpers, none of which needs to drop anything, so the stack can go back to
            // its start without unwinding.
            unsafe { running.coroutine.force_reset() };
            self.stack = Some(running.coroutine.into_stack());
            drop(running.code);
        }
        self.frame.yielder = std::ptr::null();
        self.frame.heap.chunks.truncate(KEPT_CHUNKS);
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        self.finish();
    }
}

/// Suspends the run with `event`.
///
/// # Safety
///
/// `frame` must be the frame of a run that is executing on its coroutine.
unsafe fn suspend(frame: *mut Frame, event: Event) {
    // SAFETY: the coroutine set the yielder before it called the machine code.
    unsafe {
        if let Some(yielder) = (*frame).yielder.as_ref() {
            yielder.suspend(event);
        }
    }
}

/// Yields when the slice is spent, and returns the new fuel.
pub extern "C" fn buoy_tick(frame: *mut Frame) -> i64 {
    // SAFETY: the machine code passes the frame of its run.
    unsafe {
        if (*frame).slice_start.elapsed() >= SLICE {
            suspend(frame, Event::Slice);
        }
    }
    FUEL
}

/// Ends the run with a bail. It never returns.
pub extern "C" fn buoy_bail(frame: *mut Frame, reason: i32) {
    let code = u8::try_from(reason).unwrap_or(Bail::Throw as u8);
    // SAFETY: the machine code passes the frame of its run, whose coroutine the caller
    // resets after this suspension and never resumes.
    unsafe { suspend(frame, Event::Bail(code)) }
}

/// The address of `bytes` of new memory in a new chunk of the heap, made current. A run
/// past its limit bails.
pub extern "C" fn buoy_alloc(frame: *mut Frame, bytes: u64) -> u64 {
    // SAFETY: the machine code passes the frame of its run.
    unsafe {
        let wanted = usize::try_from(bytes).unwrap_or(usize::MAX);
        let Some((start, end)) = (*frame).heap.next_chunk(wanted) else {
            buoy_bail(frame, Bail::Memory as i32);
            return 0;
        };
        (*frame).heap_next = start + bytes;
        (*frame).heap_end = end;
        start
    }
}

/// `a % b` on numbers: the remainder of IEEE 754 `fmod`, as ECMA-262 §6.1.6.1.6 defines.
pub extern "C" fn buoy_fmod(a: f64, b: f64) -> f64 {
    a % b
}

/// `a ** b` (ECMA-262 §6.1.6.1.3).
pub extern "C" fn buoy_pow(a: f64, b: f64) -> f64 {
    buoy_jit_ir::exponentiate(a, b)
}

/// `ToInt32` of a number outside the range of a 64-bit integer, or not finite.
pub extern "C" fn buoy_int32(value: f64) -> i32 {
    buoy_jit_ir::to_int32(value)
}

/// The `Math` functions that have no machine instruction, by their [`MathFn`] code.
///
/// [`MathFn`]: buoy_jit_ir::MathFn
pub extern "C" fn buoy_math(code: i32, a: f64, b: f64) -> f64 {
    use buoy_jit_ir::MathFn;
    const ROUND: i32 = MathFn::Round as i32;
    const SIGN: i32 = MathFn::Sign as i32;
    const SIN: i32 = MathFn::Sin as i32;
    const COS: i32 = MathFn::Cos as i32;
    const TAN: i32 = MathFn::Tan as i32;
    const ATAN: i32 = MathFn::Atan as i32;
    const ATAN2: i32 = MathFn::Atan2 as i32;
    const EXP: i32 = MathFn::Exp as i32;
    const LOG: i32 = MathFn::Log as i32;
    match code {
        ROUND => buoy_jit_ir::round(a),
        SIGN if a.is_nan() || a == 0.0 => a,
        SIGN => a.signum(),
        SIN => a.sin(),
        COS => a.cos(),
        TAN => a.tan(),
        ATAN => a.atan(),
        ATAN2 => a.atan2(b),
        EXP => a.exp(),
        LOG => a.ln(),
        _ => buoy_jit_ir::exponentiate(a, b),
    }
}

/// Removes the first element of an array of references and returns it, or `undefined`
/// when the array is empty.
pub extern "C" fn buoy_shift(array: u64) -> u64 {
    // SAFETY: `array` is a live array of the run's heap, with the layout of
    // `codegen::array`, whose elements are words.
    unsafe {
        let header = array as *mut u64;
        let length = usize::try_from(*header.add(1)).unwrap_or(0);
        if length == 0 {
            return 1;
        }
        let data = *header.add(3) as *mut u64;
        let first = data.read();
        std::ptr::copy(data.add(1), data, length - 1);
        *header.add(1) = (length - 1) as u64;
        first
    }
}

/// Moves the elements of an array to a block of twice the capacity.
pub extern "C" fn buoy_grow(frame: *mut Frame, array: u64) {
    // SAFETY: `array` is a live array of the run's heap, with the layout of
    // `codegen::array`: its length, its capacity, and its elements.
    unsafe {
        let header = array as *mut u64;
        let length = *header.add(1);
        let capacity = *header.add(2);
        let data = *header.add(3) as *const u64;
        let Some(bigger) = capacity.max(2).checked_mul(2).filter(|c| *c <= 1 << 31) else {
            buoy_bail(frame, Bail::Memory as i32);
            return;
        };
        let target = allocate(frame, bigger * 8) as *mut u64;
        let count = usize::try_from(length).unwrap_or(0);
        std::ptr::copy_nonoverlapping(data, target, count);
        *header.add(2) = bigger;
        *header.add(3) = target as u64;
    }
}

/// Allocates from the current chunk, or from a new one.
///
/// # Safety
///
/// `frame` must be the frame of a running run.
pub unsafe fn allocate(frame: *mut Frame, bytes: u64) -> u64 {
    // SAFETY: as the caller promises.
    unsafe {
        let next = (*frame).heap_next;
        match next.checked_add(bytes) {
            Some(end) if end <= (*frame).heap_end => {
                (*frame).heap_next = end;
                next
            }
            _ => buoy_alloc(frame, bytes),
        }
    }
}
