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
    private var isRefreshScheduled = false

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
                refreshSoon()
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
        refreshSoon()
    }

    func range(ofMatch number: Int) -> NSRange {
        let match = matches[number]
        return NSRange(
            location: text.range(ofChunkAt: match.spineIndex).location + match.range.location,
            length: match.range.length)
    }

    func beginSession() { view?.beginSearchSession() }
    func endSession() { view?.endSearchSession() }

    /// Matches stream in one by one; the page takes all marks at once, and the
    /// bar its count, so both are updated together at the end of the turn.
    private func refreshSoon() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        Task { @MainActor in
            isRefreshScheduled = false
            view?.markMatches(matches, current: results.current)
            didChange()
        }
    }
}
