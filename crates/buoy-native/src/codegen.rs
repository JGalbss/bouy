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
//! - `null` is the address 0 and `undefined` the address 1.

#![allow(unsafe_code)]

use std::collections::HashMap;

use buoy_native_ir::{
    Bail, Binary, ClassId, Expr, FuncId, Function, MathFn, Program, Stmt, Ty, Unary,
};
use cranelift_codegen::ir::condcodes::{FloatCC, IntCC};
use cranelift_codegen::ir::{
    AbiParam, Block, BlockArg, FuncRef, InstBuilder, MemFlagsData, Signature, TrapCode, Value,
    types,
};
use cranelift_frontend::{FunctionBuilder, FunctionBuilderContext, Switch, Variable};
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::{FuncId as ModuleFuncId, Linkage, Module, default_libcall_names};

use crate::run::{self, Value as RunValue};

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

/// The class word of an array, which no class id takes.
pub const ARRAY_TAG: i64 = 0xffff_ffff;

/// The most elements of an array.
const MAX_ELEMENTS: i64 = 1 << 31;

/// The undefined reference.
const UNDEFINED: i64 = 1;

/// The machine code of a program, and its entries.
pub struct Code {
    module: Option<JITModule>,
    entries: Vec<EntryFn>,
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

impl EntryFn {
    /// The words of the arguments and the globals, when each has the type of its place.
    pub fn arguments(&self, args: &[RunValue], globals: &[RunValue]) -> Option<Vec<u64>> {
        if args.len() != self.params.len() || globals.len() != self.globals.len() {
            return None;
        }
        self.params
            .iter()
            .chain(&self.globals)
            .zip(args.iter().chain(globals))
            .map(|(ty, value)| match (ty, value) {
                (Ty::Num, RunValue::Num(number)) => Some(number.to_bits()),
                (Ty::Bool, RunValue::Bool(flag)) => Some(u64::from(*flag)),
                _ => None,
            })
            .collect()
    }
}

impl Code {
    pub fn entry(&self, index: usize) -> Option<&EntryFn> {
        self.entries.get(index)
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

fn helpers() -> [Helper; 8] {
    use types::{F64, I32, I64};
    [
        Helper {
            name: "buoy_tick",
            address: run::buoy_tick as *const u8,
            params: &[I64],
            returns: &[],
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

/// Compiles every function of `program` and the trampolines of its entries.
pub fn compile(program: &Program) -> Result<Code, Error> {
    check_program(program)?;
    let mut builder = JITBuilder::with_flags(&[("opt_level", "speed")], default_libcall_names())
        .map_err(|error| error.to_string())?;
    let helpers = helpers();
    for helper in &helpers {
        builder.symbol(helper.name, helper.address);
    }
    let mut module = JITModule::new(builder);
    let compiled = define_all(&mut module, program, &helpers);
    match compiled {
        Ok(entries) => Ok(Code {
            module: Some(module),
            entries,
        }),
        Err(error) => {
            // SAFETY: no code of the module has run.
            unsafe { module.free_memory() };
            Err(error)
        }
    }
}

fn define_all(
    module: &mut JITModule,
    program: &Program,
    helpers: &[Helper],
) -> Result<Vec<EntryFn>, Error> {
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
    for (index, function) in program.functions.iter().enumerate() {
        context.func.signature = signature_of(function, call_conv);
        let builder = FunctionBuilder::new(&mut context.func, &mut builder_context);
        let mut generator = Gen::new(program, function, builder, module, &ids, &helper_ids);
        generator.body()?;
        generator.b.finalize(target);
        module
            .define_function(ids[index], &mut context)
            .map_err(|error| format!("function {}: {error:?}", function.name))?;
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
    Ok(entries)
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
        Ty::Null | Ty::Object(_) | Ty::Any | Ty::Array(_) => Some(types::I64),
    }
}

fn signature_of(function: &Function, call_conv: cranelift_codegen::isa::CallConv) -> Signature {
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
        if !matches!(ty, Ty::Num | Ty::Bool) {
            return fail("a global is a number or a boolean");
        }
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
        (Ty::Null, Ty::Null | Ty::Object(_) | Ty::Any | Ty::Array(_))
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
}

type Typed = (Option<Value>, Ty);

impl<'a, 'm> Gen<'a, 'm> {
    fn new(
        program: &'a Program,
        function: &'a Function,
        b: FunctionBuilder<'m>,
        module: &'m mut JITModule,
        ids: &'a [ModuleFuncId],
        helper_ids: &'a [ModuleFuncId],
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
        }
    }

    fn body(&mut self) -> Result<(), Error> {
        let entry = self.b.create_block();
        self.b.append_block_params_for_function_params(entry);
        self.b.switch_to_block(entry);
        let params: Vec<Value> = self.b.block_params(entry).to_vec();
        self.frame = params[0];
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

    /// Spends one unit of fuel, and calls the tick when it is gone.
    fn fuel(&mut self) {
        let flags = MemFlagsData::trusted();
        let fuel = self
            .b
            .ins()
            .load(types::I64, flags, self.frame, frame::FUEL);
        let left = self.b.ins().iadd_imm_s(fuel, -1);
        self.b.ins().store(flags, left, self.frame, frame::FUEL);
        let empty = self.b.ins().icmp_imm_s(IntCC::SignedLessThan, left, 0);
        let tick = self.b.create_block();
        let next = self.b.create_block();
        self.b.set_cold_block(tick);
        self.b.ins().brif(empty, tick, &[], next, &[]);
        self.b.switch_to_block(tick);
        let frame = self.frame;
        self.call_helper(TICK, &[frame]);
        self.b.ins().jump(next, &[]);
        self.b.switch_to_block(next);
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
            Stmt::If(test, then, otherwise) => {
                let condition = self.boolean(test)?;
                let then_block = self.b.create_block();
                let else_block = self.b.create_block();
                let merge = self.b.create_block();
                self.b
                    .ins()
                    .brif(condition, then_block, &[], else_block, &[]);
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
            }
            Stmt::Loop {
                cond,
                body,
                update,
                test_after,
            } => {
                let header = self.b.create_block();
                let body_block = self.b.create_block();
                let update_block = self.b.create_block();
                let exit = self.b.create_block();
                self.b
                    .ins()
                    .jump(if *test_after { body_block } else { header }, &[]);
                self.b.switch_to_block(header);
                self.fuel();
                match cond {
                    Some(cond) => {
                        let condition = self.boolean(cond)?;
                        self.b.ins().brif(condition, body_block, &[], exit, &[]);
                    }
                    None => {
                        self.b.ins().jump(body_block, &[]);
                    }
                }
                self.b.switch_to_block(body_block);
                self.loops.push((update_block, exit));
                self.stmts(body)?;
                if !self.is_filled() {
                    self.b.ins().jump(update_block, &[]);
                }
                self.b.switch_to_block(update_block);
                self.stmts(update)?;
                self.loops.pop();
                if !self.is_filled() {
                    self.b.ins().jump(header, &[]);
                }
                self.b.switch_to_block(exit);
            }
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
            Stmt::Return(value) => {
                let result = self.function.result.clone();
                match value {
                    Some(value) => {
                        let (value, ty) = self.expr(value)?;
                        self.expect(&ty, &result)?;
                        match value {
                            Some(value) => self.b.ins().return_(&[value]),
                            None => self.b.ins().return_(&[]),
                        };
                    }
                    None if result == Ty::Void => {
                        self.b.ins().return_(&[]);
                    }
                    None => self.bail(Bail::Undefined),
                }
            }
            Stmt::Bail(reason) => self.bail(*reason),
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
            Expr::Num(value) => (Some(self.b.ins().f64const(*value)), Ty::Num),
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
                let (object, object_ty) = self.reference(object)?;
                let (at, ty) = self.field_slot(&object_ty, *class, *index)?;
                self.check_object(object);
                let repr = repr(&ty).ok_or("a field without a value")?;
                (Some(self.b.ins().load(repr, flags, object, at)), ty)
            }
            Expr::SetField(object, class, index, value) => {
                let (object, object_ty) = self.reference(object)?;
                let (at, ty) = self.field_slot(&object_ty, *class, *index)?;
                let (value, value_ty) = self.value(value)?;
                self.expect(&value_ty, &ty)?;
                self.check_object(object);
                self.b.ins().store(flags, value, object, at);
                (Some(value), ty)
            }
            Expr::Length(array) => {
                let (array, _) = self.array(array)?;
                let length = self.b.ins().load(types::I64, flags, array, array::LENGTH);
                (
                    Some(self.b.ins().fcvt_from_uint(types::F64, length)),
                    Ty::Num,
                )
            }
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
        let flags = MemFlagsData::trusted();
        let globals = self
            .b
            .ins()
            .load(types::I64, flags, self.frame, frame::GLOBALS);
        let at = i32::try_from(8 * u64::from(index)).map_err(|e| e.to_string())?;
        let repr = repr(&ty).ok_or("a global without a value")?;
        Ok((Some(self.b.ins().load(repr, flags, globals, at)), ty))
    }

    fn conditional(
        &mut self,
        ty: &Ty,
        test: &Expr,
        then: &Expr,
        otherwise: &Expr,
    ) -> Result<Typed, Error> {
        let condition = self.boolean(test)?;
        let repr = repr(ty).ok_or("a conditional without a value")?;
        let then_block = self.b.create_block();
        let else_block = self.b.create_block();
        let merge = self.b.create_block();
        let result = self.b.append_block_param(merge, repr);
        self.b
            .ins()
            .brif(condition, then_block, &[], else_block, &[]);
        for (block, branch) in [(then_block, then), (else_block, otherwise)] {
            self.b.switch_to_block(block);
            let (value, value_ty) = self.value(branch)?;
            self.expect(&value_ty, ty)?;
            self.b.ins().jump(merge, &[BlockArg::Value(value)]);
        }
        self.b.switch_to_block(merge);
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
                (
                    Some(self.b.ins().fcvt_from_sint(types::F64, flipped)),
                    Ty::Num,
                )
            }
            Unary::Truthy => {
                let (value, ty) = self.value(operand)?;
                let truth = match ty {
                    Ty::Num => {
                        let zero = self.b.ins().f64const(0.0);
                        self.b.ins().fcmp(FloatCC::OrderedNotEqual, value, zero)
                    }
                    Ty::Bool => value,
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
        let magnitude = self.b.ins().fabs(value);
        let bound = self.b.ins().f64const(9.0e18);
        let small = self.b.ins().fcmp(FloatCC::LessThan, magnitude, bound);
        let fast = self.b.create_block();
        let slow = self.b.create_block();
        let merge = self.b.create_block();
        let result = self.b.append_block_param(merge, types::I32);
        self.b.set_cold_block(slow);
        self.b.ins().brif(small, fast, &[], slow, &[]);
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
        result
    }

    fn binary(&mut self, op: Binary, left: &Expr, right: &Expr) -> Result<Typed, Error> {
        if matches!(op, Binary::Eq | Binary::Ne) {
            return self.equality(op == Binary::Eq, left, right);
        }
        let a = self.number(left)?;
        let b = self.number(right)?;
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
        if unsigned {
            self.b.ins().fcvt_from_uint(types::F64, result)
        } else {
            self.b.ins().fcvt_from_sint(types::F64, result)
        }
    }

    /// `===` and `!==`: of numbers by value, of booleans and references by identity.
    /// Operands of different kinds are never equal.
    fn equality(&mut self, equal: bool, left: &Expr, right: &Expr) -> Result<Typed, Error> {
        let (a, a_ty) = self.value(left)?;
        let (b, b_ty) = self.value(right)?;
        let result = match (&a_ty, &b_ty) {
            (Ty::Num, Ty::Num) => {
                let cc = if equal {
                    FloatCC::Equal
                } else {
                    FloatCC::NotEqual
                };
                self.b.ins().fcmp(cc, a, b)
            }
            (Ty::Bool, Ty::Bool) => {
                let cc = if equal { IntCC::Equal } else { IntCC::NotEqual };
                self.b.ins().icmp(cc, a, b)
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
        let second = self.boolean(right)?;
        self.b.ins().jump(merge, &[BlockArg::Value(second)]);
        self.b.switch_to_block(merge);
        Ok((Some(result), Ty::Bool))
    }

    fn array(&mut self, expr: &Expr) -> Result<(Value, Ty), Error> {
        let (array, ty) = self.value(expr)?;
        let Ty::Array(element) = ty else {
            return fail(format!("{}: an array is expected", self.function.name));
        };
        self.check_object(array);
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
        self.check_object(array_value);
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
        let frame = self.frame;
        self.call_helper(GROW, &[frame, array]);
        self.b.ins().jump(store, &[]);
        self.b.switch_to_block(store);
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
        self.b.switch_to_block(body);
        let offset = self.b.ins().ishl_imm_u(index, 3);
        let address = self.b.ins().iadd(data, offset);
        self.b.ins().store(flags, value, address, 0);
        let next = self.b.ins().iadd_imm_s(index, 1);
        self.b.ins().jump(header, &[BlockArg::Value(next)]);
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
        let mut values = vec![self.frame];
        values.extend(self.arguments(function, args, 0)?);
        let callee = self.function_ref(id)?;
        let call = self.b.ins().call(callee, &values);
        let result = self.b.inst_results(call).first().copied();
        Ok((result, function.result.clone()))
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
        let callee = self.function_ref(constructor)?;
        let mut call_args = vec![self.frame, object];
        call_args.extend(values);
        self.b.ins().call(callee, &call_args);
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
        // Each class that the receiver may have, and the function its method calls.
        let mut targets: Vec<(ClassId, FuncId)> = Vec::new();
        for (index, class) in program.classes.iter().enumerate() {
            let id = u32::try_from(index).map_err(|e| e.to_string())?;
            if bound.is_some_and(|bound| !is_subclass(program, id, bound)) {
                continue;
            }
            if let Some(found) = class.methods.iter().find(|m| m.name == method) {
                let function = function_at(program, found.function)?;
                let this_ok = function
                    .locals
                    .first()
                    .is_some_and(|ty| function.params > 0 && fits(program, &Ty::Object(id), ty));
                let result_ok = if *result == Ty::Void {
                    function.result == Ty::Void
                } else {
                    fits(program, &function.result, result)
                };
                if !this_ok || !result_ok {
                    return fail(format!("{method} of {} has another signature", class.name));
                }
                targets.push((id, found.function));
            }
        }
        let mut values = Vec::with_capacity(rest.len());
        let mut value_tys = Vec::with_capacity(rest.len());
        for arg in rest {
            let (value, ty) = self.value(arg)?;
            values.push(value);
            value_tys.push(ty);
        }
        for &(_, function_id) in &targets {
            let function = function_at(program, function_id)?;
            let params = &function.locals[1..function.params as usize];
            if params.len() != value_tys.len()
                || !params
                    .iter()
                    .zip(&value_tys)
                    .all(|(to, from)| fits(program, from, to))
            {
                return fail(format!("{method}: the arguments do not fit"));
            }
        }
        self.check_object(receiver);
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
            let callee = self.function_ref(function_id)?;
            let mut call_args = vec![self.frame, receiver];
            call_args.extend(&values);
            let call = self.b.ins().call(callee, &call_args);
            match (merged, self.b.inst_results(call).first().copied()) {
                (Some(_), Some(value)) => {
                    self.b.ins().jump(merge, &[BlockArg::Value(value)]);
                }
                _ => {
                    self.b.ins().jump(merge, &[]);
                }
            }
        }
        self.b.switch_to_block(merge);
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
