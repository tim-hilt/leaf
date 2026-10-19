//! Markup and how it is kept in a Document's Automerge document (ADR-0008).
//!
//! The root's `highlights` map is keyed by Highlight ID, so Highlights added
//! on several devices never conflict. Each Highlight is a map of separately
//! written fields: `anchor` (a list of `{page_index, rects}`, where `rects`
//! is a flat list of `x, y, width, height`), `quoted_text`, `color` (sRGB as
//! `0xRRGGBB`) and `created`.
//!
//! Devices that first add a Highlight concurrently each create their own
//! `highlights` map, and Automerge keeps one of them as the winner. Reading
//! therefore lists the Highlights of all of them, and writing goes to the
//! winner.
//!
//! Positions are engine-neutral (ADR-0003): page index plus rectangles in PDF
//! page space (points, origin at the page's bottom-left), with the quoted text
//! as a fallback.

use crate::state;
use automerge::{
    ActorId, AutoCommit, ObjId, ObjType, ROOT, ReadDoc, ScalarValue, Value,
    transaction::Transactable,
};

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

/// A color in sRGB, 8 bits per channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Rgb {
    fn packed(self) -> u64 {
        u64::from(self.r) << 16 | u64::from(self.g) << 8 | u64::from(self.b)
    }

    fn unpacked(value: u64) -> Option<Self> {
        let [_, _, _, _, _, r, g, b] = value.to_be_bytes();
        (value <= 0xFF_FFFF).then_some(Self { r, g, b })
    }
}

/// One of the Highlight Colors that always exist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BuiltInColor {
    pub name: &'static str,
    pub rgb: Rgb,
}

const fn built_in(name: &'static str, r: u8, g: u8, b: u8) -> BuiltInColor {
    BuiltInColor {
        name,
        rgb: Rgb { r, g, b },
    }
}

/// The built-in Highlight Colors, yellow (the default) first.
pub const BUILT_IN_COLORS: [BuiltInColor; 6] = [
    built_in("Yellow", 255, 235, 60),
    built_in("Green", 126, 217, 87),
    built_in("Blue", 102, 178, 255),
    built_in("Pink", 255, 128, 191),
    built_in("Purple", 178, 140, 255),
    built_in("Red", 255, 99, 99),
];

/// A passage of a Document's text marked in a color. It may run across pages.
#[derive(Debug, Clone, PartialEq)]
pub struct Highlight {
    /// Unique among all Highlights, also across devices.
    pub id: String,
    /// Where it is, in page order.
    pub anchor: Vec<PageRects>,
    /// The whole passage, however many pages it spans.
    pub quoted_text: String,
    pub color: Rgb,
    /// When it was added, in milliseconds since the Unix epoch.
    pub created: u64,
}

/// Everything the user added on top of a Document.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Markup {
    /// Oldest first.
    pub highlights: Vec<Highlight>,
}

/// A new ID, unique across devices.
pub(crate) fn new_id() -> String {
    ActorId::random().to_hex_string()
}

/// The Markup in a stored Automerge document. Empty if `bytes` aren't an
/// Automerge document or hold none. Incomplete Highlights are skipped.
pub(crate) fn read(bytes: &[u8]) -> Markup {
    let Ok(doc) = AutoCommit::load(bytes) else {
        return Markup::default();
    };
    let mut highlights: Vec<_> = highlight_maps(&doc)
        .iter()
        .flat_map(|map| doc.keys(map).filter_map(|id| read_highlight(&doc, map, id)))
        .collect();
    highlights.sort_by(|a, b| a.created.cmp(&b.created).then_with(|| a.id.cmp(&b.id)));
    Markup { highlights }
}

/// The Automerge document `existing` with `highlight` added, compacted.
pub(crate) fn add(existing: Option<&[u8]>, highlight: &Highlight) -> Vec<u8> {
    state::update(existing, |doc| put_highlight(doc, highlight))
}

/// The Automerge document `existing` with the color of Highlight `id` set to
/// `color`, compacted. Unknown Highlights are left alone.
pub(crate) fn set_color(existing: Option<&[u8]>, id: &str, color: Rgb) -> Vec<u8> {
    state::update(existing, |doc| put_color(doc, id, color))
}

/// The Automerge document `existing` without Highlight `id`, compacted. A
/// removal wins over a concurrent change of the same Highlight.
pub(crate) fn remove(existing: Option<&[u8]>, id: &str) -> Vec<u8> {
    state::update(existing, |doc| delete_highlight(doc, id))
}

/// The `highlights` map holding Highlight `id`, and its entry.
fn find(doc: &AutoCommit, id: &str) -> Option<(ObjId, ObjId)> {
    highlight_maps(doc)
        .into_iter()
        .find_map(|map| match doc.get(&map, id).ok()? {
            Some((Value::Object(ObjType::Map), entry)) => Some((map, entry)),
            _ => None,
        })
}

fn put_color(doc: &mut AutoCommit, id: &str, color: Rgb) {
    if let Some((_, entry)) = find(doc, id) {
        doc.put(&entry, "color", ScalarValue::Uint(color.packed()))
            .expect("a map accepts new keys");
    }
}

fn delete_highlight(doc: &mut AutoCommit, id: &str) {
    if let Some((map, _)) = find(doc, id) {
        doc.delete(&map, id).expect("a map accepts deletions");
    }
}

