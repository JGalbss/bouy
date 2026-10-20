//! inotify for the `FSEvent` handles of `internalBinding('fs_event_wrap')` on Linux, as
//! libuv's `src/unix/linux.c` watches: one inotify descriptor for the VM, opened at the
//! first watch, with a map from each watch descriptor to the processes that watch it. A
//! thread of its own reads the descriptor, as Bun's `path_watcher.rs` reads its one, and
//! sends each event to each process as `{'$buoy_fs_event', Mask, Name}`, with `nil` for an
//! event that names no entry. A process that is gone loses its watch at its next event.

// rustler decodes each argument of a NIF by value.
#![allow(clippy::needless_pass_by_value)]

use std::collections::HashMap;
use std::ffi::CString;
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd};
use std::sync::{Mutex, OnceLock};

use rustler::env::OwnedEnv;
use rustler::{Binary, Encoder, Env, LocalPid, NewBinary, Term};

rustler::atoms! { buoy_fs_event = "$buoy_fs_event", nil }

/// libuv's mask: `IN_ATTRIB` and `IN_MODIFY` report a change, and the rest a rename.
const MASK: u32 = libc::IN_ATTRIB
    | libc::IN_CREATE
    | libc::IN_MODIFY
    | libc::IN_DELETE
    | libc::IN_DELETE_SELF
    | libc::IN_MOVE_SELF
    | libc::IN_MOVED_FROM
    | libc::IN_MOVED_TO;

/// The size of `struct inotify_event` before its name.
const HEADER: usize = 16;

struct Inotify {
    file: File,
    watchers: Mutex<HashMap<i32, Vec<LocalPid>>>,
}

static INOTIFY: OnceLock<Result<Inotify, i64>> = OnceLock::new();

fn errno_of(error: &io::Error) -> i64 {
    -i64::from(error.raw_os_error().unwrap_or(libc::EINVAL))
}

fn errno() -> i64 {
    errno_of(&io::Error::last_os_error())
}

fn inotify() -> Result<&'static Inotify, i64> {
    INOTIFY
        .get_or_init(|| {
            // SAFETY: inotify_init1 takes flags only.
            #[allow(unsafe_code)]
            let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
            if fd < 0 {
                return Err(errno());
            }
            // SAFETY: fd is a new descriptor that nothing else owns.
            #[allow(unsafe_code)]
            let file = unsafe { File::from_raw_fd(fd) };
            let reader = file.try_clone().map_err(|error| errno_of(&error))?;
            std::thread::Builder::new()
                .name("buoy-inotify".to_owned())
                .spawn(move || read_events(&reader))
                .map_err(|error| errno_of(&error))?;
            Ok(Inotify {
                file,
                watchers: Mutex::new(HashMap::new()),
            })
        })
        .as_ref()
        .map_err(|&code| code)
}

/// The reader thread: each read gives whole events. An event follows a watch, which
/// follows the initialization, so `INOTIFY` is set once a read returns.
fn read_events(mut reader: &File) {
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut env = OwnedEnv::new();
    loop {
        let filled = match reader.read(&mut buffer) {
            Ok(filled) => filled,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        };
        let Some(Ok(inotify)) = INOTIFY.get() else {
            continue;
        };
        let mut watchers = inotify
            .watchers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut at = 0;
        while at + HEADER <= filled {
            let word = |offset: usize| {
                let bytes = &buffer[at + offset..at + offset + 4];
                u32::from_ne_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
            };
            let wd = i32::from_ne_bytes(word(0).to_ne_bytes());
            let mask = word(4);
            let len = word(12) as usize;
            let name = &buffer[at + HEADER..(at + HEADER + len).min(filled)];
            let name = &name[..name
                .iter()
                .position(|&byte| byte == 0)
                .unwrap_or(name.len())];
            at += HEADER + len;
            if let Some(pids) = watchers.get_mut(&wd) {
                pids.retain(|pid| {
                    env.send_and_clear(pid, |env| message(env, mask, name))
                        .is_ok()
                });
                if pids.is_empty() {
                    watchers.remove(&wd);
                    remove_watch(inotify, wd);
                }
            }
        }
    }
}

fn message<'a>(env: Env<'a>, mask: u32, name: &[u8]) -> Term<'a> {
    let name = if name.is_empty() {
        nil().encode(env)
    } else {
        NewBinary::from_slice(env, name).into()
    };
    (buoy_fs_event(), mask, name).encode(env)
}

fn remove_watch(inotify: &Inotify, wd: i32) {
    // SAFETY: inotify_rm_watch takes two integers; a stale wd gives EINVAL.
    #[allow(unsafe_code)]
    unsafe {
        libc::inotify_rm_watch(inotify.file.as_raw_fd(), wd);
    }
}

/// Watches the path for the calling process: the watch descriptor, or the negative errno.
#[rustler::nif(schedule = "DirtyIo")]
fn fs_watch(env: Env, path: Binary) -> Result<i32, i64> {
    let inotify = inotify()?;
    let path = CString::new(path.as_slice()).map_err(|_| -i64::from(libc::EINVAL))?;
    let mut watchers = inotify
        .watchers
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    // SAFETY: path is a C string.
    #[allow(unsafe_code)]
    let wd = unsafe { libc::inotify_add_watch(inotify.file.as_raw_fd(), path.as_ptr(), MASK) };
    if wd < 0 {
        return Err(errno());
    }
    watchers.entry(wd).or_default().push(env.pid());
    Ok(wd)
}

/// Ends the watch of the calling process; the last one out removes the watch descriptor.
#[rustler::nif]
fn fs_unwatch(env: Env, wd: i32) -> bool {
    let Ok(inotify) = inotify() else { return false };
    let mut watchers = inotify
        .watchers
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Some(pids) = watchers.get_mut(&wd) else {
        return false;
    };
    let caller = env.pid();
    pids.retain(|pid| *pid != caller);
    if pids.is_empty() {
        watchers.remove(&wd);
        remove_watch(inotify, wd);
    }
    true
}
