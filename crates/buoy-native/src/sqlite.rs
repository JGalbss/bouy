//! The SQLite of `internalBinding('sqlite')`, which ports Node's `src/node_sqlite.cc`.
//!
//! Each `DatabaseSync` owns one connection thread. The realm sends a command and waits in a
//! `receive` for its reply, so a long query or a busy timeout holds no scheduler and BEAM
//! keeps preempting the realm. A user-defined function, an aggregate, the authorizer, and the
//! callbacks of `applyChangeset` run JavaScript: the thread sends the realm a call and waits
//! for its answer, and meanwhile runs each command that the JavaScript sends, because SQLite
//! lets a function use its own connection. SQLite allocates through `enif_alloc`, so
//! `BUOY_MAX_MEMORY` counts its pages and caches.
//!
//! The values of a row and of a call are `null`, an integer, a float or one of the atoms
//! `'NaN'`, `'Infinity'`, and `'-Infinity'`, a binary of UTF-8 text, or `{blob, Binary}`.

// rustler decodes each argument of a NIF by value.
#![allow(clippy::needless_pass_by_value)]

use std::any::Any;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::ffi::c_int;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

use libsqlite3_sys as ffi;
use rustler::env::{OwnedEnv, SavedTerm};
use rustler::types::tuple::get_tuple;
use rustler::{Atom, Binary, Encoder, Env, Error, LocalPid, NewBinary, NifResult, ResourceArc, Term};

mod atoms {
    rustler::atoms! {
        ok,
        null,
        blob,
        empty,
        buoy_sqlite,
        buoy_sqlite_call,
        nan = "NaN",
        infinity = "Infinity",
        negative_infinity = "-Infinity",
        // Commands.
        open,
        close,
        exec,
        prepare,
        function,
        aggregate,
        location,
        is_transaction,
        limit,
        session,
        changeset,
        delete_session,
        apply_changeset,
        db_config,
        load_extension,
        authorizer,
        backup_init,
        backup_step,
        backup_finish,
        run,
        get,
        all,
        iterate,
        next,
        reset,
        columns,
        sql,
        expanded_sql,
        params,
        // Replies.
        row,
        rows,
        none,
        done,
        step,
        sqlite_error,
        sqlite_code,
        sqlite_message,
        load_error,
        failed,
        finalized,
        not_open,
        busy,
        gone,
        // Calls and answers.
        value,
        error,
        ignore,
        inverse,
        final_ = "final",
        authorize,
        filter,
        conflict,
    }
}

/// A value of SQLite.
#[derive(Debug, Clone)]
pub enum Value {
    Null,
    Int(i64),
    Float(f64),
    Text(Vec<u8>),
    Blob(Vec<u8>),
}

/// The FFI of SQLite behind safe types: a connection, a statement, a session, and a backup
/// each own their handle and release it when dropped.
#[allow(unsafe_code)]
mod raw {
    use std::alloc::{self, Layout};
    use std::ffi::{CStr, c_char, c_int, c_void};
    use std::ptr::{self, NonNull};
    use std::sync::Once;
    use std::sync::atomic::{AtomicU64, Ordering};

    use libsqlite3_sys as ffi;

    use super::Value;

    /// The session extension, which the bundled bindings leave out (`.cargo/config.toml`
    /// compiles it in).
    #[allow(non_camel_case_types)]
    #[repr(C)]
    struct sqlite3_session {
        _private: [u8; 0],
    }

    #[allow(non_camel_case_types)]
    #[repr(C)]
    struct sqlite3_changeset_iter {
        _private: [u8; 0],
    }

    type FilterFn = unsafe extern "C" fn(*mut c_void, *const c_char) -> c_int;
    type ConflictFn = unsafe extern "C" fn(*mut c_void, c_int, *mut sqlite3_changeset_iter) -> c_int;

    unsafe extern "C" {
        // The bundled bindings leave out sqlite3_close_v2, too.
        fn sqlite3_close_v2(db: *mut ffi::sqlite3) -> c_int;
        fn sqlite3session_create(
            db: *mut ffi::sqlite3,
            name: *const c_char,
            session: *mut *mut sqlite3_session,
        ) -> c_int;
        fn sqlite3session_delete(session: *mut sqlite3_session);
        fn sqlite3session_attach(session: *mut sqlite3_session, table: *const c_char) -> c_int;
        fn sqlite3session_changeset(
            session: *mut sqlite3_session,
            size: *mut c_int,
            changeset: *mut *mut c_void,
        ) -> c_int;
        fn sqlite3session_patchset(
            session: *mut sqlite3_session,
            size: *mut c_int,
            patchset: *mut *mut c_void,
        ) -> c_int;
        fn sqlite3changeset_apply(
            db: *mut ffi::sqlite3,
            size: c_int,
            changeset: *mut c_void,
            filter: Option<FilterFn>,
            conflict: Option<ConflictFn>,
            context: *mut c_void,
        ) -> c_int;
    }

    pub const CHANGESET_ABORT: c_int = 2;

    /// `SQLITE_UTF8`, as the `unsigned char` of the 64-bit binders.
    const UTF8: u8 = 1;

    /// An error of a connection: the extended code, the message, and the text of the code.
    #[derive(Debug)]
    pub struct Failure {
        pub code: c_int,
        pub message: Vec<u8>,
        pub errstr: Vec<u8>,
    }

    /// The bytes of a C string, or `None` for a null pointer.
    ///
    /// # Safety
    /// `text` is null or points to a NUL-terminated string.
    unsafe fn bytes(text: *const c_char) -> Option<Vec<u8>> {
        if text.is_null() {
            None
        } else {
            Some(unsafe { CStr::from_ptr(text) }.to_bytes().to_vec())
        }
    }

    /// `text` up to its first NUL, NUL-terminated, as a C API that takes a `const char*`
    /// reads it.
    fn c_string(text: &[u8]) -> Vec<u8> {
        let end = text.iter().position(|&byte| byte == 0).unwrap_or(text.len());
        let mut string = Vec::with_capacity(end + 1);
        string.extend_from_slice(&text[..end]);
        string.push(0);
        string
    }

    /// `sqlite3_errstr`: the English text of a result code.
    pub fn errstr(code: c_int) -> Vec<u8> {
        unsafe { bytes(ffi::sqlite3_errstr(code)) }.unwrap_or_default()
    }

    /// The key of the next group of an aggregate.
    static AGGREGATE_KEYS: AtomicU64 = AtomicU64::new(1);

    // SQLite's allocations go through the global allocator, which is enif_alloc, with the
    // size in a header so that xSize and xFree know it. Each block is aligned to the
    // header, so the header can be read as a usize.
    const HEADER: usize = 8;

    fn layout(size: usize) -> Option<Layout> {
        Layout::from_size_align(size.checked_add(HEADER)?, HEADER).ok()
    }

    #[allow(clippy::cast_ptr_alignment)]
    unsafe extern "C" fn memory_malloc(size: c_int) -> *mut c_void {
        let Some(layout) = usize::try_from(size).ok().and_then(layout) else {
            return ptr::null_mut();
        };
        let base = unsafe { alloc::alloc(layout) };
        if base.is_null() {
            return ptr::null_mut();
        }
        unsafe {
            base.cast::<usize>().write(layout.size() - HEADER);
            base.add(HEADER).cast()
        }
    }

    #[allow(clippy::cast_ptr_alignment)]
    unsafe extern "C" fn memory_free(pointer: *mut c_void) {
        if pointer.is_null() {
            return;
        }
        let base = unsafe { pointer.cast::<u8>().sub(HEADER) };
        let size = unsafe { base.cast::<usize>().read() };
        if let Some(layout) = layout(size) {
            unsafe { alloc::dealloc(base, layout) };
        }
    }

    #[allow(clippy::cast_ptr_alignment)]
    unsafe extern "C" fn memory_realloc(pointer: *mut c_void, size: c_int) -> *mut c_void {
        if pointer.is_null() {
            return unsafe { memory_malloc(size) };
        }
        let Ok(new_size) = usize::try_from(size) else {
            return ptr::null_mut();
        };
        let base = unsafe { pointer.cast::<u8>().sub(HEADER) };
        let old_size = unsafe { base.cast::<usize>().read() };
        let (Some(old), Some(_)) = (layout(old_size), layout(new_size)) else {
            return ptr::null_mut();
        };
        let grown = unsafe { alloc::realloc(base, old, new_size + HEADER) };
        if grown.is_null() {
            return ptr::null_mut();
        }
        unsafe {
            grown.cast::<usize>().write(new_size);
            grown.add(HEADER).cast()
        }
    }

    #[allow(clippy::cast_ptr_alignment)]
    unsafe extern "C" fn memory_size(pointer: *mut c_void) -> c_int {
        if pointer.is_null() {
            return 0;
        }
        let size = unsafe { pointer.cast::<u8>().sub(HEADER).cast::<usize>().read() };
        c_int::try_from(size).unwrap_or(c_int::MAX)
    }

    unsafe extern "C" fn memory_roundup(size: c_int) -> c_int {
        size.saturating_add(7) & !7
    }

    unsafe extern "C" fn memory_init(_: *mut c_void) -> c_int {
        ffi::SQLITE_OK
    }

