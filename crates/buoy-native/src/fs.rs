//! The file system calls of `internalBinding('fs')` that ERTS lacks, as libuv's
//! `src/unix/fs.c` makes them: stat with nanosecond times, the birth time, and the block
//! counts; readdir with the type of each entry from the directory itself; utimes with
//! sub-second times; the calls that change a symlink itself; access; and statfs. Each NIF
//! runs on a dirty I/O scheduler, as `prim_file` runs its calls, and fails with the negative
//! errno of the OS, as a libuv request does.

// rustler decodes each argument of a NIF by value.
#![allow(clippy::needless_pass_by_value)]

use std::ffi::{CString, OsStr};
use std::fs::{File, Metadata, Permissions};
use std::io;
use std::mem::ManuallyDrop;
use std::os::fd::{BorrowedFd, FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::Path;
use std::time::UNIX_EPOCH;

use rustler::{Binary, Env, NewBinary, Term};

/// `PlatformInit` of Node's `src/node.cc` ignores SIGXFSZ, so a write past `RLIMIT_FSIZE`
/// fails with EFBIG instead of ending the VM. The VM's port spawner started before this
/// ran, so child processes keep the default action, as libuv resets it in a child.
pub fn ignore_file_size_signal() {
    // SAFETY: SIG_IGN is a valid disposition for SIGXFSZ.
    #[allow(unsafe_code)]
    unsafe {
        libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
    }
}

/// A call's result: the value, or the negative errno.
type Outcome<T> = Result<T, i64>;

fn errno(error: &io::Error) -> i64 {
    -i64::from(error.raw_os_error().unwrap_or(libc::EINVAL))
}

fn last_errno() -> i64 {
    errno(&io::Error::last_os_error())
}

/// 0, or the negative errno, as libuv returns a request's result.
fn code(result: io::Result<()>) -> i64 {
    result.map_or_else(|error| errno(&error), |()| 0)
}

fn path<'a>(bytes: &'a Binary) -> &'a Path {
    Path::new(OsStr::from_bytes(bytes.as_slice()))
}

fn c_path(bytes: &Binary) -> Outcome<CString> {
    CString::new(bytes.as_slice()).map_err(|_| -i64::from(libc::EINVAL))
}

/// A descriptor that the realm owns, borrowed for one call.
fn borrowed(fd: RawFd) -> ManuallyDrop<File> {
    // SAFETY: the realm keeps fd open for the call, and ManuallyDrop never closes it.
    #[allow(unsafe_code)]
    ManuallyDrop::new(unsafe { File::from_raw_fd(fd) })
}

/// Node's stat fields: dev, mode, nlink, uid, gid, rdev, blksize, ino, size, blocks, and the
/// seconds and nanoseconds of atime, mtime, ctime, and birthtime. A file system without a
/// birth time gives 0, as libuv's statx does.
#[allow(clippy::cast_possible_wrap)]
fn fields(meta: &Metadata) -> Vec<i64> {
    let (birth, birth_nsec) = meta
        .created()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or((0, 0), |since| {
            (since.as_secs() as i64, i64::from(since.subsec_nanos()))
        });
    vec![
        meta.dev() as i64,
        i64::from(meta.mode()),
        meta.nlink() as i64,
        i64::from(meta.uid()),
        i64::from(meta.gid()),
        meta.rdev() as i64,
        meta.blksize() as i64,
        meta.ino() as i64,
        meta.size() as i64,
        meta.blocks() as i64,
        meta.atime(),
        meta.atime_nsec(),
        meta.mtime(),
        meta.mtime_nsec(),
        meta.ctime(),
        meta.ctime_nsec(),
        birth,
        birth_nsec,
    ]
}

/// stat(2), or lstat(2) when `follow` is false.
#[rustler::nif(schedule = "DirtyIo")]
fn fs_stat(target: Binary, follow: bool) -> Outcome<Vec<i64>> {
    let meta = if follow {
        std::fs::metadata(path(&target))
    } else {
        std::fs::symlink_metadata(path(&target))
    };
    meta.map(|meta| fields(&meta))
        .map_err(|error| errno(&error))
}

#[rustler::nif(schedule = "DirtyIo")]
fn fs_fstat(fd: RawFd) -> Outcome<Vec<i64>> {
    borrowed(fd)
        .metadata()
        .map(|meta| fields(&meta))
        .map_err(|error| errno(&error))
}

/// The `UV_DIRENT_*` type of an entry: the type that the directory holds, as getdents(2)
/// gives it, or the lstat of the entry where the file system gives none. An entry that is
/// gone by then is `UV_DIRENT_UNKNOWN`.
fn dirent_type(entry: &std::fs::DirEntry) -> u8 {
    entry.file_type().map_or(0, |kind| {
        [
            kind.is_file(),
            kind.is_dir(),
            kind.is_symlink(),
            kind.is_fifo(),
            kind.is_socket(),
            kind.is_char_device(),
            kind.is_block_device(),
        ]
        .iter()
        .position(|&is| is)
        .map_or(0, |index| u8::try_from(index + 1).unwrap_or(0))
    })
}

/// scandir: the names and the types of the entries in the order of the directory,
/// without `.` and `..`.
#[rustler::nif(schedule = "DirtyIo")]
fn fs_readdir<'a>(env: Env<'a>, target: Binary) -> Outcome<Vec<(Term<'a>, u8)>> {
    let entries = std::fs::read_dir(path(&target)).map_err(|error| errno(&error))?;
    entries
        .map(|entry| {
            let entry = entry.map_err(|error| errno(&error))?;
            let name = NewBinary::from_slice(env, entry.file_name().as_bytes()).into();
            Ok((name, dirent_type(&entry)))
        })
        .collect()
}

