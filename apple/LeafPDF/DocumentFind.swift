#if os(iOS)
    import UIKit

    /// The native iOS find bar for a Reader, whatever its Format, driven by
    /// Document Search. The system's find session can't be handed matches, so
    /// this runs our own `UIFindSession`: the bar, the match count ("3 of 27"),
    /// next/previous, the marks in the document and the results list all come
    /// from one set of matches (`DocumentMatches`). The bar passes on the
    /// reader's case and whole-word options, and searches as they type. On
    /// compact widths the bar's options have a "Show All Results" item, which
    /// calls `onShowResults`.
    @MainActor
    final class DocumentFind: NSObject, UIFindInteractionDelegate {
        private let matches: any DocumentMatches
        /// The system's find interaction; its session is ours.
        private(set) lazy var interaction = UIFindInteraction(sessionDelegate: self)
        /// Called when the reader asks for the list of matches in the find bar's options.
        var onShowResults: () -> Void = {}

        init(view: UIView, matches: any DocumentMatches) {
            self.matches = matches
            super.init()
            interaction.offerResults(of: matches.results, in: view) { [weak self] in self?.onShowResults() }
            view.addInteraction(interaction)
        }

        /// Shows the find bar.
        func present() { interaction.presentFindNavigator(showingReplace: false) }

        func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
            FindSession(matches: matches, interaction: interaction)
        }

        func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
            matches.results.isFindBarOpen = true
            matches.beginSession()
        }

        func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
            (session as? FindSession)?.stop()
            matches.results.isFindBarOpen = false
            matches.endSession()
        }
    }

    /// One find session over a Document: searches as the bar asks and keeps the current match.
    @MainActor
    private final class FindSession: UIFindSession {
        private let matches: any DocumentMatches
        private weak var interaction: UIFindInteraction?

        init(matches: any DocumentMatches, interaction: UIFindInteraction) {
            self.matches = matches
            self.interaction = interaction
            super.init()
            matches.didChange = { [weak self] in self?.interaction?.updateResultCount() }
        }

        /// Ends the session: its matches are forgotten and unmarked.
        func stop() {
            invalidateFoundResults()
            matches.didChange = {}
        }

        override var resultCount: Int { matches.results.matches.count }
        override var highlightedResultIndex: Int { matches.results.current ?? NSNotFound }

        override func performSearch(query: String, options: UITextSearchOptions?) {
            matches.search(DocumentSearch.Query(query, options: options)) { [matches] number in
                if number == 0 { matches.makeCurrent(0) }
            }
        }

        override func highlightNextResult(in direction: UITextStorageDirection) {
            matches.stepToMatch(backward: direction == .backward)
        }

        override func invalidateFoundResults() { matches.clear() }
    }

    extension UIFindInteraction {
        /// Adds "Show All Results" to the bar's options, on compact widths, where
        /// there is no sidebar for the list of `results`; it calls `show`.
        func offerResults(of results: SearchResults, in view: UIView, show: @escaping () -> Void) {
            optionsMenuProvider = { [weak view] defaults in
                guard view?.traitCollection.horizontalSizeClass == .compact else { return UIMenu(children: defaults) }
                let item = UIAction(
                    title: "Show All Results", image: UIImage(systemName: "list.bullet"),
                    attributes: results.matches.isEmpty ? .disabled : []
                ) { _ in show() }
                return UIMenu(children: defaults + [UIMenu(options: .displayInline, children: [item])])
            }
        }
    }

    extension DocumentSearch.Query {
        /// The reader's choices in the system find bar.
        @MainActor init(_ text: String, options: UITextSearchOptions?) {
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

    /// The native macOS find bar (`NSTextFinder`) for a Reader, whatever its
    /// Format. NSTextFinder does its own matching and can't be handed matches,
    /// so this client gives it the Document's text (`DocumentMatches.text`) and
    /// it applies the reader's case and word-match options itself. It searches
    /// as they type; the match count, next and previous come with the bar. The
    /// current match is shown by the matches (`DocumentMatches.makeCurrent`).
    ///
    /// For the results list, Document Search runs alongside while the bar is
    /// showing, on the bar's search string and options, which it keeps in the
    /// system's find pasteboard. NSTextFinder reports neither its matches nor
    /// when the search changes, so the pasteboard is watched, and the current
    /// match NSTextFinder scrolls to is looked up in the list.
    @MainActor
    final class DocumentFind: NSObject, @preconcurrency NSTextFinderClient {
        private weak var view: NSView?
        private let matches: any DocumentMatches
        private let results: SearchResults
        /// Where the bar sits, once the view has it. A scroll view is observed for the
        /// bar showing and hiding; any other container reports it with `barVisibilityChanged`.
        private let barContainer: () -> NSTextFinderBarContainer?
        let finder = NSTextFinder()
        /// NSTextFinder searches it on a background queue.
        private let text: ChunkedText
        /// The current match, in the Document's text; empty before the first.
        private var selected = NSRange()
        /// The search the list shows; nil while the bar is hidden.
        private var listed: DocumentSearch.Query?
        private var barObservation: NSKeyValueObservation?
        private var watch: Timer?
        /// The find pasteboard's change count when the list was made, so an
        /// unchanged pasteboard isn't read again.
        private var listedChange: Int?

        init(view: NSView, matches: any DocumentMatches, barContainer: @escaping () -> NSTextFinderBarContainer?) {
            self.view = view
            self.matches = matches
            self.barContainer = barContainer
            results = matches.results
            text = matches.text
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
            let container = barContainer()
            finder.findBarContainer = container
            if barObservation == nil, let scrollView = container as? NSScrollView {
                barObservation = scrollView.observe(\.isFindBarVisible, options: [.new]) { [weak self] _, change in
                    let isVisible = change.newValue ?? false
                    MainActor.assumeIsolated { self?.barVisibilityChanged(isVisible) }
                }
            }
            finder.performAction(action)
        }

        // MARK: Results list

        /// Called as the find bar shows or hides.
        func barVisibilityChanged(_ isVisible: Bool) {
            results.isFindBarOpen = isVisible
            guard isVisible else {
                matches.endSession()
                watch?.invalidate()
                watch = nil
                listed = nil
                listedChange = nil
                matches.clear()
                return
            }
            matches.beginSession()
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
                if matches.range(ofMatch: number).location == selected.location, selected.length > 0 {
                    matches.makeCurrent(number)
                }
            }
        }

        /// Goes to the listed match with the given number, as if the bar had found it.
        private func choose(_ number: Int) {
            guard results.matches.indices.contains(number) else { return }
            selected = matches.range(ofMatch: number)
            matches.makeCurrent(number)
            // NSTextFinder keeps its own place in its matches; this makes it
            // go on from the selection.
            finder.noteClientStringWillChange()
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
            // A match never spans chunks (pages, spine items).
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
            guard range.length > 0, let number = matches.number(ofMatchAt: range.location) else {
                results.current = nil
                return
            }
            matches.makeCurrent(number)
        }

        func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
            outRange.pointee = NSRange(location: 0, length: text.length)
            return view ?? NSView()
        }

        func rects(forCharacterRange range: NSRange) -> [NSValue]? {
            matches.rects(forCharacterRange: range)?.map { NSValue(rect: $0) }
        }

        var visibleCharacterRanges: [NSValue] { matches.visibleRanges.map { NSValue(range: $0) } }
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
