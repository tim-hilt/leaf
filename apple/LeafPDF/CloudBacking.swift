import Foundation
import LeafCore

/// Where Sync stands, while Connected; the core's `Status`.
extension Status {
    /// What Settings says of Sync with `provider`.
    func line(for provider: CloudProvider, now: Date = .now) -> String {
        switch self {
        case .syncing: return "Syncing…"
        case .offline: return "Offline"
        case .accessLost: return "Access lost"
        case .full: return "\(provider.name) is full"
        case .updateNeeded: return "Update LeafPDF to keep syncing"
        case .synced(let at):
            let date = Date(milliseconds: at)
            return now.timeIntervalSince(date) < 60
                ? "Synced just now" : "Synced \(date.formatted(.relative(presentation: .named)))"
        }
    }
}

/// What the Gallery's toolbar shows of Sync.
enum SyncIndicator: Equatable {
    case syncing
    case synced(Date)
    /// Trying again can help unless Sync is blocked; then Settings has to.
    case failed(canRetry: Bool)

    init(_ state: Status) {
        switch state {
        case .syncing: self = .syncing
        case .synced(let at): self = .synced(Date(milliseconds: at))
        case .offline: self = .failed(canRetry: true)
        case .accessLost, .full, .updateNeeded: self = .failed(canRetry: false)
        }
    }

    /// What its popover says.
    var message: String {
        switch self {
        case .syncing: "Syncing\u{2026}"
        case .failed: "Error while syncing"
        case .synced(let date):
            "Last synced at \(date.formatted(date: .omitted, time: .shortened)) \(date.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

/// Files uploading or downloading: what the Gallery's transfer bar shows.
struct FileTransfer: Equatable {
    /// Documents whose File has been transferred.
    let done: Int
    /// Documents whose File this Sync transfers.
    let total: Int

    /// Nil once everything is transferred: there is no bar to show.
    init?(done: Int, total: Int) {
        guard done < total else { return nil }
        self.done = done
        self.total = total
    }

    var text: String { "Syncing \(done) of \(total) Documents" }
}

/// Where a Library can be backed up.
enum CloudProvider: CaseIterable, Hashable {
    case webDAV
    case iCloudDrive

    /// What the picker calls it.
    var name: String {
        switch self {
        case .webDAV: "WebDAV"
        case .iCloudDrive: "iCloud Drive"
        }
    }

    /// The SF Symbol shown next to its name.
    var icon: String {
        switch self {
        case .webDAV: "server.rack"
        case .iCloudDrive: "icloud"
        }
    }

    /// What Settings calls the detail of a Connection to it.
    var detailLabel: String {
        switch self {
        case .webDAV: "Server"
        case .iCloudDrive: "Folder"
        }
    }
}

/// The Cloud Provider this Device is Connected to.
struct CloudConnection: Equatable {
    let provider: CloudProvider
    /// What Settings shows of it, labelled `provider.detailLabel`: the Server URL
    /// for WebDAV, the folder for iCloud Drive, or the directory of a test.
    let detail: String
}

extension ConnectError {
    /// What Settings says next to the form; nil when nothing needs saying.
    var message: String? {
        switch self {
        case .Cancelled: nil
        case .AccessDenied: "Access denied"
        case .ICloudDriveUnavailable: "Turn on iCloud Drive in Settings"
        case .WrongFolder: "Choose iCloud Drive"
        case .UnsupportedAccount: "Only personal accounts are supported"
        case .WrongCredentials: "Wrong username or password"
        case .Unreachable: "Server not reachable"
        case .NotHttps: "URL must start with https://"
        case .NotWebDav: "Not a WebDAV server"
        }
    }
}

/// Forwards what the core's Sync loop reports, on its thread, to the main actor.
final class SyncRelay: SyncObserver {
    private let onStatus: @Sendable @MainActor (Status) -> Void
    private let onTransfer: @Sendable @MainActor (FileTransfer?) -> Void
    private let onLibraryChanged: @Sendable @MainActor () -> Void
    private let onMarkupChanged: @Sendable @MainActor (String) -> Void

    init(
        status: @escaping @Sendable @MainActor (Status) -> Void,
        transfer: @escaping @Sendable @MainActor (FileTransfer?) -> Void,
        libraryChanged: @escaping @Sendable @MainActor () -> Void,
        markupChanged: @escaping @Sendable @MainActor (String) -> Void
    ) {
        onStatus = status
        onTransfer = transfer
        onLibraryChanged = libraryChanged
        onMarkupChanged = markupChanged
    }

    func statusChanged(status: Status) {
        Task { @MainActor [onStatus] in onStatus(status) }
    }

    func transferProgress(done: UInt64, total: UInt64) {
        let transfer = FileTransfer(done: Int(done), total: Int(total))
        Task { @MainActor [onTransfer] in onTransfer(transfer) }
    }

    func libraryChanged() {
        Task { @MainActor [onLibraryChanged] in onLibraryChanged() }
    }

    func markupChanged(id: String) {
        Task { @MainActor [onMarkupChanged] in onMarkupChanged(id) }
    }
}
