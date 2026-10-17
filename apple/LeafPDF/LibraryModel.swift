import LeafCore
import Observation
import PDFKit

/// A Document in the Library, opened for reading.
struct LibraryDocument: Identifiable, Hashable {
    let id: String
    let pdf: PDFDocument

    var title: String { pdf.title }

    fileprivate init?(_ stored: LeafCore.Document) {
        guard let pdf = PDFDocument(url: URL(fileURLWithPath: stored.path)) else { return nil }
        id = stored.id
        self.pdf = pdf
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ImportOutcome {
    case opened(LibraryDocument)
    case failed(String)
}

/// An Import in progress: what the progress modal shows.
struct RunningImport: Equatable {
    let title: String
    /// Share of the File copied, 0...1.
    fileprivate(set) var fraction: Double = 0
}

/// Forwards the core's progress, reported on the Import's thread, to the main actor.
private final class ProgressRelay: ImportProgress {
    private let update: @Sendable @MainActor (Double) -> Void

    init(_ update: @escaping @Sendable @MainActor (Double) -> Void) { self.update = update }

    func report(copied: UInt64, total: UInt64) {
        let fraction = total == 0 ? 1 : Double(copied) / Double(total)
        Task { @MainActor [update] in update(fraction) }
    }
}

/// The Library as the clients see it: the core's Library folder plus its
/// Documents, newest Import first. One per app, shared by all windows.
@MainActor @Observable
final class LibraryModel {
    private(set) var documents: [LibraryDocument] = []
    /// Non-nil from the start of an Import until it finishes. The UI is
    /// disabled meanwhile.
    private(set) var runningImport: RunningImport?
    @ObservationIgnored private let core: LeafCore.Library

    /// Opens the Library folder at `root`, creating it if needed.
    init(root: URL) throws {
        core = try LeafCore.Library.open(root: root.path)
        refresh()
    }

    /// The Library in a hidden folder in Application Support.
    static func inApplicationSupport() throws -> LibraryModel {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try LibraryModel(root: support.appending(path: "Library", directoryHint: .isDirectory))
    }

    /// Copies the File at `url` into the Library without blocking the main
    /// thread, publishing `runningImport` meanwhile.
    func `import`(_ url: URL) async -> ImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        runningImport = RunningImport(title: PDFDocument(url: url)?.title ?? url.deletingPathExtension().lastPathComponent)
        defer { runningImport = nil }

        let core = core, path = url.path
        // Reports arriving after the Import finished find no runningImport and do nothing.
        let relay = ProgressRelay { [weak self] fraction in
            guard let running = self?.runningImport else { return }
            self?.runningImport?.fraction = max(running.fraction, fraction)
        }
        do {
            let stored = try await Task.detached { try core.import(source: path, progress: relay) }.value
            refresh()
            guard let document = LibraryDocument(stored) else {
                return .failed("The imported file couldn't be opened.")
            }
            return .opened(document)
        } catch LibraryError.Failed(let message) {
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func refresh() {
        documents = ((try? core.documents()) ?? []).compactMap(LibraryDocument.init)
    }
}
