//! Compiles the typed IR to machine code with Cranelift.
//!
//! The IR comes from a module of the program, so the compiler checks it as a verifier
//! would before it emits code: every class id, field index, function id, and local
//! exists, and every operand has the type that its use needs. A program that fails a
//! check does not compile, and its calls stay in the Erlang tier. The machine code checks
//! the rest at run time: a reference is not `null` or `undefined` before a field access,
//! an index is inside its array, and an object has a class that a dispatch knows. So the
//! code reads and writes only objects of its own heap, inside their bounds.
//!
//! Layouts, in 8-byte words:
//!
//! - An object: its class id, then one word for each field. A boolean field uses the low
//!   byte of its word.
//! - An array: [`ARRAY_TAG`], the length, the capacity, and the address of the elements,
//!   one word each.
//! - A string: [`STRING_TAG`], the length in UTF-16 code units, and the code units, two
//!   bytes each, padded to a whole word.
//! - `null` is the address 0 and `undefined` the address 1.

#![allow(unsafe_code)]

use std::collections::{HashMap, HashSet};

use buoy_jit_ir::{
    Bail, Binary, ClassId, Expr, FuncId, Function, MathFn, Program, Stmt, Ty, Unary,
};
use cranelift_codegen::ir::condcodes::{FloatCC, IntCC};
use cranelift_codegen::ir::{
    AbiParam, Block, BlockArg, FuncRef, InstBuilder, MemFlagsData, Signature, StackSlotData,
    StackSlotKind, TrapCode, Value, types,
};
use cranelift_codegen::isa::CallConv;
use cranelift_frontend::{FunctionBuilder, FunctionBuilderContext, Switch, Variable};
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::{FuncId as ModuleFuncId, Linkage, Module, default_libcall_names};

use crate::{run, text};

/// The offsets of the fields of [`run::Frame`] that the machine code uses.
pub mod frame {
    pub const FUEL: i32 = 0;
    pub const HEAP_NEXT: i32 = 8;
    pub const HEAP_END: i32 = 16;
    pub const STACK_LIMIT: i32 = 24;
    pub const RESULT: i32 = 32;
    pub const GLOBALS: i32 = 40;
}

/// The offsets of the words of an array.
pub mod array {
    pub const LENGTH: i32 = 8;
    pub const CAPACITY: i32 = 16;
    pub const DATA: i32 = 24;
    pub const SIZE: i64 = 32;
}

/// The offsets of the words of a string.
pub mod string {
    pub const LENGTH: i32 = 8;
    pub const UNITS: usize = 16;
}

/// The class word of an array, which no class id takes.
pub const ARRAY_TAG: i64 = 0xffff_ffff;

/// The class word of a string, which no class id takes.
pub const STRING_TAG: i64 = 0xffff_fffe;

/// The most elements of an array.
const MAX_ELEMENTS: i64 = 1 << 31;

/// The undefined reference.
const UNDEFINED: i64 = 1;

/// The machine code of a program, and its entries.
pub struct Code {
    module: Option<JITModule>,
    entries: Vec<EntryFn>,
    layout: Layout,
    /// The strings of the literals, which the machine code points to.
    _literals: Vec<Box<[u64]>>,
}

/// What a run needs to know of the program to copy values into its heap and out of it.
#[derive(Debug, Clone, Default)]
pub struct Layout {
    /// The types of the fields of each class.
    pub fields: Vec<Vec<Ty>>,
    /// The parent of each class.
    pub parents: Vec<Option<ClassId>>,
    /// The globals that the code writes, in order.
    pub written: Vec<u32>,
}

impl Layout {
    /// Whether `class` is `ancestor` or one of its subclasses.
    #[must_use]
    pub fn is_subclass(&self, class: ClassId, ancestor: ClassId) -> bool {
        let mut current = Some(class);
        while let Some(id) = current {
            if id == ancestor {
                return true;
            }
            current = self.parents.get(id as usize).copied().flatten();
        }
        false
    }
}

// SAFETY: after `finalize_definitions` the module is only read, and freed on drop; its
// memory is executable code that any thread may run.
unsafe impl Send for Code {}
// SAFETY: as above.
unsafe impl Sync for Code {}

impl std::fmt::Debug for Code {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Code")
            .field("entries", &self.entries.len())
            .finish_non_exhaustive()
    }
}

impl Drop for Code {
    fn drop(&mut self) {
        if let Some(module) = self.module.take() {
            // SAFETY: a run keeps its `Code` alive, so no run executes this code now.
            unsafe { module.free_memory() };
        }
    }
}

/// An entry: the address of its trampoline, `fn(*mut Frame, *const u64)`, which reads the
/// arguments and the globals from the words and leaves the result in the frame.
#[derive(Debug)]
pub struct EntryFn {
    pub address: *const u8,
    pub params: Vec<Ty>,
    pub globals: Vec<Ty>,
    pub result: Ty,
}

impl Code {
    pub fn entry(&self, index: usize) -> Option<&EntryFn> {
        self.entries.get(index)
    }

    pub fn layout(&self) -> &Layout {
        &self.layout
    }
}

/// Why a program does not compile.
pub type Error = String;

fn fail<T>(message: impl Into<String>) -> Result<T, Error> {
    Err(message.into())
}

/// The helpers that the machine code calls, with their signatures.
struct Helper {
    name: &'static str,
    address: *const u8,
    params: &'static [types::Type],
    returns: &'static [types::Type],
}

fn helpers() -> [Helper; 12] {
    use types::{F64, I8, I32, I64};
    [
        Helper {
            name: "buoy_tick",
            address: run::buoy_tick as *const u8,
            params: &[I64],
            returns: &[I64],
        },
        Helper {
            name: "buoy_bail",
            address: run::buoy_bail as *const u8,
            params: &[I64, I32],
            returns: &[],
        },
        Helper {
            name: "buoy_alloc",
            address: run::buoy_alloc as *const u8,
            params: &[I64, I64],
            returns: &[I64],
        },
        Helper {
            name: "buoy_grow",
            address: run::buoy_grow as *const u8,
            params: &[I64, I64],
            returns: &[],
        },
        Helper {
            name: "buoy_fmod",
            address: run::buoy_fmod as *const u8,
            params: &[F64, F64],
            returns: &[F64],
        },
        Helper {
            name: "buoy_pow",
            address: run::buoy_pow as *const u8,
            params: &[F64, F64],
            returns: &[F64],
        },
        Helper {
            name: "buoy_int32",
            address: run::buoy_int32 as *const u8,
            params: &[F64],
            returns: &[I32],
        },
        Helper {
            name: "buoy_math",
            address: run::buoy_math as *const u8,
            params: &[I32, F64, F64],
            returns: &[F64],
        },
        Helper {
            name: "buoy_text",
            address: text::buoy_text as *const u8,
            params: &[I64, I64, I64],
            returns: &[I64],
        },
        Helper {
            name: "buoy_str_eq",
            address: text::buoy_str_eq as *const u8,
            params: &[I64, I64],
            returns: &[I8],
        },
        Helper {
            name: "buoy_str_truthy",
            address: text::buoy_str_truthy as *const u8,
            params: &[I64],
            returns: &[I8],
        },
        Helper {
            name: "buoy_shift",
            address: run::buoy_shift as *const u8,
            params: &[I64],
            returns: &[I64],
        },
    ]
}

const TICK: usize = 0;
const BAIL: usize = 1;
const ALLOC: usize = 2;
const GROW: usize = 3;
const FMOD: usize = 4;
const POW: usize = 5;
const INT32: usize = 6;
const MATH: usize = 7;
const TEXT: usize = 8;
const STR_EQ: usize = 9;
const STR_TRUTHY: usize = 10;
const SHIFT: usize = 11;

/// Compiles every function of `program` and the trampolines of its entries.
pub fn compile(program: &Program) -> Result<Code, Error> {
    check_program(program)?;
    // The fuel lives in the pinned register (x21 on aarch64, r15 on x86_64), so spending it
    // is a subtraction, not a load and a store through memory at every call and loop turn.
    let mut builder = JITBuilder::with_flags(
        &[("opt_level", "speed"), ("enable_pinned_reg", "true")],
        default_libcall_names(),
    )
    .map_err(|error| error.to_string())?;
    let helpers = helpers();
    for helper in &helpers {
        builder.symbol(helper.name, helper.address);
    }
    let mut module = JITModule::new(builder);
    let mut literals = Vec::new();
    let written = written_globals(program);
    let compiled = define_all(&mut module, program, &helpers, &written, &mut literals);
    let layout = Layout {
        fields: program.classes.iter().map(|c| c.fields.clone()).collect(),
        parents: program.classes.iter().map(|c| c.parent).collect(),
        written: written.iter().copied().collect(),
    };
    match compiled {
        Ok(entries) => Ok(Code {
            module: Some(module),
            entries,
            layout,
            _literals: literals,
        }),
        Err(error) => {
            // SAFETY: no code of the module has run.
            unsafe { module.free_memory() };
            Err(error)
        }
    }
}

/// The globals that some code writes, in order.
fn written_globals(program: &Program) -> std::collections::BTreeSet<u32> {
    let mut written = std::collections::BTreeSet::new();
    for function in &program.functions {
        written_in_stmts(&function.body, &mut written);
    }
    written
}

