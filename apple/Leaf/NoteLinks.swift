import Foundation

/// How a Note is shown: its text with the web links in it clickable. Links are
/// found when it is shown and never stored.
enum NoteLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// `note` as it is, with `http` and `https` links as links.
    static func attributed(_ note: String) -> AttributedString {
        var shown = AttributedString(note)
        let matches = detector?.matches(in: note, range: NSRange(note.startIndex..., in: note)) ?? []
        for match in matches {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()),
                let range = Range(match.range, in: shown)
            else { continue }
            shown[range].link = url
        }
        return shown
    }
}
