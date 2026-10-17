import PDFKit

// TEMPORARY: remove with File Import (features §2)

/// The bundled public-domain Document (Alice's Adventures in Wonderland,
/// chapters I–IV; text from Project Gutenberg) that stands in for imported
/// Documents until File Import exists.
@MainActor
enum SampleDocument {
    static let pdf: PDFDocument = {
        guard let url = Bundle.main.url(forResource: "Sample", withExtension: "pdf"),
            let document = PDFDocument(url: url)
        else { fatalError("Sample.pdf is missing from the app bundle") }
        return document
    }()
}
