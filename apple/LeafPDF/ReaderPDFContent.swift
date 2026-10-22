import LeafCore
import PDFKit
import SwiftUI

/// PDFKit's native viewer, laid out as one vertical, continuously scrolling
/// column. Opens as `state` if there is one, else at page 1 at fit-to-width; see
/// `ReaderPDFView` for zooming, keeping your place, taps and scrolling.
struct ReaderPDFContent {
    let document: StyledDocument
    let inputs: ReaderInputs

    @MainActor
    fileprivate func makePDFView() -> PDFView {
        let view = ReaderPDFView(handle: inputs.handle, results: inputs.results)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        if let state = inputs.state { view.open(from: state) }
        view.document = document
        view.pageAppearance = inputs.appearance
        view.highlights = inputs.highlights
        view.pageNotes = inputs.pageNotes
        view.pageNoteColor = inputs.pageNoteColor
        view.contents = inputs.contents
        view.callbacks = inputs.callbacks
        #if os(iOS)
            view.find.onShowResults = inputs.onShowResults
        #endif
        return view
    }

    @MainActor
    fileprivate func update(_ view: PDFView) {
        guard let reader = view as? ReaderPDFView else { return }
        reader.pageAppearance = inputs.appearance
        reader.highlights = inputs.highlights
        reader.pageNotes = inputs.pageNotes
        reader.pageNoteColor = inputs.pageNoteColor
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
