import CoreGraphics
import LeafCore

/// Where a Highlight is, in engine-neutral terms (ADR-0003): rectangles per
/// page in PDF page space, in page order, and the whole quoted passage as the
/// fallback.
struct HighlightAnchor: Equatable {
    struct Page: Equatable {
        let pageIndex: Int
        /// Usually one per line of text.
        let rects: [CGRect]
    }

    let pages: [Page]
    let quotedText: String
}

/// A passage of a Document's text marked in a color.
struct Highlight: Identifiable, Equatable {
    let id: String
    let anchor: HighlightAnchor
    var color: RGB
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
        contains { $0.color == color } ? self : self + [HighlightColor(id: "Removed Color", color: color, isCustom: true)]
    }
}

extension RGB {
    init(_ stored: Rgb) { self.init(Double(stored.r) / 255, Double(stored.g) / 255, Double(stored.b) / 255) }
}