fn define_all(
    module: &mut JITModule,
    program: &Program,
    helpers: &[Helper],
    written: &std::collections::BTreeSet<u32>,
    literals: &mut Vec<Box<[u64]>>,
) -> Result<Vec<EntryFn>, Error> {
    let call_conv = module.isa().default_call_conv();
    let helper_ids = declare_helpers(module, helpers)?;
    let mut ids = Vec::with_capacity(program.functions.len());
    for (index, function) in program.functions.iter().enumerate() {
        let id = module
            .declare_function(
                &format!("f{index}"),
                Linkage::Local,
                &signature_of(function, call_conv),
            )
            .map_err(|error| error.to_string())?;
        ids.push(id);
    }
    let mut context = module.make_context();
    let mut builder_context = FunctionBuilderContext::new();
    let target = module.target_config();
    // `BUOY_JIT_DUMP=1` prints the machine code of each function to stderr.
    let dump = std::env::var_os("BUOY_JIT_DUMP").is_some();
    for (index, function) in program.functions.iter().enumerate() {
        context.func.signature = signature_of(function, call_conv);
        let builder = FunctionBuilder::new(&mut context.func, &mut builder_context);
        let mut generator = Gen::new(
            program,
            function,
            builder,
            module,
            (&ids, &helper_ids),
            written,
        );
        generator.body()?;
        literals.append(&mut generator.literals);
        generator.b.finalize(target);
        context.set_disasm(dump);
        module
            .define_function(ids[index], &mut context)
            .map_err(|error| format!("function {}: {error:?}", function.name))?;
        if let Some(code) = context.compiled_code().and_then(|code| code.vcode.as_ref()) {
            eprintln!("buoy jit: f{index} {}\n{code}", function.name);
        }
        module.clear_context(&mut context);
    }
    let mut entries = Vec::with_capacity(program.entries.len());
    let mut trampolines = Vec::with_capacity(program.entries.len());
    for (index, &function_id) in program.entries.iter().enumerate() {
        let function = function_at(program, function_id)?;
        let pointer = types::I64;
        let mut signature = Signature::new(call_conv);
        signature.params.push(AbiParam::new(pointer));
        signature.params.push(AbiParam::new(pointer));
        let id = module
            .declare_function(&format!("e{index}"), Linkage::Local, &signature)
            .map_err(|error| error.to_string())?;
        context.func.signature = signature;
        let mut builder = FunctionBuilder::new(&mut context.func, &mut builder_context);
        trampoline(
            &mut builder,
            module,
            ids[function_id as usize],
            function,
            program.globals.len(),
        )?;
        builder.finalize(module.target_config());
        module
            .define_function(id, &mut context)
            .map_err(|error| format!("entry {index}: {error:?}"))?;
        module.clear_context(&mut context);
        trampolines.push(id);
        entries.push(EntryFn {
            address: std::ptr::null(),
            params: function.locals[..function.params as usize].to_vec(),
            globals: program.globals.clone(),
            result: function.result.clone(),
        });
    }
    module
        .finalize_definitions()
        .map_err(|error| error.to_string())?;
    for (entry, id) in entries.iter_mut().zip(trampolines) {
        entry.address = module.get_finalized_function(id);
    }
    if dump {
        for (index, id) in ids.iter().enumerate() {
            eprintln!(
                "buoy jit: f{index} at {:?}",
                module.get_finalized_function(*id)
            );
        }
    }
    Ok(entries)
}

/// The ids of the helpers in the module, with the tick that refills the fuel in place of
/// the helper it calls.
fn declare_helpers(module: &mut JITModule, helpers: &[Helper]) -> Result<Vec<ModuleFuncId>, Error> {
    let call_conv = module.isa().default_call_conv();
    let mut helper_ids = Vec::with_capacity(helpers.len());
    for helper in helpers {
        let mut signature = Signature::new(call_conv);
        signature
            .params
            .extend(helper.params.iter().map(|ty| AbiParam::new(*ty)));
        signature
            .returns
            .extend(helper.returns.iter().map(|ty| AbiParam::new(*ty)));
        let id = module
            .declare_function(helper.name, Linkage::Import, &signature)
            .map_err(|error| error.to_string())?;
        helper_ids.push(id);
    }
    helper_ids[TICK] = define_tick(module, helper_ids[TICK])?;
    Ok(helper_ids)
}

/// The function that the code calls when its fuel is gone: it calls [`run::buoy_tick`]
/// and puts the new fuel in the pinned register. It saves every register it uses, so a
/// loop whose turns spend fuel keeps its values in registers across the call, which the
/// code makes only once in thousands of turns.
fn define_tick(module: &mut JITModule, tick: ModuleFuncId) -> Result<ModuleFuncId, Error> {
    let mut signature = Signature::new(CallConv::PreserveAll);
    signature.params.push(AbiParam::new(types::I64));
    let id = module
        .declare_function("tick", Linkage::Local, &signature)
        .map_err(|error| error.to_string())?;
    let mut context = module.make_context();
    context.func.signature = signature;
    let mut builder_context = FunctionBuilderContext::new();
    let mut b = FunctionBuilder::new(&mut context.func, &mut builder_context);
    let block = b.create_block();
    b.append_block_params_for_function_params(block);
    b.switch_to_block(block);
    let frame = b.block_params(block)[0];
    let callee = module.declare_func_in_func(tick, b.func);
    let call = b.ins().call(callee, &[frame]);
    let fuel = b.inst_results(call)[0];
    b.ins().set_pinned_reg(fuel);
    b.ins().return_(&[]);
    b.seal_all_blocks();
    b.finalize(module.target_config());
    module
        .define_function(id, &mut context)
        .map_err(|error| format!("tick: {error:?}"))?;
    Ok(id)
}

/// `fn(frame, words)`: stores the address of the globals in the frame, reads the
/// arguments, calls the entry, and stores its result.
fn trampoline(
    b: &mut FunctionBuilder<'_>,
    module: &mut JITModule,
    target: ModuleFuncId,
    function: &Function,
    globals: usize,
) -> Result<(), Error> {
    let block = b.create_block();
    b.append_block_params_for_function_params(block);
    b.switch_to_block(block);
    let frame = b.block_params(block)[0];
    let words = b.block_params(block)[1];
    let flags = MemFlagsData::trusted();
    let params = function.params as usize;
    let globals_at = b.ins().iadd_imm_s(words, offset(params)?);
    b.ins().store(flags, globals_at, frame, frame::GLOBALS);
    // The caller, Rust code, keeps a value of its own in the pinned register.
    let saved = b.ins().get_pinned_reg(types::I64);
    let fuel = b.ins().load(types::I64, flags, frame, frame::FUEL);
    b.ins().set_pinned_reg(fuel);
    let _ = globals;
    let mut args = vec![frame];
    for (index, ty) in function.locals[..params].iter().enumerate() {
        let at = i32::try_from(offset(index)?).map_err(|e| e.to_string())?;
        let value = match ty {
            Ty::Num => b.ins().load(types::F64, flags, words, at),
            Ty::Bool => b.ins().load(types::I8, flags, words, at),
            _ => return fail("an entry takes numbers and booleans"),
        };
        args.push(value);
    }
    let callee = module.declare_func_in_func(target, b.func);
    let call = b.ins().call(callee, &args);
    let results = b.inst_results(call).to_vec();
    b.ins().set_pinned_reg(saved);
    match (&function.result, results.first()) {
        (Ty::Num | Ty::Bool, Some(value)) => {
            b.ins().store(flags, *value, frame, frame::RESULT);
        }
        (Ty::Void, None) => {}
        _ => return fail("an entry returns a number, a boolean, or nothing"),
    }
    b.ins().return_(&[]);
    b.seal_all_blocks();
    Ok(())
}

fn offset(words: usize) -> Result<i64, Error> {
    i64::try_from(words * 8).map_err(|error| error.to_string())
}

fn function_at(program: &Program, id: FuncId) -> Result<&Function, Error> {
    program
        .functions
        .get(id as usize)
        .ok_or_else(|| format!("no function {id}"))
}

fn repr(ty: &Ty) -> Option<types::Type> {
    match ty {
        Ty::Void => None,
        Ty::Num => Some(types::F64),
        Ty::Bool => Some(types::I8),
        Ty::Null | Ty::Object(_) | Ty::Any | Ty::Array(_) | Ty::Str => Some(types::I64),
    }
}

fn signature_of(function: &Function, call_conv: CallConv) -> Signature {
    let mut signature = Signature::new(call_conv);
    signature.params.push(AbiParam::new(types::I64));
    for ty in function.locals.iter().take(function.params as usize) {
        if let Some(repr) = repr(ty) {
            signature.params.push(AbiParam::new(repr));
        }
    }
    if let Some(repr) = repr(&function.result) {
        signature.returns.push(AbiParam::new(repr));
    }
    signature
}

/// Checks the classes, the types, and the signatures of the program.
fn check_program(program: &Program) -> Result<(), Error> {
    let classes = program.classes.len();
    for (index, class) in program.classes.iter().enumerate() {
        if let Some(parent) = class.parent {
            let parent_class = program
                .classes
                .get(parent as usize)
                .ok_or("a parent class is missing")?;
            if !class.fields.starts_with(&parent_class.fields) {
                return fail(format!(
                    "{} does not extend the fields of its parent",
                    class.name
                ));
            }
        }
        // The parent chain ends, so the subclass test terminates.
        let mut steps = 0;
        let mut current = Some(u32::try_from(index).map_err(|e| e.to_string())?);
        while let Some(id) = current {
            steps += 1;
            if steps > classes {
                return fail("the parent chain of a class is a cycle");
            }
            current = program.classes[id as usize].parent;
        }
        for ty in &class.fields {
            check_value_type(program, ty)?;
        }
        for method in &class.methods {
            function_at(program, method.function)?;
        }
    }
    for function in &program.functions {
        if function.params as usize > function.locals.len() {
            return fail("a function has more parameters than locals");
        }
        for ty in &function.locals {
            check_value_type(program, ty)?;
        }
        if function.result != Ty::Void {
            check_value_type(program, &function.result)?;
        }
    }
    for ty in &program.globals {
        check_value_type(program, ty)?;
    }
    for &entry in &program.entries {
        let function = function_at(program, entry)?;
        let params_ok = function.locals[..function.params as usize]
            .iter()
            .all(|ty| matches!(ty, Ty::Num | Ty::Bool));
        if !params_ok || !matches!(function.result, Ty::Num | Ty::Bool | Ty::Void) {
            return fail("an entry takes and returns numbers and booleans");
        }
    }
    Ok(())
}

fn check_value_type(program: &Program, ty: &Ty) -> Result<(), Error> {
    match ty {
        Ty::Void => fail("a value has the type void"),
        Ty::Object(class) if *class as usize >= program.classes.len() => {
            fail(format!("no class {class}"))
        }
        Ty::Array(element) => check_value_type(program, element),
        _ => Ok(()),
    }
}

/// Whether `class` is `ancestor` or one of its subclasses.
fn is_subclass(program: &Program, class: ClassId, ancestor: ClassId) -> bool {
    let mut current = Some(class);
    while let Some(id) = current {
        if id == ancestor {
            return true;
        }
        current = program.classes.get(id as usize).and_then(|c| c.parent);
    }
    false
}

/// Whether a value of type `from` may go where the type `to` is.
fn fits(program: &Program, from: &Ty, to: &Ty) -> bool {
    match (from, to) {
        (Ty::Null, Ty::Null | Ty::Object(_) | Ty::Any | Ty::Array(_) | Ty::Str)
        | (Ty::Object(_), Ty::Any) => true,
        (Ty::Object(a), Ty::Object(b)) => is_subclass(program, *a, *b),
        _ => from == to,
    }
}

/// The code generator of one function.
struct Gen<'a, 'm> {
    program: &'a Program,
    function: &'a Function,
    b: FunctionBuilder<'m>,
    module: &'m mut JITModule,
    ids: &'a [ModuleFuncId],
    helper_ids: &'a [ModuleFuncId],
    refs: HashMap<FuncId, FuncRef>,
    helper_refs: HashMap<usize, FuncRef>,
    vars: Vec<Variable>,
    frame: Value,
    /// The continue and break targets of the enclosing loops, innermost last.
    loops: Vec<(Block, Block)>,
    bails: HashMap<u8, Block>,
    /// Where a `return` of the function whose body is being emitted goes: the block
    /// after an inlined call, or `None` for a real return.
    exit: Option<Block>,
    /// The functions whose bodies are inlined around the current point.
    inlined: Vec<FuncId>,
    /// References that are neither `null` nor `undefined`: a new object, a receiver, or the
    /// value that a check produced, which only code after the check can use.
    nonnull: HashSet<Value>,
    /// The `ToInt32` of numbers that came from 32-bit integers.
    int32s: HashMap<Value, Value>,
    /// The numbers of constants.
    constants: HashMap<Value, f64>,
    /// The globals that some code writes.
    written: &'a std::collections::BTreeSet<u32>,
    /// The strings of the literals of the function.
    literals: Vec<Box<[u64]>>,
}

