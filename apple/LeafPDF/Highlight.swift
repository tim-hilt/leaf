import CoreGraphics

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
    let color: RGB

    /// The color of new Highlights: yellow, until the Default Highlight Color
    /// is a setting.
    static let defaultColor = RGB(1, 235 / 255, 60 / 255)
}
