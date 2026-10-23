import Foundation

/// `DocumentMatches` in a `ReaderEPUBView`: runs `EPUBSearch`, marks the matches
/// in the text, the current one apart, and shows the current one.
@MainActor
final class EPUBMatches: DocumentMatches {
    private weak var view: ReaderEPUBView?
    let results: SearchResults
    private let search: EPUBSearch
    let text: ChunkedText
    private var matches: [EPUBSearch.Match] = []
    var didChange: () -> Void = {}
    /// Matches stream in one by one; the page takes all marks at once, and the
    /// bar its count, so both are updated together.
    private lazy var refresh = CoalescedUpdate { [weak self] in
        guard let self else { return }
        view?.markMatches(matches, current: results.current)
        didChange()
    }

    init(view: ReaderEPUBView, results: SearchResults) {
        self.view = view
        self.results = results
        text = ChunkedText(view.book)
        search = EPUBSearch(text, contents: view.contents)
        results.onChoose = { [weak self] in self?.makeCurrent($0) }
    }

    func search(_ query: DocumentSearch.Query, onMatch: @escaping @MainActor (Int) -> Void) {
        clear()
        search.search(
            query,
            onMatch: { [self] match in
                matches.append(match)
                results.append(.init(match))
                onMatch(matches.count - 1)
                refresh.setNeeded()
            },
            onFinish: {})
    }

    func clear() {
        search.cancel()
        matches = []
        results.removeAll()
        view?.markMatches([], current: nil)
        didChange()
    }

    func makeCurrent(_ number: Int) {
        guard matches.indices.contains(number) else { return }
        results.current = number
        view?.reveal(matches[number])
        refresh.setNeeded()
    }

    func range(ofMatch number: Int) -> NSRange {
        text.range(matches[number].range, inChunkAt: matches[number].spineIndex)
    }

    func beginSession() { view?.beginSearchSession() }
    func endSession() { view?.endSearchSession() }
}