/// The most IR nodes of a function that a call inlines.
const INLINE_SIZE: usize = 48;

/// The most inlined calls around one point.
const INLINE_DEPTH: usize = 3;

/// The IR nodes of statements.
fn size_of_stmts(stmts: &[Stmt]) -> usize {
    stmts.iter().map(size_of_stmt).sum()
}

fn size_of_stmt(stmt: &Stmt) -> usize {
    1 + match stmt {
        Stmt::Expr(expr) => size_of_expr(expr),
        Stmt::If(test, then, otherwise) => {
            size_of_expr(test) + size_of_stmts(then) + size_of_stmts(otherwise)
        }
        Stmt::Loop {
            cond, body, update, ..
        } => cond.as_ref().map_or(0, size_of_expr) + size_of_stmts(body) + size_of_stmts(update),
        Stmt::Return(value) => value.as_ref().map_or(0, size_of_expr),
        Stmt::Break(_) | Stmt::Continue(_) | Stmt::Bail(_) => 0,
    }
}

fn size_of_expr(expr: &Expr) -> usize {
    let all = |items: &[Expr]| items.iter().map(size_of_expr).sum::<usize>();
    1 + match expr {
        Expr::Num(_)
        | Expr::Bool(_)
        | Expr::Null
        | Expr::Undefined
        | Expr::Str(_)
        | Expr::Local(_)
        | Expr::Global(_)
        | Expr::Fail(..) => 0,
        Expr::SetLocal(_, value)
        | Expr::SetGlobal(_, value)
        | Expr::Unary(_, value)
        | Expr::Field(value, _, _)
        | Expr::Length(value)
        | Expr::Shift(value) => size_of_expr(value),
        Expr::Binary(_, a, b)
        | Expr::And(a, b)
        | Expr::Or(a, b)
        | Expr::SetField(a, _, _, b)
        | Expr::Index(a, b)
        | Expr::Push(a, b)
        | Expr::ArrayFill(_, a, b) => size_of_expr(a) + size_of_expr(b),
        Expr::Cond(_, a, b, c) | Expr::SetIndex(a, b, c) => {
            size_of_expr(a) + size_of_expr(b) + size_of_expr(c)
        }
        // A call or a dispatch costs about as much as a small body that it would inline.
        Expr::Call(_, args) | Expr::New(_, _, args) => 4 + all(args),
        Expr::Dispatch { args, .. } => 6 + all(args),
        Expr::ArrayOf(_, items) | Expr::Math(_, items) | Expr::Seq(items) | Expr::Text(items) => {
            all(items)
        }
        Expr::Block(stmts, value) => size_of_stmts(stmts) + size_of_expr(value),
    }
}

type Typed = (Option<Value>, Ty);

/// The locals that statements assign.
fn assigned_in_stmts(stmts: &[Stmt], out: &mut HashSet<u32>) {
    for stmt in stmts {
        match stmt {
            Stmt::Expr(expr) | Stmt::Return(Some(expr)) => assigned_in_expr(expr, out),
            Stmt::If(test, then, otherwise) => {
                assigned_in_expr(test, out);
                assigned_in_stmts(then, out);
                assigned_in_stmts(otherwise, out);
            }
            Stmt::Loop {
                cond, body, update, ..
            } => {
                if let Some(expr) = cond {
                    assigned_in_expr(expr, out);
                }
                assigned_in_stmts(body, out);
                assigned_in_stmts(update, out);
            }
            Stmt::Return(None) | Stmt::Break(_) | Stmt::Continue(_) | Stmt::Bail(_) => {}
        }
    }
}

fn assigned_in_expr(expr: &Expr, out: &mut HashSet<u32>) {
    let mut all = |items: &[Expr]| items.iter().for_each(|item| assigned_in_expr(item, out));
    match expr {
        Expr::SetLocal(local, value) => {
            out.insert(*local);
            assigned_in_expr(value, out);
        }
        Expr::Num(_)
        | Expr::Bool(_)
        | Expr::Null
        | Expr::Undefined
        | Expr::Str(_)
        | Expr::Local(_)
        | Expr::Global(_)
        | Expr::Fail(..) => {}
        Expr::Unary(_, value)
        | Expr::Field(value, _, _)
        | Expr::Length(value)
        | Expr::Shift(value)
        | Expr::SetGlobal(_, value) => {
            assigned_in_expr(value, out);
        }
        Expr::Binary(_, a, b)
        | Expr::And(a, b)
        | Expr::Or(a, b)
        | Expr::SetField(a, _, _, b)
        | Expr::Index(a, b)
        | Expr::Push(a, b)
        | Expr::ArrayFill(_, a, b) => {
            assigned_in_expr(a, out);
            assigned_in_expr(b, out);
        }
        Expr::Cond(_, a, b, c) | Expr::SetIndex(a, b, c) => {
            assigned_in_expr(a, out);
            assigned_in_expr(b, out);
            assigned_in_expr(c, out);
        }
        Expr::Call(_, args) | Expr::New(_, _, args) | Expr::Dispatch { args, .. } => all(args),
        Expr::ArrayOf(_, items) | Expr::Math(_, items) | Expr::Seq(items) | Expr::Text(items) => {
            all(items);
        }
        Expr::Block(stmts, value) => {
            assigned_in_stmts(stmts, out);
            assigned_in_expr(value, out);
        }
    }
}

/// The globals that statements write.
fn written_in_stmts(stmts: &[Stmt], out: &mut std::collections::BTreeSet<u32>) {
    for stmt in stmts {
        match stmt {
            Stmt::Expr(expr) | Stmt::Return(Some(expr)) => written_in_expr(expr, out),
            Stmt::If(test, then, otherwise) => {
                written_in_expr(test, out);
                written_in_stmts(then, out);
                written_in_stmts(otherwise, out);
            }
            Stmt::Loop {
                cond, body, update, ..
            } => {
                if let Some(expr) = cond {
                    written_in_expr(expr, out);
                }
                written_in_stmts(body, out);
                written_in_stmts(update, out);
            }
            Stmt::Return(None) | Stmt::Break(_) | Stmt::Continue(_) | Stmt::Bail(_) => {}
        }
    }
}

fn written_in_expr(expr: &Expr, out: &mut std::collections::BTreeSet<u32>) {
    if let Expr::SetGlobal(index, _) = expr {
        out.insert(*index);
    }
    if let Expr::Block(stmts, _) = expr {
        written_in_stmts(stmts, out);
    }
    for child in children(expr) {
        written_in_expr(child, out);
    }
}

/// The operands of an expression.
fn children(expr: &Expr) -> Vec<&Expr> {
    match expr {
        Expr::Num(_)
        | Expr::Bool(_)
        | Expr::Null
        | Expr::Undefined
        | Expr::Str(_)
        | Expr::Local(_)
        | Expr::Global(_)
        | Expr::Fail(..) => vec![],
        Expr::SetLocal(_, value)
        | Expr::SetGlobal(_, value)
        | Expr::Unary(_, value)
        | Expr::Field(value, _, _)
        | Expr::Length(value)
        | Expr::Shift(value)
        // The statements of a block are not operands; `written_in_expr` visits them.
        | Expr::Block(_, value) => vec![value],
        Expr::Binary(_, a, b)
        | Expr::And(a, b)
        | Expr::Or(a, b)
        | Expr::SetField(a, _, _, b)
        | Expr::Index(a, b)
        | Expr::Push(a, b)
        | Expr::ArrayFill(_, a, b) => vec![a, b],
        Expr::Cond(_, a, b, c) | Expr::SetIndex(a, b, c) => vec![a, b, c],
        Expr::Call(_, items)
        | Expr::New(_, _, items)
        | Expr::Dispatch { args: items, .. }
        | Expr::ArrayOf(_, items)
        | Expr::Math(_, items)
        | Expr::Seq(items)
        | Expr::Text(items) => items.iter().collect(),
    }
}

impl<'a, 'm> Gen<'a, 'm> {
    fn new(
        program: &'a Program,
        function: &'a Function,
        b: FunctionBuilder<'m>,
        module: &'m mut JITModule,
        (ids, helper_ids): (&'a [ModuleFuncId], &'a [ModuleFuncId]),
        written: &'a std::collections::BTreeSet<u32>,
    ) -> Self {
        Self {
            program,
            function,
            b,
            module,
            ids,
            helper_ids,
            refs: HashMap::new(),
            helper_refs: HashMap::new(),
            vars: Vec::new(),
            frame: Value::from_u32(0),
            loops: Vec::new(),
            bails: HashMap::new(),
            exit: None,
            inlined: Vec::new(),
            nonnull: HashSet::new(),
            int32s: HashMap::new(),
            constants: HashMap::new(),
            written,
            literals: Vec::new(),
        }
    }

    fn body(&mut self) -> Result<(), Error> {
        let entry = self.b.create_block();
        self.b.append_block_params_for_function_params(entry);
        self.b.switch_to_block(entry);
        self.b.seal_block(entry);
        let params: Vec<Value> = self.b.block_params(entry).to_vec();
        self.frame = params[0];
        if self.function.receiver
            && let Some(receiver) = params.get(1)
        {
            self.nonnull.insert(*receiver);
        }
        let mut param_values = params[1..].iter();
        for (index, ty) in self.function.locals.iter().enumerate() {
            let repr = repr(ty).ok_or("a local has no value")?;
            let var = self.b.declare_var(repr);
            let value = if index < self.function.params as usize {
                *param_values.next().ok_or("a parameter is missing")?
            } else {
                self.zero(ty)
            };
            self.b.def_var(var, value);
            self.vars.push(var);
        }
        self.stack_check();
        self.fuel();
        let body = &self.function.body;
        self.stmts(body)?;
        if !self.is_filled() {
            if self.function.result == Ty::Void {
                self.b.ins().return_(&[]);
            } else {
                self.bail(Bail::Undefined);
            }
        }
        let bails: Vec<(u8, Block)> = self.bails.iter().map(|(k, v)| (*k, *v)).collect();
        for (reason, block) in bails {
            self.b.switch_to_block(block);
            self.b.set_cold_block(block);
            let code = self.b.ins().iconst(types::I32, i64::from(reason));
            let frame = self.frame;
            self.call_helper(BAIL, &[frame, code]);
            self.b.ins().trap(TrapCode::unwrap_user(1));
        }
        self.b.seal_all_blocks();
        Ok(())
    }

