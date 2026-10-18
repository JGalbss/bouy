//! The test files of a test262 checkout and the facts of their frontmatter: the modes, the
//! harness files, the features, the edition, and the groups of section 5.5.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use super::compile::{Compile, Compilers};
use super::frontmatter::{self, Frontmatter};
use crate::expectations::Expectations;
use crate::parallel;
use crate::summary::Counts;

/// The minimum edition of each feature, from Boa.
const EDITIONS: &str = include_str!("editions.txt");

/// The directories that run in the nightly job only (section 5.5).
pub(super) const NIGHTLY_ONLY: [&str; 2] = ["intl402/", "staging/"];

/// The editions of the subset that predicts npm success: ES5 to ES2022.
const NPM_EDITIONS: [&str; 9] = [
    "es5", "es6", "es7", "es8", "es9", "es10", "es11", "es12", "es13",
];

/// The language mode of one execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Mode {
    NonStrict,
    Strict,
    Module,
}

impl Mode {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::NonStrict => "nonstrict",
            Self::Strict => "strict",
            Self::Module => "module",
        }
    }
}

/// One test file and the facts of its frontmatter.
#[derive(Debug)]
pub(super) struct Test {
    /// The path under `test/`.
    pub(super) id: String,
    pub(super) path: PathBuf,
    pub(super) frontmatter: Frontmatter,
    /// The features of the frontmatter and the features that its includes imply.
    pub(super) features: BTreeSet<String>,
    /// The harness files, in the order that they run.
    pub(super) includes: Vec<String>,
    pub(super) modes: Vec<Mode>,
    pub(super) edition: String,
    /// The test compiles code at run time: `eval(`, `Function(`, `$262.evalScript`, or
    /// `createRealm`.
    pub(super) dynamic_code: bool,
}

pub(super) fn load_tests(
    checkout: &Path,
    harness: &Harness,
    jobs: usize,
) -> Result<Vec<Test>, String> {
    let editions: HashMap<&str, &str> = EDITIONS
        .lines()
        .filter(|line| !line.starts_with('#'))
        .filter_map(|line| line.split_once(' '))
        .collect();
    let ids = test_ids(checkout)?;
    let loaded = parallel(&ids, jobs, |id| load_test(checkout, id, harness, &editions));
    let mut tests = Vec::with_capacity(loaded.len());
    let mut errors = Vec::new();
    for test in loaded {
        match test {
            Ok(test) => tests.push(test),
            Err(error) => errors.push(error),
        }
    }
    if errors.is_empty() {
        return Ok(tests);
    }
    errors.truncate(10);
    Err(format!(
        "the test262 format changed, so the run stops:\n{}",
        errors.join("\n")
    ))
}

/// The id of each test file under `test/`: every `.js` file except the `_FIXTURE.js`
/// modules that tests import, sorted.
fn test_ids(checkout: &Path) -> Result<Vec<String>, String> {
    let root = checkout.join("test");
    let mut ids = Vec::new();
    let mut directories = vec![String::new()];
    while let Some(directory) = directories.pop() {
        let entries = fs::read_dir(root.join(&directory))
            .map_err(|error| format!("{}: {error}", root.join(&directory).display()))?;
        for entry in entries.filter_map(Result::ok) {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let id = if directory.is_empty() {
                name
            } else {
                format!("{directory}/{name}")
            };
            if entry.path().is_dir() {
                directories.push(id);
            } else if is_javascript(&id) && !id.ends_with("_FIXTURE.js") {
                ids.push(id);
            }
        }
    }
    ids.sort();
    Ok(ids)
}

fn is_javascript(name: &str) -> bool {
    Path::new(name)
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("js"))
}

fn load_test(
    checkout: &Path,
    id: &str,
    harness: &Harness,
    editions: &HashMap<&str, &str>,
) -> Result<Test, String> {
    let path = checkout.join("test").join(id);
    let source = fs::read_to_string(&path).map_err(|error| format!("{id}: {error}"))?;
    let frontmatter = frontmatter::parse(&source).map_err(|error| format!("{id}: {error}"))?;
    let includes = includes(&frontmatter);
    if let Some(missing) = includes
        .iter()
        .find(|name| !harness.files.contains_key(*name))
    {
        return Err(format!("{id}: the harness file {missing} does not exist"));
    }
    let features = frontmatter
        .features
        .iter()
        .cloned()
        .chain(includes.iter().flat_map(|name| harness.implied(name)))
        .collect();
    Ok(Test {
        id: id.to_owned(),
        path,
        modes: modes(&frontmatter),
        edition: edition(&frontmatter, editions),
        dynamic_code: has_dynamic_code(&source),
        includes,
        features,
        frontmatter,
    })
}

