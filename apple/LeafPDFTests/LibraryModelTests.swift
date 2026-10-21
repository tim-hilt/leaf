import Foundation
import LeafCore
import Testing
import UniformTypeIdentifiers

@testable import LeafPDF

@MainActor @Suite struct LibraryModelTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    var coversFolder: URL { root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-covers") }

    /// This device's user defaults, as far as the Library is concerned: one
    /// suite per test, so tests don't see each other's sort choice.
    var defaults: UserDefaults { UserDefaults(suiteName: root.lastPathComponent)! }

    /// This device's Cloud Backing credentials: the Keychain item is per test too.
    var credentials: CloudCredentials {
        CloudCredentials(defaults: defaults, service: "leafpdf-test-\(root.lastPathComponent)")
    }

    /// Opens the Library at `root`, keeping its Covers in `coversFolder`, its
    /// sort choice in `defaults` and its Cloud Backing credentials in `credentials`.
    func openLibrary(
        syncIntervals: SyncIntervals = .standard, inbox: URL? = nil
    ) throws -> LibraryModel {
        try LibraryModel(
            root: root, coversFolder: coversFolder, defaults: defaults,
            credentials: credentials, syncIntervals: syncIntervals, inbox: inbox)
    }

    /// Imports a PDF with the given Title, oldest first when called in sequence.
    func importPDF(titled title: String, into library: LibraryModel) async throws {
        _ = await library.import(try writePDF(named: "\(UUID().uuidString).pdf", metadataTitle: title))
        try await Task.sleep(for: .milliseconds(20))
    }

    /// Imports `source` into the Library at `root` the way an older LeafPDF
    /// left it: without details, so a Library opened next lists it by file
    /// name until its background pass reads them. Call it before `openLibrary`.
    func importWithoutDetails(_ source: URL) throws {
        _ = try LeafCore.Library.open(root: root.path).import(source: source.path, progress: NoProgress())
    }

    private final class NoProgress: ImportProgress {
        func report(copied: UInt64, total: UInt64) {}
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

    // MARK: Importing from outside

    @Test(arguments: [ImportOrigin.openWithOrShare, .drop, .picker])
    func oneNewFileOpensItsDocument(origin: ImportOrigin) async throws {
        let library = try openLibrary()

        let result = await library.importFiles([try writePDF(named: "a.pdf")], from: origin)

        guard case .open(let documents, let problems) = result else {
            Issue.record("expected .open, got \(result)")
            return
        }
        #expect(documents == library.documents)
        #expect(documents.count == 1)
        #expect(problems.isEmpty)
    }

    @Test(arguments: [ImportOrigin.openWithOrShare, .drop, .picker])
    func oneDuplicateFileIsHandledPerOrigin(origin: ImportOrigin) async throws {
        let library = try openLibrary()
        let source = try writePDF(named: "a.pdf")
        let first = await library.importFiles([source], from: .picker)
        guard case .open(let opened, _) = first, let existing = opened.first else {
            Issue.record("expected .open")
            return
        }
        let renamed = source.deletingLastPathComponent().appending(path: "renamed.pdf")
        try FileManager.default.copyItem(at: source, to: renamed)

        let result = await library.importFiles([renamed], from: origin)

        switch (origin, result) {
        case (.openWithOrShare, .open(let documents, let problems)):
            #expect(documents == [existing])
            #expect(problems.isEmpty)
        case (.drop, .alreadyInLibrary(let document)), (.picker, .alreadyInLibrary(let document)):
            #expect(document == existing)
        default:
            Issue.record("unexpected \(result) for \(origin)")
        }
        #expect(library.documents == [existing])
    }

    @Test func oneRejectedFileIsReportedAsAProblemAndNothingIsCopied() async throws {
        let library = try openLibrary()
        let garbage = try writeFile(named: "notes.pdf", bytes: Data("just some text".utf8))

        let result = await library.importFiles([garbage], from: .openWithOrShare)

        guard case .problems(let problems) = result, problems.count == 1 else {
            Issue.record("expected one problem, got \(result)")
            return
        }
        #expect(problems[0].file == garbage)
        guard case .rejected(.notPDF) = problems[0].failure else {
            Issue.record("expected .rejected(.notPDF), got \(problems[0].failure)")
            return
        }
        #expect(library.documents.isEmpty)
    }

    @Test func oneFailedFileIsReportedAsAProblemWithTheSystemsReason() async throws {
        let library = try openLibrary()
        let missing = root.appending(path: "missing.pdf")

        let result = await library.importFiles([missing], from: .drop)

        guard case .problems(let problems) = result, problems.count == 1,
            case .failed(let message) = problems[0].failure
        else {
            Issue.record("expected one failed problem, got \(result)")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("no such file"))
    }

    @Test func severalFilesOpenTheNewOnesInOrderAndListProblems() async throws {
        let library = try openLibrary()
        let good = try writePDF(named: "a.pdf")
        let garbage = try writeFile(named: "notes.pdf", bytes: Data("just some text".utf8))
        let other = try writePDF(named: "b.pdf", metadataTitle: "Other")

        let result = await library.importFiles([good, garbage, other], from: .drop)

        guard case .open(let documents, let problems) = result else {
            Issue.record("expected .open, got \(result)")
            return
        }
        #expect(documents.map(\.title) == ["a", "Other"])
        #expect(problems.map(\.file) == [garbage])
        #expect(library.documents.count == 2)
    }

