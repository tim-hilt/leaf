//! Markup and how it is kept in a Document's Automerge document (ADR-0008).
//!
//! The root's `highlights` map is keyed by Highlight ID, so Highlights added
//! on several devices never conflict. Each Highlight is a map of separately
//! written fields: the anchor, `quoted_text`, `color` (sRGB as
//! `0xRRGGBB`) and `created`, and, only while it has a Note, `note`: Automerge
//! text, so concurrent typing merges. A Note is updated by diffing, and emptying
//! it deletes it. Devices that first write a Note to one Highlight
//! concurrently each create their own text, and Automerge keeps one of them.
//!
//! The root's `page_notes` map holds the Notes on a spot of a page, keyed by ID
//! likewise: `page_index`, `x` and `y` (the spot in page space), `created` and
//! `text`, Automerge text. A page Note is its text: emptying it deletes the
//! page Note, and one without text, which only exists between adding it and
//! typing, isn't listed.
//!
//! Devices that first add a Highlight concurrently each create their own
//! `highlights` map, and Automerge keeps one of them as the winner. Reading
//! therefore lists the Highlights of all of them, and writing goes to the
//! winner. The same goes for page Notes.
//!
//! The anchor of a PDF Highlight is `anchor`, a list of `{page_index, rects}`,
//! where `rects` is a flat list of `x, y, width, height`: page index plus
//! rectangles in PDF page space (points, origin at the page's bottom-left),
//! engine-neutral (ADR-0003). That of an EPUB Highlight is `epub`, a map of
//! `start_spine`, `start_offset`, `end_spine` and `end_offset` (ADR-0022). The
//! quoted text is the fallback of both.
//!

use crate::state;
use automerge::{
    AutoCommit, ObjId, ObjType, ReadDoc, ScalarValue, Value, transaction::Transactable,
};

const HIGHLIGHTS: &str = "highlights";
const PAGE_NOTES: &str = "page_notes";

/// A rectangle in PDF page space.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// The rectangles a Highlight covers on one page: usually one per line.
#[derive(Debug, Clone, PartialEq)]
pub struct PageRects {
    /// Zero-based index of the page.
    pub page_index: u32,
    pub rects: Vec<Rect>,
}

/// A character of an EPUB's text (ADR-0022).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EpubPosition {
    /// Zero-based index of the spine item.
    pub spine_index: u32,
    /// Offset into that item's text, in UTF-16 code units.
    pub offset: u64,
}

/// Where a Highlight is, in the terms of its Document's Format.
#[derive(Debug, Clone, PartialEq)]
pub enum Anchor {
    /// The rectangles it covers on each page, in page order.
    Pdf(Vec<PageRects>),
    /// From `start` up to, not including, `end`. They may be in different
    /// spine items.
    Epub {
        start: EpubPosition,
        end: EpubPosition,
    },
}

/// A color in sRGB, 8 bits per channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Rgb {
    pub(crate) fn packed(self) -> u64 {
        u64::from(self.r) << 16 | u64::from(self.g) << 8 | u64::from(self.b)
    }

    pub(crate) fn unpacked(value: u64) -> Option<Self> {
        let [_, _, _, _, _, r, g, b] = value.to_be_bytes();
        (value <= 0xFF_FFFF).then_some(Self { r, g, b })
    }
}

/// A passage of a Document's text marked in a color. It may run across pages.
#[derive(Debug, Clone, PartialEq)]
pub struct Highlight {
    /// Unique among all Highlights, also across devices.
    pub id: String,
    pub anchor: Anchor,
    /// The whole passage, however many pages it spans. For an EPUB it is the
    /// text from `start` to `end`, the spine items' texts joined by `\n`.
    pub quoted_text: String,
    pub color: Rgb,
    /// When it was added, in milliseconds since the Unix epoch.
    pub created: u64,
    /// What the user wrote about the passage. Never empty.
    pub note: Option<String>,
}

/// A Note on a spot of a page, belonging to no passage.
#[derive(Debug, Clone, PartialEq)]
pub struct PageNote {
    /// Unique among all page Notes, also across devices.
    pub id: String,
    /// Zero-based index of the page.
    pub page_index: u32,
    /// The spot, in PDF page space.
    pub x: f64,
    pub y: f64,
    /// When it was added, in milliseconds since the Unix epoch.
    pub created: u64,
    /// What the user wrote. Never empty in the Markup.
    pub text: String,
}

