//! The frontmatter of a test262 file, as `INTERPRETING.md` defines it: the YAML between
//! `/*---` and `---*/`. A hand-written parser reads the keys that the runner needs, and an
//! unknown key, flag, or phase is an error, so an upstream format change stops the run.

/// The keys that a test file may hold. Only some of them change how the test runs.
const KEYS: [&str; 11] = [
    "author",
    "description",
    "es5id",
    "es6id",
    "esid",
    "features",
    "flags",
    "includes",
    "info",
    "locale",
    "negative",
];

const FLAGS: [&str; 9] = [
    "CanBlockIsFalse",
    "CanBlockIsTrue",
    "async",
    "generated",
    "module",
    "noStrict",
    "non-deterministic",
    "onlyStrict",
    "raw",
];

/// The phase in which a negative test must fail.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Parse,
    Resolution,
    Runtime,
}

/// The expected failure of a negative test.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Negative {
    pub phase: Phase,
    /// The name of the constructor of the expected error, such as `SyntaxError`.
    pub error: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Frontmatter {
    pub flags: Vec<String>,
    pub includes: Vec<String>,
    pub features: Vec<String>,
    pub negative: Option<Negative>,
    /// The test has an `esid` or an `es6id`, which Boa reads as ES2015 or later.
    pub has_esid: bool,
}

impl Frontmatter {
    #[must_use]
    pub fn has_flag(&self, flag: &str) -> bool {
        self.flags.iter().any(|found| found == flag)
    }
}

/// The frontmatter of the test whose source is `source`.
pub fn parse(source: &str) -> Result<Frontmatter, String> {
    let start = source.find("/*---").ok_or("the file has no frontmatter")? + "/*---".len();
    let end = source[start..]
        .find("---*/")
        .ok_or("the frontmatter has no end")?
        + start;
    let mut frontmatter = Frontmatter::default();
    let mut lines = source[start..end].lines().peekable();
    while let Some(line) = lines.next() {
        if line.trim().is_empty() || line.starts_with(char::is_whitespace) {
            continue;
        }
        let (key, value) = line
            .split_once(':')
            .ok_or_else(|| format!("`{line}` is not `<key>: <value>`"))?;
        if !KEYS.contains(&key) {
            return Err(format!("the frontmatter key `{key}` is unknown"));
        }
        let mut block = Vec::new();
        while let Some(next) = lines.next_if(|next| {
            next.trim().is_empty() || next.starts_with(char::is_whitespace) || next.starts_with('-')
        }) {
            block.push(next);
        }
        match key {
            "flags" => frontmatter.flags = list(value, &block)?,
            "includes" => frontmatter.includes = list(value, &block)?,
            "features" => frontmatter.features = list(value, &block)?,
            "negative" => frontmatter.negative = Some(negative(&block)?),
            "esid" | "es6id" => frontmatter.has_esid = true,
            _ => {}
        }
    }
    if let Some(flag) = frontmatter
        .flags
        .iter()
        .find(|flag| !FLAGS.contains(&flag.as_str()))
    {
        return Err(format!("the flag `{flag}` is unknown"));
    }
    Ok(frontmatter)
}

/// A flow list, `[a, b]`, which may span lines, or a block list of `- a` lines.
pub(super) fn list(value: &str, block: &[&str]) -> Result<Vec<String>, String> {
    let value = value.trim();
    if value.is_empty() {
        return block
            .iter()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                line.trim()
                    .strip_prefix('-')
                    .map(|item| unquote(item.trim()))
                    .ok_or_else(|| format!("`{line}` is not a list item"))
            })
            .collect();
    }
    let text = std::iter::once(value)
        .chain(block.iter().map(|line| line.trim()))
        .collect::<Vec<_>>()
        .join(" ");
    let inner = text
        .strip_prefix('[')
        .and_then(|rest| rest.trim_end().strip_suffix(']'))
        .ok_or_else(|| format!("`{text}` is not a list"))?;
    Ok(inner
        .split(',')
        .map(|item| unquote(item.trim()))
        .filter(|item| !item.is_empty())
        .collect())
}

fn unquote(item: &str) -> String {
    item.trim_matches(|quote| quote == '\'' || quote == '"')
        .to_owned()
}

fn negative(block: &[&str]) -> Result<Negative, String> {
    let field = |name: &str| {
        block.iter().find_map(|line| {
            let (key, value) = line.trim().split_once(':')?;
            (key == name).then(|| value.trim().to_owned())
        })
    };
    let phase = match field("phase").as_deref() {
        Some("parse") => Phase::Parse,
        Some("resolution") => Phase::Resolution,
        Some("runtime") => Phase::Runtime,
        other => return Err(format!("the negative phase {other:?} is unknown")),
    };
    let error = field("type").ok_or("the negative test names no error type")?;
    Ok(Negative { phase, error })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_keys_that_change_a_run_are_read() {
        let source = "// Copyright\n/*---\nesid: sec-x\ndescription: |\n  flags: [raw]\n  more text\n\
                      flags: [onlyStrict, async]\nincludes: [compareArray.js,\n  propertyHelper.js]\n\
                      features:\n  - Symbol\n  - 'BigInt'\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\n";
        let frontmatter = parse(source).expect("the frontmatter parses");
        assert_eq!(frontmatter.flags, ["onlyStrict", "async"]);
        assert_eq!(
            frontmatter.includes,
            ["compareArray.js", "propertyHelper.js"]
        );
        assert_eq!(frontmatter.features, ["Symbol", "BigInt"]);
        assert_eq!(
            frontmatter.negative,
            Some(Negative {
                phase: Phase::Parse,
                error: "SyntaxError".to_owned()
            })
        );
        assert!(frontmatter.has_esid);
    }

    #[test]
    fn an_unknown_key_flag_or_phase_stops_the_run() {
        let wrap = |body: &str| format!("/*---\n{body}\n---*/");
        assert_eq!(
            parse(&wrap("timeout: 5")),
            Err("the frontmatter key `timeout` is unknown".to_owned())
        );
        assert_eq!(
            parse(&wrap("flags: [fast]")),
            Err("the flag `fast` is unknown".to_owned())
        );
        assert_eq!(
            parse(&wrap("negative:\n  phase: early\n  type: SyntaxError")),
            Err("the negative phase Some(\"early\") is unknown".to_owned())
        );
        assert_eq!(
            parse("no frontmatter"),
            Err("the file has no frontmatter".to_owned())
        );
    }

    #[test]
    fn a_block_list_of_flags_is_read() {
        let frontmatter = parse("/*---\nflags:\n- noStrict\n- raw\n---*/").expect("parses");
        assert_eq!(frontmatter.flags, ["noStrict", "raw"]);
    }
}
