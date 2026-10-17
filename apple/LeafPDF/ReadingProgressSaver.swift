import Foundation

/// Saves the Reading Progress of the Document in a Reader: the Place at the
/// top of the viewport, with the current time as Last Read. Saving is cheap
/// for the caller: the Library writes off the main thread.
///
/// Only opening saves an unmoved Place. So when several windows show the
/// Document, leaving or backgrounding the ones not in use never overrides the
/// Place of the one used last.
@MainActor
final class ReadingProgressSaver {
    private let library: LibraryModel
    private let document: LibraryDocument
    private let handle: ReaderHandle
    private let quietPeriod: Duration
    private var settling: Task<Void, Never>?
    /// The Place saved last; nil before the first save.
    private var saved: Place?

    /// `quietPeriod` is how long scrolling must stop before `scrolled()` saves.
    init(library: LibraryModel, document: LibraryDocument, handle: ReaderHandle, quietPeriod: Duration = .seconds(1)) {
        self.library = library
        self.document = document
        self.handle = handle
        self.quietPeriod = quietPeriod
    }

    /// The Reader opened the Document: saves now, which counts as reading it.
    func opened() { save(unlessUnmoved: false) }

    /// The viewport moved: saves once it has stopped for `quietPeriod`.
    func scrolled() {
        settling?.cancel()
        settling = Task {
            guard (try? await Task.sleep(for: quietPeriod)) != nil else { return }
            saveIfMoved()
        }
    }

    /// Saves now if the Place moved since the last save, e.g. when leaving.
    func saveIfMoved() { save(unlessUnmoved: true) }

    /// Saves the Place at the top of the viewport; nothing if the Reader has none.
    private func save(unlessUnmoved: Bool) {
        settling?.cancel()
        guard let place = handle.view?.topOfViewport, !(unlessUnmoved && place == saved) else { return }
        saved = place
        let library = library, document = document
        Task { await library.saveProgress(place, of: document) }
    }
}
