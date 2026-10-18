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

    /// Nil unless `components` holds exactly the six values of `components`.
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
}

/// A `PDFDocument` whose pages can be drawn as Dark Pages. Only what is drawn
/// changes, never the File, and overlays PDFKit draws on top of the page
/// (search highlights, the selection) keep their colors. Changing
/// `appearance` affects pages drawn from then on; a `PDFView` showing the
/// Document redraws with `layoutDocumentView()` (ADR-0013).
final class StyledDocument: PDFDocument, PDFDocumentDelegate {
    private let current = Mutex(PageAppearance.light)

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
        guard case .dark(let colors) = (document as? StyledDocument)?.appearance else {
            return super.draw(with: box, to: context)
        }
        // The area being drawn, in the same space PDFKit draws the page in.
        var area = context.boundingBoxOfClipPath
        if area.isInfinite || area.isNull { area = bounds(for: box) }
        area = area.integral
        let scale = hypot(context.ctm.a, context.ctm.b)
        let size = CGSize(width: ceil(area.width * scale), height: ceil(area.height * scale))
        guard size.width >= 1, size.height >= 1,
            let bitmap = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: .sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return super.draw(with: box, to: context) }

        bitmap.scaleBy(x: size.width / area.width, y: size.height / area.height)
        bitmap.translateBy(x: -area.minX, y: -area.minY)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(area)
        super.draw(with: box, to: bitmap)
        guard let original = bitmap.makeImage(), let reversed = Self.reverse(original, in: colors) else { return }
        context.draw(reversed, in: area)
    }

    /// No color management: the matrix below mixes the colors as they are, not in linear light.
    private static let core = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// Inverts, then rotates the hue by half a turn to bring the colors back
    /// (grays stay gray), then maps black to the paper and white to the ink.
    private static func reverse(_ image: CGImage, in colors: PageColors) -> CGImage? {
        let (paper, ink) = (colors.paper, colors.ink)
        let mapped = CIImage(cgImage: image)
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
        return core.createCGImage(mapped, from: mapped.extent, format: .RGBA8, colorSpace: .sRGB)
    }
}

extension PDFPage {
    /// The whole page, as it is drawn in its document, `pixelWidth` pixels
    /// wide. Nil if the page has no size.
    func image(pixelWidth: Int) -> CGImage? {
        let box = bounds(for: .cropBox)
        guard box.width > 0, box.height > 0, pixelWidth > 0 else { return nil }
        let scale = CGFloat(pixelWidth) / box.width
        guard
            let context = CGContext(
                data: nil, width: pixelWidth, height: Int((box.height * scale).rounded()), bitsPerComponent: 8,
                bytesPerRow: 0, space: .sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(box)
        context.clip(to: box)
        draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}

extension CGColorSpace {
    fileprivate static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
}