    unsafe extern "C" fn memory_shutdown(_: *mut c_void) {}

    /// Routes SQLite's allocations through the allocator of the VM. It runs once, before
    /// the first connection initializes SQLite.
    pub fn configure() {
        static CONFIGURE: Once = Once::new();
        CONFIGURE.call_once(|| {
            let methods = ffi::sqlite3_mem_methods {
                xMalloc: Some(memory_malloc),
                xFree: Some(memory_free),
                xRealloc: Some(memory_realloc),
                xSize: Some(memory_size),
                xRoundup: Some(memory_roundup),
                xInit: Some(memory_init),
                xShutdown: Some(memory_shutdown),
                pAppData: ptr::null_mut(),
            };
            // SQLite copies the methods before sqlite3_config returns.
            unsafe {
                ffi::sqlite3_config(ffi::SQLITE_CONFIG_MALLOC, &raw const methods);
            }
        });
    }

    /// The result of a function call: a value, or an error with its message. An empty
    /// message is Node's `sqlite3_result_error(ctx, "", 0)` for a pending exception.
    pub enum Outcome {
        Value(Value),
        Error(Vec<u8>),
    }

    pub type FunctionFn = Box<dyn Fn(Vec<Value>) -> Outcome>;

    /// One callback of an aggregate, with the key of its group.
    pub enum AggregateCall {
        Step(u64, Vec<Value>),
        Inverse(u64, Vec<Value>),
        Value(u64),
        Final(u64),
    }

    pub type AggregateFn = Box<dyn Fn(AggregateCall) -> Option<Outcome>>;
    pub type AuthorizerFn = Box<dyn Fn(c_int, [Option<Vec<u8>>; 4]) -> c_int>;

