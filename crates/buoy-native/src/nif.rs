//! The part of `erl_nif.h` that the native tier uses, written out by hand as the speed
//! spike did, so the crate needs no binding generator and no Erlang headers to build. The
//! library declares NIF version 2.16 (OTP 24), and calls only functions of that version.
//!
//! Every function here wraps one call of the C API. The safe wrappers take an [`Env`],
//! which is valid for the duration of the NIF call that received it.

#![allow(unsafe_code)]

use std::ffi::{CStr, c_char, c_int, c_long, c_uint, c_void};
use std::ptr;

/// An Erlang term, `ERL_NIF_TERM`.
pub type Term = usize;

#[repr(C)]
pub struct RawEnv {
    _private: [u8; 0],
}

#[repr(C)]
struct RawResourceType {
    _private: [u8; 0],
}

pub type NifFn = unsafe extern "C" fn(*mut RawEnv, c_int, *const Term) -> Term;
type Destructor = unsafe extern "C" fn(*mut RawEnv, *mut c_void);

#[repr(C)]
pub struct Func {
    pub name: *const c_char,
    pub arity: c_uint,
    pub fptr: NifFn,
    pub flags: c_uint,
}

#[repr(C)]
pub struct Entry {
    pub major: c_int,
    pub minor: c_int,
    pub name: *const c_char,
    pub num_of_funcs: c_int,
    pub funcs: *const Func,
    pub load: Option<unsafe extern "C" fn(*mut RawEnv, *mut *mut c_void, Term) -> c_int>,
    pub reload: *const c_void,
    pub upgrade: *const c_void,
    pub unload: *const c_void,
    pub vm_variant: *const c_char,
    pub options: c_uint,
    pub sizeof_resource_type_init: usize,
    pub min_erts: *const c_char,
}

#[repr(C)]
struct RawBinary {
    size: usize,
    data: *mut u8,
    ref_bin: *mut c_void,
    spare: [*mut c_void; 2],
}

const ERL_NIF_RT_CREATE: c_int = 1;

unsafe extern "C" {
    fn enif_make_atom(env: *mut RawEnv, name: *const c_char) -> Term;
    fn enif_make_long(env: *mut RawEnv, value: c_long) -> Term;
    fn enif_make_double(env: *mut RawEnv, value: f64) -> Term;
    fn enif_make_badarg(env: *mut RawEnv) -> Term;
    fn enif_make_new_binary(env: *mut RawEnv, size: usize, term: *mut Term) -> *mut u8;
    fn enif_make_tuple_from_array(env: *mut RawEnv, array: *const Term, count: c_uint) -> Term;
    fn enif_get_long(env: *mut RawEnv, term: Term, value: *mut c_long) -> c_int;
    fn enif_get_double(env: *mut RawEnv, term: Term, value: *mut f64) -> c_int;
    fn enif_get_list_cell(env: *mut RawEnv, term: Term, head: *mut Term, tail: *mut Term) -> c_int;
    fn enif_is_identical(left: Term, right: Term) -> c_int;
    fn enif_is_empty_list(env: *mut RawEnv, term: Term) -> c_int;
    fn enif_inspect_binary(env: *mut RawEnv, term: Term, binary: *mut RawBinary) -> c_int;
    fn enif_consume_timeslice(env: *mut RawEnv, percent: c_int) -> c_int;
    fn enif_schedule_nif(
        env: *mut RawEnv,
        name: *const c_char,
        flags: c_int,
        fptr: NifFn,
        argc: c_int,
        argv: *const Term,
    ) -> Term;
    fn enif_open_resource_type(
        env: *mut RawEnv,
        module: *const c_char,
        name: *const c_char,
        destructor: Option<Destructor>,
        flags: c_int,
        tried: *mut c_int,
    ) -> *mut RawResourceType;
    fn enif_alloc_resource(kind: *mut RawResourceType, size: usize) -> *mut c_void;
    fn enif_release_resource(object: *mut c_void);
    fn enif_make_resource(env: *mut RawEnv, object: *mut c_void) -> Term;
    fn enif_get_resource(
        env: *mut RawEnv,
        term: Term,
        kind: *mut RawResourceType,
        object: *mut *mut c_void,
    ) -> c_int;
}

/// The environment of one NIF call.
#[derive(Debug, Clone, Copy)]
pub struct Env(*mut RawEnv);

impl Env {
    /// # Safety
    ///
    /// `raw` must be the environment that the VM passed to the running NIF.
    pub unsafe fn new(raw: *mut RawEnv) -> Self {
        Self(raw)
    }

    pub fn atom(self, name: &CStr) -> Term {
        // SAFETY: the env is valid during the call, and the name is a C string.
        unsafe { enif_make_atom(self.0, name.as_ptr()) }
    }

    pub fn long(self, value: i64) -> Term {
        // SAFETY: the env is valid during the call.
        unsafe { enif_make_long(self.0, value) }
    }

    pub fn double(self, value: f64) -> Term {
        // SAFETY: the env is valid during the call; the caller passes a finite double.
        unsafe { enif_make_double(self.0, value) }
    }

    pub fn badarg(self) -> Term {
        // SAFETY: the env is valid during the call.
        unsafe { enif_make_badarg(self.0) }
    }

    /// A new binary with a copy of `bytes`.
    pub fn binary_from(self, bytes: &[u8]) -> Term {
        let mut term: Term = 0;
        // SAFETY: the VM returns `bytes.len()` writable bytes, which the copy fills.
        unsafe {
            let target = enif_make_new_binary(self.0, bytes.len(), &raw mut term);
            if !target.is_null() {
                ptr::copy_nonoverlapping(bytes.as_ptr(), target, bytes.len());
            }
        }
        term
    }

