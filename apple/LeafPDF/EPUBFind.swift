#if os(iOS)
    import UIKit

    /// The native iOS find bar for a `ReaderEPUBView`, driven by Document Search
    /// (`EPUBMatches`): a `UIFindSession` of our own, so the bar's count, next and
    /// previous, the marks in the text and the results list all come from one set
    /// of matches. The bar passes on the reader's case and whole-word options and
    /// searches as they type; on compact widths its options have "Show All
    /// Results", which calls `onShowResults`.
    @MainActor
    final class EPUBFind: NSObject, UIFindInteractionDelegate {
        private weak var view: ReaderEPUBView?
        private let matches: EPUBMatches
        private let results: SearchResults
        /// The system's find interaction; its session is ours.
        private(set) lazy var interaction = UIFindInteraction(sessionDelegate: self)
        /// Called when the reader asks for the list of matches in the find bar's options.
        var onShowResults: () -> Void = {}

        init(view: ReaderEPUBView, matches: EPUBMatches, results: SearchResults) {
            self.view = view
            self.matches = matches
            self.results = results
            super.init()
            interaction.offerResults(of: results, in: view) { [weak self] in self?.onShowResults() }
            view.addInteraction(interaction)
        }

        /// Shows the find bar.
        func present() { interaction.presentFindNavigator(showingReplace: false) }

        func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
            EPUBFindSession(matches: matches, results: results, interaction: interaction)
        }

        func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
            results.isFindBarOpen = true
            view?.beginSearchSession()
        }

        func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
            (session as? EPUBFindSession)?.stop()
            results.isFindBarOpen = false
            view?.endSearchSession()
        }
    }

    /// One find session over a book: searches as the bar asks and keeps the current match.
    @MainActor
    private final class EPUBFindSession: UIFindSession {
        private let matches: EPUBMatches
        private let results: SearchResults
        private weak var interaction: UIFindInteraction?

        init(matches: EPUBMatches, results: SearchResults, interaction: UIFindInteraction) {
            self.matches = matches
            self.results = results
            self.interaction = interaction
            super.init()
            matches.didChange = { [weak self] in self?.interaction?.updateResultCount() }
        }

        /// Ends the session: its matches are forgotten and unmarked.
        func stop() {
            invalidateFoundResults()
            matches.didChange = {}
        }

        override var resultCount: Int { results.matches.count }
        override var highlightedResultIndex: Int { results.current ?? NSNotFound }

        override func performSearch(query: String, options: UITextSearchOptions?) {
            matches.search(DocumentSearch.Query(query, options: options)) { [matches] number in
                if number == 0 { matches.makeCurrent(0) }
            }
        }

        override func highlightNextResult(in direction: UITextStorageDirection) {
            let count = results.matches.count
            guard count > 0 else { return }
            let step = direction == .backward ? count - 1 : 1
            matches.makeCurrent(((results.current ?? -step) + step) % count)
        }

        override func invalidateFoundResults() { matches.clear() }
    }
#elseif os(macOS)
    import AppKit

    /// The native macOS find bar (`NSTextFinder`) for a `ReaderEPUBView`.
    /// NSTextFinder does its own matching and can't be handed matches, so this
    /// client gives it the book's text (the core's text of the spine items, end to
    /// end) and it applies the reader's case and word-match options itself. It
    /// searches as they type; the match count, next and previous come with the bar.
    /// It draws nothing itself: the current match is marked in the text by
    /// `EPUBMatches`. The bar sits at the top of the view (`ReaderEPUBView` is its
    /// container).
    ///
    /// For the results list, Document Search runs alongside while the bar is
    /// showing, on the bar's search string and options, which it keeps in the
    /// system's find pasteboard. NSTextFinder reports neither its matches nor when
    /// the search changes, so the pasteboard is watched, and the current match
    /// NSTextFinder scrolls to is looked up in the list.
    @MainActor
    final class EPUBFind: NSObject, @preconcurrency NSTextFinderClient {
        private weak var view: ReaderEPUBView?
        private let matches: EPUBMatches
        private let results: SearchResults
        let finder = NSTextFinder()
        /// NSTextFinder searches it on a background queue.
        private let text: ChunkedText
        /// The current match, in the book's text; empty before the first.
        private var selected = NSRange()
        /// The search the list shows; nil while the bar is hidden.
        private var listed: DocumentSearch.Query?
        private var watch: Timer?
        /// The find pasteboard's change count when the list was made, so an
        /// unchanged pasteboard isn't read again.
        private var listedChange: Int?

        init(view: ReaderEPUBView, matches: EPUBMatches, results: SearchResults) {
            self.view = view
            self.matches = matches
            self.results = results
            text = matches.text
            super.init()
            finder.client = self
            finder.findBarContainer = view
            finder.isIncrementalSearchingEnabled = true
            results.onChoose = { [weak self] in self?.choose($0) }
        }

        /// Shows the find bar.
        func present() { finder.performAction(.showFindInterface) }

        /// Goes to the next match of the bar's search, wrapping around.
        func next() { finder.performAction(.nextMatch) }

        /// Goes to the previous match of the bar's search, wrapping around.
        func previous() { finder.performAction(.previousMatch) }

        // MARK: Results list

        /// Called by the view as its find bar shows or hides.
        func barVisibilityChanged(_ isVisible: Bool) {
            results.isFindBarOpen = isVisible
            guard isVisible else {
                view?.endSearchSession()
                watch?.invalidate()
                watch = nil
                listed = nil
                listedChange = nil
                matches.clear()
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
            matches.search(query) { [self] number in
                if location(of: matches.matches[number]) == selected.location, selected.length > 0 {
                    matches.makeCurrent(number)
                }
            }
        }

        /// Where the match starts in the book's text.
        private func location(of match: EPUBSearch.Match) -> Int {
            text.range(ofChunkAt: match.spineIndex).location + match.range.location
        }

        /// Goes to the listed match with the given number, as if the bar had found it.
        private func choose(_ number: Int) {
            guard matches.matches.indices.contains(number) else { return }
            let match = matches.matches[number]
            selected = NSRange(location: location(of: match), length: match.range.length)
            matches.makeCurrent(number)
            // NSTextFinder keeps its own place in its matches; this makes it
            // go on from the selection.
            finder.noteClientStringWillChange()
        }

        /// Number of the listed match starting at `location`, if there is one.
        private func number(ofMatchAt location: Int) -> Int? {
            let found = matches.matches
            var low = 0
            var high = found.count
            while low < high {
                let mid = (low + high) / 2
                if self.location(of: found[mid]) < location { low = mid + 1 } else { high = mid }
            }
            return low < found.count && self.location(of: found[low]) == location ? low : nil
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
            // A match never spans spine items.
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
        func scrollRangeToVisible(_ range: NSRange) { select(range) }

        private func select(_ range: NSRange) {
            selected = range
            guard range.length > 0, let number = number(ofMatchAt: range.location) else {
                results.current = nil
                return
            }
            matches.makeCurrent(number)
        }

        func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
            outRange.pointee = NSRange(location: 0, length: text.length)
            return view ?? NSView()
        }

        /// The text is in a web page, whose layout the client can't read
        /// synchronously: matches are marked in the page instead.
        func rects(forCharacterRange range: NSRange) -> [NSValue]? { nil }

        var visibleCharacterRanges: [NSValue] { [NSValue(range: NSRange(location: 0, length: text.length))] }
    }
#endif
