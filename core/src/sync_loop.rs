//! The Sync loop: one background thread that runs `Library::sync` steps
//! against a storage while a Cloud Provider is Connected (ADR-0009).
//!
//! A step runs
//!
//! - once `Intervals::debounce` after the last local change,
//! - once `Intervals::progress` after the first unsent Reading Progress,
//! - at once on start and `foreground`,
//! - every `Intervals::poll` while in the foreground, backing off towards
//!   `Intervals::idle_poll` while polls find nothing new,
//! - once more at `background`, to flush; then the loop idles.
//!
//! Polls report no `Status::Syncing`, so an idle loop stays quiet.
//!
//! A step that is blocked (`Status::is_blocked`) pauses the loop for good: it
//! sends no request until `SyncLoop::use_storage` brings new credentials, and
//! none at all after a newer schema version, which only an update of the app
//! resolves.
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
    /// The storage rejected the credentials. Blocked, until `use_storage`.
    WrongPassword,
    /// Another Device stored a newer schema version than this app knows.
    /// Blocked: nothing is written until the app is updated.
    UpdateNeeded,
}

impl Status {
    /// Whether the user has to act for Sync to go on. Being offline is not
    /// blocked.
    pub fn is_blocked(self) -> bool {
        matches!(self, Self::WrongPassword | Self::UpdateNeeded)
    }
}

/// Told what happens in the loop, from its thread: never while a lock of the
/// loop is held, never after the `SyncLoop` is dropped.
pub trait Observer: Send + Sync {
    fn status(&self, status: Status);
    /// A step changed the Documents (Reading Progress included) or the
    /// Highlight Colors: they are worth listing again. Called before
    /// `markup_changed` and the step's final `status`.
    fn library_changed(&self);
    /// A step changed the Markup of Document `id`: it is worth reading again.
    fn markup_changed(&self, id: &str);
    /// A step transfers Files: `done` Documents' Files of `total` are
    /// uploaded or downloaded. First `(0, total)`, ending at `(total, total)`;
    /// not called for a step that transfers none. A step that fails stops
    /// short, so the client clears it at the next `status`.
    fn transfer(&self, done: usize, total: usize);
}

/// When steps run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Intervals {
    /// How long after the last local change a step runs.
    pub debounce: Duration,
    /// How long after the first Reading Progress no step has sent a step
    /// runs: saved often while reading, it is sent less eagerly.
    pub progress: Duration,
    /// How long after a step the next one runs, in the foreground.
    pub poll: Duration,
    /// The longest `poll` grows to, doubling after each poll that finds
    /// nothing new.
    pub idle_poll: Duration,
}

