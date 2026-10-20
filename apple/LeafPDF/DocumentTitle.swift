import PDFKit

/// What a PDF says about itself, as stored in it: the core keeps it as the
/// Document's details and derives the Title.
struct PDFDetails: Sendable {
    let title: String?
    let author: String?
    let pageCount: Int
}

extension PDFDocument {
    /// The Title of this Document: the title stored in the PDF, or the file
    /// name (without extension) if the PDF has none.
    var title: String {
        let stored = documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return documentURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    var details: PDFDetails {
        PDFDetails(
            title: documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
            author: documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String,
            pageCount: pageCount)
    }
}