/// Everything the user added on top of a Document.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Markup {
    /// Oldest first.
    pub highlights: Vec<Highlight>,
    /// Oldest first.
    pub page_notes: Vec<PageNote>,
}

/// The Markup in a stored Automerge document. Empty if `bytes` aren't an
/// Automerge document or hold none. Incomplete Highlights are skipped.
pub(crate) fn read(bytes: &[u8]) -> Markup {
    let Ok(doc) = AutoCommit::load(bytes) else {
        return Markup::default();
    };
    let mut markup = Markup {
        highlights: entries(&doc, HIGHLIGHTS, read_highlight),
        page_notes: entries(&doc, PAGE_NOTES, read_page_note),
    };
    markup.sort();
    markup
}

/// The Markup held by all the stored Automerge documents `states` together.
/// They are separate documents, e.g. the states of a Document's Imports, never
/// merged into one: each Highlight and page Note is in the one it was added to.
pub(crate) fn read_all<'a>(states: impl IntoIterator<Item = &'a [u8]>) -> Markup {
    let mut all = Markup::default();
    for bytes in states {
        let markup = read(bytes);
        all.highlights.extend(markup.highlights);
        all.page_notes.extend(markup.page_notes);
    }
    all.sort();
    all
}

impl Markup {
    /// Puts the Highlights and page Notes in order, oldest first.
    fn sort(&mut self) {
        self.highlights
            .sort_by(|a, b| (a.created, &a.id).cmp(&(b.created, &b.id)));
        self.page_notes
            .sort_by(|a, b| (a.created, &a.id).cmp(&(b.created, &b.id)));
    }
}

/// What `read_entry` makes of each entry of every root map `key` of `doc`,
/// skipping those it can't read.
fn entries<T>(
    doc: &AutoCommit,
    key: &str,
    read_entry: impl Fn(&AutoCommit, &ObjId, String) -> Option<T>,
) -> Vec<T> {
    state::maps(doc, key)
        .iter()
        .flat_map(|map| {
            doc.keys(map)
                .filter_map(|id| read_entry(doc, &entry_of(doc, map, &id)?, id))
        })
        .collect()
}

/// The map at `id` of `map`, if it is one.
fn entry_of(doc: &AutoCommit, map: &ObjId, id: &str) -> Option<ObjId> {
    match doc.get(map, id).ok()?? {
        (Value::Object(ObjType::Map), entry) => Some(entry),
        _ => None,
    }
}

/// Removes Highlight `id` from `doc`. A removal wins over a concurrent change
/// of the same Highlight.
pub(crate) fn remove_highlight(doc: &mut AutoCommit, id: &str) {
    delete(doc, HIGHLIGHTS, id);
}

/// Removes page Note `id` from `doc`. A removal wins over a concurrent edit of
/// the same page Note.
pub(crate) fn remove_page_note(doc: &mut AutoCommit, id: &str) {
    delete(doc, PAGE_NOTES, id);
}

/// The root map `key` holding the map entry `id`, and that entry.
fn find(doc: &AutoCommit, key: &str, id: &str) -> Option<(ObjId, ObjId)> {
    state::maps(doc, key).into_iter().find_map(|map| {
        let entry = entry_of(doc, &map, id)?;
        Some((map, entry))
    })
}

/// Deletes the entry `id` of the root map `key`, if there is one.
fn delete(doc: &mut AutoCommit, key: &str, id: &str) {
    if let Some((map, _)) = find(doc, key, id) {
        doc.delete(&map, id).expect("a map accepts deletions");
    }
}

pub(crate) fn put_color(doc: &mut AutoCommit, id: &str, color: Rgb) {
    if let Some((_, entry)) = find(doc, HIGHLIGHTS, id) {
        doc.put(&entry, "color", ScalarValue::Uint(color.packed()))
            .expect("a map accepts new keys");
    }
}

pub(crate) fn put_note(doc: &mut AutoCommit, id: &str, text: &str) {
    let Some((_, entry)) = find(doc, HIGHLIGHTS, id) else {
        return;
    };
    if text.is_empty() {
        doc.delete(&entry, "note").expect("a map accepts deletions");
        return;
    }
    write_text(doc, &entry, "note", text);
}

/// Sets the text at `key` of `entry` to `text` by diffing, creating it if
/// there is none.
fn write_text(doc: &mut AutoCommit, entry: &ObjId, key: &str, text: &str) {
    let object = match doc.get(entry, key).expect("a map has readable keys") {
        Some((Value::Object(ObjType::Text), object)) => object,
        _ => doc
            .put_object(entry, key, ObjType::Text)
            .expect("a map accepts new keys"),
    };
    doc.update_text(&object, text)
        .expect("a text accepts new content");
}

