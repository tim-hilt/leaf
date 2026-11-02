//! A Document's text as the Document Search searches it (GLOSSARY.md), and the
//! search over it. The text is held as chunks — a PDF's pages, an EPUB's spine
//! items — end to end, so a position in the whole text means the same in both
//! Formats and one search serves them both. It matches chunk by chunk in
//! reading order, numbers the matches and places each in the Table of
//! Contents, and hands them over a chunk at a time; a client that stops asking
//! cancels the search. A PDF's pages are read through the client (ADR-0003)
//! and kept here, so a page's text is extracted at most once while the
//! Document is open; an EPUB's spine items the core reads itself (ADR-0021),
//! and keeps none it didn't keep already (`Epub::searched_text`).

use crate::contents::{Entry, TableOfContents};
use crate::epub;
use crate::progress::Place;
use crate::search::{self, Query};
use std::ops::Range;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

/// What a client's PDF engine reads out of an open PDF's pages (ADR-0003) for
/// the Document Search. Implemented by the client; called from the thread that
/// searches, never the main one.
pub trait PdfPages: Send + Sync {
    /// The text of the page at `index`; none if it has none.
    fn page_text(&self, index: u32) -> Option<String>;
    /// The number printed on the page at `index`, or its position in the File.
    fn page_number(&self, index: u32) -> String;
    /// Where a match on the page at `index` sits, for the Table of Contents:
    /// the top of the matched text, as the client shows it. None if the text
    /// isn't on the page, which leaves the match out. Called once per match,
    /// in reading order.
    fn place_of_match(&self, index: u32, range: Range<usize>) -> Option<Place>;
}

/// A chunk of a Document's text: which one it is, and where its text sits in
/// the whole text, in UTF-16 units.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chunk {
    pub index: u32,
    /// Where its text starts in the whole text.
    pub start: u64,
    /// The length of its text.
    pub length: u64,
}

/// A match of a Document Search over a whole `DocumentText`: where it is in
/// its chunk's text and in the whole text, and where it sits in the Document.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    /// The match's number, from 0 in reading order.
    pub number: u64,
    /// The chunk the match is in: a page's index, or a spine item's.
    pub chunk: u32,
    /// Its range in the chunk's text, in UTF-16 units.
    pub range: Range<u64>,
    /// Its range in the whole text, in UTF-16 units.
    pub text: Range<u64>,
    pub excerpt: search::Excerpt,
    /// The Chapter or Section the match is in; none if the Document has no
    /// Table of Contents or the match is before its first entry.
    pub section: Option<Entry>,
}

/// A Document's text, chunk by chunk, for the Document Search (GLOSSARY.md).
pub struct DocumentText {
    source: Source,
    /// Where each chunk's text starts in the whole text, then where the last
    /// ends, in UTF-16 units; see `starts`.
    starts: OnceLock<Vec<u64>>,
}

/// Where a Document's chunks of text come from.
enum Source {
    /// An EPUB's spine items, which the core reads (ADR-0021). Their lengths
    /// are known without reading, so a search reads no item before its turn.
    Epub {
        epub: Arc<epub::Epub>,
        lengths: Vec<u64>,
    },
    /// A PDF's pages, which the client reads and the core keeps: `read` holds
    /// the text of every page read so far, and a page is read but once, from
    /// whatever thread asks.
    Pdf {
        reader: Arc<dyn PdfPages>,
        read: Mutex<Vec<Option<Arc<[u16]>>>>,
    },
}

impl DocumentText {
    /// The text of `epub`'s spine items.
    pub fn epub(epub: Arc<epub::Epub>) -> Self {
        let lengths = epub.characters();
        Self {
            source: Source::Epub { epub, lengths },
            starts: OnceLock::new(),
        }
    }

    /// The text of a PDF of `pages` pages, which `reader` reads out.
    pub fn pdf(pages: u32, reader: Arc<dyn PdfPages>) -> Self {
        Self {
            source: Source::Pdf {
                reader,
                read: Mutex::new(vec![None; pages as usize]),
            },
            starts: OnceLock::new(),
        }
    }

    /// Begins a Document Search (GLOSSARY.md) for `query` over the whole text,
    /// which places each match in `contents`, the Document's Table of Contents.
    pub fn search(self: &Arc<Self>, query: Query, contents: Arc<TableOfContents>) -> Search {
        Search {
            text: self.clone(),
            contents,
            query,
            progress: Mutex::new(Progress::default()),
        }
    }

