import CoreGraphics
import Foundation
import PDFKit
import Testing

/// An entry of a test PDF's outline: a title, the point on a page it targets
/// (PDF page space, origin bottom-left) and nested entries.
struct OutlineEntry {
    let title: String
    let pageIndex: Int
    let point: CGPoint
    let children: [OutlineEntry]

    init(_ title: String, pageIndex: Int, at point: CGPoint = CGPoint(x: 0, y: 792), children: [OutlineEntry] = []) {
        self.title = title
        self.pageIndex = pageIndex
        self.point = point
        self.children = children
    }

    fileprivate var dictionary: CFDictionary {
        var entry: [CFString: Any] = [
            kCGPDFOutlineTitle: title,
            kCGPDFOutlineDestination: pageIndex + 1,
            kCGPDFOutlineDestinationRect: CGRect(origin: point, size: .zero).dictionaryRepresentation,
        ]
        if !children.isEmpty { entry[kCGPDFOutlineChildren] = children.map(\.dictionary) }
        return entry as CFDictionary
    }
}

/// Writes a PDF with `pageCount` US Letter pages to a fresh temporary directory
/// and returns its URL; the file keeps the given name. `metadataTitle` and
/// `author` are stored in the PDF. With an `outline`, the PDF has a table of
/// contents. `pageLabels` gives the printed number of each page, in order. With `paddedTo`, junk
/// after the end of the PDF makes the file at least that many bytes. Passwords
/// encrypt the PDF: with a `userPassword` it is locked until unlocked; with only
/// an `ownerPassword` it opens freely and just restricts permissions.
func writePDF(
    named fileName: String, metadataTitle: String? = nil, author: String? = nil, pageCount: Int = 1,
    outline: [OutlineEntry] = [], pageLabels: [String] = [],
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
    if !outline.isEmpty {
        CGPDFContextSetOutline(context, [kCGPDFOutlineChildren: outline.map(\.dictionary)] as CFDictionary)
    }
    context.closePDF()
    if !pageLabels.isEmpty { try addPageLabels(pageLabels, toPDFAt: url) }

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
func makePDF(
    named fileName: String, metadataTitle: String? = nil, pageCount: Int = 1,
    outline: [OutlineEntry] = [], pageLabels: [String] = []
) throws -> PDFDocument {
    try #require(
        PDFDocument(
            url: writePDF(
                named: fileName, metadataTitle: metadataTitle, pageCount: pageCount, outline: outline,
                pageLabels: pageLabels)))
}

/// Appends an incremental update to the PDF at `url` that gives page `i` the
/// printed number `labels[i]`. CoreGraphics can't write page labels, so this
/// replaces the catalog, found through the trailer of the plain-text file
/// that CoreGraphics writes.
private func addPageLabels(_ labels: [String], toPDFAt url: URL) throws {
    var pdf = try Data(contentsOf: url)
    let text = String(decoding: pdf, as: UTF8.self)
    func capture(_ pattern: String, in text: String) throws -> String {
        let match = try #require(text.firstMatch(of: try Regex(pattern)))
        return try #require(match.output[1].substring).description
    }
    let tail = String(text.suffix(400))
    let root = try capture(#"/Root (\d+) 0 R"#, in: tail)
    let size = try capture(#"/Size (\d+)"#, in: tail)
    let previous = try capture(#"startxref\s+(\d+)"#, in: tail)
    let catalog = try capture(#"\n\#(root) 0 obj\s*<<(.*?)>>\s*endobj"#, in: text)
    let nums = labels.enumerated().map { "\($0.offset) << /P (\($0.element)) >>" }.joined(separator: " ")

    let catalogOffset = pdf.count
    let object = "\n\(root) 0 obj\n<<\(catalog) /PageLabels << /Nums [\(nums)] >> >>\nendobj\n"
    let xrefOffset = catalogOffset + object.utf8.count
    let entry = String(format: "%010d", catalogOffset + 1)
    let update =
        object + "xref\n\(root) 1\n\(entry) 00000 n \ntrailer\n"
        + "<< /Size \(size) /Root \(root) 0 R /Prev \(previous) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
    pdf.append(Data(update.utf8))
    try pdf.write(to: url)
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
