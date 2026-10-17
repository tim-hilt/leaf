import PDFKit

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
}

extension PDFDocument {
    /// The Title, Author and page count of this Document, as saved by the Library.
    var details: DocumentDetails {
        let author = (documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DocumentDetails(
            title: title, author: author?.isEmpty == false ? author : nil, pageCount: pageCount)
    }
}
