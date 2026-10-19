//! The CLDR data and the algorithms of `Intl` (ECMA-402), on ICU4X: the Unicode
//! Consortium's Rust ICU, with CLDR compiled in (docs/design/intl.md). V8 and
//! `JavaScriptCore`, which Bun runs, split `Intl` the same way: the abstract operations of
//! ECMA-402 in the engine, here `buoy_ref_intl*.erl`, and the locale data and algorithms
//! in ICU.

pub mod collator;

use icu_locale::subtags::{Language, Region, Script};
use icu_locale::{
    Direction, LanguageIdentifier, Locale, LocaleCanonicalizer, LocaleDirectionality,
    LocaleExpander,
};

static CANONICALIZER: LocaleCanonicalizer = LocaleCanonicalizer::new_extended();
static EXPANDER: LocaleExpander = LocaleExpander::new_extended();
static DIRECTIONALITY: LocaleDirectionality = LocaleDirectionality::new_extended();

/// The tag in the canonical form of UTS #35, with the aliases of CLDR replaced in its
/// language, script, region, and variants, or `None` when it is not a structurally valid
/// Unicode locale identifier (ECMA-402 `IsStructurallyValidLanguageTag`). The values of
/// the `-u-` and `-t-` extensions keep their aliases, which `buoy_ref_intl` replaces.
#[must_use]
pub fn canonicalize(tag: &str) -> Option<String> {
    with_locale(tag, |locale| {
        CANONICALIZER.canonicalize(locale);
    })
}

/// The tag with its likely subtags added (`Intl.Locale.prototype.maximize`).
#[must_use]
pub fn maximize(tag: &str) -> Option<String> {
    with_locale(tag, |locale| maximize_id(&mut locale.id))
}

/// The tag with the subtags removed that maximize would add back
/// (`Intl.Locale.prototype.minimize`).
#[must_use]
pub fn minimize(tag: &str) -> Option<String> {
    with_locale(tag, |locale| {
        maximize_id(&mut locale.id);
        EXPANDER.minimize(&mut locale.id);
    })
}

/// The direction of the script of the locale or of its likely subtags: `Some(true)`
/// for right to left, `Some(false)` for left to right, and `None` for a script without a
/// direction, such as Zyyy, or a locale whose script is unknown.
#[must_use]
pub fn is_right_to_left(tag: &str) -> Option<bool> {
    let mut direction = None;
    with_locale(tag, |locale| {
        // TextDirectionOfLocale: the script of the tag, else that of its likely subtags.
        // The script alone decides, so the language does not replace a script such as
        // Zzzz that has no direction.
        if locale.id.script.is_none() {
            maximize_id(&mut locale.id);
        }
        let Some(script) = locale.id.script else {
            return;
        };
        let mut alone = LanguageIdentifier::UNKNOWN;
        alone.script = Some(script);
        direction = match DIRECTIONALITY.get(&alone) {
            Some(Direction::RightToLeft) => Some(true),
            Some(Direction::LeftToRight) => Some(false),
            _ => None,
        };
    })?;
    direction
}

/// Add Likely Subtags of UTS #35. ICU4X leaves a bare `und` as it is, where UTS #35
/// takes the likely subtags of `und` from CLDR: en-Latn-US.
fn maximize_id(id: &mut LanguageIdentifier) {
    EXPANDER.maximize(id);
    if id.language == Language::UNKNOWN {
        id.language = Language::try_from_str("en").unwrap_or(Language::UNKNOWN);
        id.script = id.script.or_else(|| Script::try_from_str("Latn").ok());
        id.region = id.region.or_else(|| Region::try_from_str("US").ok());
    }
}

