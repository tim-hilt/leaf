//! A Document's Automerge document (ADR-0008): the synced state kept next to
//! its File, shared by Reading Progress (`progress`) and Markup (`markup`).
//!
//! Schema, version 2: the root holds `version`, a `progress` map (see
//! `progress`), and `highlights` and `page_notes` maps (see `markup`). Version
//! 1 had no Markup; its first write makes it version 2.
//!
//! Also the Automerge helpers shared with Preferences (`preferences`). Every
//! local change is made as the Library's Device ID, see `library`.

use automerge::{
    ActorId, AutoCommit, ObjId, ObjType, Prop, ROOT, ReadDoc, ScalarValue, Value,
    transaction::Transactable,
};

const SCHEMA_VERSION: u64 = 2;

/// The Automerge document `existing` with `change` made as `actor`, stamped
/// with the current schema version (never lowering a newer one) and compacted. A missing or unreadable
/// `existing` starts a new document.
pub(crate) fn update(
    existing: Option<&[u8]>,
    actor: &ActorId,
    change: impl FnOnce(&mut AutoCommit),
) -> Vec<u8> {
    update_versioned(existing, actor, SCHEMA_VERSION, change)
}

/// `update` for an Automerge document with its own schema `version`, like
/// Preferences (`preferences`).
pub(crate) fn update_versioned(
    existing: Option<&[u8]>,
    actor: &ActorId,
    version: u64,
    change: impl FnOnce(&mut AutoCommit),
) -> Vec<u8> {
    let mut doc = existing
        .and_then(|bytes| AutoCommit::load(bytes).ok())
        .unwrap_or_default()
        .with_actor(actor.clone());
    change(&mut doc);
    // Never lowers the version, and adds no change if it is stamped already.
    let stored = scalar(&doc, &ROOT, "version").and_then(|v| v.as_u64());
    if stored.is_none_or(|stored| stored < version) {
        doc.put(ROOT, "version", version)
            .expect("a root map accepts new keys");
    }
    doc.save()
}

/// Every map at the root key `key` of `doc`, the one Automerge picks as winner
/// last. Devices that first write to it concurrently each create their own.
pub(crate) fn maps(doc: &AutoCommit, key: &str) -> Vec<ObjId> {
    doc.get_all(ROOT, key)
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

/// The map at the root key `key` of `doc` to add entries to: Automerge's winner
/// if devices created several, a new one if there is none.
pub(crate) fn map_to_write(doc: &mut AutoCommit, key: &str) -> ObjId {
    maps(doc, key).pop().unwrap_or_else(|| {
        doc.put_object(ROOT, key, ObjType::Map)
            .expect("a root map accepts new keys")
    })
}

/// A new ID for a map entry, unique across devices.
pub(crate) fn new_id() -> String {
    ActorId::random().to_hex_string()
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

    fn actor() -> ActorId {
        ActorId::from([7; 16])
    }

    #[test]
    fn an_update_stamps_the_schema_version() {
        let doc = AutoCommit::load(&update(None, &actor(), |_| {})).unwrap();
        assert_eq!(scalar(&doc, &ROOT, "version"), Some(ScalarValue::Uint(2)));
    }

    #[test]
    fn an_update_never_lowers_the_version_and_adds_no_change_for_a_stamped_one() {
        let first = update(None, &actor(), |_| {});
        let second = update(Some(&first), &actor(), |_| {});
        let mut doc = AutoCommit::load(&second).unwrap();
        assert_eq!(doc.get_changes(&[]).len(), 1);

        let newer = update_versioned(Some(&second), &actor(), 9, |_| {});
        let older = update(Some(&newer), &actor(), |_| {});
        let doc = AutoCommit::load(&older).unwrap();
        assert_eq!(scalar(&doc, &ROOT, "version"), Some(ScalarValue::Uint(9)));
    }

    #[test]
    fn new_ids_differ() {
        assert_ne!(new_id(), new_id());
    }

    #[test]
    fn an_update_keeps_what_the_document_already_holds() {
        let first = update(None, &actor(), |doc| {
            doc.put(ROOT, "a", 1_u64).unwrap();
        });
        let second = update(Some(&first), &actor(), |doc| {
            doc.put(ROOT, "b", 2_u64).unwrap();
        });
        let doc = AutoCommit::load(&second).unwrap();
        assert_eq!(scalar(&doc, &ROOT, "a"), Some(ScalarValue::Uint(1)));
        assert_eq!(scalar(&doc, &ROOT, "b"), Some(ScalarValue::Uint(2)));
    }

    #[test]
    fn an_update_is_made_as_the_given_actor() {
        let bytes = update(None, &actor(), |doc| {
            doc.put(ROOT, "a", 1_u64).unwrap();
        });
        let again = update(Some(&bytes), &actor(), |doc| {
            doc.put(ROOT, "b", 2_u64).unwrap();
        });
        let mut doc = AutoCommit::load(&again).unwrap();
        let changes = doc.get_changes(&[]);
        assert_eq!(changes.len(), 2);
        assert!(changes.iter().all(|c| c.actor_id() == &actor()));
    }
}
