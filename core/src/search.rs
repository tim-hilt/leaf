//! Document Search's matching (GLOSSARY.md), the same on every platform. It
//! works on a text in UTF-16 units, the units positions count in (ADR-0022), so
//! a PDF page's text and an EPUB spine item's are matched alike.

use std::ops::Range;
use unicode_normalization::char::is_combining_mark;

/// Which occurrences of a query's text are matches, by word boundaries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WordMatch {
    /// Anywhere, even inside a longer word.
    Contains,
    /// At the start of a word.
    StartsWith,
    /// At the end of a word.
    EndsWith,
    /// A whole word, delimited on both sides.
    FullWord,
}

/// What Document Search looks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Query {
    pub text: String,
    /// Whether case must agree; otherwise case is ignored, as in the system find bar.
    pub case_sensitive: bool,
    pub word_match: WordMatch,
}

/// A match: where it is in the searched text, and the text around it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    /// Its range in the searched text, in UTF-16 units.
    pub range: Range<usize>,
    pub excerpt: Excerpt,
}

/// The text around a match, on one line, for telling matches apart in a list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Excerpt {
    pub text: String,
    /// The match in `text`, in UTF-16 units.
    pub matched: Range<usize>,
}

/// How much text an excerpt keeps before its match and after it, in UTF-16 units.
const BEFORE: usize = 40;
const AFTER: usize = 80;

impl Query {
    /// The matches of the query in `text`, in order and without overlap. An
    /// occurrence of the query's text is a match if it starts and ends where
    /// `word_match` asks. An empty query has none.
    pub fn find(&self, text: &[u16]) -> Vec<Match> {
        let mut needle = Vec::new();
        for c in self.text.chars() {
            if self.case_sensitive {
                needle.push(c);
            } else {
                fold(c, |folded| needle.push(folded));
            }
        }
        let mut found = Vec::new();
        if needle.is_empty() {
            return found;
        }
        let mut at = 0;
        while at < text.len() {
            match self.occurrence_at(text, at, &needle) {
                Some(end) => {
                    if self.accepts(text, at..end) {
                        let excerpt = Excerpt::around(text, at..end);
                        found.push(Match {
                            range: at..end,
                            excerpt,
                        });
                    }
                    at = end;
                }
                None => at = next_char(text, at),
            }
        }
        found
    }

    /// The end of the occurrence of `needle` that starts at `at`, if there is one.
    fn occurrence_at(&self, text: &[u16], at: usize, needle: &[char]) -> Option<usize> {
        let mut rest = needle;
        let mut end = at;
        while !rest.is_empty() {
            let (c, width) = char_at(text, end)?;
            let matched = if self.case_sensitive {
                take(&mut rest, c)
            } else {
                let mut all = true;
                fold(c, |folded| all = all && take(&mut rest, folded));
                all
            };
            if !matched {
                return None;
            }
            end += width;
        }
        Some(end)
    }

    /// Whether the occurrence at `range` starts and ends where `word_match` asks.
    fn accepts(&self, text: &[u16], range: Range<usize>) -> bool {
        let starts_word = !char_before(text, range.start).is_some_and(is_word);
        let ends_word = !char_at(text, range.end).is_some_and(|(c, _)| is_word(c));
        match self.word_match {
            WordMatch::Contains => true,
            WordMatch::StartsWith => starts_word,
            WordMatch::EndsWith => ends_word,
            WordMatch::FullWord => starts_word && ends_word,
        }
    }
}

impl Excerpt {
    /// The text of `text` around `range`: up to `BEFORE` units before it and
    /// `AFTER` after, cut so that no character is split, with each run of white
    /// space made one space and none at either end.
    fn around(text: &[u16], range: Range<usize>) -> Self {
        let start = excerpt_start(text, range.start.saturating_sub(BEFORE));
        let end = excerpt_end(text, (range.end + AFTER).min(text.len()));
        let (mut out, mut width, mut space) = (String::new(), 0, false);
        let (mut matched_start, mut matched_end) = (None, None);
        let mut at = start;
        while at < end {
            if at >= range.end {
                matched_end.get_or_insert(width);
            }
            let Some((c, units)) = char_at(text, at) else {
                break;
            };
            if c.is_whitespace() {
                if at >= range.start {
                    matched_start.get_or_insert(width);
                }
                space |= !out.is_empty();
            } else {
                if space {
                    out.push(' ');
                    width += 1;
                    space = false;
                }
                if at >= range.start {
                    matched_start.get_or_insert(width);
                }
                out.push(c);
                width += c.len_utf16();
            }
            at += units;
        }
        Self {
            text: out,
            matched: matched_start.unwrap_or(width)..matched_end.unwrap_or(width),
        }
    }
}