    /// The callbacks of `sqlite3changeset_apply`.
    pub struct ApplyCallbacks<'a> {
        pub filter: Option<&'a dyn Fn(Vec<u8>) -> bool>,
        pub conflict: Option<&'a dyn Fn(c_int) -> c_int>,
    }

    /// Copies the arguments of a call.
    ///
    /// # Safety
    /// `values` holds `count` values of the current call.
    unsafe fn arguments(count: c_int, values: *mut *mut ffi::sqlite3_value) -> Vec<Value> {
        let count = usize::try_from(count).unwrap_or(0);
        (0..count)
            .map(|index| unsafe { value_of(*values.add(index)) })
            .collect()
    }

    /// # Safety
    /// `value` is a protected value of the current call.
    unsafe fn value_of(value: *mut ffi::sqlite3_value) -> Value {
        unsafe {
            match ffi::sqlite3_value_type(value) {
                ffi::SQLITE_INTEGER => Value::Int(ffi::sqlite3_value_int64(value)),
                ffi::SQLITE_FLOAT => Value::Float(ffi::sqlite3_value_double(value)),
                ffi::SQLITE_TEXT => Value::Text(
                    bytes(ffi::sqlite3_value_text(value).cast()).unwrap_or_default(),
                ),
                ffi::SQLITE_BLOB => {
                    let size = usize::try_from(ffi::sqlite3_value_bytes(value)).unwrap_or(0);
                    let data = ffi::sqlite3_value_blob(value).cast::<u8>();
                    Value::Blob(if data.is_null() || size == 0 {
                        Vec::new()
                    } else {
                        std::slice::from_raw_parts(data, size).to_vec()
                    })
                }
                _ => Value::Null,
            }
        }
    }

    /// Node's `JSValueToSQLiteResult`.
    ///
    /// # Safety
    /// `context` is the context of the current call.
    unsafe fn set_result(context: *mut ffi::sqlite3_context, outcome: Outcome) {
        unsafe {
            match outcome {
                Outcome::Value(Value::Null) => ffi::sqlite3_result_null(context),
                Outcome::Value(Value::Int(value)) => ffi::sqlite3_result_int64(context, value),
                Outcome::Value(Value::Float(value)) => ffi::sqlite3_result_double(context, value),
                Outcome::Value(Value::Text(text)) => ffi::sqlite3_result_text64(
                    context,
                    text.as_ptr().cast(),
                    text.len() as u64,
                    ffi::SQLITE_TRANSIENT(),
                    UTF8,
                ),
                Outcome::Value(Value::Blob(data)) => ffi::sqlite3_result_blob64(
                    context,
                    data.as_ptr().cast(),
                    data.len() as u64,
                    ffi::SQLITE_TRANSIENT(),
                ),
                Outcome::Error(message) => ffi::sqlite3_result_error(
                    context,
                    message.as_ptr().cast(),
                    c_int::try_from(message.len()).unwrap_or(c_int::MAX),
                ),
            }
        }
    }

    unsafe extern "C" fn destroy<T>(data: *mut c_void) {
        drop(unsafe { Box::from_raw(data.cast::<T>()) });
    }

    unsafe extern "C" fn call_function(
        context: *mut ffi::sqlite3_context,
        count: c_int,
        values: *mut *mut ffi::sqlite3_value,
    ) {
        let function = unsafe { &*ffi::sqlite3_user_data(context).cast::<FunctionFn>() };
        let outcome = function(unsafe { arguments(count, values) });
        unsafe { set_result(context, outcome) };
    }

    /// The key of the group of the current call: 0 in a fresh aggregate context, which
    /// then gets the next key.
    ///
    /// # Safety
    /// `context` is the context of the current call of an aggregate.
    unsafe fn group(context: *mut ffi::sqlite3_context) -> Option<u64> {
        let slot = unsafe { ffi::sqlite3_aggregate_context(context, 8) }.cast::<u64>();
        if slot.is_null() {
            unsafe { ffi::sqlite3_result_error_nomem(context) };
            return None;
        }
        unsafe {
            if slot.read() == 0 {
                slot.write(AGGREGATE_KEYS.fetch_add(1, Ordering::Relaxed));
            }
            Some(slot.read())
        }
    }

    unsafe fn aggregate_of<'a>(context: *mut ffi::sqlite3_context) -> &'a AggregateFn {
        unsafe { &*ffi::sqlite3_user_data(context).cast::<AggregateFn>() }
    }

    unsafe extern "C" fn aggregate_step(
        context: *mut ffi::sqlite3_context,
        count: c_int,
        values: *mut *mut ffi::sqlite3_value,
    ) {
        let Some(key) = (unsafe { group(context) }) else { return };
        let call = AggregateCall::Step(key, unsafe { arguments(count, values) });
        if let Some(outcome) = unsafe { aggregate_of(context) }(call) {
            unsafe { set_result(context, outcome) };
        }
    }

    unsafe extern "C" fn aggregate_inverse(
        context: *mut ffi::sqlite3_context,
        count: c_int,
        values: *mut *mut ffi::sqlite3_value,
    ) {
        let Some(key) = (unsafe { group(context) }) else { return };
        let call = AggregateCall::Inverse(key, unsafe { arguments(count, values) });
        if let Some(outcome) = unsafe { aggregate_of(context) }(call) {
            unsafe { set_result(context, outcome) };
        }
    }

    unsafe extern "C" fn aggregate_value(context: *mut ffi::sqlite3_context) {
        let Some(key) = (unsafe { group(context) }) else { return };
        if let Some(outcome) = unsafe { aggregate_of(context) }(AggregateCall::Value(key)) {
            unsafe { set_result(context, outcome) };
        }
    }

    unsafe extern "C" fn aggregate_final(context: *mut ffi::sqlite3_context) {
        let Some(key) = (unsafe { group(context) }) else { return };
        if let Some(outcome) = unsafe { aggregate_of(context) }(AggregateCall::Final(key)) {
            unsafe { set_result(context, outcome) };
        }
    }

    unsafe extern "C" fn authorize(
        data: *mut c_void,
        action: c_int,
        first: *const c_char,
        second: *const c_char,
        third: *const c_char,
        fourth: *const c_char,
    ) -> c_int {
        let authorizer = unsafe { &*data.cast::<AuthorizerFn>() };
        let params = unsafe { [bytes(first), bytes(second), bytes(third), bytes(fourth)] };
        authorizer(action, params)
    }

    unsafe extern "C" fn apply_filter(data: *mut c_void, table: *const c_char) -> c_int {
        let callbacks = unsafe { &*data.cast::<ApplyCallbacks<'_>>() };
        match callbacks.filter {
            Some(filter) => c_int::from(filter(unsafe { bytes(table) }.unwrap_or_default())),
            None => 1,
        }
    }

    unsafe extern "C" fn apply_conflict(
        data: *mut c_void,
        kind: c_int,
        _: *mut sqlite3_changeset_iter,
    ) -> c_int {
        let callbacks = unsafe { &*data.cast::<ApplyCallbacks<'_>>() };
        callbacks.conflict.map_or(CHANGESET_ABORT, |conflict| conflict(kind))
    }

    /// A connection. Dropping it closes it with `sqlite3_close_v2`.
    pub struct Db {
        handle: NonNull<ffi::sqlite3>,
        authorizer: std::cell::RefCell<Option<Box<AuthorizerFn>>>,
    }

    impl Db {
        /// `sqlite3_open_v2`: the connection, which SQLite returns even when the open
        /// fails, and the result code.
        pub fn open(location: &[u8], flags: c_int) -> (Option<Db>, c_int) {
            let location = c_string(location);
            let mut handle = ptr::null_mut();
            let code = unsafe {
                ffi::sqlite3_open_v2(location.as_ptr().cast(), &raw mut handle, flags, ptr::null())
            };
            let db = NonNull::new(handle).map(|handle| Db {
                handle,
                authorizer: std::cell::RefCell::new(None),
            });
            (db, code)
        }

        fn as_ptr(&self) -> *mut ffi::sqlite3 {
            self.handle.as_ptr()
        }

        /// The error of the last call on the connection.
        pub fn failure(&self) -> Failure {
            failure_of(self.as_ptr())
        }

        /// `sqlite3_db_config` with an integer and the address of the result.
        pub fn config(&self, op: c_int, value: c_int) -> c_int {
            let mut result: c_int = 0;
            unsafe { ffi::sqlite3_db_config(self.as_ptr(), op, value, &raw mut result) }
        }

        pub fn busy_timeout(&self, milliseconds: c_int) {
            unsafe { ffi::sqlite3_busy_timeout(self.as_ptr(), milliseconds) };
        }

        pub fn limit(&self, id: c_int, value: c_int) -> c_int {
            unsafe { ffi::sqlite3_limit(self.as_ptr(), id, value) }
        }

        pub fn exec(&self, sql: &[u8]) -> c_int {
            let sql = c_string(sql);
            unsafe {
                ffi::sqlite3_exec(
                    self.as_ptr(),
                    sql.as_ptr().cast(),
                    None,
                    ptr::null_mut(),
                    ptr::null_mut(),
                )
            }
        }

        /// `sqlite3_prepare_v2`: a statement, or none for text without one.
        pub fn prepare(&self, sql: &[u8]) -> Result<Option<Stmt>, c_int> {
            let sql = c_string(sql);
            let mut handle = ptr::null_mut();
            let code = unsafe {
                ffi::sqlite3_prepare_v2(
                    self.as_ptr(),
                    sql.as_ptr().cast(),
                    -1,
                    &raw mut handle,
                    ptr::null_mut(),
                )
            };
            let statement = NonNull::new(handle).map(|handle| Stmt { handle });
            if code == ffi::SQLITE_OK {
                Ok(statement)
            } else {
                Err(code)
            }
        }

        pub fn is_autocommit(&self) -> bool {
            unsafe { ffi::sqlite3_get_autocommit(self.as_ptr()) != 0 }
        }

        /// `sqlite3_db_filename`: the file of a database, or none for a memory database.
        pub fn filename(&self, name: &[u8]) -> Option<Vec<u8>> {
            let name = c_string(name);
            unsafe { bytes(ffi::sqlite3_db_filename(self.as_ptr(), name.as_ptr().cast())) }
                .filter(|file| !file.is_empty())
        }

        pub fn create_function(&self, name: &[u8], argc: c_int, flags: c_int, function: FunctionFn) -> c_int {
            let name = c_string(name);
            let data = Box::into_raw(Box::new(function)).cast::<c_void>();
            // SQLite calls the destructor of the data when the call fails, too.
            unsafe {
                ffi::sqlite3_create_function_v2(
                    self.as_ptr(),
                    name.as_ptr().cast(),
                    argc,
                    flags,
                    data,
                    Some(call_function),
                    None,
                    None,
                    Some(destroy::<FunctionFn>),
                )
            }
        }

        pub fn create_aggregate(
            &self,
            name: &[u8],
            argc: c_int,
            flags: c_int,
            window: bool,
            aggregate: AggregateFn,
        ) -> c_int {
            let name = c_string(name);
            let data = Box::into_raw(Box::new(aggregate)).cast::<c_void>();
            unsafe {
                ffi::sqlite3_create_window_function(
                    self.as_ptr(),
                    name.as_ptr().cast(),
                    argc,
                    flags,
                    data,
                    Some(aggregate_step),
                    Some(aggregate_final),
                    if window { Some(aggregate_value) } else { None },
                    if window { Some(aggregate_inverse) } else { None },
                    Some(destroy::<AggregateFn>),
                )
            }
        }

        /// Installs or clears the authorizer, and returns the result code and the
        /// authorizer that it replaced, which the caller must keep until no call of it runs.
        pub fn set_authorizer(&self, authorizer: Option<AuthorizerFn>) -> (c_int, Option<Box<AuthorizerFn>>) {
            let boxed = authorizer.map(Box::new);
            let data = boxed
                .as_ref()
                .map_or(ptr::null_mut(), |boxed| (&raw const **boxed).cast_mut().cast::<c_void>());
            let code = unsafe {
                ffi::sqlite3_set_authorizer(
                    self.as_ptr(),
                    if boxed.is_some() { Some(authorize) } else { None },
                    data,
                )
            };
            let old = self.authorizer.replace(boxed);
            (code, old)
        }

        pub fn create_session(&self, name: &[u8]) -> Result<Session, c_int> {
            let name = c_string(name);
            let mut handle = ptr::null_mut();
            let code =
                unsafe { sqlite3session_create(self.as_ptr(), name.as_ptr().cast(), &raw mut handle) };
            match NonNull::new(handle) {
                Some(handle) if code == ffi::SQLITE_OK => Ok(Session { handle }),
                _ => Err(code),
            }
        }

        pub fn apply_changeset(&self, changeset: &[u8], callbacks: &ApplyCallbacks<'_>) -> c_int {
            let Ok(size) = c_int::try_from(changeset.len()) else {
                return ffi::SQLITE_TOOBIG;
            };
            // SQLite only reads the changeset.
            unsafe {
                sqlite3changeset_apply(
                    self.as_ptr(),
                    size,
                    changeset.as_ptr().cast_mut().cast(),
                    Some(apply_filter),
                    Some(apply_conflict),
                    (&raw const *callbacks).cast_mut().cast(),
                )
            }
        }

        /// `sqlite3_load_extension`: the error message on a failure.
        pub fn load_extension(&self, path: &[u8], entry: Option<&[u8]>) -> Result<(), Option<Vec<u8>>> {
            let path = c_string(path);
            let entry = entry.map(c_string);
            let mut message: *mut c_char = ptr::null_mut();
            let code = unsafe {
                ffi::sqlite3_load_extension(
                    self.as_ptr(),
                    path.as_ptr().cast(),
                    entry.as_ref().map_or(ptr::null(), |entry| entry.as_ptr().cast()),
                    &raw mut message,
                )
            };
            if code == ffi::SQLITE_OK {
                return Ok(());
            }
            let text = unsafe { bytes(message) };
            unsafe { ffi::sqlite3_free(message.cast()) };
            Err(text)
        }

        /// Starts a backup of the database `source` of this connection into the database
        /// `target` of the file `path`.
        pub fn backup(&self, path: &[u8], source: &[u8], target: &[u8]) -> Result<Backup, Failure> {
            let (dest, code) = Db::open(
                path,
                ffi::SQLITE_OPEN_READWRITE | ffi::SQLITE_OPEN_CREATE | ffi::SQLITE_OPEN_URI,
            );
            let Some(dest) = dest else {
                return Err(Failure {
                    code,
                    message: errstr(code),
                    errstr: errstr(code),
                });
            };
            if code != ffi::SQLITE_OK {
                return Err(dest.failure());
            }
            let (source, target) = (c_string(source), c_string(target));
            let handle = unsafe {
                ffi::sqlite3_backup_init(
                    dest.as_ptr(),
                    target.as_ptr().cast(),
                    self.as_ptr(),
                    source.as_ptr().cast(),
                )
            };
            match NonNull::new(handle) {
                Some(handle) => Ok(Backup { handle, dest }),
                None => Err(dest.failure()),
            }
        }
    }

    impl Drop for Db {
        fn drop(&mut self) {
            unsafe { sqlite3_close_v2(self.as_ptr()) };
        }
    }

    fn failure_of(db: *mut ffi::sqlite3) -> Failure {
        let code = unsafe { ffi::sqlite3_extended_errcode(db) };
        Failure {
            code,
            message: unsafe { bytes(ffi::sqlite3_errmsg(db)) }.unwrap_or_default(),
            errstr: errstr(code),
        }
    }

    /// A prepared statement. Dropping it finalizes it; a connection that `sqlite3_close_v2`
    /// closed stays allocated until its last statement is finalized.
    pub struct Stmt {
        handle: NonNull<ffi::sqlite3_stmt>,
    }

    impl Stmt {
        fn as_ptr(&self) -> *mut ffi::sqlite3_stmt {
            self.handle.as_ptr()
        }

        fn db(&self) -> *mut ffi::sqlite3 {
            unsafe { ffi::sqlite3_db_handle(self.as_ptr()) }
        }

        /// The error of the last call on the connection of the statement.
        pub fn failure(&self) -> Failure {
            failure_of(self.db())
        }

        pub fn reset(&self) -> c_int {
            unsafe { ffi::sqlite3_reset(self.as_ptr()) }
        }

        pub fn clear_bindings(&self) -> c_int {
            unsafe { ffi::sqlite3_clear_bindings(self.as_ptr()) }
        }

        pub fn step(&self) -> c_int {
            unsafe { ffi::sqlite3_step(self.as_ptr()) }
        }

        pub fn bind(&self, index: c_int, value: &Value) -> c_int {
            let statement = self.as_ptr();
            unsafe {
                match value {
                    Value::Null => ffi::sqlite3_bind_null(statement, index),
                    Value::Int(value) => ffi::sqlite3_bind_int64(statement, index, *value),
                    Value::Float(value) => ffi::sqlite3_bind_double(statement, index, *value),
                    Value::Text(text) => ffi::sqlite3_bind_text64(
                        statement,
                        index,
                        text.as_ptr().cast(),
                        text.len() as u64,
                        ffi::SQLITE_TRANSIENT(),
                        UTF8,
                    ),
                    Value::Blob(data) => ffi::sqlite3_bind_blob64(
                        statement,
                        index,
                        data.as_ptr().cast(),
                        data.len() as u64,
                        ffi::SQLITE_TRANSIENT(),
                    ),
                }
            }
        }

        pub fn column_count(&self) -> c_int {
            unsafe { ffi::sqlite3_column_count(self.as_ptr()) }
        }

        pub fn column_name(&self, column: c_int) -> Vec<u8> {
            unsafe { bytes(ffi::sqlite3_column_name(self.as_ptr(), column)) }.unwrap_or_default()
        }

        /// The value of a column of the current row, as Node's `SQLITE_VALUE_TO_JS` reads it.
        pub fn column(&self, column: c_int) -> Value {
            let statement = self.as_ptr();
            unsafe {
                match ffi::sqlite3_column_type(statement, column) {
                    ffi::SQLITE_INTEGER => Value::Int(ffi::sqlite3_column_int64(statement, column)),
                    ffi::SQLITE_FLOAT => Value::Float(ffi::sqlite3_column_double(statement, column)),
                    ffi::SQLITE_TEXT => Value::Text(
                        bytes(ffi::sqlite3_column_text(statement, column).cast()).unwrap_or_default(),
                    ),
                    ffi::SQLITE_BLOB => {
                        let data = ffi::sqlite3_column_blob(statement, column).cast::<u8>();
                        let size = usize::try_from(ffi::sqlite3_column_bytes(statement, column)).unwrap_or(0);
                        Value::Blob(if data.is_null() || size == 0 {
                            Vec::new()
                        } else {
                            std::slice::from_raw_parts(data, size).to_vec()
                        })
                    }
                    _ => Value::Null,
                }
            }
        }

        /// The values of the current row.
        pub fn row(&self) -> Vec<Value> {
            (0..self.column_count()).map(|column| self.column(column)).collect()
        }

        pub fn names(&self) -> Vec<Vec<u8>> {
            (0..self.column_count()).map(|column| self.column_name(column)).collect()
        }

        /// The origin column, the database, the name, the table, and the declared type of
        /// a column.
        pub fn column_metadata(&self, column: c_int) -> [Option<Vec<u8>>; 5] {
            let statement = self.as_ptr();
            unsafe {
                [
                    bytes(ffi::sqlite3_column_origin_name(statement, column)),
                    bytes(ffi::sqlite3_column_database_name(statement, column)),
                    bytes(ffi::sqlite3_column_name(statement, column)),
                    bytes(ffi::sqlite3_column_table_name(statement, column)),
                    bytes(ffi::sqlite3_column_decltype(statement, column)),
                ]
            }
        }

        pub fn sql(&self) -> Vec<u8> {
            unsafe { bytes(ffi::sqlite3_sql(self.as_ptr())) }.unwrap_or_default()
        }

        pub fn expanded_sql(&self) -> Option<Vec<u8>> {
            let expanded = unsafe { ffi::sqlite3_expanded_sql(self.as_ptr()) };
            let text = unsafe { bytes(expanded) };
            unsafe { ffi::sqlite3_free(expanded.cast()) };
            text
        }

        /// The names of the parameters, from index 1, with none for an anonymous `?`.
        pub fn params(&self) -> Vec<Option<Vec<u8>>> {
            let statement = self.as_ptr();
            let count = unsafe { ffi::sqlite3_bind_parameter_count(statement) };
            (1..=count)
                .map(|index| unsafe { bytes(ffi::sqlite3_bind_parameter_name(statement, index)) })
                .collect()
        }

        pub fn changes(&self) -> i64 {
            unsafe { ffi::sqlite3_changes64(self.db()) }
        }

        pub fn last_insert_rowid(&self) -> i64 {
            unsafe { ffi::sqlite3_last_insert_rowid(self.db()) }
        }
    }

    impl Drop for Stmt {
        fn drop(&mut self) {
            unsafe { ffi::sqlite3_finalize(self.as_ptr()) };
        }
    }

    /// A session of the session extension. It must be dropped before its connection.
    pub struct Session {
        handle: NonNull<sqlite3_session>,
    }

    impl Session {
        pub fn attach(&self, table: Option<&[u8]>) -> c_int {
            let table = table.map(c_string);
            unsafe {
                sqlite3session_attach(
                    self.handle.as_ptr(),
                    table.as_ref().map_or(ptr::null(), |table| table.as_ptr().cast()),
                )
            }
        }

        /// The changeset, or the patchset, of the changes so far.
        pub fn changes(&self, patchset: bool) -> Result<Vec<u8>, c_int> {
            let mut size: c_int = 0;
            let mut data: *mut c_void = ptr::null_mut();
            let code = unsafe {
                if patchset {
                    sqlite3session_patchset(self.handle.as_ptr(), &raw mut size, &raw mut data)
                } else {
                    sqlite3session_changeset(self.handle.as_ptr(), &raw mut size, &raw mut data)
                }
            };
            let bytes = match usize::try_from(size) {
                Ok(size) if code == ffi::SQLITE_OK && !data.is_null() && size > 0 => {
                    unsafe { std::slice::from_raw_parts(data.cast::<u8>(), size) }.to_vec()
                }
                _ => Vec::new(),
            };
            unsafe { ffi::sqlite3_free(data) };
            if code == ffi::SQLITE_OK { Ok(bytes) } else { Err(code) }
        }
    }

    impl Drop for Session {
        fn drop(&mut self) {
            unsafe { sqlite3session_delete(self.handle.as_ptr()) };
        }
    }

    /// An online backup into the connection that it owns. It must be dropped before the
    /// source connection.
    pub struct Backup {
        handle: NonNull<ffi::sqlite3_backup>,
        dest: Db,
    }

    impl Backup {
        /// One `sqlite3_backup_step`: the result code, the pages left, and all the pages.
        pub fn step(&self, pages: c_int) -> (c_int, c_int, c_int) {
            unsafe {
                let code = ffi::sqlite3_backup_step(self.handle.as_ptr(), pages);
                (
                    code,
                    ffi::sqlite3_backup_remaining(self.handle.as_ptr()),
                    ffi::sqlite3_backup_pagecount(self.handle.as_ptr()),
                )
            }
        }

        /// The error of the destination connection.
        pub fn failure(&self) -> Failure {
            self.dest.failure()
        }
    }

    impl Drop for Backup {
        fn drop(&mut self) {
            unsafe { ffi::sqlite3_backup_finish(self.handle.as_ptr()) };
        }
    }
}

use raw::{AggregateCall, Outcome};

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The sending end of a connection thread. The thread stops when every resource that holds
/// it is gone.
struct Link(Mutex<Sender<Input>>);

impl Link {
    fn send(&self, input: Input) -> bool {
        lock(&self.0).send(input).is_ok()
    }
}

/// A `DatabaseSync` connection: its thread.
pub struct SqliteConnection {
    link: Arc<Link>,
}

#[rustler::resource_impl]
impl rustler::Resource for SqliteConnection {}

/// A statement of a connection. Dropping it finalizes the statement, as the garbage
/// collection of a `StatementSync` does.
pub struct SqliteStatement {
    link: Arc<Link>,
    id: u64,
}

#[rustler::resource_impl]
impl rustler::Resource for SqliteStatement {}

impl Drop for SqliteStatement {
    fn drop(&mut self) {
        self.link.send(Input::Release(Handle::Statement(self.id)));
    }
}

/// A session of a connection. Dropping it deletes the session.
pub struct SqliteSession {
    link: Arc<Link>,
    id: u64,
}

#[rustler::resource_impl]
impl rustler::Resource for SqliteSession {}

impl Drop for SqliteSession {
    fn drop(&mut self) {
        self.link.send(Input::Release(Handle::Session(self.id)));
    }
}

enum Handle {
    Statement(u64),
    Session(u64),
}

/// The process that sent a command, and the reference that tags its reply and its calls.
struct Caller {
    pid: LocalPid,
    env: OwnedEnv,
    reference: SavedTerm,
}

impl Caller {
    /// Sends `{Tag, Reference, Body}`.
    fn post(&self, tag: Atom, body: impl for<'a> FnOnce(Env<'a>) -> Term<'a>) -> bool {
        let mut out = OwnedEnv::new();
        out.send_and_clear(&self.pid, |env| {
            let reference = self.env.run(|own| self.reference.load(own).in_env(env));
            (tag, reference, body(env)).encode(env)
        })
        .is_ok()
    }
}

