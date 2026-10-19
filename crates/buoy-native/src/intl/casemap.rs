//! `toLocaleLowerCase` and `toLocaleUpperCase` (ECMA-402 section 19.1): ICU4X's case
//! mapping with the tailorings of a language, such as the dotted and dotless i of Turkish
//! and Azeri, the dot above of Lithuanian, and the accents of Greek capitals.

use icu_casemap::CaseMapper;
use icu_locale::LanguageIdentifier;

/// The string of UTF-16 code units in lower or upper case for the language `tag`. A
/// lone surrogate has no case and stays as it is.
#[must_use]
pub fn change_case(tag: &str, units: &[u16], upper: bool) -> Vec<u16> {
    let language: LanguageIdentifier = tag.parse().unwrap_or(LanguageIdentifier::UNKNOWN);
    let case_mapper = CaseMapper::new();
    let mut out = Vec::with_capacity(units.len());
    let mut run = String::new();
    let flush = |run: &mut String, out: &mut Vec<u16>| {
        let mapped = if upper {
            case_mapper.uppercase_to_string(run, &language)
        } else {
            case_mapper.lowercase_to_string(run, &language)
        };
        out.extend(mapped.encode_utf16());
        run.clear();
    };
    for decoded in char::decode_utf16(units.iter().copied()) {
        match decoded {
            Ok(c) => run.push(c),
            Err(lone) => {
                flush(&mut run, &mut out);
                out.push(lone.unpaired_surrogate());
            }
        }
    }
    flush(&mut run, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn case(tag: &str, text: &str, upper: bool) -> String {
        String::from_utf16_lossy(&change_case(
            tag,
            &text.encode_utf16().collect::<Vec<_>>(),
            upper,
        ))
    }

    #[test]
    fn tailors_by_language() {
        assert_eq!(case("tr", "istanbul", true), "İSTANBUL");
        assert_eq!(case("und", "istanbul", true), "ISTANBUL");
        assert_eq!(case("tr", "I", false), "ı");
        assert_eq!(
            change_case("und", &[0x41, 0xD800, 0x42], false),
            vec![0x61, 0xD800, 0x62]
        );
    }
}
