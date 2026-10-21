import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The Cover of an EPUB as an image `pixelWidth` wide at most, in the shape of
/// a Gallery cell (A4 portrait) at most. Both are on an opaque white
/// background, so they save as JPEG.
enum EPUBCover {
    private static let aspect: CGFloat = 1.414

    /// The cover image `data` the EPUB declares, scaled down to fit; nil if it can't be decoded.
    static func image(from data: Data, pixelWidth: CGFloat) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat, width > 0,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, height > 0
        else { return nil }
        let scale = min(1, pixelWidth / width, pixelWidth * aspect / height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: (max(width, height) * scale).rounded(.up),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return draw(width: scaled.width, height: scaled.height) { context in
            context.draw(scaled, in: CGRect(x: 0, y: 0, width: scaled.width, height: scaled.height))
        }
    }

    /// A plain Cover with the `title` and, if there is one, the `author`, centered.
    static func plain(title: String, author: String?, pixelWidth: CGFloat) -> CGImage? {
        let width = pixelWidth.rounded()
        let height = (pixelWidth * aspect).rounded()
        let margin = width / 8
        return draw(width: Int(width), height: Int(height)) { context in
            let inner = width - 2 * margin
            var lines = [text(title, size: width / 11, bold: true, gray: 0.1, width: inner, maxHeight: height * 0.6)]
            if let author { lines.append(text(author, size: width / 17, bold: false, gray: 0.4, width: inner)) }
            let gap = width / 20
            var top = (height + lines.map(\.height).reduce(0, +) + gap * CGFloat(lines.count - 1)) / 2
            for line in lines {
                top -= line.height
                context.saveGState()
                context.translateBy(x: margin, y: top)
                CTFrameDraw(line.frame, context)
                context.restoreGState()
                top -= gap
            }
        }
    }

    /// An opaque white bitmap, with what `content` draws on it.
    private static func draw(width: Int, height: Int, _ content: (CGContext) -> Void) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        content(context)
        return context.makeImage()
    }

    /// `string` set in Helvetica, centered, `width` wide and cut off at `maxHeight`.
    private static func text(
        _ string: String, size: CGFloat, bold: Bool, gray: CGFloat, width: CGFloat, maxHeight: CGFloat = .infinity
    ) -> Text {
        var alignment = CTTextAlignment.center
        let style = withUnsafeMutablePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let height = min(ceil(fitted.height), maxHeight)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        return Text(frame: CTFramesetterCreateFrame(setter, CFRange(), path, nil), height: height)
    }

    /// Laid out text and the height it takes.
    private struct Text {
        let frame: CTFrame
        let height: CGFloat
    }
}
