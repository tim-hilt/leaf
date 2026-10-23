//! Exchanging one Automerge document between Devices through a storage
//! directory (ADR-0009).
//!
//! Each Device writes its own changes as immutable chunks named
//! `<prefix><device>-<number>` and never touches another Device's chunks. The
//! prefix lets several documents share one directory, so one listing serves
//! them all (`""` for a directory of one document). Chunk
//! numbers only go up, so a Device's `Cursor` tells which chunks of the others
//! it has applied by remembering one number each, and a Sync step with nothing
//! new costs one listing.
//!
//! A step is split so the network never runs while the document is locked:
//! `pull` fetches new chunks, `Cursor::apply` merges them and `Cursor::outgoing`
//! collects the Device's own new changes, which `push` writes.
//!
//! A Device keeps its chunks few: once it has `MAX_OWN_CHUNKS`, its next chunk
//! is a snapshot of the whole document, which `push` follows by deleting the
//! chunks it replaces (ADR-0009). The snapshot has a higher number, so the
//! other Devices apply it like any chunk, and a Device with nothing yet
//! converges from it alone. A Device's first chunk in a storage is a snapshot
//! too, so the storage gets what its changes depend on.

use crate::storage::{Blob, Storage, get_bytes};
use automerge::{AutoCommit, ChangeHash};
use std::collections::BTreeMap;
use std::io;

/// How many chunks of one document a Device leaves in the storage before it
/// replaces them with a snapshot.
pub(crate) const MAX_OWN_CHUNKS: usize = 8;

/// What a Device knows of its exchange with one storage directory. Losing it
/// is harmless: chunks apply twice without harm, and the Device sends its
/// changes again.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct Cursor {
    /// The document's heads when the Device last sent: everything up to them is
    /// in its chunks.
    sent_heads: Vec<ChangeHash>,
    /// The number of the Device's latest chunk, which stays even if a storage
    /// loses its chunks, so numbers never repeat.
    sent: u64,
    /// The number of the latest chunk applied from each other Device.
    seen: BTreeMap<String, u64>,
}

/// New chunks of other Devices, fetched.
#[derive(Debug)]
pub(crate) struct Pulled {
    /// In the order of Device, then number.
    chunks: Vec<Chunk>,
    /// The numbers of the Device's own chunks in the storage.
    own: Vec<u64>,
}

#[derive(Debug)]
struct Chunk {
    device: String,
    number: u64,
    bytes: Vec<u8>,
}

/// A Device's own changes not yet in the storage.
#[derive(Debug)]
pub(crate) struct Outgoing {
    /// The chunk's name in the directory.
    name: String,
    number: u64,
    /// Empty if the new changes are all those of other Devices, which they
    /// send themselves.
    bytes: Vec<u8>,
    heads: Vec<ChangeHash>,
    /// The names of the Device's chunks this one is a snapshot of, to delete
    /// once it is written. Empty for a chunk of new changes.
    replaces: Vec<String>,
}

/// Fetches the chunks named `<prefix><device>-<number>` among `listing`, the
/// blobs of `dir`, of Devices other than `device` that `cursor` hasn't applied.
pub(crate) fn pull(
    storage: &dyn Storage,
    dir: &str,
    listing: &[Blob],
    prefix: &str,
    device: &str,
    cursor: &Cursor,
) -> io::Result<Pulled> {
    let mut wanted = Vec::new();
    let mut own = Vec::new();
    for blob in listing {
        let Some((from, number)) = blob
            .name
            .strip_prefix(prefix)
            .and_then(|name| name.rsplit_once('-'))
            .and_then(|(from, number)| Some((from.to_owned(), number.parse::<u64>().ok()?)))
        else {
            continue;
        };
        if from == device {
            own.push(number);
        } else if number > cursor.seen.get(&from).copied().unwrap_or(0) {
            wanted.push((from, number));
        }
    }
    wanted.sort();
    let mut chunks = Vec::new();
    for (from, number) in wanted {
        // A chunk replaced by its Device's snapshot meanwhile is skipped: the
        // snapshot is the next one.
        if let Some(bytes) = get_bytes(storage, &format!("{dir}/{prefix}{from}-{number}"))? {
            chunks.push(Chunk {
                device: from,
                number,
                bytes,
            });
        }
    }
    Ok(Pulled { chunks, own })
}

