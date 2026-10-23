//! Reading EPUBs (ADR-0021): everything but drawing them. Reflowable EPUB 2 and
//! 3 only; DRM-protected and fixed-layout ones are rejected.
//!
//! An EPUB is a zip of XML and XHTML. `Epub::open` reads its package (the
//! `.opf` file named by `META-INF/container.xml`): Title, Author, the spine
//! (the reading order of its XHTML files) and the declared Cover. Zip entries
//! are read, and inflated, one at a time, so a book is never held in memory.
//! Entries are read at an offset, so an `Epub` serves several threads at once.
//!
//! The text of a spine item, the contract with the clients' web views (ADR-0022),
//! is its XHTML body's text nodes concatenated in document order, with
//! entities resolved: XML's and HTML 4's, as web views resolve them in XHTML.
//! Its length is counted in UTF-16 code units, as
//! JavaScript counts a string.
//!
//! The Table of Contents (the EPUB 3 nav, else the EPUB 2 NCX) points into that
//! text: a link's anchor (`#id`) is the offset of the text before its element.

use crate::markup::EpubPosition;
use crate::percent::decode as percent_decode;
use crate::progress::Place;
use miniz_oxide::inflate::decompress_to_vec_with_limit;
use quick_xml::XmlVersion;
use quick_xml::events::{BytesRef, BytesStart, Event};
use quick_xml::reader::Reader;
use std::collections::HashMap;
use std::fmt;
use std::fs::File;
use std::ops::ControlFlow;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

mod entities;

/// Why a File isn't an EPUB Leaf reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// Not a zip, or not an EPUB: a required part is missing or unreadable.
    Invalid,
    /// Its content is encrypted.
    DrmProtected,
    /// Its pages have a fixed layout.
    FixedLayout,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Invalid => "This file isn't a valid EPUB",
            Self::DrmProtected => "This EPUB is DRM-protected",
            Self::FixedLayout => "Fixed-layout EPUBs aren't supported",
        })
    }
}

impl std::error::Error for Error {}

/// An opened EPUB.
pub struct Epub {
    zip: Zip,
    package: Package,
    /// The spine items read so far, by index (None: the zip can't read it).
    /// Readers ask for the same items again and again (placing Highlights), so
    /// each is inflated and parsed once.
    /// Its lock is held only to look up or insert, never while inflating or
    /// parsing, so reads on several threads don't wait for each other.
    items: Mutex<HashMap<usize, Option<Arc<Scanned>>>>,
}

/// What one `scan` of a spine item yields.
#[derive(Default)]
struct Scanned {
    /// Its text in UTF-16 code units, the unit positions count in (ADR-0022).
    text: Vec<u16>,
    /// The offset of the text before each anchor.
    anchors: HashMap<String, u64>,
}

impl Epub {
    /// Opens the EPUB at `path`.
    pub fn open(path: &Path) -> Result<Self, Error> {
        let zip = Zip::open(path).ok_or(Error::Invalid)?;
        let mimetype = zip.read("mimetype").ok_or(Error::Invalid)?;
        if mimetype.trim_ascii() != b"application/epub+zip" {
            return Err(Error::Invalid);
        }
        let container = zip.read("META-INF/container.xml").ok_or(Error::Invalid)?;
        let package_path = package_path(&container).ok_or(Error::Invalid)?;
        if let Some(encryption) = zip.read("META-INF/encryption.xml")
            && encrypts_content(&encryption)
        {
            return Err(Error::DrmProtected);
        }
        let opf = zip.read(&package_path).ok_or(Error::Invalid)?;
        let mut package = Package::parse(&opf, directory_of(&package_path))?;
        package.spine.retain(|item| zip.contains(item));
        if package.spine.is_empty() {
            return Err(Error::Invalid);
        }
        Ok(Self {
            zip,
            package,
            items: Mutex::default(),
        })
    }

    /// The title the EPUB declares, if any.
    pub fn title(&self) -> Option<&str> {
        self.package.title.as_deref()
    }

    /// The author the EPUB declares (several joined by a comma), if any.
    pub fn author(&self) -> Option<&str> {
        self.package.author.as_deref()
    }

    /// The paths in the zip of the spine items, in reading order. Each is a
    /// `resource` holding the XHTML to display.
    pub fn spine(&self) -> &[String] {
        &self.package.spine
    }

    /// The manifest item at zip path `path`: a spine item or what it uses (an
    /// image, style sheet or font). None for any other file of the zip, and for
    /// an item the zip lacks or can't read.
    pub fn resource(&self, path: &str) -> Option<Resource> {
        let media_type = self.package.media_types.get(path)?.clone();
        let bytes = self.zip.read(path)?;
        Some(Resource { bytes, media_type })
    }

    /// The bytes of the Cover image: the declared cover, else the first image
    /// of the first spine item. None if there is no image.
    pub fn cover(&self) -> Option<Vec<u8>> {
        let path = self.package.cover.clone().or_else(|| self.first_image())?;
        self.zip.read(&path)
    }

    /// The path of the first image in the first spine item that the zip has.
    fn first_image(&self) -> Option<String> {
        let item = &self.package.spine[0];
        let xhtml = self.zip.read(item)?;
        let dir = directory_of(item);
        let mut found = None;
        let _ = read_xml(&xhtml, |event| {
            let (Event::Start(tag) | Event::Empty(tag)) = event else {
                return ControlFlow::Continue(());
            };
            let source = match tag.local_name().as_ref() {
                "img" => attribute(tag, "src"),
                "image" => attribute(tag, "href"),
                _ => None,
            };
            found = source
                .map(|s| resolve(dir, &s))
                .filter(|p| self.zip.contains(p));
            if found.is_some() {
                ControlFlow::Break(())
            } else {
                ControlFlow::Continue(())
            }
        });
        found
    }

    /// The spine item at `index`, scanned once. None for an index beyond the
    /// spine, and for an item the zip can't read.
    fn item(&self, index: usize) -> Option<Arc<Scanned>> {
        if let Some(item) = self.cached().get(&index) {
            return item.clone();
        }
        let item = self.package.spine.get(index)?;
        let item = self.zip.read(item).map(|xhtml| {
            let (text, anchors) = scan(&xhtml);
            Arc::new(Scanned {
                text: text.encode_utf16().collect(),
                anchors,
            })
        });
        // Another thread may have scanned it meanwhile; keep the first result.
        self.cached().entry(index).or_insert(item).clone()
    }

    fn cached(&self) -> MutexGuard<'_, HashMap<usize, Option<Arc<Scanned>>>> {
        self.items.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The spine item at `index`; empty if the zip can't read it.
    fn item_or_empty(&self, index: usize) -> Arc<Scanned> {
        self.item(index).unwrap_or_default()
    }

    /// The text of the spine item at `index`, see the module docs: up to where
    /// it breaks if it isn't well-formed. None for an index beyond the spine,
    /// and for an item the zip can't read.
    pub fn text(&self, index: usize) -> Option<String> {
        Some(String::from_utf16_lossy(&self.item(index)?.text))
    }

