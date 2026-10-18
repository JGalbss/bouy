//! The compiler in child processes of `buoy-suites compile-worker`, each held for many
//! compiles. A compile that hangs, panics, or overflows its stack becomes the crash of one
//! test, and the run goes on.

use std::io::{self, BufRead, BufReader, Write};
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Mutex, PoisonError};
use std::thread;
use std::time::Duration;

use buoy_compiler::{Code, Goal};
use serde::{Deserialize, Serialize};

/// The stack of the thread that compiles. The compiler recurses over the syntax tree, and
/// some tests nest deeply.
const STACK_BYTES: usize = 256 << 20;

/// What a diagnostic means to the runner of negative tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Kind {
    /// BUOY200: the program is not valid JavaScript.
    Syntax,
    /// An import of a name that the module does not export.
    MissingExport,
    Other,
}

/// One diagnostic: its code, the file that it names, and its kind.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Found {
    pub code: String,
    pub path: PathBuf,
    pub kind: Kind,
}

/// The compile of one source file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Compile {
    Clean,
    Diagnostics(Vec<Found>),
    /// A Buoy bug: the compiler panicked, ran past the deadline, or ended its process.
    Bug(String),
}

#[derive(Debug, Serialize, Deserialize)]
struct Request {
    path: PathBuf,
    root: PathBuf,
    module: bool,
}

/// The compile workers that are free, started on demand.
#[derive(Debug)]
pub struct Compilers {
    binary: PathBuf,
    deadline: Duration,
    idle: Mutex<Vec<Worker>>,
}

#[derive(Debug)]
struct Worker {
    child: Child,
    stdin: ChildStdin,
    replies: Receiver<String>,
}

impl Compilers {
    /// Workers that run `binary compile-worker`, and stop a compile after `deadline`.
    pub fn new(binary: PathBuf, deadline: Duration) -> Self {
        Self {
            binary,
            deadline,
            idle: Mutex::new(Vec::new()),
        }
    }

    /// Compiles the program at `path`, naming modules from `root`, as a script or as a
    /// module.
    pub fn compile(&self, path: &Path, root: &Path, module: bool) -> Compile {
        let free = self
            .idle
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop();
        let mut worker = match free.map_or_else(|| Worker::start(&self.binary), Ok) {
            Ok(worker) => worker,
            Err(error) => return Compile::Bug(error),
        };
        let request = Request {
            path: path.to_path_buf(),
            root: root.to_path_buf(),
            module,
        };
        let line = serde_json::to_string(&request).unwrap_or_default();
        if writeln!(worker.stdin, "{line}").is_err() {
            return Compile::Bug(format!("the compiler process ended: {}", worker.stop()));
        }
        match worker.replies.recv_timeout(self.deadline) {
            Ok(reply) => {
                self.idle
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(worker);
                serde_json::from_str(&reply)
                    .unwrap_or_else(|error| Compile::Bug(format!("a bad compiler reply: {error}")))
            }
            Err(RecvTimeoutError::Timeout) => {
                let _ = worker.stop();
                Compile::Bug(format!(
                    "the compiler ran past the deadline of {:?}",
                    self.deadline
                ))
            }
            Err(RecvTimeoutError::Disconnected) => {
                Compile::Bug(format!("the compiler process ended: {}", worker.stop()))
            }
        }
    }
}

impl Worker {
    fn start(binary: &Path) -> Result<Self, String> {
        let mut child = Command::new(binary)
            .arg("compile-worker")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| format!("cannot start {}: {error}", binary.display()))?;
        let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            return Err("the compiler process has no pipes".to_owned());
        };
        let (send, replies) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if send.send(line).is_err() {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            stdin,
            replies,
        })
    }

    /// Kills the process and returns how it ended.
    fn stop(mut self) -> String {
        let _ = self.child.kill();
        self.child
            .wait()
            .map_or_else(|error| error.to_string(), |status| status.to_string())
    }
}

/// The loop of `buoy-suites compile-worker`: one request per line of stdin, one reply per
/// line of stdout, until stdin closes.
pub fn serve() {
    // The reply carries the message of a panic.
    panic::set_hook(Box::new(|_| {}));
    let served = thread::Builder::new().stack_size(STACK_BYTES).spawn(|| {
        let mut stdout = io::stdout();
        for line in io::stdin().lock().lines().map_while(Result::ok) {
            let reply = match serde_json::from_str::<Request>(&line) {
                Ok(request) => compile_here(&request),
                Err(error) => Compile::Bug(format!("a bad compile request: {error}")),
            };
            let reply = serde_json::to_string(&reply).unwrap_or_default();
            if writeln!(stdout, "{reply}")
                .and_then(|()| stdout.flush())
                .is_err()
            {
                break;
            }
        }
    });
    if let Ok(served) = served {
        let _ = served.join();
    }
}

fn compile_here(request: &Request) -> Compile {
    let goal = if request.module {
        Goal::Module
    } else {
        Goal::Script
    };
    let compiled = panic::catch_unwind(AssertUnwindSafe(|| {
        buoy_compiler::compile_goal(&request.path, &request.root, goal)
    }));
    match compiled {
        Ok(Ok(_)) => Compile::Clean,
        Ok(Err(diagnostics)) => Compile::Diagnostics(
            diagnostics
                .into_iter()
                .map(|diagnostic| Found {
                    code: diagnostic.code.as_str().to_owned(),
                    kind: match diagnostic.code {
                        Code::Syntax => Kind::Syntax,
                        Code::MissingExport => Kind::MissingExport,
                        _ => Kind::Other,
                    },
                    path: diagnostic.path,
                })
                .collect(),
        ),
        Err(payload) => Compile::Bug(format!(
            "the compiler panicked: {}",
            payload
                .downcast_ref::<String>()
                .map(String::as_str)
                .or_else(|| payload.downcast_ref::<&str>().copied())
                .unwrap_or("no message")
        )),
    }
}
