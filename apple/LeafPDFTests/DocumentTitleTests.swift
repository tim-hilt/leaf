import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import LeafPDF

@Suite struct DocumentTitleTests {
    @Test func usesTheTitleStoredInThePDF() throws {
        let document = try makePDF(named: "scan0042.pdf", metadataTitle: "Moby-Dick")
        #expect(document.title == "Moby-Dick")
    }

    @Test func fallsBackToTheFileNameWithoutExtension() throws {
        let document = try makePDF(named: "scan0042.pdf", metadataTitle: nil)
        #expect(document.title == "scan0042")
    }

    @Test func treatsABlankPDFTitleAsMissing() throws {
        let document = try makePDF(named: "scan0042.pdf", metadataTitle: "  ")
        #expect(document.title == "scan0042")
    }
}

/// Writes a one-page PDF to a fresh temporary directory and loads it from there,
/// so the returned document knows its file name like an imported Document does.
private func makePDF(named fileName: String, metadataTitle: String?) throws -> PDFDocument {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: fileName)

    var info: [CFString: Any] = [:]
    if let metadataTitle { info[kCGPDFContextTitle] = metadataTitle }
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()

    return try #require(PDFDocument(url: url))
}
