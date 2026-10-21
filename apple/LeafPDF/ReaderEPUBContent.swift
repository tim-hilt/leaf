import LeafCore
import SwiftUI

/// `ReaderEPUBView` in SwiftUI: an EPUB as one vertical, continuously scrolling column.
struct ReaderEPUBContent {
    let book: EpubBook
    /// How to open; nil opens at the start.
    let state: ReaderViewState?
    let handle: ReaderHandle
    let callbacks: ReaderCallbacks

    @MainActor
    fileprivate func makeEPUBView() -> ReaderEPUBView {
        ReaderEPUBView(book: book, state: state, handle: handle, callbacks: callbacks)
    }
}

#if os(iOS)
    extension ReaderEPUBContent: UIViewRepresentable {
        func makeUIView(context: Context) -> ReaderEPUBView { makeEPUBView() }
        func updateUIView(_ view: ReaderEPUBView, context: Context) {}
    }
#else
    extension ReaderEPUBContent: NSViewRepresentable {
        func makeNSView(context: Context) -> ReaderEPUBView { makeEPUBView() }
        func updateNSView(_ view: ReaderEPUBView, context: Context) {}
    }
#endif