    /// Where the passage `quoted` of a Highlight is, now: from `start` to `end`
    /// if the text there is `quoted`, else where `quoted` occurs nearest to
    /// `start` in the text of the whole book. Spine items' texts are joined by
    /// `\n` there and in `quoted`. None if it occurs nowhere, or `quoted` is empty.
    pub fn relocate(
        &self,
        start: EpubPosition,
        end: EpubPosition,
        quoted: &str,
    ) -> Option<(EpubPosition, EpubPosition)> {
        let quoted: Vec<u16> = quoted.encode_utf16().collect();
        if quoted.is_empty() {
            return None;
        }
        if self.passage(start, end).as_ref() == Some(&quoted) {
            return Some((start, end));
        }
        let count = self.package.spine.len();
        let first = (start.spine_index as usize).min(count - 1);
        let was = usize::try_from(start.offset)
            .unwrap_or(usize::MAX)
            .min(self.item_or_empty(first).text.len()) as isize;

        // Positions count from the start of item `first`, each item's text
        // followed by its `\n` separator. Each direction searches outward, item
        // by item, until no further item can hold a nearer occurrence. Of two
        // equally near ones the earlier wins.
        let mut best: Option<Nearest> = None;
        let search = |epub: &Self, best: &mut Option<Nearest>, index, base: isize| {
            let item = epub.item_or_empty(index);
            for offset in 0..=item.text.len() {
                if unit_at(&item.text, offset) != quoted[0] {
                    continue;
                }
                let position = base + offset as isize;
                let key = ((position - was).abs(), position);
                if best.is_none_or(|n| key < n.key) && epub.occurs_at(&quoted, index, offset) {
                    *best = Some(Nearest { key, index, offset });
                }
            }
        };
        let mut base = 0;
        for index in first..count {
            if best.is_some_and(|n| base - was >= n.key.0) {
                break;
            }
            search(self, &mut best, index, base);
            base += self.item_or_empty(index).text.len() as isize + 1;
        }
        let mut base = 0;
        for index in (0..first).rev() {
            let length = self.item_or_empty(index).text.len() as isize;
            base -= length + 1;
            if best.is_some_and(|n| was - (base + length) > n.key.0) {
                break;
            }
            search(self, &mut best, index, base);
        }

        let Nearest { index, offset, .. } = best?;
        let (mut end_index, mut end_offset) = (index, offset + quoted.len());
        while end_index + 1 < count {
            let length = self.item_or_empty(end_index).text.len() + 1;
            if end_offset < length {
                break;
            }
            end_offset -= length;
            end_index += 1;
        }
        let position = |spine_index: usize, offset: usize| EpubPosition {
            spine_index: spine_index as u32,
            offset: offset as u64,
        };
        Some((position(index, offset), position(end_index, end_offset)))
    }

    /// Whether `quoted` is what the text reads from `offset` in spine item
    /// `index` on, the spine items' texts joined by `\n`.
    fn occurs_at(&self, quoted: &[u16], mut index: usize, mut offset: usize) -> bool {
        let mut rest = quoted;
        while !rest.is_empty() {
            if index >= self.package.spine.len() {
                return false;
            }
            let item = self.item_or_empty(index);
            let (now, later) = rest.split_at((item.text.len() + 1 - offset).min(rest.len()));
            if (offset..)
                .zip(now)
                .any(|(at, &unit)| unit_at(&item.text, at) != unit)
            {
                return false;
            }
            (rest, index, offset) = (later, index + 1, 0);
        }
        true
    }

    /// The text from `start` to `end`, the spine items' texts joined by `\n`.
    /// None if they aren't in order or beyond the text.
    fn passage(&self, start: EpubPosition, end: EpubPosition) -> Option<Vec<u16>> {
        let (first, last) = (start.spine_index as usize, end.spine_index as usize);
        let mut passage = Vec::new();
        for index in first..=last {
            let item = self.item(index)?;
            let from = if index == first { start.offset } else { 0 };
            let to = if index == last {
                end.offset
            } else {
                item.text.len() as u64
            };
            let text = item
                .text
                .get(usize::try_from(from).ok()?..usize::try_from(to).ok()?)?;
            if index != first {
                passage.push(u16::from(b'\n'));
            }
            passage.extend_from_slice(text);
        }
        Some(passage)
    }

    /// The Table of Contents: Chapters with their nested Sections, in reading
    /// order. Empty if the EPUB has none. An entry whose link isn't in the
    /// spine, or that has none, has no place.
    pub fn contents(&self) -> Vec<ContentsEntry> {
        let (source, parse): (_, OutlineParser) = match (&self.package.nav, &self.package.ncx) {
            (Some(nav), _) => (nav.clone(), nav_outline),
            (None, Some(ncx)) => (ncx.clone(), ncx_outline),
            (None, None) => return Vec::new(),
        };
        let Some(xml) = self.zip.read(&source) else {
            return Vec::new();
        };
        self.resolve_outline(parse(&xml), directory_of(&source))
    }

    /// Where the link to `fragment` (an anchor's id, if any) in the file at zip
    /// path `path` points: the offset of the text before the anchor, or the
    /// start of the item if it has no such anchor. None if `path` isn't a spine
    /// item.
    pub fn locate(&self, path: &str, fragment: Option<&str>) -> Option<Place> {
        let index = self.package.spine.iter().position(|item| item == path)?;
        Some(self.place_of(index, fragment))
    }

    /// Where `fragment` is in the spine item `index`.
    fn place_of(&self, index: usize, fragment: Option<&str>) -> Place {
        let offset = fragment.map_or(0, |fragment| {
            let item = self.item_or_empty(index);
            item.anchors.get(fragment).copied().unwrap_or(0)
        });
        Place::Epub {
            spine_index: index as u32,
            offset,
        }
    }

    fn resolve_outline(&self, outline: Vec<Outlined>, dir: &str) -> Vec<ContentsEntry> {
        outline
            .into_iter()
            .map(|item| {
                let place = item.href.and_then(|href| {
                    let path = resolve(dir, &href);
                    let fragment = href.split_once('#').map(|(_, f)| percent_decode(f));
                    let index = self.package.spine.iter().position(|item| *item == path)?;
                    Some(self.place_of(index, fragment.as_deref()))
                });
                ContentsEntry {
                    title: item.title.split_whitespace().collect::<Vec<_>>().join(" "),
                    place,
                    sections: self.resolve_outline(item.sections, dir),
                }
            })
            .collect()
    }

    /// The length of the text of each spine item, in characters, in order; 0 for
    /// one the zip can't read.
    pub fn characters(&self) -> Vec<u64> {
        (0..self.package.spine.len())
            .map(|i| self.item(i).map_or(0, |item| item.text.len() as u64))
            .collect()
    }
}

/// The nearest occurrence of a passage found so far.
#[derive(Clone, Copy)]
struct Nearest {
    /// Its distance from where it was, and its position: ordered, nearest first.
    key: (isize, isize),
    index: usize,
    offset: usize,
}