    fn zero(&mut self, ty: &Ty) -> Value {
        match ty {
            Ty::Num => self.b.ins().f64const(0.0),
            Ty::Bool => self.b.ins().iconst(types::I8, 0),
            _ => self.b.ins().iconst(types::I64, UNDEFINED),
        }
    }

    /// Whether the current block ends in a terminator.
    fn is_filled(&self) -> bool {
        let Some(block) = self.b.current_block() else {
            return true;
        };
        self.b
            .func
            .layout
            .last_inst(block)
            .is_some_and(|inst| self.b.func.dfg.insts[inst].opcode().is_terminator())
    }

    /// Continues in a new block that no branch reaches, after a terminator.
    fn unreachable(&mut self) {
        let block = self.b.create_block();
        self.b.switch_to_block(block);
        self.b.seal_block(block);
    }

    fn helper(&mut self, index: usize) -> FuncRef {
        if let Some(found) = self.helper_refs.get(&index) {
            return *found;
        }
        let made = self
            .module
            .declare_func_in_func(self.helper_ids[index], self.b.func);
        self.helper_refs.insert(index, made);
        made
    }

    fn call_helper(&mut self, index: usize, args: &[Value]) -> Option<Value> {
        let callee = self.helper(index);
        let call = self.b.ins().call(callee, args);
        self.b.inst_results(call).first().copied()
    }

    fn function_ref(&mut self, id: FuncId) -> Result<FuncRef, Error> {
        if let Some(found) = self.refs.get(&id) {
            return Ok(*found);
        }
        let module_id = *self.ids.get(id as usize).ok_or("no such function")?;
        let made = self.module.declare_func_in_func(module_id, self.b.func);
        self.refs.insert(id, made);
        Ok(made)
    }

    /// The shared block that bails with `reason`.
    fn bail_block(&mut self, reason: Bail) -> Block {
        let code = reason as u8;
        if let Some(found) = self.bails.get(&code) {
            return *found;
        }
        let block = self.b.create_block();
        self.bails.insert(code, block);
        block
    }

    fn bail(&mut self, reason: Bail) {
        let block = self.bail_block(reason);
        self.b.ins().jump(block, &[]);
    }

    /// Bails with `reason` when `condition` holds.
    fn bail_if(&mut self, condition: Value, reason: Bail) {
        let target = self.bail_block(reason);
        let next = self.b.create_block();
        self.b.ins().brif(condition, target, &[], next, &[]);
        self.b.switch_to_block(next);
        self.b.seal_block(next);
    }

    fn stack_check(&mut self) {
        let sp = self.b.ins().get_stack_pointer(types::I64);
        let limit = self.b.ins().load(
            types::I64,
            MemFlagsData::trusted(),
            self.frame,
            frame::STACK_LIMIT,
        );
        let low = self.b.ins().icmp(IntCC::UnsignedLessThan, sp, limit);
        self.bail_if(low, Bail::Stack);
    }

    /// Spends one unit of the fuel in the pinned register, and calls the tick, which
    /// refills it, when it is gone.
    fn fuel(&mut self) {
        let fuel = self.b.ins().get_pinned_reg(types::I64);
        let left = self.b.ins().iadd_imm_s(fuel, -1);
        self.b.ins().set_pinned_reg(left);
        let empty = self.b.ins().icmp_imm_s(IntCC::SignedLessThan, left, 0);
        let tick = self.b.create_block();
        let next = self.b.create_block();
        self.b.set_cold_block(tick);
        self.b.ins().brif(empty, tick, &[], next, &[]);
        self.b.switch_to_block(tick);
        self.b.seal_block(tick);
        let frame = self.frame;
        self.call_helper(TICK, &[frame]);
        self.b.ins().jump(next, &[]);
        self.b.switch_to_block(next);
        self.b.seal_block(next);
    }

    fn stmts(&mut self, stmts: &[Stmt]) -> Result<(), Error> {
        for stmt in stmts {
            if self.is_filled() {
                self.unreachable();
            }
            self.stmt(stmt)?;
        }
        Ok(())
    }

    fn stmt(&mut self, stmt: &Stmt) -> Result<(), Error> {
        match stmt {
            Stmt::Expr(expr) => {
                self.expr(expr)?;
            }
            Stmt::If(test, then, otherwise) => self.if_stmt(test, then, otherwise)?,
            Stmt::Loop {
                cond,
                body,
                update,
                test_after,
            } => self.loop_stmt(cond.as_ref(), body, update, *test_after)?,
            Stmt::Break(depth) | Stmt::Continue(depth) => {
                let index = self
                    .loops
                    .len()
                    .checked_sub(1 + *depth as usize)
                    .ok_or("a break or continue outside its loop")?;
                let (continue_target, break_target) = self.loops[index];
                let target = if matches!(stmt, Stmt::Break(_)) {
                    break_target
                } else {
                    continue_target
                };
                self.b.ins().jump(target, &[]);
            }
            Stmt::Return(value) => self.return_stmt(value.as_ref())?,
            Stmt::Bail(reason) => self.bail(*reason),
        }
        Ok(())
    }

    fn if_stmt(&mut self, test: &Expr, then: &[Stmt], otherwise: &[Stmt]) -> Result<(), Error> {
        let then_block = self.b.create_block();
        let else_block = self.b.create_block();
        let merge = self.b.create_block();
        self.branch(test, then_block, else_block)?;
        self.b.seal_block(then_block);
        self.b.seal_block(else_block);
        self.b.switch_to_block(then_block);
        self.stmts(then)?;
        if !self.is_filled() {
            self.b.ins().jump(merge, &[]);
        }
        self.b.switch_to_block(else_block);
        self.stmts(otherwise)?;
        if !self.is_filled() {
            self.b.ins().jump(merge, &[]);
        }
        self.b.switch_to_block(merge);
        self.b.seal_block(merge);
        Ok(())
    }

    fn loop_stmt(
        &mut self,
        cond: Option<&Expr>,
        body: &[Stmt],
        update: &[Stmt],
        test_after: bool,
    ) -> Result<(), Error> {
        let header = self.b.create_block();
        let body_block = self.b.create_block();
        let update_block = self.b.create_block();
        let exit = self.b.create_block();
        let invariant = self.checked_invariants(cond, body, update);
        self.b
            .ins()
            .jump(if test_after { body_block } else { header }, &[]);
        self.b.switch_to_block(header);
        self.keep_checked(&invariant);
        self.fuel();
        if let Some(cond) = cond {
            self.branch(cond, body_block, exit)?;
        } else {
            self.b.ins().jump(body_block, &[]);
        }
        self.b.switch_to_block(body_block);
        self.b.seal_block(body_block);
        if test_after {
            self.keep_checked(&invariant);
        }
        self.loops.push((update_block, exit));
        self.stmts(body)?;
        if !self.is_filled() {
            self.b.ins().jump(update_block, &[]);
        }
        self.b.switch_to_block(update_block);
        self.b.seal_block(update_block);
        self.stmts(update)?;
        self.loops.pop();
        if !self.is_filled() {
            self.b.ins().jump(header, &[]);
        }
        self.b.seal_block(header);
        self.b.switch_to_block(exit);
        self.b.seal_block(exit);
        Ok(())
    }

    /// The checked locals that a loop never assigns: they stay checked in all of it.
    fn checked_invariants(
        &mut self,
        cond: Option<&Expr>,
        body: &[Stmt],
        update: &[Stmt],
    ) -> Vec<Variable> {
        let mut assigned = HashSet::new();
        if let Some(expr) = cond {
            assigned_in_expr(expr, &mut assigned);
        }
        assigned_in_stmts(body, &mut assigned);
        assigned_in_stmts(update, &mut assigned);
        let mut kept = Vec::new();
        for (index, var) in self.vars.clone().into_iter().enumerate() {
            let local = u32::try_from(index).unwrap_or(u32::MAX);
            if !assigned.contains(&local) && self.function.locals[index].is_reference() {
                let value = self.b.use_var(var);
                if self.nonnull.contains(&value) {
                    kept.push(var);
                }
            }
        }
        kept
    }

    /// Marks the values of `vars` in the current block as checked: a loop header or body
    /// sees them as block parameters, whose every incoming value is checked.
    fn keep_checked(&mut self, vars: &[Variable]) {
        for var in vars {
            let value = self.b.use_var(*var);
            self.nonnull.insert(value);
        }
    }

    /// Branches to `then` when the boolean `test` holds, else to `otherwise`. `&&`, `||`,
    /// and `!` become jumps, so no boolean is built only to be tested.
    fn branch(&mut self, test: &Expr, then: Block, otherwise: Block) -> Result<(), Error> {
        match test {
            Expr::And(left, right) | Expr::Or(left, right) => {
                let rest = self.b.create_block();
                if matches!(test, Expr::And(..)) {
                    self.branch(left, rest, otherwise)?;
                } else {
                    self.branch(left, then, rest)?;
                }
                self.b.switch_to_block(rest);
                self.b.seal_block(rest);
                self.branch(right, then, otherwise)
            }
            Expr::Unary(Unary::Not, operand) => self.branch(operand, otherwise, then),
            _ => {
                let condition = self.boolean(test)?;
                self.b.ins().brif(condition, then, &[], otherwise, &[]);
                Ok(())
            }
        }
    }

    fn return_stmt(&mut self, value: Option<&Expr>) -> Result<(), Error> {
        let result = self.function.result.clone();
        let value = match value {
            Some(value) => {
                let (value, ty) = self.expr(value)?;
                self.expect(&ty, &result)?;
                value
            }
            None if result == Ty::Void => None,
            None => {
                self.bail(Bail::Undefined);
                return Ok(());
            }
        };
        if let Some(exit) = self.exit {
            let args: Vec<BlockArg> = value.into_iter().map(BlockArg::Value).collect();
            self.b.ins().jump(exit, &args);
        } else {
            let values: Vec<Value> = value.into_iter().collect();
            self.b.ins().return_(&values);
        }
        Ok(())
    }

    fn expect(&self, from: &Ty, to: &Ty) -> Result<(), Error> {
        if fits(self.program, from, to) {
            Ok(())
        } else {
            fail(format!(
                "{}: a value of {from:?} where {to:?} goes",
                self.function.name
            ))
        }
    }

    fn value(&mut self, expr: &Expr) -> Result<(Value, Ty), Error> {
        match self.expr(expr)? {
            (Some(value), ty) => Ok((value, ty)),
            (None, _) => fail("an expression of type void used as a value"),
        }
    }

    fn number(&mut self, expr: &Expr) -> Result<Value, Error> {
        let (value, ty) = self.value(expr)?;
        if ty != Ty::Num {
            return fail(format!("{}: a number is expected", self.function.name));
        }
        Ok(value)
    }