enum Input {
    Command(Caller, Command),
    Answer(Answer),
    Release(Handle),
}

/// The answer of the realm to a call.
enum Answer {
    Value(Value),
    Error(Vec<u8>),
    Ignore,
    Int(i64),
    Bool(bool),
    Nothing,
    Gone,
}

/// The parameters that a command binds before it runs: whether it clears the old ones, and
/// each index with its value.
struct Binding {
    clear: bool,
    values: Vec<(c_int, Value)>,
}

#[allow(clippy::struct_excessive_bools)]
struct OpenConfig {
    location: Vec<u8>,
    read_only: bool,
    enable_dqs: bool,
    foreign_keys: bool,
    defensive: bool,
    timeout: c_int,
    limits: Vec<(c_int, c_int)>,
    allow_extension: bool,
}

enum Command {
    Open(Box<OpenConfig>),
    Close,
    Exec(Vec<u8>),
    Prepare(Vec<u8>),
    Function { name: Vec<u8>, argc: c_int, flags: c_int, id: u64 },
    Aggregate { name: Vec<u8>, argc: c_int, flags: c_int, id: u64, window: bool },
    Location(Vec<u8>),
    IsTransaction,
    Limit(c_int, c_int),
    Session { db: Vec<u8>, table: Option<Vec<u8>> },
    Changeset { session: u64, patchset: bool },
    DeleteSession(u64),
    ApplyChangeset { changeset: Vec<u8>, filter: bool, conflict: bool },
    DbConfig(c_int, c_int),
    LoadExtension { path: Vec<u8>, entry: Option<Vec<u8>> },
    Authorizer(bool),
    BackupInit { path: Vec<u8>, source: Vec<u8>, target: Vec<u8> },
    BackupStep(u64, c_int),
    BackupFinish(u64),
    Run(u64, Binding),
    Get(u64, Binding),
    All(u64, Binding),
    Iterate(u64, Binding),
    Next(u64),
    Reset(u64),
    Columns(u64),
    Sql(u64),
    ExpandedSql(u64),
    Params(u64),
}