pub(crate) fn put_page_note_text(doc: &mut AutoCommit, id: &str, text: &str) {
    let Some((map, entry)) = find(doc, PAGE_NOTES, id) else {
        return;
    };
    if text.is_empty() {
        doc.delete(&map, id).expect("a map accepts deletions");
    } else {
        write_text(doc, &entry, "text", text);
    }
}

/// Adds `note` to the winning `page_notes` map of `doc`, creating it if there
/// is none.
pub(crate) fn put_page_note(doc: &mut AutoCommit, note: &PageNote) {
    let map = state::map_to_write(doc, PAGE_NOTES);
    let entry = doc
        .put_object(&map, note.id.as_str(), ObjType::Map)
        .expect("a map accepts new keys");
    let fields = [
        ("page_index", ScalarValue::Uint(u64::from(note.page_index))),
        ("x", ScalarValue::F64(note.x)),
        ("y", ScalarValue::F64(note.y)),
        ("created", ScalarValue::Uint(note.created)),
    ];
    for (key, value) in fields {
        doc.put(&entry, key, value)
            .expect("a new map accepts new keys");
    }
    write_text(doc, &entry, "text", &note.text);
}

fn read_page_note(doc: &AutoCommit, entry: &ObjId, id: String) -> Option<PageNote> {
    let field = |name: &str| state::scalar(doc, entry, name);
    Some(PageNote {
        page_index: u32::try_from(field("page_index")?.as_u64()?).ok()?,
        x: field("x")?.as_f64()?,
        y: field("y")?.as_f64()?,
        created: field("created")?.as_u64()?,
        text: read_text(doc, entry, "text")?,
        id,
    })
}

fn read_highlight(doc: &AutoCommit, entry: &ObjId, id: String) -> Option<Highlight> {
    let field = |name: &str| state::scalar(doc, entry, name);
    Some(Highlight {
        anchor: read_anchor(doc, entry)?,
        quoted_text: field("quoted_text")?.into_string().ok()?,
        color: Rgb::unpacked(field("color")?.as_u64()?)?,
        created: field("created")?.as_u64()?,
        note: read_text(doc, entry, "note"),
        id,
    })
}

/// The anchor of the Highlight `entry`, of the Format it was written for.
fn read_anchor(doc: &AutoCommit, entry: &ObjId) -> Option<Anchor> {
    match doc.get(entry, "anchor").ok()? {
        Some((Value::Object(ObjType::List), anchor)) => Some(Anchor::Pdf(
            (0..doc.length(&anchor))
                .map(|i| read_page_rects(doc, &anchor, i))
                .collect::<Option<_>>()?,
        )),
        _ => {
            let epub = entry_of(doc, entry, "epub")?;
            let position = |spine: &str, offset: &str| {
                Some(EpubPosition {
                    spine_index: u32::try_from(state::scalar(doc, &epub, spine)?.as_u64()?).ok()?,
                    offset: state::scalar(doc, &epub, offset)?.as_u64()?,
                })
            };
            Some(Anchor::Epub {
                start: position("start_spine", "start_offset")?,
                end: position("end_spine", "end_offset")?,
            })
        }
    }
}

/// The text at `key` of `entry`; none if it is missing or empty.
fn read_text(doc: &AutoCommit, entry: &ObjId, key: &str) -> Option<String> {
    let Some((Value::Object(ObjType::Text), text)) = doc.get(entry, key).ok()? else {
        return None;
    };
    doc.text(&text).ok().filter(|text| !text.is_empty())
}

fn read_page_rects(doc: &AutoCommit, anchor: &ObjId, index: usize) -> Option<PageRects> {
    let Some((Value::Object(ObjType::Map), page)) = doc.get(anchor, index).ok()? else {
        return None;
    };
    let Some((Value::Object(ObjType::List), rects)) = doc.get(&page, "rects").ok()? else {
        return None;
    };
    let numbers: Vec<f64> = (0..doc.length(&rects))
        .map(|i| state::scalar(doc, &rects, i)?.as_f64())
        .collect::<Option<_>>()?;
    Some(PageRects {
        page_index: u32::try_from(state::scalar(doc, &page, "page_index")?.as_u64()?).ok()?,
        rects: numbers
            .as_chunks::<4>()
            .0
            .iter()
            .map(|&[x, y, width, height]| Rect {
                x,
                y,
                width,
                height,
            })
            .collect(),
    })
}

