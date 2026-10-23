import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a reflowable EPUB with one chapter to a fresh temporary directory and
/// returns its URL; the file keeps the given name. `chapters` are the bodies of
/// its spine items, in order; `body` is the only one by default. `metadata` goes
/// inside the package's `<metadata>`, `manifest` into its `<manifest>`; `files`
/// are more entries of the zip, by path.
func writeEPUB(
    named fileName: String, title: String? = nil, author: String? = nil, body: String = "<p>Hello</p>",
    chapters: [String]? = nil, metadata: String = "", manifest: String = "", files: [String: Data] = [:],
    doctype: String = ""
) throws -> URL {
    let chapters = chapters ?? [body]
    var details = metadata
    if let title { details += "<dc:title>\(title)</dc:title>" }
    if let author { details += "<dc:creator>\(author)</dc:creator>" }
    let container = """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>\
        </container>
        """
    let package = """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">\
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\(details)</metadata>\
        <manifest>\(chapters.indices.map { #"<item id="c\#($0)" href="chapter\#($0).xhtml" media-type="application/xhtml+xml"/>"# }.joined())\(manifest)</manifest>\
        <spine>\(chapters.indices.map { #"<itemref idref="c\#($0)"/>"# }.joined())</spine></package>
        """
    var entries: [(String, Data)] = [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", Data(container.utf8)),
        ("OEBPS/content.opf", Data(package.utf8)),
    ]
    for (index, body) in chapters.enumerated() {
        let chapter = """
            <?xml version="1.0"?>\(doctype)<html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title></head>\
            <body>\(body)</body></html>
            """
        entries.append(("OEBPS/chapter\(index).xhtml", Data(chapter.utf8)))
    }
    entries += files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    return try writeFile(named: fileName, bytes: zip(entries))
}

/// A zip of `entries`, stored without compression or checksums, which the core doesn't check.
func zip(_ entries: [(name: String, content: Data)]) -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    var body = Data()
    var directory = Data()
    for (name, content) in entries {
        let name = Data(name.utf8)
        let common =
            le(UInt16(0)) + Data(count: 8) + le(UInt32(content.count)) + le(UInt32(content.count))
            + le(UInt16(name.count)) + le(UInt16(0))
        directory +=
            Data("PK\u{1}\u{2}".utf8) + Data([20, 0, 20, 0, 0, 0]) + common + Data(count: 10)
            + le(UInt32(body.count)) + name
        body += Data("PK\u{3}\u{4}".utf8) + Data([20, 0, 0, 0]) + common + name + content
    }
    return body + directory + Data("PK\u{5}\u{6}".utf8) + Data(count: 4) + le(UInt16(entries.count))
        + le(UInt16(entries.count)) + le(UInt32(directory.count)) + le(UInt32(body.count)) + Data(count: 2)
}

/// A PNG of one `color`, `width` × `height` pixels.
func solidPNG(red: UInt8, green: UInt8, blue: UInt8, width: Int = 40, height: Int = 60) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(
        CGColor(
            srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

extension CGImage {
    /// Whether any pixel is dark: there is text on a white page.
    var hasInk: Bool {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] < 100 }
    }

    /// The color at the center, as red, green and blue bytes.
    var centerPixel: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(self, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return Array(bytes[0..<3])
    }
}