/// A call to the realm.
enum Call {
    Function(u64, Vec<Value>),
    Aggregate(u64, AggregateCall),
    Authorize(c_int, [Option<Vec<u8>>; 4]),
    Filter(Vec<u8>),
    Conflict(c_int),
}

enum Reply {
    Ok,
    Bool(bool),
    Int(i64),
    Bytes(Vec<u8>),
    Text(Option<Vec<u8>>),
    Statement(Option<u64>),
    Session(u64),
    Run(i64, i64),
    Row(Vec<Vec<u8>>, Vec<Value>),
    Rows(Vec<Vec<u8>>, Vec<Vec<Value>>),
    Nothing,
    Done,
    Columns(Vec<[Option<Vec<u8>>; 5]>),
    Params(Vec<Option<Vec<u8>>>),
    BackupStep { code: c_int, remaining: c_int, pages: c_int },
    Sqlite(raw::Failure),
    Code(c_int),
    Message(&'static str),
    LoadError(Option<Vec<u8>>),
    Failed { kept: bool, failure: raw::Failure },
    Finalized,
    NotOpen,
    Busy,
    Gone,
}

/// A statement of the thread, and whether a command runs it now.
struct Statement {
    raw: raw::Stmt,
    running: Cell<bool>,
}

/// The state of a connection thread. Each field is borrowed only between calls into
/// SQLite, because a call can run a command of the realm on this thread.
struct State {
    input: Receiver<Input>,
    link: Weak<Link>,
    db: RefCell<Option<Rc<raw::Db>>>,
    statements: RefCell<HashMap<u64, Rc<Statement>>>,
    sessions: RefCell<HashMap<u64, Rc<raw::Session>>>,
    backups: RefCell<HashMap<u64, Rc<raw::Backup>>>,
    callers: RefCell<Vec<Caller>>,
    /// What a nested command removed; it is dropped once no call of the realm waits, so
    /// no running statement loses a session or an authorizer under it.
    graveyard: RefCell<Vec<Box<dyn Any>>>,
    depth: Cell<u32>,
    next_id: Cell<u64>,
    me: std::rc::Weak<State>,
}

impl State {
    fn serve(&self) {
        while let Ok(input) = self.input.recv() {
            self.accept(input);
        }
        self.shut();
    }

    fn accept(&self, input: Input) {
        match input {
            Input::Command(caller, command) => self.command(caller, command),
            Input::Release(handle) => self.release(handle),
            // An answer with no call that waits for it.
            Input::Answer(_) => {}
        }
    }

    fn command(&self, caller: Caller, command: Command) {
        self.callers.borrow_mut().push(caller);
        let reply = self.execute(command);
        let caller = self.callers.borrow_mut().pop();
        if self.depth.get() == 0 {
            let buried = std::mem::take(&mut *self.graveyard.borrow_mut());
            drop(buried);
        }
        if let Some(caller) = caller {
            caller.post(atoms::buoy_sqlite(), |env| self.encode(env, reply));
        }
    }

    fn bury(&self, thing: Box<dyn Any>) {
        if self.depth.get() > 0 {
            self.graveyard.borrow_mut().push(thing);
        }
    }

    fn release(&self, handle: Handle) {
        match handle {
            Handle::Statement(id) => {
                let statement = self.statements.borrow_mut().remove(&id);
                drop(statement);
            }
            Handle::Session(id) => {
                let session = self.sessions.borrow_mut().remove(&id);
                if let Some(session) = session {
                    self.bury(Box::new(session));
                }
            }
        }
    }

    /// Sends a call to the realm and waits for its answer, running the commands that
    /// arrive meanwhile.
    fn call(&self, call: Call) -> Answer {
        let sent = self
            .callers
            .borrow()
            .last()
            .is_some_and(|caller| caller.post(atoms::buoy_sqlite_call(), |env| encode_call(env, call)));
        if !sent {
            return Answer::Gone;
        }
        self.depth.set(self.depth.get() + 1);
        let answer = loop {
            match self.input.recv() {
                Ok(Input::Answer(answer)) => break answer,
                Ok(input) => self.accept(input),
                Err(_) => break Answer::Gone,
            }
        };
        self.depth.set(self.depth.get() - 1);
        answer
    }

    fn next_id(&self) -> u64 {
        let id = self.next_id.get();
        self.next_id.set(id + 1);
        id
    }

    fn db(&self) -> Option<Rc<raw::Db>> {
        self.db.borrow().clone()
    }

    /// Node's `DatabaseSync::Close`, before `sqlite3_close_v2`: the backups, the
    /// statements, and the sessions go first.
    fn close_db(&self) -> Option<Rc<raw::Db>> {
        let backups = std::mem::take(&mut *self.backups.borrow_mut());
        drop(backups);
        let statements = std::mem::take(&mut *self.statements.borrow_mut());
        drop(statements);
        let sessions = std::mem::take(&mut *self.sessions.borrow_mut());
        drop(sessions);
        self.db.borrow_mut().take()
    }

    fn shut(&self) {
        drop(self.close_db());
        let buried = std::mem::take(&mut *self.graveyard.borrow_mut());
        drop(buried);
    }

    fn execute(&self, command: Command) -> Reply {
        match command {
            Command::Open(config) => self.open(&config),
            Command::BackupStep(id, pages) => {
                let backup = self.backups.borrow().get(&id).cloned();
                backup.map_or(Reply::Gone, |backup| {
                    let (code, remaining, pages) = backup.step(pages);
                    Reply::BackupStep { code, remaining, pages }
                })
            }
            Command::BackupFinish(id) => {
                let backup = self.backups.borrow_mut().remove(&id);
                backup.map_or(Reply::Gone, |backup| {
                    let failure = backup.failure();
                    self.bury(Box::new(backup));
                    Reply::Sqlite(failure)
                })
            }
            Command::Run(id, binding) => self.with_statement(id, |statement| run(statement, &binding)),
            Command::Get(id, binding) => self.with_statement(id, |statement| get(statement, &binding)),
            Command::All(id, binding) => self.with_statement(id, |statement| all(statement, &binding)),
            Command::Iterate(id, binding) => self.with_statement(id, |statement| {
                if statement.reset() != ffi::SQLITE_OK {
                    return Reply::Sqlite(statement.failure());
                }
                bind(statement, &binding).unwrap_or(Reply::Ok)
            }),
            Command::Next(id) => self.with_statement(id, next),
            Command::Reset(id) => self.with_statement(id, |statement| {
                statement.reset();
                Reply::Ok
            }),
            Command::Columns(id) => self.with_statement(id, |statement| {
                Reply::Columns(
                    (0..statement.column_count())
                        .map(|column| statement.column_metadata(column))
                        .collect(),
                )
            }),
            Command::Sql(id) => self.with_statement(id, |statement| Reply::Bytes(statement.sql())),
            Command::ExpandedSql(id) => self.with_statement(id, |statement| {
                statement.expanded_sql().map_or(
                    Reply::Message("Expanded SQL text would exceed configured limits"),
                    Reply::Bytes,
                )
            }),
            Command::Params(id) => self.with_statement(id, |statement| Reply::Params(statement.params())),
            command => match self.db() {
                Some(db) => self.execute_on(&db, command),
                None => Reply::NotOpen,
            },
        }
    }

