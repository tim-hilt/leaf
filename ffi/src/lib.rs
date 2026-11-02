//! Foreign-language interface of the Leaf core, exported via UniFFI.
//!
//! This crate is the only place that knows about FFI: it adapts
//! `leaf-core` types to UniFFI-compatible ones and connects the Library to
//! its Sync loop, so every write is sent without the client asking. Keep
//! domain logic in `leaf-core` so it stays testable without bindings.

use leaf_core::details::{Format, Size};
use leaf_core::epub::{self, ContentsEntry};
use leaf_core::google_drive::GoogleDriveStorage;
use leaf_core::library::Document as CoreDocument;
use leaf_core::library::{ImportError, ImportResult};
use leaf_core::listing::{self, Sort, SortKey};
use leaf_core::markup::{Anchor, EpubPosition, Highlight, Markup, PageNote, PageRects, Rect, Rgb};
use leaf_core::onedrive::OneDriveStorage;
use leaf_core::preferences::{HighlightColor, HighlightColors};
use leaf_core::progress::{Place, ReadingProgress};
use leaf_core::search::{self, Query, WordMatch};
use leaf_core::storage::{ConnectError, DirStorage, RefreshTokenCallback, Storage};
use leaf_core::sync_loop::{self, Status, SyncLoop};
use leaf_core::webdav::WebDavStorage;
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

uniffi::setup_scaffolding!();

/// Version of the linked core. Clients use it to verify at runtime that
/// they talk to the core they were built against.
#[uniffi::export]
pub fn core_version() -> String {
    leaf_core::VERSION.to_owned()
}

/// The error crossing the FFI: the system's message for what failed, or, for
/// an Import, why the EPUB isn't one Leaf reads.
#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum LibraryError {
    Failed(String),
    InvalidEpub,
    DrmProtectedEpub,
    FixedLayoutEpub,
    UnsupportedFormat,
}

impl std::fmt::Display for LibraryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Failed(message) => f.write_str(message),
            Self::InvalidEpub => epub::Error::Invalid.fmt(f),
            Self::DrmProtectedEpub => epub::Error::DrmProtected.fmt(f),
            Self::FixedLayoutEpub => epub::Error::FixedLayout.fmt(f),
            Self::UnsupportedFormat => ImportError::UnsupportedFormat.fmt(f),
        }
    }
}

impl From<std::io::Error> for LibraryError {
    fn from(e: std::io::Error) -> Self {
        Self::Failed(e.to_string())
    }
}

impl From<ImportError> for LibraryError {
    fn from(e: ImportError) -> Self {
        match e {
            ImportError::Io(e) => e.into(),
            ImportError::Epub(epub::Error::Invalid) => Self::InvalidEpub,
            ImportError::Epub(epub::Error::DrmProtected) => Self::DrmProtectedEpub,
            ImportError::Epub(epub::Error::FixedLayout) => Self::FixedLayoutEpub,
            ImportError::UnsupportedFormat => Self::UnsupportedFormat,
        }
    }
}

/// The Format the File at `path` would be Imported as; none if it is neither a
/// PDF nor an EPUB, which Import refuses.
#[uniffi::export]
pub fn format_of_file(path: String) -> Result<Option<Format>, LibraryError> {
    Ok(leaf_core::library::format_of(path.as_ref())?)
}

// The core's types cross the FFI as remote types: declared here, defined (and
// documented) once in `leaf-core`, which stays free of FFI concerns.

#[uniffi::remote(Enum)]
pub enum Place {
    Pdf { page_index: u32, x: f64, y: f64 },
    Epub { spine_index: u32, offset: u64 },
}

#[uniffi::remote(Record)]
pub struct ContentsEntry {
    pub title: String,
    pub place: Option<Place>,
    pub sections: Vec<ContentsEntry>,
}

#[uniffi::remote(Record)]
pub struct ReadingProgress {
    pub place: Place,
    pub last_read: u64,
}

#[uniffi::remote(Record)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[uniffi::remote(Record)]
pub struct PageRects {
    pub page_index: u32,
    pub rects: Vec<Rect>,
}

#[uniffi::remote(Record)]
pub struct EpubPosition {
    pub spine_index: u32,
    pub offset: u64,
}

#[uniffi::remote(Enum)]
pub enum Anchor {
    Pdf(Vec<PageRects>),
    Epub {
        start: EpubPosition,
        end: EpubPosition,
    },
}