/// Runs `transform` on the locale of `tag` and returns its text. ICU4X takes a language
/// subtag of 2 or 3 letters only, where UTS #35 also allows 5 to 8, so such a language
/// stands in as the private use language `qaa`, which has no data and no alias, and comes
/// back after the transform.
fn with_locale(tag: &str, transform: impl FnOnce(&mut Locale)) -> Option<String> {
    let (language, rest) = tag.split_once('-').unwrap_or((tag, ""));
    let long =
        (5..=8).contains(&language.len()) && language.bytes().all(|b| b.is_ascii_alphabetic());
    let stand_in = if long {
        format!("qaa{}{rest}", if rest.is_empty() { "" } else { "-" })
    } else {
        tag.to_owned()
    };
    let mut locale = parse(&stand_in)?;
    transform(&mut locale);
    let text = locale.to_string();
    if !long {
        return Some(text);
    }
    let lower = language.to_ascii_lowercase();
    Some(match text.strip_prefix("qaa") {
        Some(after) => format!("{lower}{after}"),
        None => text,
    })
}

/// A Unicode locale identifier of ECMA-402: ICU4X's grammar, which also takes `_` as a
/// separator, without it, and with no singleton and no variant twice.
fn parse(tag: &str) -> Option<Locale> {
    if !tag
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        || has_duplicates(tag)
    {
        return None;
    }
    tag.parse().ok()
}

/// Whether a singleton appears twice, or a variant of the language identifier does. The
/// subtags after the private use singleton `x` are free.
fn has_duplicates(tag: &str) -> bool {
    let subtags: Vec<String> = tag
        .split('-')
        .map(str::to_ascii_lowercase)
        .take_while(|subtag| subtag != "x")
        .collect();
    let singletons: Vec<&String> = subtags.iter().skip(1).filter(|s| s.len() == 1).collect();
    let mut seen = singletons.clone();
    seen.sort();
    seen.dedup();
    if seen.len() != singletons.len() {
        return true;
    }
    // The variants are the subtags of 5 to 8 characters, or of 4 that start with a digit,
    // before the first singleton.
    let mut variants: Vec<&String> = subtags
        .iter()
        .skip(1)
        .take_while(|s| s.len() != 1)
        .filter(|s| s.len() >= 5 || (s.len() == 4 && s.as_bytes()[0].is_ascii_digit()))
        .collect();
    let count = variants.len();
    variants.sort();
    variants.dedup();
    variants.len() != count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonicalizes_case_aliases_and_order() {
        assert_eq!(canonicalize("EN-us").as_deref(), Some("en-US"));
        assert_eq!(canonicalize("sgn-GR").as_deref(), Some("gss"));
        assert_eq!(canonicalize("art-lojban").as_deref(), Some("jbo"));
        assert_eq!(
            canonicalize("de-u-co-phonebk-ca-gregory").as_deref(),
            Some("de-u-ca-gregory-co-phonebk")
        );
    }

    #[test]
    fn rejects_what_ecma402_rejects() {
        for tag in [
            "en_US",
            "i-klingon",
            "x-private",
            "de-1996-1996",
            "en-u-ca-u-nu",
            "",
        ] {
            assert_eq!(canonicalize(tag), None, "{tag}");
        }
        assert!(canonicalize("en-x-u-u").is_some());
    }

    #[test]
    fn maximizes_minimizes_and_finds_direction() {
        assert_eq!(maximize("en").as_deref(), Some("en-Latn-US"));
        assert_eq!(minimize("zh-Hant-TW").as_deref(), Some("zh-TW"));
        assert_eq!(maximize("und").as_deref(), Some("en-Latn-US"));
        assert_eq!(minimize("und").as_deref(), Some("en"));
        assert_eq!(canonicalize("POSIX").as_deref(), Some("posix"));
        assert_eq!(maximize("abcdefgh").as_deref(), Some("abcdefgh"));
        assert_eq!(is_right_to_left("ar"), Some(true));
        assert_eq!(is_right_to_left("en"), Some(false));
        assert_eq!(is_right_to_left("und-Zyyy"), None);
        assert_eq!(is_right_to_left("und-Zzzz"), None);
        assert_eq!(is_right_to_left("abcdefgh-Latn"), Some(false));
        assert_eq!(is_right_to_left("en-Zzzz"), None);
        assert_eq!(is_right_to_left("en-Arab"), Some(true));
    }
}
