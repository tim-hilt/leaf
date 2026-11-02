import LeafCore
import PDFKit

/// Document Search in a PDF: the core matches the text of each page (`searchText`),
/// and the matches are shown as PDFKit selections. Pages are searched one at a time,
/// off the main actor, and each page's matches reach `onMatch` as it is done. One
/// search runs at a time; starting another cancels the one before it.
@MainActor
final class DocumentSearch {
    struct Match {
        let pageIndex: Int
        /// The matched text on its page, for highlighting.
        let selection: PDFSelection
        /// The match's range in its page's text, in UTF-16 units.
        let range: NSRange
        let excerpt: SearchExcerpt
        /// The printed number of the page, or its position in the File if it has none.
        let pageNumber: String
        /// The Chapter or Section the match is in; nil if the Document has no
        /// Table of Contents or the match is before its first entry.
        let section: Entry?
    }

    private let document: PDFDocument
    private let contents: TableOfContents
    private var running: Task<Void, Never>?

    /// `contents` is the Document's Table of Contents, which places matches in
    /// Chapters and Sections.
    init(_ document: PDFDocument, contents: TableOfContents) {
        self.document = document
        self.contents = contents
    }

    /// Searches for `query`, replacing any search still running. Calls `onMatch`
    /// for each match, in reading order, then `onFinish` once nothing more will
    /// come. A cancelled search calls neither again. An empty query has no matches.
    func search(
        _ query: Query, onMatch: @escaping @MainActor (Match) -> Void, onFinish: @escaping @MainActor () -> Void
    ) {
        cancel()
        guard !query.text.isEmpty else { return onFinish() }
        running = Task { [contents] in
            // PDFKit draws pages on background threads too (ADR-0013), so their text is read there.
            nonisolated(unsafe) let document = self.document
            for index in 0..<document.pageCount {
                let found = await Task.detached {
                    searchText(query: query, text: document.page(at: index)?.string ?? "")
                }.value
                guard !Task.isCancelled else { return }
                guard let page = document.page(at: index) else { continue }
                for match in found {
                    let range = match.nsRange
                    guard let selection = page.selection(for: range) else { continue }
                    let top = selection.bounds(for: page)
                    onMatch(
                        Match(
                            pageIndex: index, selection: selection, range: range, excerpt: match.excerpt,
                            pageNumber: document.printedPageNumber(at: index),
                            section: contents.position(
                                place: Place.pdf(pageIndex: index, point: CGPoint(x: top.minX, y: top.maxY)))?.current))
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

extension Query {
    /// What to look for; the defaults are the system find bar's: case-insensitive, Contains.
    init(_ text: String, caseSensitive: Bool = false, wordMatch: WordMatch = .contains) {
        self.init(text: text, caseSensitive: caseSensitive, wordMatch: wordMatch)
    }
}

extension SearchMatch {
    /// The match's range as NSString counts it.
    var nsRange: NSRange { NSRange(location: Int(start), length: Int(end - start)) }
}
