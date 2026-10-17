import PDFKit
import SwiftUI

/// Shows one Document's pages in a single continuously scrolling vertical
/// column, titled with the Document's Title. Must be pushed onto a
/// `NavigationStack`, which provides the back chevron and iOS edge swipe.
struct ReaderView: View {
    let document: PDFDocument

    var body: some View {
        PDFKitView(document: document)
            .navigationTitle(document.title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #else
                .background(BackShortcut())
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
/// column, scaled to fit the width.
private struct PDFKitView {
    let document: PDFDocument

    @MainActor
    fileprivate func makePDFView() -> PDFView {
        let view = PDFView()
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
