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
use std::io;

pub(crate) const SCHEMA_VERSION: u64 = 2;

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
    if self::version(&doc) < version {
        doc.put(ROOT, "version", version)
            .expect("a root map accepts new keys");
    }
    doc.save()
}

/// The Automerge document stored as `bytes`, made anew by `actor`: the same
/// content, without the history, as one change of `actor`. Of concurrent
/// values, Automerge's winner stays. For a document written before Device IDs,
/// whose changes no Device would send (see `chunks`). None if `bytes` is
/// unreadable.
pub(crate) fn remake(bytes: &[u8], actor: &ActorId) -> Option<Vec<u8>> {
    let content = AutoCommit::load(bytes).ok()?.hydrate(ROOT, None).ok()?;
    let mut doc = AutoCommit::new().with_actor(actor.clone());
    doc.update_object(ROOT, &content).ok()?;
    Some(doc.save())
}

/// The schema version stamped in `doc`: the highest one if Devices stamped it
/// concurrently, 0 if none.
pub(crate) fn version(doc: &AutoCommit) -> u64 {
    doc.get_all(ROOT, "version")
        .map(|values| {
            values
                .into_iter()
                .filter_map(|(value, _)| value.as_u64())
                .max()
                .unwrap_or(0)
        })
        .unwrap_or(0)
}

/// Fails with `Unsupported` if `doc` has a newer schema version than `known`:
/// this app doesn't understand it and must neither merge nor write it.
pub(crate) fn check_schema(doc: &AutoCommit, known: u64) -> io::Result<()> {
    if version(doc) > known {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "a synced document has a newer schema version",
        ));
    }
    Ok(())
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
    fn the_version_of_concurrent_stamps_is_the_highest_whichever_wins() {
        let old = update_versioned(None, &ActorId::from([1; 16]), 1, |_| {});
        let new = update_versioned(None, &ActorId::from([2; 16]), 3, |_| {});
        for (mut first, mut second) in [(old.clone(), new.clone()), (new, old)] {
            let mut doc = AutoCommit::load(&std::mem::take(&mut first)).unwrap();
            doc.merge(&mut AutoCommit::load(&std::mem::take(&mut second)).unwrap())
                .unwrap();
            assert_eq!(version(&doc), 3);
        }
    }

    #[test]
    fn a_document_with_a_newer_version_than_known_fails_the_schema_check() {
        let doc = AutoCommit::load(&update_versioned(None, &actor(), 3, |_| {})).unwrap();
        assert!(check_schema(&doc, 3).is_ok());
        assert_eq!(
            check_schema(&doc, 2).unwrap_err().kind(),
            io::ErrorKind::Unsupported
        );
    }

    #[test]
    fn a_remade_document_holds_the_same_content_as_changes_of_the_actor_alone() {
        let mut bytes = update(None, &ActorId::random(), |doc| {
            doc.put(ROOT, "a", 1_u64).unwrap();
            let text = doc.put_object(ROOT, "t", ObjType::Text).unwrap();
            doc.splice_text(&text, 0, 0, "note").unwrap();
        });
        bytes = update(Some(&bytes), &ActorId::random(), |doc| {
            let list = doc.put_object(ROOT, "l", ObjType::List).unwrap();
            doc.insert(&list, 0, 2.5).unwrap();
        });
        let old = AutoCommit::load(&bytes).unwrap();

        let mut remade = AutoCommit::load(&remake(&bytes, &actor()).unwrap()).unwrap();

        assert_eq!(remade.hydrate(ROOT, None), old.hydrate(ROOT, None));
        assert!(
            remade
                .get_changes(&[])
                .iter()
                .all(|c| c.actor_id() == &actor())
        );
        assert!(remake(b"garbage", &actor()).is_none());
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
