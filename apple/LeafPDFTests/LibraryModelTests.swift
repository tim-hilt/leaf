import Foundation
import Testing

@testable import LeafPDF

@MainActor @Suite struct LibraryModelTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    var detailsFile: URL { root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-details.json") }

    var coversFolder: URL { root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-covers") }

    /// Opens the Library at `root`, keeping its saved Titles and Authors in
    /// `detailsFile` and its Covers in `coversFolder`.
    func openLibrary() throws -> LibraryModel {
        try LibraryModel(root: root, detailsFile: detailsFile, coversFolder: coversFolder)
    }

    /// The saved Cover files.
    func savedCovers() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: coversFolder, includingPropertiesForKeys: nil)) ?? []
    }

    @Test func startsEmpty() throws {
        let library = try openLibrary()
        #expect(library.documents.isEmpty)
    }

    @Test func importOpensTheNewDocumentAndListsIt() async throws {
        let library = try openLibrary()
        let source = try writePDF(named: "scan0042.pdf", pageCount: 2)

        let outcome = await library.import(source)

        guard case .opened(let document) = outcome else {
            Issue.record("expected .opened, got \(outcome)")
            return
        }
        #expect(library.documents == [document])
    }

    @Test func aDocumentWithoutStoredTitleShowsItsOriginalFileName() async throws {
        let library = try openLibrary()

        _ = await library.import(try writePDF(named: "scan0042.pdf"))

        #expect(library.documents.first?.title == "scan0042")
    }

    @Test func listsTheNewestImportFirst() async throws {
        let library = try openLibrary()
        _ = await library.import(try writePDF(named: "old.pdf", metadataTitle: "Old"))
        try await Task.sleep(for: .milliseconds(20))
        _ = await library.import(try writePDF(named: "new.pdf", metadataTitle: "New"))

        #expect(library.documents.map(\.title) == ["New", "Old"])
    }

    @Test func importingTheSameContentAgainIsADuplicateOfTheExistingDocument() async throws {
        let library = try openLibrary()
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
        let library = try openLibrary()
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
        let library = try openLibrary()
        let garbage = try writeFile(named: "notes.pdf", bytes: Data("just some text".utf8))

        let outcome = await library.import(garbage)

        guard case .rejected(.notPDF) = outcome else {
            Issue.record("expected .rejected(.notPDF), got \(outcome)")
            return
        }
        #expect(library.documents.isEmpty)
    }

    @Test func aDamagedPDFIsRejectedAsUnreadable() async throws {
        let library = try openLibrary()
        let damaged = try writeFile(named: "damaged.pdf", bytes: Data("%PDF-1.7\nnot really".utf8))

        let outcome = await library.import(damaged)

        guard case .rejected(.unreadable) = outcome else {
            Issue.record("expected .rejected(.unreadable), got \(outcome)")
            return
        }
        #expect(library.documents.isEmpty)
    }

    @Test func aPasswordProtectedPDFIsRejectedAsLockedAndNothingIsCopied() async throws {
        let library = try openLibrary()
        let locked = try writePDF(named: "locked.pdf", userPassword: "secret", ownerPassword: "secret")

        let outcome = await library.import(locked)

        guard case .rejected(.locked) = outcome else {
            Issue.record("expected .rejected(.locked), got \(outcome)")
            return
        }
        #expect(library.documents.isEmpty)
    }

    @Test func aPDFThatOnlyRestrictsPermissionsImportsNormally() async throws {
        let library = try openLibrary()
        let restricted = try writePDF(named: "restricted.pdf", ownerPassword: "owner")

        let outcome = await library.import(restricted)

        guard case .opened = outcome else {
            Issue.record("expected .opened, got \(outcome)")
            return
        }
        #expect(library.documents.count == 1)
    }

    @Test func aRemovedDocumentDisappearsAndCanBeImportedAgain() async throws {
        let library = try openLibrary()
        let source = try writePDF(named: "a.pdf")
        let other = try writePDF(named: "b.pdf")
        guard case .opened(let doomed) = await library.import(source),
            case .opened(let kept) = await library.import(other)
        else {
            Issue.record("expected .opened")
            return
        }

        library.remove(doomed)

        #expect(library.documents == [kept])
        #expect(try openLibrary().documents == [kept])
        guard case .opened(let again) = await library.import(source) else {
            Issue.record("expected the removed File to Import as new")
            return
        }
        #expect(again == doomed)
        #expect(library.documents == [again, kept])
    }

    @Test func reopeningTheLibraryKeepsItsDocuments() async throws {
        _ = await (try openLibrary()).import(try writePDF(named: "a.pdf"))

        #expect(try openLibrary().documents.count == 1)
    }

    @Test func importSavesTheTitleFileNameAndAuthor() async throws {
        let library = try openLibrary()

        _ = await library.import(try writePDF(named: "scan0042.pdf", metadataTitle: "Moby-Dick", author: "Melville"))

        let document = try #require(library.documents.first)
        #expect(document.title == "Moby-Dick")
        #expect(document.fileName == "scan0042.pdf")
        #expect(document.author == "Melville")
    }

    @Test func aPDFWithoutTitleOrAuthorShowsItsFileNameAndNoAuthor() async throws {
        let library = try openLibrary()

        _ = await library.import(try writePDF(named: "scan0042.pdf"))

        let document = try #require(library.documents.first)
        #expect(document.title == "scan0042")
        #expect(document.author == nil)
    }

    @Test func aDocumentExposesItsStoredFile() async throws {
        let library = try openLibrary()

        _ = await library.import(try writePDF(named: "a.pdf"))

        let document = try #require(library.documents.first)
        #expect(FileManager.default.fileExists(atPath: document.file.path))
        #expect(document.file.lastPathComponent == "a.pdf")
    }

    @Test func titlesAndAuthorsSurviveReopeningTheLibrary() async throws {
        _ = await (try openLibrary()).import(try writePDF(named: "a.pdf", metadataTitle: "Moby-Dick", author: "Melville"))

        let document = try #require(try openLibrary().documents.first)

        #expect(document.title == "Moby-Dick")
        #expect(document.author == "Melville")
    }

    @Test func missingSavedTitlesShowFileNamesFirstAndTitlesAfterTheBackgroundPass() async throws {
        _ = await (try openLibrary()).import(try writePDF(named: "scan0042.pdf", metadataTitle: "Moby-Dick", author: "Melville"))
        try FileManager.default.removeItem(at: detailsFile)

        let library = try openLibrary()
        #expect(library.documents.map(\.title) == ["scan0042"])
        #expect(library.documents.first?.author == nil)

        try await waitUntil { library.documents.first?.title == "Moby-Dick" }
        #expect(library.documents.first?.author == "Melville")
        // Saved, so the next launch has them at once.
        #expect(try openLibrary().documents.first?.title == "Moby-Dick")
    }

    @Test func removeDeletesTheSavedTitleAndAuthor() async throws {
        let library = try openLibrary()
        let source = try writePDF(named: "a.pdf", metadataTitle: "Moby-Dick", author: "Melville")
        guard case .opened(let document) = await library.import(source) else {
            Issue.record("expected .opened")
            return
        }

        library.remove(document)

        let details = try JSONDecoder().decode([String: DocumentDetails].self, from: Data(contentsOf: detailsFile))
        #expect(details.isEmpty)
        guard case .opened(let again) = await library.import(try writePDF(named: "b.pdf")) else {
            Issue.record("expected .opened")
            return
        }
        #expect(again.author == nil)
    }

    @Test func openingTheLibraryOpensNoPDFs() throws {
        // A File PDFKit can't open still lists, by its file name: the Library never looks inside it.
        let folder = root.appending(path: String(repeating: "a", count: 64), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a PDF".utf8).write(to: folder.appending(path: "broken.pdf"))

        let library = try openLibrary()

        #expect(library.documents.map(\.title) == ["broken"])
    }

    @Test func aCoverIsAvailableAfterImportWithoutRendering() async throws {
        let library = try openLibrary()
        guard case .opened(let document) = await library.import(try writePDF(named: "a.pdf")) else {
            Issue.record("expected .opened")
            return
        }
        #expect(savedCovers().count == 1)
        // Without its File, the Cover can only come from the saved copy.
        try FileManager.default.removeItem(at: document.file)

        let cover = try #require(await library.cover(for: document))

        // US Letter, rendered 300 pt wide.
        #expect(abs(Double(cover.height) / Double(cover.width) - 792.0 / 612.0) < 0.01)
        #expect(cover.width >= 300)
    }

    @Test func aCoverIsRenderedAgainAfterItsSavedCopyIsDeleted() async throws {
        let library = try openLibrary()
        guard case .opened(let document) = await library.import(try writePDF(named: "a.pdf")) else {
            Issue.record("expected .opened")
            return
        }
        try FileManager.default.removeItem(at: coversFolder)

        #expect(await library.cover(for: document) != nil)
        #expect(savedCovers().count == 1)
    }

    @Test func aSavedCoverIsLoadedWithoutRenderingAMissingOne() async throws {
        let library = try openLibrary()
        guard case .opened(let document) = await library.import(try writePDF(named: "a.pdf")) else {
            Issue.record("expected .opened")
            return
        }
        #expect(await library.savedCover(for: document) != nil)

        try FileManager.default.removeItem(at: coversFolder)

        #expect(await library.savedCover(for: document) == nil)
        #expect(savedCovers().isEmpty)
    }

    @Test func aSavedCoverSurvivesReopeningTheLibrary() async throws {
        guard case .opened(let document) = await (try openLibrary()).import(try writePDF(named: "a.pdf")) else {
            Issue.record("expected .opened")
            return
        }
        try FileManager.default.removeItem(at: document.file)

        #expect(await (try openLibrary()).cover(for: document) != nil)
    }

    @Test func removeDeletesTheSavedCover() async throws {
        let library = try openLibrary()
        guard case .opened(let document) = await library.import(try writePDF(named: "a.pdf")) else {
            Issue.record("expected .opened")
            return
        }

        library.remove(document)

        #expect(savedCovers().isEmpty)
    }

    @Test func aRunningImportShowsTheTitleAndProgressUntilItFinishes() async throws {
        let library = try openLibrary()
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
        #expect(seen.last?.title == "Big One")
        #expect(seen.allSatisfy { (0...1).contains($0.fraction) })
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        #expect(library.runningImport == nil)
    }

    /// Waits up to 10 s for `condition`, which the background pass makes true.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