    fn boolean(&mut self, expr: &Expr) -> Result<Value, Error> {
        let (value, ty) = self.value(expr)?;
        if ty != Ty::Bool {
            return fail(format!("{}: a boolean is expected", self.function.name));
        }
        Ok(value)
    }

    fn reference(&mut self, expr: &Expr) -> Result<(Value, Ty), Error> {
        let (value, ty) = self.value(expr)?;
        if !ty.is_reference() {
            return fail(format!("{}: a reference is expected", self.function.name));
        }
        Ok((value, ty))
    }

    /// Bails when the reference is `null` or `undefined`.
    fn check_object(&mut self, value: Value) {
        let nullish = self
            .b
            .ins()
            .icmp_imm_s(IntCC::UnsignedLessThan, value, UNDEFINED + 1);
        self.bail_if(nullish, Bail::Nullish);
    }

    /// The value of a reference expression, checked: it bails when the reference is
    /// `null` or `undefined`. A local that held it holds the checked value from then on,
    /// so the accesses that follow in code that the check dominates skip the check.
    fn object(&mut self, expr: &Expr) -> Result<(Value, Ty), Error> {
        let (value, ty) = self.reference(expr)?;
        Ok((self.checked(value, Some(expr))?, ty))
    }

    /// `value`, checked as `object` checks it.
    fn checked(&mut self, value: Value, expr: Option<&Expr>) -> Result<Value, Error> {
        if self.nonnull.contains(&value) {
            return Ok(value);
        }
        self.check_object(value);
        let checked = self.b.ins().iadd_imm_s(value, 0);
        self.nonnull.insert(checked);
        if let Some(Expr::Local(local)) = expr {
            let (var, _) = self.local(*local)?;
            self.b.def_var(var, checked);
        }
        Ok(checked)
    }

    fn local(&self, local: u32) -> Result<(Variable, Ty), Error> {
        let index = local as usize;
        match (self.vars.get(index), self.function.locals.get(index)) {
            (Some(var), Some(ty)) => Ok((*var, ty.clone())),
            _ => fail(format!("{}: no local {local}", self.function.name)),
        }
    }

    fn field_slot(&self, object_ty: &Ty, class: ClassId, index: u32) -> Result<(i32, Ty), Error> {
        let Ty::Object(actual) = object_ty else {
            return fail("a field of a value that is not an object");
        };
        if !is_subclass(self.program, *actual, class) {
            return fail("a field of an object of another class");
        }
        let class_data = self
            .program
            .classes
            .get(class as usize)
            .ok_or("no such class")?;
        let ty = class_data
            .fields
            .get(index as usize)
            .ok_or("no such field")?
            .clone();
        let at = i32::try_from(8 + 8 * u64::from(index)).map_err(|e| e.to_string())?;
        Ok((at, ty))
    }

    fn expr(&mut self, expr: &Expr) -> Result<Typed, Error> {
        let flags = MemFlagsData::trusted();
        Ok(match expr {
            Expr::Num(value) => {
                let constant = self.b.ins().f64const(*value);
                self.constants.insert(constant, *value);
                (Some(constant), Ty::Num)
            }
            Expr::Bool(value) => (
                Some(self.b.ins().iconst(types::I8, i64::from(*value))),
                Ty::Bool,
            ),
            Expr::Null => (Some(self.b.ins().iconst(types::I64, 0)), Ty::Null),
            Expr::Undefined => (Some(self.b.ins().iconst(types::I64, UNDEFINED)), Ty::Null),
            Expr::Local(local) => {
                let (var, ty) = self.local(*local)?;
                (Some(self.b.use_var(var)), ty)
            }
            Expr::Global(index) => self.global(*index)?,
            Expr::SetGlobal(index, value) => self.set_global(*index, value)?,
            Expr::Str(units) => (Some(self.literal(units)), Ty::Str),
            Expr::Text(parts) => (Some(self.text(parts)?), Ty::Str),
            Expr::Shift(array) => self.shift(array)?,
            Expr::Fail(reason, ty) => self.fail_with(*reason, ty)?,
            Expr::Block(stmts, value) => {
                self.stmts(stmts)?;
                if self.is_filled() {
                    self.unreachable();
                }
                self.expr(value)?
            }
            Expr::SetLocal(local, value) => {
                let (var, ty) = self.local(*local)?;
                let (value, value_ty) = self.value(value)?;
                self.expect(&value_ty, &ty)?;
                self.b.def_var(var, value);
                (Some(value), ty)
            }
            Expr::Unary(op, operand) => self.unary(*op, operand)?,
            Expr::Binary(op, left, right) => self.binary(*op, left, right)?,
            Expr::And(left, right) => self.logical(true, left, right)?,
            Expr::Or(left, right) => self.logical(false, left, right)?,
            Expr::Cond(ty, test, then, otherwise) => self.conditional(ty, test, then, otherwise)?,
            Expr::Field(object, class, index) => {
                let (object, object_ty) = self.object(object)?;
                let (at, ty) = self.field_slot(&object_ty, *class, *index)?;
                let repr = repr(&ty).ok_or("a field without a value")?;
                (Some(self.b.ins().load(repr, flags, object, at)), ty)
            }
            Expr::SetField(object, class, index, value) => {
                let (object, object_ty) = self.object(object)?;
                let (at, ty) = self.field_slot(&object_ty, *class, *index)?;
                let (value, value_ty) = self.value(value)?;
                self.expect(&value_ty, &ty)?;
                self.b.ins().store(flags, value, object, at);
                (Some(value), ty)
            }
            Expr::Length(target) => (Some(self.length(target)?), Ty::Num),
            Expr::Index(array, index) => self.index(array, index)?,
            Expr::SetIndex(array, index, value) => self.set_index(array, index, value)?,
            Expr::Push(array, value) => {
                let (array, element) = self.array(array)?;
                let (value, value_ty) = self.value(value)?;
                self.expect(&value_ty, &element)?;
                let length = self.push(array, value);
                (
                    Some(self.b.ins().fcvt_from_uint(types::F64, length)),
                    Ty::Num,
                )
            }
            Expr::Call(function, args) => self.call(*function, args)?,
            Expr::Dispatch {
                method,
                args,
                result,
            } => self.dispatch(method, args, result)?,
            Expr::New(class, constructor, args) => self.new_object(*class, *constructor, args)?,
            Expr::ArrayOf(element, items) => self.array_of(element, items)?,
            Expr::ArrayFill(element, length, value) => {
                check_value_type(self.program, element)?;
                let length = self.number(length)?;
                let (value, value_ty) = self.value(value)?;
                self.expect(&value_ty, element)?;
                (
                    Some(self.array_fill(length, value)),
                    Ty::Array(Box::new(element.clone())),
                )
            }
            Expr::Math(function, args) => self.math(*function, args)?,
            Expr::Seq(items) => {
                let mut last = (None, Ty::Void);
                for item in items {
                    last = self.expr(item)?;
                }
                last
            }
        })
    }

    fn global(&mut self, index: u32) -> Result<Typed, Error> {
        let ty = self
            .program
            .globals
            .get(index as usize)
            .ok_or("no such global")?
            .clone();
        // A global that no code writes never changes during a run, so its loads may move
        // and merge.
        let fixed = MemFlagsData::trusted().with_readonly().with_can_move();
        let flags = if self.written.contains(&index) {
            MemFlagsData::trusted()
        } else {
            fixed
        };
        let globals = self
            .b
            .ins()
            .load(types::I64, fixed, self.frame, frame::GLOBALS);
        let at = i32::try_from(8 * u64::from(index)).map_err(|e| e.to_string())?;
        let repr = repr(&ty).ok_or("a global without a value")?;
        Ok((Some(self.b.ins().load(repr, flags, globals, at)), ty))
    }

    /// The length of an array or a string.
    fn length(&mut self, target: &Expr) -> Result<Value, Error> {
        let (value, ty) = self.value(target)?;
        if !matches!(ty, Ty::Array(_) | Ty::Str) {
            return fail(format!("{}: a length of a value", self.function.name));
        }
        let value = self.checked(value, Some(target))?;
        // An array and a string keep their length at the same offset.
        let length = self
            .b
            .ins()
            .load(types::I64, MemFlagsData::trusted(), value, array::LENGTH);
        Ok(self.b.ins().fcvt_from_uint(types::F64, length))
    }

    fn shift(&mut self, array: &Expr) -> Result<Typed, Error> {
        let (array, element) = self.array(array)?;
        if !element.is_reference() {
            return fail("shift of an array of numbers or booleans");
        }
        let first = self.call_helper(SHIFT, &[array]).ok_or("shift")?;
        Ok((Some(first), element))
    }

    /// A bail where a value of `ty` stands: the code after it never runs.
    fn fail_with(&mut self, reason: Bail, ty: &Ty) -> Result<Typed, Error> {
        self.bail(reason);
        self.unreachable();
        if *ty == Ty::Void {
            return Ok((None, Ty::Void));
        }
        check_value_type(self.program, ty)?;
        Ok((Some(self.zero(ty)), ty.clone()))
    }

    fn set_global(&mut self, index: u32, value: &Expr) -> Result<Typed, Error> {
        let ty = self
            .program
            .globals
            .get(index as usize)
            .ok_or("no such global")?
            .clone();
        let (value, value_ty) = self.value(value)?;
        self.expect(&value_ty, &ty)?;
        let fixed = MemFlagsData::trusted().with_readonly().with_can_move();
        let globals = self
            .b
            .ins()
            .load(types::I64, fixed, self.frame, frame::GLOBALS);
        let at = i32::try_from(8 * u64::from(index)).map_err(|e| e.to_string())?;
        self.b
            .ins()
            .store(MemFlagsData::trusted(), value, globals, at);
        Ok((Some(value), ty))
    }

    /// The address of the string of a literal, which the code keeps.
    fn literal(&mut self, units: &[u16]) -> Value {
        let words = text::string_words(units);
        let address = words.as_ptr() as i64;
        self.literals.push(words);
        let value = self.b.ins().iconst(types::I64, address);
        self.nonnull.insert(value);
        value
    }