/// Writes `outgoing` to `dir`, which the Device's `cursor` then counts as sent,
/// and deletes the chunks it replaces.
pub(crate) fn push(
    storage: &dyn Storage,
    dir: &str,
    cursor: &mut Cursor,
    outgoing: Outgoing,
) -> io::Result<()> {
    if !outgoing.bytes.is_empty() {
        storage.put(
            &format!("{dir}/{}", outgoing.name),
            &mut outgoing.bytes.as_slice(),
        )?;
        cursor.sent = outgoing.number;
    }
    cursor.sent_heads = outgoing.heads;
    for name in &outgoing.replaces {
        storage.delete(&format!("{dir}/{name}"))?;
    }
    Ok(())
}

impl Pulled {
    /// The number of the Device's own latest chunk in the storage, 0 if none.
    fn own_latest(&self) -> u64 {
        self.own.iter().copied().max().unwrap_or(0)
    }
}

impl Cursor {
    /// Whether `pulled` calls for loading the document: there are new chunks, or
    /// the storage lost this Device's, which `apply` then sends again.
    pub fn wants(&self, pulled: &Pulled) -> bool {
        !pulled.chunks.is_empty() || pulled.own_latest() < self.sent
    }

    /// Merges `pulled` into `doc`; true if that changed it. A chunk that isn't
    /// an Automerge document is skipped for good.
    pub fn apply(&mut self, doc: &mut AutoCommit, pulled: &Pulled) -> bool {
        // The storage lost our chunks, e.g. because it is another one: send
        // everything again.
        if pulled.own_latest() < self.sent {
            self.sent_heads.clear();
        }
        self.sent = self.sent.max(pulled.own_latest());
        let before = doc.get_heads();
        for chunk in &pulled.chunks {
            let _ = doc.load_incremental(&chunk.bytes);
            let seen = self.seen.entry(chunk.device.clone()).or_default();
            *seen = (*seen).max(chunk.number);
        }
        doc.get_heads() != before
    }

    /// The changes `doc` got from its Device since the last `push`, as a chunk
    /// named with `prefix`; none if it hasn't changed. If `pulled`, the
    /// listing `doc` was merged with, shows the Device at its limit of chunks,
    /// the chunk is a snapshot replacing them. So is the Device's first chunk
    /// in a storage: it may lack what the Device merged from others, on which
    /// its own changes depend.
    pub fn outgoing(
        &self,
        doc: &mut AutoCommit,
        prefix: &str,
        pulled: &Pulled,
    ) -> Option<Outgoing> {
        let heads = doc.get_heads();
        if heads == self.sent_heads {
            return None;
        }
        let device = doc.get_actor().clone();
        let mut bytes: Vec<u8> = doc
            .get_changes(&self.sent_heads)
            .iter()
            .filter(|change| change.actor_id() == &device)
            .flat_map(|change| change.raw_bytes().iter().copied())
            .collect();
        let device = device.to_hex_string();
        let mut replaces = Vec::new();
        let first = self.sent_heads.is_empty();
        if !bytes.is_empty() && (first || pulled.own.len() >= MAX_OWN_CHUNKS) {
            bytes = doc.save();
            replaces = (pulled.own.iter())
                .map(|number| format!("{prefix}{device}-{number}"))
                .collect();
        }
        let number = self.sent + 1;
        Some(Outgoing {
            name: format!("{prefix}{device}-{number}"),
            number,
            bytes,
            heads,
            replaces,
        })
    }

