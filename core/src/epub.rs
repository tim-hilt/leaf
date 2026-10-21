//! Reading EPUBs (ADR-0021): everything but drawing them. Reflowable EPUB 2 and
//! 3 only; DRM-protected and fixed-layout ones are rejected.
//!
//! An EPUB is a zip of XML and XHTML. `Epub::open` reads its package (the
//! `.opf` file named by `META-INF/container.xml`): Title, Author, the spine
//! (the reading order of its XHTML files) and the declared Cover. Zip entries
//! are read, and inflated, one at a time, so a book is never held in memory.
//!
//! The text of a spine item, the contract with the clients' web views (ADR-0022),
//! is its XHTML body's text nodes concatenated in document order, with
//! entities resolved. Its length is counted in UTF-16 code units, as
//! JavaScript counts a string.

use miniz_oxide::inflate::decompress_to_vec_with_limit;
use quick_xml::XmlVersion;
use quick_xml::events::{BytesStart, Event};
use quick_xml::reader::Reader;
use std::collections::HashMap;
use std::fmt;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::ops::ControlFlow;
use std::path::Path;

/// Why a File isn't an EPUB LeafPDF reads.
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
}

impl Epub {
    /// Opens the EPUB at `path`.
    pub fn open(path: &Path) -> Result<Self, Error> {
        let mut zip = Zip::open(path).ok_or(Error::Invalid)?;
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
        Ok(Self { zip, package })
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
    pub fn resource(&mut self, path: &str) -> Option<Resource> {
        let media_type = self.package.media_types.get(path)?.clone();
        let bytes = self.zip.read(path)?;
        Some(Resource { bytes, media_type })
    }

    /// The bytes of the Cover image: the declared cover, else the first image
    /// of the first spine item. None if there is no image.
    pub fn cover(&mut self) -> Option<Vec<u8>> {
        let path = self.package.cover.clone().or_else(|| self.first_image())?;
        self.zip.read(&path)
    }

    /// The path of the first image in the first spine item that the zip has.
    fn first_image(&mut self) -> Option<String> {
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

    /// The text of the spine item at `index`, see the module docs: up to where
    /// it breaks if it isn't well-formed. None for an index beyond the spine,
    /// and for an item the zip can't read.
    pub fn text(&mut self, index: usize) -> Option<String> {
        let item = self.package.spine.get(index)?;
        self.zip.read(item).map(|xhtml| text_of(&xhtml))
    }

    /// The length of the text of each spine item, in characters, in order; 0 for
    /// one the zip can't read.
    pub fn characters(&mut self) -> Vec<u64> {
        (0..self.package.spine.len())
            .map(|i| {
                let text = self.text(i);
                text.map_or(0, |t| t.encode_utf16().count() as u64)
            })
            .collect()
    }
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
        Ok(Self {
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

/// The length of the text of the XHTML document `xhtml`, see the module docs.
fn text_of(xhtml: &[u8]) -> String {
    let (mut in_body, mut text) = (false, String::new());
    let _ = read_xml(xhtml, |event| {
        match event {
            Event::Start(tag) if tag.local_name().as_ref() == "body" => in_body = true,
            Event::End(tag) if tag.local_name().as_ref() == "body" => in_body = false,
            Event::Text(t) if in_body => text.push_str(&t.xml10_content()),
            Event::CData(t) if in_body => text.push_str(&t.xml10_content()),
            Event::GeneralRef(r) if in_body => match (r.resolve_char_ref(), &**r) {
                (Ok(Some(c)), _) => text.push(c),
                (_, "amp") => text.push('&'),
                (_, "lt") => text.push('<'),
                (_, "gt") => text.push('>'),
                (_, "quot") => text.push('"'),
                (_, "apos") => text.push('\''),
                _ => {}
            },
            _ => {}
        }
        ControlFlow::Continue(())
    });
    text
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

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let escaped = bytes.get(i + 1..i + 3).and_then(|hex| {
            let hex = std::str::from_utf8(hex).ok()?;
            u8::from_str_radix(hex, 16).ok()
        });
        match (bytes[i], escaped) {
            (b'%', Some(byte)) => {
                decoded.push(byte);
                i += 3;
            }
            (byte, _) => {
                decoded.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&decoded).into_owned()
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

impl Zip {
    /// Opens the zip at `path`; none if it isn't one.
    fn open(path: &Path) -> Option<Self> {
        let mut file = File::open(path).ok()?;
        let len = file.metadata().ok()?.len();
        let mut signature = [0; 4];
        file.read_exact(&mut signature).ok()?;
        if signature != LOCAL_HEADER {
            return None;
        }
        // The end record is within 64 KiB (its comment) of the end.
        let tail_len = len.min(22 + 0xFFFF);
        file.seek(SeekFrom::Start(len - tail_len)).ok()?;
        let mut tail = vec![0; usize::try_from(tail_len).ok()?];
        file.read_exact(&mut tail).ok()?;
        let end = &tail[tail.windows(4).rposition(|w| w == END_OF_DIRECTORY)?..];
        let count = usize::from(u16_at(end, 10)?);
        let (size, offset) = (u32_at(end, 12)?, u32_at(end, 16)?);
        if count == 0xFFFF || size == u32::MAX || offset == u32::MAX || u64::from(size) > len {
            return None;
        }
        file.seek(SeekFrom::Start(offset.into())).ok()?;
        let mut directory = vec![0; usize::try_from(size).ok()?];
        file.read_exact(&mut directory).ok()?;

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
    fn read(&mut self, name: &str) -> Option<Vec<u8>> {
        let entry = self.entries.get(name)?;
        if entry.size > MAX_ENTRY || entry.compressed > self.len {
            return None;
        }
        self.file.seek(SeekFrom::Start(entry.header_offset)).ok()?;
        let mut header = [0; 30];
        self.file.read_exact(&mut header).ok()?;
        if header[..4] != LOCAL_HEADER {
            return None;
        }
        let skip = i64::from(u16_at(&header, 26)?) + i64::from(u16_at(&header, 28)?);
        self.file.seek(SeekFrom::Current(skip)).ok()?;
        let mut raw = Vec::with_capacity(usize::try_from(entry.compressed).ok()?);
        (&mut self.file)
            .take(entry.compressed)
            .read_to_end(&mut raw)
            .ok()?;
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
        let path =
            std::env::temp_dir().join(format!("leafpdf-epub-{}-{n}.epub", std::process::id()));
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
            "<h1>Hi</h1><p>a<b>b</b>&amp;&#233;&nbsp;</p>",
            "<p><![CDATA[<x>]]>😀</p>",
        ]);
        let mut epub = open(&book.bytes()).unwrap();
        // `&nbsp;` is not an XML entity: dropped.
        assert_eq!(epub.text(0).as_deref(), Some("Hiab&é"));
        assert_eq!(epub.text(1).as_deref(), Some("<x>😀"));
        assert_eq!(epub.text(2), None);
    }

    #[test]
    fn characters_count_the_text_of_every_spine_item_in_utf16_units() {
        let book = Book::new("").chapters(&[
            "<h1>Hi</h1><p>a<b>b</b>&amp;&#233;&nbsp;</p>",
            "<p><![CDATA[<x>]]>😀</p>",
        ]);
        // "Hiab&é" and "<x>" + 😀 (2 units)
        assert_eq!(open(&book.bytes()).unwrap().characters(), [6, 5]);
    }

    #[test]
    fn characters_leave_out_everything_outside_the_body_and_stop_at_broken_xhtml() {
        let book = Book::new("").chapters(&["<p>abc</p><p>de"]);
        // The head's title isn't text; the item breaks at its unclosed `p`.
        assert_eq!(open(&book.bytes()).unwrap().characters(), [5]);
    }

    #[test]
    fn resources_are_the_manifests_items_with_their_media_types() {
        let book = Book::new("")
            .manifest(r#"<item id="i" href="img/c%20d.png" media-type="image/png"/>"#)
            .manifest(r#"<item id="g" href="gone.png" media-type="image/png"/>"#)
            .file("OEBPS/img/c d.png", b"PNG")
            .file("OEBPS/unlisted.txt", b"secret");
        let mut epub = open(&book.bytes()).unwrap();

        let image = epub.resource("OEBPS/img/c d.png").unwrap();
        assert_eq!(image.media_type, "image/png");
        assert_eq!(image.bytes, b"PNG");
        // Neither files outside the manifest nor items missing from the zip.
        assert!(epub.resource("OEBPS/unlisted.txt").is_none());
        assert!(epub.resource("META-INF/container.xml").is_none());
        assert!(epub.resource("OEBPS/gone.png").is_none());
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
        let mut epub = open(&zip(&entries, &["OEBPS/content.opf", "OEBPS/a.xhtml"])).unwrap();
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
