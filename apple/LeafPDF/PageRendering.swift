import CoreImage
import PDFKit
import Synchronization

/// A color, as red, green and blue from 0 to 1, in sRGB.
struct RGB: Equatable, Sendable {
    let r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { (self.r, self.g, self.b) = (r, g, b) }
}

/// The colors of Dark Pages: the paper that white turns into and the ink that
/// black turns into.
struct PageColors: Equatable, Sendable {
    var paper: RGB
    var ink: RGB

    static let `default` = PageColors(
        paper: RGB(0x1E / 255, 0x1E / 255, 0x1E / 255), ink: RGB(0xD6 / 255, 0xD6 / 255, 0xD6 / 255))

    /// Paper then ink, as red, green and blue each: the form saved in user defaults.
    var components: [Double] { [paper.r, paper.g, paper.b, ink.r, ink.g, ink.b] }

    /// Nil unless `c` holds six values from 0 to 1, in the order of `components`.
    init?(components c: [Double]) {
        guard c.count == 6, c.allSatisfy({ (0...1).contains($0) }) else { return nil }
        self.init(paper: RGB(c[0], c[1], c[2]), ink: RGB(c[3], c[4], c[5]))
    }

    init(paper: RGB, ink: RGB) { (self.paper, self.ink) = (paper, ink) }
}

/// How pages are drawn: as they are in the File (Light Pages), or with their
/// brightness reversed and hue kept, in Page Colors (Dark Pages).
enum PageAppearance: Equatable, Sendable {
    case light
    case dark(PageColors)

    /// The color of a page with nothing on it: white, or the paper.
    var paper: RGB {
        switch self {
        case .light: RGB(1, 1, 1)
        case .dark(let colors): colors.paper
        }
    }
}

/// A `PDFDocument` whose pages can be drawn as Dark Pages, with Highlights
/// drawn into them. Only what is drawn changes, never the File, and overlays
/// PDFKit draws on top of the page (search highlights, the selection) keep
/// their colors. Changing `appearance` or `highlights` affects pages drawn
/// from then on; `ReaderPDFView` redraws its pages when they change (ADR-0013).
final class StyledDocument: PDFDocument, PDFDocumentDelegate {
    /// A Highlight's rectangle on a page, in PDF page space.
    fileprivate struct Mark: Sendable {
        let rect: CGRect
        let color: RGB
    }

    private let current = Mutex(PageAppearance.light)
    private let marks = Mutex([Int: [Mark]]())

    /// The Highlights drawn into the pages, each over its rectangles. Safe to
    /// read and set from any thread: PDFKit draws pages on background threads.
    var highlights: [Highlight] = [] {
        didSet {
            var byPage: [Int: [Mark]] = [:]
            for highlight in highlights {
                for page in highlight.anchor.pages {
                    byPage[page.pageIndex, default: []] += page.rects.map { Mark(rect: $0, color: highlight.color) }
                }
            }
            marks.withLock { $0 = byPage }
        }
    }

    /// The Highlights' rectangles on `page`. Pages without any cost no lookup of their index.
    fileprivate func marks(on page: PDFPage) -> [Mark] {
        guard !marks.withLock({ $0.isEmpty }) else { return [] }
        let index = index(for: page)
        return marks.withLock { $0[index] ?? [] }
    }

    /// Safe to read from any thread: PDFKit draws pages on background threads.
    var appearance: PageAppearance {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    override init?(url: URL) {
        super.init(url: url)
        delegate = self
    }

    func classForPage() -> AnyClass { StyledPage.self }
}

/// Draws itself in its `StyledDocument`'s appearance. Holds no state of its
/// own: PDFKit creates it without running Swift initializers.
private final class StyledPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let styled = document as? StyledDocument
        let marks = styled?.marks(on: self) ?? []
        guard case .dark(let colors) = styled?.appearance else {
            super.draw(with: box, to: context)
            return paint(marks, in: context, box: box)
        }
        // The part of the page being drawn, in the context's space. Like
        // `super`, never paint outside the page (rotated and cropped).
        let page = bounds(for: box).applying(transform(for: box))
        let area = context.boundingBoxOfClipPath.intersection(page).integral
        let scale = hypot(context.ctm.a, context.ctm.b)
        let size = CGSize(width: ceil(area.width * scale), height: ceil(area.height * scale))
        guard size.width >= 1, size.height >= 1,
            let bitmap = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: .sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            super.draw(with: box, to: context)
            return paint(marks, in: context, box: box)
        }

        bitmap.scaleBy(x: size.width / area.width, y: size.height / area.height)
        bitmap.translateBy(x: -area.minX, y: -area.minY)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(area)
        super.draw(with: box, to: bitmap)
        // Highlights are part of the page, so they are reversed with it.
        paint(marks, in: bitmap, box: box)
        guard let original = bitmap.makeImage(), let reversed = original.reversed(in: colors) else { return }
        context.draw(reversed, in: area)
    }

    /// Multiplies the Highlights' colors into what is drawn, so text on them
    /// stays as dark as it was.
    fileprivate func paint(_ marks: [StyledDocument.Mark], in context: CGContext, box: PDFDisplayBox) {
        guard !marks.isEmpty else { return }
        let transform = transform(for: box)
        context.saveGState()
        context.setBlendMode(.multiply)
        for mark in marks {
            context.setFillColor(CGColor(srgbRed: mark.color.r, green: mark.color.g, blue: mark.color.b, alpha: 1))
            context.fill(mark.rect.applying(transform))
        }
        context.restoreGState()
    }
}

extension CGImage {
    /// No color management: the matrix below mixes the colors as they are, not in linear light.
    private static let core = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// Inverts, then rotates the hue by half a turn to bring the colors back
    /// (grays stay gray), then maps black to the paper and white to the ink.
    fileprivate func reversed(in colors: PageColors) -> CGImage? {
        let (paper, ink) = (colors.paper, colors.ink)
        let mapped = CIImage(cgImage: self)
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: ink.r - paper.r, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: ink.g - paper.g, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: ink.b - paper.b, w: 0),
                    "inputBiasVector": CIVector(x: paper.r, y: paper.g, z: paper.b, w: 0),
                ])
        return Self.core.createCGImage(mapped, from: mapped.extent, format: .RGBA8, colorSpace: .sRGB)
    }
}

extension CGColorSpace {
    fileprivate static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
}
