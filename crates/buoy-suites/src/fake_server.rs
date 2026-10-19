//! The fake model server of `runtime/test/library/buoy_fake_openai.erl` (contract section 14),
//! started once for the process. It serves the `OpenAI` and Anthropic APIs. The child keeps
//! the stdin pipe of the server open, and the server halts when the pipe closes, as this
//! process ends.

use std::fs;
use std::io::{BufRead, BufReader};
use std::process::{self, Child, Command, Stdio};
use std::sync::OnceLock;

/// The key that the server accepts.
pub const KEY: &str = "sk-fake-key";

struct Server {
    _child: Child,
    port: u16,
}

fn server() -> Result<&'static Server, String> {
    static SERVER: OnceLock<Result<Server, String>> = OnceLock::new();
    SERVER.get_or_init(start).as_ref().map_err(Clone::clone)
}

fn start() -> Result<Server, String> {
    let build = std::env::temp_dir().join(format!("buoy-fake-openai-{}", process::id()));
    fs::create_dir_all(&build).map_err(|error| format!("{}: {error}", build.display()))?;
    let compiled = Command::new("erlc")
        .arg("-o")
        .arg(&build)
        .arg(crate::repository().join("runtime/test/library/buoy_fake_openai.erl"))
        .status()
        .map_err(|error| format!("cannot run erlc: {error}"))?;
    if !compiled.success() {
        return Err("runtime/test/library/buoy_fake_openai.erl does not compile".to_owned());
    }
    let mut child = Command::new("erl")
        .arg("-noshell")
        .arg("-pa")
        .arg(&build)
        .args(["-eval", "buoy_fake_openai:main()", "-extra", "stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|error| format!("cannot start the fake server with erl: {error}"))?;
    let stdout = child.stdout.take().ok_or("the fake server has no stdout")?;
    let mut line = String::new();
    BufReader::new(stdout)
        .read_line(&mut line)
        .map_err(|error| format!("the fake server printed no port: {error}"))?;
    let port = line.trim().parse().map_err(|error| {
        format!(
            "the fake server printed `{}`, not a port: {error}",
            line.trim()
        )
    })?;
    // The server has loaded its module once it prints the port.
    let _ = fs::remove_dir_all(&build);
    Ok(Server {
        _child: child,
        port,
    })
}

/// Points `command` at the fake server: the base URLs of `OpenAI` and Anthropic, and the key.
///
/// # Errors
///
/// When the server cannot start, because erlc or erl is missing.
pub fn point(command: &mut Command) -> Result<&mut Command, String> {
    let port = server()?.port;
    Ok(command
        .env("OPENAI_BASE_URL", format!("http://127.0.0.1:{port}/v1"))
        .env("OPENAI_API_KEY", KEY)
        .env("ANTHROPIC_BASE_URL", format!("http://127.0.0.1:{port}"))
        .env("ANTHROPIC_API_KEY", KEY))
}
