import Foundation
import Testing

@testable import LeafPDF

@MainActor @Suite struct LibraryModelTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    @Test func startsEmpty() throws {
        let library = try LibraryModel(root: root)
        #expect(library.documents.isEmpty)
    }

    @Test func importOpensTheNewDocumentAndListsIt() async throws {
        let library = try LibraryModel(root: root)
        let source = try writePDF(named: "scan0042.pdf", pageCount: 2)

        let outcome = await library.import(source)

        guard case .opened(let document) = outcome else {
            Issue.record("expected .opened, got \(outcome)")
            return
        }
        #expect(library.documents == [document])
        #expect(document.pdf.pageCount == 2)
    }

    @Test func aDocumentWithoutStoredTitleShowsItsOriginalFileName() async throws {
        let library = try LibraryModel(root: root)

        _ = await library.import(try writePDF(named: "scan0042.pdf"))

        #expect(library.documents.first?.title == "scan0042")
    }

    @Test func listsTheNewestImportFirst() async throws {
        let library = try LibraryModel(root: root)
        _ = await library.import(try writePDF(named: "old.pdf", metadataTitle: "Old"))
        try await Task.sleep(for: .milliseconds(20))
        _ = await library.import(try writePDF(named: "new.pdf", metadataTitle: "New"))

        #expect(library.documents.map(\.title) == ["New", "Old"])
    }

    @Test func importingAMissingFileFails() async throws {
        let library = try LibraryModel(root: root)
        let missing = root.appending(path: "missing.pdf")

        let outcome = await library.import(missing)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(library.documents.isEmpty)
    }

    @Test func reopeningTheLibraryKeepsItsDocuments() async throws {
        _ = await (try LibraryModel(root: root)).import(try writePDF(named: "a.pdf"))

        #expect(try LibraryModel(root: root).documents.count == 1)
    }
}