    /// A new string of the parts, each converted as `ToString` does: the helper reads
    /// pairs of words, a kind and the value, from a slot of the stack.
    fn text(&mut self, parts: &[Expr]) -> Result<Value, Error> {
        let bytes = u32::try_from(16 * parts.len().max(1)).map_err(|e| e.to_string())?;
        let slot = self.b.create_sized_stack_slot(StackSlotData::new(
            StackSlotKind::ExplicitSlot,
            bytes,
            3,
        ));
        for (index, part) in parts.iter().enumerate() {
            let (value, ty) = self.value(part)?;
            let (kind, word) = match ty {
                Ty::Num => (text::TEXT_NUM, value),
                Ty::Bool => (text::TEXT_BOOL, self.b.ins().uextend(types::I64, value)),
                Ty::Str | Ty::Null => (text::TEXT_STR, value),
                _ => return fail("a part of a template that is not a primitive"),
            };
            let at = i32::try_from(16 * index).map_err(|e| e.to_string())?;
            let kind = self.b.ins().iconst(types::I64, kind);
            self.b.ins().stack_store(types::I64, kind, slot, at);
            self.b.ins().stack_store(types::I64, word, slot, at + 8);
        }
        let address = self.b.ins().stack_addr(types::I64, slot, 0);
        let count = self
            .b
            .ins()
            .iconst(types::I64, i64::try_from(parts.len()).unwrap_or(0));
        let frame = self.frame;
        let text = self
            .call_helper(TEXT, &[frame, address, count])
            .ok_or("text")?;
        self.nonnull.insert(text);
        Ok(text)
    }

    fn conditional(
        &mut self,
        ty: &Ty,
        test: &Expr,
        then: &Expr,
        otherwise: &Expr,
    ) -> Result<Typed, Error> {
        let repr = repr(ty).ok_or("a conditional without a value")?;
        let then_block = self.b.create_block();
        let else_block = self.b.create_block();
        let merge = self.b.create_block();
        let result = self.b.append_block_param(merge, repr);
        self.branch(test, then_block, else_block)?;
        for (block, branch) in [(then_block, then), (else_block, otherwise)] {
            self.b.switch_to_block(block);
            self.b.seal_block(block);
            let (value, value_ty) = self.value(branch)?;
            self.expect(&value_ty, ty)?;
            self.b.ins().jump(merge, &[BlockArg::Value(value)]);
        }
        self.b.switch_to_block(merge);
        self.b.seal_block(merge);
        Ok((Some(result), ty.clone()))
    }

    fn array_of(&mut self, element: &Ty, items: &[Expr]) -> Result<Typed, Error> {
        let mut values = Vec::with_capacity(items.len());
        for item in items {
            let (value, ty) = self.value(item)?;
            self.expect(&ty, element)?;
            values.push(value);
        }
        check_value_type(self.program, element)?;
        let count = i64::try_from(values.len()).map_err(|e| e.to_string())?;
        let capacity = count.max(4);
        let array = self.allocate_const(array::SIZE + 8 * capacity);
        let data = self.b.ins().iadd_imm_s(array, array::SIZE);
        self.init_array(array, count, capacity, data);
        for (index, value) in values.into_iter().enumerate() {
            let at = i32::try_from(8 * index).map_err(|e| e.to_string())?;
            self.b.ins().store(MemFlagsData::trusted(), value, data, at);
        }
        Ok((Some(array), Ty::Array(Box::new(element.clone()))))
    }

    fn unary(&mut self, op: Unary, operand: &Expr) -> Result<Typed, Error> {
        Ok(match op {
            Unary::Neg => {
                let value = self.number(operand)?;
                (Some(self.b.ins().fneg(value)), Ty::Num)
            }
            Unary::Not => {
                let value = self.boolean(operand)?;
                (
                    Some(self.b.ins().icmp_imm_s(IntCC::Equal, value, 0)),
                    Ty::Bool,
                )
            }
            Unary::BitNot => {
                let value = self.number(operand)?;
                let int = self.int32(value);
                let flipped = self.b.ins().bnot(int);
                let number = self.b.ins().fcvt_from_sint(types::F64, flipped);
                self.int32s.insert(number, flipped);
                (Some(number), Ty::Num)
            }
            Unary::Truthy => {
                let (value, ty) = self.value(operand)?;
                let truth = match ty {
                    Ty::Num => {
                        let zero = self.b.ins().f64const(0.0);
                        self.b.ins().fcmp(FloatCC::OrderedNotEqual, value, zero)
                    }
                    Ty::Bool => value,
                    Ty::Str => self.call_helper(STR_TRUTHY, &[value]).ok_or("truthy")?,
                    _ => self
                        .b
                        .ins()
                        .icmp_imm_s(IntCC::UnsignedGreaterThan, value, UNDEFINED),
                };
                (Some(truth), Ty::Bool)
            }
            Unary::Nullish => {
                let (value, _) = self.reference(operand)?;
                (
                    Some(
                        self.b
                            .ins()
                            .icmp_imm_s(IntCC::UnsignedLessThan, value, UNDEFINED + 1),
                    ),
                    Ty::Bool,
                )
            }
        })
    }

    /// `ToInt32` of a number: a conversion when it fits in 64 bits, else the helper.
    fn int32(&mut self, value: Value) -> Value {
        if let Some(int) = self.int32s.get(&value) {
            return *int;
        }
        if let Some(constant) = self.constants.get(&value) {
            return self
                .b
                .ins()
                .iconst(types::I32, i64::from(buoy_jit_ir::to_int32(*constant)));
        }
        let magnitude = self.b.ins().fabs(value);
        let bound = self.b.ins().f64const(9.0e18);
        let small = self.b.ins().fcmp(FloatCC::LessThan, magnitude, bound);
        let fast = self.b.create_block();
        let slow = self.b.create_block();
        let merge = self.b.create_block();
        let result = self.b.append_block_param(merge, types::I32);
        self.b.set_cold_block(slow);
        self.b.ins().brif(small, fast, &[], slow, &[]);
        self.b.seal_block(fast);
        self.b.seal_block(slow);
        self.b.switch_to_block(fast);
        let wide = self.b.ins().fcvt_to_sint_sat(types::I64, value);
        let narrow = self.b.ins().ireduce(types::I32, wide);
        self.b.ins().jump(merge, &[BlockArg::Value(narrow)]);
        self.b.switch_to_block(slow);
        let converted = self
            .call_helper(INT32, &[value])
            .unwrap_or_else(|| self.b.ins().iconst(types::I32, 0));
        self.b.ins().jump(merge, &[BlockArg::Value(converted)]);
        self.b.switch_to_block(merge);
        self.b.seal_block(merge);
        result
    }

    fn binary(&mut self, op: Binary, left: &Expr, right: &Expr) -> Result<Typed, Error> {
        if matches!(op, Binary::Eq | Binary::Ne) {
            return self.equality(op == Binary::Eq, left, right);
        }
        let a = self.number(left)?;
        let b = self.number(right)?;
        if let Some(compared) = self.int_compare(op, a, b) {
            return Ok((Some(compared), Ty::Bool));
        }
        let ins = self.b.ins();
        let number = |value| (Some(value), Ty::Num);
        Ok(match op {
            Binary::Add => number(ins.fadd(a, b)),
            Binary::Sub => number(ins.fsub(a, b)),
            Binary::Mul => number(ins.fmul(a, b)),
            Binary::Div => number(ins.fdiv(a, b)),
            Binary::Rem => number(self.call_helper(FMOD, &[a, b]).ok_or("fmod")?),
            Binary::Pow => number(self.call_helper(POW, &[a, b]).ok_or("pow")?),
            Binary::Lt => (Some(ins.fcmp(FloatCC::LessThan, a, b)), Ty::Bool),
            Binary::Le => (Some(ins.fcmp(FloatCC::LessThanOrEqual, a, b)), Ty::Bool),
            Binary::Gt => (Some(ins.fcmp(FloatCC::GreaterThan, a, b)), Ty::Bool),
            Binary::Ge => (Some(ins.fcmp(FloatCC::GreaterThanOrEqual, a, b)), Ty::Bool),
            Binary::BitAnd
            | Binary::BitOr
            | Binary::BitXor
            | Binary::Shl
            | Binary::Shr
            | Binary::UShr => number(self.bitwise(op, a, b)),
            Binary::Eq | Binary::Ne => unreachable!("equality returns above"),
        })
    }

    fn bitwise(&mut self, op: Binary, a: Value, b: Value) -> Value {
        let x = self.int32(a);
        let y = self.int32(b);
        let ins = self.b.ins();
        let (result, unsigned) = match op {
            Binary::BitAnd => (ins.band(x, y), false),
            Binary::BitOr => (ins.bor(x, y), false),
            Binary::BitXor => (ins.bxor(x, y), false),
            Binary::Shl => (ins.ishl(x, y), false),
            Binary::Shr => (ins.sshr(x, y), false),
            _ => (ins.ushr(x, y), true),
        };
        let number = if unsigned {
            self.b.ins().fcvt_from_uint(types::F64, result)
        } else {
            self.b.ins().fcvt_from_sint(types::F64, result)
        };
        // A uint32 has the bits of its ToInt32.
        self.int32s.insert(number, result);
        number
    }

    /// The 32-bit integer of a number that is one: a result of a bitwise operator, or a
    /// constant that is an int32.
    fn known_int32(&mut self, value: Value) -> Option<Value> {
        if let Some(int) = self.int32s.get(&value) {
            return Some(*int);
        }
        let constant = *self.constants.get(&value)?;
        let int = buoy_jit_ir::to_int32(constant);
        (f64::from(int).to_bits() == constant.to_bits() || (int == 0 && constant == 0.0))
            .then(|| self.b.ins().iconst(types::I32, i64::from(int)))
    }

    /// A comparison of two numbers that are both int32s, as one of integers: it gives the
    /// result of the comparison of doubles, which hold them exactly.
    fn int_compare(&mut self, op: Binary, a: Value, b: Value) -> Option<Value> {
        let cc = match op {
            Binary::Lt => IntCC::SignedLessThan,
            Binary::Le => IntCC::SignedLessThanOrEqual,
            Binary::Gt => IntCC::SignedGreaterThan,
            Binary::Ge => IntCC::SignedGreaterThanOrEqual,
            Binary::Eq => IntCC::Equal,
            Binary::Ne => IntCC::NotEqual,
            _ => return None,
        };
        if !self.int32s.contains_key(&a) && !self.int32s.contains_key(&b) {
            return None;
        }
        let x = self.known_int32(a)?;
        let y = self.known_int32(b)?;
        Some(self.b.ins().icmp(cc, x, y))
    }

    /// `===` and `!==`: of numbers by value, of booleans and references by identity.
    /// Operands of different kinds are never equal.
    fn equality(&mut self, equal: bool, left: &Expr, right: &Expr) -> Result<Typed, Error> {
        let (a, a_ty) = self.value(left)?;
        let (b, b_ty) = self.value(right)?;
        let result = match (&a_ty, &b_ty) {
            (Ty::Num, Ty::Num) => {
                let op = if equal { Binary::Eq } else { Binary::Ne };
                if let Some(compared) = self.int_compare(op, a, b) {
                    compared
                } else {
                    let cc = if equal {
                        FloatCC::Equal
                    } else {
                        FloatCC::NotEqual
                    };
                    self.b.ins().fcmp(cc, a, b)
                }
            }
            (Ty::Bool, Ty::Bool) => {
                let cc = if equal { IntCC::Equal } else { IntCC::NotEqual };
                self.b.ins().icmp(cc, a, b)
            }
            (Ty::Str, Ty::Str) => {
                let same = self.call_helper(STR_EQ, &[a, b]).ok_or("equality")?;
                let cc = if equal { IntCC::NotEqual } else { IntCC::Equal };
                self.b.ins().icmp_imm_s(cc, same, 0)
            }
            _ if a_ty.is_reference() && b_ty.is_reference() => {
                let cc = if equal { IntCC::Equal } else { IntCC::NotEqual };
                self.b.ins().icmp(cc, a, b)
            }
            _ => self.b.ins().iconst(types::I8, i64::from(!equal)),
        };
        Ok((Some(result), Ty::Bool))
    }

