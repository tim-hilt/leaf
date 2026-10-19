//! Reading Progress and how it is kept in a Document's Automerge document
//! (ADR-0008).
//!
//! The root's `progress` map holds `page_index`, `x`, `y` and `last_read`
//! (see `state` for the schema). The whole map is written as one value on
//! every save, so a Place and its Last Read never mix between devices. When
//! devices wrote concurrently, reading picks the newest Last Read.

use crate::state;
use automerge::{
    AutoCommit, ObjId, ObjType, ROOT, ReadDoc, ScalarValue, Value, transaction::Transactable,
};

/// Where in a Document the user last left off, and when.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReadingProgress {
    /// Zero-based index of the page.
    pub page_index: u32,
    /// The point on that page in PDF page space (points, origin at the
    /// page's bottom-left).
    pub x: f64,
    pub y: f64,
    /// Last Read: when the Reader showed the Document, in milliseconds since
    /// the Unix epoch.
    pub last_read: u64,
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

/// The Reading Progress held by the map `map`, if it is complete.
fn read_map(doc: &AutoCommit, map: &ObjId) -> Option<ReadingProgress> {
    let field = |name: &str| state::scalar(doc, map, name);
    Some(ReadingProgress {
        page_index: u32::try_from(field("page_index")?.as_u64()?).ok()?,
        x: field("x")?.as_f64()?,
        y: field("y")?.as_f64()?,
        last_read: field("last_read")?.as_u64()?,
    })
}

/// The Automerge document `existing` with `progress` written into it,
/// compacted. A missing or unreadable `existing` starts a new document.
pub(crate) fn write(existing: Option<&[u8]>, progress: &ReadingProgress) -> Vec<u8> {
    state::update(existing, |doc| put_progress(doc, progress))
}

/// Writes `progress` into `doc` as one new `progress` map, replacing every
/// value (also concurrent ones) the key held.
fn put_progress(doc: &mut AutoCommit, progress: &ReadingProgress) {
    let map = doc
        .put_object(ROOT, "progress", ObjType::Map)
        .expect("a root map accepts new keys");
    let values = [
        ("page_index", ScalarValue::Uint(progress.page_index.into())),
        ("x", ScalarValue::F64(progress.x)),
        ("y", ScalarValue::F64(progress.y)),
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

    fn place(page_index: u32, last_read: u64) -> ReadingProgress {
        ReadingProgress {
            page_index,
            x: f64::from(page_index) + 0.5,
            y: f64::from(page_index) + 0.25,
            last_read,
        }
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
