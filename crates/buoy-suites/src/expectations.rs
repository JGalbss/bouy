//! The expectation files of section 3.2 of docs/design/testing.md: one line for each test,
//! sorted by id, with the outcome as the last word. When the modes of a test differ, the
//! line holds the outcome of each mode, as `nonstrict=pass,strict=fail`.

use std::collections::BTreeMap;
use std::fmt::{self, Write as _};
use std::fs;
use std::path::Path;
use std::str::FromStr;

use crate::outcome::Outcome;

/// The outcome of one id: one outcome for every mode, or one for each mode when they
/// differ.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entry {
    Same(Outcome),
    Modes(BTreeMap<String, Outcome>),
}

/// The entries of an expectation file, by id.
pub type Expectations = BTreeMap<String, Entry>;

/// The platform of this run, as a line whose outcome differs by platform names it.
pub const PLATFORM: &str = std::env::consts::OS;

/// The platforms whose runs record the expectation files of Node's tests.
pub const PLATFORMS: [&str; 2] = ["linux", "macos"];

/// The entries as a run on `platform` expects them (`Entry::on_platform`).
#[must_use]
pub fn on_platform(entries: &Expectations, platform: &str) -> Expectations {
    entries
        .iter()
        .map(|(id, entry)| (id.clone(), entry.on_platform(platform)))
        .collect()
}

impl Entry {
    /// The entry of the outcome of each mode. Equal outcomes collapse to one.
    #[must_use]
    pub fn of_modes(modes: BTreeMap<String, Outcome>) -> Self {
        let mut outcomes = modes.values();
        match outcomes.next() {
            Some(first) if outcomes.all(|outcome| outcome == first) => Self::Same(*first),
            Some(_) => Self::Modes(modes),
            None => Self::Same(Outcome::Skip),
        }
    }

    /// The outcome that counts for the id: a test passes when each of its modes passes, so
    /// the mode of the highest rank counts, and the first mode on a tie.
    #[must_use]
    pub fn outcome(&self) -> Outcome {
        match self {
            Self::Same(outcome) => *outcome,
            Self::Modes(modes) => modes
                .values()
                .copied()
                .reduce(|worst, next| {
                    if next.rank() > worst.rank() {
                        next
                    } else {
                        worst
                    }
                })
                .unwrap_or(Outcome::Skip),
        }
    }

    /// Whether some mode passes.
    #[must_use]
    pub fn passes_in_a_mode(&self) -> bool {
        match self {
            Self::Same(outcome) => *outcome == Outcome::Pass,
            Self::Modes(modes) => modes.values().any(|outcome| *outcome == Outcome::Pass),
        }
    }

    /// The entry that a run on `platform` expects: the outcome of `platform` when the line
    /// names platforms, as `linux=fail,macos=pass`.
    #[must_use]
    pub fn on_platform(&self, platform: &str) -> Self {
        match self {
            Self::Modes(platforms) => platforms
                .get(platform)
                .map_or_else(|| self.clone(), |outcome| Self::Same(*outcome)),
            Self::Same(_) => self.clone(),
        }
    }

    /// The entry with `outcome` on `platform`. A line that names platforms keeps the others.
    /// A line that names none takes `outcome` on every platform when `everywhere` holds, as
    /// an update after a change to the code does, and else keeps its outcome on the other
    /// platforms of `PLATFORMS`, as a run of the same code on a second platform does.
    #[must_use]
    pub fn with_platform(&self, platform: &str, outcome: Outcome, everywhere: bool) -> Self {
        match self {
            Self::Same(_) if everywhere => Self::Same(outcome),
            Self::Same(before) => Self::of_modes(
                PLATFORMS
                    .iter()
                    .map(|other| ((*other).to_owned(), *before))
                    .chain([(platform.to_owned(), outcome)])
                    .collect(),
            ),
            Self::Modes(platforms) => {
                let mut platforms = platforms.clone();
                platforms.insert(platform.to_owned(), outcome);
                Self::of_modes(platforms)
            }
        }
    }

    /// The pairs of outcomes, before and after, of each mode that both entries name. A
    /// `Same` entry holds for every mode.
    #[must_use]
    pub fn moves(&self, after: &Self) -> Vec<(Outcome, Outcome)> {
        match (self, after) {
            (Self::Same(before), Self::Same(after)) => vec![(*before, *after)],
            (Self::Same(before), Self::Modes(modes)) => {
                modes.values().map(|after| (*before, *after)).collect()
            }
            (Self::Modes(modes), Self::Same(after)) => {
                modes.values().map(|before| (*before, *after)).collect()
            }
            (Self::Modes(before), Self::Modes(after)) => before
                .iter()
                .filter_map(|(mode, before)| Some((*before, *after.get(mode)?)))
                .collect(),
        }
    }
}

impl fmt::Display for Entry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Same(outcome) => write!(f, "{outcome}"),
            Self::Modes(modes) => {
                let modes: Vec<String> = modes
                    .iter()
                    .map(|(mode, outcome)| format!("{mode}={outcome}"))
                    .collect();
                f.write_str(&modes.join(","))
            }
        }
    }
}

