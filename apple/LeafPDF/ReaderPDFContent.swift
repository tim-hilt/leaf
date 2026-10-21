import PDFKit
import SwiftUI

/// PDFKit's native viewer, laid out as one vertical, continuously scrolling
/// column. Opens as `state` if there is one, else at page 1 at fit-to-width; see
/// `ReaderPDFView` for zooming, keeping your place, taps and scrolling.
struct ReaderPDFContent {
    let document: StyledDocument
    let appearance: PageAppearance
    let highlights: [Highlight]
    let pageNotes: [PageNote]
    let pageNoteColor: RGB
    let handle: ReaderHandle
    let results: SearchResults
    let state: ReaderViewState?
    let contents: TableOfContents
    let callbacks: ReaderCallbacks
    /// Called when the reader asks for the list of matches in the find bar (iOS only).
    let onShowResults: () -> Void

    @MainActor
    fileprivate func makePDFView() -> PDFView {
        let view = ReaderPDFView(handle: handle, results: results)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        if let state { view.open(from: state) }
        view.document = document
        view.pageAppearance = appearance
        view.highlights = highlights
        view.pageNotes = pageNotes
        view.pageNoteColor = pageNoteColor
        view.contents = contents
        view.callbacks = callbacks
        #if os(iOS)
            view.find.onShowResults = onShowResults
        #endif
        return view
    }

    @MainActor
    fileprivate func update(_ view: PDFView) {
        guard let reader = view as? ReaderPDFView else { return }
        reader.pageAppearance = appearance
        reader.highlights = highlights
        reader.pageNotes = pageNotes
        reader.pageNoteColor = pageNoteColor
    }
}

#if os(iOS)
    extension ReaderPDFContent: UIViewRepresentable {
        func makeUIView(context: Context) -> PDFView { makePDFView() }
        func updateUIView(_ view: PDFView, context: Context) { update(view) }
    }
#else
    extension ReaderPDFContent: NSViewRepresentable {
        func makeNSView(context: Context) -> PDFView { makePDFView() }
        func updateNSView(_ view: PDFView, context: Context) { update(view) }
    }
#endif
