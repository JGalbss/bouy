//! The locale data of `Intl.NumberFormat` on ICU4X's decimal data (ECMA-402 section 16):
//! the engine rounds and lays out the number, as V8 and `JavaScriptCore` do over ICU4C's
//! number skeletons, and reads the symbols and patterns of the locale here.

use icu_decimal::CompactDecimalFormatter;
use icu_decimal::options::CompactDecimalFormatterOptions;
use icu_locale::Locale;

/// `ComputeExponentForMagnitude` in compact notation: the power of ten by which the locale
/// `tag` scales a number whose leading digit has the magnitude, short or long, such as 3
/// for thousands. A locale without compact data scales by 0.
#[must_use]
pub fn compact_exponent(tag: &str, long: bool, magnitude: i16) -> u8 {
    let Ok(locale) = tag.parse::<Locale>() else {
        return 0;
    };
    let formatter = if long {
        CompactDecimalFormatter::try_new_long(
            (&locale).into(),
            CompactDecimalFormatterOptions::default(),
        )
    } else {
        CompactDecimalFormatter::try_new_short(
            (&locale).into(),
            CompactDecimalFormatterOptions::default(),
        )
    };
    formatter.map_or(0, |formatter| {
        formatter.compact_exponent_for_magnitude(magnitude)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_compact_exponents() {
        assert_eq!(compact_exponent("fr", false, 6), 6);
        assert_eq!(compact_exponent("ja", true, 6), 4);
        assert_eq!(compact_exponent("en", false, 2), 0);
    }
}
