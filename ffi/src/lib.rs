//! Foreign-language interface of the LeafPDF core, exported via UniFFI.
//!
//! This crate is the only place that knows about FFI: it adapts
//! `leafpdf-core` types to UniFFI-compatible ones and nothing else. Keep
//! domain logic in `leafpdf-core` so it stays testable without bindings.

use std::sync::Arc;

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

/// A Document in the Library: its ID, the path of its stored File and its
/// Reading Progress, if it was ever opened.
#[derive(uniffi::Record)]
pub struct Document {
    pub id: String,
    pub path: String,
    pub progress: Option<ReadingProgress>,
}

impl From<leafpdf_core::library::Document> for Document {
    fn from(d: leafpdf_core::library::Document) -> Self {
        Self {
            id: d.id,
            path: d.path.to_string_lossy().into_owned(),
            progress: d.progress.map(Into::into),
        }
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

/// The Library folder, see `leafpdf_core::library::Library`.
#[derive(uniffi::Object)]
pub struct Library(leafpdf_core::library::Library);

#[uniffi::export]
impl Library {
    #[uniffi::constructor]
    pub fn open(root: String) -> Result<Arc<Self>, LibraryError> {
        Ok(Arc::new(Self(leafpdf_core::library::Library::open(root)?)))
    }

    pub fn import(
        &self,
        source: String,
        progress: Arc<dyn ImportProgress>,
    ) -> Result<ImportResult, LibraryError> {
        let result = self.0.import(source.as_ref(), |copied, total| {
            progress.report(copied, total)
        })?;
        Ok(result.into())
    }

    pub fn remove(&self, id: String) -> Result<(), LibraryError> {
        Ok(self.0.remove(&id)?)
    }

    pub fn save_progress(&self, id: String, progress: ReadingProgress) -> Result<(), LibraryError> {
        Ok(self.0.save_progress(&id, &progress.into())?)
    }

    pub fn markup(&self, id: String) -> Result<Markup, LibraryError> {
        Ok(self.0.markup(&id)?.into())
    }

    pub fn add_highlight(
        &self,
        id: String,
        anchor: Vec<PageRects>,
        quoted_text: String,
        color: Rgb,
        created: u64,
    ) -> Result<Highlight, LibraryError> {
        let anchor = anchor.into_iter().map(Into::into).collect();
        let highlight = self
            .0
            .add_highlight(&id, anchor, &quoted_text, color.into(), created)?;
        Ok(highlight.into())
    }

    pub fn set_highlight_color(
        &self,
        id: String,
        highlight: String,
        color: Rgb,
    ) -> Result<(), LibraryError> {
        Ok(self.0.set_highlight_color(&id, &highlight, color.into())?)
    }

    pub fn set_highlight_note(
        &self,
        id: String,
        highlight: String,
        note: String,
    ) -> Result<(), LibraryError> {
        Ok(self.0.set_highlight_note(&id, &highlight, &note)?)
    }

    pub fn remove_highlight(&self, id: String, highlight: String) -> Result<(), LibraryError> {
        Ok(self.0.remove_highlight(&id, &highlight)?)
    }

    pub fn add_page_note(
        &self,
        id: String,
        page_index: u32,
        x: f64,
        y: f64,
        created: u64,
    ) -> Result<PageNote, LibraryError> {
        Ok(self.0.add_page_note(&id, page_index, x, y, created)?.into())
    }

    pub fn set_page_note_text(
        &self,
        id: String,
        note: String,
        text: String,
    ) -> Result<(), LibraryError> {
        Ok(self.0.set_page_note_text(&id, &note, &text)?)
    }

    pub fn remove_page_note(&self, id: String, note: String) -> Result<(), LibraryError> {
        Ok(self.0.remove_page_note(&id, &note)?)
    }

    pub fn highlight_colors(&self) -> Vec<HighlightColor> {
        self.0
            .highlight_colors()
            .into_iter()
            .map(Into::into)
            .collect()
    }

    pub fn default_highlight_color(&self) -> HighlightColor {
        self.0.default_highlight_color().into()
    }

    pub fn set_default_highlight_color(&self, id: String) -> Result<(), LibraryError> {
        Ok(self.0.set_default_highlight_color(&id)?)
    }

    pub fn add_custom_color(&self, rgb: Rgb, added: u64) -> Result<HighlightColor, LibraryError> {
        Ok(self.0.add_custom_color(rgb.into(), added)?.into())
    }

    pub fn remove_custom_color(&self, id: String) -> Result<(), LibraryError> {
        Ok(self.0.remove_custom_color(&id)?)
    }

    pub fn documents(&self) -> Result<Vec<Document>, LibraryError> {
        Ok(self.0.documents()?.into_iter().map(Into::into).collect())
    }
}
