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

/// Why a File isn't Imported at all; nothing was copied.
enum ImportRejection: Error {
    /// Not a PDF.
    case notPDF
    /// Looks like a PDF, but PDFKit can't open it.
    case unreadable
    /// Needs a password to open. PDFs that only restrict permissions aren't locked.
    case locked
}

/// How an Import ended.
enum ImportOutcome {
    /// The File is now a new Document in the Library.
    case opened(LibraryDocument)
    /// The Library already holds this File's content: the existing Document.
    case duplicate(LibraryDocument)
    case rejected(ImportRejection)
    /// Copying failed; the system's reason. Nothing was left behind.
    case failed(String)
}

/// An Import in progress: what the progress modal shows.
struct RunningImport: Equatable {
    /// The file name until PDFKit has read the File, then its Title.
    fileprivate(set) var title: String
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
    /// thread, publishing `runningImport` meanwhile. Files that aren't
    /// readable, unlocked PDFs are rejected before anything is copied.
    func `import`(_ url: URL) async -> ImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Disable the UI before PDFKit reads the File: that alone can take a while.
        runningImport = RunningImport(title: url.deletingPathExtension().lastPathComponent)
        defer { runningImport = nil }

        switch await Task.detached(operation: { Self.check(url) }).value {
        case .failure(let rejection): return .rejected(rejection)
        case .success(let title?): runningImport?.title = title
        case .success(nil): break
        }

        let core = core, path = url.path
        // Reports arriving after the Import finished find no runningImport and do nothing.
        let relay = ProgressRelay { [weak self] fraction in
            guard let running = self?.runningImport else { return }
            self?.runningImport?.fraction = max(running.fraction, fraction)
        }
        do {
            let result = try await Task.detached { try core.import(source: path, progress: relay) }.value
            refresh()
            let (stored, isNew) =
                switch result {
                case .imported(let stored): (stored, true)
                case .alreadyImported(let stored): (stored, false)
                }
            guard let document = documents.first(where: { $0.id == stored.id }) else {
                return .failed("The imported file couldn't be opened.")
            }
            return isNew ? .opened(document) : .duplicate(document)
        } catch LibraryError.Failed(let message) {
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Deletes the Document and its File. If that fails, the Document stays in
    /// `documents`.
    func remove(_ document: LibraryDocument) {
        try? core.remove(id: document.id)
        refresh()
    }

    /// The Title of the File at `url` if it can be Imported, or why not. A
    /// File that can't be read at all isn't rejected (nil Title): copying it
    /// fails with the system's own reason. Reads the File, so keep it off the
    /// main thread.
    private nonisolated static func check(_ url: URL) -> Result<String?, ImportRejection> {
        if let pdf = PDFDocument(url: url) { return pdf.isLocked ? .failure(.locked) : .success(pdf.title) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .success(nil) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 5)) ?? Data()
        return .failure(head == Data("%PDF-".utf8) ? .unreadable : .notPDF)
    }

    /// Reloads `documents` from the core. Documents already listed keep their
    /// opened PDF. If the listing fails, `documents` stays as it was rather
    /// than looking as if everything was Removed.
    private func refresh() {
        guard let stored = try? core.documents() else { return }
        let listed = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        documents = stored.compactMap { listed[$0.id] ?? LibraryDocument($0) }
    }
}
