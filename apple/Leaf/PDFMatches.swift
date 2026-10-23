import PDFKit

#if os(iOS)
    import UIKit
#endif

/// `DocumentMatches` in a `ReaderPDFView`: runs `DocumentSearch`, and shows the
/// current match. On iOS all matches are marked on the pages, the current one
/// orange among the yellow others (PDFView's `highlightedSelections`); on macOS
/// the find bar marks them, and the current one is the view's selection.
@MainActor
final class PDFMatches: DocumentMatches {
    private weak var view: ReaderPDFView?
    let results: SearchResults
    /// Made with the first search, once the view has its Document and Table of Contents.
    private lazy var documentSearch = DocumentSearch(
        view?.document ?? PDFDocument(), contents: view?.contents ?? TableOfContents())
    /// Read with the first need for it: only the macOS find bar searches the text itself.
    private(set) lazy var text = ChunkedText(view?.document)
    private var matches: [DocumentSearch.Match] = []
    var didChange: () -> Void = {}
    private var isRefreshScheduled = false

    init(view: ReaderPDFView, results: SearchResults) {
        self.view = view
        self.results = results
        results.onChoose = { [weak self] in self?.makeCurrent($0) }
    }

    func search(_ query: DocumentSearch.Query, onMatch: @escaping @MainActor (Int) -> Void) {
        clear()
        documentSearch.search(
            query,
            onMatch: { [self] match in
                matches.append(match)
                results.append(.init(match))
                #if os(iOS)
                    match.selection.color = Self.otherColor
                #endif
                onMatch(matches.count - 1)
                refreshSoon()
            },
            onFinish: {})
    }

    func clear() {
        documentSearch.cancel()
        matches = []
        results.removeAll()
        #if os(iOS)
            view?.highlightedSelections = nil
        #endif
        didChange()
    }

    func makeCurrent(_ number: Int) {
        guard matches.indices.contains(number) else { return }
        #if os(iOS)
            if let old = results.current, matches.indices.contains(old) {
                matches[old].selection.color = Self.otherColor
            }
            matches[number].selection.color = Self.currentColor
        #else
            view?.currentSelection = matches[number].selection
        #endif
        results.current = number
        view?.reveal(matches[number].selection)
        refreshSoon()
    }

    func range(ofMatch number: Int) -> NSRange {
        let match = matches[number]
        return NSRange(
            location: text.range(ofChunkAt: match.pageIndex).location + match.range.location,
            length: match.range.length)
    }

    func beginSession() { view?.beginSearchSession() }
    func endSession() { view?.endSearchSession() }

    #if os(iOS)
        private static let otherColor = UIColor.systemYellow.withAlphaComponent(0.4)
        private static let currentColor = UIColor.systemOrange
    #endif

    /// Matches stream in one by one; PDFView takes all marks at once, and the
    /// bar its count, so both are updated together at the end of the turn.
    private func refreshSoon() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        Task { @MainActor in
            isRefreshScheduled = false
            #if os(iOS)
                view?.highlightedSelections = matches.map(\.selection)
            #endif
            didChange()
        }
    }

    #if os(macOS)
        func rects(forCharacterRange range: NSRange) -> [CGRect]? {
            guard let view, let selection = view.document?.selection(for: range, in: text) else { return nil }
            return selection.selectionsByLine().flatMap { line in
                line.pages.map { view.convert(line.bounds(for: $0), from: $0) }
            }
        }

        var visibleRanges: [NSRange] {
            guard let view, let document = view.document else { return [] }
            return view.visiblePages.map { text.range(ofChunkAt: document.index(for: $0)) }
        }
    #endif
}