    /// Runs `body` on a statement that no other command runs now.
    fn with_statement(&self, id: u64, body: impl FnOnce(&raw::Stmt) -> Reply) -> Reply {
        let statement = self.statements.borrow().get(&id).cloned();
        let Some(statement) = statement else {
            return Reply::Finalized;
        };
        if statement.running.replace(true) {
            return Reply::Busy;
        }
        let reply = body(&statement.raw);
        statement.running.set(false);
        reply
    }

    fn open(&self, config: &OpenConfig) -> Reply {
        if self.db.borrow().is_some() {
            return Reply::Busy;
        }
        let flags = ffi::SQLITE_OPEN_URI
            | if config.read_only {
                ffi::SQLITE_OPEN_READONLY
            } else {
                ffi::SQLITE_OPEN_READWRITE | ffi::SQLITE_OPEN_CREATE
            };
        let (db, code) = raw::Db::open(&config.location, flags);
        let Some(db) = db else {
            return Reply::Failed {
                kept: false,
                failure: raw::Failure {
                    code,
                    message: raw::errstr(code),
                    errstr: raw::errstr(code),
                },
            };
        };
        let db = Rc::new(db);
        *self.db.borrow_mut() = Some(Rc::clone(&db));
        let failed = || Reply::Failed {
            kept: true,
            failure: db.failure(),
        };
        if code != ffi::SQLITE_OK {
            return failed();
        }
        let dqs = c_int::from(config.enable_dqs);
        let settings = [
            (ffi::SQLITE_DBCONFIG_DQS_DML, dqs),
            (ffi::SQLITE_DBCONFIG_DQS_DDL, dqs),
            (ffi::SQLITE_DBCONFIG_ENABLE_FKEY, c_int::from(config.foreign_keys)),
            (ffi::SQLITE_DBCONFIG_DEFENSIVE, c_int::from(config.defensive)),
        ];
        if settings
            .iter()
            .any(|&(op, value)| db.config(op, value) != ffi::SQLITE_OK)
        {
            return failed();
        }
        db.busy_timeout(config.timeout);
        for &(id, value) in &config.limits {
            db.limit(id, value);
        }
        if config.allow_extension
            && db.config(ffi::SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 1) != ffi::SQLITE_OK
        {
            return failed();
        }
        Reply::Ok
    }

    #[allow(clippy::too_many_lines)]
    fn execute_on(&self, db: &Rc<raw::Db>, command: Command) -> Reply {
        let checked = |code: c_int| {
            if code == ffi::SQLITE_OK {
                Reply::Ok
            } else {
                Reply::Sqlite(db.failure())
            }
        };
        match command {
            Command::Close => {
                if self.depth.get() > 0 {
                    return Reply::Busy;
                }
                drop(self.close_db());
                Reply::Ok
            }
            Command::Exec(sql) => checked(db.exec(&sql)),
            Command::Prepare(sql) => match db.prepare(&sql) {
                Ok(Some(statement)) => {
                    let id = self.next_id();
                    self.statements.borrow_mut().insert(
                        id,
                        Rc::new(Statement {
                            raw: statement,
                            running: Cell::new(false),
                        }),
                    );
                    Reply::Statement(Some(id))
                }
                Ok(None) => Reply::Statement(None),
                Err(_) => Reply::Sqlite(db.failure()),
            },
            Command::Function { name, argc, flags, id } => {
                let me = self.me.clone();
                let function: raw::FunctionFn = Box::new(move |args| {
                    let answer = me
                        .upgrade()
                        .map_or(Answer::Gone, |state| state.call(Call::Function(id, args)));
                    outcome(answer)
                });
                checked(db.create_function(&name, argc, flags, function))
            }
            Command::Aggregate { name, argc, flags, id, window } => {
                let me = self.me.clone();
                let aggregate: raw::AggregateFn = Box::new(move |call| {
                    let produces = matches!(call, AggregateCall::Value(_) | AggregateCall::Final(_));
                    let answer = me
                        .upgrade()
                        .map_or(Answer::Gone, |state| state.call(Call::Aggregate(id, call)));
                    match answer {
                        Answer::Nothing => None,
                        Answer::Ignore | Answer::Gone | Answer::Error(_) => Some(outcome(answer)),
                        answer if produces => Some(outcome(answer)),
                        _ => None,
                    }
                });
                checked(db.create_aggregate(&name, argc, flags, window, aggregate))
            }
            Command::Location(name) => Reply::Text(db.filename(&name)),
            Command::IsTransaction => Reply::Bool(!db.is_autocommit()),
            Command::Limit(id, value) => Reply::Int(i64::from(db.limit(id, value))),
            Command::Session { db: name, table } => match db.create_session(&name) {
                Ok(session) => {
                    let session = Rc::new(session);
                    let id = self.next_id();
                    self.sessions.borrow_mut().insert(id, Rc::clone(&session));
                    let code = session.attach(table.as_deref());
                    if code == ffi::SQLITE_OK {
                        Reply::Session(id)
                    } else {
                        Reply::Sqlite(db.failure())
                    }
                }
                Err(_) => Reply::Sqlite(db.failure()),
            },
            Command::Changeset { session, patchset } => {
                let found = self.sessions.borrow().get(&session).cloned();
                found.map_or(Reply::Finalized, |found| match found.changes(patchset) {
                    Ok(bytes) => Reply::Bytes(bytes),
                    Err(_) => Reply::Sqlite(db.failure()),
                })
            }
            Command::DeleteSession(session) => {
                let found = self.sessions.borrow_mut().remove(&session);
                found.map_or(Reply::Finalized, |found| {
                    self.bury(Box::new(found));
                    Reply::Ok
                })
            }
            Command::ApplyChangeset { changeset, filter, conflict } => {
                let me = &self.me;
                let filter_fn = move |table: Vec<u8>| {
                    me.upgrade().is_some_and(|state| {
                        matches!(state.call(Call::Filter(table)), Answer::Bool(true))
                    })
                };
                let conflict_fn = move |kind: c_int| match me.upgrade().map(|state| state.call(Call::Conflict(kind))) {
                    Some(Answer::Int(code)) => c_int::try_from(code).unwrap_or(-1),
                    _ => raw::CHANGESET_ABORT,
                };
                let callbacks = raw::ApplyCallbacks {
                    filter: if filter { Some(&filter_fn) } else { None },
                    conflict: if conflict { Some(&conflict_fn) } else { None },
                };
                match db.apply_changeset(&changeset, &callbacks) {
                    ffi::SQLITE_OK => Reply::Bool(true),
                    ffi::SQLITE_ABORT => Reply::Bool(false),
                    code => Reply::Code(code),
                }
            }
            Command::DbConfig(op, value) => checked(db.config(op, value)),
            Command::LoadExtension { path, entry } => match db.load_extension(&path, entry.as_deref()) {
                Ok(()) => Reply::Ok,
                Err(message) => Reply::LoadError(message),
            },
            Command::Authorizer(enable) => {
                let authorizer: Option<raw::AuthorizerFn> = enable.then(|| {
                    let me = self.me.clone();
                    Box::new(move |action, params| {
                        match me.upgrade().map(|state| state.call(Call::Authorize(action, params))) {
                            Some(Answer::Int(code)) => c_int::try_from(code).unwrap_or(ffi::SQLITE_DENY),
                            _ => ffi::SQLITE_DENY,
                        }
                    }) as raw::AuthorizerFn
                });
                let (code, old) = db.set_authorizer(authorizer);
                if let Some(old) = old {
                    self.bury(old);
                }
                checked(code)
            }
            Command::BackupInit { path, source, target } => match db.backup(&path, &source, &target) {
                Ok(backup) => {
                    let id = self.next_id();
                    self.backups.borrow_mut().insert(id, Rc::new(backup));
                    Reply::Int(i64::try_from(id).unwrap_or(i64::MAX))
                }
                Err(failure) => Reply::Sqlite(failure),
            },
            _ => Reply::Gone,
        }
    }

