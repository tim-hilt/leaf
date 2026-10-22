import LeafCore
import SwiftUI

/// A Document's File opened for the Reader, in the document view of its Format.
enum OpenedDocument {
    case pdf(StyledDocument)
    case epub(EpubBook)

    /// Opens `document`'s File, drawn per `appearance` from the start, and reads
    /// its Table of Contents (empty if it has none). The EPUB is opened and the
    /// Table of Contents built off the main thread. Nil if the File can't be read.
    @MainActor
    static func open(
        _ document: LibraryDocument, in library: LibraryModel, appearance: PageAppearance
    ) async -> (document: OpenedDocument, contents: TableOfContents)? {
        switch document.format {
        case .pdf:
            // Styled before PDFKit sees it, so it never starts drawing in Light Pages.
            guard let pdf = StyledDocument(url: document.file) else { return nil }
            pdf.appearance = appearance
            // Nothing else uses the PDF until the Reader has it.
            nonisolated(unsafe) let unshared = pdf
            let contents = await Task.detached { TableOfContents(unshared) }.value
            return (.pdf(pdf), contents)
        case .epub:
            guard let book = await library.epub(of: document) else { return nil }
            let contents = await Task.detached {
                // Has the core parse every spine item now, off the main thread, so the
                // Reader's own calls for the text lengths are cheap.
                _ = book.textLengths()
                return TableOfContents(book)
            }.value
            return (.epub(book), contents)
        }
    }
}

/// Everything the Reader hands a document view, whatever its Format. It reports
/// through `handle` and `callbacks`; see `ReaderDocumentView`.
struct ReaderInputs {
    /// The Page Style to show.
    let appearance: PageAppearance
    let highlights: [Highlight]
    let pageNotes: [PageNote]
    let pageNoteColor: RGB
    let handle: ReaderHandle
    let results: SearchResults
    /// How to open; nil opens at the start.
    let state: ReaderViewState?
    /// The Table of Contents, which names the Back place.
    let contents: TableOfContents
    /// The text size of EPUBs; see `TextSize`.
    let textSize: CGFloat
    let callbacks: ReaderCallbacks
    /// Called when the reader asks for the list of matches in the find bar (iOS only).
    let onShowResults: () -> Void
}

/// The view that shows an `OpenedDocument`, picking the document view of its Format.
struct ReaderContent: View {
    let document: OpenedDocument
    let inputs: ReaderInputs

    var body: some View {
        switch document {
        case .pdf(let pdf): ReaderPDFContent(document: pdf, inputs: inputs)
        case .epub(let book): ReaderEPUBContent(book: book, inputs: inputs)
        }
    }
}
