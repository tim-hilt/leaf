//! Foreign-language interface of the LeafPDF core, exported via UniFFI.
//!
//! This crate is the only place that knows about FFI: it adapts
//! `leafpdf-core` types to UniFFI-compatible ones and connects the Library to
//! its Sync loop, so every write is sent without the client asking. Keep
//! domain logic in `leafpdf-core` so it stays testable without bindings.

use leafpdf_core::listing;
use leafpdf_core::storage::{DirStorage, Storage};
use leafpdf_core::sync_loop::{self, SyncLoop};
use leafpdf_core::webdav::WebDavStorage;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

uniffi::setup_scaffolding!();

/// Version of the linked core. Clients use it to verify at runtime that
/// they talk to the core they were built against.
#[uniffi::export]
pub fn core_version() -> String {
    leafpdf_core::VERSION.to_owned()
}

/// The one error crossing the FFI: the system's message for what failed.
#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum LibraryError {
    Failed(String),
}

impl std::fmt::Display for LibraryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self::Failed(message) = self;
        f.write_str(message)
    }
}

impl From<std::io::Error> for LibraryError {
    fn from(e: std::io::Error) -> Self {
        Self::Failed(e.to_string())
    }
}

/// Where the user left off, see `leafpdf_core::progress::ReadingProgress`.
/// `last_read` is milliseconds since the Unix epoch.
#[derive(uniffi::Record)]
pub struct ReadingProgress {
    pub page_index: u32,
    pub x: f64,
    pub y: f64,
    pub last_read: u64,
}

impl From<leafpdf_core::progress::ReadingProgress> for ReadingProgress {
    fn from(p: leafpdf_core::progress::ReadingProgress) -> Self {
        Self {
            page_index: p.page_index,
            x: p.x,
            y: p.y,
            last_read: p.last_read,
        }
    }
}

impl From<ReadingProgress> for leafpdf_core::progress::ReadingProgress {
    fn from(p: ReadingProgress) -> Self {
        Self {
            page_index: p.page_index,
            x: p.x,
            y: p.y,
            last_read: p.last_read,
        }
    }
}

/// A rectangle in PDF page space, see `leafpdf_core::markup::Rect`.
#[derive(uniffi::Record)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// The rectangles of a Highlight on one page, see `leafpdf_core::markup::PageRects`.
#[derive(uniffi::Record)]
pub struct PageRects {
    pub page_index: u32,
    pub rects: Vec<Rect>,
}

/// An sRGB color, 8 bits per channel.
#[derive(uniffi::Record)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

/// See `leafpdf_core::preferences::HighlightColor`.
#[derive(uniffi::Record)]
pub struct HighlightColor {
    pub id: String,
    pub rgb: Rgb,
    pub is_custom: bool,
}

impl From<leafpdf_core::preferences::HighlightColor> for HighlightColor {
    fn from(c: leafpdf_core::preferences::HighlightColor) -> Self {
        Self {
            id: c.id,
            rgb: c.rgb.into(),
            is_custom: c.is_custom,
        }
    }
}

/// See `leafpdf_core::markup::Highlight`. `created` is milliseconds since the
/// Unix epoch.
#[derive(uniffi::Record)]
pub struct Highlight {
    pub id: String,
    pub anchor: Vec<PageRects>,
    pub quoted_text: String,
    pub color: Rgb,
    pub created: u64,
    pub note: Option<String>,
}

/// See `leafpdf_core::markup::PageNote`. `created` is milliseconds since the
/// Unix epoch.
#[derive(uniffi::Record)]
pub struct PageNote {
    pub id: String,
    pub page_index: u32,
    pub x: f64,
    pub y: f64,
    pub created: u64,
    pub text: String,
}

/// See `leafpdf_core::markup::Markup`.
#[derive(uniffi::Record)]
pub struct Markup {
    pub highlights: Vec<Highlight>,
    pub page_notes: Vec<PageNote>,
}

impl From<leafpdf_core::markup::Rect> for Rect {
    fn from(r: leafpdf_core::markup::Rect) -> Self {
        Self {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        }
    }
}

