import Foundation
import LeafCore

/// The matches of the Document Search going on in a Reader's document view,
/// whatever the Format: the Document Search (`DocumentSearch`) finds them, and
/// this marks them in the document, the current one apart, and shows it. The
/// find bar (`DocumentFind`) drives it. Choosing a match in the list makes it
/// current too, unless the find bar takes that over. Runs on the main actor.
@MainActor
protocol DocumentMatches: AnyObject {
    /// The Document Search that finds the matches and owns them.
    var search: DocumentSearch { get }
    /// Called, once per turn of the main loop at most, after matches arrived or
    /// the current one changed, for the bar to update its count.
    var didChange: () -> Void { get set }

    /// Replaces the matches with those of `query`, as they are found. `onMatch`
    /// is called with the number of each new match.
    func search(_ query: Query, onMatch: @escaping @MainActor (Int) -> Void)
    /// Forgets every match, and unmarks them.
    func clear()
    /// Makes match `number` the current one and shows it.
    func makeCurrent(_ number: Int)

    /// Starts a Document Search session in the view, when the find bar opens.
    func beginSession()
    /// Ends the Document Search session in the view, when the find bar closes.
    func endSession()

    #if os(macOS)
        /// Where the text at `range` is, in the view's coordinates; nil if the Format
        /// marks matches in the document itself.
        func rects(forCharacterRange range: NSRange) -> [CGRect]?
        /// The parts of the text on screen, where incremental matches are marked.
        var visibleRanges: [NSRange] { get }
    #endif
}

extension DocumentMatches {
    /// The matches, as the results list shows them.
    var results: SearchResults { search.results }
    /// The Document's text, which the matches are positions in.
    var text: DocumentText { search.text }

    func search(_ query: Query) { search(query) { _ in } }

    /// Where match `number` is in the Document's text.
    func range(ofMatch number: Int) -> NSRange { search.range(ofMatch: number) }

    /// Number of the match starting at `location` in the text, if there is one.
    func number(ofMatchAt location: Int) -> Int? { search.number(ofMatchAt: location) }

    /// Makes the next match current, or the previous one, wrapping around; the
    /// first, or the last, when there is no current one.
    func stepToMatch(backward: Bool) {
        let count = results.matches.count
        guard count > 0 else { return }
        let step = backward ? count - 1 : 1
        makeCurrent(((results.current ?? -step) + step) % count)
    }

    #if os(macOS)
        func rects(forCharacterRange range: NSRange) -> [CGRect]? { nil }
        var visibleRanges: [NSRange] { [NSRange(location: 0, length: Int(text.length()))] }
    #endif
}
