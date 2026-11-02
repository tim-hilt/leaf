//! The order the Gallery lists Documents in, and Library Search: rules every
//! client shares, so a Library looks the same on every Device.

use crate::library::Document;
use std::cmp::{Ordering, Reverse};
use std::iter::Peekable;
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};

/// What Documents are ordered by.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortKey {
    /// Date Imported, newest first.
    DateImported,
    /// A–Z by Title, Finder-like: "2" before "10", ignoring case and accents.
    Title,
    /// Last Read, newest first; never-opened Documents follow by Date Imported.
    RecentlyRead,
}

/// How a Gallery orders its Documents.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Sort {
    pub key: SortKey,
    /// Flips the order of `key`: oldest Import first, Z–A, or longest unread
    /// first. Never-opened Documents trail either way.
    pub reversed: bool,
}

/// What a `Listing` orders and searches a Document by.
#[derive(Debug, Clone, PartialEq)]
struct Item {
    title: String,
    file_name: String,
    author: Option<String>,
    /// Date Imported, in milliseconds since the Unix epoch.
    imported: u64,
    /// Last Read, in milliseconds since the Unix epoch; none if never opened.
    last_read: Option<u64>,
}

impl From<&Document> for Item {
    fn from(document: &Document) -> Self {
        let file_name = document.path.file_name().unwrap_or_default();
        Self {
            title: document.title(),
            file_name: file_name.to_string_lossy().into_owned(),
            author: document.details.as_ref().and_then(|d| d.author.clone()),
            imported: document.imported,
            last_read: document.progress.map(|p| p.last_read),
        }
    }
}

/// The Documents of a Library in a `Sort`, ready for Library Search. Built
/// once per change of the Documents or the Sort; each search is then cheap.
pub struct Listing {
    /// The Documents, in the order they were given: newest Import first.
    documents: Vec<Document>,
    /// Positions in `documents`, in Sort order.
    order: Vec<usize>,
    /// Each Document's Title, file name and Author, `fold`ed and joined by a
    /// NUL, so a search never matches across two of them.
    searched: Vec<String>,
}

impl Listing {
    /// `documents` in `sort` order. Documents the Sort can't tell apart (same
    /// Title, same Last Read) keep Date Imported order, newest first, and then
    /// their order in `documents`.
    pub fn new(documents: Vec<Document>, sort: Sort) -> Self {
        let items: Vec<Item> = documents.iter().map(Item::from).collect();
        let items = items.as_slice();
        let flip = |mut order: Vec<usize>| {
            if sort.reversed {
                order.reverse();
            }
            order
        };
        // Stable sorts throughout, so ties keep this order.
        let mut by_import: Vec<usize> = (0..items.len()).collect();
        by_import.sort_by_key(|&i| Reverse(items[i].imported));
        let order = match sort.key {
            SortKey::DateImported => flip(by_import),
            SortKey::Title => {
                let titles: Vec<String> = items.iter().map(|i| fold(&i.title)).collect();
                by_import.sort_by(|&a, &b| natural(&titles[a], &titles[b]));
                flip(by_import)
            }
            SortKey::RecentlyRead => {
                let (mut opened, never): (Vec<_>, Vec<_>) = by_import
                    .into_iter()
                    .partition(|&i| items[i].last_read.is_some());
                opened.sort_by_key(|&i| Reverse(items[i].last_read));
                let mut order = flip(opened);
                order.extend(never);
                order
            }
        };
        let searched = items
            .iter()
            .map(|item| {
                let author = item.author.as_deref().unwrap_or_default();
                [&item.title, &item.file_name, author].map(fold).join("\0")
            })
            .collect();
        Self {
            documents,
            order,
            searched,
        }
    }

    /// The Documents, in the order they were given: newest Import first.
    pub fn documents(&self) -> &[Document] {
        &self.documents
    }

    /// The positions in `documents()` of the Documents whose Title, file name
    /// or Author contains `search`, ignoring case and accents, in this
    /// Listing's order. A blank `search` matches every Document.
    pub fn matching(&self, search: &str) -> Vec<usize> {
        let search = fold(search.trim());
        let order = self.order.iter().copied();
        order
            .filter(|&i| self.searched[i].contains(&search))
            .collect()
    }
}