/// The modes of section 5.5. The `module` flag alone sets the module goal.
fn modes(frontmatter: &Frontmatter) -> Vec<Mode> {
    if frontmatter.has_flag("module") {
        return vec![Mode::Module];
    }
    if frontmatter.has_flag("onlyStrict") {
        return vec![Mode::Strict];
    }
    if frontmatter.has_flag("noStrict") || frontmatter.has_flag("raw") {
        return vec![Mode::NonStrict];
    }
    vec![Mode::NonStrict, Mode::Strict]
}

/// The harness files of a test: `assert.js` and `sta.js`, `doneprintHandle.js` for an
/// async test, then the includes. A raw test gets none of the defaults.
fn includes(frontmatter: &Frontmatter) -> Vec<String> {
    let defaults: &[&str] = match (frontmatter.has_flag("raw"), frontmatter.has_flag("async")) {
        (true, _) => &[],
        (false, true) => &["assert.js", "sta.js", "doneprintHandle.js"],
        (false, false) => &["assert.js", "sta.js"],
    };
    let mut includes: Vec<String> = defaults.iter().map(|name| (*name).to_owned()).collect();
    for include in &frontmatter.includes {
        if !includes.contains(include) {
            includes.push(include.clone());
        }
    }
    includes
}

/// The minimum edition of a test, computed as Boa does: ES2017 for an async test, ES2015
/// for a module or a test with an `esid` or `es6id`, ES5 otherwise, raised to the edition
/// of each feature. A feature that the table lacks gives `unknown`.
fn edition(frontmatter: &Frontmatter, editions: &HashMap<&str, &str>) -> String {
    let number = |edition: &str| -> u8 {
        edition
            .strip_prefix("es")
            .and_then(|number| number.parse().ok())
            .unwrap_or(u8::MAX)
    };
    let base = match (
        frontmatter.has_flag("async"),
        frontmatter.has_flag("module") || frontmatter.has_esid,
    ) {
        (true, _) => 8,
        (false, true) => 6,
        (false, false) => 5,
    };
    let mut minimum = base;
    for feature in &frontmatter.features {
        let Some(edition) = editions.get(feature.as_str()) else {
            return "unknown".to_owned();
        };
        minimum = minimum.max(number(edition));
    }
    if minimum == u8::MAX {
        return "esnext".to_owned();
    }
    format!("es{minimum}")
}

fn has_dynamic_code(source: &str) -> bool {
    let called = |name: &str| {
        source.match_indices(name).any(|(index, _)| {
            !source[..index]
                .chars()
                .next_back()
                .is_some_and(|before| before.is_alphanumeric() || "_$.".contains(before))
        })
    };
    called("eval(")
        || called("Function(")
        || source.contains("$262.evalScript")
        || source.contains("createRealm")
}

/// The harness files, each compiled once as a sloppy script, and the features that each
/// one implies in `harness/features.yml`.
#[derive(Debug)]
pub(super) struct Harness {
    pub(super) files: HashMap<String, HarnessFile>,
    pub(super) implied: HashMap<String, Vec<String>>,
}

#[derive(Debug)]
pub(super) struct HarnessFile {
    pub(super) source: String,
    pub(super) compiled: Compile,
}

impl Harness {
    pub(super) fn load(checkout: &Path, compilers: &Compilers) -> Result<Self, String> {
        let root = checkout.join("harness");
        let mut files = HashMap::new();
        let mut directories = vec![String::new()];
        while let Some(directory) = directories.pop() {
            let entries = fs::read_dir(root.join(&directory))
                .map_err(|error| format!("{}: {error}", root.join(&directory).display()))?;
            for entry in entries.filter_map(Result::ok) {
                let name = entry.file_name().to_string_lossy().into_owned();
                let name = if directory.is_empty() {
                    name
                } else {
                    format!("{directory}/{name}")
                };
                if entry.path().is_dir() {
                    directories.push(name);
                } else if is_javascript(&name) {
                    let source = fs::read_to_string(entry.path())
                        .map_err(|error| format!("harness/{name}: {error}"))?;
                    let compiled = compilers.compile(&entry.path(), checkout, false);
                    files.insert(name, HarnessFile { source, compiled });
                }
            }
        }
        let features = fs::read_to_string(root.join("features.yml")).unwrap_or_default();
        let implied = features
            .lines()
            .filter_map(|line| line.split_once(':'))
            .map(|(name, list)| {
                let features = frontmatter::list(list, &[])?;
                Ok((name.trim().to_owned(), features))
            })
            .collect::<Result<_, String>>()
            .map_err(|error| format!("harness/features.yml: {error}"))?;
        Ok(Self { files, implied })
    }

