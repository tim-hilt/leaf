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

/// One of the Highlight Colors to choose from. The name identifies it.
struct HighlightColor: Identifiable, Equatable, Sendable {
    let name: String
    let color: RGB

    var id: String { name }
}

extension HighlightColor {
    init(_ stored: BuiltInColor) { self.init(name: stored.name, color: RGB(stored.rgb)) }
}

extension RGB {
    init(_ stored: Rgb) { self.init(Double(stored.r) / 255, Double(stored.g) / 255, Double(stored.b) / 255) }
}
