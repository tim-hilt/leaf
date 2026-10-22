import LeafCore
import PDFKit

/// A Document's text as one string: its chunks of text (a PDF's pages, an EPUB's
/// spine items) end to end. It is what a client that searches the text itself
/// (the macOS find bar) sees. A match never spans chunks, so each chunk is its
/// own search chunk. Immutable, so a search may read it from any thread.
struct ChunkedText: Sendable {
    private let chunks: [(string: String, start: Int)]
    /// Total length of the text, in UTF-16 units.
    let length: Int

    init(_ strings: [String]) {
        var start = 0
        chunks = strings.map { string in
            defer { start += string.utf16.count }
            return (string, start)
        }
        length = start
    }

    /// Reads the text of every spine item of `book`, as the core extracts it
    /// (ADR-0022), so build it once per book.
    init(_ book: EpubBook) {
        self.init((0..<book.spine().count).map { book.text(index: UInt32($0)) ?? "" })
    }

    var chunkCount: Int { chunks.count }

    func string(ofChunkAt index: Int) -> String { chunks[index].string }

    /// Where the text of the chunk at `index` sits in the whole text.
    func range(ofChunkAt index: Int) -> NSRange {
        NSRange(location: chunks[index].start, length: chunks[index].string.utf16.count)
    }

    /// The text of the chunk holding the character at `index`, and where it sits
    /// in the whole text. `index` must be below `length`.
    func chunk(at index: Int) -> (string: String, range: NSRange) {
        let chunk = chunkIndex(containing: index)
        return (chunks[chunk].string, range(ofChunkAt: chunk))
    }

    /// The chunk holding `range`, which lies within one chunk, and `range` as it
    /// is in that chunk; nil if it is empty or outside the text.
    func inChunk(_ range: NSRange) -> (chunkIndex: Int, range: NSRange)? {
        guard range.length > 0, range.location < length else { return nil }
        let index = chunkIndex(containing: range.location)
        return (index, NSRange(location: range.location - chunks[index].start, length: range.length))
    }

    /// The last chunk starting at or before `index`. Empty chunks share their
    /// start with the next one, so this skips them.
    func chunkIndex(containing index: Int) -> Int {
        var low = 0
        var high = chunks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if chunks[mid].start <= index { low = mid } else { high = mid - 1 }
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