    pub fn tuple(self, items: &[Term]) -> Term {
        let count = c_uint::try_from(items.len()).unwrap_or(0);
        // SAFETY: the env is valid, and `items` holds `count` terms of this env.
        unsafe { enif_make_tuple_from_array(self.0, items.as_ptr(), count) }
    }

    pub fn get_long(self, term: Term) -> Option<i64> {
        let mut value: c_long = 0;
        // SAFETY: the env and the term are valid during the call.
        (unsafe { enif_get_long(self.0, term, &raw mut value) } != 0).then_some(value)
    }

    pub fn get_double(self, term: Term) -> Option<f64> {
        let mut value = 0.0;
        // SAFETY: the env and the term are valid during the call.
        (unsafe { enif_get_double(self.0, term, &raw mut value) } != 0).then_some(value)
    }

    /// The items of a proper list.
    pub fn list(self, mut term: Term) -> Option<Vec<Term>> {
        let mut items = Vec::new();
        loop {
            let (mut head, mut tail) = (0, 0);
            // SAFETY: the env and the term are valid during the call.
            if unsafe { enif_get_list_cell(self.0, term, &raw mut head, &raw mut tail) } == 0 {
                // SAFETY: the env and the term are valid during the call.
                return (unsafe { enif_is_empty_list(self.0, term) } != 0).then_some(items);
            }
            items.push(head);
            term = tail;
        }
    }

    /// The bytes of a binary, which live as long as the term.
    pub fn binary<'a>(self, term: Term) -> Option<&'a [u8]> {
        let mut binary = RawBinary {
            size: 0,
            data: ptr::null_mut(),
            ref_bin: ptr::null_mut(),
            spare: [ptr::null_mut(); 2],
        };
        // SAFETY: the env and the term are valid; on success `data` holds `size` bytes
        // that live as long as the term.
        unsafe {
            (enif_inspect_binary(self.0, term, &raw mut binary) != 0).then_some(())?;
            if binary.size == 0 {
                return Some(&[]);
            }
            Some(std::slice::from_raw_parts(binary.data, binary.size))
        }
    }

    /// Reports the share of a timeslice that the call used, and whether the slice is
    /// spent.
    pub fn consume_timeslice(self, percent: i32) -> bool {
        // SAFETY: the env is valid during the call.
        unsafe { enif_consume_timeslice(self.0, percent.clamp(1, 100)) != 0 }
    }

    /// Returns to the scheduler, which calls `function` with `args` later.
    pub fn schedule(self, name: &CStr, function: NifFn, args: &[Term]) -> Term {
        let count = c_int::try_from(args.len()).unwrap_or(0);
        // SAFETY: the env is valid, the name is static, and `args` are terms of this env.
        unsafe { enif_schedule_nif(self.0, name.as_ptr(), 0, function, count, args.as_ptr()) }
    }
}

pub fn is_identical(left: Term, right: Term) -> bool {
    // SAFETY: comparing two terms reads no memory that the terms do not own.
    unsafe { enif_is_identical(left, right) != 0 }
}

/// A resource type whose objects hold one Rust value of type `T`. The VM frees an object
/// when no term refers to it, and the destructor drops the value.
#[derive(Debug)]
pub struct ResourceType<T> {
    raw: *mut RawResourceType,
    _value: std::marker::PhantomData<T>,
}

// SAFETY: the VM's resource type handle may be used from any scheduler thread.
unsafe impl<T> Send for ResourceType<T> {}
// SAFETY: as above; the handle is never written after `open`.
unsafe impl<T> Sync for ResourceType<T> {}

impl<T: Send + Sync> ResourceType<T> {
    /// Opens the resource type `name` in the `load` callback of the library.
    pub fn open(env: Env, name: &CStr) -> Option<Self> {
        let mut tried = 0;
        // SAFETY: called from `load` with its env; the names are static C strings.
        let raw = unsafe {
            enif_open_resource_type(
                env.0,
                ptr::null(),
                name.as_ptr(),
                Some(drop_value::<T>),
                ERL_NIF_RT_CREATE,
                &raw mut tried,
            )
        };
        (!raw.is_null()).then_some(Self {
            raw,
            _value: std::marker::PhantomData,
        })
    }

    /// A new resource term that owns `value`.
    pub fn make(&self, env: Env, value: T) -> Term {
        // SAFETY: the VM returns memory of the size of `T`, aligned for any C type, which
        // `write` fills before the term exists. The term keeps the object alive, so the
        // reference of this function can go.
        unsafe {
            let object = enif_alloc_resource(self.raw, size_of::<T>()).cast::<T>();
            object.write(value);
            let term = enif_make_resource(env.0, object.cast());
            enif_release_resource(object.cast());
            term
        }
    }

    /// The value of a resource term of this type.
    pub fn get<'a>(&self, env: Env, term: Term) -> Option<&'a T> {
        let mut object: *mut c_void = ptr::null_mut();
        // SAFETY: on success the object is a `T` that `make` wrote, and the term keeps it
        // alive for the duration of the call.
        unsafe {
            (enif_get_resource(env.0, term, self.raw, &raw mut object) != 0).then_some(())?;
            object.cast::<T>().as_ref()
        }
    }
}

unsafe extern "C" fn drop_value<T>(_env: *mut RawEnv, object: *mut c_void) {
    // SAFETY: the VM calls the destructor once, when no term refers to the object, which
    // holds a `T` that `make` wrote.
    unsafe { ptr::drop_in_place(object.cast::<T>()) }
}
