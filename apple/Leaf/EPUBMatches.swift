import Foundation
import LeafCore

/// `DocumentMatches` in a `ReaderEPUBView`: the Document Search finds the
/// matches in the core (`DocumentSearch` over the book's `DocumentText`), and
/// this marks them in the text, the current one apart, and shows the current
/// one.
@MainActor
final class EPUBMatches: DocumentMatches {
    private weak var view: ReaderEPUBView?
    let search: DocumentSearch
    var didChange: () -> Void = {}
    /// Matches stream in one by one; the page takes all marks at once, and the
    /// bar its count, so both are updated together.
    private lazy var refresh = CoalescedUpdate { [weak self] in
        guard let self else { return }
        view?.markMatches(search.matches, current: search.results.current)
        didChange()
    }

    init(view: ReaderEPUBView, results: SearchResults) {
        self.view = view
        search = DocumentSearch(text: DocumentText.of(view.book), contents: view.contents, results: results)
        results.onChoose = { [weak self] in self?.makeCurrent($0) }
    }

    func search(_ query: Query, onMatch: @escaping @MainActor (Int) -> Void) {
        clear()
        search.search(
            query,
            onMatch: { [self] match in
                onMatch(match.number)
                refresh.setNeeded()
            },
            onFinish: {})
    }

    func clear() {
        search.cancel()
        view?.markMatches([], current: nil)
        didChange()
    }

    func makeCurrent(_ number: Int) {
        guard search.matches.indices.contains(number) else { return }
        search.results.current = number
        view?.reveal(search.matches[number])
        refresh.setNeeded()
    }

    func beginSession() { view?.beginSearchSession() }
    func endSession() { view?.endSearchSession() }
}
