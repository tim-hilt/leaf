//! Reading Progress, kept as one plain value (ADR-0020): `encode` and `decode`
//! store it as one line, `<page_index> <x> <y> <last_read>` for a PDF and
//! `e <spine_index> <offset> <last_read>` for an EPUB (ADR-0022).
//!
//! Older versions kept it in a Document's Automerge document (ADR-0008), which
//! `read` still understands, for PDFs only: the root's `progress` map holds `page_index`, `x`,
//! `y` and `last_read`. When devices wrote concurrently, the newest Last Read
//! wins.

use crate::state;
use automerge::{AutoCommit, ObjId, ObjType, ROOT, ReadDoc, Value};

/// A spot in a Document, in the terms of its Format.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Place {
    /// A point on a page of a PDF.
    Pdf {
        /// Zero-based index of the page.
        page_index: u32,
        /// The point on that page in PDF page space (points, origin at the
        /// page's bottom-left).
        x: f64,
        y: f64,
    },
    /// A character of an EPUB's text.
    Epub {
        /// Zero-based index of the spine item.
        spine_index: u32,
        /// Offset into that item's text, in UTF-16 code units (ADR-0022).
        offset: u64,
    },
}

/// Where in a Document the user last left off, and when.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReadingProgress {
    pub place: Place,
    /// Last Read: when the Reader showed the Document, in milliseconds since
    /// the Unix epoch.
    pub last_read: u64,
}

impl ReadingProgress {
    /// Progress at a point of a PDF page.
    pub(crate) fn pdf(page_index: u32, x: f64, y: f64, last_read: u64) -> Self {
        let place = Place::Pdf { page_index, x, y };
        Self { place, last_read }
    }

    /// Progress at a character of an EPUB spine item.
    #[cfg(test)]
    pub(crate) fn epub(spine_index: u32, offset: u64, last_read: u64) -> Self {
        let place = Place::Epub {
            spine_index,
            offset,
        };
        Self { place, last_read }
    }
}

/// `progress` as stored.
pub(crate) fn encode(progress: &ReadingProgress) -> Vec<u8> {
    let last_read = progress.last_read;
    match progress.place {
        Place::Pdf { page_index, x, y } => format!("{page_index} {x} {y} {last_read}"),
        Place::Epub {
            spine_index,
            offset,
        } => format!("e {spine_index} {offset} {last_read}"),
    }
    .into_bytes()
}

/// The Reading Progress stored in `bytes`; none if they aren't one.
pub(crate) fn decode(bytes: &[u8]) -> Option<ReadingProgress> {
    let mut fields = std::str::from_utf8(bytes).ok()?.split(' ');
    let first = fields.next()?;
    let place = if first == "e" {
        Place::Epub {
            spine_index: fields.next()?.parse().ok()?,
            offset: fields.next()?.parse().ok()?,
        }
    } else {
        Place::Pdf {
            page_index: first.parse().ok()?,
            x: fields.next()?.parse().ok()?,
            y: fields.next()?.parse().ok()?,
        }
    };
    let last_read = fields.next()?.parse().ok()?;
    fields
        .next()
        .is_none()
        .then_some(ReadingProgress { place, last_read })
}

/// The Reading Progress in a stored Automerge document. None if `bytes` aren't
/// an Automerge document or hold no Reading Progress.
///
/// Concurrent writes from several devices leave several `progress` values.
/// The one with the newest Last Read wins; on equal times, Automerge's own
/// winner does.
pub(crate) fn read(bytes: &[u8]) -> Option<ReadingProgress> {
    let doc = AutoCommit::load(bytes).ok()?;
    // Automerge lists conflicting values with its default winner last, and
    // `max_by_key` keeps the last of equal maxima.
    doc.get_all(ROOT, "progress")
        .ok()?
        .into_iter()
        .filter_map(|(value, id)| match value {
            Value::Object(ObjType::Map) => read_map(&doc, &id),
            _ => None,
        })
        .max_by_key(|progress| progress.last_read)
}

/// The Reading Progress held by the stored Automerge documents `states`, e.g.
/// those of a Document's Imports: the one with the newest Last Read, the last
/// of those if several have it.
pub(crate) fn read_all<'a>(states: impl IntoIterator<Item = &'a [u8]>) -> Option<ReadingProgress> {
    states
        .into_iter()
        .filter_map(read)
        .max_by_key(|progress| progress.last_read)
}

/// The Reading Progress held by the map `map`, if it is complete.
fn read_map(doc: &AutoCommit, map: &ObjId) -> Option<ReadingProgress> {
    let field = |name: &str| state::scalar(doc, map, name);
    Some(ReadingProgress::pdf(
        u32::try_from(field("page_index")?.as_u64()?).ok()?,
        field("x")?.as_f64()?,
        field("y")?.as_f64()?,
        field("last_read")?.as_u64()?,
    ))
}

