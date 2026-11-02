import Foundation
import LeafCore

/// Document Search in an EPUB: the core matches the text of each spine item
/// (`EpubBook.search`), so a match is a position (ADR-0022): a spine item and a
/// UTF-16 range in its text. Delivers matches in reading order, a spine item at
/// a time. One search runs at a time; starting another cancels the one before
/// it. Runs on the main actor.
@MainActor
final class EPUBSearch {
    struct Match {
        let spineIndex: Int
        /// The matched text in its spine item's text, in UTF-16 units.
        let range: NSRange
        let excerpt: SearchExcerpt
        /// The Chapter or Section the match is in; nil if the book has no
        /// Table of Contents or the match is before its first entry.
        let section: TableOfContents.Entry?

        /// Where the match starts.
        var place: Place { .epub(spineIndex: spineIndex, offset: range.location) }
    }

    private let book: EpubBook
    private let contents: TableOfContents
    private var running: Task<Void, Never>?

    /// `contents` is the book's Table of Contents, which places matches in Chapters and Sections.
    init(_ book: EpubBook, contents: TableOfContents) {
        self.book = book
        self.contents = contents
    }

    /// Searches for `query`, replacing any search still running. Calls
    /// `onMatch` for each match, in reading order, then `onFinish` once nothing
    /// more will come. A cancelled search calls neither again. An empty query
    /// has no matches.
    func search(
        _ query: Query, onMatch: @escaping @MainActor (Match) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        cancel()
        guard !query.text.isEmpty else { return onFinish() }
        running = Task { [book, contents] in
            for index in 0..<book.spine().count {
                // Searched off the main actor: the core may have to parse the spine
                // item. Awaiting also lets a newer search cancel this one.
                let found = await Task.detached { book.search(index: UInt32(index), query: query) }.value
                guard !Task.isCancelled else { return }
                for match in found {
                    let range = match.nsRange
                    onMatch(
                        Match(
                            spineIndex: index, range: range, excerpt: match.excerpt,
                            section: contents.position(at: .epub(spineIndex: index, offset: range.location))?
                                .current))
                }
            }
            guard !Task.isCancelled else { return }
            running = nil
            onFinish()
        }
    }

    /// Stops the search that is running, if any.
    func cancel() {
        running?.cancel()
        running = nil
    }
}