    /// The length of the whole text, in UTF-16 units. Reads every chunk, see
    /// `starts`.
    pub fn length(&self) -> u64 {
        self.starts().last().copied().unwrap_or(0)
    }

    /// The chunk at `index`; none beyond the chunks. Reads every chunk, see
    /// `starts`.
    pub fn chunk(&self, index: u32) -> Option<Chunk> {
        let starts = self.starts();
        let index = index as usize;
        let (start, end) = (*starts.get(index)?, *starts.get(index + 1)?);
        Some(Chunk {
            index: index as u32,
            start,
            length: end - start,
        })
    }

    /// The chunk holding the character at `offset` in the whole text: the last
    /// one starting at or before it, so empty chunks — which share their start
    /// with the next one — are skipped. None without chunks. Reads every
    /// chunk, see `starts`.
    pub fn chunk_containing(&self, offset: u64) -> Option<Chunk> {
        let chunks = self.starts().len().checked_sub(1)?;
        let after = self.starts()[..chunks].partition_point(|&start| start <= offset);
        self.chunk(after.checked_sub(1)? as u32)
    }

    /// Where each chunk's text starts in the whole text, then where the last
    /// one ends, in UTF-16 units. Worked out once, reading every chunk, so
    /// later calls take no lock.
    fn starts(&self) -> &[u64] {
        self.starts.get_or_init(|| {
            let mut at = 0;
            std::iter::once(0)
                .chain((0..self.chunks()).map(|index| {
                    at += self.chunk_length(index);
                    at
                }))
                .collect()
        })
    }

    /// The text of the chunk at `index`; none beyond the chunks.
    pub fn text(&self, index: u32) -> Option<String> {
        self.units(index as usize)
            .map(|units| String::from_utf16_lossy(&units))
    }

    /// The number printed on the chunk at `index`: a PDF page's, or its
    /// position in the File; none in a Format without pages.
    pub fn page_number(&self, index: u32) -> Option<String> {
        match &self.source {
            Source::Epub { .. } => None,
            Source::Pdf { reader, .. } => Some(reader.page_number(index)),
        }
    }

    /// How many chunks of text there are.
    fn chunks(&self) -> usize {
        match &self.source {
            Source::Epub { lengths, .. } => lengths.len(),
            Source::Pdf { read, .. } => read.lock().unwrap_or_else(PoisonError::into_inner).len(),
        }
    }

    /// The text of the chunk at `index`, in UTF-16 units; none beyond the
    /// chunks, and none for one that can't be read.
    fn units(&self, index: usize) -> Option<Arc<[u16]>> {
        match &self.source {
            Source::Epub { epub, .. } => epub.searched_text(index),
            Source::Pdf { reader, read } => {
                let mut read = read.lock().unwrap_or_else(PoisonError::into_inner);
                match &read[index] {
                    Some(units) => Some(units.clone()),
                    // Read with the lock held, so a page is never read twice.
                    None => {
                        let units: Arc<[u16]> = reader
                            .page_text(index as u32)
                            .unwrap_or_default()
                            .encode_utf16()
                            .collect::<Vec<_>>()
                            .into();
                        read[index] = Some(units.clone());
                        Some(units)
                    }
                }
            }
        }
    }

    /// The length of the text of the chunk at `index`, in UTF-16 units; 0
    /// beyond the chunks. Reads the chunk unless its length is known without.
    fn chunk_length(&self, index: usize) -> u64 {
        match &self.source {
            Source::Epub { lengths, .. } => lengths.get(index).copied().unwrap_or(0),
            Source::Pdf { .. } => self.units(index).map_or(0, |units| units.len() as u64),
        }
    }

    /// Where a match in the chunk at `index` sits, for the Table of Contents:
    /// an EPUB's at its offset in its spine item (ADR-0022), a PDF's where its
    /// page's client puts it. None if it can't be placed, which leaves the
    /// match out.
    fn place_of_match(&self, index: usize, range: Range<usize>) -> Option<Place> {
        match &self.source {
            Source::Epub { .. } => Some(Place::Epub {
                spine_index: index as u32,
                offset: range.start as u64,
            }),
            Source::Pdf { reader, .. } => reader.place_of_match(index as u32, range),
        }
    }
}