    @Test func severalNewFilesAllOpenWithoutProblems() async throws {
        let library = try openLibrary()
        let files = try (1...3).map { try writePDF(named: "\($0).pdf", metadataTitle: "Book \($0)") }

        let result = await library.importFiles(files, from: .picker)

        guard case .open(let documents, let problems) = result else {
            Issue.record("expected .open, got \(result)")
            return
        }
        #expect(documents.map(\.title) == ["Book 1", "Book 2", "Book 3"])
        #expect(problems.isEmpty)
    }

    @Test(arguments: [ImportOrigin.openWithOrShare, .drop, .picker])
    func severalFilesOpenADuplicateInsteadOfSkippingIt(origin: ImportOrigin) async throws {
        let library = try openLibrary()
        let existing = try writePDF(named: "a.pdf", metadataTitle: "Existing")
        _ = await library.importFiles([existing], from: .picker)
        let duplicate = existing.deletingLastPathComponent().appending(path: "copy.pdf")
        try FileManager.default.copyItem(at: existing, to: duplicate)
        let new = try writePDF(named: "b.pdf", metadataTitle: "New")

        let result = await library.importFiles([new, duplicate], from: origin)

        guard case .open(let documents, let problems) = result else {
            Issue.record("expected .open, got \(result)")
            return
        }
        #expect(documents.map(\.title) == ["New", "Existing"])
        #expect(problems.isEmpty)
        #expect(library.documents.count == 2)
    }

    @Test func severalFilesListOnlyRejectedAndFailedOnesAsProblems() async throws {
        let library = try openLibrary()
        let new = try writePDF(named: "b.pdf", metadataTitle: "New")
        let garbage = try writeFile(named: "notes.pdf", bytes: Data("just some text".utf8))
        let missing = root.appending(path: "missing.pdf")

        let result = await library.importFiles([garbage, new, missing], from: .openWithOrShare)

        guard case .open(let documents, let problems) = result else {
            Issue.record("expected .open, got \(result)")
            return
        }
        #expect(documents.map(\.title) == ["New"])
        #expect(problems.map(\.file) == [garbage, missing])
    }

    @Test func severalFilesThatAllFailOpenNothing() async throws {
        let library = try openLibrary()
        let garbage = try writeFile(named: "notes.pdf", bytes: Data("just some text".utf8))
        let missing = root.appending(path: "missing.pdf")

        let result = await library.importFiles([garbage, missing], from: .picker)

        guard case .problems(let problems) = result else {
            Issue.record("expected .problems, got \(result)")
            return
        }
        #expect(problems.map(\.file) == [garbage, missing])
        #expect(library.documents.isEmpty)
    }

    @Test func aCallWhileAnImportRunsWaitsForItAndBothFinish() async throws {
        let library = try openLibrary()
        let big = try writePDF(named: "big.pdf", metadataTitle: "Big", paddedTo: 64_000_000)
        let small = try writePDF(named: "small.pdf", metadataTitle: "Small")
        var finished: [String] = []

        let first = Task { @MainActor in
            _ = await library.importFiles([big], from: .openWithOrShare)
            finished.append("big")
        }
        while library.runningImport == nil { try await Task.sleep(for: .milliseconds(1)) }
        let second = Task { @MainActor in
            _ = await library.importFiles([small], from: .openWithOrShare)
            finished.append("small")
        }
        await first.value
        await second.value

        #expect(finished == ["big", "small"])
        #expect(library.documents.map(\.title).sorted() == ["Big", "Small"])
    }

    @Test func aFileInTheInboxIsDeletedAfterItsImportWhateverTheOutcome() async throws {
        let inbox = root.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let library = try openLibrary(inbox: inbox)
        let good = inbox.appending(path: "a.pdf")
        let garbage = inbox.appending(path: "notes.pdf")
        try FileManager.default.copyItem(at: try writePDF(named: "a.pdf"), to: good)
        try Data("just some text".utf8).write(to: garbage)

        _ = await library.importFiles([good], from: .openWithOrShare)
        _ = await library.importFiles([garbage], from: .openWithOrShare)

        #expect(!FileManager.default.fileExists(atPath: good.path))
        #expect(!FileManager.default.fileExists(atPath: garbage.path))
        #expect(library.documents.count == 1)
    }

    @Test func aFileOutsideTheInboxIsLeftUntouched() async throws {
        let library = try openLibrary(inbox: root.appending(path: "Inbox", directoryHint: .isDirectory))
        let source = try writePDF(named: "a.pdf")

        _ = await library.importFiles([source], from: .openWithOrShare)

        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func declaresPDFAndEPUBAsTheOnlyDocumentTypesWithAlternateRank() throws {
        let types = try #require(
            Bundle(for: LibraryModel.self).infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])

