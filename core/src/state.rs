//! A Document's Automerge document (ADR-0008): the synced state kept next to
//! its File, shared by Reading Progress (`progress`) and Markup (`markup`).
//!
//! Schema, version 2: the root holds `version`, a `progress` map (see
//! `progress`) and a `highlights` map (see `markup`). Version 1 had no
//! `highlights`; it reads as a document without Markup, and its first write
//! makes it version 2.

use automerge::{
    AutoCommit, ObjId, Prop, ROOT, ReadDoc, ScalarValue, Value, transaction::Transactable,
};

const SCHEMA_VERSION: u64 = 2;

/// The Automerge document `existing` with `change` applied, stamped with the
/// current schema version and compacted. A missing or unreadable `existing`
/// starts a new document.
pub(crate) fn update(existing: Option<&[u8]>, change: impl FnOnce(&mut AutoCommit)) -> Vec<u8> {
    update_versioned(existing, SCHEMA_VERSION, change)
}

/// `update` for an Automerge document with its own schema `version`, like
/// Preferences (`preferences`).
pub(crate) fn update_versioned(
    existing: Option<&[u8]>,
    version: u64,
    change: impl FnOnce(&mut AutoCommit),
) -> Vec<u8> {
    let mut doc = existing
        .and_then(|bytes| AutoCommit::load(bytes).ok())
        .unwrap_or_default();
    change(&mut doc);
    doc.put(ROOT, "version", version)
        .expect("a root map accepts new keys");
    doc.save()
}

/// The scalar at `prop` of `obj`, if there is one.
pub(crate) fn scalar(doc: &AutoCommit, obj: &ObjId, prop: impl Into<Prop>) -> Option<ScalarValue> {
    match doc.get(obj, prop).ok()?? {
        (Value::Scalar(value), _) => Some(value.into_owned()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_update_stamps_the_schema_version() {
        let doc = AutoCommit::load(&update(None, |_| {})).unwrap();
        assert_eq!(scalar(&doc, &ROOT, "version"), Some(ScalarValue::Uint(2)));
    }

    #[test]
    fn an_update_keeps_what_the_document_already_holds() {
        let first = update(None, |doc| {
            doc.put(ROOT, "a", 1_u64).unwrap();
        });
        let second = update(Some(&first), |doc| {
            doc.put(ROOT, "b", 2_u64).unwrap();
        });
        let doc = AutoCommit::load(&second).unwrap();
        assert_eq!(scalar(&doc, &ROOT, "a"), Some(ScalarValue::Uint(1)));
        assert_eq!(scalar(&doc, &ROOT, "b"), Some(ScalarValue::Uint(2)));
    }
}
