import Foundation

/// The matches of the Document Search going on in a Reader's document view,
/// whatever the Format: one search session, which the find bar (`DocumentFind`)
/// drives. It searches, fills the results list (`SearchResults`), keeps the
/// matches marked in the document, the current one apart, and shows the
/// current one. Choosing a match in the list makes it current too, unless the
/// find bar takes that over. Runs on the main actor.
///
/// Matches are numbered as in `SearchResults`, from 0 in reading order.
@MainActor
protocol DocumentMatches: AnyObject {
    var results: SearchResults { get }
    /// The Document's text, which the matches are positions in.
    var text: ChunkedText { get }
    /// Called, once per turn of the main loop at most, after matches arrived or
    /// the current one changed, for the bar to update its count.
    var didChange: () -> Void { get set }

    /// Replaces the matches with those of `query`, as they are found. `onMatch`
    /// is called with the number of each new match.
    func search(_ query: DocumentSearch.Query, onMatch: @escaping @MainActor (Int) -> Void)
    /// Forgets every match, and unmarks them.
    func clear()
    /// Makes match `number` the current one and shows it.
    func makeCurrent(_ number: Int)
    /// Where match `number` is in `text`.
    func range(ofMatch number: Int) -> NSRange

    /// Starts a Document Search session in the view, when the find bar opens.
    func beginSession()
    /// Ends the Document Search session in the view, when the find bar closes.
    func endSession()

    #if os(macOS)
        /// Where the text at `range` is, in the view's coordinates; nil if the Format
        /// marks matches in the document itself.
        func rects(forCharacterRange range: NSRange) -> [CGRect]?
        /// The parts of `text` on screen, where incremental matches are marked.
        var visibleRanges: [NSRange] { get }
    #endif
}

extension DocumentMatches {
    func search(_ query: DocumentSearch.Query) { search(query) { _ in } }

    /// Makes the next match current, or the previous one, wrapping around; the
    /// first, or the last, when there is no current one.
    func stepToMatch(backward: Bool) {
        let count = results.matches.count
        guard count > 0 else { return }
        let step = backward ? count - 1 : 1
        makeCurrent(((results.current ?? -step) + step) % count)
    }

    /// Number of the match starting at `location` in `text`, if there is one.
    func number(ofMatchAt location: Int) -> Int? {
        var low = 0
        var high = results.matches.count
        while low < high {
            let mid = (low + high) / 2
            if range(ofMatch: mid).location < location { low = mid + 1 } else { high = mid }
        }
        return low < results.matches.count && range(ofMatch: low).location == location ? low : nil
    }

    #if os(macOS)
        func rects(forCharacterRange range: NSRange) -> [CGRect]? { nil }
        var visibleRanges: [NSRange] { [NSRange(location: 0, length: text.length)] }
    #endif
}
