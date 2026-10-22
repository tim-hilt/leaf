import CoreGraphics
import Foundation
import LeafCore

/// Where a Highlight is, in the terms of its Document's Format: for a PDF,
/// rectangles per page in PDF page space, in page order (ADR-0003); for an EPUB,
/// the characters from one position up to another in the core's text (ADR-0022).
/// The whole quoted passage is the fallback of both.
struct HighlightAnchor: Equatable {
    struct Page: Equatable {
        let pageIndex: Int
        /// Usually one per line of text.
        let rects: [CGRect]
    }

    /// A character of an EPUB's text: a spine item and a UTF-16 offset into its text.
    struct Position: Equatable {
        let spineIndex: Int
        let offset: Int
    }

    /// The characters from `start` up to, not including, `end`; they may be in different spine items.
    struct Span: Equatable {
        let start: Position
        let end: Position
    }

    enum Location: Equatable {
        case pdf(pages: [Page])
        case epub(Span)
    }

    let location: Location
    /// The whole passage; for an EPUB the spine items' texts are joined by a line feed.
    let quotedText: String

    init(location: Location, quotedText: String) {
        self.location = location
        self.quotedText = quotedText
    }

    init(pages: [Page], quotedText: String) {
        self.init(location: .pdf(pages: pages), quotedText: quotedText)
    }

    /// The pages of a PDF anchor; none for another kind.
    var pages: [Page] {
        guard case .pdf(let pages) = location else { return [] }
        return pages
    }
}

/// A passage of a Document's text marked in a color.
struct Highlight: Identifiable, Equatable {
    let id: String
    let anchor: HighlightAnchor
    var color: RGB
    /// What the reader wrote about the passage; nil if nothing, never empty.
    var note: String?
}

/// A color to highlight in: a built-in one, or a Custom Color of the user.
/// The id identifies it: a built-in color's name, or a Custom Color's ID.
struct HighlightColor: Identifiable, Equatable, Sendable {
    let id: String
    let color: RGB
    let isCustom: Bool

    /// What names the color to VoiceOver.
    var name: String { isCustom ? "Custom Color" : id }
}

extension HighlightColor {
    init(_ stored: LeafCore.HighlightColor) {
        self.init(id: stored.id, color: RGB(stored.rgb), isCustom: stored.isCustom)
    }
}

extension [HighlightColor] {
    /// These colors, and a last one in `color` unless one is already: a Highlight
    /// keeps its color when its Custom Color is removed, so it still shows.
    func including(_ color: RGB) -> [HighlightColor] {
        contains { $0.color == color }
            ? self : self + [HighlightColor(id: "Removed Color", color: color, isCustom: true)]
    }
}

extension RGB {
    /// The color as six hexadecimal digits, `rrggbb`.
    var hex: String {
        let byte = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    init(_ stored: Rgb) { self.init(Double(stored.r) / 255, Double(stored.g) / 255, Double(stored.b) / 255) }
}
