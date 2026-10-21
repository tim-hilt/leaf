//! The Library document: the Library's Automerge document (ADR-0015), listing
//! every Import and every Remove.
//!
//! Schema, version 1: the root holds `version`, an `imports` map and a
//! `removed` map. `imports` maps each Import ID to a map of `hash` (the File's
//! SHA-256), `name` (the original file name) and `imported` (Date Imported, in
//! milliseconds since the Unix epoch). `removed` holds the ID of every Import
//! that was Removed. Imports are never edited. A Remove covers every Import of
//! the File the Device knows of; an Import made concurrently elsewhere is a new
//! one and stays.
//!
//! Devices that first write to `imports` or `removed` concurrently each create
//! their own map; reading lists the entries of all of them (see `state`).

use crate::chunks::{Cursor, Outgoing, Pulled};
use crate::state;
use automerge::{
    ActorId, AutoCommit, ObjId, ObjType, ReadDoc, ScalarValue, Value, transaction::Transactable,
};
use std::collections::HashSet;
use std::io;

pub(crate) const SCHEMA_VERSION: u64 = 1;

/// Copying a File into the Library on one Device.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Import {
    pub id: String,
    /// SHA-256 of the File, lowercase hex. Identifies the Document.
    pub hash: String,
    pub name: String,
    /// Date Imported, in milliseconds since the Unix epoch.
    pub imported: u64,
    pub removed: bool,
}

/// A loaded Library document. Reading doesn't touch the Automerge document:
/// the Imports are listed once, when it loads or changes.
#[derive(Debug)]
pub(crate) struct LibraryDoc {
    doc: AutoCommit,
    /// Every Import, oldest first.
    imports: Vec<Import>,
}

impl LibraryDoc {
    /// The Library document stored as `bytes`, changed as `actor`. Missing or
    /// unreadable `bytes` give an empty one.
    pub fn load(bytes: Option<&[u8]>, actor: &ActorId) -> Self {
        let doc = bytes
            .and_then(|bytes| AutoCommit::load(bytes).ok())
            .unwrap_or_default()
            .with_actor(actor.clone());
        let imports = read_imports(&doc);
        Self { doc, imports }
    }

    /// Every Import, Removed ones too, oldest first.
    pub fn imports(&self) -> &[Import] {
        &self.imports
    }

    /// The Imports of the File `hash` that weren't Removed, oldest first.
    pub fn live<'a>(&'a self, hash: &'a str) -> impl Iterator<Item = &'a Import> {
        self.imports
            .iter()
            .filter(move |i| i.hash == hash && !i.removed)
    }

    /// The Files that were Removed: every Import of each is Removed. A File
    /// with a live Import, e.g. one made elsewhere since, isn't among them.
    pub fn removed_files(&self) -> HashSet<&str> {
        let live: HashSet<&str> = self
            .imports
            .iter()
            .filter(|i| !i.removed)
            .map(|i| i.hash.as_str())
            .collect();
        self.imports
            .iter()
            .filter(|i| i.removed && !live.contains(i.hash.as_str()))
            .map(|i| i.hash.as_str())
            .collect()
    }

    /// Records an Import of the File `hash`, `imported` in milliseconds since
    /// the Unix epoch, and returns its ID.
    pub fn add_import(&mut self, hash: &str, name: &str, imported: u64) -> String {
        state::stamp_version(&mut self.doc, SCHEMA_VERSION);
        let id = state::new_id();
        let map = state::map_to_write(&mut self.doc, "imports");
        let entry = self
            .doc
            .put_object(&map, id.as_str(), ObjType::Map)
            .expect("a map accepts new keys");
        let fields = [
            ("hash", ScalarValue::Str(hash.into())),
            ("name", ScalarValue::Str(name.into())),
            ("imported", ScalarValue::Uint(imported)),
        ];
        for (key, value) in fields {
            self.doc
                .put(&entry, key, value)
                .expect("a new map accepts new keys");
        }
        let import = Import {
            id: id.clone(),
            hash: hash.to_owned(),
            name: name.to_owned(),
            imported,
            removed: false,
        };
        let at = self.imports.partition_point(|i| order(i) <= order(&import));
        self.imports.insert(at, import);
        id
    }