/// The unit at `at` of a spine item's text followed by its `\n` separator.
fn unit_at(text: &[u16], at: usize) -> u16 {
    text.get(at).copied().unwrap_or(u16::from(b'\n'))
}

/// Reads the entries of a nav or an NCX.
type OutlineParser = fn(&[u8]) -> Vec<Outlined>;

/// A Chapter or Section of the Table of Contents.
#[derive(Debug, Clone, PartialEq)]
pub struct ContentsEntry {
    pub title: String,
    /// An EPUB place; none for an entry without a link into the book.
    pub place: Option<Place>,
    /// The Sections nested under it.
    pub sections: Vec<ContentsEntry>,
}

/// A file of an EPUB, as the manifest declares it.
#[derive(Debug, PartialEq, Eq)]
pub struct Resource {
    pub bytes: Vec<u8>,
    /// The MIME type, such as `application/xhtml+xml` or `image/png`.
    pub media_type: String,
}

/// What the package file says.
struct Package {
    title: Option<String>,
    author: Option<String>,
    /// The path in the zip of the declared Cover image.
    cover: Option<String>,
    /// The paths in the zip of the spine items, in reading order.
    spine: Vec<String>,
    /// The media type of every manifest item, by its path in the zip.
    media_types: HashMap<String, String>,
    /// The path in the zip of the EPUB 3 navigation document.
    nav: Option<String>,
    /// The path in the zip of the EPUB 2 NCX.
    ncx: Option<String>,
}

/// An `item` of the package's manifest.
struct Item {
    path: String,
    media_type: String,
    properties: String,
}

impl Package {
    /// Reads the package file `opf`, which lies in the zip folder `dir`.
    fn parse(opf: &[u8], dir: &str) -> Result<Self, Error> {
        /// The text being read.
        #[derive(PartialEq)]
        enum Reading {
            Nothing,
            Title,
            Creator,
            Layout,
        }
        let (mut title, mut creators, mut fixed_layout) = (None, Vec::new(), false);
        let mut text = String::new();
        let mut reading = Reading::Nothing;
        let mut manifest: HashMap<String, Item> = HashMap::new();
        let (mut spine, mut cover_id) = (Vec::new(), None);
        read_xml(opf, |event| {
            match event {
                Event::Start(tag) | Event::Empty(tag) => match tag.local_name().as_ref() {
                    "title" if title.is_none() => (reading, text) = (Reading::Title, String::new()),
                    "creator" => (reading, text) = (Reading::Creator, String::new()),
                    "meta" => {
                        let name = attribute(tag, "name");
                        let content = attribute(tag, "content");
                        match (name.as_deref(), attribute(tag, "property").as_deref()) {
                            (Some("cover"), _) => cover_id = content,
                            (Some("fixed-layout"), _) => {
                                fixed_layout |= content.as_deref() == Some("true")
                            }
                            (_, Some("rendition:layout")) => {
                                (reading, text) = (Reading::Layout, String::new());
                            }
                            _ => {}
                        }
                    }
                    "item" => {
                        if let (Some(id), Some(href)) =
                            (attribute(tag, "id"), attribute(tag, "href"))
                        {
                            manifest.insert(
                                id,
                                Item {
                                    path: resolve(dir, &href),
                                    media_type: attribute(tag, "media-type").unwrap_or_default(),
                                    properties: attribute(tag, "properties").unwrap_or_default(),
                                },
                            );
                        }
                    }
                    "itemref" => spine.extend(attribute(tag, "idref")),
                    _ => {}
                },
                Event::Text(t) if reading != Reading::Nothing => text.push_str(&t.xml10_content()),
                Event::CData(t) if reading != Reading::Nothing => text.push_str(&t.xml10_content()),
                Event::End(_) => {
                    let finished = std::mem::take(&mut text);
                    let finished = finished.trim();
                    match std::mem::replace(&mut reading, Reading::Nothing) {
                        Reading::Title => title = Some(finished.to_owned()),
                        Reading::Creator => creators.push(finished.to_owned()),
                        Reading::Layout => fixed_layout |= finished == "pre-paginated",
                        Reading::Nothing => {}
                    }
                }
                _ => {}
            }
            ControlFlow::Continue(())
        })
        .map_err(|()| Error::Invalid)?;
        if fixed_layout {
            return Err(Error::FixedLayout);
        }
        let is_image = |item: &&Item| item.media_type.starts_with("image/");
        let declared = manifest
            .values()
            .find(|i| i.properties.split_whitespace().any(|p| p == "cover-image"))
            .or_else(|| cover_id.and_then(|id| manifest.get(&id)).filter(is_image));
        creators.retain(|creator| !creator.is_empty());
        let path_of =
            |is: &dyn Fn(&Item) -> bool| manifest.values().find(|i| is(i)).map(|i| i.path.clone());
        let nav = path_of(&|i| i.properties.split_whitespace().any(|p| p == "nav"));
        let ncx = path_of(&|i| i.media_type == "application/x-dtbncx+xml");
        Ok(Self {
            nav,
            ncx,
            title: title.filter(|t| !t.is_empty()),
            author: (!creators.is_empty()).then(|| creators.join(", ")),
            cover: declared.map(|item| item.path.clone()),
            spine: spine
                .iter()
                .filter_map(|id| manifest.get(id))
                .map(|item| item.path.clone())
                .collect(),
            media_types: manifest
                .into_values()
                .map(|item| (item.path, item.media_type))
                .collect(),
        })
    }
}

/// The path of the package file named by `container.xml`.
fn package_path(container: &[u8]) -> Option<String> {
    let mut path = None;
    let _ = read_xml(container, |event| {
        if let Event::Start(tag) | Event::Empty(tag) = event
            && tag.local_name().as_ref() == "rootfile"
        {
            path = attribute(tag, "full-path");
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    });
    path.map(|p| resolve("", &p))
}

/// Whether `encryption.xml` encrypts content. Obfuscated fonts are no DRM:
/// the book's publisher only ties them to its identifier.
fn encrypts_content(encryption: &[u8]) -> bool {
    const FONT_OBFUSCATION: [&str; 2] = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ];
    let mut encrypted = false;
    // A file that can't be read is no promise of encrypted content.
    let _ = read_xml(encryption, |event| {
        if let Event::Start(tag) | Event::Empty(tag) = event
            && tag.local_name().as_ref() == "EncryptionMethod"
        {
            let algorithm = attribute(tag, "Algorithm").unwrap_or_default();
            encrypted |= !FONT_OBFUSCATION.contains(&algorithm.as_str());
        }
        ControlFlow::Continue(())
    });
    encrypted
}

