#if os(iOS)
    import PDFKit
    import UIKit

    /// The native iOS find bar for a Reader, driven by Document Search. PDFView's
    /// built-in find session doesn't expose its matches, so this runs our own
    /// `UIFindSession`: the bar, the match count ("3 of 27"), next/previous, the
    /// page highlights and the results list all come from one set of matches
    /// (`SearchResults`). The bar passes on the reader's case and whole-word
    /// options, and searches as they type. On compact widths the bar's options
    /// have a "Show All Results" item, which calls `onShowResults`.
    @MainActor
    final class DocumentFind: NSObject, UIFindInteractionDelegate {
        private weak var view: ReaderPDFView?
        private let results: SearchResults
        /// The system's find interaction; its session is ours.
        private(set) lazy var interaction = UIFindInteraction(sessionDelegate: self)
        /// Called when the reader asks for the list of matches in the find bar's options.
        var onShowResults: () -> Void = {}

        init(view: ReaderPDFView, results: SearchResults) {
            self.view = view
            self.results = results
            super.init()
            interaction.optionsMenuProvider = { [weak self] defaults in
                UIMenu(children: defaults + (self?.resultsMenu ?? []))
            }
            view.addInteraction(interaction)
        }

        /// Shows the find bar.
        func present() { interaction.presentFindNavigator(showingReplace: false) }

        /// The options item that opens the list, on compact widths, where there is no sidebar.
        private var resultsMenu: [UIMenuElement] {
            guard view?.traitCollection.horizontalSizeClass == .compact else { return [] }
            let show = UIAction(
                title: "Show All Results", image: UIImage(systemName: "list.bullet"),
                attributes: results.matches.isEmpty ? .disabled : []
            ) { [weak self] _ in self?.onShowResults() }
            return [UIMenu(options: .displayInline, children: [show])]
        }

        func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
            guard let reader = self.view, let document = reader.document else { return nil }
            return FindSession(document: document, view: reader, results: results, interaction: interaction)
        }

        func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
            results.isFindBarOpen = true
            view?.beginSearchSession()
        }

        func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
            (session as? FindSession)?.stop()
            results.isFindBarOpen = false
            view?.endSearchSession()
        }
    }

    /// One find session over a Document: searches as the bar asks, numbers the
    /// matches as they arrive (reading order) and keeps the current one.
    @MainActor
    private final class FindSession: UIFindSession {
        private let search: DocumentSearch
        private weak var view: ReaderPDFView?
        private let results: SearchResults
        private weak var interaction: UIFindInteraction?
        private var isRefreshScheduled = false

        init(document: PDFDocument, view: ReaderPDFView, results: SearchResults, interaction: UIFindInteraction) {
            search = DocumentSearch(document, contents: view.contents)
            self.view = view
            self.results = results
            self.interaction = interaction
            super.init()
            results.onChoose = { [weak self] in self?.makeCurrent($0) }
        }

        /// Ends the session: its matches are forgotten and unmarked.
        func stop() {
            invalidateFoundResults()
            results.onChoose = { _ in }
        }

        override var resultCount: Int { results.matches.count }
        override var highlightedResultIndex: Int { results.current ?? NSNotFound }

        override func performSearch(query: String, options: UITextSearchOptions?) {
            invalidateFoundResults()
            search.search(
                DocumentSearch.Query(query, options: options),
                onMatch: { [self] match in
                    results.append(match)
                    match.selection.color = Self.otherColor
                    if results.current == nil { makeCurrent(0) }
                    refreshSoon()
                },
                onFinish: {})
        }

        override func highlightNextResult(in direction: UITextStorageDirection) {
            let count = results.matches.count
            guard count > 0 else { return }
            let step = direction == .backward ? count - 1 : 1
            makeCurrent(((results.current ?? -step) + step) % count)
        }

        override func invalidateFoundResults() {
            search.cancel()
            results.removeAll()
            view?.highlightedSelections = nil
            interaction?.updateResultCount()
        }

        /// Makes match `number` the current one, orange among the others, and shows it.
        private func makeCurrent(_ number: Int) {
            guard results.matches.indices.contains(number) else { return }
            if let old = results.current { results.matches[old].selection.color = Self.otherColor }
            results.current = number
            results.matches[number].selection.color = Self.currentColor
            view?.reveal(results.matches[number].selection)
            refreshSoon()
        }

        private static let otherColor = UIColor.systemYellow.withAlphaComponent(0.4)
        private static let currentColor = UIColor.systemOrange

        /// Matches stream in one by one; PDFView takes all marks at once, and
        /// the bar its count, so both are updated together at the end of the turn.
        private func refreshSoon() {
            guard !isRefreshScheduled else { return }
            isRefreshScheduled = true
            Task { @MainActor in
                isRefreshScheduled = false
                view?.highlightedSelections = results.matches.map(\.selection)
                interaction?.updateResultCount()
            }
        }
    }

    extension DocumentSearch.Query {
        /// The reader's choices in the system find bar.
        @MainActor fileprivate init(_ text: String, options: UITextSearchOptions?) {
            let wordMatch: DocumentSearch.WordMatch =
                switch options?.wordMatchMethod {
                case .startsWith: .startsWith
                case .fullWord: .fullWord
                default: .contains
                }
            self.init(
                text, caseSensitive: !(options?.stringCompareOptions.contains(.caseInsensitive) ?? true),
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
    ///
    /// For the results list, Document Search runs alongside while the bar is
    /// showing, on the bar's search string and options, which it keeps in the
    /// system's find pasteboard. NSTextFinder reports neither its matches nor
    /// when the search changes, so the pasteboard is watched, and the current
    /// match NSTextFinder scrolls to is looked up in the list.
    @MainActor
    final class DocumentFind: NSObject, @preconcurrency NSTextFinderClient {
        private weak var view: ReaderPDFView?
        private let results: SearchResults
        let finder = NSTextFinder()
        /// NSTextFinder searches it on a background queue.
        private let text: DocumentText
        /// The current match, in the Document's text; empty before the first.
        private var selected = NSRange()
        private let search: DocumentSearch
        /// The search the list shows; nil while the bar is hidden.
        private var listed: DocumentSearch.Query?
        private var barObservation: NSKeyValueObservation?
        private var watch: Timer?
        /// The find pasteboard's change count when the list was made, so an
        /// unchanged pasteboard isn't read again.
        private var listedChange: Int?

        init(view: ReaderPDFView, results: SearchResults) {
            self.view = view
            self.results = results
            text = DocumentText(view.document)
            search = DocumentSearch(view.document ?? PDFDocument(), contents: view.contents)
            super.init()
            finder.client = self
            finder.isIncrementalSearchingEnabled = true
            results.onChoose = { [weak self] in self?.choose($0) }
        }

        /// Shows the find bar.
        func present() { perform(.showFindInterface) }

        /// Goes to the next match of the bar's search, wrapping around.
        func next() { perform(.nextMatch) }

        /// Goes to the previous match of the bar's search, wrapping around.
        func previous() { perform(.previousMatch) }

        private func perform(_ action: NSTextFinder.Action) {
            // PDFView lays out inside its own scroll view, which hosts the bar.
            let container = view?.documentView?.enclosingScrollView
            finder.findBarContainer = container
            if barObservation == nil {
                barObservation = container?.observe(\.isFindBarVisible, options: [.new]) { [weak self] _, change in
                    let isVisible = change.newValue ?? false
                    MainActor.assumeIsolated { self?.barVisibilityChanged(isVisible) }
                }
            }
            finder.performAction(action)
        }

        // MARK: Results list

        private func barVisibilityChanged(_ isVisible: Bool) {
            results.isFindBarOpen = isVisible
            guard isVisible else {
                view?.endSearchSession()
                watch?.invalidate()
                watch = nil
                listed = nil
                listedChange = nil
                search.cancel()
                results.removeAll()
                return
            }
            view?.beginSearchSession()
            refreshList()
            watch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                MainActor.assumeIsolated { self.refreshList() }
            }
        }

        /// Lists the matches of the bar's search, if it has changed since the list was made.
        private func refreshList() {
            let pasteboard = NSPasteboard(name: .find)
            guard pasteboard.changeCount != listedChange else { return }
            listedChange = pasteboard.changeCount
            let query = DocumentSearch.Query(findPasteboard: pasteboard)
            guard query != listed else { return }
            listed = query
            results.removeAll()
            search.search(
                query,
                onMatch: { [self] match in
                    results.append(match)
                    if location(of: match) == selected.location, selected.length > 0 {
                        results.current = results.matches.count - 1
                    }
                },
                onFinish: {})
        }

        /// Where the match starts in the Document's text.
        private func location(of match: DocumentSearch.Match) -> Int {
            text.range(ofPageAt: match.pageIndex).location + match.range.location
        }

        /// Goes to the listed match with the given number, as if the bar had found it.
        private func choose(_ number: Int) {
            guard results.matches.indices.contains(number) else { return }
            let match = results.matches[number]
            scrollRangeToVisible(NSRange(location: location(of: match), length: match.range.length))
            // NSTextFinder keeps its own place in its matches; this makes it
            // go on from the selection.
            finder.noteClientStringWillChange()
        }

        /// Number of the listed match starting at `location`, if there is one.
        private func number(ofMatchAt location: Int) -> Int? {
            let matches = results.matches
            var low = 0
            var high = matches.count
            while low < high {
                let mid = (low + high) / 2
                if self.location(of: matches[mid]) < location { low = mid + 1 } else { high = mid }
            }
            return low < matches.count && self.location(of: matches[low]) == location ? low : nil
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
            results.current = range.length > 0 ? number(ofMatchAt: range.location) : nil
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

    extension DocumentSearch.Query {
        /// The search in the system's find pasteboard: the search string and
        /// options the find bar shows and every app's find bar shares.
        @MainActor init(findPasteboard pasteboard: NSPasteboard) {
            let options =
                pasteboard.data(forType: .textFinderOptions)
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            let caseInsensitive = options[
                NSPasteboard.PasteboardType.TextFinderOptionKey.textFinderCaseInsensitiveKey.rawValue]
            let matching = options[NSPasteboard.PasteboardType.TextFinderOptionKey.textFinderMatchingTypeKey.rawValue]
            let wordMatch: DocumentSearch.WordMatch =
                switch (matching as? Int).flatMap(NSTextFinder.MatchingType.init(rawValue:)) {
                case .startsWith: .startsWith
                case .endsWith: .endsWith
                case .fullWord: .fullWord
                default: .contains
                }
            self.init(
                pasteboard.string(forType: .string) ?? "", caseSensitive: (caseInsensitive as? Bool) == false,
                wordMatch: wordMatch)
        }
    }
#endif
