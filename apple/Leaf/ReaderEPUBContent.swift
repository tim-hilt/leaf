import LeafCore
import SwiftUI

/// `ReaderEPUBView` in SwiftUI: an EPUB as one vertical, continuously scrolling column.
struct ReaderEPUBContent {
    let book: EpubBook
    let inputs: ReaderInputs

    @MainActor
    fileprivate func makeEPUBView() -> ReaderEPUBView {
        let view = ReaderEPUBView(
            book: book, state: inputs.state, contents: inputs.contents, textSize: inputs.textSize,
            appearance: inputs.appearance, highlights: inputs.highlights, handle: inputs.handle,
            results: inputs.results, callbacks: inputs.callbacks)
        view.pageNotes = inputs.pageNotes
        view.pageNoteColor = inputs.pageNoteColor
        #if os(iOS)
            view.find.onShowResults = inputs.onShowResults
        #endif
        return view
    }

    @MainActor
    fileprivate func update(_ view: ReaderEPUBView) {
        view.contents = inputs.contents
        view.textSize = inputs.textSize
        view.pageAppearance = inputs.appearance
        view.highlights = inputs.highlights
        view.pageNotes = inputs.pageNotes
        view.pageNoteColor = inputs.pageNoteColor
    }
}

#if os(iOS)
    extension ReaderEPUBContent: UIViewRepresentable {
        func makeUIView(context: Context) -> ReaderEPUBView { makeEPUBView() }
        func updateUIView(_ view: ReaderEPUBView, context: Context) { update(view) }
    }
#else
    extension ReaderEPUBContent: NSViewRepresentable {
        func makeNSView(context: Context) -> ReaderEPUBView { makeEPUBView() }
        func updateNSView(_ view: ReaderEPUBView, context: Context) { update(view) }
    }
#endif