/// The text of the XHTML document `xhtml`, see the module docs, and the offset
/// (in UTF-16 units) of the text before each element of the body with an `id`
/// or `name`.
fn scan(xhtml: &[u8]) -> (String, HashMap<String, u64>) {
    let (mut in_body, mut text, mut anchors) = (false, String::new(), HashMap::new());
    // The units of `text[..counted]`: counted only when an anchor needs them.
    let (mut units, mut counted) = (0u64, 0);
    let _ = read_xml(xhtml, |event| {
        match event {
            Event::Start(tag) if tag.local_name().as_ref() == "body" => in_body = true,
            Event::End(tag) if tag.local_name().as_ref() == "body" => in_body = false,
            Event::Text(t) if in_body => text.push_str(&t.xml10_content()),
            Event::CData(t) if in_body => text.push_str(&t.xml10_content()),
            Event::GeneralRef(r) if in_body => text.extend(entity(r)),
            _ => {}
        }
        if let (true, Event::Start(tag) | Event::Empty(tag)) = (in_body, event) {
            for name in ["id", "name"] {
                if let Some(anchor) = attribute(tag, name) {
                    units += text[counted..].encode_utf16().count() as u64;
                    counted = text.len();
                    anchors.entry(anchor).or_insert(units);
                }
            }
        }
        ControlFlow::Continue(())
    });
    (text, anchors)
}

/// The character an entity or character reference stands for: XML's and
/// HTML 4's entities (such as `&nbsp;`); none for any other.
fn entity(reference: &BytesRef<'_>) -> Option<char> {
    match (reference.resolve_char_ref(), &**reference) {
        (Ok(Some(c)), _) => Some(c),
        (_, "apos") => Some('\''),
        (_, name) => entities::html(name),
    }
}

/// An entry of a Table of Contents as the nav or NCX gives it.
#[derive(Default)]
struct Outlined {
    title: String,
    /// As written: relative to the file, with its anchor.
    href: Option<String>,
    sections: Vec<Outlined>,
}

/// Builds the entries of an outline from its nesting: entries are begun and
/// ended in order, and one ended while another is open becomes its Section.
#[derive(Default)]
struct Outline {
    open: Vec<Outlined>,
    done: Vec<Outlined>,
}

impl Outline {
    fn begin(&mut self) {
        self.open.push(Outlined::default());
    }

    /// Adds title text to the innermost open entry.
    fn text(&mut self, text: &str) {
        if let Some(entry) = self.open.last_mut() {
            entry.title.push_str(text);
        }
    }

    fn character(&mut self, character: Option<char>) {
        if let Some(character) = character {
            self.text(character.encode_utf8(&mut [0; 4]));
        }
    }

    /// Gives the innermost open entry its first link, if `href` is one.
    fn link(&mut self, href: Option<String>) {
        if let (Some(entry), Some(href)) = (self.open.last_mut(), href) {
            entry.href.get_or_insert(href);
        }
    }

    fn end(&mut self) {
        let Some(entry) = self.open.pop() else { return };
        match self.open.last_mut() {
            Some(parent) => parent.sections.push(entry),
            None => self.done.push(entry),
        }
    }
}

/// The entries of the `toc` nav of an EPUB 3 navigation document: nested
/// `ol`/`li` lists of links.
fn nav_outline(xhtml: &[u8]) -> Vec<Outlined> {
    let (mut outline, mut in_toc) = (Outline::default(), false);
    let _ = read_xml(xhtml, |event| {
        match event {
            Event::Start(tag) if !in_toc && tag.local_name().as_ref() == "nav" => {
                in_toc = attribute(tag, "type")
                    .is_some_and(|t| t.split_whitespace().any(|t| t == "toc"));
            }
            Event::End(tag) if in_toc && tag.local_name().as_ref() == "nav" => {
                return ControlFlow::Break(());
            }
            Event::Start(tag) if in_toc => match tag.local_name().as_ref() {
                "li" => outline.begin(),
                "a" => outline.link(attribute(tag, "href")),
                _ => {}
            },
            Event::End(tag) if in_toc && tag.local_name().as_ref() == "li" => outline.end(),
            Event::Text(t) if in_toc => outline.text(&t.xml10_content()),
            Event::CData(t) if in_toc => outline.text(&t.xml10_content()),
            Event::GeneralRef(r) if in_toc => outline.character(entity(r)),
            _ => {}
        }
        ControlFlow::Continue(())
    });
    outline.done
}

/// The entries of an EPUB 2 NCX: nested `navPoint`s with a label and a
/// `content` link.
fn ncx_outline(xml: &[u8]) -> Vec<Outlined> {
    let (mut outline, mut in_label) = (Outline::default(), false);
    let _ = read_xml(xml, |event| {
        match event {
            Event::Start(tag) => match tag.local_name().as_ref() {
                "navPoint" => outline.begin(),
                "navLabel" => in_label = true,
                "content" => outline.link(attribute(tag, "src")),
                _ => {}
            },
            Event::Empty(tag) if tag.local_name().as_ref() == "content" => {
                outline.link(attribute(tag, "src"));
            }
            Event::End(tag) => match tag.local_name().as_ref() {
                "navPoint" => outline.end(),
                "navLabel" => in_label = false,
                _ => {}
            },
            Event::Text(t) if in_label => outline.text(&t.xml10_content()),
            Event::CData(t) if in_label => outline.text(&t.xml10_content()),
            Event::GeneralRef(r) if in_label => outline.character(entity(r)),
            _ => {}
        }
        ControlFlow::Continue(())
    });
    outline.done
}

/// Calls `visit` with each event of the XML in `bytes` until it breaks. Err if
/// the XML isn't well-formed, after `visit` saw everything before.
fn read_xml(bytes: &[u8], mut visit: impl FnMut(&Event<'_>) -> ControlFlow<()>) -> Result<(), ()> {
    let text = String::from_utf8_lossy(bytes);
    let mut reader = Reader::from_str(text.trim_start_matches('\u{feff}'));
    loop {
        match reader.read_event().map_err(|_| ())? {
            Event::Eof => return Ok(()),
            event if visit(&event).is_break() => return Ok(()),
            _ => {}
        }
    }
}

/// The value of attribute `name`, whatever its namespace prefix.
fn attribute(tag: &BytesStart<'_>, name: &str) -> Option<String> {
    tag.attributes()
        .flatten()
        .find(|a| a.key.local_name().as_ref() == name)
        .and_then(|a| a.normalized_value(XmlVersion::Implicit1_0).ok())
        .map(|value| value.into_owned())
}

/// The zip folder of the entry `path`, without the trailing slash.
fn directory_of(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(dir, _)| dir)
}

/// The zip path `href` points to from the zip folder `dir`: percent-decoded,
/// without query or fragment, with `.` and `..` resolved.
fn resolve(dir: &str, href: &str) -> String {
    let href = href.split(['#', '?']).next().unwrap_or_default();
    let href = percent_decode(href);
    let start = if href.starts_with('/') { "" } else { dir };
    let mut parts: Vec<&str> = Vec::new();
    for part in start.split('/').chain(href.split('/')) {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            part => parts.push(part),
        }
    }
    parts.join("/")
}

/// The entries of a zip file, read one at a time. Only what EPUBs use: stored
/// and deflated entries, no encryption, no zip64.
struct Zip {
    file: File,
    len: u64,
    entries: HashMap<String, ZipEntry>,
}

