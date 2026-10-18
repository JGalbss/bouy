//! The rules of the test layout that section 7 of docs/design/testing.md checks in
//! `pnpm check`. Rules 4 and 5 land with the phases that create their files.

use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

/// The directories and files that no rule reads: version control, builds, caches, installed
/// packages, and the worktrees of agents.
const SKIPPED: [&str; 8] = [
    ".git",
    ".buoy",
    ".claude",
    ".turbo",
    ".DS_Store",
    "_build",
    "node_modules",
    "target",
];

/// The vendored upstream trees. Rule 7 keeps them byte-identical, so no rule reads their
/// code, and the `node` shim stops any call to node at run time.
const UPSTREAM: [&str; 2] = ["tests/node/test/", "runtime/vendor/node/"];

/// The files that may name node as a program: the oracle tools, the test that checks that
/// the `node` shim answers, and this file, which names the patterns.
const ORACLE_TOOLS: [&str; 7] = [
    "scripts/freeze-expectations.sh",
    "bench/reference/",
    "scripts/node-surface.sh",
    "crates/buoy-bench/",
    "crates/buoy-fuzz/",
    "crates/buoy-cli/tests/harness.rs",
    "crates/buoy-suites/tests/rules.rs",
];

/// A call that starts the program `node`, such as `Command::new("node")` or
/// `spawn("node", args)`.
const NODE_CALLS: [&str; 6] = [
    "(\"node\"",
    "(\"node ",
    "('node'",
    "('node ",
    "(`node`",
    "(`node ",
];

/// A shell line that runs `node` after an operator or a keyword.
const NODE_COMMANDS: [&str; 8] = [
    "| node ",
    "&& node ",
    "; node ",
    "$(node ",
    "`node ",
    "exec node ",
    "then node ",
    "run: node ",
];

fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// The files under `root/relative` outside `SKIPPED`, as paths relative to `root` with `/`,
/// sorted by bytes.
fn files(root: &Path, relative: &str) -> Vec<String> {
    files_except(root, relative, &SKIPPED)
}

/// The files under `root/relative` apart from the names of `skipped`, as paths relative to
/// `root` with `/`, sorted by bytes. A symbolic link is no file.
fn files_except(root: &Path, relative: &str, skipped: &[&str]) -> Vec<String> {
    let mut found = Vec::new();
    let mut directories = vec![relative.to_owned()];
    while let Some(directory) = directories.pop() {
        let entries = fs::read_dir(root.join(&directory))
            .unwrap_or_else(|error| panic!("{directory}: {error}"));
        for entry in entries.filter_map(Result::ok) {
            let name = entry.file_name().to_string_lossy().into_owned();
            if skipped.contains(&name.as_str())
                || entry.file_type().is_ok_and(|kind| kind.is_symlink())
            {
                continue;
            }
            let path = if directory.is_empty() {
                name
            } else {
                format!("{directory}/{name}")
            };
            if entry.path().is_dir() {
                directories.push(path);
            } else {
                found.push(path);
            }
        }
    }
    found.sort();
    found
}

/// Rule 1: each name in `tests/regressions` is an issue number with no zero padding:
/// `<issue>.ts`, its recorded output, or a directory `<issue>/`.
#[test]
fn regressions_are_named_after_their_issue() {
    let Ok(entries) = fs::read_dir(repository().join("tests/regressions")) else {
        return;
    };
    let wrong: Vec<String> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name != "README.md" && !is_issue_number(name.split('.').next()))
        .collect();
    assert!(
        wrong.is_empty(),
        "these names in tests/regressions are not issue numbers: {wrong:?}"
    );
}

fn is_issue_number(stem: Option<&str>) -> bool {
    stem.is_some_and(|stem| {
        !stem.is_empty() && !stem.starts_with('0') && stem.bytes().all(|byte| byte.is_ascii_digit())
    })
}

