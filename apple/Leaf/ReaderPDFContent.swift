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
    fileprivate func makePDFView() -> ReaderPDFView {
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
    fileprivate func update(_ view: ReaderPDFView) {
        view.pageAppearance = inputs.appearance
        view.highlights = inputs.highlights
        view.pageNotes = inputs.pageNotes
        view.pageNoteColor = inputs.pageNoteColor
    }
}

#if os(iOS)
    extension ReaderPDFContent: UIViewRepresentable {
        func makeUIView(context: Context) -> ReaderPDFView { makePDFView() }
        func updateUIView(_ view: ReaderPDFView, context: Context) { update(view) }
    }
#else
    extension ReaderPDFContent: NSViewRepresentable {
        func makeNSView(context: Context) -> ReaderPDFView { makePDFView() }
        func updateNSView(_ view: ReaderPDFView, context: Context) { update(view) }
    }
#endif
