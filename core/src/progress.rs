//! Reading Progress and how it is kept in a Document's Automerge document
//! (ADR-0008).
//!
//! Schema, version 1: the root holds `version` and a `progress` map with
//! `page_index`, `x`, `y` and `last_read`. The whole map is written as one
//! value on every save, so a Place and its Last Read never mix between
//! devices.

use automerge::{
    AutoCommit, ObjType, ROOT, ReadDoc, ScalarValue, Value, transaction::Transactable,
};

const SCHEMA_VERSION: u64 = 1;

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
pub(crate) fn read(bytes: &[u8]) -> Option<ReadingProgress> {
    let doc = AutoCommit::load(bytes).ok()?;
    let (Value::Object(ObjType::Map), map) = doc.get(ROOT, "progress").ok()?? else {
        return None;
    };
    let field = |name: &str| match doc.get(map.clone(), name).ok()?? {
        (Value::Scalar(value), _) => Some(value.into_owned()),
        _ => None,
    };
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
    let mut doc = existing
        .and_then(|bytes| AutoCommit::load(bytes).ok())
        .unwrap_or_default();
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
    doc.put(ROOT, "version", SCHEMA_VERSION)
        .expect("a root map accepts new keys");
    doc.save()
}