/// Whether the Gallery for `sort` shows something new once the Reading
/// Progress of a Document goes from `before` to `after`. `last_reads` are the
/// Last Read of the other Documents that have one. The Gallery shows each
/// Document's percent read, and in Recently Read order its Last Read. Never says
/// no where something changed; may say yes where nothing did.
pub(crate) fn progress_changes_gallery(
    sort: Sort,
    before: &Document,
    after: &Document,
    last_reads: impl IntoIterator<Item = u64>,
) -> bool {
    if before.percent_read() != after.percent_read() {
        return true;
    }
    if sort.key != SortKey::RecentlyRead {
        return false;
    }
    match (before.progress, after.progress) {
        // Reading on without passing another Document's Last Read keeps the order.
        (Some(from), Some(to)) => {
            let (low, high) = (
                from.last_read.min(to.last_read),
                from.last_read.max(to.last_read),
            );
            from.last_read != to.last_read
                && last_reads
                    .into_iter()
                    .any(|read| (low..=high).contains(&read))
        }
        (None, None) => false,
        // Opened for the first time, or unopened: it moves.
        _ => true,
    }
}

/// `text` as searching and sorting compare it: lowercase, without accents.
fn fold(text: &str) -> String {
    text.nfd()
        .filter(|&c| !is_combining_mark(c))
        .flat_map(char::to_lowercase)
        .collect()
}

/// The order of `a` and `b` with each run of digits compared as a number, so
/// "2" comes before "10"; the rest compares character by character.
fn natural(a: &str, b: &str) -> Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        let ordering = match (a.peek(), b.peek()) {
            (None, None) => return Ordering::Equal,
            (x, y)
                if x.is_some_and(char::is_ascii_digit) && y.is_some_and(char::is_ascii_digit) =>
            {
                number(&mut a).cmp(&number(&mut b))
            }
            (x, y) => {
                let ordering = x.cmp(&y);
                a.next();
                b.next();
                ordering
            }
        };
        if ordering.is_ne() {
            return ordering;
        }
    }
}

