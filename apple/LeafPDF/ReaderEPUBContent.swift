import LeafCore
import SwiftUI

/// `ReaderEPUBView` in SwiftUI: an EPUB as one vertical, continuously scrolling column.
struct ReaderEPUBContent {
    let book: EpubBook
    /// How to open; nil opens at the start.
    let state: ReaderViewState?
    /// The Table of Contents, which names the Back place.
    let contents: TableOfContents
    /// The text size to show; see `TextSize`.
    let textSize: CGFloat
    /// The Page Style to show.
    let appearance: PageAppearance
    let handle: ReaderHandle
    let callbacks: ReaderCallbacks

    @MainActor
    fileprivate func makeEPUBView() -> ReaderEPUBView {
        ReaderEPUBView(
            book: book, state: state, contents: contents, textSize: textSize, appearance: appearance,
            handle: handle, callbacks: callbacks)
    }

    @MainActor
    fileprivate func update(_ view: ReaderEPUBView) {
        view.contents = contents
        view.textSize = textSize
        view.pageAppearance = appearance
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