impl FromStr for Entry {
    type Err = String;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        if !text.contains('=') {
            return Ok(Self::Same(text.parse()?));
        }
        let modes = text
            .split(',')
            .map(|pair| {
                let (mode, outcome) = pair
                    .split_once('=')
                    .ok_or_else(|| format!("`{pair}` is not `<mode>=<outcome>`"))?;
                Ok((mode.to_owned(), outcome.parse()?))
            })
            .collect::<Result<BTreeMap<_, _>, String>>()?;
        Ok(Self::of_modes(modes))
    }
}

/// Reads an expectation file. A comment line starts with `#`.
pub fn parse(text: &str) -> Result<Expectations, String> {
    let mut entries = Expectations::new();
    for (index, line) in text.lines().enumerate() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let failed = |reason: String| format!("line {}: {reason}", index + 1);
        let (id, entry) = line
            .rsplit_once(' ')
            .ok_or_else(|| failed(format!("`{line}` is not `<id> <outcome>`")))?;
        let entry = entry.parse().map_err(failed)?;
        if entries.insert(unescape(id), entry).is_some() {
            return Err(failed(format!("`{id}` has a second line")));
        }
    }
    Ok(entries)
}

/// Reads the expectation file at `path`. A missing file holds no entry.
pub fn read(path: &Path) -> Result<Expectations, String> {
    match fs::read_to_string(path) {
        Ok(text) => parse(&text).map_err(|error| format!("{}: {error}", path.display())),
        Err(_) => Ok(Expectations::new()),
    }
}

/// Writes an expectation file: the `header` lines as comments, then one line for each id,
/// sorted by id.
#[must_use]
pub fn write(header: &[String], entries: &Expectations) -> String {
    let mut text = header.iter().fold(String::new(), |mut text, line| {
        let _ = writeln!(text, "# {line}");
        text
    });
    for (id, entry) in entries {
        text.push_str(&escape(id));
        text.push(' ');
        text.push_str(&entry.to_string());
        text.push('\n');
    }
    text
}

fn escape(id: &str) -> String {
    id.replace('\\', "\\\\").replace('\n', "\\n")
}

fn unescape(id: &str) -> String {
    let mut text = String::with_capacity(id.len());
    let mut characters = id.chars();
    while let Some(character) = characters.next() {
        if character != '\\' {
            text.push(character);
            continue;
        }
        match characters.next() {
            Some('n') => text.push('\n'),
            Some(other) => text.push(other),
            None => text.push('\\'),
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_reads_back_as_it_was_written() {
        let text = "# Generated.\n\
                    a\\nb\\\\c.js nonstrict=pass,strict=fail\n\
                    a b.js pass\n\
                    c.js rejected\n";
        let entries = parse(text).expect("the file parses");
        assert_eq!(entries.get("a b.js"), Some(&Entry::Same(Outcome::Pass)));
        assert!(entries.contains_key("a\nb\\c.js"));
        assert_eq!(write(&["Generated.".to_owned()], &entries), text);
    }

    #[test]
    fn equal_modes_collapse_and_the_worst_mode_counts() {
        let same: Entry = "nonstrict=pass,strict=pass".parse().expect("parses");
        assert_eq!(same, Entry::Same(Outcome::Pass));
        let mixed: Entry = "nonstrict=rejected,strict=crash".parse().expect("parses");
        assert_eq!(mixed.outcome(), Outcome::Crash);
        assert_eq!(mixed.to_string(), "nonstrict=rejected,strict=crash");
    }

    #[test]
    fn a_platform_line_keeps_the_outcome_of_the_other_platform() {
        let line: Entry = "linux=fail,macos=pass".parse().expect("parses");
        assert_eq!(line.on_platform("linux"), Entry::Same(Outcome::Fail));
        assert_eq!(line.on_platform("macos"), Entry::Same(Outcome::Pass));
        assert_eq!(line.outcome(), Outcome::Fail, "the worst platform counts");
        assert_eq!(
            line.with_platform("linux", Outcome::Pass, true),
            Entry::Same(Outcome::Pass)
        );
        assert_eq!(line.with_platform("macos", Outcome::Pass, true), line);
        let same = Entry::Same(Outcome::Pass);
        assert_eq!(
            same.with_platform("linux", Outcome::Fail, false),
            line,
            "a run of the same code splits the line"
        );
        assert_eq!(
            same.with_platform("linux", Outcome::Fail, true),
            Entry::Same(Outcome::Fail),
            "an update after a change moves every platform"
        );
    }

    #[test]
    fn a_bad_line_names_its_number() {
        assert_eq!(
            parse("a.js pass\nb.js maybe\n"),
            Err("line 2: `maybe` is not an outcome".to_owned())
        );
        assert_eq!(
            parse("a.js pass\na.js fail\n"),
            Err("line 2: `a.js` has a second line".to_owned())
        );
    }
}