/// `uv__fs_to_timespec`: infinity is now, NaN leaves the time, and a time keeps whole
/// microseconds, as libuv keeps them on every platform.
#[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
fn timespec(time: Term) -> libc::timespec {
    let (seconds, nanoseconds) = match time
        .decode::<f64>()
        .or_else(|_| time.decode::<i64>().map(|n| n as f64))
    {
        Ok(time) if time.is_finite() => {
            let whole = time.trunc();
            let mut nsec = ((time - whole) * 1e9) as libc::c_long;
            nsec -= nsec % 1000;
            if nsec < 0 {
                (whole as libc::time_t - 1, nsec + 1_000_000_000)
            } else {
                (whole as libc::time_t, nsec)
            }
        }
        _ if time.atom_to_string().is_ok_and(|name| name == "NaN") => (0, libc::UTIME_OMIT),
        _ => (0, libc::UTIME_NOW),
    };
    libc::timespec {
        tv_sec: seconds,
        tv_nsec: nanoseconds,
    }
}

/// utimensat(2), on the symlink itself when `follow` is false.
#[rustler::nif(schedule = "DirtyIo")]
fn fs_utimes(target: Binary, atime: Term, mtime: Term, follow: bool) -> i64 {
    let times = [timespec(atime), timespec(mtime)];
    let flags = if follow { 0 } else { libc::AT_SYMLINK_NOFOLLOW };
    c_path(&target).map_or_else(
        |code| code,
        |target| {
            // SAFETY: target is a C string and times holds two timespecs.
            #[allow(unsafe_code)]
            let status =
                unsafe { libc::utimensat(libc::AT_FDCWD, target.as_ptr(), times.as_ptr(), flags) };
            if status == 0 { 0 } else { last_errno() }
        },
    )
}

#[rustler::nif(schedule = "DirtyIo")]
fn fs_futimes(fd: RawFd, atime: Term, mtime: Term) -> i64 {
    let times = [timespec(atime), timespec(mtime)];
    // SAFETY: times holds two timespecs.
    #[allow(unsafe_code)]
    let status = unsafe { libc::futimens(fd, times.as_ptr()) };
    if status == 0 { 0 } else { last_errno() }
}

/// chmod(2), or lchmod(3) when `follow` is false.
#[rustler::nif(schedule = "DirtyIo")]
#[allow(clippy::cast_possible_truncation)]
fn fs_chmod(target: Binary, mode: u32, follow: bool) -> i64 {
    if follow {
        return code(std::fs::set_permissions(
            path(&target),
            Permissions::from_mode(mode),
        ));
    }
    c_path(&target).map_or_else(
        |code| code,
        |target| {
            // SAFETY: target is a C string.
            #[allow(unsafe_code)]
            let status = unsafe {
                libc::fchmodat(
                    libc::AT_FDCWD,
                    target.as_ptr(),
                    mode as libc::mode_t,
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            };
            if status == 0 { 0 } else { last_errno() }
        },
    )
}

#[rustler::nif(schedule = "DirtyIo")]
fn fs_fchmod(fd: RawFd, mode: u32) -> i64 {
    code(borrowed(fd).set_permissions(Permissions::from_mode(mode)))
}

/// -1 keeps the owner or the group, as chown(2) reads `(uid_t) -1`.
fn id(value: i64) -> Option<u32> {
    u32::try_from(value).ok().filter(|&id| id != u32::MAX)
}

/// chown(2), or lchown(2) when `follow` is false.
#[rustler::nif(schedule = "DirtyIo")]
fn fs_chown(target: Binary, uid: i64, gid: i64, follow: bool) -> i64 {
    let change = if follow {
        std::os::unix::fs::chown
    } else {
        std::os::unix::fs::lchown
    };
    code(change(path(&target), id(uid), id(gid)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn fs_fchown(fd: RawFd, uid: i64, gid: i64) -> i64 {
    // SAFETY: the realm keeps fd open for the call.
    #[allow(unsafe_code)]
    let fd = unsafe { BorrowedFd::borrow_raw(fd) };
    code(std::os::unix::fs::fchown(fd, id(uid), id(gid)))
}

/// access(2) with the mode bits of `R_OK`, `W_OK`, and `X_OK`.
#[rustler::nif(schedule = "DirtyIo")]
fn fs_access(target: Binary, mode: i32) -> i64 {
    c_path(&target).map_or_else(
        |code| code,
        |target| {
            // SAFETY: target is a C string.
            #[allow(unsafe_code)]
            let status = unsafe { libc::access(target.as_ptr(), mode) };
            if status == 0 { 0 } else { last_errno() }
        },
    )
}

/// statfs(2): type, bsize, blocks, bfree, bavail, files, and ffree.
#[rustler::nif(schedule = "DirtyIo")]
#[allow(
    clippy::cast_possible_wrap,
    clippy::unnecessary_cast,
    clippy::cast_lossless
)]
fn fs_statfs(target: Binary) -> Outcome<Vec<i64>> {
    let target = c_path(&target)?;
    // SAFETY: statfs fills the zeroed struct, and target is a C string.
    #[allow(unsafe_code)]
    let (status, buf) = unsafe {
        let mut buf: libc::statfs = std::mem::zeroed();
        (libc::statfs(target.as_ptr(), &raw mut buf), buf)
    };
    if status != 0 {
        return Err(last_errno());
    }
    Ok(vec![
        buf.f_type as i64,
        buf.f_bsize as i64,
        buf.f_blocks as i64,
        buf.f_bfree as i64,
        buf.f_bavail as i64,
        buf.f_files as i64,
        buf.f_ffree as i64,
    ])
}
