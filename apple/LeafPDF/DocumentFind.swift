#if os(iOS)
    import PDFKit
    import UIKit

    /// The native iOS find bar for a Reader, driven by Document Search. PDFView's
    /// built-in find session doesn't expose its matches, so this runs our own
    /// `UIFindInteraction` session over `FindableDocument`: the bar, the match
    /// count ("3 of 27"), next/previous and the page highlights all come from
    /// one set of matches. The bar passes on the reader's case and whole-word
    /// options, and searches as they type.
    @MainActor
    final class DocumentFind: NSObject, UIFindInteractionDelegate {
        private weak var view: ReaderPDFView?
        /// The system's find interaction; its session is ours.
        private(set) lazy var interaction = UIFindInteraction(sessionDelegate: self)
        /// The searchable object of the active session, which holds it only weakly.
        private var findable: FindableDocument?

        init(view: ReaderPDFView) {
            self.view = view
            super.init()
            view.addInteraction(interaction)
        }

        /// Shows the find bar.
        func present() { interaction.presentFindNavigator(showingReplace: false) }

        func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
            guard let reader = self.view, let document = reader.document else { return nil }
            let findable = FindableDocument(document: document, view: reader)
            self.findable = findable
            return UITextSearchingFindSession(searchableObject: findable)
        }

        func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
            findable?.stop()
            findable = nil
        }
    }

    /// A Document, searchable by the find bar. Ranges are matches of Document
    /// Search, numbered in the order they arrive, which is reading order.
    @MainActor
    private final class FindableDocument: NSObject, @preconcurrency UITextSearching {
        private let search: DocumentSearch
        private weak var view: ReaderPDFView?
        private var matchCount = 0
        /// Matches marked on the pages, by number; the style is on the selection's colour.
        private var marked: [Int: PDFSelection] = [:]
        private var isRefreshScheduled = false

        init(document: PDFDocument, view: ReaderPDFView) {
            search = DocumentSearch(document)
            self.view = view
        }

        func stop() {
            search.cancel()
            clearAllDecoratedFoundText()
        }

        // MARK: UITextSearching

        /// Searches always start from the first match.
        var selectedTextRange: UITextRange? { nil }

        func compare(_ foundRange: UITextRange, toRange: UITextRange, document: AnyHashable??) -> ComparisonResult {
            guard let a = foundRange as? FoundRange, let b = toRange as? FoundRange else { return .orderedSame }
            return a.number < b.number ? .orderedAscending : a.number > b.number ? .orderedDescending : .orderedSame
        }

        func performTextSearch(
            queryString string: String, options: UITextSearchOptions,
            resultAggregator aggregator: UITextSearchAggregator<AnyHashable?>
        ) {
            clearAllDecoratedFoundText()
            matchCount = 0
            search.search(
                DocumentSearch.Query(string, options: options),
                onMatch: { [self] match in
                    aggregator.foundRange(
                        FoundRange(number: matchCount, match: match), searchString: string, document: nil)
                    matchCount += 1
                },
                onFinish: { aggregator.finishedSearching() })
        }

        func decorate(foundTextRange range: UITextRange, document: AnyHashable??, usingStyle style: UITextSearchFoundTextStyle) {
            guard let found = range as? FoundRange else { return }
            switch style {
            case .normal:
                marked[found.number] = nil
            case .found:
                found.match.selection.color = .systemYellow.withAlphaComponent(0.4)
                marked[found.number] = found.match.selection
            case .highlighted:
                found.match.selection.color = .systemOrange
                marked[found.number] = found.match.selection
            @unknown default:
                break
            }
            refreshMarksSoon()
        }

        func clearAllDecoratedFoundText() {
            marked = [:]
            view?.highlightedSelections = nil
        }

        func scrollRangeToVisible(_ range: UITextRange, inDocument document: AnyHashable??) {
            if let found = range as? FoundRange { view?.reveal(found.match.selection) }
        }

        /// Decorating is called once per match as they stream in; PDFView takes
        /// them all at once, so they are applied together at the end of the turn.
        private func refreshMarksSoon() {
            guard !isRefreshScheduled else { return }
            isRefreshScheduled = true
            Task { @MainActor in
                isRefreshScheduled = false
                view?.highlightedSelections = Array(marked.values)
            }
        }
    }

    /// A match as the find bar sees it: an opaque range, ordered by `number`.
    private final class FoundRange: UITextRange {
        /// Position among the matches of its search, in reading order.
        let number: Int
        let match: DocumentSearch.Match

        init(number: Int, match: DocumentSearch.Match) {
            self.number = number
            self.match = match
        }

        // The bar only compares and decorates ranges, through `FindableDocument`.
        override var start: UITextPosition { UITextPosition() }
        override var end: UITextPosition { UITextPosition() }
        override var isEmpty: Bool { false }
    }

    extension DocumentSearch.Query {
        /// The reader's choices in the system find bar.
        @MainActor fileprivate init(_ text: String, options: UITextSearchOptions) {
            let wordMatch: DocumentSearch.WordMatch =
                switch options.wordMatchMethod {
                case .startsWith: .startsWith
                case .fullWord: .fullWord
                default: .contains
                }
            self.init(
                text, caseSensitive: !options.stringCompareOptions.contains(.caseInsensitive),
                wordMatch: wordMatch)
        }
    }
#endif
