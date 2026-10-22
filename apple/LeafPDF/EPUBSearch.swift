import Foundation
import LeafCore

/// Document Search in an EPUB: finds text in the core's text of the spine items,
/// so each match is a position (ADR-0022): a spine item and a UTF-16 range in its
/// text. Delivers matches in reading order, a spine item at a time. One search
/// runs at a time; starting another cancels the one before it. Runs on the main actor.
@MainActor
final class EPUBSearch {
    struct Match {
        let spineIndex: Int
        /// The matched text in its spine item's text, in UTF-16 units.
        let range: NSRange
        let excerpt: DocumentSearch.Excerpt
        /// The Chapter or Section the match is in; nil if the book has no
        /// Table of Contents or the match is before its first entry.
        let section: TableOfContents.Entry?

        /// Where the match starts.
        var place: Place { .epub(spineIndex: spineIndex, offset: range.location) }
    }

    private let text: ChunkedText
    private let contents: TableOfContents
    private var running: Task<Void, Never>?

    /// `text` is the book's text, one chunk per spine item; `contents` is its
    /// Table of Contents, which places matches in Chapters and Sections.
    init(_ text: ChunkedText, contents: TableOfContents) {
        self.text = text
        self.contents = contents
    }

    /// Searches for `query`, replacing any search still running. Calls
    /// `onMatch` for each match, in reading order, then `onFinish` once nothing
    /// more will come. A cancelled search calls neither again. An empty query
    /// has no matches.
    func search(
        _ query: DocumentSearch.Query, onMatch: @escaping @MainActor (Match) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        cancel()
        guard !query.text.isEmpty else { return onFinish() }
        running = Task { [text, contents] in
            for index in 0..<text.chunkCount {
                // Fetched off the main actor: the core may have to parse the spine
                // item. Awaiting also lets a newer search cancel this one.
                let chapter = await Task.detached { text.string(ofChunkAt: index) }.value as NSString
                guard !Task.isCancelled else { return }
                for range in query.ranges(in: chapter) {
                    guard !Task.isCancelled else { return }
                    onMatch(
                        Match(
                            spineIndex: index, range: range,
                            excerpt: DocumentSearch.Excerpt(around: range, in: chapter),
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
