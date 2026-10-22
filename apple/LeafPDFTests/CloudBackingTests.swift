import Foundation
import LeafCore
import Testing

@testable import LeafPDF

/// Cloud Backing through `LibraryModel`: two models, each a Device, share a
/// directory as their cloud.
extension LibraryModelTests {
    private static let fast = SyncIntervals(debounceMs: 10, progressMs: 10, pollMs: 30, idlePollMs: 30)

    /// The shared cloud directory of this test.
    private var cloud: URL { root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-cloud") }

    /// A second Device with a Library of its own.
    private func openOtherDevice() throws -> LibraryModel {
        let name = "\(root.lastPathComponent)-other"
        let parent = root.deletingLastPathComponent()
        let defaults = UserDefaults(suiteName: name)!
        return try LibraryModel(
            root: parent.appending(path: name, directoryHint: .isDirectory),
            coversFolder: parent.appending(path: "\(name)-covers"), defaults: defaults,
            credentials: CloudCredentials(defaults: defaults, service: "leafpdf-test-\(name)"), syncIntervals: Self.fast
        )
    }

    private func ids(_ library: LibraryModel) -> [String] { library.documents.map(\.id) }

    /// True once `condition` holds, within 5 s.
    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// `eventually` for a condition that needs to wait for the core.
    private func eventuallyAsync(_ condition: @MainActor () async -> Bool) async throws -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func importedID(_ library: LibraryModel, titled title: String) async throws -> String {
        guard
            case .opened(let document) = await library.import(try writePDF(named: "\(title).pdf", metadataTitle: title))
        else { throw ImportFailure() }
        return document.id
    }

    private struct ImportFailure: Error {}

    @Test func cloudBackingIsOffUntilConnected() throws {
        let library = try openLibrary()

        #expect(library.connection == nil)
    }

    @Test func anImportOnOneDeviceAppearsOnTheOther() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)

        let id = try await importedID(a, titled: "Paper")

