//! `Intl.Collator` on ICU4X's collator, the Unicode Collation Algorithm with the CLDR
//! tailorings (ECMA-402 section 10). V8 and `JavaScriptCore` call ICU4C's `ucol` the same
//! way: the engine resolves the options, and ICU compares.

use std::cmp::Ordering;

use icu_collator::options::{AlternateHandling, CaseLevel, CollatorOptions, Strength};
use icu_collator::provider::{Baked, CollationTailoringV1};
use icu_collator::{Collator, CollatorBorrowed, CollatorPreferences};
use icu_locale::{LanguageIdentifier, Locale};
use icu_provider::prelude::{
    DataIdentifierBorrowed, DataLocale, DataMarkerAttributes, DataProvider, DataRequest,
};

/// The collation types that ICU4X has data for, as `supportedValuesOf("collation")`
/// lists them.
const TYPES: [&str; 12] = [
    "compat", "dict", "emoji", "eor", "phonebk", "phonetic", "pinyin", "searchjl", "stroke",
    "trad", "unihan", "zhuyin",
];

/// The sensitivity of ECMA-402 as ICU options: `base` compares base letters only
/// (primary), `accent` also accents (secondary), `case` base letters and case (primary
/// with the case level), and `variant` everything (tertiary). `ignore_punctuation`
/// shifts the variable characters, which ignores them.
#[derive(Clone, Copy, Debug)]
pub enum Sensitivity {
    Base,
    Accent,
    Case,
    Variant,
}

/// A collator for the locale `tag`, whose `-u-co`, `-u-kf`, and `-u-kn` keywords choose
/// the collation, the case order, and numeric ordering.
#[must_use]
pub fn new(
    tag: &str,
    sensitivity: Sensitivity,
    ignore_punctuation: bool,
) -> Option<CollatorBorrowed<'static>> {
    let locale: Locale = tag.parse().ok()?;
    let prefs = CollatorPreferences::from(&locale);
    let mut options = CollatorOptions::default();
    options.strength = Some(match sensitivity {
        Sensitivity::Base | Sensitivity::Case => Strength::Primary,
        Sensitivity::Accent => Strength::Secondary,
        Sensitivity::Variant => Strength::Tertiary,
    });
    if matches!(sensitivity, Sensitivity::Case) {
        options.case_level = Some(CaseLevel::On);
    }
    options.alternate_handling = Some(if ignore_punctuation {
        AlternateHandling::Shifted
    } else {
        AlternateHandling::NonIgnorable
    });
    Collator::try_new(prefs, options).ok()
}

/// The order of two strings of UTF-16 code units.
#[must_use]
pub fn compare(collator: &CollatorBorrowed<'static>, left: &[u16], right: &[u16]) -> Ordering {
    collator.compare_utf16(left, right)
}

/// The collation types of the locale and of root: the tailorings that ICU4X has for the
/// locale or for a locale that it falls back to, by dropping the region, then the script.
#[must_use]
pub fn types(tag: &str) -> Vec<&'static str> {
    let Ok(locale) = tag.parse::<Locale>() else {
        return Vec::new();
    };
    let id = &locale.id;
    let mut chain = vec![id.clone()];
    let mut no_region = id.clone();
    no_region.region = None;
    chain.push(no_region.clone());
    let mut language = no_region;
    language.script = None;
    chain.push(language);
    chain.push(LanguageIdentifier::UNKNOWN);
    TYPES
        .into_iter()
        .filter(|kind| chain.iter().any(|id| has_tailoring(id, kind)))
        .collect()
}

/// Whether ICU4X has the tailoring `kind` for exactly the locale `id`.
fn has_tailoring(id: &LanguageIdentifier, kind: &str) -> bool {
    let Ok(attributes) = DataMarkerAttributes::try_from_str(kind) else {
        return false;
    };
    let locale = DataLocale::from(id);
    let request = DataRequest {
        id: DataIdentifierBorrowed::for_marker_attributes_and_locale(attributes, &locale),
        ..Default::default()
    };
    DataProvider::<CollationTailoringV1>::load(&Baked, request).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn units(text: &str) -> Vec<u16> {
        text.encode_utf16().collect()
    }

    #[test]
    fn compares_by_sensitivity() {
        let base = new("en", Sensitivity::Base, false).expect("collator");
        assert_eq!(compare(&base, &units("a"), &units("Á")), Ordering::Equal);
        let variant = new("en", Sensitivity::Variant, false).expect("collator");
        assert_eq!(compare(&variant, &units("a"), &units("A")), Ordering::Less);
        let numeric = new("en-u-kn", Sensitivity::Variant, false).expect("collator");
        assert_eq!(compare(&numeric, &units("2"), &units("10")), Ordering::Less);
    }

    #[test]
    fn lists_the_types_of_a_locale() {
        assert!(types("de").contains(&"phonebk"));
        assert!(types("de-DE").contains(&"phonebk"));
        assert!(!types("en").contains(&"phonebk"));
    }
}