/// One Document Search (GLOSSARY.md) over a `DocumentText`: the matches of a
/// query, a chunk's worth at a time, in reading order. Each match is numbered
/// from 0 and placed in the Chapter or Section that contains it. The client
/// asks for the next chunk's matches until there are none; it may stop at any
/// point, which cancels the search.
pub struct Search {
    text: Arc<DocumentText>,
    contents: Arc<TableOfContents>,
    query: Query,
    /// Where the search is, and what it has found. The lock is never held
    /// while a chunk is searched, so the numbers can be asked meanwhile.
    progress: Mutex<Progress>,
}

#[derive(Default)]
struct Progress {
    /// The next chunk to search.
    next: usize,
    /// Where `next`'s chunk starts in the whole text, in UTF-16 units.
    offset: u64,
    /// Where each match found so far starts in the whole text, in UTF-16
    /// units, in reading order: matches are numbered by their place here.
    starts: Vec<u64>,
}

impl Search {
    /// The matches in the next chunk of the text, in reading order; none once
    /// the whole text has been searched. The chunk is searched on the calling
    /// thread, one `next` at a time.
    pub fn next(&self) -> Option<Vec<Found>> {
        let (index, offset) = {
            let mut progress = self.progress.lock().unwrap_or_else(PoisonError::into_inner);
            let (index, offset) = (progress.next, progress.offset);
            if index < self.text.chunks() {
                progress.next += 1;
            }
            (index, offset)
        };
        if index >= self.text.chunks() {
            return None;
        }
        let units = self.text.units(index).unwrap_or_default();
        let mut found: Vec<_> = self
            .query
            .find(&units)
            .into_iter()
            .filter_map(|matched| {
                let place = self.text.place_of_match(index, matched.range.clone())?;
                let section = self.contents.position(place).map(|at| at.current);
                let start = offset + matched.range.start as u64;
                Some(Found {
                    number: 0,
                    chunk: index as u32,
                    range: matched.range.start as u64..matched.range.end as u64,
                    text: start..offset + matched.range.end as u64,
                    excerpt: matched.excerpt,
                    section,
                })
            })
            .collect();
        let mut progress = self.progress.lock().unwrap_or_else(PoisonError::into_inner);
        let first = progress.starts.len() as u64;
        for (number, found) in found.iter_mut().enumerate() {
            found.number = first + number as u64;
        }
        progress
            .starts
            .extend(found.iter().map(|found| found.text.start));
        // The chunk's text was read for the search, so its length costs nothing.
        progress.offset += self.text.chunk_length(index);
        Some(found)
    }