#[uniffi::remote(Record)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[uniffi::remote(Record)]
pub struct HighlightColor {
    pub id: String,
    pub rgb: Rgb,
    pub is_custom: bool,
}

#[uniffi::remote(Record)]
pub struct HighlightColors {
    pub colors: Vec<HighlightColor>,
    pub default_color: HighlightColor,
}

#[uniffi::remote(Record)]
pub struct Highlight {
    pub id: String,
    pub anchor: Anchor,
    pub quoted_text: String,
    pub color: Rgb,
    pub created: u64,
    pub note: Option<String>,
}

#[uniffi::remote(Record)]
pub struct PageNote {
    pub id: String,
    pub place: Place,
    pub created: u64,
    pub text: String,
}

#[uniffi::remote(Record)]
pub struct Markup {
    pub highlights: Vec<Highlight>,
    pub page_notes: Vec<PageNote>,
}

#[uniffi::remote(Enum)]
pub enum Format {
    Pdf,
    Epub,
}

#[uniffi::remote(Enum)]
pub enum SortKey {
    DateImported,
    Title,
    RecentlyRead,
}

#[uniffi::remote(Record)]
pub struct Sort {
    pub key: SortKey,
    pub reversed: bool,
}

#[uniffi::remote(Enum)]
pub enum Status {
    Syncing,
    Synced { at: u64 },
    Offline,
    AccessLost,
    Full,
    UpdateNeeded,
}

#[uniffi::remote(Error)]
pub enum ConnectError {
    Cancelled,
    AccessDenied,
    ICloudDriveUnavailable,
    WrongFolder,
    UnsupportedAccount,
    WrongCredentials,
    Unreachable,
    NotHttps,
    NotWebDav,
}

/// A Document in the Library, see `leaf_core::library::Document`. Author
/// and page count are none until `Library::set_details` gives them; an
/// EPUB's come with it, and its page count is always none.
#[derive(uniffi::Record)]
pub struct Document {
    pub id: String,
    pub path: String,
    pub format: Format,
    /// Date Imported, in milliseconds since the Unix epoch.
    pub imported: u64,
    pub progress: Option<ReadingProgress>,
    pub title: String,
    pub author: Option<String>,
    pub page_count: Option<u32>,
    pub percent_read: Option<u8>,
}

impl From<CoreDocument> for Document {
    fn from(d: CoreDocument) -> Self {
        Self {
            title: d.title(),
            percent_read: d.percent_read(),
            format: d.format(),
            id: d.id,
            path: d.path.to_string_lossy().into_owned(),
            imported: d.imported,
            progress: d.progress,
            author: d.details.as_ref().and_then(|x| x.author.clone()),
            page_count: d.details.and_then(|x| match x.size {
                Size::Pages(pages) => Some(pages),
                Size::Characters(_) => None,
            }),
        }
    }
}

#[uniffi::remote(Enum)]
pub enum WordMatch {
    Contains,
    StartsWith,
    EndsWith,
    FullWord,
}

/// What Document Search looks for, see `leaf_core::search::Query`.
#[uniffi::remote(Record)]
pub struct Query {
    pub text: String,
    pub case_sensitive: bool,
    pub word_match: WordMatch,
}

/// A match of Document Search, see `leaf_core::search::Match`: its range in the
/// searched text, in UTF-16 units, and its excerpt.
#[derive(uniffi::Record)]
pub struct SearchMatch {
    pub start: u64,
    pub end: u64,
    pub excerpt: SearchExcerpt,
}

/// The text around a match, see `leaf_core::search::Excerpt`.
#[derive(uniffi::Record)]
pub struct SearchExcerpt {
    pub text: String,
    /// The match in `text`, in UTF-16 units.
    pub matched_start: u64,
    pub matched_end: u64,
}

impl From<search::Match> for SearchMatch {
    fn from(m: search::Match) -> Self {
        Self {
            start: m.range.start as u64,
            end: m.range.end as u64,
            excerpt: SearchExcerpt {
                text: m.excerpt.text,
                matched_start: m.excerpt.matched.start as u64,
                matched_end: m.excerpt.matched.end as u64,
            },
        }
    }
}