/// Rule 1: each name in `tests/fuzz` is a seed: `<generator>/<seed>.ts` and its recorded
/// output, with no zero padding, next to `expectations.txt`.
#[test]
fn fuzz_cases_are_named_after_their_seed() {
    let root = repository();
    if !root.join("tests/fuzz").is_dir() {
        return;
    }
    let wrong: Vec<String> = files(&root, "tests/fuzz")
        .into_iter()
        .filter(|path| path != "tests/fuzz/expectations.txt")
        .filter(|path| {
            let [_, _, _, name] = path.split('/').collect::<Vec<_>>()[..] else {
                return true;
            };
            let (seed, extension) = name.split_once('.').unwrap_or((name, ""));
            let is_seed = seed == "0" || is_issue_number(Some(seed));
            !(is_seed && matches!(extension, "ts" | "stdout" | "status"))
        })
        .collect();
    assert!(
        wrong.is_empty(),
        "these names in tests/fuzz are not `<generator>/<seed>.ts` or its output: {wrong:?}"
    );
}

/// Rule 3: `tests/migration/before` matches `before.sha256`, so nobody can make the migration
/// test pass by changing the fixture. After a reviewed change to the fixture, write the file
/// from `tests/migration` with
/// `find before -type f ! -name .DS_Store ! -path '*/.buoy/*' | LC_ALL=C sort | xargs shasum -a 256 > before.sha256`.
#[test]
fn the_migration_fixture_matches_its_hash() {
    let migration = repository().join("tests/migration");
    let recorded = fs::read_to_string(migration.join("before.sha256"))
        .expect("tests/migration/before.sha256 exists");
    let actual = files(&migration, "before")
        .iter()
        .fold(String::new(), |mut manifest, file| {
            let _ = writeln!(manifest, "{}  {file}", sha256(&migration.join(file)));
            manifest
        });
    let changed: Vec<&str> = actual
        .lines()
        .filter(|line| !recorded.lines().any(|kept| kept == *line))
        .chain(
            recorded
                .lines()
                .filter(|line| !actual.lines().any(|now| now == *line)),
        )
        .collect();
    assert!(
        changed.is_empty(),
        "tests/migration/before differs from tests/migration/before.sha256 in these lines:\n{}",
        changed.join("\n")
    );
}

fn sha256(path: &Path) -> String {
    let digest = Sha256::digest(
        fs::read(path).unwrap_or_else(|error| panic!("{}: {error}", path.display())),
    );
    digest.iter().fold(String::new(), |mut hex, byte| {
        let _ = write!(hex, "{byte:02x}");
        hex
    })
}

/// Rules 2 and 5: each file of `tests/node/test` matches its upstream hash in
/// `tests/node/suite.sha256`, which `scripts/vendor-node-tests.sh` writes from the upstream
/// checkout, unless `tests/node/edited.txt` lists it with a reason. Only files of `common/`
/// may change, and a line of `edited.txt` for an unchanged file is stale.
#[test]
fn vendored_node_tests_match_their_upstream_hash() {
    let node = repository().join("tests/node");
    let Ok(manifest) = fs::read_to_string(node.join("suite.sha256")) else {
        return;
    };
    let upstream: BTreeMap<&str, &str> = manifest
        .lines()
        .map(|line| {
            let (hash, path) = line
                .split_once("  ")
                .unwrap_or_else(|| panic!("suite.sha256: `{line}` is not `<sha256>  <path>`"));
            (path, hash)
        })
        .collect();
    let edited_text = fs::read_to_string(node.join("edited.txt")).expect("edited.txt exists");
    let edited: BTreeSet<&str> = edited_text
        .lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| {
            let (path, reason) = line.split_once(' ').unwrap_or((line, ""));
            assert!(
                !reason.trim().is_empty() && path.starts_with("common/"),
                "edited.txt: `{line}` must be `common/<file> <reason>`"
            );
            path
        })
        .collect();
    // Node's fixtures hold node_modules directories, so this walk skips only Finder files.
    let vendored = files_except(&node, "test", &[".DS_Store"]);
    let mut wrong: Vec<String> = Vec::new();
    for file in &vendored {
        let path = file.strip_prefix("test/").unwrap_or(file);
        let matches = upstream.get(path) == Some(&sha256(&node.join(file)).as_str());
        match (matches, edited.contains(path)) {
            (false, false) => wrong.push(format!("{path}: differs from upstream")),
            (true, true) => wrong.push(format!("{path}: edited.txt lists it, and it is unchanged")),
            _ => {}
        }
    }
    let present: BTreeSet<&str> = vendored
        .iter()
        .map(|file| file.strip_prefix("test/").unwrap_or(file))
        .collect();
    wrong.extend(
        upstream
            .keys()
            .filter(|path| !present.contains(*path))
            .map(|path| format!("{path}: missing")),
    );
    assert!(
        wrong.is_empty(),
        "tests/node/test differs from tests/node/suite.sha256; run scripts/vendor-node-tests.sh, \
         or list an edit of common/ in tests/node/edited.txt:\n{}",
        wrong.join("\n")
    );
}

