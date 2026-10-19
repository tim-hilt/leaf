//! The Sync loop: one background thread that runs `Library::sync` steps
//! against a storage while a Cloud Provider is Connected (ADR-0009).
//!
//! A step runs
//!
//! - once `Intervals::debounce` after the last local change,
//! - at once on start and `foreground`,
//! - every `Intervals::poll` while in the foreground,
//! - once more at `background`, to flush; then the loop idles.
//!
//! There is no async runtime: the thread sleeps on a condition variable until
//! the next step is due. Dropping the `SyncLoop` is Disconnecting: running
//! transfers are cancelled and the thread is joined.

use crate::library::{Library, now};
use crate::storage::{Blob, Storage};
use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// Where Sync stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// A step is running.
    Syncing,
    /// The last step succeeded, at `at` milliseconds since the Unix epoch.
    Synced { at: u64 },
    /// The last step failed. The next one retries.
    Offline,
}

/// Told what happens in the loop, from its thread: never while a lock of the
/// loop is held, never after the `SyncLoop` is dropped.
pub trait Observer: Send + Sync {
    fn status(&self, status: Status);
    /// A step changed the Documents: they are worth listing again.
    fn library_changed(&self);
}

/// When steps run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Intervals {
    /// How long after the last local change a step runs.
    pub debounce: Duration,
    /// How long after a step the next one runs, in the foreground.
    pub poll: Duration,
}

impl Default for Intervals {
    fn default() -> Self {
        Self {
            debounce: Duration::from_secs(3),
            poll: Duration::from_secs(10),
        }
    }
}

/// A running Sync loop.
pub struct SyncLoop {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

struct Shared {
    state: Mutex<State>,
    wake: Condvar,
    cancelled: Arc<AtomicBool>,
}

/// What the loop is waiting for.
struct State {
    foreground: bool,
    /// A step is wanted at once: at start, `foreground` and `background`.
    immediate: bool,
    /// The latest local change no step has sent yet.
    changed: Option<Instant>,
    /// When the next step is due on its own; only in the foreground.
    poll: Option<Instant>,
}

impl State {
    /// When the next step is due; `None` for never.
    fn due(&self, now: Instant, intervals: &Intervals) -> Option<Instant> {
        if self.immediate {
            return Some(now);
        }
        if !self.foreground {
            return None;
        }
        [self.changed.map(|at| at + intervals.debounce), self.poll]
            .into_iter()
            .flatten()
            .min()
    }
}

impl SyncLoop {
    /// Starts syncing `library` with `storage`, in the foreground: the first
    /// step runs at once.
    pub fn start(
        library: Arc<Library>,
        storage: Arc<dyn Storage>,
        observer: Arc<dyn Observer>,
        intervals: Intervals,
    ) -> Self {
        let cancelled = Arc::new(AtomicBool::new(false));
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                foreground: true,
                immediate: true,
                changed: None,
                poll: None,
            }),
            wake: Condvar::new(),
            cancelled: cancelled.clone(),
        });
        let storage = Cancellable {
            inner: storage,
            cancelled,
        };
        let thread = {
            let shared = shared.clone();
            thread::spawn(move || shared.run(&library, &storage, &*observer, &intervals))
        };
        Self {
            shared,
            thread: Some(thread),
        }
    }

    /// Something changed locally: a step sends it after the debounce interval,
    /// or at `background`. Each change restarts the interval, so a burst goes
    /// out as one.
    pub fn local_change(&self) {
        self.update(|state| state.changed = Some(Instant::now()));
    }

    /// The app is in the foreground: a step runs at once, and then every poll
    /// interval.
    pub fn foreground(&self) {
        self.update(|state| {
            state.foreground = true;
            state.immediate = true;
        });
    }

    /// The app goes to the background: one more step flushes, then the loop
    /// idles until `foreground`. Returns at once.
    pub fn background(&self) {
        self.update(|state| {
            state.foreground = false;
            state.immediate = true;
        });
    }

    fn update(&self, change: impl FnOnce(&mut State)) {
        change(&mut self.shared.lock());
        self.shared.wake.notify_one();
    }
}

