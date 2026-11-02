import LeafCore
import PDFKit

/// The pages of a PDF as the core's Document Search reads them (ADR-0003): the
/// text of a page extracted with PDFKit when the core first asks for it, the
/// page's printed number, and where a match sits on its page. The core calls
/// from the thread that searches, so PDFKit is read off the main actor, as when
/// it draws pages (ADR-0013).
final class PDFKitPages: PdfPages {
    /// PDFKit reads safely from several threads (ADR-0013).
    private nonisolated(unsafe) let document: PDFDocument

    init(_ document: PDFDocument) {
        self.document = document
    }

    func pageText(index: UInt32) -> String? {
        document.page(at: Int(index))?.string
    }

    func pageNumber(index: UInt32) -> String {
        document.printedPageNumber(at: Int(index))
    }

    func placeOfMatch(index: UInt32, start: UInt64, end: UInt64) -> Place? {
        guard let page = document.page(at: Int(index)),
            let selection = page.selection(
                for: NSRange(location: Int(start), length: Int(end - start)))
        else { return nil }
        let top = selection.bounds(for: page)
        return .pdf(pageIndex: Int(index), point: CGPoint(x: top.minX, y: top.maxY))
    }
}
