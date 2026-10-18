//! `buoy --buoy-exec`: the last step of a child process that the runtime starts. The
//! runtime's shell wires the stdio descriptors and then execs this binary, which sets what
//! a shell cannot set exactly, as libuv's `uv_spawn` does in its child: the whole
//! environment, `argv[0]`, the user and the group, and a new session for a detached
//! child. It then execs the file, so the child keeps this process id.
//!
//! The arguments: the options (`-`, or a comma list of `detached`, `uid=<n>`, and
//! `gid=<n>`), `argv[0]`, the file, the count of environment pairs, each pair as
//! `NAME=value`, and the arguments of the child.

use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::process::CommandExt as _;
use std::process::{Command, ExitCode};

/// The exit status of a child that this step could not exec, as a shell gives it.
const NOT_EXECUTED: u8 = 127;

pub fn exec(arguments: &[OsString]) -> ExitCode {
    let [options, argv0, file, count, rest @ ..] = arguments else {
        return failed("--buoy-exec takes options, argv0, a file, and an environment");
    };
    let Some(count) = count.to_str().and_then(|text| text.parse::<usize>().ok()) else {
        return failed("--buoy-exec takes the count of the environment pairs");
    };
    let Some((pairs, args)) = rest.split_at_checked(count) else {
        return failed("--buoy-exec has fewer environment pairs than its count");
    };
    let mut command = Command::new(file);
    command
        .arg0(argv0)
        .args(args)
        .env_clear()
        .envs(pairs.iter().map(|pair| split_pair(pair)));
    for option in options.to_string_lossy().split(',') {
        match option.split_once('=') {
            Some(("uid", id)) => match id.parse() {
                Ok(uid) => {
                    command.uid(uid);
                }
                Err(_) => return failed(&format!("--buoy-exec: bad uid {id}")),
            },
            Some(("gid", id)) => match id.parse() {
                Ok(gid) => {
                    command.gid(gid);
                }
                Err(_) => return failed(&format!("--buoy-exec: bad gid {id}")),
            },
            // setsid(2), as uv_spawn does for UV_PROCESS_DETACHED. erl_child_setup starts
            // each port program in a session of its own already, where setsid fails.
            None if option == "detached" => {
                let leader = nix::unistd::getsid(None).ok() == Some(nix::unistd::getpid());
                if !leader && let Err(error) = nix::unistd::setsid() {
                    return failed(&format!("setsid: {error}"));
                }
            }
            _ => {}
        }
    }
    let error = command.exec();
    failed(&format!("{}: {error}", file.to_string_lossy()))
}

/// `NAME=value` as libuv passes it to execve: the name ends at the first `=`.
fn split_pair(pair: &OsStr) -> (&OsStr, &OsStr) {
    let bytes = pair.as_bytes();
    match bytes.iter().position(|&byte| byte == b'=') {
        Some(at) => (
            OsStr::from_bytes(&bytes[..at]),
            OsStr::from_bytes(&bytes[at + 1..]),
        ),
        None => (pair, OsStr::new("")),
    }
}

fn failed(message: &str) -> ExitCode {
    eprintln!("buoy: {message}");
    ExitCode::from(NOT_EXECUTED)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_a_pair_at_the_first_equals_sign() {
        assert_eq!(
            split_pair(OsStr::new("A=b=c")),
            (OsStr::new("A"), OsStr::new("b=c"))
        );
        assert_eq!(
            split_pair(OsStr::new("EMPTY=")),
            (OsStr::new("EMPTY"), OsStr::new(""))
        );
    }
}