/// Writes `progress`, which is of a PDF, into `doc` as one new `progress` map,
/// replacing every value (also concurrent ones) the key held, as older versions
/// did.
#[cfg(test)]
pub(crate) fn put_progress(doc: &mut AutoCommit, progress: &ReadingProgress) {
    use automerge::{ScalarValue, transaction::Transactable};
    let Place::Pdf { page_index, x, y } = progress.place else {
        panic!("older versions kept PDFs only");
    };
    let map = doc
        .put_object(ROOT, "progress", ObjType::Map)
        .expect("a root map accepts new keys");
    let values = [
        ("page_index", ScalarValue::Uint(page_index.into())),
        ("x", ScalarValue::F64(x)),
        ("y", ScalarValue::F64(y)),
        ("last_read", ScalarValue::Uint(progress.last_read)),
    ];
    for (key, value) in values {
        doc.put(&map, key, value)
            .expect("a new map accepts new keys");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use automerge::ActorId;

    /// The Automerge document `existing` with `progress` written into it.
    fn write(existing: Option<&[u8]>, progress: &ReadingProgress) -> Vec<u8> {
        state::update(existing, &ActorId::random(), |doc| {
            put_progress(doc, progress);
        })
    }

    fn place(page_index: u32, last_read: u64) -> ReadingProgress {
        let (x, y) = (f64::from(page_index) + 0.5, f64::from(page_index) + 0.25);
        ReadingProgress::pdf(page_index, x, y, last_read)
    }

    /// Two devices, `low` and `high` named by their actor IDs (Automerge's
    /// default winner is the higher one), start from the same stored state,
    /// each write `low_progress` and `high_progress` offline, then merge.
    /// Returns what `read` makes of the merge in both directions.
    fn merged(
        low_progress: &ReadingProgress,
        high_progress: &ReadingProgress,
    ) -> [Option<ReadingProgress>; 2] {
        let base = write(None, &place(0, 1));
        let device = |actor: u8, progress: &ReadingProgress| {
            let mut doc = AutoCommit::load(&base)
                .unwrap()
                .with_actor(ActorId::from([actor; 16]));
            put_progress(&mut doc, progress);
            doc
        };
        let merge = |into: u8, from: u8| {
            let progress = |actor| {
                if actor == 1 {
                    low_progress
                } else {
                    high_progress
                }
            };
            let mut a = device(into, progress(into));
            a.merge(&mut device(from, progress(from))).unwrap();
            read(&a.save())
        };
        [merge(1, 2), merge(2, 1)]
    }

    #[test]
    fn progress_reads_back_as_encoded_and_anything_else_reads_as_none() {
        let pdf = ReadingProgress::pdf(7, 0.1 + 0.2, -3.75, u64::MAX);
        let epub = ReadingProgress::epub(3, u64::MAX, u64::MAX);
        for exact in [pdf, epub] {
            assert_eq!(decode(&encode(&exact)), Some(exact));
        }
        let bad_ones = [&b""[..], b"1 2 3", b"1 2 3 4 5", b"a 2 3 4", &[0xff]];
        let bad_epubs = [&b"e 1 2"[..], b"e 1 2 3 4", b"e -1 2 3", b"e 1 2.5 3"];
        for bad in bad_ones.into_iter().chain(bad_epubs) {
            assert_eq!(decode(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn the_newest_last_read_of_several_documents_wins() {
        let (old, new) = (write(None, &place(3, 1_000)), write(None, &place(7, 2_000)));
        let states = [old.as_slice(), b"garbage", new.as_slice(), old.as_slice()];
        assert_eq!(read_all(states), Some(place(7, 2_000)));
        assert_eq!(read_all([]), None);
    }

    #[test]
    fn newest_last_read_wins_when_it_is_from_the_lower_actor() {
        let (newer, older) = (place(7, 2_000), place(3, 1_000));
        assert_eq!(merged(&newer, &older), [Some(newer), Some(newer)]);
    }

    #[test]
    fn newest_last_read_wins_when_it_is_from_the_higher_actor() {
        let (older, newer) = (place(3, 1_000), place(7, 2_000));
        assert_eq!(merged(&older, &newer), [Some(newer), Some(newer)]);
    }

    #[test]
    fn equal_last_reads_fall_back_to_the_higher_actor() {
        let (low, high) = (place(3, 1_000), place(7, 1_000));
        assert_eq!(merged(&low, &high), [Some(high), Some(high)]);
    }

    #[test]
    fn writing_after_a_merge_replaces_the_conflict() {
        let bytes = write(None, &place(0, 1));
        let mut a = AutoCommit::load(&bytes)
            .unwrap()
            .with_actor(ActorId::from([1; 16]));
        let mut b = AutoCommit::load(&bytes)
            .unwrap()
            .with_actor(ActorId::from([2; 16]));
        put_progress(&mut a, &place(3, 3_000));
        put_progress(&mut b, &place(7, 2_000));
        a.merge(&mut b).unwrap();
        let after = write(Some(&a.save()), &place(5, 1_000));
        assert_eq!(read(&after), Some(place(5, 1_000)));
    }
}
