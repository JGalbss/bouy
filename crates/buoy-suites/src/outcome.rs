//! The outcomes of section 3.1 of docs/design/testing.md, and `classify`, which turns the
//! facts of one execution into one outcome.

use std::collections::BTreeSet;
use std::fmt;
use std::fs;
use std::path::Path;
use std::str::FromStr;

use serde::Deserialize;

/// The outcome of one test, or of one mode of a test, in the order of the table of
/// section 3.1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Pass,
    Rejected,
    Late,
    Skip,
    Never,
    Fail,
    Timeout,
    HarnessError,
    Crash,
}

impl Outcome {
    /// Every outcome, in the order of the table of section 3.1.
    pub const ALL: [Self; 9] = [
        Self::Pass,
        Self::Rejected,
        Self::Late,
        Self::Skip,
        Self::Never,
        Self::Fail,
        Self::Timeout,
        Self::HarnessError,
        Self::Crash,
    ];

    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pass => "pass",
            Self::Rejected => "rejected",
            Self::Late => "late",
            Self::Skip => "skip",
            Self::Never => "never",
            Self::Fail => "fail",
            Self::Timeout => "timeout",
            Self::HarnessError => "harness_error",
            Self::Crash => "crash",
        }
    }

    /// 0 for a pass, 1 for a loud failure, 2 for a silent one, and 3 for a Buoy bug.
    #[must_use]
    pub fn rank(self) -> u8 {
        match self {
            Self::Pass => 0,
            Self::Rejected | Self::Late | Self::Skip | Self::Never => 1,
            Self::Fail | Self::Timeout | Self::HarnessError => 2,
            Self::Crash => 3,
        }
    }
}

impl fmt::Display for Outcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for Outcome {
    type Err = String;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|outcome| outcome.as_str() == text)
            .ok_or_else(|| format!("`{text}` is not an outcome"))
    }
}

/// What `buoy run` wrote to `BUOY_RESULT_FILE` (section 1 of the contract).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct RunResult {
    pub status: i32,
    /// The codes of the compile diagnostics, when the CLI stopped at them.
    #[serde(default)]
    pub diagnostics: Vec<String>,
    /// The JavaScript value that reached the top of the program.
    pub uncaught: Option<Uncaught>,
    /// An Erlang reason that is not a JavaScript value, or a failure of the VM around the
    /// program, such as generated Erlang that does not compile.
    pub erlang: Option<String>,
}

/// The fields of an uncaught value that tell one error from another.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct Uncaught {
    pub name: Option<String>,
    pub message: Option<String>,
    pub code: Option<String>,
    /// The Erlang reason of an error that the runtime made from one.
    pub erlang: Option<String>,
}

impl RunResult {
    /// The result that the run wrote to `path`, or `None` when it wrote none, as a VM that
    /// crashed or was killed writes none.
    #[must_use]
    pub fn read(path: &Path) -> Option<Self> {
        serde_json::from_slice(&fs::read(path).ok()?).ok()
    }

    /// What kept a run with `outcome` from passing, for the blockers table of section 6:
    /// each diagnostic code of a `rejected` run once, or the message of a `late` rejection.
    #[must_use]
    pub fn blockers(&self, outcome: Outcome) -> Vec<String> {
        match outcome {
            Outcome::Rejected => {
                let codes: BTreeSet<&String> = self.diagnostics.iter().collect();
                codes.into_iter().cloned().collect()
            }
            Outcome::Late => self
                .uncaught
                .as_ref()
                .and_then(|uncaught| uncaught.message.clone())
                .into_iter()
                .collect(),
            _ => Vec::new(),
        }
    }
}

/// The facts of one execution that `classify` reads.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Facts {
    /// The diagnostic codes of the compiler for the test or a harness file that it includes.
    pub diagnostics: Vec<String>,
    /// A Buoy bug: a compiler panic, a run that wrote no result, or an Erlang reason that
    /// reached the program.
    pub bug: Option<String>,
    pub timed_out: bool,
    pub uncaught: Option<Uncaught>,
    /// A harness file compiled and then threw, so the test never started.
    pub harness_threw: bool,
    /// The result equals the Node result, or the test's own check passed.
    pub passed: bool,
}

