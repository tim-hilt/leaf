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