impl Drop for SyncLoop {
    fn drop(&mut self) {
        {
            // Under the lock, so the thread can't miss it between checking
            // the flag and waiting.
            let _state = self.shared.lock();
            self.shared.cancelled.store(true, Relaxed);
        }
        self.shared.wake.notify_one();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Relaxed)
    }

    fn run(
        &self,
        library: &Library,
        storage: &dyn Storage,
        observer: &dyn Observer,
        intervals: &Intervals,
    ) {
        let mut state = self.lock();
        while !self.is_cancelled() {
            let now = Instant::now();
            match state.due(now, intervals) {
                None => {
                    state = self
                        .wake
                        .wait(state)
                        .unwrap_or_else(PoisonError::into_inner)
                }
                Some(due) if due > now => {
                    state = self
                        .wake
                        .wait_timeout(state, due - now)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
                Some(_) => {
                    state.immediate = false;
                    state.changed = None;
                    drop(state);
                    self.step(library, storage, observer);
                    state = self.lock();
                    state.poll = state.foreground.then(|| Instant::now() + intervals.poll);
                }
            }
        }
    }

    fn step(&self, library: &Library, storage: &dyn Storage, observer: &dyn Observer) {
        observer.status(Status::Syncing);
        let changes = library.sync_changes();
        let result = library.sync(storage);
        if self.is_cancelled() {
            return;
        }
        if library.sync_changes() != changes {
            observer.library_changed();
        }
        observer.status(match result {
            Ok(()) => Status::Synced { at: now() },
            Err(_) => Status::Offline,
        });
    }
}

/// A storage that fails once cancelled, also in the middle of a transfer.
struct Cancellable {
    inner: Arc<dyn Storage>,
    cancelled: Arc<AtomicBool>,
}

impl Cancellable {
    fn check(&self) -> io::Result<()> {
        check(&self.cancelled)
    }
}

fn check(cancelled: &AtomicBool) -> io::Result<()> {
    // Not `Interrupted`: `io::copy` retries that.
    if cancelled.load(Relaxed) {
        Err(io::Error::other("Sync cancelled"))
    } else {
        Ok(())
    }
}

/// A reader that fails once cancelled.
struct Checked<R> {
    inner: R,
    cancelled: Arc<AtomicBool>,
}

impl<R: Read> Read for Checked<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        check(&self.cancelled)?;
        self.inner.read(buf)
    }
}