struct ZipEntry {
    method: u16,
    compressed: u64,
    size: u64,
    header_offset: u64,
}

const LOCAL_HEADER: [u8; 4] = *b"PK\x03\x04";
const CENTRAL_HEADER: [u8; 4] = *b"PK\x01\x02";
const END_OF_DIRECTORY: [u8; 4] = *b"PK\x05\x06";
/// No entry of an EPUB is bigger; the limit stops zip bombs.
const MAX_ENTRY: u64 = 512 << 20;

fn u16_at(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(bytes.get(at..at + 2)?.try_into().ok()?))
}

fn u32_at(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

/// Fills `buf` from `file` at `offset`, leaving no cursor to share between
/// threads. None if the file ends first.
fn read_at(file: &File, buf: &mut [u8], offset: u64) -> Option<()> {
    use std::os::unix::fs::FileExt;
    file.read_exact_at(buf, offset).ok()
}

impl Zip {
    /// Opens the zip at `path`; none if it isn't one.
    fn open(path: &Path) -> Option<Self> {
        let file = File::open(path).ok()?;
        let len = file.metadata().ok()?.len();
        let mut signature = [0; 4];
        read_at(&file, &mut signature, 0)?;
        if signature != LOCAL_HEADER {
            return None;
        }
        // The end record is within 64 KiB (its comment) of the end.
        let tail_len = len.min(22 + 0xFFFF);
        let mut tail = vec![0; usize::try_from(tail_len).ok()?];
        read_at(&file, &mut tail, len - tail_len)?;
        let end = &tail[tail.windows(4).rposition(|w| w == END_OF_DIRECTORY)?..];
        let count = usize::from(u16_at(end, 10)?);
        let (size, offset) = (u32_at(end, 12)?, u32_at(end, 16)?);
        if count == 0xFFFF || size == u32::MAX || offset == u32::MAX || u64::from(size) > len {
            return None;
        }
        let mut directory = vec![0; usize::try_from(size).ok()?];
        read_at(&file, &mut directory, offset.into())?;

        let mut entries = HashMap::new();
        let mut at = 0;
        for _ in 0..count {
            let header = directory.get(at..)?;
            if header.get(..4)? != CENTRAL_HEADER {
                return None;
            }
            let (name_len, extra_len, comment_len) = (
                usize::from(u16_at(header, 28)?),
                usize::from(u16_at(header, 30)?),
                usize::from(u16_at(header, 32)?),
            );
            let name = String::from_utf8_lossy(header.get(46..46 + name_len)?).into_owned();
            let encrypted = u16_at(header, 8)? & 1 != 0;
            let entry = ZipEntry {
                method: u16_at(header, 10)?,
                compressed: u32_at(header, 20)?.into(),
                size: u32_at(header, 24)?.into(),
                header_offset: u32_at(header, 42)?.into(),
            };
            if !encrypted {
                entries.insert(name, entry);
            }
            at += 46 + name_len + extra_len + comment_len;
        }
        Some(Self { file, len, entries })
    }

    fn contains(&self, name: &str) -> bool {
        self.entries.contains_key(name)
    }

    /// The content of entry `name`; none if there is no such entry or it
    /// can't be read.
    fn read(&self, name: &str) -> Option<Vec<u8>> {
        let entry = self.entries.get(name)?;
        if entry.size > MAX_ENTRY || entry.compressed > self.len {
            return None;
        }
        let mut header = [0; 30];
        read_at(&self.file, &mut header, entry.header_offset)?;
        if header[..4] != LOCAL_HEADER {
            return None;
        }
        let data = entry.header_offset
            + 30
            + u64::from(u16_at(&header, 26)?)
            + u64::from(u16_at(&header, 28)?);
        let mut raw = vec![0; usize::try_from(entry.compressed).ok()?];
        read_at(&self.file, &mut raw, data)?;
        let content = match entry.method {
            0 => raw,
            8 => decompress_to_vec_with_limit(&raw, usize::try_from(entry.size).ok()?).ok()?,
            _ => return None,
        };
        (content.len() as u64 == entry.size).then_some(content)
    }
}

/// Test EPUBs, built in code. Entries are stored without a checksum, which
/// readers here don't check.
#[cfg(test)]
pub(crate) mod fixtures {
    /// A zip of `entries`, each stored uncompressed, except those named in
    /// `deflated`.
    pub fn zip(entries: &[(&str, &[u8])], deflated: &[&str]) -> Vec<u8> {
        let (mut body, mut directory) = (Vec::new(), Vec::new());
        for (name, content) in entries {
            let packed = if deflated.contains(name) {
                (8u16, miniz_oxide::deflate::compress_to_vec(content, 6))
            } else {
                (0, content.to_vec())
            };
            let (method, data) = packed;
            let common = |out: &mut Vec<u8>| {
                out.extend(method.to_le_bytes());
                out.extend([0; 4]); // time, date
                out.extend([0; 4]); // CRC-32
                out.extend((data.len() as u32).to_le_bytes());
                out.extend((content.len() as u32).to_le_bytes());
                out.extend((name.len() as u16).to_le_bytes());
                out.extend([0; 2]); // extra length
            };
            let offset = body.len() as u32;
            body.extend(b"PK\x03\x04");
            body.extend([20, 0, 0, 0]); // version, flags
            common(&mut body);
            body.extend(name.as_bytes());
            body.extend(&data);

            directory.extend(b"PK\x01\x02");
            directory.extend([20, 0, 20, 0, 0, 0]); // versions, flags
            common(&mut directory);
            directory.extend([0; 10]); // comment length, disk, internal and external attributes
            directory.extend(offset.to_le_bytes());
            directory.extend(name.as_bytes());
        }
        let mut zip = body;
        let directory_offset = zip.len() as u32;
        zip.extend(&directory);
        zip.extend(b"PK\x05\x06");
        zip.extend([0; 4]); // disks
        zip.extend((entries.len() as u16).to_le_bytes());
        zip.extend((entries.len() as u16).to_le_bytes());
        zip.extend((directory.len() as u32).to_le_bytes());
        zip.extend(directory_offset.to_le_bytes());
        zip.extend([0; 2]); // comment length
        zip
    }

    pub const CONTAINER: &str = r#"<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"#;

    /// An EPUB under construction: a package in `OEBPS/` whose spine lists
    /// `OEBPS/text/chapter<n>.xhtml`.
    #[derive(Default)]
    pub struct Book {
        /// Inside `<metadata>`.
        pub metadata: String,
        /// More manifest items.
        pub manifest: String,
        /// The `<body>` of each chapter.
        pub chapters: Vec<String>,
        /// More files, by path in the zip.
        pub files: Vec<(String, Vec<u8>)>,
    }

    impl Book {
        pub fn new(metadata: &str) -> Self {
            Self {
                metadata: metadata.to_owned(),
                chapters: vec!["<p>Hello</p>".to_owned()],
                ..Self::default()
            }
        }

        pub fn manifest(mut self, items: &str) -> Self {
            self.manifest.push_str(items);
            self
        }

        pub fn chapters(mut self, bodies: &[&str]) -> Self {
            self.chapters = bodies.iter().map(|b| (*b).to_owned()).collect();
            self
        }

        pub fn file(mut self, path: &str, content: &[u8]) -> Self {
            self.files.push((path.to_owned(), content.to_vec()));
            self
        }

        pub fn bytes(&self) -> Vec<u8> {
            let (mut manifest, mut spine) = (self.manifest.clone(), String::new());
            let mut chapters = Vec::new();
            for (n, body) in self.chapters.iter().enumerate() {
                manifest.push_str(&format!(
                    r#"<item id="c{n}" href="text/chapter{n}.xhtml" media-type="application/xhtml+xml"/>"#
                ));
                spine.push_str(&format!(r#"<itemref idref="c{n}"/>"#));
                let xhtml = format!(
                    r#"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignored</title></head><body>{body}</body></html>"#
                );
                chapters.push((format!("OEBPS/text/chapter{n}.xhtml"), xhtml.into_bytes()));
            }
            let opf = format!(
                r#"<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">{}</metadata>
  <manifest>{manifest}</manifest>
  <spine>{spine}</spine>
</package>"#,
                self.metadata
            );
            let mut entries: Vec<(&str, &[u8])> = vec![
                ("mimetype", b"application/epub+zip"),
                ("META-INF/container.xml", CONTAINER.as_bytes()),
                ("OEBPS/content.opf", opf.as_bytes()),
            ];
            entries.extend(chapters.iter().map(|(n, c)| (n.as_str(), c.as_slice())));
            entries.extend(self.files.iter().map(|(n, c)| (n.as_str(), c.as_slice())));
            zip(&entries, &[])
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::{Book, CONTAINER, zip};
    use super::*;
    use std::fs;

    /// Opens `bytes` as an EPUB file in a scratch folder.
    fn open(bytes: &[u8]) -> Result<Epub, Error> {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("leaf-epub-{}-{n}.epub", std::process::id()));
        fs::write(&path, bytes).unwrap();
        let opened = Epub::open(&path);
        fs::remove_file(path).unwrap();
        opened
    }

    const TITLE_AND_AUTHOR: &str = "<dc:title>Emma</dc:title><dc:creator>Jane Austen</dc:creator>";

    #[test]
    fn reads_title_and_author_and_joins_several_authors() {
        let epub = open(&Book::new(TITLE_AND_AUTHOR).bytes()).unwrap();
        assert_eq!(epub.title(), Some("Emma"));
        assert_eq!(epub.author(), Some("Jane Austen"));

        let two = Book::new("<dc:creator>A</dc:creator><dc:creator> B </dc:creator>");
        assert_eq!(open(&two.bytes()).unwrap().author(), Some("A, B"));
    }

    #[test]
    fn a_missing_or_blank_title_and_author_are_none() {
        let epub = open(&Book::new("<dc:title> </dc:title>").bytes()).unwrap();
        assert_eq!((epub.title(), epub.author()), (None, None));
    }

    #[test]
    fn the_cover_is_the_epub3_cover_image() {
        let book = Book::new("")
            .manifest(r#"<item id="i" href="img/c.png" media-type="image/png" properties="cover-image"/>"#)
            .file("OEBPS/img/c.png", b"PNG3");
        assert_eq!(open(&book.bytes()).unwrap().cover(), Some(b"PNG3".to_vec()));
    }

    #[test]
    fn the_cover_is_the_epub2_cover_meta_image() {
        let book = Book::new(r#"<meta name="cover" content="cov"/>"#)
            .manifest(r#"<item id="cov" href="c%20x.jpg" media-type="image/jpeg"/>"#)
            .file("OEBPS/c x.jpg", b"JPG2");
        assert_eq!(open(&book.bytes()).unwrap().cover(), Some(b"JPG2".to_vec()));
    }

    #[test]
    fn without_a_declared_cover_it_is_the_first_image_of_the_first_spine_item() {
        let book = Book::new("")
            .chapters(&[
                r#"<p>x</p><img src="../img/a.png"/><img src="../img/b.png"/>"#,
                r#"<img src="../img/c.png"/>"#,
            ])
            .file("OEBPS/img/a.png", b"A")
            .file("OEBPS/img/b.png", b"B")
            .file("OEBPS/img/c.png", b"C");
        assert_eq!(open(&book.bytes()).unwrap().cover(), Some(b"A".to_vec()));
    }

    #[test]
    fn an_svg_image_counts_as_an_image() {
        let book = Book::new("")
            .chapters(&[r#"<svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../a.jpg"/></svg>"#])
            .file("OEBPS/a.jpg", b"A");
        assert_eq!(open(&book.bytes()).unwrap().cover(), Some(b"A".to_vec()));
    }

    #[test]
    fn there_is_no_cover_without_images_or_when_the_first_item_has_none() {
        let none = Book::new("").chapters(&["<p>no image</p>"]);
        assert_eq!(open(&none.bytes()).unwrap().cover(), None);

        let later = Book::new("")
            .chapters(&["<p>no image</p>", r#"<img src="../a.png"/>"#])
            .file("OEBPS/a.png", b"A");
        assert_eq!(open(&later.bytes()).unwrap().cover(), None);

        let missing = Book::new("").chapters(&[r#"<img src="gone.png"/>"#]);
        assert_eq!(open(&missing.bytes()).unwrap().cover(), None);
    }

    #[test]
    fn a_cover_meta_that_names_no_image_is_not_a_cover() {
        let book = Book::new(r#"<meta name="cover" content="c0"/>"#);
        assert_eq!(open(&book.bytes()).unwrap().cover(), None);
    }

    #[test]
    fn text_is_the_concatenated_body_text_nodes_of_a_spine_item() {
        let book = Book::new("").chapters(&[
            "<h1>Hi</h1><p>a<b>b</b>&amp;&#233;&nbsp;&apos;&bogus;</p>",
            "<p><![CDATA[<x>]]>😀</p>",
        ]);
        let epub = open(&book.bytes()).unwrap();
        // HTML's named entities too, as web views resolve them in XHTML; unknown ones are dropped.
        assert_eq!(epub.text(0).as_deref(), Some("Hiab&é\u{a0}'"));
        assert_eq!(epub.text(1).as_deref(), Some("<x>😀"));
        assert_eq!(epub.text(2), None);
    }

    #[test]
    fn characters_count_the_text_of_every_spine_item_in_utf16_units() {
        let book = Book::new("").chapters(&[
            "<h1>Hi</h1><p>a<b>b</b>&amp;&#233;&nbsp;</p>",
            "<p><![CDATA[<x>]]>😀</p>",
        ]);
        // "Hiab&é\u{a0}" and "<x>" + 😀 (2 units)
        assert_eq!(open(&book.bytes()).unwrap().characters(), [7, 5]);
    }

    #[test]
    fn characters_leave_out_everything_outside_the_body_and_stop_at_broken_xhtml() {
        let book = Book::new("").chapters(&["<p>abc</p><p>de"]);
        // The head's title isn't text; the item breaks at its unclosed `p`.
        assert_eq!(open(&book.bytes()).unwrap().characters(), [5]);
    }

    #[test]
    fn resources_and_texts_are_served_to_several_threads_at_once() {
        let bodies: Vec<String> = (0..6).map(|n| format!("<p>chapter {n}</p>")).collect();
        let mut book =
            Book::new("").chapters(&bodies.iter().map(String::as_str).collect::<Vec<_>>());
        for n in 0..6 {
            book = book
                .manifest(&format!(
                    r#"<item id="i{n}" href="img/{n}.png" media-type="image/png"/>"#
                ))
                .file(&format!("OEBPS/img/{n}.png"), format!("PNG{n}").as_bytes());
        }
        let epub = open(&book.bytes()).unwrap();

        std::thread::scope(|scope| {
            for thread in 0..8 {
                let epub = &epub;
                scope.spawn(move || {
                    for round in 0..50 {
                        let n = (thread + round) % 6;
                        let image = epub.resource(&format!("OEBPS/img/{n}.png")).unwrap();
                        assert_eq!(image.bytes, format!("PNG{n}").as_bytes());
                        assert_eq!(epub.text(n), Some(format!("chapter {n}")));
                    }
                });
            }
        });
    }

    #[test]
    fn resources_are_the_manifests_items_with_their_media_types() {
        let book = Book::new("")
            .manifest(r#"<item id="i" href="img/c%20d.png" media-type="image/png"/>"#)
            .manifest(r#"<item id="g" href="gone.png" media-type="image/png"/>"#)
            .file("OEBPS/img/c d.png", b"PNG")
            .file("OEBPS/unlisted.txt", b"secret");
        let epub = open(&book.bytes()).unwrap();

        let image = epub.resource("OEBPS/img/c d.png").unwrap();
        assert_eq!(image.media_type, "image/png");
        assert_eq!(image.bytes, b"PNG");
        // Neither files outside the manifest nor items missing from the zip.
        assert!(epub.resource("OEBPS/unlisted.txt").is_none());
        assert!(epub.resource("META-INF/container.xml").is_none());
        assert!(epub.resource("OEBPS/gone.png").is_none());
    }

    const NAV: &str = r#"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
<nav epub:type="landmarks"><ol><li><a href="text/chapter0.xhtml">Landmark</a></li></ol></nav>
<nav epub:type="toc"><h1>Contents</h1><ol>
<li><a href="text/chapter0.xhtml">One</a><ol>
<li><a href="text/chapter0.xhtml#mid">Mid <em>way</em></a></li>
<li><a href="text/chapter1.xhtml#nowhere">Gone</a></li></ol></li>
<li><span>Part</span><ol><li><a href="text/chapter1.xhtml">Two</a></li></ol></li>
<li><a href="https://example.com/">Web</a></li>
</ol></nav></body></html>"#;

    fn entry(
        title: &str,
        spine_index: u32,
        offset: u64,
        sections: Vec<ContentsEntry>,
    ) -> ContentsEntry {
        let place = Some(Place::Epub {
            spine_index,
            offset,
        });
        ContentsEntry {
            title: title.to_owned(),
            place,
            sections,
        }
    }

    #[test]
    fn the_contents_are_the_epub3_nav_with_nested_sections_at_text_offsets() {
        let book = Book::new("")
            .chapters(&[r#"<p>abc</p><p id="mid">de&amp;f</p>"#, "<p>x</p>"])
            .manifest(
                r#"<item id="n" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            )
            .file("OEBPS/nav.xhtml", NAV.as_bytes());
        let epub = open(&book.bytes()).unwrap();

        // A heading without a link is listed but points nowhere, and so is a web link.
        let part = ContentsEntry {
            title: "Part".into(),
            place: None,
            sections: vec![entry("Two", 1, 0, vec![])],
        };
        let web = ContentsEntry {
            title: "Web".into(),
            place: None,
            sections: vec![],
        };
        let one = entry(
            "One",
            0,
            0,
            vec![entry("Mid way", 0, 3, vec![]), entry("Gone", 1, 0, vec![])],
        );
        assert_eq!(epub.contents(), [one, part, web]);
    }

    #[test]
    fn without_a_nav_the_contents_are_the_epub2_ncx() {
        let ncx = r#"<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><docTitle><text>Book</text></docTitle><navMap>
<navPoint id="a"><navLabel><text>One</text></navLabel><content src="text/chapter0.xhtml"/>
  <navPoint id="b"><navLabel><text> Mid
  way </text></navLabel><content src="text/chapter1.xhtml#mid"/>
    <navPoint id="c"><navLabel><text>Deep</text></navLabel><content src="text/chapter1.xhtml#deep"/></navPoint>
  </navPoint></navPoint>
<navPoint id="d"><navLabel><text>Two</text></navLabel><content src="text/chapter1.xhtml"/></navPoint>
</navMap></ncx>"#;
        let book = Book::new("")
            .chapters(&[
                "<p>abc</p>",
                r#"<p>ab<b id="mid">c</b><i/>d<a name="deep"/>ef</p>"#,
            ])
            .manifest(r#"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#)
            .file("OEBPS/toc.ncx", ncx.as_bytes());
        let epub = open(&book.bytes()).unwrap();

        let deep = entry("Deep", 1, 4, vec![]);
        let one = entry("One", 0, 0, vec![entry("Mid way", 1, 2, vec![deep])]);
        assert_eq!(epub.contents(), [one, entry("Two", 1, 0, vec![])]);
    }

    #[test]
    fn the_nav_wins_over_the_ncx_and_a_book_without_either_has_no_contents() {
        let nav = r#"<html xmlns:epub="x"><body><nav epub:type="toc"><ol><li><a href="text/chapter0.xhtml">Nav</a></li></ol></nav></body></html>"#;
        let ncx = r#"<ncx><navMap><navPoint><navLabel><text>Ncx</text></navLabel><content src="text/chapter0.xhtml"/></navPoint></navMap></ncx>"#;
        let book = Book::new("")
            .manifest(r#"<item id="n" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#)
            .file("OEBPS/nav.xhtml", nav.as_bytes())
            .file("OEBPS/toc.ncx", ncx.as_bytes());
        let both = open(&book.bytes()).unwrap();
        assert_eq!(both.contents(), [entry("Nav", 0, 0, vec![])]);

        assert!(open(&Book::new("").bytes()).unwrap().contents().is_empty());
    }

    #[test]
    fn locate_finds_the_text_offset_of_an_anchor_in_a_spine_item() {
        let book =
            Book::new("").chapters(&[r#"<p id="a">ab</p><p>c<span id="b"/>d</p>"#, "<p>x</p>"]);
        let epub = open(&book.bytes()).unwrap();
        let at = |spine_index, offset| {
            Some(Place::Epub {
                spine_index,
                offset,
            })
        };

        assert_eq!(
            epub.locate("OEBPS/text/chapter0.xhtml", Some("b")),
            at(0, 3)
        );
        assert_eq!(
            epub.locate("OEBPS/text/chapter0.xhtml", Some("a")),
            at(0, 0)
        );
        // An unknown anchor, or none, is the start of the item.
        assert_eq!(
            epub.locate("OEBPS/text/chapter0.xhtml", Some("zzz")),
            at(0, 0)
        );
        assert_eq!(epub.locate("OEBPS/text/chapter1.xhtml", None), at(1, 0));
        // Not a spine item.
        assert_eq!(epub.locate("OEBPS/content.opf", None), None);
    }

    const OPF: &str = r#"<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="x"><dc:title>Deflated</dc:title></metadata>
<manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="gone.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="b"/><itemref idref="a"/></spine></package>"#;

    #[test]
    fn inflates_deflated_entries_and_leaves_out_spine_items_missing_from_the_zip() {
        let entries: Vec<(&str, &[u8])> = vec![
            ("mimetype", b"application/epub+zip"),
            ("META-INF/container.xml", CONTAINER.as_bytes()),
            ("OEBPS/content.opf", OPF.as_bytes()),
            ("OEBPS/a.xhtml", b"<html><body>12345</body></html>"),
        ];
        let epub = open(&zip(&entries, &["OEBPS/content.opf", "OEBPS/a.xhtml"])).unwrap();
        assert_eq!(epub.title(), Some("Deflated"));
        assert_eq!(epub.characters(), [5]);
    }

    #[test]
    fn a_book_with_encrypted_content_is_drm_protected() {
        let encryption = r#"<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
<enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
<enc:CipherData><enc:CipherReference URI="OEBPS/text/chapter0.xhtml"/></enc:CipherData></enc:EncryptedData></encryption>"#;
        let book = Book::new("").file("META-INF/encryption.xml", encryption.as_bytes());
        assert_eq!(open(&book.bytes()).err(), Some(Error::DrmProtected));
    }

    #[test]
    fn obfuscated_fonts_are_no_drm() {
        let encryption = r#"<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
<enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></enc:EncryptedData>
<enc:EncryptedData><enc:EncryptionMethod Algorithm="http://ns.adobe.com/pdf/enc#RC"/></enc:EncryptedData></encryption>"#;
        let book = Book::new("").file("META-INF/encryption.xml", encryption.as_bytes());
        assert!(open(&book.bytes()).is_ok());
    }

    #[test]
    fn fixed_layout_books_are_rejected() {
        for metadata in [
            r#"<meta property="rendition:layout">pre-paginated</meta>"#,
            r#"<meta name="fixed-layout" content="true"/>"#,
        ] {
            let book = Book::new(metadata);
            assert_eq!(
                open(&book.bytes()).err(),
                Some(Error::FixedLayout),
                "{metadata}"
            );
        }
        let reflowable = Book::new(r#"<meta property="rendition:layout">reflowable</meta>"#);
        assert!(open(&reflowable.bytes()).is_ok());
    }

    #[test]
    fn anything_else_is_invalid() {
        let good: Vec<(&str, &[u8])> = vec![
            ("mimetype", b"application/epub+zip"),
            ("META-INF/container.xml", CONTAINER.as_bytes()),
            ("OEBPS/content.opf", OPF.as_bytes()),
            ("OEBPS/a.xhtml", b"<html><body>1</body></html>"),
        ];
        assert!(open(&zip(&good, &[])).is_ok());
        let without = |name: &str| -> Vec<u8> {
            let rest: Vec<_> = good.iter().filter(|(n, _)| *n != name).cloned().collect();
            zip(&rest, &[])
        };
        let wrong_mimetype = {
            let mut entries = good.clone();
            entries[0].1 = b"application/zip";
            zip(&entries, &[])
        };
        let broken_package = {
            let mut entries = good.clone();
            entries[2].1 = b"<package><metadata></package>";
            zip(&entries, &[])
        };
        let empty_spine = {
            let mut entries = good.clone();
            entries[2].1 = b"<package><manifest/><spine/></package>";
            zip(&entries, &[])
        };
        for (what, bytes) in [
            ("not a zip", b"just text, no zip at all".to_vec()),
            ("empty", Vec::new()),
            ("no mimetype", without("mimetype")),
            ("wrong mimetype", wrong_mimetype),
            ("no container", without("META-INF/container.xml")),
            ("no package", without("OEBPS/content.opf")),
            ("broken package", broken_package),
            ("empty spine", empty_spine),
            ("no spine files", without("OEBPS/a.xhtml")),
            ("truncated", good_truncated(&zip(&good, &[]))),
        ] {
            assert_eq!(open(&bytes).err(), Some(Error::Invalid), "{what}");
        }
    }

    fn good_truncated(zip: &[u8]) -> Vec<u8> {
        zip[..zip.len() - 30].to_vec()
    }

    fn at(spine_index: u32, offset: u64) -> EpubPosition {
        EpubPosition {
            spine_index,
            offset,
        }
    }

    #[test]
    fn relocate_finds_a_passage_spanning_two_spine_items() {
        let book = Book::new("").chapters(&["<p>alpha beta</p>", "<p>gamma delta</p>"]);
        let epub = open(&book.bytes()).unwrap();
        // Joined by `\n`; the stored place is stale.
        assert_eq!(
            epub.relocate(at(1, 9), at(1, 9), "beta\ngamma"),
            Some((at(0, 6), at(1, 5)))
        );
        // Not where the item break would have to be.
        assert_eq!(epub.relocate(at(0, 0), at(0, 1), "beta gamma"), None);
    }

    #[test]
    fn relocate_picks_the_occurrence_nearest_to_the_stored_start_on_either_side() {
        let book = Book::new("").chapters(&["<p>ab</p>", "<p>zzzz</p>", "<p>ab</p>", "<p>ab</p>"]);
        let epub = open(&book.bytes()).unwrap();
        let nearest = |from: EpubPosition| epub.relocate(from, from, "ab");
        assert_eq!(nearest(at(1, 0)), Some((at(0, 0), at(0, 2))));
        assert_eq!(nearest(at(1, 4)), Some((at(2, 0), at(2, 2))));
        // Beyond the book, a start counts as its end.
        assert_eq!(nearest(at(9, 9)), Some((at(3, 0), at(3, 2))));
    }

    #[test]
    fn paths_resolve_against_their_folder() {
        assert_eq!(
            resolve("OEBPS/text", "../img/a%20b.png#x"),
            "OEBPS/img/a b.png"
        );
        assert_eq!(resolve("OEBPS", "./c.xhtml?q"), "OEBPS/c.xhtml");
        assert_eq!(resolve("OEBPS", "/abs/c.png"), "abs/c.png");
        assert_eq!(resolve("a", "../../../b"), "b");
        assert_eq!(resolve("", "100%"), "100%");
    }
}
