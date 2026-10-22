import Foundation

/// The matches of the Document Search going on in a `ReaderEPUBView`, whichever
/// find bar drives it: runs `EPUBSearch`, fills the results list (`SearchResults`),
/// and keeps the matches marked in the text, the current one apart, and the
/// current one in view. The find bar's adapter (`EPUBFind`) asks it to search,
/// to clear and to make a match current; choosing a match in the list makes it
/// current too, unless the adapter takes that over. Runs on the main actor.
///
/// Matches are numbered as in `SearchResults`, from 0 in reading order.
@MainActor
final class EPUBMatches {
    private weak var view: ReaderEPUBView?
    private let results: SearchResults
    private let search: EPUBSearch
    /// The book's text, which the matches are positions in.
    let text: ChunkedText
    private(set) var matches: [EPUBSearch.Match] = []
    /// Called, once per turn of the main loop at most, after matches arrived or
    /// the current one changed, for the bar to update its count.
    var didChange: () -> Void = {}
    private var isRefreshScheduled = false

    init(view: ReaderEPUBView, results: SearchResults) {
        self.view = view
        self.results = results
        text = ChunkedText(view.book)
        search = EPUBSearch(text, contents: view.contents)
        results.onChoose = { [weak self] in self?.makeCurrent($0) }
    }

    /// Replaces the matches with those of `query`, as they are found. `onMatch`
    /// is called with the number of each new match.
    func search(_ query: DocumentSearch.Query, onMatch: @escaping @MainActor (Int) -> Void = { _ in }) {
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

    /// Forgets every match, and unmarks them.
    func clear() {
        search.cancel()
        matches = []
        results.removeAll()
        view?.markMatches([], current: nil)
        didChange()
    }

    /// Makes match `number` the current one and shows it.
    func makeCurrent(_ number: Int) {
        guard matches.indices.contains(number) else { return }
        results.current = number
        view?.reveal(matches[number])
        refreshSoon()
    }

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