    /// Records a Remove of every Import of the File `hash`. False if there was
    /// none to Remove.
    pub fn remove(&mut self, hash: &str) -> bool {
        let ids: Vec<_> = self.live(hash).map(|i| i.id.clone()).collect();
        if ids.is_empty() {
            return false;
        }
        state::stamp_version(&mut self.doc, SCHEMA_VERSION);
        let map = state::map_to_write(&mut self.doc, "removed");
        for id in ids {
            self.doc
                .put(&map, id, true)
                .expect("a map accepts new keys");
        }
        for import in self.imports.iter_mut().filter(|i| i.hash == hash) {
            import.removed = true;
        }
        true
    }

    /// Merges what `pulled` fetched into the document; true if that changed it.
    /// Fails with `Unsupported`, merging nothing, if that makes the document
    /// one of a newer schema version than this app knows.
    pub fn merge(&mut self, cursor: &mut Cursor, pulled: &Pulled) -> io::Result<bool> {
        let heads = self.doc.get_heads();
        let before = cursor.clone();
        let merged = cursor.apply(&mut self.doc, pulled);
        if let Err(e) = state::check_schema(&self.doc, SCHEMA_VERSION) {
            // Takes what was merged back out.
            let actor = self.doc.get_actor().clone();
            self.doc = self
                .doc
                .fork_at(&heads)
                .expect("the document knows its own heads")
                .with_actor(actor);
            *cursor = before;
            return Err(e);
        }
        if merged {
            self.imports = read_imports(&self.doc);
        }
        Ok(merged)
    }

    /// This Device's changes that `cursor` doesn't count as sent.
    pub fn outgoing(&mut self, cursor: &Cursor, prefix: &str, pulled: &Pulled) -> Option<Outgoing> {
        cursor.outgoing(&mut self.doc, prefix, pulled)
    }

    /// The document as stored bytes.
    pub fn save(&mut self) -> Vec<u8> {
        self.doc.save()
    }
}

/// Every Import in `doc`, oldest first, ties by ID. Incomplete ones are
/// skipped.
fn read_imports(doc: &AutoCommit) -> Vec<Import> {
    let removed: HashSet<String> = state::maps(doc, "removed")
        .iter()
        .flat_map(|map| doc.keys(map))
        .collect();
    let mut imports = Vec::new();
    for map in state::maps(doc, "imports") {
        for id in doc.keys(&map) {
            let Ok(Some((Value::Object(ObjType::Map), entry))) = doc.get(&map, id.as_str()) else {
                continue;
            };
            let import = (|| {
                Some(Import {
                    hash: text(doc, &entry, "hash")?,
                    name: text(doc, &entry, "name")?,
                    imported: state::scalar(doc, &entry, "imported")?.as_u64()?,
                    removed: removed.contains(&id),
                    id: id.clone(),
                })
            })();
            imports.extend(import);
        }
    }
    imports.sort_by(|a, b| order(a).cmp(&order(b)));
    imports
}

/// What Imports are ordered by: oldest first, ties by ID.
fn order(import: &Import) -> (u64, &str) {
    (import.imported, &import.id)
}