/// Calls `emit` with the characters `c` folds to when case is ignored: its
/// uppercase, lowercased again, so "ß" folds to "ss" as NSString's case-insensitive
/// search does. The dotless "ı" stays itself: NSString doesn't take it for "i".
fn fold(c: char, mut emit: impl FnMut(char)) {
    if c == 'ı' {
        return emit(c);
    }
    for upper in c.to_uppercase() {
        for lower in upper.to_lowercase() {
            emit(lower);
        }
    }
}

/// Removes `c` from the front of `rest` if it starts with it.
fn take(rest: &mut &[char], c: char) -> bool {
    match rest.split_first() {
        Some((first, tail)) if *first == c => {
            *rest = tail;
            true
        }
        _ => false,
    }
}

/// Whether `c` is part of a word: a letter or digit, or a mark that goes with one.
fn is_word(c: char) -> bool {
    c.is_alphanumeric() || is_combining_mark(c)
}

/// The character starting at UTF-16 index `at` and its width in units; a lone
/// surrogate reads as U+FFFD. None at or past the end.
fn char_at(text: &[u16], at: usize) -> Option<(char, usize)> {
    match char::decode_utf16(text.get(at..)?.iter().copied()).next()? {
        Ok(c) => Some((c, c.len_utf16())),
        Err(_) => Some((char::REPLACEMENT_CHARACTER, 1)),
    }
}

/// The character that ends at UTF-16 index `at`; None at the start.
fn char_before(text: &[u16], at: usize) -> Option<char> {
    if at == 0 {
        return None;
    }
    char_at(text, previous_boundary(text, at)).map(|(c, _)| c)
}

/// Where the character that ends at `at` (above 0) starts.
fn previous_boundary(text: &[u16], at: usize) -> usize {
    if at >= 2 && is_low(text[at - 1]) && is_high(text[at - 2]) {
        at - 2
    } else {
        at - 1
    }
}

/// Where the character after the one starting at `at` starts.
fn next_char(text: &[u16], at: usize) -> usize {
    at + char_at(text, at).map_or(1, |(_, width)| width)
}

fn is_high(unit: u16) -> bool {
    matches!(unit, 0xD800..=0xDBFF)
}

fn is_low(unit: u16) -> bool {
    matches!(unit, 0xDC00..=0xDFFF)
}

/// Whether `at` is inside a surrogate pair.
fn splits_pair(text: &[u16], at: usize) -> bool {
    at > 0 && at < text.len() && is_low(text[at]) && is_high(text[at - 1])
}

/// `at`, moved back to where a character starts, and back past the combining
/// marks that go with the character before them.
fn excerpt_start(text: &[u16], at: usize) -> usize {
    let mut at = if splits_pair(text, at) { at - 1 } else { at };
    while at > 0 && char_at(text, at).is_some_and(|(c, _)| is_combining_mark(c)) {
        at = previous_boundary(text, at);
    }
    at
}

