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

    @Test func importingTheSameContentAgainIsADuplicateOfTheExistingDocument() async throws {
        let library = try LibraryModel(root: root)
        let source = try writePDF(named: "a.pdf")
        guard case .opened(let first) = await library.import(source) else {
            Issue.record("expected .opened")
            return
        }
        // Generated PDFs differ on every write, so copy the same bytes under another name.
        let renamed = source.deletingLastPathComponent().appending(path: "renamed.pdf")
        try FileManager.default.copyItem(at: source, to: renamed)

        let outcome = await library.import(renamed)

        guard case .duplicate(let existing) = outcome else {
            Issue.record("expected .duplicate, got \(outcome)")
            return
        }
        #expect(existing == first)
        #expect(library.documents == [first])
    }

    @Test func importingAMissingFileFailsWithTheSystemsReason() async throws {
        let library = try LibraryModel(root: root)
        let missing = root.appending(path: "missing.pdf")

        let outcome = await library.import(missing)

        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("no such file"))
        #expect(library.documents.isEmpty)
    }

    @Test func garbageBytesAreRejectedAsNotAPDFAndNothingIsCopied() async throws {
        let library = try LibraryModel(root: root)
        let garbage = try writeFile(named: "notes.pdf", bytes: Data("just some text".utf8))

        let outcome = await library.import(garbage)

        guard case .rejected(.notPDF) = outcome else {
            Issue.record("expected .rejected(.notPDF), got \(outcome)")
            return
        }
        #expect(library.documents.isEmpty)
    }

    @Test func aDamagedPDFIsRejectedAsUnreadable() async throws {
        let library = try LibraryModel(root: root)
        let damaged = try writeFile(named: "damaged.pdf", bytes: Data("%PDF-1.7\nnot really".utf8))

        let outcome = await library.import(damaged)

        guard case .rejected(.unreadable) = outcome else {
            Issue.record("expected .rejected(.unreadable), got \(outcome)")
            return
        }
        #expect(library.documents.isEmpty)
    }

    @Test func aPasswordProtectedPDFIsRejectedAsLockedAndNothingIsCopied() async throws {
        let library = try LibraryModel(root: root)
        let locked = try writePDF(named: "locked.pdf", userPassword: "secret", ownerPassword: "secret")

        let outcome = await library.import(locked)

        guard case .rejected(.locked) = outcome else {
            Issue.record("expected .rejected(.locked), got \(outcome)")
            return
        }
        #expect(library.documents.isEmpty)
    }

    @Test func aPDFThatOnlyRestrictsPermissionsImportsNormally() async throws {
        let library = try LibraryModel(root: root)
        let restricted = try writePDF(named: "restricted.pdf", ownerPassword: "owner")

        let outcome = await library.import(restricted)

        guard case .opened = outcome else {
            Issue.record("expected .opened, got \(outcome)")
            return
        }
        #expect(library.documents.count == 1)
    }

    @Test func reopeningTheLibraryKeepsItsDocuments() async throws {
        _ = await (try LibraryModel(root: root)).import(try writePDF(named: "a.pdf"))

        #expect(try LibraryModel(root: root).documents.count == 1)
    }

    @Test func aRunningImportShowsTheTitleAndProgressUntilItFinishes() async throws {
        let library = try LibraryModel(root: root)
        let source = try writePDF(named: "big.pdf", metadataTitle: "Big One", paddedTo: 64_000_000)
        #expect(library.runningImport == nil)

        let importing = Task { @MainActor in _ = await library.import(source) }
        var seen: [RunningImport] = []
        while seen.last?.fraction ?? 0 < 1 {
            if let running = library.runningImport { seen.append(running) }
            if library.runningImport == nil, !seen.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await importing.value

        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0.title == "Big One" && (0...1).contains($0.fraction) })
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        #expect(library.runningImport == nil)
    }
}
