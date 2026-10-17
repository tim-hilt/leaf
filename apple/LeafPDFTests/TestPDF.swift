import CoreGraphics
import Foundation
import PDFKit
import Testing

/// Writes a PDF with `pageCount` US Letter pages to a fresh temporary directory
/// and returns its URL; the file keeps the given name. `metadataTitle` and
/// `author` are stored in the PDF. With `paddedTo`, junk
/// after the end of the PDF makes the file at least that many bytes. Passwords
/// encrypt the PDF: with a `userPassword` it is locked until unlocked; with only
/// an `ownerPassword` it opens freely and just restricts permissions.
func writePDF(
    named fileName: String, metadataTitle: String? = nil, author: String? = nil, pageCount: Int = 1,
    paddedTo size: Int = 0, userPassword: String? = nil, ownerPassword: String? = nil
) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: fileName)

    var info: [CFString: Any] = [:]
    if let metadataTitle { info[kCGPDFContextTitle] = metadataTitle }
    if let author { info[kCGPDFContextAuthor] = author }
    if let userPassword { info[kCGPDFContextUserPassword] = userPassword }
    if let ownerPassword { info[kCGPDFContextOwnerPassword] = ownerPassword }
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

/// Writes `bytes` to a file called `fileName` in a fresh temporary directory.
func writeFile(named fileName: String, bytes: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: fileName)
    try bytes.write(to: url)
    return url
}