/// `at`, moved forward to where a character ends, and past the combining marks
/// that go with it.
fn excerpt_end(text: &[u16], at: usize) -> usize {
    let mut at = if splits_pair(text, at) { at + 1 } else { at };
    while let Some((c, width)) = char_at(text, at)
        && is_combining_mark(c)
    {
        at += width;
    }
    at
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `text` in UTF-16 units, as the core searches it.
    fn units(text: &str) -> Vec<u16> {
        text.encode_utf16().collect()
    }

    /// A case-insensitive query for `text` with `word_match`.
    fn query(text: &str, word_match: WordMatch) -> Query {
        Query {
            text: text.to_owned(),
            case_sensitive: false,
            word_match,
        }
    }

    /// Where the matches of `query` in `text` are, in UTF-16 units.
    fn ranges(query: &Query, text: &str) -> Vec<Range<usize>> {
        query
            .find(&units(text))
            .into_iter()
            .map(|m| m.range)
            .collect()
    }

    /// The excerpts of the matches of `word` (contained, ignoring case) in `text`.
    fn excerpts(text: &str, word: &str) -> Vec<Excerpt> {
        query(word, WordMatch::Contains)
            .find(&units(text))
            .into_iter()
            .map(|m| m.excerpt)
            .collect()
    }

    /// The text of `excerpt`'s match.
    fn matched(excerpt: &Excerpt) -> String {
        String::from_utf16_lossy(&units(&excerpt.text)[excerpt.matched.clone()])
    }

    /// "cat" as a word at the start and end, among punctuation, and inside
    /// "category", "bobcat" and "cats".
    const CATS: &str = "cat category, (cat) bobcat cats cat-food. cat";

    #[test]
    fn contains_matches_inside_words() {
        assert_eq!(ranges(&query("cat", WordMatch::Contains), CATS).len(), 7);
    }

    #[test]
    fn starts_with_matches_at_the_start_of_a_word() {
        // Not "bobcat": it is the end of a word.
        assert_eq!(ranges(&query("cat", WordMatch::StartsWith), CATS).len(), 6);
    }

    #[test]
    fn ends_with_matches_at_the_end_of_a_word() {
        // Not "category" or "cats": a letter follows.
        assert_eq!(ranges(&query("cat", WordMatch::EndsWith), CATS).len(), 5);
    }

    #[test]
    fn full_word_matches_whole_words_only() {
        // The first and last on the text, "(cat)" and "cat-food".
        assert_eq!(ranges(&query("cat", WordMatch::FullWord), CATS).len(), 4);
    }

    #[test]
    fn full_word_matches_a_text_that_is_one_word() {
        assert_eq!(
            ranges(&query("cat", WordMatch::FullWord), "cat"),
            vec![0..3]
        );
    }

    #[test]
    fn digits_are_part_of_words_and_punctuation_is_not() {
        assert_eq!(
            ranges(&query("cat", WordMatch::StartsWith), "1cat cat"),
            vec![5..8]
        );
        assert_eq!(
            ranges(&query("cat", WordMatch::StartsWith), "_cat"),
            vec![1..4]
        );
    }

    #[test]
    fn a_combining_mark_is_part_of_the_word_before_it() {
        // "cafe" followed by a combining acute accent is "café", not "cafe".
        let text = "cafe\u{301} cafe";
        assert_eq!(
            ranges(&query("cafe", WordMatch::FullWord), text),
            vec![6..10]
        );
    }

    #[test]
    fn occurrences_do_not_overlap() {
        assert_eq!(ranges(&query("aa", WordMatch::Contains), "aaa"), vec![0..2]);
        assert_eq!(
            ranges(&query("aa", WordMatch::Contains), "aaaa"),
            vec![0..2, 2..4]
        );
    }

    #[test]
    fn ranges_are_in_utf16_units() {
        assert_eq!(
            ranges(&query("apple", WordMatch::Contains), "😀 apple"),
            vec![3..8]
        );
    }

    #[test]
    fn finds_every_occurrence_in_order() {
        assert_eq!(
            ranges(&query("apple", WordMatch::Contains), "apple pie, apple"),
            vec![0..5, 11..16]
        );
    }

    #[test]
    fn ignores_case_unless_asked_not_to() {
        let text = "Apple apple APPLE";
        let sensitive = |text: &str| Query {
            text: text.to_owned(),
            case_sensitive: true,
            word_match: WordMatch::Contains,
        };

        assert_eq!(
            ranges(&query("apple", WordMatch::Contains), text),
            vec![0..5, 6..11, 12..17]
        );
        assert_eq!(ranges(&sensitive("apple"), text), vec![6..11]);
        assert_eq!(ranges(&sensitive("Apple"), text), vec![0..5]);
    }

    #[test]
    fn case_insensitive_matching_agrees_with_ns_string_for_common_text() {
        // Each expected result is what NSString's `range(of:options:)` with
        // `.caseInsensitive` finds, for the same text and query.
        let cases: [(&str, &str, Vec<Range<usize>>); 13] = [
            ("Café café CAFÉ", "café", vec![0..4, 5..9, 10..14]),
            ("ÀÉÎ àéî", "àéî", vec![0..3, 4..7]),
            ("Ärger ärger ÄRGER", "ärger", vec![0..5, 6..11, 12..17]),
            ("Привет привет ПРИВЕТ", "привет", vec![0..6, 7..13, 14..20]),
            ("ΑΒΓ αβγ", "αβγ", vec![0..3, 4..7]),
            ("Ω ω Ω", "ω", vec![0..1, 2..3, 4..5]),
            ("ÉCOLE école", "École", vec![0..5, 6..11]),
            ("ÇA ça", "ça", vec![0..2, 3..5]),
            ("ǅ ǆ Ǆ", "ǆ", vec![0..1, 2..3, 4..5]),
            ("ς σ Σ", "σ", vec![0..1, 2..3, 4..5]),
            // "ß" is "ss", "ſ" is "s" and "ﬁ" is "fi", as in full case folding.
            ("Straße STRASSE straße", "straße", vec![0..6, 7..14, 15..21]),
            ("ſ S s", "s", vec![0..1, 2..3, 4..5]),
            ("ﬁle FILE file", "file", vec![0..3, 4..8, 9..13]),
        ];
        for (text, query_text, expected) in cases {
            assert_eq!(
                ranges(&query(query_text, WordMatch::Contains), text),
                expected,
                "{text} / {query_text}"
            );
        }
        // NSString keeps the dotless ı apart from "i", and "İ" from "i".
        assert_eq!(
            ranges(&query("i", WordMatch::Contains), "ı I i"),
            vec![2..3, 4..5]
        );
        assert_eq!(
            ranges(&query("istanbul", WordMatch::Contains), "İstanbul istanbul"),
            vec![9..17]
        );
    }

    #[test]
    fn an_empty_query_or_text_has_no_matches() {
        assert!(ranges(&query("", WordMatch::Contains), "apple").is_empty());
        assert!(ranges(&query("apple", WordMatch::Contains), "").is_empty());
    }

    #[test]
    fn an_excerpt_is_the_text_around_the_match_with_the_match_in_it() {
        let found = excerpts("The quick brown fox jumps over the lazy dog", "fox");

        assert_eq!(found[0].text, "The quick brown fox jumps over the lazy dog");
        assert_eq!(matched(&found[0]), "fox");
    }

    #[test]
    fn an_excerpt_keeps_forty_units_before_the_match_and_eighty_after() {
        let text = format!("{}needle{}", "a".repeat(100), "b".repeat(200));

        let found = &excerpts(&text, "needle")[0];

        assert_eq!(
            found.text,
            format!("{}needle{}", "a".repeat(40), "b".repeat(80))
        );
        assert_eq!(found.matched, 40..46);
    }

    #[test]
    fn an_excerpt_is_on_one_line_with_white_space_collapsed() {
        let found = &excerpts("Lorem\n\n  ipsum\tdolor sit\r\namet", "dolor")[0];

        assert_eq!(found.text, "Lorem ipsum dolor sit amet");
        assert_eq!(found.matched, 12..17);
    }

    #[test]
    fn an_excerpt_has_no_white_space_at_either_end() {
        let found = &excerpts("  cat \n", "cat")[0];

        assert_eq!(found.text, "cat");
        assert_eq!(found.matched, 0..3);
    }

    #[test]
    fn an_excerpt_at_the_edges_of_the_text_is_cut_there() {
        let found = excerpts("cat sat on a cat", "cat");

        assert_eq!(
            found.iter().map(|e| e.text.as_str()).collect::<Vec<_>>(),
            ["cat sat on a cat"; 2]
        );
        assert_eq!(
            found.iter().map(|e| e.matched.start).collect::<Vec<_>>(),
            [0, 13]
        );
    }

    #[test]
    fn an_excerpt_never_splits_a_surrogate_pair() {
        // The window starts 40 units before the match, in the middle of an
        // emoji, which it takes whole instead.
        let text = format!("{}x{}", "😀".repeat(30), "needle");

        let found = &excerpts(&text, "needle")[0];

        assert_eq!(found.text, format!("{}xneedle", "😀".repeat(20)));
        assert_eq!(found.matched, 41..47);
    }

    #[test]
    fn an_excerpt_never_starts_or_ends_with_a_split_combining_mark() {
        // The window would start on the combining accent of "é", and end on the
        // "é" before its accent; both are taken with their letter.
        let start = format!("{}e\u{301}{}needle", "x".repeat(39), "z".repeat(39));
        let found = &excerpts(&start, "needle")[0];
        assert_eq!(found.text, format!("e\u{301}{}needle", "z".repeat(39)));
        assert_eq!(found.matched, 41..47);

        let end = format!("needle{}e\u{301}y", "x".repeat(79));
        let found = &excerpts(&end, "needle")[0];
        assert_eq!(found.text, format!("needle{}e\u{301}", "x".repeat(79)));
    }
}
