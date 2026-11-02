import LeafCore
import PDFKit

#if os(iOS)
    import UIKit
#endif

/// `DocumentMatches` in a `ReaderPDFView`: the Document Search finds the
/// matches in the core (`DocumentSearch` over the Document's `DocumentText`),
/// and this marks them on the pages and shows the current one. On iOS all
/// matches are marked on the pages, the current one orange among the yellow
/// others (PDFView's `highlightedSelections`); on macOS the find bar marks
/// them, and the current one is the view's selection.
@MainActor
final class PDFMatches: DocumentMatches {
    private weak var view: ReaderPDFView?
    let results: SearchResults
    /// Made with the first search, once the view has its Document and Table of Contents.
    private(set) lazy var search = DocumentSearch(
        text: DocumentText.of(view?.document ?? PDFDocument()),
        contents: view?.contents ?? TableOfContents(entries: []),
        results: results)
    /// The selection of each match in `search.matches`, in the order they
    /// arrived; made as one arrives. A nil one leaves its match unmarked.
    private var selections: [PDFSelection?] = []
    var didChange: () -> Void = {}
    /// Matches stream in one by one; PDFView takes all marks at once, and the
    /// bar its count, so both are updated together.
    private lazy var refresh = CoalescedUpdate { [weak self] in
        guard let self else { return }
        #if os(iOS)
            view?.highlightedSelections = selections.compactMap { $0 }
        #endif
        didChange()
    }

    init(view: ReaderPDFView, results: SearchResults) {
        self.view = view
        self.results = results
        results.onChoose = { [weak self] in self?.makeCurrent($0) }
    }

    func search(_ query: Query, onMatch: @escaping @MainActor (Int) -> Void) {
        clear()
        search.search(
            query,
            onMatch: { [self] match in
                let selection = self.selection(for: match)
                #if os(iOS)
                    selection?.color = Self.otherColor
                #endif
                selections.append(selection)
                onMatch(match.number)
                refresh.setNeeded()
            },
            onFinish: {})
    }

    func clear() {
        search.cancel()
        selections = []
        #if os(iOS)
            view?.highlightedSelections = nil
        #endif
        didChange()
    }

    func makeCurrent(_ number: Int) {
        guard search.matches.indices.contains(number), selections.indices.contains(number) else { return }
        #if os(iOS)
            if let old = results.current, selections.indices.contains(old) {
                selections[old]?.color = Self.otherColor
            }
            selections[number]?.color = Self.currentColor
        #else
            if let selection = selections[number] { view?.currentSelection = selection }
        #endif
        results.current = number
        if let selection = selections[number] { view?.reveal(selection) }
        refresh.setNeeded()
    }

    /// The selection of the match, on its page; nil if the page has no text there.
    private func selection(for match: DocumentSearch.Match) -> PDFSelection? {
        view?.document?.page(at: match.chunkIndex)?.selection(for: match.range)
    }

    func beginSession() { view?.beginSearchSession() }
    func endSession() { view?.endSearchSession() }

    #if os(iOS)
        private static let otherColor = UIColor.systemYellow.withAlphaComponent(0.4)
        private static let currentColor = UIColor.systemOrange
    #endif

    #if os(macOS)
        func rects(forCharacterRange range: NSRange) -> [CGRect]? {
            guard let view, let selection = view.document?.selection(for: range, in: text) else { return nil }
            return selection.selectionsByLine().flatMap { line in
                line.pages.map { view.convert(line.bounds(for: $0), from: $0) }
            }
        }

        var visibleRanges: [NSRange] {
            guard let view, let document = view.document else { return [] }
            return view.visiblePages.compactMap {
                text.chunk(index: UInt32(clamping: document.index(for: $0)))?.range
            }
        }
    #endif
}
