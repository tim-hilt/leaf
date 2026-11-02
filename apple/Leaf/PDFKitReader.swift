import LeafCore
import PDFKit

/// Reads what a PDF says about itself with PDFKit, for the core: its Title,
/// Author and page count, which the core keeps as the Document's details. A
/// PDF PDFKit can't open is unreadable; one that needs a password is locked.
final class PDFKitReader: PdfReader {
    func read(path: String) throws -> PdfDetails {
        guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)) else { throw PdfProblem.Unreadable }
        guard !pdf.isLocked else { throw PdfProblem.Locked }
        let attributes = pdf.documentAttributes
        return PdfDetails(
            title: attributes?[PDFDocumentAttribute.titleAttribute] as? String,
            author: attributes?[PDFDocumentAttribute.authorAttribute] as? String,
            pageCount: UInt32(clamping: pdf.pageCount))
    }
}
