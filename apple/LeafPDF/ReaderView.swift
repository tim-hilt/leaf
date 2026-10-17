import PDFKit
import SwiftUI

/// Opens a Document's File and shows its pages in a single continuously
/// scrolling vertical column, titled with the Document's Title. Must be pushed onto a
/// `NavigationStack`, which provides the back chevron and iOS edge swipe.
///
/// Immersive Mode hides everything but the pages. On iOS a single tap toggles
/// it; on macOS it is the native full screen, with the toolbar shown on hover.
/// Scrolling never changes it, and the Reader always opens with its UI showing.
struct ReaderView: View {
    let document: LibraryDocument
    @State private var pdf: PDFDocument?
    @State private var handle = ReaderHandle()
    #if os(iOS)
        @State private var isImmersive = false
    #endif

    var body: some View {
        Group {
            if let pdf {
                PDFKitView(document: pdf, handle: handle, onSingleTap: toggleImmersive)
            } else {
                Color.clear
            }
        }
        .task { if pdf == nil { pdf = PDFDocument(url: document.file) } }
        .navigationTitle(document.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(isImmersive ? .hidden : .automatic, for: .navigationBar)
            .statusBarHidden(isImmersive)
            // Hiding system overlays also lets the home indicator fade.
            .persistentSystemOverlays(isImmersive ? .hidden : .automatic)
            .animation(.default, value: isImmersive)
        #else
            .background(BackShortcut())
            .focusedSceneValue(\.reader, handle)
            .windowToolbarFullScreenVisibility(.onHover)
        #endif
    }

    private func toggleImmersive() {
        #if os(iOS)
            isImmersive.toggle()
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
/// column. Opens at fit-to-width; see `ReaderPDFView` for zooming, keeping
/// your place and taps.
private struct PDFKitView {
    let document: PDFDocument
    let handle: ReaderHandle
    let onSingleTap: () -> Void

    @MainActor
    fileprivate func makePDFView() -> PDFView {
        let view = ReaderPDFView(handle: handle)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.document = document
        view.onSingleTap = onSingleTap
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