/// The matches of `query` in `text`, the text of a PDF page: the same matching
/// as `EpubBook.search`, with positions in UTF-16 units as PDFKit counts them.
#[uniffi::export]
pub fn search_text(query: Query, text: String) -> Vec<SearchMatch> {
    let units: Vec<u16> = text.encode_utf16().collect();
    query.find(&units).into_iter().map(Into::into).collect()
}

/// A file of an EPUB, see `leaf_core::epub::Resource`.
#[derive(uniffi::Record)]
pub struct EpubResource {
    pub bytes: Vec<u8>,
    pub media_type: String,
}

/// An EPUB opened for reading, see `leaf_core::epub::Epub`. Clients keep it
/// open while the Reader shows the book, instead of opening it per file.
#[derive(uniffi::Object)]
pub struct EpubBook(epub::Epub);

#[uniffi::export]
impl EpubBook {
    /// The paths of the spine items, in reading order.
    pub fn spine(&self) -> Vec<String> {
        self.0.spine().to_vec()
    }

    /// The text of the spine item at `index`, which positions count into
    /// (ADR-0022); none beyond the spine.
    pub fn text(&self, index: u32) -> Option<String> {
        self.0.text(index as usize)
    }

    /// The length of each spine item's text in UTF-16 units, in spine order:
    /// the counts positions are measured in (ADR-0022), 0 for an unreadable item.
    /// Known from the Import, so asking for them parses no spine item.
    pub fn text_lengths(&self) -> Vec<u64> {
        self.0.characters()
    }

    /// The Table of Contents: Chapters with their nested Sections.
    pub fn contents(&self) -> Vec<ContentsEntry> {
        self.0.contents()
    }

    /// Where a link to `fragment` in the file at `path` points; none if `path`
    /// isn't a spine item.
    pub fn locate(&self, path: String, fragment: Option<String>) -> Option<Place> {
        self.0.locate(&path, fragment.as_deref())
    }

    /// Where the passage `quoted_text` of a Highlight from `start` to `end` is
    /// now: there if the text still matches, else where the text occurs nearest;
    /// none if it occurs nowhere.
    pub fn relocate(
        &self,
        start: EpubPosition,
        end: EpubPosition,
        quoted_text: String,
    ) -> Option<Anchor> {
        let (start, end) = self.0.relocate(start, end, &quoted_text)?;
        Some(Anchor::Epub { start, end })
    }

    /// The matches of `query` in the text of the spine item at `index` (ADR-0022),
    /// with their excerpts; none beyond the spine. Items not read before are not kept.
    pub fn search(&self, index: u32, query: Query) -> Vec<SearchMatch> {
        self.0
            .search(index as usize, &query)
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// The file at `path` (a spine item or what it uses), if the EPUB has it.
    pub fn resource(&self, path: String) -> Option<EpubResource> {
        let resource = self.0.resource(&path)?;
        Some(EpubResource {
            bytes: resource.bytes,
            media_type: resource.media_type,
        })
    }
}

/// The Library's Documents in the order of a `Sort`, ready for Library Search,
/// see `leaf_core::listing::Listing`.
#[derive(uniffi::Object)]
pub struct Listing(listing::Listing);

#[uniffi::export]
impl Listing {
    /// The Documents, newest Import first. `matching` gives positions in them.
    pub fn documents(&self) -> Vec<Document> {
        self.0.documents().iter().cloned().map(Into::into).collect()
    }

