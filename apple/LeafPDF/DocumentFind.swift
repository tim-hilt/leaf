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
#elseif os(macOS)
    import AppKit
    import PDFKit

    /// The native macOS find bar (`NSTextFinder`) for a Reader. NSTextFinder does
    /// its own matching and can't be handed matches, so this client gives it the
    /// Document's text (see `DocumentText`) and it applies the reader's case and
    /// word-match options itself. It searches as they type; the match count,
    /// next and previous come with the bar, and the current match is the
    /// PDFView's selection. Made once the Reader has its Document.
    @MainActor
    final class DocumentFind: NSObject, @preconcurrency NSTextFinderClient {
        private weak var view: ReaderPDFView?
        let finder = NSTextFinder()
        /// NSTextFinder searches it on a background queue.
        private let text: DocumentText
        /// The current match, in the Document's text; empty before the first.
        private var selected = NSRange()

        init(view: ReaderPDFView) {
            self.view = view
            text = DocumentText(view.document)
            super.init()
            finder.client = self
            finder.isIncrementalSearchingEnabled = true
        }

        /// Shows the find bar.
        func present() { perform(.showFindInterface) }

        /// Goes to the next match of the bar's search, wrapping around.
        func next() { perform(.nextMatch) }

        /// Goes to the previous match of the bar's search, wrapping around.
        func previous() { perform(.previousMatch) }

        private func perform(_ action: NSTextFinder.Action) {
            // PDFView lays out inside its own scroll view, which hosts the bar.
            finder.findBarContainer = view?.documentView?.enclosingScrollView
            finder.performAction(action)
        }

        // MARK: NSTextFinderClient

        var isSelectable: Bool { true }
        var allowsMultipleSelection: Bool { false }
        var isEditable: Bool { false }

        // The text is read from NSTextFinder's search queue.

        nonisolated func stringLength() -> Int { text.length }

        nonisolated func string(
            at characterIndex: Int, effectiveRange outRange: NSRangePointer,
            endsWithSearchBoundary outFlag: UnsafeMutablePointer<ObjCBool>
        ) -> String {
            let (string, range) = text.chunk(at: characterIndex)
            outRange.pointee = range
            // A match never spans pages.
            outFlag.pointee = true
            return string
        }

        var firstSelectedRange: NSRange { selected }

        var selectedRanges: [NSValue] {
            get { [NSValue(range: selected)] }
            set { select(newValue.first?.rangeValue ?? NSRange()) }
        }

        /// NSTextFinder never sets the selection to a match it found; it only
        /// asks for the match to be scrolled into view. So that is where the
        /// current match changes.
        func scrollRangeToVisible(_ range: NSRange) {
            select(range)
            if let selection = view?.currentSelection { view?.reveal(selection) }
        }

        private func select(_ range: NSRange) {
            selected = range
            view?.currentSelection = selection(for: range)
        }

        func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
            outRange.pointee = NSRange(location: 0, length: text.length)
            return view ?? NSView()
        }

        func rects(forCharacterRange range: NSRange) -> [NSValue]? {
            guard let view, let selection = selection(for: range) else { return nil }
            return selection.selectionsByLine().flatMap { line in
                line.pages.map { NSValue(rect: view.convert(line.bounds(for: $0), from: $0)) }
            }
        }

        /// The pages on screen, which is where incremental matches are marked.
        var visibleCharacterRanges: [NSValue] {
            guard let view, let document = view.document else { return [] }
            return view.visiblePages.map { NSValue(range: text.range(ofPageAt: document.index(for: $0))) }
        }

        private func selection(for range: NSRange) -> PDFSelection? {
            view?.document?.selection(for: range, in: text)
        }
    }
#endif
