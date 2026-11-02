import Foundation
import LeafCore

/// Document Search in a Reader's Document, whatever the Format: the core
/// (`DocumentText`) searches the Document's text chunk by chunk — a PDF's
/// pages, an EPUB's spine items — in reading order, numbers the matches and
/// places each in the Chapter or Section that contains it, and hands them over
/// a chunk at a time. One search runs at a time; starting another cancels the
/// one before it.
@MainActor
final class DocumentSearch {
    /// A match as the search found it.
    struct Match {
        /// The match's number, from 0 in reading order.
        let number: Int
        /// The index of the chunk the match is in: a page's, or a spine item's.
        let chunkIndex: Int
        /// The match's range in its chunk's text, in UTF-16 units.
        let range: NSRange
        /// The match's range in the Document's whole text, in UTF-16 units.
        let textRange: NSRange
        let excerpt: SearchExcerpt
        /// The printed number of the page the match is on; nil in a Format without pages.
        let pageNumber: String?
        /// The Chapter or Section the match is in; nil if the Document has no
        /// Table of Contents or the match is before its first entry.
        let section: Entry?
    }

    /// The Document's text, which the matches are positions in.
    let text: DocumentText
    /// The Document's Table of Contents, which places matches in Chapters and
    /// Sections.
    let contents: TableOfContents
    let results: SearchResults
    /// The matches of the search that ran last, in reading order; kept until
    /// the next search or a cancel, so one can still be found at its place.
    private(set) var matches: [Match] = []
    /// The core's search of the search that ran last; nil after a cancel.
    private var session: SearchSession?
    private var running: Task<Void, Never>?

    /// `contents` is the Document's Table of Contents, which places matches in
    /// Chapters and Sections.
    init(text: DocumentText, contents: TableOfContents, results: SearchResults) {
        self.text = text
        self.contents = contents
        self.results = results
    }

    /// Searches for `query`, replacing any search still running. Calls
    /// `onMatch` for each match, in reading order, then `onFinish` once nothing
    /// more will come. A cancelled search calls neither again. An empty query
    /// has no matches.
    func search(
        _ query: Query, onMatch: @escaping @MainActor (Match) -> Void, onFinish: @escaping @MainActor () -> Void
    ) {
        cancel()
        guard !query.text.isEmpty else { return onFinish() }
        let session = text.search(query: query, contents: contents)
        self.session = session
        running = Task { [weak self] in
            while true {
                let found = await Task.detached { session.next() }.value
                guard let found, !Task.isCancelled else { break }
                self?.deliver(found, onMatch: onMatch)
            }
            guard !Task.isCancelled else { return }
            self?.running = nil
            onFinish()
        }
    }

    /// Stops the search that is running, if any, and forgets everything found.
    func cancel() {
        running?.cancel()
        running = nil
        session = nil
        matches = []
        results.removeAll()
    }

    /// The number of the match starting at `location` in the whole text, if the
    /// search that ran last found one.
    func number(ofMatchAt location: Int) -> Int? {
        session?.numberAt(offset: UInt64(clamping: location)).map(Int.init)
    }

    /// Where match `number` is in the whole text.
    func range(ofMatch number: Int) -> NSRange {
        matches[number].textRange
    }

    /// Adds `found`, one chunk's matches, and reports each.
    private func deliver(_ found: [FoundMatch], onMatch: @escaping @MainActor (Match) -> Void) {
        // A batch is one chunk's matches, so its page's number is read once.
        let pageNumber = found.first.flatMap { text.pageNumber(index: $0.chunk) }
        for found in found {
            let match = Match(found, pageNumber: pageNumber)
            matches.append(match)
            results.append(.init(match))
            onMatch(match)
        }
    }
}

extension DocumentSearch.Match {
    /// `found` as the core's search found it; `pageNumber` is the printed
    /// number of its page, if pages have one.
    init(_ found: FoundMatch, pageNumber: String?) {
        number = Int(found.number)
        chunkIndex = Int(found.chunk)
        range = NSRange(location: Int(found.start), length: Int(found.end - found.start))
        textRange = NSRange(location: Int(found.textStart), length: Int(found.textEnd - found.textStart))
        excerpt = found.excerpt
        self.pageNumber = pageNumber
        section = found.section
    }
}

extension Query {
    /// What to look for; the defaults are the system find bar's: case-insensitive, Contains.
    init(_ text: String, caseSensitive: Bool = false, wordMatch: WordMatch = .contains) {
        self.init(text: text, caseSensitive: caseSensitive, wordMatch: wordMatch)
    }
}