impl Storage for Cancellable {
    fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
        self.check()?;
        let mut data = Checked {
            inner: data,
            cancelled: self.cancelled.clone(),
        };
        self.inner.put(name, &mut data)
    }

    fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
        self.check()?;
        Ok(self.inner.get(name)?.map(|data| {
            Box::new(Checked {
                inner: data,
                cancelled: self.cancelled.clone(),
            }) as Box<dyn Read + Send>
        }))
    }

    fn list(&self, dir: &str) -> io::Result<Vec<Blob>> {
        self.check()?;
        self.inner.list(dir)
    }

    fn delete(&self, name: &str) -> io::Result<()> {
        self.check()?;
        self.inner.delete(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::ImportResult;
    use crate::storage::DirStorage;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, AtomicUsize};
    use std::thread::sleep;

    const HOUR: Duration = Duration::from_secs(3600);
    const MS: Duration = Duration::from_millis(1);

    fn intervals(debounce: Duration, poll: Duration) -> Intervals {
        Intervals { debounce, poll }
    }

    /// Waits until `condition` holds, for at most 5 seconds.
    fn eventually(what: &str, condition: impl Fn() -> bool) {
        let give_up = Instant::now() + Duration::from_secs(5);
        while !condition() {
            assert!(Instant::now() < give_up, "timed out waiting for {what}");
            sleep(MS);
        }
    }

    /// A temp dir holding the cloud and the Devices' Libraries.
    struct Home {
        dir: PathBuf,
        /// Opened once: opening a storage clears its unfinished puts.
        cloud: Arc<DirStorage>,
    }

    impl Home {
        fn new() -> Self {
            static NEXT: AtomicU32 = AtomicU32::new(0);
            let dir = std::env::temp_dir().join(format!(
                "leafpdf-loop-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Relaxed)
            ));
            let cloud = Arc::new(DirStorage::open(dir.join("cloud")).unwrap());
            Self { dir, cloud }
        }

        fn cloud(&self) -> Arc<DirStorage> {
            self.cloud.clone()
        }

        fn device(&self, name: &str) -> Arc<Library> {
            Arc::new(Library::open(self.dir.join(name).join("library")).unwrap())
        }

        /// Imports a File with `bytes` into `library` and returns its ID.
        fn import(&self, library: &Library, bytes: &[u8]) -> String {
            let source = self.dir.join(format!("{}.pdf", bytes.len()));
            fs::write(&source, bytes).unwrap();
            match library.import(&source, |_, _| {}).unwrap() {
                ImportResult::Imported(d) | ImportResult::AlreadyImported(d) => d.id,
            }
        }
    }

    impl Drop for Home {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    fn ids(library: &Library) -> Vec<String> {
        library
            .documents()
            .unwrap()
            .into_iter()
            .map(|d| d.id)
            .collect()
    }

    #[derive(Default)]
    struct Events {
        statuses: Mutex<Vec<Status>>,
        library_changed: AtomicUsize,
    }

    impl Events {
        /// How many steps have ended.
        fn steps(&self) -> usize {
            let statuses = self.statuses.lock().unwrap();
            statuses
                .iter()
                .filter(|s| !matches!(s, Status::Syncing))
                .count()
        }

        fn last(&self) -> Option<Status> {
            self.statuses.lock().unwrap().last().copied()
        }
    }

    impl Observer for Events {
        fn status(&self, status: Status) {
            self.statuses.lock().unwrap().push(status);
        }
        fn library_changed(&self) {
            self.library_changed.fetch_add(1, Relaxed);
        }
    }

    fn start(
        library: &Arc<Library>,
        storage: Arc<dyn Storage>,
        intervals: Intervals,
    ) -> (SyncLoop, Arc<Events>) {
        let events = Arc::new(Events::default());
        let sync_loop = SyncLoop::start(library.clone(), storage, events.clone(), intervals);
        (sync_loop, events)
    }

    #[test]
    fn the_loop_syncs_at_once_when_it_starts() {
        let home = Home::new();
        let (a, b) = (home.device("a"), home.device("b"));
        let id = home.import(&a, b"on a");
        let (_loop, events) = start(&a, home.cloud(), intervals(HOUR, HOUR));

        eventually("the first step", || events.steps() == 1);

        b.sync(&*home.cloud()).unwrap();
        assert_eq!(ids(&b), [id]);
        assert!(matches!(events.last(), Some(Status::Synced { at }) if at > 0));
        // Sending what is local changes no Document.
        assert_eq!(events.library_changed.load(Relaxed), 0);
    }

    #[test]
    fn local_changes_in_a_burst_are_sent_in_one_step_after_the_debounce_interval() {
        let home = Home::new();
        let a = home.device("a");
        let (sync_loop, events) = start(
            &a,
            home.cloud(),
            intervals(Duration::from_millis(300), HOUR),
        );
        eventually("the first step", || events.steps() == 1);

        // Each change restarts the interval: 5 changes over 200 ms.
        for _ in 0..5 {
            sync_loop.local_change();
            sleep(Duration::from_millis(40));
        }
        assert_eq!(events.steps(), 1, "no step before the interval is over");

        eventually("the step after the burst", || events.steps() == 2);
        sleep(Duration::from_millis(500));
        assert_eq!(events.steps(), 2, "one step for the whole burst");
    }

    #[test]
    fn foreground_syncs_at_once() {
        let home = Home::new();
        let (a, b) = (home.device("a"), home.device("b"));
        let (sync_loop, events) = start(&a, home.cloud(), intervals(HOUR, HOUR));
        eventually("the first step", || events.steps() == 1);
        let id = home.import(&b, b"on b");
        b.sync(&*home.cloud()).unwrap();

        sync_loop.foreground();

        eventually("the other Device's Import", || ids(&a) == [id.clone()]);
    }

    #[test]
    fn polling_picks_up_another_devices_import() {
        let home = Home::new();
        let (a, b) = (home.device("a"), home.device("b"));
        let (_loop, events) = start(&a, home.cloud(), intervals(HOUR, 10 * MS));
        eventually("the first step", || events.steps() == 1);

        let id = home.import(&b, b"on b");
        b.sync(&*home.cloud()).unwrap();

        eventually("the other Device's Import", || ids(&a) == [id.clone()]);
        assert!(events.library_changed.load(Relaxed) >= 1);
    }

    #[test]
    fn background_flushes_pending_changes_and_then_idles() {
        let home = Home::new();
        let (a, b) = (home.device("a"), home.device("b"));
        let (sync_loop, events) = start(&a, home.cloud(), intervals(HOUR, 10 * MS));
        eventually("the first step", || events.steps() >= 1);
        let id = home.import(&a, b"on a");
        sync_loop.local_change();

        sync_loop.background();

        eventually("the flush", || {
            b.sync(&*home.cloud()).unwrap();
            ids(&b) == [id.clone()]
        });
        // Idle: no steps, and another Device's Import isn't picked up.
        sleep(50 * MS);
        let steps = events.steps();
        let other = home.import(&b, b"on b");
        b.sync(&*home.cloud()).unwrap();
        sleep(100 * MS);
        assert_eq!(events.steps(), steps);
        assert!(!ids(&a).contains(&other));

        sync_loop.foreground();

        eventually("syncing again", || ids(&a).contains(&other));
    }

    /// A storage that can be down.
    struct Flaky {
        inner: Arc<DirStorage>,
        down: AtomicBool,
    }

    impl Flaky {
        fn up(&self) -> io::Result<()> {
            if self.down.load(Relaxed) {
                Err(io::Error::from(io::ErrorKind::ConnectionRefused))
            } else {
                Ok(())
            }
        }
    }

    impl Storage for Flaky {
        fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
            self.up()?;
            self.inner.put(name, data)
        }
        fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
            self.up()?;
            self.inner.get(name)
        }
        fn list(&self, dir: &str) -> io::Result<Vec<Blob>> {
            self.up()?;
            self.inner.list(dir)
        }
        fn delete(&self, name: &str) -> io::Result<()> {
            self.up()?;
            self.inner.delete(name)
        }
    }

    #[test]
    fn a_failing_step_is_offline_and_the_next_one_retries() {
        let home = Home::new();
        let (a, b) = (home.device("a"), home.device("b"));
        let id = home.import(&a, b"on a");
        let flaky = Arc::new(Flaky {
            inner: home.cloud(),
            down: AtomicBool::new(true),
        });
        let (_loop, events) = start(&a, flaky.clone(), intervals(HOUR, 10 * MS));
        eventually("being offline", || events.last() == Some(Status::Offline));

        flaky.down.store(false, Relaxed);

        eventually("being synced", || {
            matches!(events.last(), Some(Status::Synced { .. }))
        });
        b.sync(&*home.cloud()).unwrap();
        assert_eq!(ids(&b), [id]);
    }

    /// A storage whose Files upload slowly, counting the chunks taken.
    struct Slow {
        inner: Arc<DirStorage>,
        chunks: AtomicUsize,
    }

    impl Storage for Slow {
        fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
            if !name.starts_with("v1/files/") {
                return self.inner.put(name, data);
            }
            let mut all = Vec::new();
            let mut chunk = [0; 64 * 1024];
            loop {
                let n = data.read(&mut chunk)?;
                if n == 0 {
                    return self.inner.put(name, &mut all.as_slice());
                }
                all.extend_from_slice(&chunk[..n]);
                self.chunks.fetch_add(1, Relaxed);
                sleep(5 * MS);
            }
        }
        fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
            self.inner.get(name)
        }
        fn list(&self, dir: &str) -> io::Result<Vec<Blob>> {
            self.inner.list(dir)
        }
        fn delete(&self, name: &str) -> io::Result<()> {
            self.inner.delete(name)
        }
    }

    #[test]
    fn dropping_the_loop_cancels_a_running_transfer_and_stops_syncing() {
        let home = Home::new();
        let a = home.device("a");
        let id = home.import(&a, &vec![7; 64 * 1024 * 100]);
        let slow = Arc::new(Slow {
            inner: home.cloud(),
            chunks: AtomicUsize::new(0),
        });
        let (sync_loop, events) = start(&a, slow.clone(), intervals(HOUR, 10 * MS));
        eventually("the upload to start", || slow.chunks.load(Relaxed) > 0);

        let started = Instant::now();
        drop(sync_loop);

        assert!(started.elapsed() < Duration::from_millis(300));
        assert!(slow.chunks.load(Relaxed) < 100);
        let steps = events.statuses.lock().unwrap().len();
        sleep(50 * MS);
        assert_eq!(events.statuses.lock().unwrap().len(), steps);
        // The cancelled upload left no File behind.
        let uploaded = home.cloud().list("v1/files").unwrap();
        assert!(uploaded.iter().all(|blob| blob.name != id));
    }
}
