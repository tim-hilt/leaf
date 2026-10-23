//! Percent-encoding and -decoding, as URLs and EPUB hrefs use them.

use std::fmt::Write as _;

/// Percent-encodes a path segment or query value: everything but unreserved
/// characters.
pub(crate) fn encode(part: &str) -> String {
    let mut out = String::with_capacity(part.len());
    for byte in part.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char);
            }
            // Writing to a `String` can't fail.
            _ => _ = write!(out, "%{byte:02X}"),
        }
    }
    out
}

/// `text` with each `%XX` escape replaced by its byte. An invalid escape stays
/// as it is, and invalid UTF-8 in the result becomes U+FFFD.
pub(crate) fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let mut byte = [0];
        let escaped = bytes[i] == b'%'
            && bytes
                .get(i + 1..i + 3)
                .is_some_and(|digits| hex::decode_to_slice(digits, &mut byte).is_ok());
        if escaped {
            out.push(byte[0]);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_percent_encoded() {
        assert_eq!(encode("a b/ü"), "a%20b%2F%C3%BC");
        assert_eq!(decode(&encode("x&y='z'")), "x&y='z'");
    }

    #[test]
    fn escapes_become_their_bytes() {
        assert_eq!(decode("a%20b%2Fc%c3%a9"), "a b/cé");
        assert_eq!(decode("plain"), "plain");
    }

    #[test]
    fn invalid_escapes_stay() {
        assert_eq!(decode("100%"), "100%");
        assert_eq!(decode("%zz%4"), "%zz%4");
        assert_eq!(decode("%+f"), "%+f");
    }

    #[test]
    fn invalid_utf8_is_replaced() {
        assert_eq!(decode("%ff"), "\u{fffd}");
    }
}