/// The run of digits `chars` starts with, taken from it, as a key that orders
/// runs by their value: the digits without leading zeros, shorter first.
fn number(chars: &mut Peekable<impl Iterator<Item = char>>) -> (usize, String) {
    let mut digits = String::new();
    while let Some(digit) = chars.next_if(char::is_ascii_digit) {
        digits.push(digit);
    }
    let value = digits.trim_start_matches('0').to_owned();
    (value.len(), value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::details::{Details, Size};
    use crate::progress::ReadingProgress;

    /// A Document with `title`, whose ID is its `imported` date.
    fn item(title: &str, imported: u64, last_read: Option<u64>) -> Document {
        Document {
            id: imported.to_string(),
            path: format!("/library/{imported}/{imported}.pdf").into(),
            imported,
            progress: last_read.map(|at| ReadingProgress::pdf(0, 0.0, 0.0, at)),
            details: Some(Details {
                title: Some(title.to_owned()),
                author: None,
                size: Size::Pages(1),
            }),
        }
    }

    fn author(document: &mut Document, author: &str) {
        document.details.as_mut().unwrap().author = Some(author.to_owned());
    }

    /// "Zebra", "résumé 10", "Resume 2", "apple", newest Import first; "apple"
    /// was read at 100, "Zebra" at 200, "Resume 2" at 300.
    fn shelf() -> Vec<Document> {
        vec![
            item("apple", 1, Some(100)),
            item("Zebra", 4, Some(200)),
            item("Resume 2", 2, Some(300)),
            item("résumé 10", 3, None),
        ]
    }

    fn titles(documents: &[Document], key: SortKey, reversed: bool, search: &str) -> Vec<String> {
        let listing = Listing::new(documents.to_vec(), Sort { key, reversed });
        listing
            .matching(search)
            .into_iter()
            .map(|i| listing.documents()[i].title())
            .collect()
    }

    /// The IDs of the Documents `listing` matches for `search`, in its order.
    fn ids<'a>(listing: &'a Listing, search: &str) -> Vec<&'a str> {
        listing
            .matching(search)
            .into_iter()
            .map(|i| listing.documents()[i].id.as_str())
            .collect()
    }

    #[test]
    fn date_imported_lists_the_newest_first_or_reversed_the_oldest() {
        let items = shelf();
        let newest = ["Zebra", "résumé 10", "Resume 2", "apple"];
        assert_eq!(titles(&items, SortKey::DateImported, false, ""), newest);
        let oldest: Vec<_> = newest.into_iter().rev().collect();
        assert_eq!(titles(&items, SortKey::DateImported, true, ""), oldest);
    }

    #[test]
    fn title_sorts_like_finder_or_reversed_z_to_a() {
        let items = shelf();
        let a_to_z = ["apple", "Resume 2", "résumé 10", "Zebra"];
        assert_eq!(titles(&items, SortKey::Title, false, ""), a_to_z);
        let z_to_a: Vec<_> = a_to_z.into_iter().rev().collect();
        assert_eq!(titles(&items, SortKey::Title, true, ""), z_to_a);
    }

    #[test]
    fn numbers_in_titles_compare_by_value() {
        let items = vec![
            item("Vol 10", 1, None),
            item("Vol 9", 2, None),
            item("Vol 009b", 3, None),
            item("Vol", 4, None),
        ];
        let sorted = titles(&items, SortKey::Title, false, "");
        assert_eq!(sorted, ["Vol", "Vol 9", "Vol 009b", "Vol 10"]);
    }

    #[test]
    fn equal_titles_keep_date_imported_order() {
        let items = vec![
            item("Same", 1, None),
            item("same", 3, None),
            item("Same", 2, None),
        ];
        let listing = Listing::new(items, sort(SortKey::Title));
        assert_eq!(ids(&listing, ""), ["3", "2", "1"]);
    }

    #[test]
    fn recently_read_lists_the_last_read_first_and_never_opened_last() {
        let items = shelf();
        let sorted = titles(&items, SortKey::RecentlyRead, false, "");
        assert_eq!(sorted, ["Resume 2", "Zebra", "apple", "résumé 10"]);
    }

    #[test]
    fn reversing_recently_read_flips_only_the_opened_documents() {
        let mut items = shelf();
        items.push(item("Never", 0, None));
        let sorted = titles(&items, SortKey::RecentlyRead, true, "");
        assert_eq!(sorted, ["apple", "Zebra", "Resume 2", "résumé 10", "Never"]);
    }

    #[test]
    fn search_matches_parts_of_the_title_the_file_name_and_the_author() {
        let mut items = vec![item("Moby-Dick", 1, None), item("Walden", 2, None)];
        author(&mut items[0], "Herman Melville");
        items[1].path = "/library/2/scan0042.pdf".into();
        let listing = Listing::new(items, sort(SortKey::Title));

        assert_eq!(ids(&listing, "oby"), ["1"]);
        assert_eq!(ids(&listing, "can004"), ["2"]);
        assert_eq!(ids(&listing, "melv"), ["1"]);
        assert!(ids(&listing, "xyz").is_empty());
    }

    #[test]
    fn search_ignores_case_accents_and_surrounding_white_space_and_keeps_the_order() {
        let items = shelf();
        assert_eq!(
            titles(&items, SortKey::Title, false, " RESUME\n"),
            ["Resume 2", "résumé 10"]
        );
        assert_eq!(
            titles(&items, SortKey::DateImported, false, "resume"),
            ["résumé 10", "Resume 2"]
        );
        assert_eq!(titles(&items, SortKey::Title, false, " ").len(), 4);
    }

    #[test]
    fn search_never_matches_across_fields() {
        let mut items = vec![item("Moby", 1, None)];
        author(&mut items[0], "Dick");
        items[0].path = "/library/1/x.pdf".into();
        let listing = Listing::new(items, sort(SortKey::Title));
        assert!(listing.matching("mobydick").is_empty());
        assert!(listing.matching("moby dick").is_empty());
    }

    #[test]
    fn an_item_has_what_the_gallery_shows_of_its_document() {
        let document = Document {
            id: "abc".to_owned(),
            path: "/library/abc/scan0042.pdf".into(),
            imported: 7,
            progress: Some(crate::progress::ReadingProgress::pdf(0, 0.0, 0.0, 9)),
            details: Some(crate::details::Details {
                title: Some("Moby-Dick".to_owned()),
                author: Some("Melville".to_owned()),
                size: crate::details::Size::Pages(1),
            }),
        };
        let expected = Item {
            title: "Moby-Dick".to_owned(),
            file_name: "scan0042.pdf".to_owned(),
            author: Some("Melville".to_owned()),
            imported: 7,
            last_read: Some(9),
        };
        assert_eq!(Item::from(&document), expected);
    }

    #[test]
    fn the_listing_keeps_its_documents_in_the_order_given() {
        let items = shelf();
        let listing = Listing::new(items.clone(), sort(SortKey::Title));
        assert_eq!(listing.documents(), items);
    }

    /// A Document of `pages` pages, read last at `last_read` on page `page`, if
    /// it was read at all.
    fn read(page: u32, last_read: Option<u64>, pages: u32) -> Document {
        Document {
            id: String::new(),
            path: "/library/a/a.pdf".into(),
            imported: 1,
            progress: last_read.map(|at| ReadingProgress::pdf(page, 0.0, 0.0, at)),
            details: Some(Details {
                title: None,
                author: None,
                size: Size::Pages(pages),
            }),
        }
    }

    #[test]
    fn a_new_percent_read_changes_the_gallery_in_every_sort() {
        let (before, after) = (read(0, Some(100), 10), read(1, Some(200), 10));
        for key in [SortKey::DateImported, SortKey::Title, SortKey::RecentlyRead] {
            assert!(progress_changes_gallery(sort(key), &before, &after, []));
        }
    }

    #[test]
    fn the_same_percent_read_changes_nothing_in_date_imported_or_title_order() {
        let (before, after) = (read(0, Some(100), 10), read(0, Some(900), 10));
        for key in [SortKey::DateImported, SortKey::Title] {
            assert!(!progress_changes_gallery(
                sort(key),
                &before,
                &after,
                [50, 2_000]
            ));
        }
    }

    #[test]
    fn opening_a_document_changes_the_recently_read_order() {
        // No pages known, so the percent read stays none.
        let (never, opened) = (read(0, None, 0), read(0, Some(500), 0));
        assert!(progress_changes_gallery(
            sort(SortKey::RecentlyRead),
            &never,
            &opened,
            []
        ));
        assert!(!progress_changes_gallery(
            sort(SortKey::DateImported),
            &never,
            &opened,
            []
        ));
    }

    #[test]
    fn reading_on_past_the_last_read_document_keeps_the_recently_read_order() {
        let (before, after) = (read(0, Some(300), 0), read(0, Some(400), 0));
        assert!(!progress_changes_gallery(
            sort(SortKey::RecentlyRead),
            &before,
            &after,
            [100, 200]
        ));
    }

    #[test]
    fn moving_past_another_document_changes_the_recently_read_order_both_ways() {
        let (before, after) = (read(0, Some(150), 0), read(0, Some(250), 0));
        for reversed in [false, true] {
            let sort = Sort {
                key: SortKey::RecentlyRead,
                reversed,
            };
            assert!(progress_changes_gallery(sort, &before, &after, [200]));
        }
    }

    #[test]
    fn reading_at_the_same_last_read_keeps_the_recently_read_order() {
        let (before, after) = (read(0, Some(300), 0), read(2, Some(300), 0));
        assert!(!progress_changes_gallery(
            sort(SortKey::RecentlyRead),
            &before,
            &after,
            [300]
        ));
    }

    fn sort(key: SortKey) -> Sort {
        Sort {
            key,
            reversed: false,
        }
    }
}
