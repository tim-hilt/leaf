import CoreGraphics
import Foundation
import LeafCore

// The core's records are the app's Highlights, page Notes and colors; this adds
// what Swift needs on top. `RGB` stays the UI's color; the two conversions between
// it and the core's byte color live at the end of this file.

extension Anchor {
    /// The pages of a PDF anchor, in page order; none for another kind.
    var pages: [PageRects] {
        guard case .pdf(let pages) = self else { return [] }
        return pages
    }
}

extension PageRects {
    /// Usually one rectangle per line of text, in PDF page space.
    init(pageIndex: Int, rects: [CGRect]) {
        self.init(pageIndex: UInt32(pageIndex), rects: rects.map(Rect.init))
    }

    var page: Int { Int(pageIndex) }
    var cgRects: [CGRect] { rects.map(\.cgRect) }
}

extension Rect {
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension EpubPosition {
    /// A character of an EPUB's text: a spine item and a UTF-16 offset into its text.
    init(spineIndex: Int, offset: Int) {
        self.init(spineIndex: UInt32(spineIndex), offset: UInt64(offset))
    }

    var spine: Int { Int(spineIndex) }
    var utf16Offset: Int { Int(clamping: offset) }
}

extension Highlight {
    /// The color as the UI draws it.
    var tint: RGB { RGB(color) }
}

extension HighlightColor {
    /// The color as the UI draws it.
    var tint: RGB { RGB(rgb) }

    /// What names the color to VoiceOver.
    var name: String { isCustom ? "Custom Color" : id }
}

extension [HighlightColor] {
    /// These colors, and a last one in `color` unless one is already: a Highlight
    /// keeps its color when its Custom Color is removed, so it still shows.
    func including(_ color: RGB) -> [HighlightColor] {
        contains { $0.tint == color }
            ? self : self + [HighlightColor(id: "Removed Color", rgb: Rgb(color), isCustom: true)]
    }
}

extension RGB {
    /// The color as six hexadecimal digits, `rrggbb`.
    var hex: String { String(format: "%02x%02x%02x", r.colorByte, g.colorByte, b.colorByte) }

    /// The UI color of the core's byte color.
    init(_ stored: Rgb) { self.init(Double(stored.r) / 255, Double(stored.g) / 255, Double(stored.b) / 255) }
}

extension Rgb {
    /// The core's byte color of the UI color.
    init(_ color: RGB) { self.init(r: color.r.colorByte, g: color.g.colorByte, b: color.b.colorByte) }
}

extension Double {
    /// This color component, clamped to 0...1, as a byte.
    fileprivate var colorByte: UInt8 { UInt8((min(max(self, 0), 1) * 255).rounded()) }
}
