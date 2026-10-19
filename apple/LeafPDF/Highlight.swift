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

    /// The built-in Highlight Colors from the core, yellow first.
    static let builtInColors: [(name: String, color: RGB)] = LeafCore.builtInColors().map { ($0.name, RGB($0.rgb)) }

    /// The color of new Highlights: yellow, until the Default Highlight Color
    /// is a setting.
    static let defaultColor = builtInColors[0].color
}

extension RGB {
    init(_ stored: Rgb) { self.init(Double(stored.r) / 255, Double(stored.g) / 255, Double(stored.b) / 255) }
}