impl From<Rect> for leafpdf_core::markup::Rect {
    fn from(r: Rect) -> Self {
        Self {
            x: r.x,
            y: r.y,
            width: r.width,
            height: r.height,
        }
    }
}

impl From<leafpdf_core::markup::PageRects> for PageRects {
    fn from(p: leafpdf_core::markup::PageRects) -> Self {
        Self {
            page_index: p.page_index,
            rects: p.rects.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<PageRects> for leafpdf_core::markup::PageRects {
    fn from(p: PageRects) -> Self {
        Self {
            page_index: p.page_index,
            rects: p.rects.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<leafpdf_core::markup::Rgb> for Rgb {
    fn from(c: leafpdf_core::markup::Rgb) -> Self {
        Self {
            r: c.r,
            g: c.g,
            b: c.b,
        }
    }
}

impl From<Rgb> for leafpdf_core::markup::Rgb {
    fn from(c: Rgb) -> Self {
        Self {
            r: c.r,
            g: c.g,
            b: c.b,
        }
    }
}

impl From<leafpdf_core::markup::Highlight> for Highlight {
    fn from(h: leafpdf_core::markup::Highlight) -> Self {
        Self {
            id: h.id,
            anchor: h.anchor.into_iter().map(Into::into).collect(),
            quoted_text: h.quoted_text,
            color: h.color.into(),
            created: h.created,
            note: h.note,
        }
    }
}

impl From<leafpdf_core::markup::PageNote> for PageNote {
    fn from(n: leafpdf_core::markup::PageNote) -> Self {
        Self {
            id: n.id,
            page_index: n.page_index,
            x: n.x,
            y: n.y,
            created: n.created,
            text: n.text,
        }
    }
}

impl From<leafpdf_core::markup::Markup> for Markup {
    fn from(m: leafpdf_core::markup::Markup) -> Self {
        Self {
            highlights: m.highlights.into_iter().map(Into::into).collect(),
            page_notes: m.page_notes.into_iter().map(Into::into).collect(),
        }
    }
}

/// A Document in the Library, see `leafpdf_core::library::Document`. Author
/// and page count are none until `Library::set_details` gives them.
#[derive(uniffi::Record)]
pub struct Document {
    pub id: String,
    pub path: String,
    /// Date Imported, in milliseconds since the Unix epoch.
    pub imported: u64,
    pub progress: Option<ReadingProgress>,
    pub title: String,
    pub author: Option<String>,
    pub page_count: Option<u32>,
    pub percent_read: Option<u8>,
}

impl From<leafpdf_core::library::Document> for Document {
    fn from(d: leafpdf_core::library::Document) -> Self {
        Self {
            title: d.title(),
            percent_read: d.percent_read(),
            id: d.id,
            path: d.path.to_string_lossy().into_owned(),
            imported: d.imported,
            progress: d.progress.map(Into::into),
            author: d.details.as_ref().and_then(|x| x.author.clone()),
            page_count: d.details.map(|x| x.page_count),
        }
    }
}

/// What Documents are ordered by, see `leafpdf_core::listing::SortKey`.
#[derive(uniffi::Enum)]
pub enum SortKey {
    DateImported,
    Title,
    RecentlyRead,
}

/// How a Gallery orders its Documents, see `leafpdf_core::listing::Sort`.
#[derive(uniffi::Record)]
pub struct Sort {
    pub key: SortKey,
    pub reversed: bool,
}

impl From<Sort> for listing::Sort {
    fn from(s: Sort) -> Self {
        Self {
            key: match s.key {
                SortKey::DateImported => listing::SortKey::DateImported,
                SortKey::Title => listing::SortKey::Title,
                SortKey::RecentlyRead => listing::SortKey::RecentlyRead,
            },
            reversed: s.reversed,
        }
    }
}

impl From<&Document> for listing::Item {
    fn from(d: &Document) -> Self {
        let path = std::path::Path::new(&d.path);
        Self {
            title: d.title.clone(),
            file_name: path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned(),
            author: d.author.clone(),
            imported: d.imported,
            last_read: d.progress.as_ref().map(|p| p.last_read),
        }
    }
}

/// Documents in the order of a `Sort`, ready for Library Search, see
/// `leafpdf_core::listing::Listing`.
#[derive(uniffi::Object)]
pub struct Listing(listing::Listing);

#[uniffi::export]
impl Listing {
    #[uniffi::constructor]
    pub fn new(documents: &[Document], sort: Sort) -> Arc<Self> {
        let items: Vec<_> = documents.iter().map(Into::into).collect();
        Arc::new(Self(listing::Listing::new(&items, sort.into())))
    }

    /// The positions in `documents` of those matching `search`, in order.
    pub fn matching(&self, search: &str) -> Vec<u32> {
        let found = self.0.matching(search).into_iter();
        found
            .map(|i| u32::try_from(i).unwrap_or(u32::MAX))
            .collect()
    }
}

/// What an Import did, see `leafpdf_core::library::ImportResult`.
#[derive(uniffi::Enum)]
pub enum ImportResult {
    Imported(Document),
    AlreadyImported(Document),
}

impl From<leafpdf_core::library::ImportResult> for ImportResult {
    fn from(r: leafpdf_core::library::ImportResult) -> Self {
        use leafpdf_core::library::ImportResult as Core;
        match r {
            Core::Imported(d) => Self::Imported(d.into()),
            Core::AlreadyImported(d) => Self::AlreadyImported(d.into()),
        }
    }
}

/// Receives the progress of an Import. Implemented by the client and called
/// from the thread that runs the Import, not the main thread.
#[uniffi::export(with_foreign)]
pub trait ImportProgress: Send + Sync {
    /// `copied` bytes of the File's `total` are processed.
    fn report(&self, copied: u64, total: u64);
}

/// Why connecting to a WebDAV server failed, see
/// `leafpdf_core::webdav::ConnectError`.
#[derive(Debug, uniffi::Error)]
pub enum ConnectError {
    WrongCredentials,
    Unreachable,
    NotHttps,
    NotWebDav,
}

impl From<leafpdf_core::webdav::ConnectError> for ConnectError {
    fn from(e: leafpdf_core::webdav::ConnectError) -> Self {
        use leafpdf_core::webdav::ConnectError as Core;
        match e {
            Core::WrongCredentials => Self::WrongCredentials,
            Core::Unreachable => Self::Unreachable,
            Core::NotHttps => Self::NotHttps,
            Core::NotWebDav => Self::NotWebDav,
        }
    }
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

/// Where Sync stands, see `leafpdf_core::sync_loop::Status`. `at` is
/// milliseconds since the Unix epoch.
#[derive(uniffi::Enum)]
pub enum SyncStatus {
    Syncing,
    Synced {
        at: u64,
    },
    Offline,
    /// Blocked: the server rejected the credentials, see `update_webdav_credentials`.
    WrongPassword,
    /// Blocked: another Device synced a newer version than this app knows.
    UpdateNeeded,
}

/// Receives what the Sync loop does. Implemented by the client and called from
/// the loop's thread, not the main thread.
#[uniffi::export(with_foreign)]
pub trait SyncObserver: Send + Sync {
    fn status_changed(&self, status: SyncStatus);
    /// The Documents (Reading Progress included) or the Highlight Colors
    /// changed: read them again.
    fn library_changed(&self);
    /// The Markup of Document `id` changed: read it again.
    fn markup_changed(&self, id: String);
    /// Files are transferring: `done` Documents of `total`, from `0` to `total`.
    /// A Sync that fails stops short; its next `status_changed` ends it.
    fn transfer_progress(&self, done: u64, total: u64);
}

/// When Sync steps run, see `leafpdf_core::sync_loop::Intervals`.
#[derive(uniffi::Record)]
pub struct SyncIntervals {
    pub debounce_ms: u64,
    pub progress_ms: u64,
    pub poll_ms: u64,
    pub idle_poll_ms: u64,
}

impl From<SyncIntervals> for sync_loop::Intervals {
    fn from(i: SyncIntervals) -> Self {
        Self {
            debounce: Duration::from_millis(i.debounce_ms),
            progress: Duration::from_millis(i.progress_ms),
            poll: Duration::from_millis(i.poll_ms),
            idle_poll: Duration::from_millis(i.idle_poll_ms),
        }
    }
}

/// Adapts the client's observer to the core's.
struct Observer(Arc<dyn SyncObserver>);

impl sync_loop::Observer for Observer {
    fn status(&self, status: sync_loop::Status) {
        use sync_loop::Status as Core;
        self.0.status_changed(match status {
            Core::Syncing => SyncStatus::Syncing,
            Core::Synced { at } => SyncStatus::Synced { at },
            Core::Offline => SyncStatus::Offline,
            Core::WrongPassword => SyncStatus::WrongPassword,
            Core::UpdateNeeded => SyncStatus::UpdateNeeded,
        });
    }

    fn library_changed(&self) {
        self.0.library_changed();
    }

    fn markup_changed(&self, id: &str) {
        self.0.markup_changed(id.to_owned());
    }

    fn transfer(&self, done: usize, total: usize) {
        self.0.transfer_progress(done as u64, total as u64);
    }
}

/// The Library folder, see `leafpdf_core::library::Library`, and its
/// Connection to a Cloud Provider, if any.
#[derive(uniffi::Object)]
pub struct Library {
    core: Arc<leafpdf_core::library::Library>,
    sync: Mutex<Option<SyncLoop>>,
}

impl Library {
    /// Syncs with `storage` from now on, instead of with any earlier one.
    fn start_sync(
        &self,
        storage: Arc<dyn Storage>,
        observer: Arc<dyn SyncObserver>,
        intervals: SyncIntervals,
    ) {
        self.disconnect();
        let started = SyncLoop::start(
            self.core.clone(),
            storage,
            Arc::new(Observer(observer)),
            intervals.into(),
        );
        *self.sync() = Some(started);
    }

    fn sync(&self) -> std::sync::MutexGuard<'_, Option<SyncLoop>> {
        self.sync.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The outcome of a write to the Library; tells the Sync loop, if any, to
    /// send it soon. Every write goes through here, so clients never have to.
    fn written<T>(&self, outcome: std::io::Result<T>) -> Result<T, LibraryError> {
        if let Some(sync) = &*self.sync() {
            sync.local_change();
        }
        Ok(outcome?)
    }

    /// `written`, for Reading Progress, which Syncs less eagerly.
    fn progress_written(&self, outcome: std::io::Result<()>) -> Result<(), LibraryError> {
        if let Some(sync) = &*self.sync() {
            sync.progress_change();
        }
        Ok(outcome?)
    }
}

#[uniffi::export]
impl Library {
    #[uniffi::constructor]
    pub fn open(root: String) -> Result<Arc<Self>, LibraryError> {
        Ok(Arc::new(Self {
            core: Arc::new(leafpdf_core::library::Library::open(root)?),
            sync: Mutex::new(None),
        }))
    }

    /// Connects to the WebDAV server at `url` and starts syncing with it: the
    /// first step merges the Library with the cloud's. Checks the details first
    /// and creates the `LeafPDF` folder if needed; blocks while it talks to the
    /// server. Replaces any earlier Connection.
    pub fn connect_webdav(
        &self,
        url: String,
        username: String,
        password: String,
        observer: Arc<dyn SyncObserver>,
        intervals: SyncIntervals,
    ) -> Result<(), ConnectError> {
        let storage = WebDavStorage::connect(&url, &username, &password)?;
        self.start_sync(Arc::new(storage), observer, intervals);
        Ok(())
    }

    /// Like `connect_webdav` for a server connected before, e.g. at the last
    /// launch: contacts nobody, so it works offline.
    pub fn resume_webdav(
        &self,
        url: String,
        username: String,
        password: String,
        observer: Arc<dyn SyncObserver>,
        intervals: SyncIntervals,
    ) -> Result<(), ConnectError> {
        let storage = WebDavStorage::resume(&url, &username, &password)?;
        self.start_sync(Arc::new(storage), observer, intervals);
        Ok(())
    }

    /// Gives the running Connection new credentials, after its status became
    /// `WrongPassword`: checks them like `connect_webdav` and, if they are
    /// right, resumes syncing at once. Blocks while it talks to the server.
    /// Does nothing if not Connected.
    pub fn update_webdav_credentials(
        &self,
        url: String,
        username: String,
        password: String,
    ) -> Result<(), ConnectError> {
        let storage = WebDavStorage::connect(&url, &username, &password)?;
        if let Some(sync) = &*self.sync() {
            sync.use_storage(Arc::new(storage));
        }
        Ok(())
    }

    /// Connects to the directory `path` as if it were a cloud, for tests.
    pub fn connect_directory(
        &self,
        path: String,
        observer: Arc<dyn SyncObserver>,
        intervals: SyncIntervals,
    ) -> Result<(), LibraryError> {
        let storage = DirStorage::open(path)?;
        self.start_sync(Arc::new(storage), observer, intervals);
        Ok(())
    }

    /// Stops syncing and cancels running transfers. Keeps everything in the
    /// Library and leaves the cloud untouched. Blocks until the transfers have
    /// stopped.
    pub fn disconnect(&self) {
        let stopped = self.sync().take();
        drop(stopped);
    }

    /// The app is in the foreground: syncs at once, then regularly.
    pub fn foreground(&self) {
        if let Some(sync) = &*self.sync() {
            sync.foreground();
        }
    }

    /// The app goes to the background: syncs once more, then idles.
    pub fn background(&self) {
        if let Some(sync) = &*self.sync() {
            sync.background();
        }
    }

    pub fn import(
        &self,
        source: String,
        progress: Arc<dyn ImportProgress>,
    ) -> Result<ImportResult, LibraryError> {
        let result = self.core.import(source.as_ref(), |copied, total| {
            progress.report(copied, total)
        });
        Ok(self.written(result)?.into())
    }

    pub fn remove(&self, id: String) -> Result<(), LibraryError> {
        self.written(self.core.remove(&id))
    }

    pub fn save_progress(&self, id: String, progress: ReadingProgress) -> Result<(), LibraryError> {
        self.progress_written(self.core.save_progress(&id, &progress.into()))
    }

    pub fn markup(&self, id: String) -> Result<Markup, LibraryError> {
        Ok(self.core.markup(&id)?.into())
    }

    pub fn add_highlight(
        &self,
        id: String,
        anchor: Vec<PageRects>,
        quoted_text: String,
        color: Rgb,
        created: u64,
    ) -> Result<Option<Highlight>, LibraryError> {
        let anchor = anchor.into_iter().map(Into::into).collect();
        let highlight = self
            .core
            .add_highlight(&id, anchor, &quoted_text, color.into(), created);
        Ok(self.written(highlight)?.map(Into::into))
    }

    pub fn set_highlight_color(
        &self,
        id: String,
        highlight: String,
        color: Rgb,
    ) -> Result<(), LibraryError> {
        self.written(self.core.set_highlight_color(&id, &highlight, color.into()))
    }

    pub fn set_highlight_note(
        &self,
        id: String,
        highlight: String,
        note: String,
    ) -> Result<(), LibraryError> {
        self.written(self.core.set_highlight_note(&id, &highlight, &note))
    }

    pub fn remove_highlight(&self, id: String, highlight: String) -> Result<(), LibraryError> {
        self.written(self.core.remove_highlight(&id, &highlight))
    }

    pub fn add_page_note(
        &self,
        id: String,
        page_index: u32,
        x: f64,
        y: f64,
        created: u64,
    ) -> Result<Option<PageNote>, LibraryError> {
        let note = self.core.add_page_note(&id, page_index, x, y, created);
        Ok(self.written(note)?.map(Into::into))
    }

    pub fn set_page_note_text(
        &self,
        id: String,
        note: String,
        text: String,
    ) -> Result<(), LibraryError> {
        self.written(self.core.set_page_note_text(&id, &note, &text))
    }

    pub fn remove_page_note(&self, id: String, note: String) -> Result<(), LibraryError> {
        self.written(self.core.remove_page_note(&id, &note))
    }

    pub fn highlight_colors(&self) -> Vec<HighlightColor> {
        self.core
            .highlight_colors()
            .into_iter()
            .map(Into::into)
            .collect()
    }

    pub fn default_highlight_color(&self) -> HighlightColor {
        self.core.default_highlight_color().into()
    }

    pub fn set_default_highlight_color(&self, id: String) -> Result<(), LibraryError> {
        self.written(self.core.set_default_highlight_color(&id))
    }

    pub fn add_custom_color(&self, rgb: Rgb, added: u64) -> Result<HighlightColor, LibraryError> {
        Ok(self
            .written(self.core.add_custom_color(rgb.into(), added))?
            .into())
    }

    pub fn remove_custom_color(&self, id: String) -> Result<(), LibraryError> {
        self.written(self.core.remove_custom_color(&id))
    }

    pub fn documents(&self) -> Result<Vec<Document>, LibraryError> {
        Ok(self.core.documents()?.into_iter().map(Into::into).collect())
    }

    pub fn document(&self, id: String) -> Result<Option<Document>, LibraryError> {
        Ok(self.core.document(&id)?.map(Into::into))
    }

    /// Keeps what the client read from the File of Document `id` on this
    /// Device, see `leafpdf_core::library::Library::set_details`. Not synced.
    pub fn set_details(
        &self,
        id: String,
        title: Option<String>,
        author: Option<String>,
        page_count: u32,
    ) -> Result<(), LibraryError> {
        let details = leafpdf_core::details::Details {
            title,
            author,
            page_count,
        };
        Ok(self.core.set_details(&id, &details)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering::Relaxed};
    use std::time::Instant;

    /// Counts the Sync steps that ended.
    #[derive(Default)]
    struct Steps(AtomicUsize);

    impl SyncObserver for Steps {
        fn status_changed(&self, status: SyncStatus) {
            if !matches!(status, SyncStatus::Syncing) {
                self.0.fetch_add(1, Relaxed);
            }
        }
        fn library_changed(&self) {}
        fn markup_changed(&self, _: String) {}
        fn transfer_progress(&self, _: u64, _: u64) {}
    }

    struct NoProgress;

    impl ImportProgress for NoProgress {
        fn report(&self, _: u64, _: u64) {}
    }

    /// Waits up to 5 s for a step to end after the `before`th one.
    fn another_step(steps: &Steps, before: usize, after: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while steps.0.load(Relaxed) <= before {
            assert!(Instant::now() < deadline, "no Sync step after {after}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn every_write_starts_a_sync_step_without_being_told() {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "leafpdf-ffi-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("a.pdf");
        std::fs::write(&source, b"%PDF-").unwrap();
        let library = Library::open(dir.join("library").display().to_string()).unwrap();
        let steps = Arc::new(Steps::default());
        let hour = 3_600_000;
        library
            .connect_directory(
                dir.join("cloud").display().to_string(),
                steps.clone(),
                SyncIntervals {
                    debounce_ms: 10,
                    progress_ms: 10,
                    poll_ms: hour,
                    idle_poll_ms: hour,
                },
            )
            .unwrap();
        another_step(&steps, 0, "connecting");

        // Each write runs on the Library's only Document, if any.
        let write = |name: &str, write: &dyn Fn(&Library, String)| {
            let before = steps.0.load(Relaxed);
            let id = library.documents().unwrap().first().map(|d| d.id.clone());
            write(&library, id.unwrap_or_default());
            another_step(&steps, before, name);
        };
        write("import", &|l, _| {
            l.import(source.display().to_string(), Arc::new(NoProgress))
                .unwrap();
        });
        write("save_progress", &|l, id| {
            let progress = ReadingProgress {
                page_index: 1,
                x: 0.0,
                y: 0.0,
                last_read: 1,
            };
            l.save_progress(id, progress).unwrap();
        });
        write("add_page_note", &|l, id| {
            l.add_page_note(id, 0, 1.0, 2.0, 1).unwrap();
        });
        write("add_custom_color", &|l, _| {
            l.add_custom_color(Rgb { r: 1, g: 2, b: 3 }, 1).unwrap();
        });
        write("remove", &|l, id| l.remove(id).unwrap());

        library.disconnect();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
