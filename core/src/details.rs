//! A Document's details: what the client read from its File, since the core
//! never opens PDFs (ADR-0003). Kept on this Device only, never synced: every
//! Device reads them from the same File.
//!
//! Stored as three lines: the page count, the title and the author, an empty
//! line for one the File lacks. Anything else reads as no details, which the
//! client then reads again.

/// What a Document's File says about itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Details {
    /// The title stored in the File; none if it has none.
    pub title: Option<String>,
    /// The author stored in the File; none if it has none.
    pub author: Option<String>,
    pub page_count: u32,
}

/// `details` as stored. A blank title or author is stored as none, and line
/// breaks in them become single spaces, so they read back that way.
pub(crate) fn encode(details: &Details) -> Vec<u8> {
    let line = |text: &Option<String>| one_line(text.as_deref().unwrap_or_default());
    let (title, author) = (line(&details.title), line(&details.author));
    format!("{}\n{title}\n{author}", details.page_count).into_bytes()
}

/// The details stored in `bytes`; none if they aren't stored details.
pub(crate) fn decode(bytes: &[u8]) -> Option<Details> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut lines = text.split('\n');
    let page_count = lines.next()?.parse().ok()?;
    let (title, author) = (lines.next()?, lines.next()?);
    let some = |line: &str| (!line.is_empty()).then(|| line.to_owned());
    lines.next().is_none().then(|| Details {
        title: some(title),
        author: some(author),
        page_count,
    })
}

/// `text` on one line, its lines trimmed and joined by single spaces; empty if
/// it is blank.
fn one_line(text: &str) -> String {
    let lines: Vec<_> = text
        .split(['\n', '\r'])
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();
    lines.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn details(title: Option<&str>, author: Option<&str>, page_count: u32) -> Details {
        Details {
            title: title.map(str::to_owned),
            author: author.map(str::to_owned),
            page_count,
        }
    }

    #[test]
    fn details_read_back_as_stored() {
        for stored in [
            details(Some("Moby-Dick"), Some("Melville"), 635),
            details(None, None, 0),
            details(Some("Walden"), None, 1),
        ] {
            assert_eq!(decode(&encode(&stored)), Some(stored));
        }
    }

    #[test]
    fn blank_titles_and_authors_are_none_and_surrounding_white_space_goes() {
        let stored = encode(&details(Some(" \t"), Some("  Melville \n"), 3));
        assert_eq!(decode(&stored), Some(details(None, Some("Melville"), 3)));
    }

    #[test]
    fn line_breaks_become_single_spaces() {
        let stored = encode(&details(Some("Moby-Dick;\r\n or, \nThe Whale"), None, 3));
        assert_eq!(
            decode(&stored).unwrap().title.as_deref(),
            Some("Moby-Dick; or, The Whale")
        );
    }

    #[test]
    fn anything_but_stored_details_reads_as_none() {
        for bytes in [&b""[..], b"x\n\n", b"3\ntitle", b"3\na\nb\nc", b"\xff\n\n"] {
            assert_eq!(decode(bytes), None, "{bytes:?}");
        }
    }
}
