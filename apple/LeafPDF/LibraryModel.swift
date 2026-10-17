import LeafCore
import Observation
import PDFKit

/// A Document in the Library. Holds no open PDF: the Reader opens `file`.
struct LibraryDocument: Identifiable, Hashable {
    let id: String
    /// The stored File.
    let file: URL
    /// Read from the PDF at Import or by the Library's background pass; nil until then.
    fileprivate(set) var details: DocumentDetails?

    /// The name the File had when it was Imported.
    var fileName: String { file.lastPathComponent }
    /// The saved Title, or the file name without extension until it is read.
    var title: String { details?.title ?? file.deletingPathExtension().lastPathComponent }
    var author: String? { details?.author }

    fileprivate init(_ stored: LeafCore.Document, details: DocumentDetails?) {
        id = stored.id
        file = URL(fileURLWithPath: stored.path)
        self.details = details
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
/// Documents, newest Import first, each with its saved Title and Author. One
/// per app, shared by all windows.
@MainActor @Observable
final class LibraryModel {
    private(set) var documents: [LibraryDocument] = []
    /// Non-nil from the start of an Import until it finishes. The UI is
    /// disabled meanwhile.
    private(set) var runningImport: RunningImport?
    @ObservationIgnored private let core: LeafCore.Library
    @ObservationIgnored private let saved: DetailsStore
    @ObservationIgnored private let covers: CoverStore

    /// Opens the Library folder at `root`, creating it if needed, with Titles
    /// and Authors saved in `detailsFile` and Covers in `coversFolder`. Documents without saved details are
    /// listed by file name; a low-priority background pass then reads them
    /// from the PDFs, one at a time.
    init(root: URL, detailsFile: URL, coversFolder: URL) throws {
        core = try LeafCore.Library.open(root: root.path)
        saved = DetailsStore(file: detailsFile)
        covers = CoverStore(folder: coversFolder)
        refresh()
        readMissingDetails()
    }

    /// The Library in a hidden folder in Application Support, with Covers in
    /// the system Caches folder.
    static func inApplicationSupport() throws -> LibraryModel {
        let files = FileManager.default
        let support = try files.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try LibraryModel(
            root: support.appending(path: "Library", directoryHint: .isDirectory),
            detailsFile: support.appending(path: "Details.json"),
            coversFolder: caches.appending(path: "Covers", directoryHint: .isDirectory))
    }

    /// The saved Cover of `document`, loaded off the main thread, or nil if
    /// there is none. Cheap, so safe to call while scrolling; never renders.
    func savedCover(for document: LibraryDocument) async -> CGImage? {
        let covers = covers, id = document.id
        return await Task.detached { covers.saved(id) }.value
    }

    /// The Cover of `document`: the saved one, or page 1 rendered off the main
    /// thread and saved. Nil if it can't be rendered; the Gallery then keeps
    /// the placeholder. A caller that is already cancelled gets nil without
    /// any rendering, so requests of cells that scrolled away are dropped.
    func cover(for document: LibraryDocument) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let covers = covers, id = document.id, file = document.file
        return await Task.detached { covers.cover(id: id, file: file) }.value
    }

    /// Copies the File at `url` into the Library without blocking the main
    /// thread, publishing `runningImport` meanwhile. Files that aren't
    /// readable, unlocked PDFs are rejected before anything is copied. The
    /// Document's Title, Author and Cover are saved before this returns.
    func `import`(_ url: URL) async -> ImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Disable the UI before PDFKit reads the File: that alone can take a while.
        runningImport = RunningImport(title: url.deletingPathExtension().lastPathComponent)
        defer { runningImport = nil }

        let read: ReadPDF?
        let covers = covers
        switch await Task.detached(operation: { Self.check(url, covers: covers) }).value {
        case .failure(let rejection): return .rejected(rejection)
        case .success(let details): read = details
        }
        if let read { runningImport?.title = read.details.title }

        let core = core, path = url.path
        // Reports arriving after the Import finished find no runningImport and do nothing.
        let relay = ProgressRelay { [weak self] fraction in
            guard let running = self?.runningImport else { return }
            self?.runningImport?.fraction = max(running.fraction, fraction)
        }
        do {
            let result = try await Task.detached { try core.import(source: path, progress: relay) }.value
            let (stored, isNew) =
                switch result {
                case .imported(let stored): (stored, true)
                case .alreadyImported(let stored): (stored, false)
                }
            if let read {
                if saved[stored.id] == nil { saved[stored.id] = read.details }
                if let cover = read.cover { covers.save(cover, id: stored.id) }
            }
            refresh()
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

    /// Deletes the Document, its File and its saved Title, Author and Cover. If that
    /// fails, the Document stays in `documents`.
    func remove(_ document: LibraryDocument) {
        if (try? core.remove(id: document.id)) != nil {
            saved[document.id] = nil
            covers.remove(document.id)
        }
        refresh()
    }

    /// What Import reads from the PDF it opened to check the File.
    private struct ReadPDF: Sendable {
        let details: DocumentDetails
        let cover: CGImage?
    }

    /// What the File at `url` yields if it can be Imported, or why not. A File
    /// that can't be read at all isn't rejected (nil): copying it fails with
    /// the system's own reason. Reads the File and renders its Cover, so keep
    /// it off the main thread.
    private nonisolated static func check(_ url: URL, covers: CoverStore) -> Result<ReadPDF?, ImportRejection> {
        if let pdf = PDFDocument(url: url) {
            return pdf.isLocked ? .failure(.locked) : .success(ReadPDF(details: pdf.details, cover: covers.render(pdf)))
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .success(nil) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 5)) ?? Data()
        return .failure(head == Data("%PDF-".utf8) ? .unreadable : .notPDF)
    }

    /// Reloads `documents` from the core, with their saved details. If the
    /// listing fails, `documents` stays as it was rather than looking as if
    /// everything was Removed.
    private func refresh() {
        guard let stored = try? core.documents() else { return }
        documents = stored.map { LibraryDocument($0, details: saved[$0.id]) }
    }

    /// Reads the details of Documents that have none from their PDFs, one at a
    /// time at background priority, publishing each as it arrives. A PDF that
    /// can't be read is skipped and tried again at the next launch.
    private func readMissingDetails() {
        let missing = documents.filter { $0.details == nil }.map { ($0.id, $0.file) }
        guard !missing.isEmpty else { return }
        Task(priority: .background) { [weak self] in
            for (id, file) in missing {
                let read = await Task.detached(priority: .background) { PDFDocument(url: file)?.details }.value
                guard let self else { return }
                self.publish(read, for: id)
            }
        }
    }

    /// Saves `details` for Document `id` unless it was Removed or already has some.
    private func publish(_ details: DocumentDetails?, for id: String) {
        guard let details, saved[id] == nil, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        saved[id] = details
        documents[index].details = details
    }
}