impl Facts {
    /// The facts of a `buoy run` that wrote `result`, or nothing. `passed` is the check of
    /// the suite: the Node output, or the rule of the upstream test.
    #[must_use]
    pub fn of_run(result: Option<&RunResult>, timed_out: bool, passed: bool) -> Self {
        if timed_out {
            return Self {
                timed_out,
                ..Self::default()
            };
        }
        let Some(result) = result else {
            return Self {
                bug: Some("the run ended and wrote no result".to_owned()),
                ..Self::default()
            };
        };
        let uncaught_reason = result
            .uncaught
            .as_ref()
            .and_then(|uncaught| uncaught.erlang.clone());
        Self {
            diagnostics: result.diagnostics.clone(),
            bug: result.erlang.clone().or(uncaught_reason),
            uncaught: result.uncaught.clone(),
            passed,
            ..Self::default()
        }
    }
}

/// The one outcome that the facts show. A bug outranks every other fact, and a late
/// rejection outranks a pass, because a run that stopped at a missing feature proves
/// nothing.
#[must_use]
pub fn classify(facts: &Facts) -> Outcome {
    if facts.bug.is_some() {
        return Outcome::Crash;
    }
    if !facts.diagnostics.is_empty() {
        return Outcome::Rejected;
    }
    if facts.timed_out {
        return Outcome::Timeout;
    }
    if facts.uncaught.as_ref().is_some_and(|uncaught| {
        uncaught.name.as_deref() == Some("TypeError")
            && uncaught.code.as_deref() == Some("ERR_BUOY_UNSUPPORTED")
    }) {
        return Outcome::Late;
    }
    if facts.harness_threw {
        return Outcome::HarnessError;
    }
    if facts.passed {
        return Outcome::Pass;
    }
    Outcome::Fail
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uncaught(name: &str, code: Option<&str>) -> Uncaught {
        Uncaught {
            name: Some(name.to_owned()),
            code: code.map(str::to_owned),
            ..Uncaught::default()
        }
    }

    #[test]
    fn each_fact_gives_its_outcome() {
        let cases = [
            (Facts::default(), Outcome::Fail),
            (
                Facts {
                    passed: true,
                    ..Facts::default()
                },
                Outcome::Pass,
            ),
            (
                Facts {
                    diagnostics: vec!["BUOY206".to_owned()],
                    ..Facts::default()
                },
                Outcome::Rejected,
            ),
            (
                Facts {
                    uncaught: Some(uncaught("TypeError", Some("ERR_BUOY_UNSUPPORTED"))),
                    passed: true,
                    ..Facts::default()
                },
                Outcome::Late,
            ),
            (
                Facts {
                    uncaught: Some(uncaught("TypeError", None)),
                    ..Facts::default()
                },
                Outcome::Fail,
            ),
            (
                Facts {
                    harness_threw: true,
                    ..Facts::default()
                },
                Outcome::HarnessError,
            ),
            (Facts::of_run(None, true, false), Outcome::Timeout),
            (Facts::of_run(None, false, true), Outcome::Crash),
        ];
        for (facts, outcome) in cases {
            assert_eq!(classify(&facts), outcome, "{facts:?}");
        }
    }

    #[test]
    fn an_erlang_reason_in_the_result_is_a_crash() {
        let result: RunResult = serde_json::from_str(
            r#"{"status":1,"uncaught":{"name":"TypeError","message":"bad argument","erlang":"badarg"}}"#,
        )
        .expect("the result parses");
        assert_eq!(
            classify(&Facts::of_run(Some(&result), false, false)),
            Outcome::Crash
        );
        let rejected: RunResult = serde_json::from_str(r#"{"status":2,"diagnostics":["BUOY201"]}"#)
            .expect("the result parses");
        assert_eq!(
            classify(&Facts::of_run(Some(&rejected), false, false)),
            Outcome::Rejected
        );
    }

    #[test]
    fn outcomes_read_back_from_their_names() {
        for outcome in Outcome::ALL {
            assert_eq!(outcome.as_str().parse::<Outcome>(), Ok(outcome));
        }
    }
}