        #expect(ImportableTypes.all == [.pdf, .epub])
        #expect(
            types.compactMap { ($0["LSItemContentTypes"] as? [String])?.first } == ImportableTypes.all.map(\.identifier)
        )
        #expect(types.allSatisfy { ($0["LSItemContentTypes"] as? [String])?.count == 1 })
        #expect(types.allSatisfy { $0["CFBundleTypeRole"] as? String == "Viewer" })
        #expect(types.allSatisfy { $0["LSHandlerRank"] as? String == "Alternate" })
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
        #expect(again.id == doomed.id)
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
        _ = await (try openLibrary()).import(
            try writePDF(named: "a.pdf", metadataTitle: "Moby-Dick", author: "Melville"))

        let document = try #require(try openLibrary().documents.first)

        #expect(document.title == "Moby-Dick")
        #expect(document.author == "Melville")
    }

    @Test func missingSavedTitlesShowFileNamesFirstAndTitlesAfterTheBackgroundPass() async throws {
        try importWithoutDetails(try writePDF(named: "scan0042.pdf", metadataTitle: "Moby-Dick", author: "Melville"))

        let library = try openLibrary()
        let stale = try #require(library.documents.first)
        #expect(stale.title == "scan0042")
        #expect(stale.author == nil)

        try await waitUntil { library.documents.first?.title == "Moby-Dick" }
        #expect(library.documents.first?.author == "Melville")
        // Views holding the stale value see a change, so their caption updates.
        #expect(library.documents.first != stale)
        // Saved, so the next launch has them at once.
        #expect(try openLibrary().documents.first?.title == "Moby-Dick")
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
        // PDFKit fits the page inside 300 × 388 px at scale 1, so rounding can cost a pixel.
        #expect(cover.width >= 299)
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

        // Decoded Covers stay in memory, so after a relaunch.
        try FileManager.default.removeItem(at: coversFolder)

        #expect(await (try openLibrary()).savedCover(for: document) == nil)
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

    // MARK: Sorting

    /// A Library with Titles imported in this order, so Date Imported is
    /// newest-first: "Zebra", "résumé 10", "Resume 2", "apple".
    func libraryForSorting() async throws -> LibraryModel {
        let library = try openLibrary()
        for title in ["apple", "Resume 2", "résumé 10", "Zebra"] { try await importPDF(titled: title, into: library) }
        return library
    }

    @Test func sortsByDateImportedNewestFirstByDefault() async throws {
        let library = try await libraryForSorting()

        #expect(library.sort == LibrarySort(key: .dateImported, isReversed: false))
        #expect(library.visibleDocuments(matching: "").map(\.title) == ["Zebra", "résumé 10", "Resume 2", "apple"])
    }

    @Test func reversingDateImportedListsTheOldestFirst() async throws {
        let library = try await libraryForSorting()

        library.sort.isReversed = true

        #expect(library.visibleDocuments(matching: "").map(\.title) == ["apple", "Resume 2", "résumé 10", "Zebra"])
    }

    @Test func sortsByTitleLikeFinder() async throws {
        let library = try await libraryForSorting()

        library.sort.key = .title

        #expect(library.visibleDocuments(matching: "").map(\.title) == ["apple", "Resume 2", "résumé 10", "Zebra"])
    }

    @Test func reversingTitleListsZToA() async throws {
        let library = try await libraryForSorting()

        library.sort = LibrarySort(key: .title, isReversed: true)

        #expect(library.visibleDocuments(matching: "").map(\.title) == ["Zebra", "résumé 10", "Resume 2", "apple"])
    }

    @Test func aDocumentWhoseTitleArrivesLaterMovesToItsPlace() async throws {
        try importWithoutDetails(try writePDF(named: "zzz.pdf", metadataTitle: "Alpha"))
        try importWithoutDetails(try writePDF(named: "mmm.pdf", metadataTitle: "Mike"))
        let library = try openLibrary()
        library.sort.key = .title
        // Still by file name: the background pass can't publish before the next suspension.
        #expect(library.visibleDocuments(matching: "").map(\.title) == ["mmm", "zzz"])

        try await waitUntil { library.visibleDocuments(matching: "").map(\.title) == ["Alpha", "Mike"] }
    }

    @Test func theSortChoiceIsRememberedOnThisDevice() throws {
        let library = try openLibrary()

        library.sort = LibrarySort(key: .title, isReversed: true)

        #expect(try openLibrary().sort == LibrarySort(key: .title, isReversed: true))
    }

    // MARK: EPUBs

    @Test func anEPUBImportsLikeAPDFWithItsTitleAndAuthorAndTheFileUnchanged() async throws {
        let library = try openLibrary()
        let source = try writeEPUB(named: "book.epub", title: "Emma", author: "Jane Austen")

        guard case .opened(let document) = await library.import(source) else {
            Issue.record("expected .opened")
            return
        }

        #expect(document.format == .epub)
        #expect(document.title == "Emma")
        #expect(document.author == "Jane Austen")
        #expect(document.pageCount == nil)
        #expect(library.documents == [document])
        #expect(try Data(contentsOf: document.file) == Data(contentsOf: source))
    }

    @Test func anEPUBsReadingProgressIsItsPlaceAndPercentReadInCharacters() async throws {
        let library = try openLibrary()
        let source = try writeEPUB(named: "book.epub", chapters: ["<p>12345</p>", "<p>1234567890</p>"])
        guard case .opened(let document) = await library.import(source) else { throw ImportFailed() }
        let place = Place.epub(spineIndex: 1, offset: 5)

        await library.saveProgress(place, of: document, at: lastRead)

        for library in [library, try openLibrary()] {
            let updated = try #require(library.documents.first)
            #expect(updated.place == place)
            #expect(updated.lastRead == lastRead)
            #expect(updated.percentRead == 66)  // 10 of 15 characters
        }
    }

    @Test func anEPUBWithoutATitleShowsItsFileName() async throws {
        let library = try openLibrary()

        _ = await library.import(try writeEPUB(named: "Walden.epub"))

        #expect(library.documents.first?.title == "Walden")
    }

    @Test func aPDFIsStillAPDF() async throws {
        let library = try openLibrary()

        _ = await library.import(try writePDF(named: "a.pdf"))

        #expect(library.documents.first?.format == .pdf)
    }

    @Test func anEPUBsCoverIsItsDeclaredImageInOriginalColors() async throws {
        let library = try openLibrary()
        let source = try writeEPUB(
            named: "book.epub",
            manifest: #"<item id="cv" href="cover.png" media-type="image/png" properties="cover-image"/>"#,
            files: ["OEBPS/cover.png": solidPNG(red: 255, green: 0, blue: 0)])
        guard case .opened(let document) = await library.import(source) else {
            Issue.record("expected .opened")
            return
        }
        #expect(savedCovers().count == 1)

        let cover = try #require(await library.savedCover(for: document))

        #expect(cover.height > cover.width)
        let pixel = cover.centerPixel
        #expect(pixel[0] > 245 && pixel[1] < 10 && pixel[2] < 10, "\(pixel)")
    }

    @Test func anEPUBWithoutImagesGetsAPlainCoverMadeAgainWhenItsSavedCopyIsDeleted() async throws {
        let library = try openLibrary()
        let source = try writeEPUB(named: "book.epub", title: "A Long Title Here", author: "Jane Austen")
        guard case .opened(let document) = await library.import(source) else {
            Issue.record("expected .opened")
            return
        }
        #expect(savedCovers().count == 1)
        try FileManager.default.removeItem(at: coversFolder)

        let cover = try #require(await library.cover(for: document))

        // A4 portrait, 300 pt wide, like a PDF's.
        #expect(abs(Double(cover.height) / Double(cover.width) - 1.414) < 0.01)
        #expect(cover.hasInk)
        #expect(savedCovers().count == 1)
    }

    @Test func anEPUBRejectedForDRMOrAFixedLayoutOrAsInvalidLeavesNothingBehind() async throws {
        let library = try openLibrary()
        let encryption = """
            <encryption xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData>\
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>\
            </enc:EncryptedData></encryption>
            """
        let drm = try writeEPUB(named: "drm.epub", files: ["META-INF/encryption.xml": Data(encryption.utf8)])
        let fixed = try writeEPUB(
            named: "fixed.epub", metadata: #"<meta property="rendition:layout">pre-paginated</meta>"#)
        let invalid = try writeFile(named: "invalid.epub", bytes: Data("not a zip".utf8))
        let otherZip = try writeFile(named: "other", bytes: zip([("a.txt", Data("a".utf8))]))

        let outcomes =
            [await library.import(drm), await library.import(fixed)]
            + [await library.import(invalid), await library.import(otherZip)]

        let reasons = outcomes.map { outcome -> ImportRejection? in
            if case .rejected(let reason) = outcome { reason } else { nil }
        }
        #expect(reasons == [.drmProtectedEPUB, .fixedLayoutEPUB, .invalidEPUB, .invalidEPUB])
        #expect(library.documents.isEmpty)
        #expect(savedCovers().isEmpty)
    }

    @Test func anEPUBAlreadyInTheLibraryIsADuplicate() async throws {
        let library = try openLibrary()
        let source = try writeEPUB(named: "a.epub", title: "Emma")
        guard case .opened(let first) = await library.import(source) else {
            Issue.record("expected .opened")
            return
        }
        let renamed = source.deletingLastPathComponent().appending(path: "renamed.epub")
        try FileManager.default.copyItem(at: source, to: renamed)

        let outcome = await library.import(renamed)

        guard case .duplicate(let existing) = outcome else {
            Issue.record("expected .duplicate, got \(outcome)")
            return
        }
        #expect(existing == first)
    }

    @Test func oneBadEPUBAmongSeveralFilesIsAProblemAndTheOthersOpen() async throws {
        let library = try openLibrary()
        let urls = [
            try writeEPUB(named: "good.epub", title: "Good"),
            try writeFile(named: "bad.epub", bytes: Data("nope".utf8)),
            try writePDF(named: "a.pdf"),
        ]

        let result = await library.importFiles(urls, from: .picker)

        guard case .open(let documents, let problems) = result else {
            Issue.record("expected .open, got \(result)")
            return
        }
        #expect(documents.map(\.format) == [.epub, .pdf])
        #expect(problems.map(\.file.lastPathComponent) == ["bad.epub"])
    }

    @Test func searchFindsAnEPUBByItsAuthorAndItSortsLikeAPDF() async throws {
        let library = try openLibrary()
        _ = await library.import(try writePDF(named: "a.pdf", metadataTitle: "Moby-Dick", author: "Melville"))
        _ = await library.import(try writeEPUB(named: "b.epub", title: "Emma", author: "Jane Austen"))

        #expect(library.visibleDocuments(matching: "austen").map(\.title) == ["Emma"])
        library.sort.key = .title
        #expect(library.visibleDocuments(matching: "").map(\.title) == ["Emma", "Moby-Dick"])
    }

    @Test func removingAnEPUBDeletesItsCover() async throws {
        let library = try openLibrary()
        guard case .opened(let document) = await library.import(try writeEPUB(named: "a.epub")) else {
            Issue.record("expected .opened")
            return
        }

        library.remove(document)

        #expect(library.documents.isEmpty)
        #expect(savedCovers().isEmpty)
    }

    // MARK: Library Search

    @Test func searchMatchesPartsOfTheTitleTheFileNameAndTheAuthor() async throws {
        let library = try openLibrary()
        _ = await library.import(try writePDF(named: "a.pdf", metadataTitle: "Moby-Dick", author: "Melville"))
        _ = await library.import(try writePDF(named: "scan0042.pdf", metadataTitle: "Walden", author: "Thoreau"))

        #expect(library.visibleDocuments(matching: "oby").map(\.title) == ["Moby-Dick"])
        #expect(library.visibleDocuments(matching: "can004").map(\.title) == ["Walden"])
        #expect(library.visibleDocuments(matching: "melv").map(\.title) == ["Moby-Dick"])
    }

    @Test func searchIgnoresCaseAndAccents() async throws {
        let library = try openLibrary()
        try await importPDF(titled: "Résumé", into: library)
        try await importPDF(titled: "Other", into: library)

        #expect(library.visibleDocuments(matching: "RESUME").map(\.title) == ["Résumé"])
    }

    @Test func searchKeepsTheCurrentOrder() async throws {
        let library = try await libraryForSorting()

        #expect(library.visibleDocuments(matching: "resume").map(\.title) == ["résumé 10", "Resume 2"])

        library.sort.key = .title
        #expect(library.visibleDocuments(matching: "resume").map(\.title) == ["Resume 2", "résumé 10"])
    }

    @Test func noMatchesShowNothingAndABlankSearchShowsEverything() async throws {
        let library = try await libraryForSorting()

        #expect(library.visibleDocuments(matching: "xyz").isEmpty)
        #expect(library.visibleDocuments(matching: " ").count == 4)
    }

    @Test func aDocumentWhoseAuthorArrivesLaterJoinsTheResults() async throws {
        try importWithoutDetails(try writePDF(named: "a.pdf", metadataTitle: "Moby-Dick", author: "Melville"))
        let library = try openLibrary()
        #expect(library.visibleDocuments(matching: "melville").isEmpty)

        try await waitUntil { library.visibleDocuments(matching: "melville").map(\.title) == ["Moby-Dick"] }
    }

    // MARK: Reading Progress

    /// Imports a new PDF and returns its Document.
    func importDocument(into library: LibraryModel) async throws -> LibraryDocument {
        guard case .opened(let document) = await library.import(try writePDF(named: "\(UUID().uuidString).pdf"))
        else { throw ImportFailed() }
        return document
    }

    struct ImportFailed: Error {}

    let place = Place.pdf(pageIndex: 7, point: CGPoint(x: 12.5, y: 700.25))
    let lastRead = Date(timeIntervalSince1970: 1_700_000_000.5)

    @Test func aNeverOpenedDocumentHasNoReadingProgress() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)

        #expect(document.place == nil)
        #expect(document.lastRead == nil)
    }

    @Test func savingReadingProgressUpdatesTheDocument() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)

        await library.saveProgress(place, of: document, at: lastRead)

        let updated = try #require(library.documents.first)
        #expect(updated.place == place)
        #expect(updated.lastRead == lastRead)
        #expect(library.visibleDocuments(matching: "").first?.place == place)
    }

    @Test func readingProgressSurvivesReopeningTheLibrary() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        await library.saveProgress(place, of: document, at: lastRead)

        let reopened = try #require(try openLibrary().documents.first)

        #expect(reopened.place == place)
        #expect(reopened.lastRead == lastRead)
    }

    @Test func theLatestSavedPlaceIsTheReadingProgress() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let earlier = Place.pdf(pageIndex: 3, point: .zero)

        await library.saveProgress(place, of: document, at: lastRead)
        await library.saveProgress(earlier, of: document, at: lastRead.addingTimeInterval(5))

        #expect(library.documents.first?.place == earlier)
        #expect(try openLibrary().documents.first?.place == earlier)
    }

    @Test func savingForARemovedDocumentDoesNothing() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        library.remove(document)

        await library.saveProgress(place, of: document, at: lastRead)

        #expect(library.documents.isEmpty)
        #expect(try openLibrary().documents.isEmpty)
    }

    // MARK: Markup

    let anchor = HighlightAnchor(
        pages: [
            .init(pageIndex: 2, rects: [CGRect(x: 72, y: 700.5, width: 200, height: 12)]),
            .init(
                pageIndex: 3,
                rects: [CGRect(x: 72, y: 720, width: 100, height: 12), CGRect(x: 72, y: 706, width: 40, height: 12)]),
        ],
        quotedText: "the passage")

    @Test func aNeverHighlightedDocumentHasNoHighlights() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)

        #expect(await library.markup(of: document).highlights == [])
    }

    @Test func anAddedHighlightIsReturnedAndInTheDocumentsHighlights() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)

        let added = try #require(await library.addHighlight(anchor, to: document))

        #expect(added.anchor == anchor)
        #expect(added.color == library.defaultHighlightColor.color)
        #expect(await library.markup(of: document).highlights == [added])
    }

    @Test func highlightsSurviveReopeningTheLibrary() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let added = try #require(await library.addHighlight(anchor, to: document))

        let reopened = try openLibrary()

        #expect(await reopened.markup(of: document).highlights == [added])
    }

    @Test func highlightsKeepTheOrderTheyWereAddedIn() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let first = try #require(await library.addHighlight(anchor, to: document, at: Date(timeIntervalSince1970: 1)))
        let second = try #require(await library.addHighlight(anchor, to: document, at: Date(timeIntervalSince1970: 2)))

        #expect(first.id != second.id)
        #expect(await library.markup(of: document).highlights == [first, second])
    }

    @Test func highlightingARemovedDocumentDoesNothing() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        library.remove(document)

        #expect(await library.addHighlight(anchor, to: document) == nil)
        #expect(await library.markup(of: document).highlights == [])
    }

    @Test func removingADocumentTakesItsHighlightsAlong() async throws {
        let library = try openLibrary()
        let source = try writePDF(named: "a.pdf")
        guard case .opened(let document) = await library.import(source) else { throw ImportFailed() }
        _ = await library.addHighlight(anchor, to: document)

        library.remove(document)
        _ = await library.import(source)

        #expect(await library.markup(of: document).highlights == [])
    }

    @Test func aRecoloredHighlightKeepsItsColorAfterReopeningTheLibrary() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let added = try #require(await library.addHighlight(anchor, to: document))
        let green = library.highlightColors[1].color

        await library.setHighlightColor(green, of: added, in: document)

        var recolored = added
        recolored.color = green
        #expect(await library.markup(of: document).highlights == [recolored])
        #expect(await (try openLibrary()).markup(of: document).highlights == [recolored])
    }

    @Test func aHighlightsNoteSurvivesReopeningTheLibraryAndEmptyingItRemovesIt() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let added = try #require(await library.addHighlight(anchor, to: document))

        await library.setNote("my thought", of: added, in: document)

        var noted = added
        noted.note = "my thought"
        #expect(await (try openLibrary()).markup(of: document).highlights == [noted])

        await library.setNote("", of: added, in: document)
        #expect(await (try openLibrary()).markup(of: document).highlights == [added])
    }

    @Test func aNeverNotedDocumentHasNoPageNotes() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)

        #expect(await library.markup(of: document).pageNotes == [])
    }

    @Test func anAddedPageNoteIsAtItsPlaceAndListedOnceItHasText() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let place = Place.pdf(pageIndex: 4, point: CGPoint(x: 100.5, y: 200.5))

        let added = try #require(await library.addPageNote(at: place, to: document))

        #expect(added.place == place)
        #expect(added.text == "")
        #expect(await library.markup(of: document).pageNotes == [])

        await library.setText("my thought", of: added, in: document)
        var typed = added
        typed.text = "my thought"
        #expect(await library.markup(of: document).pageNotes == [typed])
        #expect(await (try openLibrary()).markup(of: document).pageNotes == [typed])
    }

    @Test func emptyingAPageNoteOrRemovingItLeavesNoPageNote() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let place = Place.pdf(pageIndex: 0, point: .zero)
        let emptied = try #require(await library.addPageNote(at: place, to: document))
        let removed = try #require(await library.addPageNote(at: place, to: document))
        await library.setText("x", of: emptied, in: document)
        await library.setText("y", of: removed, in: document)

        await library.setText("", of: emptied, in: document)
        await library.removePageNote(removed, from: document)

        #expect(await (try openLibrary()).markup(of: document).pageNotes == [])
    }

    @Test func addingAPageNoteToARemovedDocumentDoesNothing() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        library.remove(document)

        #expect(await library.addPageNote(at: Place.pdf(pageIndex: 0, point: .zero), to: document) == nil)
    }

    @Test func aRemovedHighlightIsGoneAfterReopeningTheLibrary() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let first = try #require(await library.addHighlight(anchor, to: document))
        let second = try #require(await library.addHighlight(anchor, to: document))

        await library.removeHighlight(first, from: document)

        #expect(await library.markup(of: document).highlights == [second])
        #expect(await (try openLibrary()).markup(of: document).highlights == [second])
    }

    @Test func recoloringAndRemovingInARemovedDocumentDoNothing() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let added = try #require(await library.addHighlight(anchor, to: document))
        library.remove(document)

        await library.setHighlightColor(library.highlightColors[1].color, of: added, in: document)
        await library.removeHighlight(added, from: document)

        #expect(await library.markup(of: document).highlights == [])
    }

    @Test func theHighlightColorsAreTheBuiltInOnesYellowFirst() throws {
        let library = try openLibrary()
        #expect(library.highlightColors.map(\.name) == ["Yellow", "Green", "Blue", "Pink", "Purple", "Red"])
    }

    @Test func theDefaultHighlightColorIsYellowUntilChosen() throws {
        let library = try openLibrary()
        #expect(library.defaultHighlightColor == library.highlightColors[0])
    }

    @Test func aChosenDefaultHighlightColorSurvivesReopeningTheLibrary() async throws {
        let library = try openLibrary()
        let purple = library.highlightColors[4]

        await library.setDefaultHighlightColor(purple)

        #expect(library.defaultHighlightColor == purple)
        #expect(try openLibrary().defaultHighlightColor == purple)
    }

    @Test func aCustomColorComesAfterTheBuiltInOnesInTheOrderAddedAndSurvivesReopening() async throws {
        let library = try openLibrary()
        let teal = try #require(await library.addCustomColor(RGB(0, 0.5, 0.5)))
        let brown = try #require(await library.addCustomColor(RGB(0.6, 0.3, 0)))

        #expect(library.highlightColors.suffix(2) == [teal, brown])
        #expect(teal.isCustom && !library.highlightColors[0].isCustom)
        #expect(try openLibrary().highlightColors.suffix(2) == [teal, brown])
    }

    @Test func aCustomColorCanBeTheDefaultHighlightColor() async throws {
        let library = try openLibrary()
        let teal = try #require(await library.addCustomColor(RGB(0, 0.5, 0.5)))

        await library.setDefaultHighlightColor(teal)

        #expect(try openLibrary().defaultHighlightColor == teal)
    }

    @Test func removingTheDefaultCustomColorMakesYellowTheDefaultAgain() async throws {
        let library = try openLibrary()
        let teal = try #require(await library.addCustomColor(RGB(0, 0.5, 0.5)))
        await library.setDefaultHighlightColor(teal)

        await library.removeCustomColor(teal)

        #expect(library.highlightColors.count == 6)
        #expect(library.defaultHighlightColor == library.highlightColors[0])
        #expect(try openLibrary().highlightColors.count == 6)
        #expect(try openLibrary().defaultHighlightColor.name == "Yellow")
    }

    @Test func aBuiltInColorCannotBeRemoved() async throws {
        let library = try openLibrary()

        await library.removeCustomColor(library.highlightColors[1])

        #expect(library.highlightColors.count == 6)
    }

    @Test func aHighlightKeepsItsColorWhenItsCustomColorIsRemoved() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let teal = try #require(await library.addCustomColor(RGB(0, 0.5, 0.5)))
        await library.setDefaultHighlightColor(teal)
        _ = await library.addHighlight(anchor, to: document)

        await library.removeCustomColor(teal)

        #expect(await library.markup(of: document).highlights.map(\.color) == [teal.color])
    }

    @Test func aColorThatIsNoLongerInThePaletteShowsAsAnExtraCircleAtTheEnd() throws {
        let library = try openLibrary()
        let gone = RGB(0, 0.5, 0.5)

        let shown = library.highlightColors.including(gone)

        #expect(shown.count == 7 && shown.last?.color == gone)
        #expect(library.highlightColors.including(library.highlightColors[2].color) == library.highlightColors)
    }

    @Test func newHighlightsGetTheDefaultHighlightColor() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        let green = library.highlightColors[1]
        await library.setDefaultHighlightColor(green)

        let added = try #require(await library.addHighlight(anchor, to: document))

        #expect(added.color == green.color)
        #expect(await library.markup(of: document).highlights.map(\.color) == [green.color])
    }

    @Test func highlightsDoNotDisturbReadingProgress() async throws {
        let library = try openLibrary()
        let document = try await importDocument(into: library)
        await library.saveProgress(place, of: document, at: lastRead)

        _ = await library.addHighlight(anchor, to: document)

        #expect(try openLibrary().documents.first?.place == place)
    }

    // MARK: Recently Read sort

    /// `libraryForSorting()` with "apple" read at 100 s, "Zebra" at 200 s and
    /// "Resume 2" at 300 s; "résumé 10" is never opened. Date Imported order
    /// (newest first) is Zebra, résumé 10, Resume 2, apple.
    func libraryForRecentlyRead() async throws -> LibraryModel {
        let library = try await libraryForSorting()
        for (title, seconds) in [("apple", 100.0), ("Zebra", 200), ("Resume 2", 300)] {
            let document = try #require(library.documents.first { $0.title == title })
            await library.saveProgress(place, of: document, at: Date(timeIntervalSince1970: seconds))
        }
        return library
    }

    @Test func recentlyReadListsTheLastReadFirstAndNeverOpenedDocumentsLast() async throws {
        let library = try await libraryForRecentlyRead()

        library.sort.key = .recentlyRead

        #expect(library.visibleDocuments(matching: "").map(\.title) == ["Resume 2", "Zebra", "apple", "résumé 10"])
    }

    @Test func reversingRecentlyReadFlipsOnlyTheOpenedDocuments() async throws {
        let library = try await libraryForRecentlyRead()

        library.sort = LibrarySort(key: .recentlyRead, isReversed: true)

        #expect(library.visibleDocuments(matching: "").map(\.title) == ["apple", "Zebra", "Resume 2", "résumé 10"])
    }

    @Test func neverOpenedDocumentsFollowInDateImportedOrderInBothDirections() async throws {
        let library = try await libraryForSorting()  // Zebra, résumé 10, Resume 2, apple; none opened
        let newestFirst = library.visibleDocuments(matching: "").map(\.title)

        library.sort = LibrarySort(key: .recentlyRead, isReversed: false)
        #expect(library.visibleDocuments(matching: "").map(\.title) == newestFirst)

        library.sort = LibrarySort(key: .recentlyRead, isReversed: true)
        #expect(library.visibleDocuments(matching: "").map(\.title) == newestFirst)
    }

    @Test func openingADocumentMovesItToTheTopOfRecentlyRead() async throws {
        let library = try await libraryForRecentlyRead()
        library.sort.key = .recentlyRead
        let never = try #require(library.documents.first { $0.title == "résumé 10" })

        await library.saveProgress(place, of: never, at: Date(timeIntervalSince1970: 400))

        #expect(library.visibleDocuments(matching: "").map(\.title) == ["résumé 10", "Resume 2", "Zebra", "apple"])
    }

    @Test func searchKeepsTheRecentlyReadOrder() async throws {
        let library = try await libraryForRecentlyRead()
        library.sort.key = .recentlyRead

        #expect(library.visibleDocuments(matching: "resume").map(\.title) == ["Resume 2", "résumé 10"])
        #expect(library.visibleDocuments(matching: "e").map(\.title) == ["Resume 2", "Zebra", "apple", "résumé 10"])
    }

    @Test func theRecentlyReadChoiceIsRememberedOnThisDevice() throws {
        let library = try openLibrary()

        library.sort = LibrarySort(key: .recentlyRead, isReversed: true)

        #expect(try openLibrary().sort == LibrarySort(key: .recentlyRead, isReversed: true))
    }

    // MARK: Page count and percentage read

    /// Imports a PDF of `pageCount` pages.
    private func importDocument(pageCount: Int, into library: LibraryModel) async throws -> LibraryDocument {
        guard case .opened(let document) = await library.import(try writePDF(named: "a.pdf", pageCount: pageCount))
        else { throw ImportFailed() }
        return document
    }

    @Test func importSavesThePageCount() async throws {
        let library = try openLibrary()

        let document = try await importDocument(pageCount: 3, into: library)

        #expect(document.pageCount == 3)
        #expect(try openLibrary().documents.first?.pageCount == 3)
    }

    @Test func theBackgroundPassReadsAMissingPageCount() async throws {
        try importWithoutDetails(try writePDF(named: "a.pdf", pageCount: 3))

        let library = try openLibrary()
        #expect(library.documents.first?.pageCount == nil)

        try await waitUntil { library.documents.first?.pageCount == 3 }
        #expect(try openLibrary().documents.first?.pageCount == 3)
    }

    @Test(arguments: [(0, 25), (1, 50), (2, 75), (3, 100)])
    func percentReadIsThePageReachedOfThePageCount(pageIndex: Int, percent: Int) async throws {
        let library = try openLibrary()
        let document = try await importDocument(pageCount: 4, into: library)

        await library.saveProgress(Place.pdf(pageIndex: pageIndex, point: .zero), of: document, at: lastRead)

        #expect(library.documents.first?.percentRead == percent)
    }

    @Test func percentReadIsRoundedDown() async throws {
        let library = try openLibrary()
        let document = try await importDocument(pageCount: 3, into: library)

        await library.saveProgress(Place.pdf(pageIndex: 1, point: .zero), of: document, at: lastRead)

        #expect(library.documents.first?.percentRead == 66)
    }

    @Test func aDocumentOpenedOnTheFirstPageOfALongBookReadsZeroPercent() async throws {
        let library = try openLibrary()
        let document = try await importDocument(pageCount: 200, into: library)

        await library.saveProgress(Place.pdf(pageIndex: 0, point: .zero), of: document, at: lastRead)

        #expect(library.documents.first?.percentRead == 0)
    }

    @Test func aNeverOpenedDocumentHasNoPercentRead() async throws {
        let document = try await importDocument(pageCount: 4, into: try openLibrary())

        #expect(document.percentRead == nil)
    }

    @Test func voiceOverReadsAnOpenedDocumentWithItsPercentage() async throws {
        let library = try openLibrary()
        let document = try await importDocument(pageCount: 4, into: library)
        #expect(document.accessibilityLabel == document.title)

        await library.saveProgress(Place.pdf(pageIndex: 1, point: .zero), of: document, at: lastRead)

        #expect(library.documents.first?.accessibilityLabel == "\(document.title), 50 % read")
    }

    /// Waits up to 10 s for `condition`, which the background pass makes true.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
