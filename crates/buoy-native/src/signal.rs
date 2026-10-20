//! SIGINT for `process.on('SIGINT')` and the `breakOnSigint` of `node:vm`. OTP's
//! `os:set_signal/2` catches no SIGINT, so while a listener waits for one, a handler of
//! this library writes each SIGINT to a pipe, and a thread hands it to the process that
//! `sigint_handle/1` names as the event `{notify, sigint}`, which `erl_signal_server`
//! dispatches as OTP dispatches the signals that it catches. The handler only writes one
//! byte, which is async-signal-safe.

use std::ffi::{c_int, c_void};
use std::fs::File;
use std::io::Read;
use std::os::fd::FromRawFd;
use std::sync::Mutex;
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};

use rustler::{Encoder, LocalPid, OwnedEnv};

rustler::atoms! {
    notify,
    sigint,
}

/// SIGINT on Linux and on macOS.
const SIGINT: c_int = 2;

/// The write end of the pipe, or -1 before the first `sigint_handle`.
static WRITE_FD: AtomicI32 = AtomicI32::new(-1);
/// The disposition of SIGINT before `sigint_handle` replaced it, such as `SIG_DFL`.
static PREVIOUS: AtomicUsize = AtomicUsize::new(0);
/// The process that receives `{notify, sigint}`.
static TARGET: Mutex<Option<LocalPid>> = Mutex::new(None);

#[allow(unsafe_code)]
mod sys {
    use std::ffi::{c_int, c_void};

    unsafe extern "C" {
        /// `signal(2)`: the handler is a `sighandler_t`, a pointer-sized value.
        pub fn signal(signum: c_int, handler: usize) -> usize;
        pub fn pipe(fds: *mut c_int) -> c_int;
        pub fn write(fd: c_int, buffer: *const c_void, count: usize) -> isize;
        pub fn kill(pid: c_int, signum: c_int) -> c_int;
    }
}

/// `kill(2)` of `process.kill` and of a child's handle: 0, or the negative errno, as uv
/// returns it. A shell's `kill` took a process and tens of milliseconds for each signal.
#[allow(unsafe_code)]
#[rustler::nif]
fn os_kill(pid: c_int, signum: c_int) -> c_int {
    // SAFETY: kill(2) takes plain integers.
    if unsafe { sys::kill(pid, signum) } == 0 {
        0
    } else {
        -std::io::Error::last_os_error().raw_os_error().unwrap_or(1)
    }
}

#[allow(unsafe_code)]
extern "C" fn on_sigint(_signum: c_int) {
    let fd = WRITE_FD.load(Ordering::Relaxed);
    if fd >= 0 {
        let byte = 1_u8;
        // SAFETY: write(2) of one byte from a live local is async-signal-safe.
        unsafe { sys::write(fd, (&raw const byte).cast::<c_void>(), 1) };
    }
}

/// The pipe and the thread that reads it, made once.
#[allow(unsafe_code)]
fn start_reader() -> bool {
    if WRITE_FD.load(Ordering::Acquire) >= 0 {
        return true;
    }
    let mut fds: [c_int; 2] = [-1, -1];
    // SAFETY: pipe(2) writes two descriptors into the array of two.
    if unsafe { sys::pipe(fds.as_mut_ptr()) } != 0 {
        return false;
    }
    // SAFETY: the read end is a fresh descriptor that only this File owns.
    let mut reader = unsafe { File::from_raw_fd(fds[0]) };
    std::thread::spawn(move || {
        let mut byte = [0_u8; 1];
        while reader.read_exact(&mut byte).is_ok() {
            let target = *TARGET
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(pid) = target {
                let mut env = OwnedEnv::new();
                let _ = env.send_and_clear(&pid, |env| (notify(), sigint()).encode(env));
            }
        }
    });
    WRITE_FD.store(fds[1], Ordering::Release);
    true
}

/// Sends each SIGINT to `target` as `{notify, sigint}`, until `sigint_default/0`.
#[allow(unsafe_code)]
#[rustler::nif]
fn sigint_handle(target: LocalPid) -> bool {
    *TARGET
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(target);
    if !start_reader() {
        return false;
    }
    let handler = on_sigint as extern "C" fn(c_int) as usize;
    // SAFETY: on_sigint only does async-signal-safe work.
    let previous = unsafe { sys::signal(SIGINT, handler) };
    if previous != handler {
        PREVIOUS.store(previous, Ordering::Release);
    }
    true
}

/// Gives SIGINT back the disposition that it had before `sigint_handle/1`.
#[allow(unsafe_code)]
#[rustler::nif]
fn sigint_default() -> bool {
    let handler = on_sigint as extern "C" fn(c_int) as usize;
    // SAFETY: the previous disposition came from signal(2) itself.
    let previous = unsafe { sys::signal(SIGINT, PREVIOUS.load(Ordering::Acquire)) };
    previous == handler
}
