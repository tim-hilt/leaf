import PDFKit
import SwiftUI

/// Opens a Document's File and shows its pages in a single continuously
/// scrolling vertical column, titled with the Document's Title. Must be pushed onto a
/// `NavigationStack`, which provides the back chevron and iOS edge swipe.
///
/// Immersive Mode hides everything but the pages. On iOS a single tap toggles
/// it; on macOS it is the native full screen, with the toolbar shown on hover.
/// Scrolling never changes it, and the Reader always opens with its UI showing.
///
/// Opens at the Document's Reading Progress at fit-to-width, or at page 1, and
/// saves it (see `ReadingProgressSaver`) when opened, after scrolling stops,
/// when it disappears and when the scene goes to the background.
struct ReaderView: View {
    let document: LibraryDocument
    @Environment(LibraryModel.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var pdf: PDFDocument?
    @State private var handle = ReaderHandle()
    @State private var saver: ReadingProgressSaver?
    #if os(iOS)
        @State private var isImmersive = false
    #endif

    var body: some View {
        Group {
            if let pdf {
                PDFKitView(
                    document: pdf, handle: handle, place: document.place, onSingleTap: toggleImmersive,
                    onOpen: { saver?.saveNow() }, onScroll: { saver?.scrolled() })
            } else {
                Color.clear
            }
        }
        .task {
            guard pdf == nil else { return }
            saver = ReadingProgressSaver(library: library, document: document, handle: handle)
            pdf = PDFDocument(url: document.file)
        }
        .onDisappear { saver?.saveNow() }
        .onChange(of: scenePhase) { if scenePhase == .background { saver?.saveNow() } }
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
/// column. Opens at fit-to-width, at `place` if there is one; see
/// `ReaderPDFView` for zooming, keeping your place, taps and scrolling.
private struct PDFKitView {
    let document: PDFDocument
    let handle: ReaderHandle
    let place: Place?
    let onSingleTap: () -> Void
    let onOpen: () -> Void
    let onScroll: () -> Void

    @MainActor
    fileprivate func makePDFView() -> PDFView {
        let view = ReaderPDFView(handle: handle)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        if let place { view.open(at: place) }
        view.document = document
        view.onSingleTap = onSingleTap
        view.onOpen = onOpen
        view.onScroll = onScroll
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