        #expect(try await eventually { ids(b) == [id] })
        #expect(b.documents.first?.fileName.hasSuffix(".pdf") == true)
        #expect(try await eventually { b.documents.first?.title == "Paper" })
    }

    @Test func aRemoveOnOneDeviceRemovesTheDocumentOnTheOther() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)
        let id = try await importedID(a, titled: "Paper")
        #expect(try await eventually { ids(b) == [id] })

        a.remove(a.documents[0])

        #expect(try await eventually { b.documents.isEmpty })
    }

    @Test func aDocumentRemovedOnAnotherDeviceClosesItsTab() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        let tabs = Tabs(defaults: UserDefaults(suiteName: UUID().uuidString)!, library: b.documents)
        tabs.open(b.documents)

        a.remove(try #require(a.documents.first))

        #expect(try await eventually { b.documents.isEmpty })
        tabs.keep(onlyIn: b.documents)
        #expect(tabs.openIDs.isEmpty)
        #expect(!tabs.isShowingReader)
    }

    @Test func connectingMergesTheLibrariesOfBothDevices() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        let onA = try await importedID(a, titled: "On A")
        let onB = try await importedID(b, titled: "On B")

        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)

        let both = Set([onA, onB])
        #expect(try await eventually { Set(ids(a)) == both && Set(ids(b)) == both })
    }

    @Test func connectingShowsTheServerAndTheSyncStatus() async throws {
        let library = try openLibrary(syncIntervals: Self.fast)

        try await library.connect(directory: cloud)

        #expect(library.connection == CloudConnection(server: cloud.path))
        #expect(
            try await eventually {
                if case .synced = library.syncState { true } else { false }
            })
    }

    @Test func disconnectingStopsSyncingAndKeepsTheLibrary() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)
        let first = try await importedID(a, titled: "First")
        #expect(try await eventually { ids(b) == [first] })

        await b.disconnect()
        _ = try await importedID(a, titled: "Second")
        try await Task.sleep(for: .milliseconds(300))

        #expect(b.connection == nil)
        #expect(ids(b) == [first])
    }

    @Test func reconnectingSyncsWhatChangedWhileDisconnected() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)
        await b.disconnect()
        let onA = try await importedID(a, titled: "On A")
        let onB = try await importedID(b, titled: "On B")

        try await b.connect(directory: cloud)

        let both = Set([onA, onB])
        #expect(try await eventually { Set(ids(a)) == both && Set(ids(b)) == both })
    }

    @Test func aConnectionToAnUnreachableServerFailsAndLeavesCloudBackingOff() async throws {
        let library = try openLibrary()

        await #expect(throws: ConnectError.Unreachable) {
            try await library.connect(url: "https://127.0.0.1:1", username: "reader", password: "secret")
        }
        #expect(library.connection == nil)
        #expect(credentials.load() == nil)
    }

    @Test func aURLWithoutHTTPSIsRefusedBeforeAnythingIsSent() async throws {
        let library = try openLibrary()

        await #expect(throws: ConnectError.NotHttps) {
            try await library.connect(url: "http://example.com", username: "reader", password: "secret")
        }
        #expect(library.connection == nil)
    }

    @Test func connectErrorsSayWhatToFix() {
        #expect(ConnectError.WrongCredentials.message == "Wrong username or password")
        #expect(ConnectError.Unreachable.message == "Server not reachable")
        #expect(ConnectError.NotHttps.message == "URL must start with https://")
        #expect(ConnectError.NotWebDav.message == "Not a WebDAV server")
    }

    @Test func credentialsSurviveARelaunchAndAreGoneAfterDisconnect() async throws {
        let account = WebDAVAccount(url: "https://127.0.0.1:1", username: "reader", password: "secret")
        #expect(credentials.save(account))

        // Relaunch: Connected again without contacting the server, which is down.
        let library = try openLibrary(syncIntervals: Self.fast)
        #expect(library.connection == CloudConnection(server: account.url))
        #expect(try await eventually { library.syncState == .offline })

        await library.disconnect()

        #expect(library.connection == nil)
        #expect(credentials.load() == nil)
        #expect(try openLibrary().connection == nil)
    }

    @Test func savedCredentialsHoldOnlyTheLatestAccount() {
        credentials.save(WebDAVAccount(url: "https://a.example", username: "a", password: "1"))
        credentials.save(WebDAVAccount(url: "https://b.example", username: "b", password: "2"))

        #expect(credentials.load() == WebDAVAccount(url: "https://b.example", username: "b", password: "2"))
        credentials.forget()
        #expect(credentials.load() == nil)
    }

    @Test func theTransferBarSaysHowManyDocumentsAreDoneAndIsGoneAtTheEnd() {
        #expect(FileTransfer(done: 0, total: 120)?.text == "Syncing 0 of 120 Documents")
        #expect(FileTransfer(done: 12, total: 120)?.text == "Syncing 12 of 120 Documents")
        #expect(FileTransfer(done: 120, total: 120) == nil)
    }

    @Test func theTransferBarCountsUpDuringAMultiFileSyncAndIsGoneAfterwards() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        let count = 8
        for number in 0..<count { _ = try await importedID(a, titled: "Doc \(number)") }
        try await a.connect(directory: cloud)
        // All Files are in the cloud, so B downloads them in one Sync.
        #expect(
            try await eventually {
                if case .synced = a.syncState { true } else { false }
            })

        try await b.connect(directory: cloud)
        var seen: [Int] = []
        for _ in 0..<5000 {
            if let done = b.transfer?.done, seen.last != done { seen.append(done) }
            if b.documents.count == count && b.transfer == nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(!seen.isEmpty)
        #expect(seen == seen.sorted())
        #expect(b.documents.count == count)
        #expect(b.transfer == nil)
    }

    @Test func syncsOfStateOnlyShowNoTransferBar() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        let onA = try #require(a.documents.first)
        let onB = try #require(b.documents.first)
        let before = b.markupRevision(of: onB)

        _ = try #require(await a.addHighlight(anchor, quotedText: quote, to: onA))
        await a.saveProgress(place, of: onA, at: lastRead)
        var bars: [FileTransfer] = []
        for _ in 0..<500 where b.markupRevision(of: onB) == before || b.documents.first?.place == nil {
            bars += [a.transfer, b.transfer].compactMap { $0 }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(b.markupRevision(of: onB) > before)
        #expect(bars.isEmpty)
    }

    @Test func theStatusLineSaysHowSyncStands() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        func synced(_ secondsAgo: Double) -> Status {
            .synced(at: UInt64(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000))
        }

        #expect(Status.syncing.line(now: now) == "Syncing…")
        #expect(Status.offline.line(now: now) == "Offline")
        #expect(synced(5).line(now: now) == "Synced just now")
        #expect(synced(300).line(now: now).hasPrefix("Synced "))
        #expect(synced(300).line(now: now) != "Synced just now")
    }

    @Test func theStatusLineNamesBothBlockedStates() {
        #expect(Status.wrongPassword.line() == "Wrong password")
        #expect(Status.updateNeeded.line() == "Update LeafPDF to keep syncing")
    }

    @Test func theIndicatorShowsHowSyncStandsWhileConnected() async throws {
        // Offline: the server is down. Trying again can help.
        let account = WebDAVAccount(url: "https://127.0.0.1:1", username: "reader", password: "secret")
        #expect(credentials.save(account))
        let offline = try openLibrary(syncIntervals: Self.fast)
        #expect(try await eventually { offline.syncState == .offline })
        #expect(offline.syncIndicator == .failed(canRetry: true))
        await offline.disconnect()

        // Not Connected.
        let library = try openLibrary(syncIntervals: Self.fast)
        #expect(library.syncIndicator == nil)

        // Blocked: the cloud refuses access, as a server does with a wrong password.
        try await library.connect(directory: cloud)
        #expect(try await eventually { if case .synced = library.syncState { true } else { false } })
        if case .synced(let at) = library.syncState {
            #expect(library.syncIndicator == .synced(Date(milliseconds: at)))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cloud.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cloud.path) }
        #expect(try await eventually { library.syncState == .wrongPassword })
        #expect(library.syncIndicator == .failed(canRetry: false))
        #expect(library.connection != nil)

        await library.disconnect()
        #expect(library.syncIndicator == nil)
    }

    @Test func theIndicatorsMessageSaysWhenSyncLastSucceeded() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let time = date.formatted(date: .omitted, time: .shortened)
        let day = date.formatted(date: .abbreviated, time: .omitted)

        #expect(SyncIndicator.synced(date).message == "Last synced at \(time) \(day)")
        #expect(SyncIndicator.syncing.message == "Syncing…")
        #expect(SyncIndicator.failed(canRetry: true).message == "Error while syncing")
        #expect(SyncIndicator.failed(canRetry: false).message == "Error while syncing")
    }

    @Test func aNewPasswordThatTheServerCantCheckLeavesTheConnectionAndTheSavedPasswordAlone() async throws {
        let account = WebDAVAccount(url: "https://127.0.0.1:1", username: "reader", password: "old")
        #expect(credentials.save(account))
        let library = try openLibrary(syncIntervals: Self.fast)

        await #expect(throws: ConnectError.Unreachable) { try await library.updatePassword("new") }

        #expect(library.connection == CloudConnection(server: account.url))
        #expect(credentials.load() == account)
    }

    @Test func updatingThePasswordWithoutAWebDAVConnectionDoesNothing() async throws {
        let library = try openLibrary(syncIntervals: Self.fast)
        try await library.connect(directory: cloud)

        try await library.updatePassword("new")

        #expect(library.connection == CloudConnection(server: cloud.path))
        #expect(credentials.load() == nil)
    }

    /// Two connected Devices that both hold one Document, imported on the first.
    private func twoDevicesWithADocument() async throws -> (LibraryModel, LibraryModel, String) {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)
        let id = try await importedID(a, titled: "Paper")
        #expect(try await eventually { ids(b) == [id] })
        return (a, b, id)
    }

    @Test func aHighlightAddedOnOneDeviceAppearsOnTheOtherAndTheReaderIsTold() async throws {
        let (a, b, id) = try await twoDevicesWithADocument()
        let onB = try #require(b.documents.first)
        let before = b.markupRevision(of: onB)

        let onA = try #require(a.documents.first)
        let added = try #require(await a.addHighlight(anchor, quotedText: quote, to: onA))

        #expect(try await eventually { b.markupRevision(of: onB) > before })
        #expect(await b.markup(of: onB).highlights == [added])
        #expect(onB.id == id)
    }

    @Test func aNoteAndAPageNoteAddedOnOneDeviceAppearOnTheOther() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        let onA = try #require(a.documents.first)
        let onB = try #require(b.documents.first)
        let highlight = try #require(await a.addHighlight(anchor, quotedText: quote, to: onA))
        await a.setNote("worth a note", of: highlight, in: onA)
        let pageNote = try #require(await a.addPageNote(at: place, to: onA))
        await a.setText("page note", of: pageNote, in: onA)

        #expect(
            try await eventuallyAsync {
                let note = await b.markup(of: onB).highlights.first?.note
                let pageNotes = await b.markup(of: onB).pageNotes
                return note == "worth a note" && pageNotes.count == 1
            })
    }

    @Test func incomingReadingProgressShowsInTheGalleryButNeverMovesAnOpenReader() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        // What the Reader of B holds: the Document as it was opened.
        let open = try #require(b.documents.first)
        await b.saveProgress(place, of: open, at: lastRead)
        let opened = try #require(b.documents.first)

        await a.saveProgress(
            Place.pdf(pageIndex: 3, point: .zero), of: try #require(a.documents.first),
            at: lastRead.addingTimeInterval(60))

        #expect(try await eventually { b.documents.first?.place?.pageIndex == 3 })
        #expect(opened.place == place)
        // Its next save carries the newer Last Read, so it wins everywhere.
        let later = lastRead.addingTimeInterval(120)
        await b.saveProgress(place, of: opened, at: later)
        #expect(try await eventually { a.documents.first?.lastRead == later })
        #expect(a.documents.first?.place == place)
    }

    @Test func customColorsAndTheDefaultHighlightColorSyncBetweenDevices() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)

        let custom = try #require(await a.addCustomColor(RGB(0.2, 0.4, 0.6)))
        await a.setDefaultHighlightColor(custom)

        #expect(try await eventually { b.highlightColors.contains(custom) && b.defaultHighlightColor == custom })
        await b.removeCustomColor(custom)
        #expect(try await eventually { !a.highlightColors.contains(custom) && a.defaultHighlightColor.id == "Yellow" })
    }
}
