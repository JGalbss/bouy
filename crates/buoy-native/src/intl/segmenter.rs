//! `Intl.Segmenter` on ICU4X's segmenters (ECMA-402 section 19): the grapheme clusters,
//! words, and sentences of UAX #29 with the tailorings of the locale, and the
//! dictionaries of Chinese, Japanese, Thai, Lao, Khmer, and Burmese words, as V8 takes
//! them from ICU4C's break iterators.

use icu_locale::LanguageIdentifier;
use icu_segmenter::options::{
    SentenceBreakInvariantOptions, SentenceBreakOptions, WordBreakInvariantOptions,
    WordBreakOptions,
};
use icu_segmenter::{GraphemeClusterSegmenter, SentenceSegmenter, WordSegmenter};

/// The unit of a segmentation.
#[derive(Clone, Copy, Debug)]
pub enum Granularity {
    Grapheme,
    Word,
    Sentence,
}

/// The boundaries of the UTF-16 text in the locale `tag`, from 0 to its length, each with
/// whether the segment before it is word-like (letters, numbers, or ideographs; only words
/// have such segments).
#[must_use]
pub fn boundaries(granularity: Granularity, tag: &str, text: &[u16]) -> Vec<(usize, bool)> {
    let language: Option<LanguageIdentifier> = tag.parse().ok();
    match granularity {
        Granularity::Grapheme => GraphemeClusterSegmenter::new()
            .segment_utf16(text)
            .map(|index| (index, false))
            .collect(),
        Granularity::Word => {
            let mut options = WordBreakOptions::default();
            options.content_locale = language.as_ref();
            let segmenter = WordSegmenter::try_new_dictionary(options).unwrap_or_else(|_| {
                WordSegmenter::new_dictionary(WordBreakInvariantOptions::default())
                    .static_to_owned()
            });
            let mut boundaries = Vec::new();
            let mut iterator = segmenter.as_borrowed().segment_utf16(text);
            while let Some(index) = iterator.next() {
                boundaries.push((index, iterator.is_word_like()));
            }
            boundaries
        }
        Granularity::Sentence => {
            let mut options = SentenceBreakOptions::default();
            options.content_locale = language.as_ref();
            let segmenter = SentenceSegmenter::try_new(options).unwrap_or_else(|_| {
                SentenceSegmenter::new(SentenceBreakInvariantOptions::default()).static_to_owned()
            });
            segmenter
                .as_borrowed()
                .segment_utf16(text)
                .map(|index| (index, false))
                .collect()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utf16(text: &str) -> Vec<u16> {
        text.encode_utf16().collect()
    }

    #[test]
    fn finds_words_and_sentences() {
        let words = boundaries(Granularity::Word, "en", &utf16("Hello, world"));
        assert_eq!(
            words,
            [(0, false), (5, true), (6, false), (7, false), (12, true)]
        );
        let sentences = boundaries(Granularity::Sentence, "en", &utf16("Hi. Bye."));
        assert_eq!(sentences, [(0, false), (4, false), (8, false)]);
        let graphemes = boundaries(Granularity::Grapheme, "en", &utf16("e\u{301}x"));
        assert_eq!(graphemes, [(0, false), (2, false), (3, false)]);
    }
}
