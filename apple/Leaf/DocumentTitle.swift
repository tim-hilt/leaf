import PDFKit

/// What a PDF says about itself, as stored in it: the core keeps it as the
/// Document's details and derives the Title.
struct PDFDetails: Sendable {
    let title: String?
    let author: String?
    let pageCount: Int
}

extension PDFDocument {
    var details: PDFDetails {
        PDFDetails(
            title: documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
            author: documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String,
            pageCount: pageCount)
    }
}