/// Every `highlights` map in `doc`, the one Automerge picks as winner last.
fn highlight_maps(doc: &AutoCommit) -> Vec<ObjId> {
    doc.get_all(ROOT, "highlights")
        .map(|values| {
            values
                .into_iter()
                .filter_map(|(value, id)| {
                    matches!(value, Value::Object(ObjType::Map)).then_some(id)
                })
                .collect()
        })
        .unwrap_or_default()
}

fn read_highlight(doc: &AutoCommit, map: &ObjId, id: String) -> Option<Highlight> {
    let Some((Value::Object(ObjType::Map), entry)) = doc.get(map, &id).ok()? else {
        return None;
    };
    let field = |name: &str| state::scalar(doc, &entry, name);
    let Some((Value::Object(ObjType::List), anchor)) = doc.get(&entry, "anchor").ok()? else {
        return None;
    };
    Some(Highlight {
        anchor: (0..doc.length(&anchor))
            .map(|i| read_page_rects(doc, &anchor, i))
            .collect::<Option<_>>()?,
        quoted_text: field("quoted_text")?.into_string().ok()?,
        color: Rgb::unpacked(field("color")?.as_u64()?)?,
        created: field("created")?.as_u64()?,
        id,
    })
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

/// Adds `highlight` to the winning `highlights` map of `doc`, creating it if
/// there is none.
fn put_highlight(doc: &mut AutoCommit, highlight: &Highlight) {
    let map = highlight_maps(doc).pop().unwrap_or_else(|| {
        doc.put_object(ROOT, "highlights", ObjType::Map)
            .expect("a root map accepts new keys")
    });
    let entry = doc
        .put_object(&map, highlight.id.as_str(), ObjType::Map)
        .expect("a map accepts new keys");
    let anchor = doc
        .put_object(&entry, "anchor", ObjType::List)
        .expect("a new map accepts new keys");
    for (i, page) in highlight.anchor.iter().enumerate() {
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

    fn highlight(id: &str, created: u64) -> Highlight {
        Highlight {
            id: id.to_owned(),
            anchor: vec![PageRects {
                page_index: 1,
                rects: vec![Rect {
                    x: 1.5,
                    y: 2.5,
                    width: 3.5,
                    height: 4.5,
                }],
            }],
            quoted_text: format!("passage {id}"),
            color: Rgb {
                r: 255,
                g: 0,
                b: 128,
            },
            created,
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
                highlights: vec![added]
            }
        );
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
    fn bytes_that_are_no_automerge_document_hold_no_markup() {
        assert_eq!(read(b"garbage"), Markup::default());
    }

    #[test]
    fn concurrent_additions_to_a_document_without_markup_are_both_kept() {
        let base = state::update(None, |_| {});
        let (one, two) = (highlight("one", 1), highlight("two", 2));
        let expected = Markup {
            highlights: vec![one.clone(), two.clone()],
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
        };
        assert_eq!(merged(&base, &one, &two), [expected.clone(), expected]);
    }

    #[test]
    fn adding_after_a_merge_keeps_every_highlight() {
        let base = state::update(None, |_| {});
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
        let map = highlight_maps(&doc).pop().unwrap();
        let (_, entry) = doc.get(&map, "a").unwrap().unwrap();
        doc.put(&entry, "future", "x").unwrap();
        assert_eq!(read(&doc.save()).highlights, vec![highlight("a", 1)]);
    }

    #[test]
    fn a_highlight_without_its_color_is_skipped() {
        let mut doc = AutoCommit::load(&add(None, &highlight("a", 1))).unwrap();
        let map = highlight_maps(&doc).pop().unwrap();
        let (_, entry) = doc.get(&map, "a").unwrap().unwrap();
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
            |doc| delete_highlight(doc, "a"),
            |doc| put_color(doc, "a", GREEN),
        );
        assert_eq!(merged, [Markup::default(), Markup::default()]);
    }

    #[test]
    fn a_color_change_and_an_edit_of_another_field_both_survive() {
        let base = add(None, &highlight("a", 5));
        // Stands in for any other field, like the Note.
        let edit_quote = |doc: &mut AutoCommit| {
            let map = highlight_maps(doc).pop().unwrap();
            let (_, entry) = doc.get(&map, "a").unwrap().unwrap();
            doc.put(&entry, "quoted_text", "edited").unwrap();
        };
        let expected = Markup {
            highlights: vec![Highlight {
                color: GREEN,
                quoted_text: "edited".to_owned(),
                ..highlight("a", 5)
            }],
        };
        let merged = merged_edits(&base, |doc| put_color(doc, "a", GREEN), edit_quote);
        assert_eq!(merged, [expected.clone(), expected]);
    }

    #[test]
    fn the_built_in_colors_start_with_yellow_and_are_distinct() {
        assert_eq!(BUILT_IN_COLORS.len(), 6);
        assert_eq!(BUILT_IN_COLORS[0].name, "Yellow");
        for (i, a) in BUILT_IN_COLORS.iter().enumerate() {
            assert!(BUILT_IN_COLORS[i + 1..].iter().all(|b| a.rgb != b.rgb));
        }
    }

    #[test]
    fn new_ids_differ() {
        assert_ne!(new_id(), new_id());
    }
}