    /// Positions in `documents` of the Documents matching `search`, in order.
    pub fn matching(&self, search: &str) -> Vec<u32> {
        self.0
            .matching(search)
            .into_iter()
            .map(|i| i as u32)
            .collect()
    }
}

// `Document` is hand-made (computed Title and percent read): the core's
// crosses as that.
uniffi::custom_type!(CoreDocument, Document, {
    remote,
    lower: |d| d.into(),
    try_lift: |_document| Err(uniffi::deps::anyhow::anyhow!("Documents only go to the client")),
});

#[uniffi::remote(Enum)]
pub enum ImportResult {
    Imported(CoreDocument),
    AlreadyImported(CoreDocument),
}

/// Receives the progress of an Import. Implemented by the client and called
/// from the thread that runs the Import, not the main thread.
#[uniffi::export(with_foreign)]
pub trait ImportProgress: Send + Sync {
    /// `copied` bytes of the File's `total` are processed.
    fn report(&self, copied: u64, total: u64);
}

/// Receives what the Sync loop does. Implemented by the client and called from
/// the loop's thread, not the main thread.
#[uniffi::export(with_foreign)]
pub trait SyncObserver: Send + Sync {
    fn status_changed(&self, status: Status);
    /// The Documents (Reading Progress included) or the Highlight Colors
    /// changed: read them again.
    fn library_changed(&self);
    /// The Markup of Document `id` changed: read it again.
    fn markup_changed(&self, id: String);
    /// Files are transferring: `done` Documents of `total`, from `0` to `total`.
    /// A Sync that fails stops short; its next `status_changed` ends it.
    fn transfer_progress(&self, done: u64, total: u64);
}

/// Asks the client to have the system download a file of iCloud Drive that is
/// not on the Device yet. Implemented by the client and called from the Sync
/// loop's thread.
#[uniffi::export(with_foreign)]
pub trait DownloadRequester: Send + Sync {
    fn request_download(&self, path: String);
}

/// Receives the refresh tokens that a Cloud Provider behind OAuth rotates.
/// The client keeps the latest (in the Keychain) and resumes with it. Called
/// from the Sync loop's thread, or from a thread that connects.
#[uniffi::export(with_foreign)]
pub trait RefreshTokenObserver: Send + Sync {
    fn new_refresh_token(&self, token: String);
}

/// Adapts the client's observer of refresh tokens to the core's.
struct RefreshTokens(Arc<dyn RefreshTokenObserver>);

impl RefreshTokenCallback for RefreshTokens {
    fn new_refresh_token(&self, token: &str) {
        self.0.new_refresh_token(token.to_owned());
    }
}

/// A Cloud Provider behind OAuth. Its storage, endpoints and errors are in the
/// core; the client only signs in and keeps the refresh token.
#[derive(uniffi::Enum, Clone, Copy)]
pub enum OAuthProvider {
    /// The `Leaf` folder in My Drive.
    GoogleDrive,
    /// `Apps/Leaf`, personal accounts only.
    OneDrive,
}

impl OAuthProvider {
    /// Its storage for the user who owns `refresh_token`, a token of the public
    /// OAuth client `client_id`, with the user's account. Contacts the provider.
    fn connect(
        self,
        client_id: &str,
        refresh_token: &str,
        tokens: Arc<dyn RefreshTokenObserver>,
    ) -> Result<(Arc<dyn Storage>, String), ConnectError> {
        let tokens = Arc::new(RefreshTokens(tokens));
        let connected = match self {
            Self::GoogleDrive => GoogleDriveStorage::connect(client_id, refresh_token, tokens)
                .map(|(storage, account)| (Arc::new(storage) as Arc<dyn Storage>, account)),
            Self::OneDrive => OneDriveStorage::connect(client_id, refresh_token, tokens)
                .map(|(storage, account)| (Arc::new(storage) as Arc<dyn Storage>, account)),
        };
        connected.map_err(|error| ConnectError::of_cloud(&error))
    }

    /// Like `connect`, without contacting anyone.
    fn resume(
        self,
        client_id: &str,
        refresh_token: &str,
        tokens: Arc<dyn RefreshTokenObserver>,
    ) -> Arc<dyn Storage> {
        let tokens = Arc::new(RefreshTokens(tokens));
        match self {
            Self::GoogleDrive => {
                Arc::new(GoogleDriveStorage::resume(client_id, refresh_token, tokens))
            }
            Self::OneDrive => Arc::new(OneDriveStorage::resume(client_id, refresh_token, tokens)),
        }
    }
}

/// A Cloud Provider to Connect to, see `Library::connect`: what it takes to
/// reach it, and where its storage lives in the core.
#[derive(uniffi::Enum)]
pub enum Cloud {
    /// The WebDAV server at `url`, reached as `username` with `password`.
    /// Connecting checks them and creates the `Leaf` folder if needed.
    WebDav {
        url: String,
        username: String,
        password: String,
    },
    /// The `Leaf` folder in the granted iCloud Drive, at `folder`, created if
    /// missing. Files other Devices wrote that iCloud hasn't downloaded yet are
    /// not there for Sync until `downloads` has fetched them. `AccessDenied` if
    /// `folder` can't be opened.
    ICloudDrive {
        folder: String,
        downloads: Arc<dyn DownloadRequester>,
    },
    /// Google Drive or OneDrive (`provider`) of the user who owns
    /// `refresh_token`, a token of the public OAuth client `client_id`. Every
    /// token the provider rotates goes to `tokens`.
    OAuth {
        provider: OAuthProvider,
        client_id: String,
        refresh_token: String,
        tokens: Arc<dyn RefreshTokenObserver>,
    },
    /// The directory `path`, as if it were a cloud, for tests.
    Directory { path: String },
}

impl Cloud {
    /// Its storage and its account, empty if the provider doesn't tell it.
    /// Contacts the provider, if the Cloud has one.
    fn connect(self) -> Result<(Arc<dyn Storage>, String), ConnectError> {
        match self {
            Self::WebDav {
                url,
                username,
                password,
            } => {
                let storage = WebDavStorage::connect(&url, &username, &password)?;
                Ok((Arc::new(storage), String::new()))
            }
            Self::OAuth {
                provider,
                client_id,
                refresh_token,
                tokens,
            } => provider.connect(&client_id, &refresh_token, tokens),
            cloud => Ok((cloud.resume()?, String::new())),
        }
    }