/// Rule 6: only `scripts/freeze-expectations.sh`, `scripts/node-surface.sh`, `crates/buoy-bench`,
/// and `crates/buoy-fuzz` start node. The `node` shim stops a test that starts node when it
/// runs. This check finds the code before it runs.
#[test]
fn only_the_oracle_tools_start_node() {
    let root = repository();
    let found: Vec<String> = files(&root, "")
        .into_iter()
        .filter(|path| {
            !ORACLE_TOOLS
                .iter()
                .chain(&UPSTREAM)
                .any(|tool| path.starts_with(tool))
        })
        .flat_map(|path| {
            let text = fs::read_to_string(root.join(&path)).unwrap_or_default();
            text.lines()
                .enumerate()
                .filter(|(_, line)| starts_node(&path, line))
                .map(|(index, line)| format!("{path}:{}: {}", index + 1, line.trim()))
                .collect::<Vec<_>>()
        })
        .collect();
    assert!(
        found.is_empty(),
        "only scripts/freeze-expectations.sh, scripts/node-surface.sh, crates/buoy-bench, and \
         crates/buoy-fuzz may start node:\n{}",
        found.join("\n")
    );
}

/// Whether `line` of the file at `path` starts node: as the program of a call in source
/// code, as a command of a shell line, or in a script of a `package.json`.
fn starts_node(path: &str, line: &str) -> bool {
    let extension = Path::new(path)
        .extension()
        .map_or("", |extension| extension.to_str().unwrap_or_default());
    match extension {
        "rs" | "ts" | "tsx" | "mts" | "cts" | "js" | "mjs" | "cjs" | "erl" | "hrl" => {
            NODE_CALLS.iter().any(|call| line.contains(call))
        }
        "sh" | "yml" | "yaml" | "" => {
            let command = line.trim_start();
            command == "node"
                || command.starts_with("node ")
                || NODE_COMMANDS.iter().any(|operator| line.contains(operator))
        }
        "json" => path.ends_with("package.json") && line.contains("\"node "),
        _ => false,
    }
}

#[test]
fn the_node_patterns_find_each_way_to_start_node() {
    let starts = [
        ("crates/x/src/main.rs", "    Command::new(\"node\")"),
        ("tests/x.ts", "spawn('node', [file]);"),
        ("scripts/x.sh", "  node \"$program\" >out"),
        ("scripts/x.sh", "out=$(node --version)"),
        (".github/workflows/ci.yml", "      - run: node build.mjs"),
        ("package.json", "    \"build\": \"node build.mjs\""),
    ];
    let others = [
        (
            "tests/x.ts",
            "for (const node of graph.keys()) visit(node);",
        ),
        ("scripts/x.sh", "echo \"$0: node is $found\" >&2"),
        (".github/workflows/ci.yml", "          node-version: 25"),
        ("bench/results/x.json", "  \"runtime\": \"node\","),
        (
            "tests/migration/before/README.md",
            "  node --experimental-transform-types x.ts",
        ),
    ];
    for (path, line) in starts {
        assert!(starts_node(path, line), "{path}: {line}");
    }
    for (path, line) in others {
        assert!(!starts_node(path, line), "{path}: {line}");
    }
}
