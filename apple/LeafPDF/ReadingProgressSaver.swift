import Foundation

/// Saves the Reading Progress of the Document in a Reader: the Place at the
/// top of the viewport, with the current time as Last Read. Saving is cheap
/// for the caller: the Library writes off the main thread.
@MainActor
final class ReadingProgressSaver {
    private let library: LibraryModel
    private let document: LibraryDocument
    private let handle: ReaderHandle
    private let quietPeriod: Duration
    private var settling: Task<Void, Never>?

    /// `quietPeriod` is how long scrolling must stop before `scrolled()` saves.
    init(library: LibraryModel, document: LibraryDocument, handle: ReaderHandle, quietPeriod: Duration = .seconds(1)) {
        self.library = library
        self.document = document
        self.handle = handle
        self.quietPeriod = quietPeriod
    }

    /// The viewport moved: saves once it has stopped for `quietPeriod`.
    func scrolled() {
        settling?.cancel()
        settling = Task {
            guard (try? await Task.sleep(for: quietPeriod)) != nil else { return }
            saveNow()
        }
    }

    /// Saves the Place at the top of the viewport now; nothing if the Reader has none.
    func saveNow() {
        settling?.cancel()
        guard let place = handle.view?.topOfViewport else { return }
        let library = library, document = document
        Task { await library.saveProgress(place, of: document) }
    }
}