    fn logical(&mut self, and: bool, left: &Expr, right: &Expr) -> Result<Typed, Error> {
        let first = self.boolean(left)?;
        let rest = self.b.create_block();
        let merge = self.b.create_block();
        let result = self.b.append_block_param(merge, types::I8);
        if and {
            self.b
                .ins()
                .brif(first, rest, &[], merge, &[BlockArg::Value(first)]);
        } else {
            self.b
                .ins()
                .brif(first, merge, &[BlockArg::Value(first)], rest, &[]);
        }
        self.b.switch_to_block(rest);
        self.b.seal_block(rest);
        let second = self.boolean(right)?;
        self.b.ins().jump(merge, &[BlockArg::Value(second)]);
        self.b.switch_to_block(merge);
        self.b.seal_block(merge);
        Ok((Some(result), Ty::Bool))
    }

    fn array(&mut self, expr: &Expr) -> Result<(Value, Ty), Error> {
        let (array, ty) = self.value(expr)?;
        let Ty::Array(element) = ty else {
            return fail(format!("{}: an array is expected", self.function.name));
        };
        let array = self.checked(array, Some(expr))?;
        Ok((array, *element))
    }

    /// The integer of a number that is an exact integer, and whether it is one.
    fn exact_index(&mut self, index: Value) -> (Value, Value) {
        let integer = self.b.ins().fcvt_to_sint_sat(types::I64, index);
        let back = self.b.ins().fcvt_from_sint(types::F64, integer);
        let exact = self.b.ins().fcmp(FloatCC::Equal, back, index);
        (integer, exact)
    }

    fn element_address(&mut self, array: Value, integer: Value) -> Value {
        let data = self
            .b
            .ins()
            .load(types::I64, MemFlagsData::trusted(), array, array::DATA);
        let offset = self.b.ins().ishl_imm_u(integer, 3);
        self.b.ins().iadd(data, offset)
    }

    fn index(&mut self, array: &Expr, index: &Expr) -> Result<Typed, Error> {
        let (array, element) = self.array(array)?;
        let index = self.number(index)?;
        let repr = repr(&element).ok_or("an element without a value")?;
        let (integer, exact) = self.exact_index(index);
        let length = self
            .b
            .ins()
            .load(types::I64, MemFlagsData::trusted(), array, array::LENGTH);
        let inside = self.b.ins().icmp(IntCC::UnsignedLessThan, integer, length);
        let found = self.b.ins().band(exact, inside);
        let read = self.b.create_block();
        let outside = self.b.create_block();
        let merge = self.b.create_block();
        let result = self.b.append_block_param(merge, repr);
        self.b.ins().brif(found, read, &[], outside, &[]);
        self.b.seal_block(read);
        self.b.seal_block(outside);
        self.b.switch_to_block(read);
        let address = self.element_address(array, integer);
        let value = self.b.ins().load(repr, MemFlagsData::trusted(), address, 0);
        self.b.ins().jump(merge, &[BlockArg::Value(value)]);
        self.b.switch_to_block(outside);
        if element.is_reference() {
            let undefined = self.b.ins().iconst(types::I64, UNDEFINED);
            self.b.ins().jump(merge, &[BlockArg::Value(undefined)]);
        } else {
            self.bail(Bail::Index);
        }
        self.b.switch_to_block(merge);
        self.b.seal_block(merge);
        Ok((Some(result), element))
    }

    fn set_index(&mut self, array: &Expr, index: &Expr, value: &Expr) -> Result<Typed, Error> {
        let (array_value, array_ty) = self.value(array)?;
        let Ty::Array(element) = array_ty else {
            return fail("an element of a value that is not an array");
        };
        let index = self.number(index)?;
        let (value, value_ty) = self.value(value)?;
        self.expect(&value_ty, &element)?;
        let array_value = self.checked(array_value, Some(array))?;
        let (integer, exact) = self.exact_index(index);
        let not_exact = self.b.ins().icmp_imm_s(IntCC::Equal, exact, 0);
        self.bail_if(not_exact, Bail::Index);
        let length = self.b.ins().load(
            types::I64,
            MemFlagsData::trusted(),
            array_value,
            array::LENGTH,
        );
        let inside = self.b.ins().icmp(IntCC::UnsignedLessThan, integer, length);
        let write = self.b.create_block();
        let append = self.b.create_block();
        let merge = self.b.create_block();
        self.b.ins().brif(inside, write, &[], append, &[]);
        self.b.seal_block(write);
        self.b.seal_block(append);
        self.b.switch_to_block(write);
        let address = self.element_address(array_value, integer);
        self.b
            .ins()
            .store(MemFlagsData::trusted(), value, address, 0);
        self.b.ins().jump(merge, &[]);
        self.b.switch_to_block(append);
        let at_end = self.b.ins().icmp(IntCC::Equal, integer, length);
        let past = self.b.ins().icmp_imm_s(IntCC::Equal, at_end, 0);
        self.bail_if(past, Bail::Index);
        self.push(array_value, value);
        self.b.ins().jump(merge, &[]);
        self.b.switch_to_block(merge);
        self.b.seal_block(merge);
        Ok((Some(value), *element))
    }

    /// Appends `value`, growing the array when it is full, and returns the new length.
    fn push(&mut self, array: Value, value: Value) -> Value {
        let flags = MemFlagsData::trusted();
        let length = self.b.ins().load(types::I64, flags, array, array::LENGTH);
        let capacity = self.b.ins().load(types::I64, flags, array, array::CAPACITY);
        let full = self.b.ins().icmp(IntCC::Equal, length, capacity);
        let grow = self.b.create_block();
        let store = self.b.create_block();
        self.b.set_cold_block(grow);
        self.b.ins().brif(full, grow, &[], store, &[]);
        self.b.switch_to_block(grow);
        self.b.seal_block(grow);
        let frame = self.frame;
        self.call_helper(GROW, &[frame, array]);
        self.b.ins().jump(store, &[]);
        self.b.switch_to_block(store);
        self.b.seal_block(store);
        let address = self.element_address(array, length);
        self.b.ins().store(flags, value, address, 0);
        let longer = self.b.ins().iadd_imm_s(length, 1);
        self.b.ins().store(flags, longer, array, array::LENGTH);
        longer
    }

    fn init_array(&mut self, array: Value, count: i64, capacity: i64, data: Value) {
        let flags = MemFlagsData::trusted();
        let tag = self.b.ins().iconst(types::I64, ARRAY_TAG);
        self.b.ins().store(flags, tag, array, 0);
        let length = self.b.ins().iconst(types::I64, count);
        self.b.ins().store(flags, length, array, array::LENGTH);
        let capacity = self.b.ins().iconst(types::I64, capacity);
        self.b.ins().store(flags, capacity, array, array::CAPACITY);
        self.b.ins().store(flags, data, array, array::DATA);
    }

    fn array_fill(&mut self, length: Value, value: Value) -> Value {
        let flags = MemFlagsData::trusted();
        // `new Array(n)` throws a RangeError unless n is an integer in [0, 2^32).
        let (count, exact) = self.exact_index(length);
        let not_exact = self.b.ins().icmp_imm_s(IntCC::Equal, exact, 0);
        self.bail_if(not_exact, Bail::Throw);
        let negative = self.b.ins().icmp_imm_s(IntCC::SignedLessThan, count, 0);
        self.bail_if(negative, Bail::Throw);
        let huge = self
            .b
            .ins()
            .icmp_imm_s(IntCC::SignedGreaterThan, count, MAX_ELEMENTS);
        self.bail_if(huge, Bail::Memory);
        let capacity = self.b.ins().iadd_imm_s(count, 1);
        let bytes = self.b.ins().ishl_imm_u(capacity, 3);
        let size = self.b.ins().iadd_imm_s(bytes, array::SIZE);
        let array = self.allocate(size);
        let data = self.b.ins().iadd_imm_s(array, array::SIZE);
        let tag = self.b.ins().iconst(types::I64, ARRAY_TAG);
        self.b.ins().store(flags, tag, array, 0);
        self.b.ins().store(flags, count, array, array::LENGTH);
        self.b.ins().store(flags, capacity, array, array::CAPACITY);
        self.b.ins().store(flags, data, array, array::DATA);
        let header = self.b.create_block();
        let body = self.b.create_block();
        let exit = self.b.create_block();
        let start = self.b.ins().iconst(types::I64, 0);
        let index = self.b.append_block_param(header, types::I64);
        self.b.ins().jump(header, &[BlockArg::Value(start)]);
        self.b.switch_to_block(header);
        let more = self.b.ins().icmp(IntCC::SignedLessThan, index, count);
        self.b.ins().brif(more, body, &[], exit, &[]);
        self.b.seal_block(body);
        self.b.seal_block(exit);
        self.b.switch_to_block(body);
        let offset = self.b.ins().ishl_imm_u(index, 3);
        let address = self.b.ins().iadd(data, offset);
        self.b.ins().store(flags, value, address, 0);
        let next = self.b.ins().iadd_imm_s(index, 1);
        self.b.ins().jump(header, &[BlockArg::Value(next)]);
        self.b.seal_block(header);
        self.b.switch_to_block(exit);
        array
    }

    /// The address of `size` new bytes of the heap.
    fn allocate(&mut self, size: Value) -> Value {
        let flags = MemFlagsData::trusted();
        let next = self
            .b
            .ins()
            .load(types::I64, flags, self.frame, frame::HEAP_NEXT);
        let end = self.b.ins().iadd(next, size);
        let limit = self
            .b
            .ins()
            .load(types::I64, flags, self.frame, frame::HEAP_END);
        let over = self.b.ins().icmp(IntCC::UnsignedGreaterThan, end, limit);
        let fast = self.b.create_block();
        let slow = self.b.create_block();
        let merge = self.b.create_block();
        let result = self.b.append_block_param(merge, types::I64);
        self.b.set_cold_block(slow);
        self.b.ins().brif(over, slow, &[], fast, &[]);
        self.b.seal_block(fast);
        self.b.seal_block(slow);
        self.b.switch_to_block(fast);
        self.b.ins().store(flags, end, self.frame, frame::HEAP_NEXT);
        self.b.ins().jump(merge, &[BlockArg::Value(next)]);
        self.b.switch_to_block(slow);
        let frame = self.frame;
        let fresh = self
            .call_helper(ALLOC, &[frame, size])
            .unwrap_or_else(|| self.b.ins().iconst(types::I64, 0));
        self.b.ins().jump(merge, &[BlockArg::Value(fresh)]);
        self.b.switch_to_block(merge);
        self.b.seal_block(merge);
        result
    }

