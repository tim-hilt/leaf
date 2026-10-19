import Foundation
import LeafCore
import Testing

@testable import LeafPDF

/// Cloud Backing through `LibraryModel`: two models, each a Device, share a
/// directory as their cloud.
extension LibraryModelTests {
    private static let fast = SyncIntervals(debounceMs: 10, pollMs: 30)

    /// The shared cloud directory of this test.
    private var cloud: URL { root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-cloud") }

    /// A second Device with a Library of its own.
    private func openOtherDevice() throws -> LibraryModel {
        let name = "\(root.lastPathComponent)-other"
        let parent = root.deletingLastPathComponent()
        let defaults = UserDefaults(suiteName: name)!
        return try LibraryModel(
            root: parent.appending(path: name, directoryHint: .isDirectory),
            detailsFile: parent.appending(path: "\(name)-details.json"),
            coversFolder: parent.appending(path: "\(name)-covers"), defaults: defaults,
            credentials: CloudCredentials(defaults: defaults, service: "leafpdf-test-\(name)"), syncIntervals: Self.fast)
    }

    private func ids(_ library: LibraryModel) -> [String] { library.documents.map(\.id) }

    /// True once `condition` holds, within 5 s.
    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func importedID(_ library: LibraryModel, titled title: String) async throws -> String {
        guard case .opened(let document) = await library.import(try writePDF(named: "\(title).pdf", metadataTitle: title))
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

    @Test func theStatusLineSaysHowSyncStands() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(SyncState.syncing.line(now: now) == "Syncing…")
        #expect(SyncState.offline.line(now: now) == "Offline")
        #expect(SyncState.synced(now.addingTimeInterval(-5)).line(now: now) == "Synced just now")
        #expect(SyncState.synced(now.addingTimeInterval(-300)).line(now: now).hasPrefix("Synced "))
        #expect(SyncState.synced(now.addingTimeInterval(-300)).line(now: now) != "Synced just now")
    }
}
