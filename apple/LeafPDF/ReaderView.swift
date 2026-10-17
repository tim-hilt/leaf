import PDFKit
import SwiftUI

/// Shows one Document's pages in a single continuously scrolling vertical
/// column, titled with the Document's Title. Must be pushed onto a
/// `NavigationStack`, which provides the back chevron and iOS edge swipe.
struct ReaderView: View {
    let document: PDFDocument
    @State private var handle = ReaderHandle()

    var body: some View {
        PDFKitView(document: document, handle: handle)
            .navigationTitle(document.title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #else
                .background(BackShortcut())
                .focusedSceneValue(\.reader, handle)
            #endif
    }
}

#if os(macOS)
    /// Invisible button that makes ⌘[ pop the Reader, as in other macOS apps.
    private struct BackShortcut: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            Button("Back", action: dismiss.callAsFunction)
                .keyboardShortcut("[", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
#endif

/// PDFKit's native viewer, laid out as one vertical, continuously scrolling
/// column. Opens at fit-to-width; see `ReaderPDFView` for zooming and keeping
/// your place.
private struct PDFKitView {
    let document: PDFDocument
    let handle: ReaderHandle

    @MainActor
    fileprivate func makePDFView() -> PDFView {
        let view = ReaderPDFView(handle: handle)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.document = document
        return view
    }
}

#if os(iOS)
    extension PDFKitView: UIViewRepresentable {
        func makeUIView(context: Context) -> PDFView { makePDFView() }
        func updateUIView(_ view: PDFView, context: Context) {}
    }
#else
    extension PDFKitView: NSViewRepresentable {
        func makeNSView(context: Context) -> PDFView { makePDFView() }
        func updateNSView(_ view: PDFView, context: Context) {}
    }
#endif