    fn allocate_const(&mut self, size: i64) -> Value {
        let size = self.b.ins().iconst(types::I64, size);
        self.allocate(size)
    }

    fn arguments(
        &mut self,
        function: &Function,
        args: &[Expr],
        skip: usize,
    ) -> Result<Vec<Value>, Error> {
        let params = &function.locals[..function.params as usize];
        if params.len() != args.len() + skip {
            return fail(format!(
                "{}: a call with the wrong count of arguments",
                function.name
            ));
        }
        let mut values = Vec::with_capacity(args.len());
        for (arg, ty) in args.iter().zip(&params[skip..]) {
            let (value, value_ty) = self.value(arg)?;
            self.expect(&value_ty, ty)?;
            values.push(value);
        }
        Ok(values)
    }

    fn call(&mut self, id: FuncId, args: &[Expr]) -> Result<Typed, Error> {
        let program = self.program;
        let function = function_at(program, id)?;
        let mut values = self.arguments(function, args, 0)?;
        // The callee relies on its receiver, so a direct call checks it.
        if function.receiver
            && let Some(first) = values.first_mut()
        {
            *first = self.checked(*first, args.first())?;
        }
        let result = self.invoke(id, values)?;
        Ok((result, function.result.clone()))
    }

    /// Calls the function with the values of its parameters: inline when its body is
    /// small and the call is not recursive, else with a call instruction.
    fn invoke(&mut self, id: FuncId, values: Vec<Value>) -> Result<Option<Value>, Error> {
        let function = function_at(self.program, id)?;
        let small = size_of_stmts(&function.body) <= INLINE_SIZE;
        let recursive = self.inlined.contains(&id) || std::ptr::eq(function, self.function);
        if small && !recursive && self.inlined.len() < INLINE_DEPTH {
            return self.inline(id, function, &values);
        }
        let callee = self.function_ref(id)?;
        let mut call_args = vec![self.frame];
        call_args.extend(values);
        let call = self.b.ins().call(callee, &call_args);
        Ok(self.b.inst_results(call).first().copied())
    }

    /// Emits the body of `function` in place of a call, with its locals as new variables
    /// and its returns as jumps to the block after it.
    fn inline(
        &mut self,
        id: FuncId,
        function: &'a Function,
        values: &[Value],
    ) -> Result<Option<Value>, Error> {
        let exit = self.b.create_block();
        let result = repr(&function.result).map(|repr| self.b.append_block_param(exit, repr));
        let mut vars = Vec::with_capacity(function.locals.len());
        for (index, ty) in function.locals.iter().enumerate() {
            let repr = repr(ty).ok_or("a local has no value")?;
            let var = self.b.declare_var(repr);
            let value = if index < function.params as usize {
                *values.get(index).ok_or("a parameter is missing")?
            } else {
                self.zero(ty)
            };
            self.b.def_var(var, value);
            vars.push(var);
        }
        let saved_function = std::mem::replace(&mut self.function, function);
        let saved_vars = std::mem::replace(&mut self.vars, vars);
        let saved_loops = std::mem::take(&mut self.loops);
        let saved_exit = self.exit.replace(exit);
        self.inlined.push(id);
        let emitted = self.stmts(&function.body);
        if emitted.is_ok() && !self.is_filled() {
            if function.result == Ty::Void {
                self.b.ins().jump(exit, &[]);
            } else {
                self.bail(Bail::Undefined);
            }
        }
        self.inlined.pop();
        self.exit = saved_exit;
        self.loops = saved_loops;
        self.vars = saved_vars;
        self.function = saved_function;
        emitted?;
        self.b.switch_to_block(exit);
        self.b.seal_block(exit);
        Ok(result)
    }

    fn new_object(
        &mut self,
        class: ClassId,
        constructor: FuncId,
        args: &[Expr],
    ) -> Result<Typed, Error> {
        let program = self.program;
        let class_data = program.classes.get(class as usize).ok_or("no such class")?;
        let function = function_at(program, constructor)?;
        let this_ty = function
            .locals
            .first()
            .ok_or("a constructor without this")?;
        if function.params == 0
            || !fits(program, &Ty::Object(class), this_ty)
            || function.result != Ty::Void
        {
            return fail("a constructor of another class");
        }
        let values = self.arguments(function, args, 1)?;
        let fields = i64::try_from(class_data.fields.len()).map_err(|e| e.to_string())?;
        let object = self.allocate_const(8 + 8 * fields);
        let flags = MemFlagsData::trusted();
        let id = self.b.ins().iconst(types::I64, i64::from(class));
        self.b.ins().store(flags, id, object, 0);
        let zero = self.b.ins().iconst(types::I64, 0);
        for index in 0..class_data.fields.len() {
            let at = i32::try_from(8 + 8 * index).map_err(|e| e.to_string())?;
            self.b.ins().store(flags, zero, object, at);
        }
        self.nonnull.insert(object);
        let mut call_args = vec![object];
        call_args.extend(values);
        self.invoke(constructor, call_args)?;
        Ok((Some(object), Ty::Object(class)))
    }

    fn dispatch(&mut self, method: &str, args: &[Expr], result: &Ty) -> Result<Typed, Error> {
        let program = self.program;
        let (receiver_expr, rest) = args.split_first().ok_or("a dispatch without a receiver")?;
        let (receiver, receiver_ty) = self.reference(receiver_expr)?;
        let bound = match receiver_ty {
            Ty::Object(class) => Some(class),
            Ty::Any | Ty::Null => None,
            _ => return fail("a dispatch on an array"),
        };
        let mut values = Vec::with_capacity(rest.len());
        let mut value_tys = Vec::with_capacity(rest.len());
        for arg in rest {
            let (value, ty) = self.value(arg)?;
            values.push(value);
            value_tys.push(ty);
        }
        // Each class that the receiver may have, and the function its method calls. A
        // class whose method of that name takes or returns other types cannot be the class
        // of the receiver of a well-typed call, such as a class that has a method of the
        // name but does not implement the interface; it stays out, and an object of it
        // bails.
        let mut targets: Vec<(ClassId, FuncId)> = Vec::new();
        for (index, class) in program.classes.iter().enumerate() {
            let id = u32::try_from(index).map_err(|e| e.to_string())?;
            if bound.is_some_and(|bound| !is_subclass(program, id, bound)) {
                continue;
            }
            let Some(found) = class.methods.iter().find(|m| m.name == method) else {
                continue;
            };
            let function = function_at(program, found.function)?;
            let params = &function.locals[..function.params as usize];
            let this_ok = params
                .first()
                .is_some_and(|ty| fits(program, &Ty::Object(id), ty));
            let args_ok = params.len() == value_tys.len() + 1
                && params[1..]
                    .iter()
                    .zip(&value_tys)
                    .all(|(to, from)| fits(program, from, to));
            let result_ok = if *result == Ty::Void {
                function.result == Ty::Void
            } else {
                fits(program, &function.result, result)
            };
            if this_ok && args_ok && result_ok {
                targets.push((id, found.function));
            }
        }
        let receiver = self.checked(receiver, Some(receiver_expr))?;
        // A receiver of a class whose subclasses all call one function needs no switch:
        // its type says that it is an instance of one of them.
        if let Some(bound) = bound
            && let Some(&(_, only)) = targets.first()
            && targets.iter().all(|(_, function)| *function == only)
            && (0..program.classes.len()).all(|index| {
                let id = u32::try_from(index).unwrap_or(u32::MAX);
                !is_subclass(program, id, bound) || targets.iter().any(|(class, _)| *class == id)
            })
        {
            let mut call_args = vec![receiver];
            call_args.extend(&values);
            let value = self.invoke(only, call_args)?;
            return Ok((value.filter(|_| *result != Ty::Void), result.clone()));
        }
        let class_id = self
            .b
            .ins()
            .load(types::I64, MemFlagsData::trusted(), receiver, 0);
        let merge = self.b.create_block();
        let result_repr = repr(result);
        let merged = result_repr.map(|repr| self.b.append_block_param(merge, repr));
        let mut switch = Switch::new();
        let mut blocks: HashMap<FuncId, Block> = HashMap::new();
        for &(class, function_id) in &targets {
            let block = *blocks
                .entry(function_id)
                .or_insert_with(|| self.b.create_block());
            switch.set_entry(u128::from(class), block);
        }
        let otherwise = self.bail_block(Bail::Dispatch);
        switch.emit(&mut self.b, class_id, otherwise);
        let mut ordered: Vec<(FuncId, Block)> = blocks.into_iter().collect();
        ordered.sort_by_key(|(id, _)| *id);
        for (function_id, block) in ordered {
            self.b.switch_to_block(block);
            self.b.seal_block(block);
            let mut call_args = vec![receiver];
            call_args.extend(&values);
            match (merged, self.invoke(function_id, call_args)?) {
                (Some(_), Some(value)) => {
                    self.b.ins().jump(merge, &[BlockArg::Value(value)]);
                }
                _ => {
                    self.b.ins().jump(merge, &[]);
                }
            }
        }
        self.b.switch_to_block(merge);
        self.b.seal_block(merge);
        Ok((merged, result.clone()))
    }

    fn math(&mut self, function: MathFn, args: &[Expr]) -> Result<Typed, Error> {
        let mut values = Vec::with_capacity(args.len());
        for arg in args {
            values.push(self.number(arg)?);
        }
        let arity = match function {
            MathFn::Min | MathFn::Max | MathFn::Atan2 | MathFn::Pow => 2,
            _ => 1,
        };
        if values.len() != arity {
            return fail("a Math function with the wrong count of arguments");
        }
        let a = values[0];
        let ins = self.b.ins();
        let value = match function {
            MathFn::Sqrt => ins.sqrt(a),
            MathFn::Abs => ins.fabs(a),
            MathFn::Floor => ins.floor(a),
            MathFn::Ceil => ins.ceil(a),
            MathFn::Trunc => ins.trunc(a),
            MathFn::Min => ins.fmin(a, values[1]),
            MathFn::Max => ins.fmax(a, values[1]),
            MathFn::Pow => self.call_helper(POW, &[a, values[1]]).ok_or("pow")?,
            _ => {
                let b = values.get(1).copied().unwrap_or(a);
                let code = self.b.ins().iconst(types::I32, function as i64);
                self.call_helper(MATH, &[code, a, b]).ok_or("math")?
            }
        };
        Ok((Some(value), Ty::Num))
    }
}