    fn encode<'a>(&self, env: Env<'a>, reply: Reply) -> Term<'a> {
        let link = self.link.upgrade();
        match reply {
            Reply::Ok => atoms::ok().encode(env),
            Reply::Bool(value) => value.encode(env),
            Reply::Int(value) => value.encode(env),
            Reply::Bytes(bytes) => binary(env, &bytes),
            Reply::Text(text) => nullable(env, text.as_deref()),
            Reply::Statement(None) => (atoms::ok(), atoms::empty()).encode(env),
            Reply::Statement(Some(id)) => link.map_or(atoms::gone().encode(env), |link| {
                (atoms::ok(), ResourceArc::new(SqliteStatement { link, id })).encode(env)
            }),
            Reply::Session(id) => link.map_or(atoms::gone().encode(env), |link| {
                (atoms::ok(), ResourceArc::new(SqliteSession { link, id })).encode(env)
            }),
            Reply::Run(changes, last) => (atoms::ok(), changes, last).encode(env),
            Reply::Row(names, values) => (atoms::row(), names_term(env, &names), values_term(env, &values)).encode(env),
            Reply::Rows(names, rows) => {
                let rows: Vec<Term<'a>> = rows.iter().map(|row| values_term(env, row)).collect();
                (atoms::rows(), names_term(env, &names), rows).encode(env)
            }
            Reply::Nothing => atoms::none().encode(env),
            Reply::Done => atoms::done().encode(env),
            Reply::Columns(columns) => columns
                .iter()
                .map(|column| {
                    let [origin, database, name, table, kind] = column;
                    (
                        nullable(env, origin.as_deref()),
                        nullable(env, database.as_deref()),
                        nullable(env, name.as_deref()),
                        nullable(env, table.as_deref()),
                        nullable(env, kind.as_deref()),
                    )
                        .encode(env)
                })
                .collect::<Vec<_>>()
                .encode(env),
            Reply::Params(params) => params
                .iter()
                .map(|param| nullable(env, param.as_deref()))
                .collect::<Vec<_>>()
                .encode(env),
            Reply::BackupStep { code, remaining, pages } => {
                (atoms::step(), code, binary(env, &raw::errstr(code)), remaining, pages).encode(env)
            }
            Reply::Sqlite(failure) => failure_term(env, &failure),
            Reply::Code(code) => (atoms::sqlite_code(), code, binary(env, &raw::errstr(code))).encode(env),
            Reply::Message(message) => (atoms::sqlite_message(), binary(env, message.as_bytes())).encode(env),
            Reply::LoadError(message) => (atoms::load_error(), nullable(env, message.as_deref())).encode(env),
            Reply::Failed { kept, failure } => (atoms::failed(), kept, failure_term(env, &failure)).encode(env),
            Reply::Finalized => atoms::finalized().encode(env),
            Reply::NotOpen => atoms::not_open().encode(env),
            Reply::Busy => atoms::busy().encode(env),
            Reply::Gone => atoms::gone().encode(env),
        }
    }
}

/// Node's `StatementExecutionHelper::Run` after the reset and the binding.
fn run(statement: &raw::Stmt, binding: &Binding) -> Reply {
    if statement.reset() != ffi::SQLITE_OK {
        return Reply::Sqlite(statement.failure());
    }
    if let Some(failure) = bind(statement, binding) {
        return failure;
    }
    statement.step();
    if statement.reset() != ffi::SQLITE_OK {
        return Reply::Sqlite(statement.failure());
    }
    Reply::Run(statement.changes(), statement.last_insert_rowid())
}

fn get(statement: &raw::Stmt, binding: &Binding) -> Reply {
    if statement.reset() != ffi::SQLITE_OK {
        return Reply::Sqlite(statement.failure());
    }
    if let Some(failure) = bind(statement, binding) {
        return failure;
    }
    let reply = match statement.step() {
        ffi::SQLITE_DONE => Reply::Nothing,
        ffi::SQLITE_ROW if statement.column_count() == 0 => Reply::Nothing,
        ffi::SQLITE_ROW => Reply::Row(statement.names(), statement.row()),
        _ => Reply::Sqlite(statement.failure()),
    };
    statement.reset();
    reply
}

fn all(statement: &raw::Stmt, binding: &Binding) -> Reply {
    if statement.reset() != ffi::SQLITE_OK {
        return Reply::Sqlite(statement.failure());
    }
    if let Some(failure) = bind(statement, binding) {
        return failure;
    }
    let mut rows = Vec::new();
    let code = loop {
        match statement.step() {
            ffi::SQLITE_ROW => rows.push(statement.row()),
            code => break code,
        }
    };
    let reply = if code == ffi::SQLITE_DONE {
        Reply::Rows(statement.names(), rows)
    } else {
        Reply::Sqlite(statement.failure())
    };
    statement.reset();
    reply
}

/// `StatementSyncIterator::Next`.
fn next(statement: &raw::Stmt) -> Reply {
    match statement.step() {
        ffi::SQLITE_ROW => Reply::Row(statement.names(), statement.row()),
        ffi::SQLITE_DONE => {
            statement.reset();
            Reply::Done
        }
        _ => Reply::Sqlite(statement.failure()),
    }
}

/// Binds the parameters: the failure, if one fails.
fn bind(statement: &raw::Stmt, binding: &Binding) -> Option<Reply> {
    if binding.clear && statement.clear_bindings() != ffi::SQLITE_OK {
        return Some(Reply::Sqlite(statement.failure()));
    }
    binding
        .values
        .iter()
        .find(|(index, value)| statement.bind(*index, value) != ffi::SQLITE_OK)
        .map(|_| Reply::Sqlite(statement.failure()))
}

/// The result of a function from the answer of the realm.
fn outcome(answer: Answer) -> Outcome {
    match answer {
        Answer::Value(value) => Outcome::Value(value),
        Answer::Error(message) => Outcome::Error(message),
        Answer::Int(value) => Outcome::Value(Value::Int(value)),
        Answer::Bool(_) | Answer::Nothing => Outcome::Value(Value::Null),
        Answer::Ignore | Answer::Gone => Outcome::Error(Vec::new()),
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    Binary::from(binary).encode(env)
}

fn nullable<'a>(env: Env<'a>, bytes: Option<&[u8]>) -> Term<'a> {
    bytes.map_or(atoms::null().encode(env), |bytes| binary(env, bytes))
}

/// Text as V8's `String::NewFromUtf8` reads it: invalid sequences become U+FFFD.
fn text<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    match String::from_utf8_lossy(bytes) {
        std::borrow::Cow::Borrowed(_) => binary(env, bytes),
        std::borrow::Cow::Owned(fixed) => binary(env, fixed.as_bytes()),
    }
}

fn value_term<'a>(env: Env<'a>, value: &Value) -> Term<'a> {
    match value {
        Value::Null => atoms::null().encode(env),
        Value::Int(value) => (*value).encode(env),
        Value::Float(value) if value.is_finite() => (*value).encode(env),
        Value::Float(value) if value.is_nan() => atoms::nan().encode(env),
        Value::Float(value) if *value > 0.0 => atoms::infinity().encode(env),
        Value::Float(_) => atoms::negative_infinity().encode(env),
        Value::Text(bytes) => text(env, bytes),
        Value::Blob(bytes) => (atoms::blob(), binary(env, bytes)).encode(env),
    }
}

fn values_term<'a>(env: Env<'a>, values: &[Value]) -> Term<'a> {
    values
        .iter()
        .map(|value| value_term(env, value))
        .collect::<Vec<_>>()
        .encode(env)
}

fn names_term<'a>(env: Env<'a>, names: &[Vec<u8>]) -> Term<'a> {
    names
        .iter()
        .map(|name| text(env, name))
        .collect::<Vec<_>>()
        .encode(env)
}

fn failure_term<'a>(env: Env<'a>, failure: &raw::Failure) -> Term<'a> {
    (
        atoms::sqlite_error(),
        failure.code,
        text(env, &failure.message),
        binary(env, &failure.errstr),
    )
        .encode(env)
}