    /// Its storage, without contacting anyone.
    fn resume(self) -> Result<Arc<dyn Storage>, ConnectError> {
        match self {
            Self::WebDav {
                url,
                username,
                password,
            } => Ok(Arc::new(WebDavStorage::resume(&url, &username, &password)?)),
            Self::ICloudDrive { folder, downloads } => {
                let storage = DirStorage::open(folder)
                    .map_err(|_| ConnectError::AccessDenied)?
                    .on_download_needed(move |path| {
                        downloads.request_download(path.to_string_lossy().into_owned());
                    });
                Ok(Arc::new(storage))
            }
            Self::OAuth {
                provider,
                client_id,
                refresh_token,
                tokens,
            } => Ok(provider.resume(&client_id, &refresh_token, tokens)),
            Self::Directory { path } => {
                let storage = DirStorage::open(path).map_err(|_| ConnectError::AccessDenied)?;
                Ok(Arc::new(storage))
            }
        }
    }
}

/// When Sync steps run, see `leaf_core::sync_loop::Intervals`.
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
    fn status(&self, status: Status) {
        self.0.status_changed(status);
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

/// The Library folder, see `leaf_core::library::Library`, and its
/// Connection to a Cloud Provider, if any.
#[derive(uniffi::Object)]
pub struct Library {
    core: Arc<leaf_core::library::Library>,
    sync: Mutex<Option<SyncLoop>>,
    /// Whether the Device has a network, see `set_online`. Changed only while
    /// `sync` is locked, so a starting loop can't miss a change.
    online: AtomicBool,
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
        let mut sync = self.sync();
        *sync = Some(SyncLoop::start(
            self.core.clone(),
            storage,
            Arc::new(Observer(observer)),
            intervals.into(),
            self.online.load(Relaxed),
        ));
    }

    fn sync(&self) -> std::sync::MutexGuard<'_, Option<SyncLoop>> {
        self.sync.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The outcome of a write to the Library; tells the Sync loop, if any, to
    /// send it soon. Every write goes through here, so clients never have to.
    fn written<T, E>(&self, outcome: Result<T, E>) -> Result<T, LibraryError>
    where
        LibraryError: From<E>,
    {
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
            core: Arc::new(leaf_core::library::Library::open(root)?),
            sync: Mutex::new(None),
            online: AtomicBool::new(true),
        }))
    }

    /// Connects to `cloud` and starts syncing with it: the first step merges
    /// the Library with the cloud's. Blocks while it talks to the provider.
    /// Returns the user's account, empty if the provider doesn't tell it or the
    /// Cloud has none. Fails with `UnsupportedAccount` for a OneDrive work or
    /// school account. Replaces any earlier Connection.
    pub fn connect(
        &self,
        cloud: Cloud,
        observer: Arc<dyn SyncObserver>,
        intervals: SyncIntervals,
    ) -> Result<String, ConnectError> {
        let (storage, account) = cloud.connect()?;
        self.start_sync(storage, observer, intervals);
        Ok(account)
    }

    /// Like `connect` for a Cloud connected before, e.g. at the last launch:
    /// contacts nobody, so it works offline.
    pub fn resume(
        &self,
        cloud: Cloud,
        observer: Arc<dyn SyncObserver>,
        intervals: SyncIntervals,
    ) -> Result<(), ConnectError> {
        let storage = cloud.resume()?;
        self.start_sync(storage, observer, intervals);
        Ok(())
    }

    /// Reconnects the running Connection to `cloud`, after its status became
    /// `AccessLost`: checks it like `connect` and, if it is right, resumes
    /// syncing at once. Blocks while it talks to the provider. Returns the
    /// account. Does nothing if not Connected.
    pub fn reconnect(&self, cloud: Cloud) -> Result<String, ConnectError> {
        let (storage, account) = cloud.connect()?;
        if let Some(sync) = &*self.sync() {
            sync.use_storage(storage);
        }
        Ok(account)
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

    /// Whether the Device has a network. Without one nothing syncs; when it
    /// comes back, Sync runs at once. Online until told otherwise.
    pub fn set_online(&self, online: bool) {
        let sync = self.sync();
        self.online.store(online, Relaxed);
        if let Some(sync) = &*sync {
            sync.set_online(online);
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
        self.written(result)
    }

    pub fn remove(&self, id: String) -> Result<(), LibraryError> {
        self.written(self.core.remove(&id))
    }

    /// EPUB `id`, opened for reading; none for a PDF, or an EPUB that can't be read.
    pub fn open_epub(&self, id: String) -> Result<Option<Arc<EpubBook>>, LibraryError> {
        Ok(self
            .core
            .open_epub(&id)?
            .map(|epub| Arc::new(EpubBook(epub))))
    }

    /// The bytes of the Cover image of EPUB `id`, if it has one.
    pub fn epub_cover(&self, id: String) -> Result<Option<Vec<u8>>, LibraryError> {
        Ok(self.core.epub_cover(&id)?)
    }

    pub fn save_progress(&self, id: String, progress: ReadingProgress) -> Result<(), LibraryError> {
        self.progress_written(self.core.save_progress(&id, &progress))
    }

    pub fn markup(&self, id: String) -> Result<Markup, LibraryError> {
        Ok(self.core.markup(&id)?)
    }

    pub fn add_highlight(
        &self,
        id: String,
        anchor: Anchor,
        quoted_text: String,
        color: Rgb,
        created: u64,
    ) -> Result<Option<Highlight>, LibraryError> {
        let highlight = self
            .core
            .add_highlight(&id, anchor, &quoted_text, color, created);
        self.written(highlight)
    }

    pub fn set_highlight_color(
        &self,
        id: String,
        highlight: String,
        color: Rgb,
    ) -> Result<(), LibraryError> {
        self.written(self.core.set_highlight_color(&id, &highlight, color))
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
        place: Place,
        created: u64,
    ) -> Result<Option<PageNote>, LibraryError> {
        let note = self.core.add_page_note(&id, place, created);
        self.written(note)
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

    pub fn highlight_colors(&self) -> HighlightColors {
        self.core.highlight_colors()
    }

    pub fn set_default_highlight_color(&self, id: String) -> Result<(), LibraryError> {
        self.written(self.core.set_default_highlight_color(&id))
    }

    pub fn add_custom_color(&self, rgb: Rgb, added: u64) -> Result<HighlightColor, LibraryError> {
        self.written(self.core.add_custom_color(rgb, added))
    }

    pub fn remove_custom_color(&self, id: String) -> Result<(), LibraryError> {
        self.written(self.core.remove_custom_color(&id))
    }

    /// The Documents in the order of `sort`, ready for Library Search.
    pub fn listing(&self, sort: Sort) -> Result<Arc<Listing>, LibraryError> {
        Ok(Arc::new(Listing(self.core.listing(sort)?)))
    }

    pub fn document(&self, id: String) -> Result<Option<Document>, LibraryError> {
        Ok(self.core.document(&id)?.map(Into::into))
    }

    /// Keeps what the client read from the File of Document `id` on this
    /// Device, see `leaf_core::library::Library::set_details`. Not synced.
    pub fn set_details(
        &self,
        id: String,
        title: Option<String>,
        author: Option<String>,
        page_count: u32,
    ) -> Result<(), LibraryError> {
        let details = leaf_core::details::Details {
            title,
            author,
            size: Size::Pages(page_count),
        };
        Ok(self.core.set_details(&id, &details)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering::Relaxed};
    use std::time::Instant;

    #[test]
    fn search_text_counts_ranges_in_utf16_units() {
        let query = Query {
            text: "apple".to_owned(),
            case_sensitive: false,
            word_match: WordMatch::Contains,
        };
        let found = search_text(query, "😀 Apple".to_owned());
        assert_eq!((found[0].start, found[0].end), (3, 8));
    }

    /// Counts the Sync steps that ended.
    #[derive(Default)]
    struct Steps(AtomicUsize);

    impl SyncObserver for Steps {
        fn status_changed(&self, status: Status) {
            if !matches!(status, Status::Syncing) {
                self.0.fetch_add(1, Relaxed);
            }
        }
        fn library_changed(&self) {}
        fn markup_changed(&self, _: String) {}
        fn transfer_progress(&self, _: u64, _: u64) {}
    }

    struct Requests(Mutex<Vec<String>>);

    impl DownloadRequester for Requests {
        fn request_download(&self, path: String) {
            self.0.lock().unwrap().push(path);
        }
    }

    #[test]
    fn icloud_drive_syncs_its_folder_and_asks_for_files_not_downloaded_yet() {
        let dir = std::env::temp_dir().join(format!("leaf-ffi-icloud-{}", std::process::id()));
        let folder = dir.join("Leaf");
        std::fs::create_dir_all(folder.join("v1")).unwrap();
        std::fs::write(folder.join("v1/.later.icloud"), b"placeholder").unwrap();
        let library = Library::open(dir.join("library").display().to_string()).unwrap();
        let (steps, requests) = (
            Arc::new(Steps::default()),
            Arc::new(Requests(Mutex::default())),
        );
        let hour = 3_600_000;

        library
            .connect(
                Cloud::ICloudDrive {
                    folder: folder.display().to_string(),
                    downloads: requests.clone(),
                },
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

        let asked = requests.0.lock().unwrap().clone();
        assert_eq!(asked, [folder.join("v1/later").display().to_string()]);
        library.disconnect();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_folder_that_cannot_be_created_is_access_denied() {
        let dir = std::env::temp_dir().join(format!("leaf-ffi-denied-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("Leaf"), b"a file").unwrap();
        let library = Library::open(dir.join("library").display().to_string()).unwrap();

        let result = library.connect(
            Cloud::ICloudDrive {
                folder: dir.join("Leaf").display().to_string(),
                downloads: Arc::new(Requests(Mutex::default())),
            },
            Arc::new(Steps::default()),
            SyncIntervals {
                debounce_ms: 10,
                progress_ms: 10,
                poll_ms: 10,
                idle_poll_ms: 10,
            },
        );

        assert_eq!(result.unwrap_err(), ConnectError::AccessDenied);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn resume_syncs_the_cloud_without_connecting_it_again() {
        let dir = std::env::temp_dir().join(format!("leaf-ffi-resume-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let library = Library::open(dir.join("library").display().to_string()).unwrap();
        let steps = Arc::new(Steps::default());
        let hour = 3_600_000;

        library
            .resume(
                Cloud::Directory {
                    path: dir.join("cloud").display().to_string(),
                },
                steps.clone(),
                SyncIntervals {
                    debounce_ms: 10,
                    progress_ms: 10,
                    poll_ms: hour,
                    idle_poll_ms: hour,
                },
            )
            .unwrap();
        another_step(&steps, 0, "resuming");

        library.disconnect();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn resuming_an_icloud_folder_that_is_gone_is_access_denied_and_starts_no_sync() {
        let dir = std::env::temp_dir().join(format!("leaf-ffi-gone-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("Leaf"), b"a file").unwrap();
        let library = Library::open(dir.join("library").display().to_string()).unwrap();

        let result = library.resume(
            Cloud::ICloudDrive {
                folder: dir.join("Leaf").display().to_string(),
                downloads: Arc::new(Requests(Mutex::default())),
            },
            Arc::new(Steps::default()),
            SyncIntervals {
                debounce_ms: 10,
                progress_ms: 10,
                poll_ms: 10,
                idle_poll_ms: 10,
            },
        );

        assert_eq!(result.unwrap_err(), ConnectError::AccessDenied);
        assert!(library.sync().is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn reconnecting_without_a_connection_checks_the_cloud_and_starts_no_sync() {
        let dir = std::env::temp_dir().join(format!("leaf-ffi-reconnect-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let library = Library::open(dir.join("library").display().to_string()).unwrap();

        let account = library
            .reconnect(Cloud::Directory {
                path: dir.join("cloud").display().to_string(),
            })
            .unwrap();

        assert_eq!(account, "");
        assert!(library.sync().is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_library_lists_its_documents_by_id_in_order_and_searches_them() {
        let dir = std::env::temp_dir().join(format!("leaf-ffi-listing-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let library = Library::open(dir.join("library").display().to_string()).unwrap();
        let mut ids = vec![];
        let books = [
            ("Zebra", None),
            ("apple 10", Some("Émile Zola")),
            ("apple 2", None),
        ];
        for (n, (title, author)) in books.into_iter().enumerate() {
            let source = dir.join(format!("{n}.pdf"));
            std::fs::write(&source, format!("%PDF-{n}")).unwrap();
            let path = source.display().to_string();
            let Ok(ImportResult::Imported(document)) = library.import(path, Arc::new(NoProgress))
            else {
                panic!("import")
            };
            let (title, author) = (Some(title.to_owned()), author.map(str::to_owned));
            library
                .set_details(document.id.clone(), title, author, 1)
                .unwrap();
            ids.push(document.id);
            std::thread::sleep(Duration::from_millis(2));
        }
        let listed = |key, reversed, search: &str| {
            let listing = library.listing(Sort { key, reversed }).unwrap();
            let documents = listing.documents();
            let matched = listing.matching(search);
            matched
                .into_iter()
                .map(|i| documents[i as usize].id.clone())
                .collect::<Vec<_>>()
        };
        let [zebra, ten, two] = [&ids[0], &ids[1], &ids[2]].map(String::as_str);
        assert_eq!(listed(SortKey::DateImported, false, ""), [two, ten, zebra]);
        assert_eq!(listed(SortKey::Title, false, ""), [two, ten, zebra]);
        assert_eq!(listed(SortKey::Title, true, ""), [zebra, ten, two]);
        assert_eq!(listed(SortKey::Title, false, "emile"), [ten]);
        assert_eq!(listed(SortKey::Title, false, "2.PDF"), [two]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The Library's Documents, in the order the Gallery lists them by default.
    fn listed_documents(library: &Library) -> Vec<Document> {
        let sort = Sort {
            key: SortKey::DateImported,
            reversed: false,
        };
        library.listing(sort).unwrap().documents()
    }

    struct NoProgress;

    impl ImportProgress for NoProgress {
        fn report(&self, _: u64, _: u64) {}
    }

    #[test]
    fn import_refuses_a_file_that_is_neither_a_pdf_nor_an_epub() {
        let dir = std::env::temp_dir().join(format!("leaf-ffi-format-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("notes.txt");
        std::fs::write(&source, b"hello").unwrap();
        let path = source.display().to_string();
        let library = Library::open(dir.join("library").display().to_string()).unwrap();

        assert_eq!(format_of_file(path.clone()).unwrap(), None);
        let refused = library.import(path, Arc::new(NoProgress));
        assert!(matches!(refused, Err(LibraryError::UnsupportedFormat)));
        assert_eq!(listed_documents(&library).len(), 0);
        std::fs::remove_dir_all(dir).unwrap();
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
            "leaf-ffi-{}-{}",
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
            .connect(
                Cloud::Directory {
                    path: dir.join("cloud").display().to_string(),
                },
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
            let id = listed_documents(&library).first().map(|d| d.id.clone());
            write(&library, id.unwrap_or_default());
            another_step(&steps, before, name);
        };
        write("import", &|l, _| {
            l.import(source.display().to_string(), Arc::new(NoProgress))
                .unwrap();
        });
        write("save_progress", &|l, id| {
            let progress = ReadingProgress {
                place: Place::Pdf {
                    page_index: 1,
                    x: 0.0,
                    y: 0.0,
                },
                last_read: 1,
            };
            l.save_progress(id, progress).unwrap();
        });
        write("add_page_note", &|l, id| {
            let place = Place::Pdf {
                page_index: 0,
                x: 1.0,
                y: 2.0,
            };
            l.add_page_note(id, place, 1).unwrap();
        });
        write("add_custom_color", &|l, _| {
            l.add_custom_color(Rgb { r: 1, g: 2, b: 3 }, 1).unwrap();
        });
        write("remove", &|l, id| l.remove(id).unwrap());

        library.disconnect();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