fn text(doc: &AutoCommit, entry: &ObjId, key: &str) -> Option<String> {
    state::scalar(doc, entry, key)?.into_string().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use automerge::ROOT;

    fn actor(n: u8) -> ActorId {
        ActorId::from([n; 16])
    }

    fn reloaded(doc: &mut LibraryDoc, actor: &ActorId) -> LibraryDoc {
        LibraryDoc::load(Some(&doc.save()), actor)
    }

    #[test]
    fn an_added_import_is_listed_and_survives_saving() {
        let mut doc = LibraryDoc::load(None, &actor(1));
        let id = doc.add_import("abc", "Paper.pdf", 1_000);

        let expected = Import {
            id,
            hash: "abc".into(),
            name: "Paper.pdf".into(),
            imported: 1_000,
            removed: false,
        };
        assert_eq!(doc.imports().to_vec(), vec![expected.clone()]);
        assert_eq!(
            reloaded(&mut doc, &actor(1)).imports().to_vec(),
            vec![expected]
        );
    }

    #[test]
    fn imports_are_listed_oldest_first() {
        let mut doc = LibraryDoc::load(None, &actor(1));
        doc.add_import("late", "b.pdf", 2_000);
        doc.add_import("early", "a.pdf", 1_000);

        let hashes: Vec<_> = doc.imports().iter().map(|i| i.hash.as_str()).collect();
        assert_eq!(hashes, ["early", "late"]);
    }

    #[test]
    fn a_remove_covers_every_import_of_the_file_and_no_other() {
        let mut doc = LibraryDoc::load(None, &actor(1));
        doc.add_import("abc", "a.pdf", 1);
        doc.add_import("abc", "a.pdf", 2);
        doc.add_import("def", "b.pdf", 3);

        assert!(doc.remove("abc"));

        let mut doc = reloaded(&mut doc, &actor(1));
        assert_eq!(doc.live("abc").count(), 0);
        assert_eq!(doc.live("def").count(), 1);
        assert_eq!(doc.imports().iter().filter(|i| i.removed).count(), 2);
        assert!(!doc.remove("abc"));
    }

    #[test]
    fn a_reimport_after_a_remove_is_a_new_import() {
        let mut doc = LibraryDoc::load(None, &actor(1));
        let first = doc.add_import("abc", "a.pdf", 1);
        doc.remove("abc");

        let second = doc.add_import("abc", "a.pdf", 2);

        let live: Vec<_> = doc.live("abc").map(|i| i.id.clone()).collect();
        assert_ne!(first, second);
        assert_eq!(live, [second]);
    }

    #[test]
    fn a_file_is_removed_only_while_none_of_its_imports_is_live() {
        let mut doc = LibraryDoc::load(None, &actor(1));
        doc.add_import("gone", "a.pdf", 1);
        doc.add_import("back", "b.pdf", 2);
        doc.add_import("kept", "c.pdf", 3);
        doc.remove("gone");
        doc.remove("back");
        assert_eq!(doc.removed_files(), HashSet::from(["gone", "back"]));

        doc.add_import("back", "b.pdf", 4);

        assert_eq!(doc.removed_files(), HashSet::from(["gone"]));
    }

    #[test]
    fn imports_added_on_two_devices_from_nothing_are_both_kept() {
        let mut one = LibraryDoc::load(None, &actor(1));
        let mut two = LibraryDoc::load(None, &actor(2));
        one.add_import("abc", "a.pdf", 1);
        two.add_import("def", "b.pdf", 2);
        two.remove("def");

        one.doc.merge(&mut two.doc).unwrap();
        let merged = reloaded(&mut one, &actor(1));

        let listed: Vec<_> = merged
            .imports()
            .iter()
            .map(|i| (i.hash.as_str(), i.removed))
            .collect();
        assert_eq!(listed, [("abc", false), ("def", true)]);
    }

    #[test]
    fn changes_are_made_as_the_given_actor() {
        let mut doc = LibraryDoc::load(None, &actor(3));
        doc.add_import("abc", "a.pdf", 1);
        doc.remove("abc");

        let changes = doc.doc.get_changes(&[]);
        assert!(!changes.is_empty());
        assert!(changes.iter().all(|c| c.actor_id() == &actor(3)));
    }

    #[test]
    fn the_schema_version_is_stamped_once_and_never_lowered() {
        let mut doc = LibraryDoc::load(None, &actor(1));
        doc.add_import("abc", "a.pdf", 1);
        let version = |doc: &LibraryDoc| state::scalar(&doc.doc, &ROOT, "version");
        assert_eq!(version(&doc), Some(ScalarValue::Uint(1)));
        let changes = doc.doc.get_changes(&[]).len();

        doc.add_import("def", "b.pdf", 2);
        assert_eq!(doc.doc.get_changes(&[]).len(), changes + 1);

        doc.doc.put(ROOT, "version", 9_u64).unwrap();
        doc.add_import("ghi", "c.pdf", 3);
        assert_eq!(version(&doc), Some(ScalarValue::Uint(9)));
    }

    #[test]
    fn unreadable_bytes_give_an_empty_library_document() {
        let doc = LibraryDoc::load(Some(b"garbage"), &actor(1));
        assert!(doc.imports().is_empty());
    }
}