    /// The cursor as stored: a line `sent <number>`, a line `heads <hash>…`
    /// and a line `seen <device> <number>` per other Device.
    pub fn encode(&self) -> String {
        let heads: String = self.sent_heads.iter().map(|h| format!(" {h}")).collect();
        let mut text = format!("sent {}\nheads{heads}\n", self.sent);
        for (device, number) in &self.seen {
            text.push_str(&format!("seen {device} {number}\n"));
        }
        text
    }

    /// The cursor `encode` made `text` from. What can't be read is forgotten.
    pub fn decode(text: &str) -> Self {
        let mut cursor = Self::default();
        for line in text.lines() {
            let mut words = line.split(' ');
            match words.next() {
                Some("sent") => {
                    cursor.sent = words.next().and_then(|n| n.parse().ok()).unwrap_or(0);
                }
                Some("heads") => cursor.sent_heads = words.filter_map(|h| h.parse().ok()).collect(),
                Some("seen") => {
                    if let (Some(device), Some(Ok(number))) =
                        (words.next(), words.next().map(str::parse))
                    {
                        cursor.seen.insert(device.to_owned(), number);
                    }
                }
                _ => {}
            }
        }
        cursor
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::DirStorage;
    use automerge::{ActorId, ROOT, ReadDoc, transaction::Transactable};
    use std::fs;
    use std::path::PathBuf;

    /// One Device's copy of a document and its cursor.
    struct Replica {
        doc: AutoCommit,
        cursor: Cursor,
    }

    impl Replica {
        fn new(n: u8) -> Self {
            Self {
                doc: AutoCommit::new().with_actor(ActorId::from([n; 16])),
                cursor: Cursor::default(),
            }
        }

        fn device(&self) -> String {
            self.doc.get_actor().to_hex_string()
        }

        fn set(&mut self, key: &str, value: &str) {
            self.doc.put(ROOT, key, value).unwrap();
        }

        fn get(&self, key: &str) -> Option<String> {
            let (value, _) = self.doc.get(ROOT, key).unwrap()?;
            Some(value.into_string().unwrap())
        }

        /// One full exchange.
        fn exchange(&mut self, storage: &dyn Storage) {
            let listing = storage.list("doc").unwrap();
            let pulled = pull(storage, "doc", &listing, "", &self.device(), &self.cursor).unwrap();
            self.cursor.apply(&mut self.doc, &pulled);
            if let Some(outgoing) = self.cursor.outgoing(&mut self.doc, "", &pulled) {
                push(storage, "doc", &mut self.cursor, outgoing).unwrap();
            }
        }
    }

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> (Self, DirStorage) {
            let dir =
                std::env::temp_dir().join(format!("leaf-chunks-{}-{name}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            let storage = DirStorage::open(&dir).unwrap();
            (Scratch(dir), storage)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn changes_reach_the_other_device_and_concurrent_ones_merge() {
        let (_alive, storage) = Scratch::new("merge");
        let (mut a, mut b) = (Replica::new(1), Replica::new(2));
        a.set("a", "from a");
        b.set("b", "from b");

        a.exchange(&storage);
        b.exchange(&storage);
        a.exchange(&storage);

        for replica in [&a, &b] {
            assert_eq!(replica.get("a").as_deref(), Some("from a"));
            assert_eq!(replica.get("b").as_deref(), Some("from b"));
        }
    }

    #[test]
    fn an_exchange_with_nothing_new_changes_nothing() {
        let (alive, storage) = Scratch::new("idle");
        let mut a = Replica::new(1);
        a.set("a", "x");
        a.exchange(&storage);
        let cursor = a.cursor.clone();
        let blobs = fs::read_dir(alive.0.join("doc")).unwrap().count();

        a.exchange(&storage);

        assert_eq!(a.cursor, cursor);
        assert_eq!(fs::read_dir(alive.0.join("doc")).unwrap().count(), blobs);
    }

    #[test]
    fn a_device_sends_only_its_own_changes() {
        let (alive, storage) = Scratch::new("own");
        let (mut a, mut b) = (Replica::new(1), Replica::new(2));
        a.set("a", "x");
        a.exchange(&storage);
        b.exchange(&storage);
        assert_eq!(b.get("a").as_deref(), Some("x"));

        b.exchange(&storage);

        let b_chunks = fs::read_dir(alive.0.join("doc"))
            .unwrap()
            .filter(|e| {
                let name = e
                    .as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .into_owned();
                name.starts_with(&b.device())
            })
            .count();
        assert_eq!(b_chunks, 0);
    }

    #[test]
    fn a_device_that_changes_again_sends_just_the_new_changes() {
        let (_alive, storage) = Scratch::new("again");
        let (mut a, mut b) = (Replica::new(1), Replica::new(2));
        a.set("a", "1");
        a.exchange(&storage);
        b.exchange(&storage);
        a.set("a", "2");
        a.set("c", "3");
        a.exchange(&storage);
        b.exchange(&storage);

        assert_eq!(b.get("a").as_deref(), Some("2"));
        assert_eq!(b.get("c").as_deref(), Some("3"));
    }

    #[test]
    fn a_cursor_survives_encoding_and_garbage_decodes_to_a_fresh_one() {
        let (_alive, storage) = Scratch::new("encode");
        let (mut a, mut b) = (Replica::new(1), Replica::new(2));
        a.set("a", "x");
        a.exchange(&storage);
        b.exchange(&storage);
        b.set("b", "y");
        b.exchange(&storage);

        assert_eq!(Cursor::decode(&b.cursor.encode()), b.cursor);
        assert_eq!(Cursor::decode("\u{0}garbage\nsent x"), Cursor::default());
    }

    #[test]
    fn a_device_sends_everything_again_to_a_storage_that_lacks_its_chunks() {
        let (_one, first) = Scratch::new("first");
        let (_two, second) = Scratch::new("second");
        let (mut a, mut b) = (Replica::new(1), Replica::new(2));
        a.set("a", "x");
        a.exchange(&first);

        a.exchange(&second);
        b.exchange(&second);

        assert_eq!(b.get("a").as_deref(), Some("x"));
    }

    #[test]
    fn a_storage_that_lacks_a_devices_chunks_also_gets_what_it_merged_from_others() {
        let (_one, first) = Scratch::new("merged-first");
        let (_two, second) = Scratch::new("merged-second");
        let (mut a, mut b, mut c) = (Replica::new(1), Replica::new(2), Replica::new(3));
        b.set("b", "from b");
        b.exchange(&first);
        a.set("a", "from a");
        a.exchange(&first);
        a.set("a", "later");

        // B never reaches the second storage.
        a.exchange(&second);
        c.exchange(&second);

        assert_eq!(c.get("a").as_deref(), Some("later"));
        assert_eq!(c.get("b").as_deref(), Some("from b"));
    }

    #[test]
    fn a_device_that_lost_its_cursor_neither_loses_nor_overwrites_chunks() {
        let (_alive, storage) = Scratch::new("lost");
        let (mut a, mut b) = (Replica::new(1), Replica::new(2));
        a.set("a", "x");
        a.exchange(&storage);
        a.cursor = Cursor::default();
        a.set("c", "z");

        a.exchange(&storage);
        b.exchange(&storage);

        assert_eq!(b.get("a").as_deref(), Some("x"));
        assert_eq!(b.get("c").as_deref(), Some("z"));
    }

    #[test]
    fn documents_with_different_prefixes_share_one_directory_without_mixing() {
        let (_alive, storage) = Scratch::new("prefix");
        let (mut a, b) = (Replica::new(1), Replica::new(2));
        a.set("a", "x");
        let pulled = pull(&storage, "doc", &[], "one.", &a.device(), &a.cursor).unwrap();
        let outgoing = a.cursor.outgoing(&mut a.doc, "one.", &pulled).unwrap();
        push(&storage, "doc", &mut a.cursor, outgoing).unwrap();
        let listing = storage.list("doc").unwrap();

        let pull_as_b =
            |prefix: &str| pull(&storage, "doc", &listing, prefix, &b.device(), &b.cursor).unwrap();

        assert!(b.cursor.wants(&pull_as_b("one.")));
        assert!(!b.cursor.wants(&pull_as_b("two.")));
    }

    #[test]
    fn a_device_wants_to_load_a_document_only_for_new_chunks_or_lost_own_ones() {
        let (_one, first) = Scratch::new("wants-first");
        let (_two, empty) = Scratch::new("wants-empty");
        let mut a = Replica::new(1);
        a.set("a", "x");
        a.exchange(&first);
        let wants = |storage: &dyn Storage| {
            let listing = storage.list("doc").unwrap();
            let pulled = pull(storage, "doc", &listing, "", &a.device(), &a.cursor).unwrap();
            a.cursor.wants(&pulled)
        };

        assert!(!wants(&first));
        assert!(wants(&empty));
    }

    /// The names in `doc` that are chunks of `device`.
    fn chunks_of(storage: &dyn Storage, device: &str) -> Vec<String> {
        let mut names: Vec<String> = storage
            .list("doc")
            .unwrap()
            .into_iter()
            .map(|blob| blob.name)
            .filter(|name| name.starts_with(device))
            .collect();
        names.sort();
        names
    }

    #[test]
    fn a_devices_chunk_count_stays_bounded_however_many_changes_it_makes() {
        let (_alive, storage) = Scratch::new("bounded");
        let mut a = Replica::new(1);
        let mut most = 0;
        for n in 0..100 {
            a.set("a", &n.to_string());
            a.exchange(&storage);
            most = most.max(chunks_of(&storage, &a.device()).len());
        }

        assert!(most <= MAX_OWN_CHUNKS, "{most} chunks");
        assert!(chunks_of(&storage, &a.device()).len() < 100);
    }

    #[test]
    fn devices_converge_after_compaction_also_from_a_fresh_start() {
        let (_alive, storage) = Scratch::new("compacted");
        let (mut a, mut b, mut fresh) = (Replica::new(1), Replica::new(2), Replica::new(3));
        for n in 0..(3 * MAX_OWN_CHUNKS) {
            a.set(&format!("a{n}"), "x");
            a.exchange(&storage);
            // b follows only now and then, so its chunks are replaced meanwhile.
            if n % 7 == 0 {
                b.set(&format!("b{n}"), "y");
                b.exchange(&storage);
            }
        }
        a.set("last", "z");
        a.exchange(&storage);
        b.exchange(&storage);
        a.exchange(&storage);
        fresh.exchange(&storage);

        for replica in [&a, &b, &fresh] {
            assert_eq!(replica.doc.keys(ROOT).count(), 3 * MAX_OWN_CHUNKS + 4 + 1);
            assert_eq!(replica.get("last").as_deref(), Some("z"));
            assert_eq!(replica.get("a0").as_deref(), Some("x"));
            assert_eq!(replica.get("b14").as_deref(), Some("y"));
        }
    }

    #[test]
    fn compacting_never_deletes_the_chunks_of_another_device() {
        let (_alive, storage) = Scratch::new("others");
        let (mut a, mut b) = (Replica::new(1), Replica::new(2));
        b.set("b", "y");
        b.exchange(&storage);
        let theirs = chunks_of(&storage, &b.device());

        for n in 0..(2 * MAX_OWN_CHUNKS) {
            a.set("a", &n.to_string());
            a.exchange(&storage);
        }

        assert_eq!(chunks_of(&storage, &b.device()), theirs);
    }

    #[test]
    fn a_chunk_that_is_not_a_document_is_skipped() {
        let (_alive, storage) = Scratch::new("garbage");
        storage.put("doc/ff-1", &mut &b"garbage"[..]).unwrap();
        storage.put("doc/not-a-chunk", &mut &b"x"[..]).unwrap();
        let mut a = Replica::new(1);

        a.exchange(&storage);

        assert_eq!(a.cursor.seen.get("ff"), Some(&1));
    }
}