/// Writes `pages` as the `anchor` of the Highlight `entry`.
fn put_pages(doc: &mut AutoCommit, entry: &ObjId, pages: &[PageRects]) {
    let anchor = doc
        .put_object(entry, "anchor", ObjType::List)
        .expect("a new map accepts new keys");
    for (i, page) in pages.iter().enumerate() {
        let page_map = doc
            .insert_object(&anchor, i, ObjType::Map)
            .expect("a list accepts new items");
        doc.put(&page_map, "page_index", u64::from(page.page_index))
            .expect("a new map accepts new keys");
        let rects = doc
            .put_object(&page_map, "rects", ObjType::List)
            .expect("a new map accepts new keys");
        let numbers = page
            .rects
            .iter()
            .flat_map(|r| [r.x, r.y, r.width, r.height]);
        for (n, number) in numbers.enumerate() {
            doc.insert(&rects, n, ScalarValue::F64(number))
                .expect("a list accepts new items");
        }
    }
}

/// Adds `highlight` to the winning `highlights` map of `doc`, creating it if
/// there is none.
pub(crate) fn put_highlight(doc: &mut AutoCommit, highlight: &Highlight) {
    let map = state::map_to_write(doc, HIGHLIGHTS);
    let entry = doc
        .put_object(&map, highlight.id.as_str(), ObjType::Map)
        .expect("a map accepts new keys");
    match &highlight.anchor {
        Anchor::Pdf(pages) => put_pages(doc, &entry, pages),
        Anchor::Epub { start, end } => {
            let epub = doc
                .put_object(&entry, "epub", ObjType::Map)
                .expect("a new map accepts new keys");
            let fields = [
                ("start_spine", u64::from(start.spine_index)),
                ("start_offset", start.offset),
                ("end_spine", u64::from(end.spine_index)),
                ("end_offset", end.offset),
            ];
            for (key, value) in fields {
                doc.put(&epub, key, ScalarValue::Uint(value))
                    .expect("a new map accepts new keys");
            }
        }
    }
    let fields = [
        (
            "quoted_text",
            ScalarValue::Str(highlight.quoted_text.as_str().into()),
        ),
        ("color", ScalarValue::Uint(highlight.color.packed())),
        ("created", ScalarValue::Uint(highlight.created)),
    ];
    for (key, value) in fields {
        doc.put(&entry, key, value)
            .expect("a new map accepts new keys");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use automerge::ActorId;

    /// The Automerge document `existing` with `change` made.
    fn edit(existing: Option<&[u8]>, change: impl FnOnce(&mut AutoCommit)) -> Vec<u8> {
        state::update(existing, &ActorId::random(), change)
    }

    fn add(existing: Option<&[u8]>, highlight: &Highlight) -> Vec<u8> {
        edit(existing, |doc| put_highlight(doc, highlight))
    }

    fn set_color(existing: Option<&[u8]>, id: &str, color: Rgb) -> Vec<u8> {
        edit(existing, |doc| put_color(doc, id, color))
    }

    fn set_note(existing: Option<&[u8]>, id: &str, text: &str) -> Vec<u8> {
        edit(existing, |doc| put_note(doc, id, text))
    }

    fn remove(existing: Option<&[u8]>, id: &str) -> Vec<u8> {
        edit(existing, |doc| remove_highlight(doc, id))
    }

    fn add_page_note(existing: Option<&[u8]>, note: &PageNote) -> Vec<u8> {
        edit(existing, |doc| put_page_note(doc, note))
    }

    fn set_page_note_text(existing: Option<&[u8]>, id: &str, text: &str) -> Vec<u8> {
        edit(existing, |doc| put_page_note_text(doc, id, text))
    }

    fn remove_page_note(existing: Option<&[u8]>, id: &str) -> Vec<u8> {
        edit(existing, |doc| super::remove_page_note(doc, id))
    }

    /// The entry of Highlight `id` in `doc`.
    fn entry(doc: &AutoCommit, id: &str) -> ObjId {
        find(doc, HIGHLIGHTS, id).unwrap().1
    }

    fn highlight(id: &str, created: u64) -> Highlight {
        Highlight {
            id: id.to_owned(),
            anchor: Anchor::Pdf(vec![PageRects {
                page_index: 1,
                rects: vec![Rect {
                    x: 1.5,
                    y: 2.5,
                    width: 3.5,
                    height: 4.5,
                }],
            }]),
            quoted_text: format!("passage {id}"),
            color: Rgb {
                r: 255,
                g: 0,
                b: 128,
            },
            created,
            note: None,
        }
    }

    /// Two devices, with actor IDs 1 and 2, start from `base` and each add one
    /// Highlight offline, then merge. Returns what `read` makes of the merge
    /// in both directions.
    fn merged(base: &[u8], one: &Highlight, two: &Highlight) -> [Markup; 2] {
        let device = |actor: u8, highlight: &Highlight| {
            let mut doc = AutoCommit::load(base)
                .unwrap()
                .with_actor(ActorId::from([actor; 16]));
            put_highlight(&mut doc, highlight);
            doc
        };
        let merge = |first: (u8, &Highlight), second: (u8, &Highlight)| {
            let mut a = device(first.0, first.1);
            a.merge(&mut device(second.0, second.1)).unwrap();
            read(&a.save())
        };
        [merge((1, one), (2, two)), merge((2, two), (1, one))]
    }

    #[test]
    fn a_highlight_reads_back_as_it_was_added() {
        let added = highlight("a", 5);
        assert_eq!(
            read(&add(None, &added)),
            Markup {
                highlights: vec![added],
                ..Markup::default()
            }
        );
    }

    fn epub_highlight(id: &str, start: (u32, u64), end: (u32, u64)) -> Highlight {
        let position = |(spine_index, offset)| EpubPosition {
            spine_index,
            offset,
        };
        Highlight {
            anchor: Anchor::Epub {
                start: position(start),
                end: position(end),
            },
            ..highlight(id, 5)
        }
    }

    #[test]
    fn an_epub_highlight_reads_back_across_spine_items_with_its_note() {
        let mut added = epub_highlight("a", (2, 40), (3, 7));
        let bytes = set_note(Some(&add(None, &added)), "a", "a thought");
        added.note = Some("a thought".to_owned());
        assert_eq!(read(&bytes).highlights, vec![added]);
    }

    #[test]
    fn an_epub_highlight_without_a_complete_position_is_skipped() {
        let bytes = add(None, &epub_highlight("a", (0, 1), (0, 2)));
        let bytes = edit(Some(&bytes), |doc| {
            let (_, epub) = doc.get(entry(doc, "a"), "epub").unwrap().unwrap();
            doc.delete(&epub, "end_offset").unwrap();
        });
        assert!(read(&bytes).highlights.is_empty());
    }

    #[test]
    fn colors_keep_all_their_channels() {
        for color in [(0, 0, 0), (255, 255, 255), (1, 2, 3), (255, 0, 0)] {
            let mut added = highlight("a", 5);
            added.color = Rgb {
                r: color.0,
                g: color.1,
                b: color.2,
            };
            assert_eq!(read(&add(None, &added)).highlights, vec![added]);
        }
    }

    #[test]
    fn the_markup_of_several_documents_is_listed_together_oldest_first() {
        let (one, two) = (add(None, &highlight("a", 2)), add(None, &highlight("b", 1)));
        let note = page_note("n", 0, "x");
        let with_note = add_page_note(None, &note);

        let all = read_all([
            one.as_slice(),
            b"garbage",
            two.as_slice(),
            with_note.as_slice(),
        ]);

        let ids: Vec<_> = all.highlights.iter().map(|h| h.id.as_str()).collect();
        assert_eq!(ids, ["b", "a"]);
        assert_eq!(all.page_notes, vec![note]);
        assert_eq!(read_all([]), Markup::default());
    }

    #[test]
    fn bytes_that_are_no_automerge_document_hold_no_markup() {
        assert_eq!(read(b"garbage"), Markup::default());
    }

    #[test]
    fn concurrent_additions_to_a_document_without_markup_are_both_kept() {
        let base = state::update(None, &ActorId::random(), |_| {});
        let (one, two) = (highlight("one", 1), highlight("two", 2));
        let expected = Markup {
            highlights: vec![one.clone(), two.clone()],
            ..Markup::default()
        };
        assert_eq!(merged(&base, &one, &two), [expected.clone(), expected]);
    }

    #[test]
    fn concurrent_additions_to_a_document_with_markup_are_all_kept() {
        let first = highlight("first", 0);
        let base = add(None, &first);
        let (one, two) = (highlight("one", 1), highlight("two", 2));
        let expected = Markup {
            highlights: vec![first, one.clone(), two.clone()],
            ..Markup::default()
        };
        assert_eq!(merged(&base, &one, &two), [expected.clone(), expected]);
    }

    #[test]
    fn adding_after_a_merge_keeps_every_highlight() {
        let base = state::update(None, &ActorId::random(), |_| {});
        let mut a = AutoCommit::load(&base)
            .unwrap()
            .with_actor(ActorId::from([1; 16]));
        let mut b = AutoCommit::load(&base)
            .unwrap()
            .with_actor(ActorId::from([2; 16]));
        put_highlight(&mut a, &highlight("one", 1));
        put_highlight(&mut b, &highlight("two", 2));
        a.merge(&mut b).unwrap();

        let after = add(Some(&a.save()), &highlight("three", 3));

        let ids: Vec<_> = read(&after).highlights.into_iter().map(|h| h.id).collect();
        assert_eq!(ids, ["one", "two", "three"]);
    }

    #[test]
    fn a_stored_highlight_ignores_fields_it_does_not_know() {
        let mut doc = AutoCommit::load(&add(None, &highlight("a", 1))).unwrap();
        let entry = entry(&doc, "a");
        doc.put(&entry, "future", "x").unwrap();
        assert_eq!(read(&doc.save()).highlights, vec![highlight("a", 1)]);
    }

    #[test]
    fn a_highlight_without_its_color_is_skipped() {
        let mut doc = AutoCommit::load(&add(None, &highlight("a", 1))).unwrap();
        let entry = entry(&doc, "a");
        doc.delete(&entry, "color").unwrap();
        assert_eq!(read(&doc.save()), Markup::default());
    }

    const GREEN: Rgb = Rgb { r: 0, g: 200, b: 0 };

    /// Two devices, with actor IDs 1 and 2, start from `base` and each edit it
    /// offline, then merge. Returns what `read` makes of the merge in both
    /// directions.
    fn merged_edits(
        base: &[u8],
        one: impl Fn(&mut AutoCommit),
        two: impl Fn(&mut AutoCommit),
    ) -> [Markup; 2] {
        let device = |actor: u8, edit: &dyn Fn(&mut AutoCommit)| {
            let mut doc = AutoCommit::load(base)
                .unwrap()
                .with_actor(ActorId::from([actor; 16]));
            edit(&mut doc);
            doc
        };
        let merge = |first: (u8, &dyn Fn(&mut AutoCommit)),
                     second: (u8, &dyn Fn(&mut AutoCommit))| {
            let mut a = device(first.0, first.1);
            a.merge(&mut device(second.0, second.1)).unwrap();
            read(&a.save())
        };
        [merge((1, &one), (2, &two)), merge((2, &two), (1, &one))]
    }

    #[test]
    fn a_color_change_replaces_the_color_and_nothing_else() {
        let base = add(None, &highlight("a", 5));
        let other = highlight("b", 6);
        let base = add(Some(&base), &other);

        let changed = read(&set_color(Some(&base), "a", GREEN));

        let recolored = Highlight {
            color: GREEN,
            ..highlight("a", 5)
        };
        assert_eq!(changed.highlights, vec![recolored, other]);
    }

    #[test]
    fn a_color_change_of_an_unknown_highlight_changes_nothing() {
        let base = add(None, &highlight("a", 5));
        assert_eq!(
            read(&set_color(Some(&base), "nope", GREEN)).highlights,
            vec![highlight("a", 5)]
        );
    }

    #[test]
    fn removing_deletes_only_that_highlight() {
        let base = add(Some(&add(None, &highlight("a", 5))), &highlight("b", 6));
        let removed = read(&remove(Some(&base), "a"));
        assert_eq!(removed.highlights, vec![highlight("b", 6)]);
    }

    #[test]
    fn removing_an_unknown_highlight_changes_nothing() {
        let base = add(None, &highlight("a", 5));
        assert_eq!(
            read(&remove(Some(&base), "nope")).highlights,
            vec![highlight("a", 5)]
        );
    }

    #[test]
    fn a_removal_wins_over_a_concurrent_color_change() {
        let base = add(None, &highlight("a", 5));
        let merged = merged_edits(
            &base,
            |doc| delete(doc, HIGHLIGHTS, "a"),
            |doc| put_color(doc, "a", GREEN),
        );
        assert_eq!(merged, [Markup::default(), Markup::default()]);
    }

    // Notes

    fn with_note(mut highlight: Highlight, note: &str) -> Highlight {
        highlight.note = Some(note.to_owned());
        highlight
    }

    #[test]
    fn a_note_reads_back_as_it_was_set() {
        let base = add(None, &highlight("a", 5));
        let noted = read(&set_note(Some(&base), "a", "my thought"));
        assert_eq!(
            noted.highlights,
            vec![with_note(highlight("a", 5), "my thought")]
        );
    }

    #[test]
    fn a_new_note_replaces_the_old_one_and_touches_no_other_highlight() {
        let base = add(Some(&add(None, &highlight("a", 5))), &highlight("b", 6));
        let first = set_note(Some(&base), "a", "one");
        let second = read(&set_note(Some(&first), "a", "two"));
        assert_eq!(
            second.highlights,
            vec![with_note(highlight("a", 5), "two"), highlight("b", 6)]
        );
    }

    #[test]
    fn an_empty_note_removes_the_note() {
        let base = add(None, &highlight("a", 5));
        let noted = set_note(Some(&base), "a", "thought");
        let emptied = read(&set_note(Some(&noted), "a", ""));
        assert_eq!(emptied.highlights, vec![highlight("a", 5)]);
    }

    #[test]
    fn an_empty_note_on_a_highlight_without_one_changes_nothing() {
        let base = add(None, &highlight("a", 5));
        let emptied = read(&set_note(Some(&base), "a", ""));
        assert_eq!(emptied.highlights, vec![highlight("a", 5)]);
    }

    #[test]
    fn a_note_can_be_written_again_after_it_was_removed() {
        let base = add(None, &highlight("a", 5));
        let emptied = set_note(Some(&set_note(Some(&base), "a", "x")), "a", "");
        let again = read(&set_note(Some(&emptied), "a", "y"));
        assert_eq!(again.highlights, vec![with_note(highlight("a", 5), "y")]);
    }

    #[test]
    fn a_note_of_an_unknown_highlight_changes_nothing() {
        let base = add(None, &highlight("a", 5));
        let noted = read(&set_note(Some(&base), "nope", "x"));
        assert_eq!(noted.highlights, vec![highlight("a", 5)]);
    }

    #[test]
    fn removing_a_highlight_removes_its_note() {
        let base = set_note(Some(&add(None, &highlight("a", 5))), "a", "x");
        assert_eq!(read(&remove(Some(&base), "a")), Markup::default());
    }

    #[test]
    fn notes_with_any_text_survive() {
        for text in ["ünï 🌿 \n multi\nline", "  ", "https://example.com/a?b=c"] {
            let base = add(None, &highlight("a", 5));
            let noted = read(&set_note(Some(&base), "a", text));
            assert_eq!(noted.highlights[0].note.as_deref(), Some(text));
        }
    }

    #[test]
    fn concurrent_typing_in_one_note_merges_character_by_character() {
        let base = set_note(Some(&add(None, &highlight("a", 5))), "a", "the quick fox");
        let merged = merged_edits(
            &base,
            |doc| put_note(doc, "a", "the quick brown fox"),
            |doc| put_note(doc, "a", "the quick fox jumps"),
        );
        let expected = Markup {
            highlights: vec![with_note(highlight("a", 5), "the quick brown fox jumps")],
            ..Markup::default()
        };
        assert_eq!(merged, [expected.clone(), expected]);
    }

    #[test]
    fn a_note_edit_and_a_color_change_both_survive() {
        let base = set_note(Some(&add(None, &highlight("a", 5))), "a", "old");
        let expected = Markup {
            highlights: vec![Highlight {
                color: GREEN,
                ..with_note(highlight("a", 5), "new")
            }],
            ..Markup::default()
        };
        let merged = merged_edits(
            &base,
            |doc| put_note(doc, "a", "new"),
            |doc| put_color(doc, "a", GREEN),
        );
        assert_eq!(merged, [expected.clone(), expected]);
    }

    #[test]
    fn a_removal_wins_over_a_concurrent_note_edit() {
        let base = set_note(Some(&add(None, &highlight("a", 5))), "a", "old");
        let merged = merged_edits(
            &base,
            |doc| delete(doc, HIGHLIGHTS, "a"),
            |doc| put_note(doc, "a", "new"),
        );
        assert_eq!(merged, [Markup::default(), Markup::default()]);
    }

    #[test]
    fn emptying_a_note_wins_over_a_concurrent_edit_of_it() {
        let base = set_note(Some(&add(None, &highlight("a", 5))), "a", "old");
        let merged = merged_edits(
            &base,
            |doc| put_note(doc, "a", ""),
            |doc| put_note(doc, "a", "older"),
        );
        let expected = Markup {
            highlights: vec![highlight("a", 5)],
            ..Markup::default()
        };
        assert_eq!(merged, [expected.clone(), expected]);
    }

    // Page Notes

    fn page_note(id: &str, created: u64, text: &str) -> PageNote {
        PageNote {
            id: id.to_owned(),
            page_index: 3,
            x: 10.5,
            y: 20.5,
            created,
            text: text.to_owned(),
        }
    }

    fn only_page_notes(notes: Vec<PageNote>) -> Markup {
        Markup {
            page_notes: notes,
            ..Markup::default()
        }
    }

    #[test]
    fn a_page_note_reads_back_as_it_was_written() {
        let note = page_note("a", 5, "my thought");
        let doc = add_page_note(None, &note);
        assert_eq!(read(&doc), only_page_notes(vec![note]));
    }

    #[test]
    fn a_page_note_without_text_is_not_listed_until_it_has_some() {
        let doc = add_page_note(None, &page_note("a", 5, ""));
        assert_eq!(read(&doc), Markup::default());
        let typed = set_page_note_text(Some(&doc), "a", "now");
        assert_eq!(
            read(&typed),
            only_page_notes(vec![page_note("a", 5, "now")])
        );
    }

    #[test]
    fn page_notes_are_listed_oldest_first_and_new_text_replaces_the_old() {
        let later = add_page_note(None, &page_note("later", 2, "l"));
        let both = add_page_note(Some(&later), &page_note("earlier", 1, "e"));
        let edited = set_page_note_text(Some(&both), "later", "l2");
        assert_eq!(
            read(&edited),
            only_page_notes(vec![
                page_note("earlier", 1, "e"),
                page_note("later", 2, "l2")
            ])
        );
    }

    #[test]
    fn an_empty_text_removes_the_page_note() {
        let doc = add_page_note(None, &page_note("a", 5, "x"));
        let emptied = set_page_note_text(Some(&doc), "a", "");
        assert_eq!(read(&emptied), Markup::default());
    }

    #[test]
    fn removing_a_page_note_leaves_the_others() {
        let doc = add_page_note(None, &page_note("a", 1, "x"));
        let doc = add_page_note(Some(&doc), &page_note("b", 2, "y"));
        let removed = remove_page_note(Some(&doc), "a");
        assert_eq!(
            read(&removed),
            only_page_notes(vec![page_note("b", 2, "y")])
        );
    }

    #[test]
    fn changing_or_removing_an_unknown_page_note_changes_nothing() {
        let doc = add_page_note(None, &page_note("a", 1, "x"));
        let doc = set_page_note_text(Some(&doc), "nope", "y");
        let doc = remove_page_note(Some(&doc), "nope");
        assert_eq!(read(&doc), only_page_notes(vec![page_note("a", 1, "x")]));
    }

    #[test]
    fn page_notes_and_highlights_are_kept_side_by_side() {
        let doc = add(None, &highlight("h", 1));
        let doc = add_page_note(Some(&doc), &page_note("n", 2, "x"));
        let doc = remove(Some(&doc), "h");
        assert_eq!(read(&doc), only_page_notes(vec![page_note("n", 2, "x")]));
    }

    #[test]
    fn concurrent_typing_in_one_page_note_merges_character_by_character() {
        let base = add_page_note(None, &page_note("a", 5, "the quick fox"));
        let merged = merged_edits(
            &base,
            |doc| put_page_note_text(doc, "a", "the quick brown fox"),
            |doc| put_page_note_text(doc, "a", "the quick fox jumps"),
        );
        let expected = only_page_notes(vec![page_note("a", 5, "the quick brown fox jumps")]);
        assert_eq!(merged, [expected.clone(), expected]);
    }

    #[test]
    fn a_page_note_removal_wins_over_a_concurrent_edit() {
        let base = add_page_note(None, &page_note("a", 5, "old"));
        let merged = merged_edits(
            &base,
            |doc| delete(doc, PAGE_NOTES, "a"),
            |doc| put_page_note_text(doc, "a", "new"),
        );
        assert_eq!(merged, [Markup::default(), Markup::default()]);
    }

    #[test]
    fn concurrent_page_note_additions_are_both_kept() {
        let base = state::update(None, &ActorId::random(), |_| {});
        let (one, two) = (page_note("one", 1, "x"), page_note("two", 2, "y"));
        let expected = only_page_notes(vec![one.clone(), two.clone()]);
        let merged = merged_edits(
            &base,
            |doc| put_page_note(doc, &one),
            |doc| put_page_note(doc, &two),
        );
        assert_eq!(merged, [expected.clone(), expected]);
    }
}