impl Default for Intervals {
    fn default() -> Self {
        Self {
            debounce: Duration::from_secs(3),
            progress: Duration::from_secs(60),
            poll: Duration::from_secs(10),
            idle_poll: Duration::from_secs(300),
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
    /// The storage steps use, which `use_storage` replaces.
    storage: Arc<Cancellable>,
    /// How often the storage was replaced.
    storage_changes: u32,
    /// The last step was blocked: no more steps until the storage is replaced.
    blocked: bool,
    foreground: bool,
    /// A step is wanted at once: at start, `foreground` and `background`.
    immediate: bool,
    /// The latest local change no step has sent yet.
    changed: Option<Instant>,
    /// The first Reading Progress no step has sent yet.
    progress: Option<Instant>,
    /// When the next step is due on its own; only in the foreground.
    poll: Option<Instant>,
    /// How long after a step the next poll runs; grows while polls find
    /// nothing.
    poll_interval: Duration,
}

impl State {
    /// When the next step is due; `None` for never.
    fn due(&self, now: Instant, intervals: &Intervals) -> Option<Instant> {
        if self.blocked {
            return None;
        }
        if self.immediate {
            return Some(now);
        }
        if !self.foreground {
            return None;
        }
        [
            self.changed.map(|at| at + intervals.debounce),
            self.progress.map(|at| at + intervals.progress),
            self.poll,
        ]
        .into_iter()
        .flatten()
        .min()
    }

    /// Whether a step due now is a mere poll: nothing local to send, no
    /// reason to sync at once.
    fn polls(&self) -> bool {
        !self.immediate && self.changed.is_none() && self.progress.is_none()
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
                storage: Arc::new(Cancellable {
                    inner: storage,
                    cancelled: cancelled.clone(),
                }),
                storage_changes: 0,
                blocked: false,
                foreground: true,
                immediate: true,
                changed: None,
                progress: None,
                poll: None,
                poll_interval: intervals.poll,
            }),
            wake: Condvar::new(),
            cancelled,
        });
        let thread = {
            let shared = shared.clone();
            thread::spawn(move || shared.run(&library, &*observer, &intervals))
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

    /// Reading Progress was saved: a step sends it after the progress interval,
    /// or with the next other change, or at `background`. Later saves don't
    /// restart the interval, so reading on doesn't hold it back.
    pub fn progress_change(&self) {
        self.update(|state| {
            state.progress.get_or_insert_with(Instant::now);
        });
    }

    /// Syncs with `storage` from now on: new credentials, after Sync was
    /// blocked by a rejected password. A step runs at once.
    pub fn use_storage(&self, storage: Arc<dyn Storage>) {
        let cancelled = self.shared.cancelled.clone();
        self.update(|state| {
            state.storage = Arc::new(Cancellable {
                inner: storage,
                cancelled,
            });
            state.storage_changes += 1;
            state.blocked = false;
            state.immediate = true;
        });
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

    fn run(&self, library: &Library, observer: &dyn Observer, intervals: &Intervals) {
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
                    let polls = state.polls();
                    state.immediate = false;
                    state.changed = None;
                    state.progress = None;
                    let (storage, storage_changes) = (state.storage.clone(), state.storage_changes);
                    drop(state);
                    let step = self.step(library, &*storage, observer, polls);
                    state = self.lock();
                    // New credentials since the step began aren't blocked yet.
                    state.blocked = step.is_some_and(|(status, _)| status.is_blocked())
                        && state.storage_changes == storage_changes;
                    state.poll_interval = match step {
                        Some((_, false)) if polls => {
                            (state.poll_interval * 2).min(intervals.idle_poll)
                        }
                        _ => intervals.poll,
                    };
                    state.poll = state
                        .foreground
                        .then(|| Instant::now() + state.poll_interval);
                }
            }
        }
    }

    /// Runs a step and tells how it ended and whether it brought anything
    /// new; `None` if it was cancelled. A `poll` reports no `Syncing`.
    fn step(
        &self,
        library: &Library,
        storage: &dyn Storage,
        observer: &dyn Observer,
        poll: bool,
    ) -> Option<(Status, bool)> {
        if !poll {
            observer.status(Status::Syncing);
        }
        let changes = library.sync_changes();
        let transferred = AtomicBool::new(false);
        let result = library.sync_reporting(storage, &|done, total| {
            transferred.store(true, Relaxed);
            if !self.is_cancelled() {
                observer.transfer(done, total);
            }
        });
        if self.is_cancelled() {
            return None;
        }
        let mut news = transferred.into_inner();
        if library.sync_changes() != changes {
            news = true;
            observer.library_changed();
        }
        for id in library.take_markup_changes() {
            news = true;
            observer.markup_changed(&id);
        }
        let status = match result {
            Ok(()) => Status::Synced { at: now() },
            Err(e) => match e.kind() {
                io::ErrorKind::PermissionDenied => Status::WrongPassword,
                io::ErrorKind::Unsupported => Status::UpdateNeeded,
                _ => Status::Offline,
            },
        };
        observer.status(status);
        Some((status, news))
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

    /// Without a longer interval for Reading Progress, and without backoff.
    fn intervals(debounce: Duration, poll: Duration) -> Intervals {
        Intervals {
            debounce,
            progress: debounce,
            poll,
            idle_poll: poll,
        }
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
        markup_changed: Mutex<Vec<String>>,
        transfers: Mutex<Vec<(usize, usize)>>,
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
        fn markup_changed(&self, id: &str) {
            self.markup_changed.lock().unwrap().push(id.to_owned());
        }
        fn transfer(&self, done: usize, total: usize) {
            self.transfers.lock().unwrap().push((done, total));
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
    fn file_transfers_are_reported_as_documents_done_of_total_and_state_only_steps_report_none() {
        let home = Home::new();
        let (a, b) = (home.device("a"), home.device("b"));
        let id = home.import(&a, b"on a");
        home.import(&a, b"on a, too");
        let (a_loop, a_events) = start(&a, home.cloud(), intervals(10 * MS, HOUR));
        eventually("the upload", || a_events.steps() == 1);
        let (_b_loop, b_events) = start(&b, home.cloud(), intervals(HOUR, HOUR));
        eventually("the download", || b_events.steps() == 1);
        let expected = [(0, 2), (1, 2), (2, 2)];
        assert_eq!(*a_events.transfers.lock().unwrap(), expected);
        assert_eq!(*b_events.transfers.lock().unwrap(), expected);

        a.add_highlight(
            &id,
            vec![],
            "quoted",
            crate::markup::Rgb { r: 1, g: 2, b: 3 },
            1,
        )
        .unwrap()
        .unwrap();
        a_loop.local_change();
        eventually("the state-only step", || a_events.steps() == 2);
        assert_eq!(a_events.transfers.lock().unwrap().len(), 3);
    }

    #[test]
    fn markup_and_progress_from_another_device_are_reported_and_sent_after_a_local_change() {
        let home = Home::new();
        let (a, b) = (home.device("a"), home.device("b"));
        let id = home.import(&a, b"on a");
        a.sync(&*home.cloud()).unwrap();
        b.sync(&*home.cloud()).unwrap();
        let (_a_loop, a_events) = start(&a, home.cloud(), intervals(HOUR, 20 * MS));
        let (b_loop, b_events) = start(&b, home.cloud(), intervals(10 * MS, HOUR));
        eventually("the first steps", || {
            a_events.steps() >= 1 && b_events.steps() >= 1
        });

        let color = crate::markup::Rgb { r: 1, g: 2, b: 3 };
        b.add_highlight(&id, vec![], "quoted", color, 1)
            .unwrap()
            .unwrap();
        b.save_progress(&id, &crate::progress::ReadingProgress::pdf(2, 0.0, 0.0, 7))
            .unwrap();
        b_loop.local_change();

        // A may poll between B sending the Markup and the Reading Progress.
        eventually("the reports on A", || {
            !a_events.markup_changed.lock().unwrap().is_empty()
                && a.documents().unwrap()[0].progress.is_some()
                && a_events.library_changed.load(Relaxed) >= 1
        });
        assert_eq!(
            *a_events.markup_changed.lock().unwrap(),
            std::slice::from_ref(&id)
        );
        assert_eq!(a.documents().unwrap()[0].progress.unwrap().last_read, 7);
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
    fn reading_progress_is_sent_after_the_progress_interval_however_often_it_is_saved() {
        let home = Home::new();
        let a = home.device("a");
        let progress = Duration::from_millis(300);
        let (sync_loop, events) = start(
            &a,
            home.cloud(),
            Intervals {
                progress,
                ..intervals(MS, HOUR)
            },
        );
        eventually("the first step", || events.steps() == 1);
        let saved = Instant::now();

        // Saved every 40 ms while reading on.
        while events.steps() == 1 {
            sync_loop.progress_change();
            assert!(saved.elapsed() < 5 * progress, "never sent");
            sleep(40 * MS);
        }

        assert!(saved.elapsed() >= progress, "sent too early");
    }

    #[test]
    fn polls_back_off_while_they_find_nothing_and_report_no_syncing() {
        let home = Home::new();
        let a = home.device("a");
        let (_loop, events) = start(
            &a,
            home.cloud(),
            Intervals {
                idle_poll: 80 * MS,
                ..intervals(HOUR, 10 * MS)
            },
        );

        // Without backing off, 30 polls.
        sleep(300 * MS);

        let steps = events.steps();
        assert!((2..10).contains(&steps), "{steps} steps");
        let statuses = events.statuses.lock().unwrap();
        let syncing = statuses.iter().filter(|s| **s == Status::Syncing).count();
        assert_eq!(syncing, 1, "only the first step");
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

        eventually("the other Device's Import", || {
            ids(&a) == std::slice::from_ref(&id)
        });
    }

    #[test]
    fn polling_picks_up_another_devices_import() {
        let home = Home::new();
        let (a, b) = (home.device("a"), home.device("b"));
        let (_loop, events) = start(&a, home.cloud(), intervals(HOUR, 10 * MS));
        eventually("the first step", || events.steps() == 1);

        let id = home.import(&b, b"on b");
        b.sync(&*home.cloud()).unwrap();

        eventually("the other Device's Import", || {
            ids(&a) == std::slice::from_ref(&id)
        });
        eventually("the Library change report", || {
            events.library_changed.load(Relaxed) >= 1
        });
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
            if !name.starts_with("v1/file.") {
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
        let uploaded = home.cloud().list("v1").unwrap();
        assert!(
            uploaded
                .iter()
                .all(|blob| blob.name != format!("file.{id}"))
        );
    }

    /// A storage that counts its requests and fails each with `error`.
    struct Failing {
        error: io::ErrorKind,
        requests: AtomicUsize,
    }

    impl Failing {
        fn new(error: io::ErrorKind) -> Arc<Self> {
            Arc::new(Self {
                error,
                requests: AtomicUsize::new(0),
            })
        }

        fn fail<T>(&self) -> io::Result<T> {
            self.requests.fetch_add(1, Relaxed);
            Err(io::Error::from(self.error))
        }
    }

    impl Storage for Failing {
        fn put(&self, _: &str, _: &mut dyn Read) -> io::Result<()> {
            self.fail()
        }
        fn get(&self, _: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
            self.fail()
        }
        fn list(&self, _: &str) -> io::Result<Vec<Blob>> {
            self.fail()
        }
        fn delete(&self, _: &str) -> io::Result<()> {
            self.fail()
        }
    }

    #[test]
    fn a_rejected_password_blocks_the_loop_until_new_credentials_come() {
        let home = Home::new();
        let (a, b) = (home.device("a"), home.device("b"));
        let id = home.import(&a, b"on a");
        let rejecting = Failing::new(io::ErrorKind::PermissionDenied);
        let (sync_loop, events) = start(&a, rejecting.clone(), intervals(MS, MS));
        eventually("being blocked", || {
            events.last() == Some(Status::WrongPassword)
        });
        assert!(Status::WrongPassword.is_blocked());

        // Neither polling, a local change nor the app's lifecycle sends more.
        let requests = rejecting.requests.load(Relaxed);
        sync_loop.local_change();
        sync_loop.foreground();
        sync_loop.background();
        sleep(100 * MS);
        assert_eq!(rejecting.requests.load(Relaxed), requests);
        assert_eq!(events.last(), Some(Status::WrongPassword));

        sync_loop.use_storage(home.cloud());

        eventually("being synced", || {
            matches!(events.last(), Some(Status::Synced { .. }))
        });
        b.sync(&*home.cloud()).unwrap();
        assert_eq!(ids(&b), [id]);
    }

    #[test]
    fn new_credentials_that_are_rejected_block_the_loop_again() {
        let home = Home::new();
        let a = home.device("a");
        let (sync_loop, events) = start(
            &a,
            Failing::new(io::ErrorKind::PermissionDenied),
            intervals(HOUR, 5 * MS),
        );
        eventually("being blocked", || events.steps() == 1);

        let still_wrong = Failing::new(io::ErrorKind::PermissionDenied);
        sync_loop.use_storage(still_wrong.clone());

        eventually("the new storage to be tried", || events.steps() == 2);
        sleep(50 * MS);
        assert_eq!(still_wrong.requests.load(Relaxed), 1);
        assert_eq!(events.last(), Some(Status::WrongPassword));
    }

    #[test]
    fn a_newer_schema_version_blocks_the_loop_with_update_needed() {
        let home = Home::new();
        let a = home.device("a");
        let newer = Failing::new(io::ErrorKind::Unsupported);
        let (sync_loop, events) = start(&a, newer.clone(), intervals(MS, MS));
        eventually("being blocked", || {
            events.last() == Some(Status::UpdateNeeded)
        });
        assert!(Status::UpdateNeeded.is_blocked());
        assert!(!Status::Offline.is_blocked());

        let requests = newer.requests.load(Relaxed);
        sync_loop.foreground();
        sleep(100 * MS);
        assert_eq!(newer.requests.load(Relaxed), requests);
    }
}