    /// The number of the match that starts at `offset` in the whole text, if
    /// one has been found so far.
    pub fn number_at(&self, offset: u64) -> Option<u64> {
        self.progress
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .starts
            .binary_search(&offset)
            .ok()
            .map(|number| number as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contents::ContentsEntry;
    use crate::epub::fixtures::{Book, open};
    use crate::search::WordMatch;

    /// A query for `text`, contained and ignoring case.
    fn query(text: &str) -> Query {
        Query {
            text: text.to_owned(),
            case_sensitive: false,
            word_match: WordMatch::Contains,
        }
    }

    /// Every match of `search`, asked for chunk by chunk.
    fn all(search: &Search) -> Vec<Found> {
        let mut found = Vec::new();
        while let Some(batch) = search.next() {
            found.extend(batch);
        }
        found
    }

    /// The texts of `found`, from their chunks.
    fn texts(found: &[Found], text: &DocumentText) -> Vec<String> {
        found
            .iter()
            .map(|found| {
                String::from_utf16_lossy(
                    &text.units(found.chunk as usize).unwrap()
                        [found.range.start as usize..found.range.end as usize],
                )
            })
            .collect()
    }

    /// A PDF whose pages' text is `pages`, read through a reader that counts
    /// how often each page was read.
    struct Pages {
        texts: Vec<String>,
        reads: Mutex<Vec<u32>>,
    }

    impl Pages {
        fn new(texts: &[&str]) -> Arc<Self> {
            Arc::new(Self {
                texts: texts.iter().map(|text| (*text).to_owned()).collect(),
                reads: Mutex::new(vec![0; texts.len()]),
            })
        }

        fn reads(&self) -> Vec<u32> {
            self.reads.lock().unwrap().clone()
        }
    }

    /// The match sits at the top of its page, unless the page has no such text.
    fn top(page_index: u32, range: Range<usize>) -> Option<Place> {
        if range.is_empty() {
            None
        } else {
            Some(place(page_index))
        }
    }

    fn place(page_index: u32) -> Place {
        Place::Pdf {
            page_index,
            x: 0.0,
            y: 720.0,
        }
    }

    impl PdfPages for Pages {
        fn page_text(&self, index: u32) -> Option<String> {
            *self.reads.lock().unwrap().get_mut(index as usize).unwrap() += 1;
            self.texts.get(index as usize).cloned()
        }

        fn page_number(&self, index: u32) -> String {
            (index + 1).to_string()
        }

        fn place_of_match(&self, index: u32, range: Range<usize>) -> Option<Place> {
            top(index, range)
        }
    }

    /// A Chapter at the top of page 1 with a Section on page 2, and one on page 3.
    fn contents() -> Arc<TableOfContents> {
        Arc::new(TableOfContents::new(vec![
            ContentsEntry {
                title: "Chapter 1".into(),
                page_label: None,
                place: top(1, 0..1),
                sections: vec![entry("Section 1.1", top(2, 0..1))],
            },
            entry("Chapter 2", top(3, 0..1)),
        ]))
    }

    fn entry(title: &str, place: Option<Place>) -> ContentsEntry {
        ContentsEntry {
            title: title.into(),
            page_label: None,
            place,
            sections: vec![],
        }
    }

    #[test]
    fn a_page_is_read_but_once_whatever_reads_it() {
        let pages = Pages::new(&["apple", "pie"]);
        let text = DocumentText::pdf(2, pages.clone());

        assert_eq!(text.text(0).as_deref(), Some("apple"));
        assert_eq!(text.text(1).as_deref(), Some("pie"));
        assert_eq!(text.text(0).as_deref(), Some("apple"));
        assert_eq!(pages.reads(), [1, 1]);
    }

    #[test]
    fn a_page_without_text_is_empty_and_read_but_once() {
        let pages = Pages::new(&["apple", "", "pie"]);
        let text = DocumentText::pdf(3, pages.clone());

        assert_eq!(text.text(1).as_deref(), Some(""));
        assert_eq!(text.text(1).as_deref(), Some(""));
        assert_eq!(pages.reads(), [0, 1, 0]);
    }

    #[test]
    fn a_chunk_knows_where_its_text_sits_in_the_whole_text() {
        let text = DocumentText::pdf(3, Pages::new(&["apple", "", "banana pie"]));

        assert_eq!(
            text.chunk(0),
            Some(Chunk {
                index: 0,
                start: 0,
                length: 5
            })
        );
        assert_eq!(
            text.chunk(2),
            Some(Chunk {
                index: 2,
                start: 5,
                length: 10
            })
        );
        assert_eq!(text.chunk(3), None);
        assert_eq!(text.length(), 15);
    }

    #[test]
    fn a_character_is_found_in_the_chunk_holding_it() {
        let text = DocumentText::pdf(3, Pages::new(&["apple", "", "banana pie"]));

        // An empty chunk shares its start with the next one, which holds the text.
        assert_eq!(text.chunk_containing(0).map(|chunk| chunk.index), Some(0));
        assert_eq!(text.chunk_containing(5).map(|chunk| chunk.index), Some(2));
        assert_eq!(text.chunk_containing(14).map(|chunk| chunk.index), Some(2));
    }

    #[test]
    fn a_search_finds_the_matches_across_the_chunks_in_reading_order_and_numbers_them() {
        let text = Arc::new(DocumentText::pdf(
            3,
            Pages::new(&["apple pie, apple", "", "an apple"]),
        ));
        let search = text.search(query("apple"), contents());

        let found = all(&search);
        assert_eq!(
            found.iter().map(|found| found.chunk).collect::<Vec<_>>(),
            [0, 0, 2]
        );
        assert_eq!(
            found.iter().map(|found| found.number).collect::<Vec<_>>(),
            [0, 1, 2]
        );
        assert_eq!(
            found
                .iter()
                .map(|found| found.text.clone())
                .collect::<Vec<_>>(),
            [0..5, 11..16, 19..24]
        );
        assert_eq!(
            found
                .iter()
                .map(|found| found.range.clone())
                .collect::<Vec<_>>(),
            [0..5, 11..16, 3..8]
        );
        assert_eq!(texts(&found, &text), ["apple"; 3]);
    }

    #[test]
    fn a_search_places_each_match_in_its_chapter_or_section() {
        let text = Arc::new(DocumentText::pdf(
            4,
            Pages::new(&["preface apple", "apple", "apple", "apple"]),
        ));
        let search = text.search(query("apple"), contents());

        let found = all(&search);
        // Nothing contains the preface.
        assert_eq!(
            found
                .iter()
                .map(|found| found.section.as_ref().map(|section| &*section.title))
                .collect::<Vec<_>>(),
            [
                None,
                Some("Chapter 1"),
                Some("Section 1.1"),
                Some("Chapter 2")
            ]
        );
    }

    #[test]
    fn a_match_that_cannot_be_placed_is_left_out_and_the_numbering_goes_on() {
        struct PagesWithoutPlace;
        impl PdfPages for PagesWithoutPlace {
            fn page_text(&self, _: u32) -> Option<String> {
                Some("apple".into())
            }
            fn page_number(&self, index: u32) -> String {
                (index + 1).to_string()
            }
            fn place_of_match(&self, index: u32, _: Range<usize>) -> Option<Place> {
                if index != 0 { Some(place(index)) } else { None }
            }
        }

        let text = Arc::new(DocumentText::pdf(2, Arc::new(PagesWithoutPlace)));
        let search = text.search(query("apple"), contents());

        let found = all(&search);
        assert_eq!(
            found.iter().map(|found| found.chunk).collect::<Vec<_>>(),
            [1]
        );
        assert_eq!(
            found.iter().map(|found| found.number).collect::<Vec<_>>(),
            [0]
        );
    }

    #[test]
    fn the_match_at_a_text_offset_is_found_by_its_number_once_searched() {
        let text = Arc::new(DocumentText::pdf(
            2,
            Pages::new(&["apple pie, apple", "an apple"]),
        ));
        let search = text.search(query("apple"), contents());

        assert_eq!(search.number_at(0), None);
        assert!(search.next().is_some());

        assert_eq!(search.number_at(0), Some(0));
        assert_eq!(search.number_at(11), Some(1));
        assert_eq!(search.number_at(1), None);

        // A match of a chunk not searched yet is not found.
        assert_eq!(search.number_at(19), None);
        assert!(search.next().is_some());
        assert_eq!(search.number_at(19), Some(2));
    }

    #[test]
    fn a_search_stopped_early_ends_without_the_rest_and_a_new_one_starts_afresh() {
        let text = Arc::new(DocumentText::pdf(
            3,
            Pages::new(&["apple", "apple", "apple"]),
        ));

        let search = text.search(query("apple"), contents());
        assert_eq!(search.next().map(|batch| batch.len()), Some(1));

        // The rest is never asked for, and a new search starts afresh.
        let search = text.search(query("apple"), contents());
        assert_eq!(all(&search).len(), 3);
    }

    #[test]
    fn an_epub_is_searched_across_its_spine_items() {
        let book = Book::new("").chapters(&[
            "<p>apple pie, apple</p>",
            "<p>nothing</p>",
            "<p>an apple</p>",
        ]);
        // Counted at Import, as the Reader opens a book.
        let epub = Arc::new(open(&book.bytes()).unwrap().with_characters(vec![16, 7, 8]));
        let text = Arc::new(DocumentText::epub(epub.clone()));
        let search = text.search(query("apple"), contents());

        let found = all(&search);
        assert_eq!(
            found.iter().map(|found| found.chunk).collect::<Vec<_>>(),
            [0, 0, 2]
        );
        assert_eq!(
            found.iter().map(|found| found.number).collect::<Vec<_>>(),
            [0, 1, 2]
        );
        assert_eq!(texts(&found, &text), ["apple"; 3]);
        assert_eq!(text.text(0).as_deref(), Some("apple pie, apple"));
        assert_eq!(text.length(), 31);
        // The book keeps none of the items the search read.
        assert_eq!(epub.scanned_items(), 0);
    }
}
