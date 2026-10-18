//! The facts that a result depends on: the host, the tool versions, and the load of the
//! machine.

use std::env;
use std::ffi::OsStr;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::thread;

use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct Host {
    /// The name in the results file: `--host`, or else the CPU model as a slug.
    pub name: String,
    pub cpu: String,
    pub cores: usize,
    pub os: String,
}

#[derive(Debug, Serialize)]
pub struct Tools {
    /// `git describe` of the repository, with `-dirty` for uncommitted changes.
    pub commit: String,
    pub buoy: String,
    pub otp: String,
    pub node: String,
    pub bun: String,
}

/// Prints the full OTP release, such as `29.0.1`, and the ERTS version.
const OTP_VERSION: &str = r#"{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:format("~s (erts ~s)", [string:trim(V), erlang:system_info(version)]), halt()."#;

pub fn host(name: Option<String>) -> Host {
    let cpu = cpu_model();
    Host {
        name: name.unwrap_or_else(|| slug(&cpu)),
        cores: thread::available_parallelism().map_or(0, usize::from),
        os: output("uname", &["-srm"]),
        cpu,
    }
}

pub fn tools(buoy: &Path, node: &Path, bun: &Path, repository: &Path) -> Tools {
    let erl = env::var_os("BUOY_ERL").unwrap_or_else(|| "erl".into());
    Tools {
        commit: output(
            "git",
            &[
                OsStr::new("-C"),
                repository.as_os_str(),
                OsStr::new("describe"),
                OsStr::new("--always"),
                OsStr::new("--dirty"),
            ],
        ),
        buoy: output(buoy, &["--version"]),
        otp: output(erl, &["-noshell", "-eval", OTP_VERSION]),
        node: output(node, &["--version"]),
        bun: output(bun, &["--version"]),
    }
}

/// The load average over 1, 5, and 15 minutes, or zeros when the platform hides it.
pub fn load_average() -> [f64; 3] {
    let text = fs::read_to_string("/proc/loadavg")
        .unwrap_or_else(|_| output("sysctl", &["-n", "vm.loadavg"]));
    parse_load(&text)
}

/// The UTC date as `YYYY-MM-DD`.
pub fn today() -> String {
    output("date", &["-u", "+%F"])
}

/// Reads the first three numbers of `/proc/loadavg` (`0.52 0.58 0.59 1/467 3214`) or of
/// the macOS `vm.loadavg` (`{ 0.52 0.58 0.59 }`).
fn parse_load(text: &str) -> [f64; 3] {
    let mut numbers = text.split_whitespace().filter_map(|word| word.parse().ok());
    [numbers.next(), numbers.next(), numbers.next()].map(|number| number.unwrap_or(0.0))
}

fn cpu_model() -> String {
    let linux = fs::read_to_string("/proc/cpuinfo").ok().and_then(|info| {
        info.lines()
            .find_map(|line| line.strip_prefix("model name"))
            .and_then(|rest| rest.split_once(':'))
            .map(|(_, model)| model.trim().to_owned())
    });
    linux.unwrap_or_else(|| output("sysctl", &["-n", "machdep.cpu.brand_string"]))
}

/// `Apple M5 Pro` becomes `apple-m5-pro`.
fn slug(text: &str) -> String {
    text.split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(str::to_ascii_lowercase)
        .collect::<Vec<_>>()
        .join("-")
}

/// The trimmed standard output of a command, or `unknown` when it fails.
fn output(program: impl AsRef<OsStr>, args: &[impl AsRef<OsStr>]) -> String {
    Command::new(program)
        .args(args)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map_or_else(
            || "unknown".to_owned(),
            |output| String::from_utf8_lossy(&output.stdout).trim().to_owned(),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_both_load_formats() {
        let read = |text| format!("{:?}", parse_load(text));
        assert_eq!(read("0.52 0.58 0.59 1/467 3214\n"), "[0.52, 0.58, 0.59]");
        assert_eq!(read("{ 14.16 16.27 14.43 }\n"), "[14.16, 16.27, 14.43]");
        assert_eq!(read("unknown"), "[0.0, 0.0, 0.0]");
    }

    #[test]
    fn names_a_host_after_its_cpu() {
        assert_eq!(slug("Apple M5 Pro"), "apple-m5-pro");
        assert_eq!(
            slug("Intel(R) Xeon(R) CPU @ 2.30GHz"),
            "intel-r-xeon-r-cpu-2-30ghz"
        );
    }
}
