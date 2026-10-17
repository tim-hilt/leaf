import CoreGraphics
import Foundation
import PDFKit
import Testing

/// Writes a PDF with `pageCount` US Letter pages to a fresh temporary directory
/// and returns its URL; the file keeps the given name. With `paddedTo`, junk
/// after the end of the PDF makes the file at least that many bytes.
func writePDF(
    named fileName: String, metadataTitle: String? = nil, pageCount: Int = 1, paddedTo size: Int = 0
) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: fileName)

    var info: [CFString: Any] = [:]
    if let metadataTitle { info[kCGPDFContextTitle] = metadataTitle }
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
    for _ in 0..<pageCount {
        context.beginPDFPage(nil)
        context.endPDFPage()
    }
    context.closePDF()

    let padding = size - (try Data(contentsOf: url).count)
    if padding > 0 {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: padding))
    }
    return url
}

/// Like `writePDF`, loaded from there so the document knows its file name like
/// an imported Document does.
func makePDF(named fileName: String, metadataTitle: String? = nil, pageCount: Int = 1) throws -> PDFDocument {
    try #require(PDFDocument(url: writePDF(named: fileName, metadataTitle: metadataTitle, pageCount: pageCount)))
}
