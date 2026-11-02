import LeafCore
import SwiftUI

/// A Document's File opened for the Reader, in the document view of its Format.
enum OpenedDocument {
    case pdf(StyledDocument)
    case epub(EpubBook)
}

/// Everything the Reader shows of a Document when it opens, read before it is
/// pushed, so that it shows complete at once: bar, pages and Markup.
struct LoadedDocument {
    /// The `LibraryDocument` it was read from.
    let id: String
    let file: OpenedDocument
    /// Empty if the Document has none.
    let contents: TableOfContents
    let highlights: [Highlight]
    let pageNotes: [PageNote]

    /// Reads `document`: its File, drawn per `appearance` from the start, Table
    /// of Contents and Markup. The EPUB is opened and the Table of Contents built
    /// off the main thread. Nil if the File can't be read.
    @MainActor
    static func load(
        _ document: LibraryDocument, in library: LibraryModel, appearance: PageAppearance
    ) async -> LoadedDocument? {
        async let markup = library.markup(of: document)
        guard let (file, contents) = await open(document, in: library, appearance: appearance) else { return nil }
        let (highlights, pageNotes) = await markup
        return LoadedDocument(
            id: document.id, file: file, contents: contents, highlights: highlights, pageNotes: pageNotes)
    }

    @MainActor
    private static func open(
        _ document: LibraryDocument, in library: LibraryModel, appearance: PageAppearance
    ) async -> (OpenedDocument, TableOfContents)? {
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
            let contents = await Task.detached { book.tableOfContents() }.value
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
    /// Where to open; nil opens at the start.
    let place: Place?
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
        case .pdf(let pdf):
            ReaderPDFContent(document: pdf, inputs: inputs)
                #if os(iOS)
                    // Pages run edge to edge in landscape, across the Dynamic Island.
                    .ignoresSafeArea(.container, edges: .horizontal)
                #endif
        case .epub(let book): ReaderEPUBContent(book: book, inputs: inputs)
        }
    }
}
