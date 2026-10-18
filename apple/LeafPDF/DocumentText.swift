import PDFKit

/// A Document's text as one string: the text of its pages, end to end. It is
/// what a client that searches the text itself (the macOS find bar) sees. A
/// match never spans pages, so each page is its own search chunk. Immutable,
/// so a search may read it from any thread.
struct DocumentText: Sendable {
    private let pages: [(string: String, start: Int)]
    /// Total length of the text, in UTF-16 units.
    let length: Int

    /// Reads the text of every page, so build it once per Document. Without a
    /// Document, the text is empty.
    init(_ document: PDFDocument?) {
        var start = 0
        pages = (0..<(document?.pageCount ?? 0)).map { index in
            let string = document?.page(at: index)?.string ?? ""
            defer { start += string.utf16.count }
            return (string, start)
        }
        length = start
    }

    /// The text of the page holding the character at `index`, and where it sits
    /// in the whole text. `index` must be below `length`.
    func chunk(at index: Int) -> (string: String, range: NSRange) {
        let page = pages[pageIndex(containing: index)]
        return (page.string, NSRange(location: page.start, length: page.string.utf16.count))
    }

    /// Where the text of the page at `index` sits in the whole text.
    func range(ofPageAt index: Int) -> NSRange {
        NSRange(location: pages[index].start, length: pages[index].string.utf16.count)
    }

    /// The page holding `range`, which lies within one page, and `range` as it
    /// is on that page, as PDFKit sees it; nil if it is empty or outside the text.
    func onPage(_ range: NSRange) -> (pageIndex: Int, range: NSRange)? {
        guard range.length > 0, range.location < length else { return nil }
        let index = pageIndex(containing: range.location)
        return (index, NSRange(location: range.location - pages[index].start, length: range.length))
    }

    /// The last page starting at or before `index`. Empty pages share their
    /// start with the next page, so this skips them.
    private func pageIndex(containing index: Int) -> Int {
        var low = 0
        var high = pages.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if pages[mid].start <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

extension PDFDocument {
    /// The text of `text` at `range` as PDFKit selects it; nil if `range` is empty or outside it.
    func selection(for range: NSRange, in text: DocumentText) -> PDFSelection? {
        guard let (index, onPage) = text.onPage(range) else { return nil }
        return page(at: index)?.selection(for: onPage)
    }
}
