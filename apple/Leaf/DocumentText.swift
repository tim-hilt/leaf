import LeafCore
import PDFKit

/// The core's `DocumentText` (the text a Document Search searches) of an open
/// Document, as its Format provides it.
extension DocumentText {
    /// The text of `document`'s pages, which PDFKit extracts as the core asks
    /// for them and the core keeps.
    static func of(_ document: PDFDocument) -> DocumentText {
        DocumentText.pdf(pages: UInt32(document.pageCount), reader: PDFKitPages(document))
    }

    /// The text of `book`'s spine items.
    static func of(_ book: EpubBook) -> DocumentText {
        DocumentText.epub(book: book)
    }
}

extension TextChunk {
    /// The chunk's span as NSRange counts it.
    var range: NSRange { NSRange(location: Int(start), length: Int(length)) }
}

extension PDFDocument {
    /// The text at `range` of `text`'s whole text, as PDFKit selects it; nil if
    /// `range` is empty or outside it.
    func selection(for range: NSRange, in text: DocumentText) -> PDFSelection? {
        guard range.length > 0, range.location < text.length(),
            let chunk = text.chunkContaining(offset: UInt64(range.location))
        else { return nil }
        return page(at: Int(chunk.index))?
            .selection(for: NSRange(location: range.location - Int(chunk.start), length: range.length))
    }
}
