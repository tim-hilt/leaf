import LeafCore
import PDFKit

/// A Document's text as one string: its chunks of text (a PDF's pages, an EPUB's
/// spine items) end to end. It is what a client that searches the text itself
/// (the macOS find bar) sees. A match never spans chunks, so each chunk is its
/// own search chunk. Only the lengths are kept: a chunk's string is fetched
/// when asked for, so an EPUB's text lives in the core alone. Immutable, so a
/// search may read it from any thread.
struct ChunkedText: Sendable {
    private let starts: [Int]
    private let lengths: [Int]
    private let fetch: @Sendable (Int) -> String
    /// Total length of the text, in UTF-16 units.
    let length: Int

    /// `lengths[i]` is the length of chunk `i`'s string in UTF-16 units, which
    /// `fetch(i)` returns.
    private init(lengths: [Int], fetch: @escaping @Sendable (Int) -> String) {
        var start = 0
        starts = lengths.map { length in
            defer { start += length }
            return start
        }
        self.lengths = lengths
        self.fetch = fetch
        length = start
    }

    /// The text of `strings`, held as given.
    init(_ strings: [String]) {
        self.init(lengths: strings.map { $0.utf16.count }, fetch: { strings[$0] })
    }

    /// The text of every spine item of `book`, as the core extracts it (ADR-0022):
    /// lengths from the core, each item's text fetched from it on demand.
    init(_ book: EpubBook) {
        self.init(lengths: book.textLengths().map(Int.init), fetch: { book.text(index: UInt32($0)) ?? "" })
    }

    var chunkCount: Int { lengths.count }

    /// The text of the chunk at `index`.
    func string(ofChunkAt index: Int) -> String { fetch(index) }

    /// Where the text of the chunk at `index` sits in the whole text.
    func range(ofChunkAt index: Int) -> NSRange {
        NSRange(location: starts[index], length: lengths[index])
    }

    /// The text of the chunk holding the character at `index`, and where it sits
    /// in the whole text. `index` must be below `length`.
    func chunk(at index: Int) -> (string: String, range: NSRange) {
        let chunk = chunkIndex(containing: index)
        return (fetch(chunk), range(ofChunkAt: chunk))
    }

    /// The chunk holding `range`, which lies within one chunk, and `range` as it
    /// is in that chunk; nil if it is empty or outside the text.
    func inChunk(_ range: NSRange) -> (chunkIndex: Int, range: NSRange)? {
        guard range.length > 0, range.location < length else { return nil }
        let index = chunkIndex(containing: range.location)
        return (index, NSRange(location: range.location - starts[index], length: range.length))
    }

    /// The last chunk starting at or before `index`. Empty chunks share their
    /// start with the next one, so this skips them.
    func chunkIndex(containing index: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// The text of a PDF: a chunk per page.
struct DocumentText: Sendable {
    private let text: ChunkedText
    /// Total length of the text, in UTF-16 units.
    var length: Int { text.length }

    /// Reads the text of every page, so build it once per Document. Without a
    /// Document, the text is empty.
    init(_ document: PDFDocument?) {
        text = ChunkedText((0..<(document?.pageCount ?? 0)).map { document?.page(at: $0)?.string ?? "" })
    }

    /// The text of the page holding the character at `index`, and where it sits
    /// in the whole text. `index` must be below `length`.
    func chunk(at index: Int) -> (string: String, range: NSRange) { text.chunk(at: index) }

    /// Where the text of the page at `index` sits in the whole text.
    func range(ofPageAt index: Int) -> NSRange { text.range(ofChunkAt: index) }

    /// The page holding `range`, which lies within one page, and `range` as it
    /// is on that page, as PDFKit sees it; nil if it is empty or outside the text.
    func onPage(_ range: NSRange) -> (pageIndex: Int, range: NSRange)? {
        text.inChunk(range).map { ($0.chunkIndex, $0.range) }
    }
}

extension PDFDocument {
    /// The text of `text` at `range` as PDFKit selects it; nil if `range` is empty or outside it.
    func selection(for range: NSRange, in text: DocumentText) -> PDFSelection? {
        guard let (index, onPage) = text.onPage(range) else { return nil }
        return page(at: index)?.selection(for: onPage)
    }
}