    /// The features that the include `name` implies. `features.yml` names some files
    /// without `.js`.
    fn implied(&self, name: &str) -> Vec<String> {
        [name, name.trim_end_matches(".js")]
            .iter()
            .filter_map(|key| self.implied.get(*key))
            .flatten()
            .cloned()
            .collect()
    }
}

/// The groups of section 5.5: the directory to depth 3, each feature, the edition, positive
/// or negative, and the subsets `npm` and `dynamic-code`.
pub(super) fn groups(
    tests: &[Test],
    entries: &Expectations,
) -> BTreeMap<String, BTreeMap<String, Counts>> {
    let mut groups: BTreeMap<String, BTreeMap<String, Counts>> = BTreeMap::new();
    for test in tests {
        let Some(entry) = entries.get(&test.id) else {
            continue;
        };
        let mut add = |kind: &str, group: &str| {
            groups
                .entry(kind.to_owned())
                .or_default()
                .entry(group.to_owned())
                .or_default()
                .add(entry);
        };
        let directories: Vec<&str> = test.id.split('/').collect();
        let depth = directories.len().saturating_sub(1).min(3);
        add("directory", &directories[..depth].join("/"));
        for feature in &test.features {
            add("feature", feature);
        }
        add("edition", &test.edition);
        add(
            "kind",
            match test.frontmatter.negative {
                Some(_) => "negative",
                None => "positive",
            },
        );
        if NPM_EDITIONS.contains(&test.edition.as_str())
            && !NIGHTLY_ONLY
                .iter()
                .any(|prefix| test.id.starts_with(prefix))
        {
            add("subset", "npm");
        }
        if test.dynamic_code {
            add("subset", "dynamic-code");
        }
    }
    groups
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_test_without_a_mode_flag_runs_twice() {
        let frontmatter = |flags: &[&str]| Frontmatter {
            flags: flags.iter().map(|flag| (*flag).to_owned()).collect(),
            ..Frontmatter::default()
        };
        assert_eq!(modes(&frontmatter(&[])), [Mode::NonStrict, Mode::Strict]);
        assert_eq!(modes(&frontmatter(&["onlyStrict"])), [Mode::Strict]);
        assert_eq!(modes(&frontmatter(&["raw"])), [Mode::NonStrict]);
        assert_eq!(modes(&frontmatter(&["module", "async"])), [Mode::Module]);
        assert_eq!(
            includes(&frontmatter(&["async"])),
            ["assert.js", "sta.js", "doneprintHandle.js"]
        );
        assert!(includes(&frontmatter(&["raw"])).is_empty());
    }

    #[test]
    fn the_edition_follows_boa() {
        let editions = HashMap::from([("BigInt", "es11"), ("decorators", "esnext")]);
        let test = |features: &[&str], flags: &[&str], has_esid: bool| Frontmatter {
            features: features.iter().map(|name| (*name).to_owned()).collect(),
            flags: flags.iter().map(|flag| (*flag).to_owned()).collect(),
            has_esid,
            ..Frontmatter::default()
        };
        assert_eq!(edition(&test(&[], &[], false), &editions), "es5");
        assert_eq!(edition(&test(&[], &[], true), &editions), "es6");
        assert_eq!(edition(&test(&[], &["async"], false), &editions), "es8");
        assert_eq!(edition(&test(&["BigInt"], &[], true), &editions), "es11");
        assert_eq!(
            edition(&test(&["decorators"], &[], true), &editions),
            "esnext"
        );
        assert_eq!(
            edition(&test(&["Unknown"], &[], true), &editions),
            "unknown"
        );
    }

    #[test]
    fn dynamic_code_is_a_call_of_eval_or_function() {
        assert!(has_dynamic_code("eval('1');"));
        assert!(has_dynamic_code("new Function('a', 'return a');"));
        assert!(!has_dynamic_code(
            "retrieval(x); AsyncFunction(); x.eval(1);"
        ));
    }
}