fn encode_call<'a>(env: Env<'a>, call: Call) -> Term<'a> {
    match call {
        Call::Function(id, args) => (atoms::function(), id, values_term(env, &args)).encode(env),
        Call::Aggregate(id, AggregateCall::Step(key, args)) => {
            (atoms::aggregate(), id, atoms::step(), key, values_term(env, &args)).encode(env)
        }
        Call::Aggregate(id, AggregateCall::Inverse(key, args)) => {
            (atoms::aggregate(), id, atoms::inverse(), key, values_term(env, &args)).encode(env)
        }
        Call::Aggregate(id, AggregateCall::Value(key)) => {
            (atoms::aggregate(), id, atoms::value(), key, Vec::<Term<'a>>::new()).encode(env)
        }
        Call::Aggregate(id, AggregateCall::Final(key)) => {
            (atoms::aggregate(), id, atoms::final_(), key, Vec::<Term<'a>>::new()).encode(env)
        }
        Call::Authorize(action, params) => {
            let params: Vec<Term<'a>> = params.iter().map(|param| nullable(env, param.as_deref())).collect();
            (atoms::authorize(), action, params).encode(env)
        }
        Call::Filter(table) => (atoms::filter(), text(env, &table)).encode(env),
        Call::Conflict(kind) => (atoms::conflict(), kind).encode(env),
    }
}

// Decoding the terms of the realm.

fn bytes_of(term: Term<'_>) -> NifResult<Vec<u8>> {
    Ok(term.decode::<Binary<'_>>()?.as_slice().to_vec())
}

fn optional_bytes(term: Term<'_>) -> NifResult<Option<Vec<u8>>> {
    if term.decode::<Atom>().is_ok_and(|atom| atom == atoms::null()) {
        Ok(None)
    } else {
        bytes_of(term).map(Some)
    }
}

fn decode_value(term: Term<'_>) -> NifResult<Value> {
    if let Ok(atom) = term.decode::<Atom>() {
        return Ok(if atom == atoms::nan() {
            Value::Float(f64::NAN)
        } else if atom == atoms::infinity() {
            Value::Float(f64::INFINITY)
        } else if atom == atoms::negative_infinity() {
            Value::Float(f64::NEG_INFINITY)
        } else if atom == atoms::null() {
            Value::Null
        } else {
            return Err(Error::BadArg);
        });
    }
    if term.is_float() {
        return Ok(Value::Float(term.decode()?));
    }
    if term.is_integer() {
        return Ok(Value::Int(term.decode()?));
    }
    if term.is_binary() {
        return Ok(Value::Text(bytes_of(term)?));
    }
    let (tag, data): (Atom, Term<'_>) = term.decode()?;
    if tag == atoms::blob() {
        Ok(Value::Blob(bytes_of(data)?))
    } else {
        Err(Error::BadArg)
    }
}

fn decode_answer(term: Term<'_>) -> NifResult<Answer> {
    if let Ok(flag) = term.decode::<bool>() {
        return Ok(Answer::Bool(flag));
    }
    if let Ok(atom) = term.decode::<Atom>() {
        return Ok(if atom == atoms::ignore() {
            Answer::Ignore
        } else {
            Answer::Nothing
        });
    }
    if term.is_integer() {
        return Ok(Answer::Int(term.decode()?));
    }
    let (tag, data): (Atom, Term<'_>) = term.decode()?;
    if tag == atoms::value() {
        Ok(Answer::Value(decode_value(data)?))
    } else if tag == atoms::error() {
        Ok(Answer::Error(bytes_of(data)?))
    } else {
        Err(Error::BadArg)
    }
}

/// The statement of `term`, which must belong to `connection`.
fn statement_of(connection: &SqliteConnection, term: Term<'_>) -> NifResult<u64> {
    let statement: ResourceArc<SqliteStatement> = term.decode()?;
    if Arc::ptr_eq(&statement.link, &connection.link) {
        Ok(statement.id)
    } else {
        Err(Error::BadArg)
    }
}

fn session_of(connection: &SqliteConnection, term: Term<'_>) -> NifResult<u64> {
    let session: ResourceArc<SqliteSession> = term.decode()?;
    if Arc::ptr_eq(&session.link, &connection.link) {
        Ok(session.id)
    } else {
        Err(Error::BadArg)
    }
}

/// `{Clear, [{Index, Value}]}`.
fn decode_binding(term: Term<'_>) -> NifResult<Binding> {
    let (clear, values): (bool, Vec<(c_int, Term<'_>)>) = term.decode()?;
    let values = values
        .into_iter()
        .map(|(index, value)| Ok((index, decode_value(value)?)))
        .collect::<NifResult<Vec<_>>>()?;
    Ok(Binding { clear, values })
}

#[allow(clippy::too_many_lines)]
fn decode_command(connection: &SqliteConnection, term: Term<'_>) -> NifResult<Command> {
    if let Ok(atom) = term.decode::<Atom>() {
        return if atom == atoms::close() {
            Ok(Command::Close)
        } else if atom == atoms::is_transaction() {
            Ok(Command::IsTransaction)
        } else {
            Err(Error::BadArg)
        };
    }
    let elements = get_tuple(term)?;
    let (&tag, args) = elements.split_first().ok_or(Error::BadArg)?;
    let tag: Atom = tag.decode()?;
    let arg = |index: usize| args.get(index).copied().ok_or(Error::BadArg);
    let statement = |index: usize| statement_of(connection, arg(index)?);
    Ok(if tag == atoms::open() {
        Command::Open(Box::new(OpenConfig {
            location: bytes_of(arg(0)?)?,
            read_only: arg(1)?.decode()?,
            enable_dqs: arg(2)?.decode()?,
            foreign_keys: arg(3)?.decode()?,
            defensive: arg(4)?.decode()?,
            timeout: arg(5)?.decode()?,
            limits: arg(6)?.decode()?,
            allow_extension: arg(7)?.decode()?,
        }))
    } else if tag == atoms::exec() {
        Command::Exec(bytes_of(arg(0)?)?)
    } else if tag == atoms::prepare() {
        Command::Prepare(bytes_of(arg(0)?)?)
    } else if tag == atoms::function() {
        Command::Function {
            name: bytes_of(arg(0)?)?,
            argc: arg(1)?.decode()?,
            flags: arg(2)?.decode()?,
            id: arg(3)?.decode()?,
        }
    } else if tag == atoms::aggregate() {
        Command::Aggregate {
            name: bytes_of(arg(0)?)?,
            argc: arg(1)?.decode()?,
            flags: arg(2)?.decode()?,
            id: arg(3)?.decode()?,
            window: arg(4)?.decode()?,
        }
    } else if tag == atoms::location() {
        Command::Location(bytes_of(arg(0)?)?)
    } else if tag == atoms::limit() {
        Command::Limit(arg(0)?.decode()?, arg(1)?.decode()?)
    } else if tag == atoms::session() {
        Command::Session {
            db: bytes_of(arg(0)?)?,
            table: optional_bytes(arg(1)?)?,
        }
    } else if tag == atoms::changeset() {
        Command::Changeset {
            session: session_of(connection, arg(0)?)?,
            patchset: arg(1)?.decode()?,
        }
    } else if tag == atoms::delete_session() {
        Command::DeleteSession(session_of(connection, arg(0)?)?)
    } else if tag == atoms::apply_changeset() {
        Command::ApplyChangeset {
            changeset: bytes_of(arg(0)?)?,
            filter: arg(1)?.decode()?,
            conflict: arg(2)?.decode()?,
        }
    } else if tag == atoms::db_config() {
        Command::DbConfig(arg(0)?.decode()?, arg(1)?.decode()?)
    } else if tag == atoms::load_extension() {
        Command::LoadExtension {
            path: bytes_of(arg(0)?)?,
            entry: optional_bytes(arg(1)?)?,
        }
    } else if tag == atoms::authorizer() {
        Command::Authorizer(arg(0)?.decode()?)
    } else if tag == atoms::backup_init() {
        Command::BackupInit {
            path: bytes_of(arg(0)?)?,
            source: bytes_of(arg(1)?)?,
            target: bytes_of(arg(2)?)?,
        }
    } else if tag == atoms::backup_step() {
        Command::BackupStep(arg(0)?.decode()?, arg(1)?.decode()?)
    } else if tag == atoms::backup_finish() {
        Command::BackupFinish(arg(0)?.decode()?)
    } else if tag == atoms::run() {
        Command::Run(statement(0)?, decode_binding(arg(1)?)?)
    } else if tag == atoms::get() {
        Command::Get(statement(0)?, decode_binding(arg(1)?)?)
    } else if tag == atoms::all() {
        Command::All(statement(0)?, decode_binding(arg(1)?)?)
    } else if tag == atoms::iterate() {
        Command::Iterate(statement(0)?, decode_binding(arg(1)?)?)
    } else if tag == atoms::next() {
        Command::Next(statement(0)?)
    } else if tag == atoms::reset() {
        Command::Reset(statement(0)?)
    } else if tag == atoms::columns() {
        Command::Columns(statement(0)?)
    } else if tag == atoms::sql() {
        Command::Sql(statement(0)?)
    } else if tag == atoms::expanded_sql() {
        Command::ExpandedSql(statement(0)?)
    } else if tag == atoms::params() {
        Command::Params(statement(0)?)
    } else {
        return Err(Error::BadArg);
    })
}

// The NIFs.

/// A new connection thread, with no database open yet.
#[rustler::nif]
fn sqlite_connection() -> NifResult<ResourceArc<SqliteConnection>> {
    raw::configure();
    let (sender, receiver) = mpsc::channel();
    let link = Arc::new(Link(Mutex::new(sender)));
    let weak = Arc::downgrade(&link);
    std::thread::Builder::new()
        .name("buoy-sqlite".into())
        .spawn(move || {
            let state = Rc::new_cyclic(|me| State {
                input: receiver,
                link: weak,
                db: RefCell::new(None),
                statements: RefCell::new(HashMap::new()),
                sessions: RefCell::new(HashMap::new()),
                backups: RefCell::new(HashMap::new()),
                callers: RefCell::new(Vec::new()),
                graveyard: RefCell::new(Vec::new()),
                depth: Cell::new(0),
                next_id: Cell::new(1),
                me: me.clone(),
            });
            state.serve();
        })
        .map_err(|_| Error::Atom("no_thread"))?;
    Ok(ResourceArc::new(SqliteConnection { link }))
}

/// Sends a command; the thread replies `{buoy_sqlite, Reference, Reply}` to the caller, and
/// sends it `{buoy_sqlite_call, Reference, Call}` for each call that waits for an answer.
#[rustler::nif]
fn sqlite_command<'a>(
    env: Env<'a>,
    connection: ResourceArc<SqliteConnection>,
    reference: Term<'a>,
    command: Term<'a>,
) -> NifResult<bool> {
    let command = decode_command(&connection, command)?;
    let own = OwnedEnv::new();
    let saved = own.save(reference);
    let caller = Caller {
        pid: env.pid(),
        env: own,
        reference: saved,
    };
    Ok(connection.link.send(Input::Command(caller, command)))
}

/// The answer of the realm to the call that waits.
#[rustler::nif]
fn sqlite_answer(connection: ResourceArc<SqliteConnection>, answer: Term<'_>) -> NifResult<bool> {
    Ok(connection.link.send(Input::Answer(decode_answer(answer)?)))
}
