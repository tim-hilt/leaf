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
///
/// A trailing toolbar button opens the Table of Contents, in a popover (a sheet
/// on iPhone), unless the Document has none. It shows where the top of the
/// page is, and choosing an entry is a Jump. After a Jump, a floating capsule
/// "Back to p. 42" returns to where the reader was; it also shows in Immersive
/// Mode, where it is the only way back. Following a link in the Document is a
/// Jump too, and tapping a link doesn't switch Immersive Mode.
///
/// A trailing toolbar button opens the native find bar for Document Search,
/// unless Immersive Mode hides it. ⌘F opens it too: on iOS with a keyboard, on
/// macOS from Edit > Find, which also has ⌘G and ⇧⌘G.
struct ReaderView: View {
    let document: LibraryDocument
    @Environment(LibraryModel.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var pdf: PDFDocument?
    @State private var handle = ReaderHandle()
    @State private var saver: ReadingProgressSaver?
    @State private var contents: TableOfContents?
    @State private var isShowingContents = false
    /// Printed page number of the Back place; nil when there is none.
    @State private var backPageNumber: String?
    #if os(iOS)
        @State private var isImmersive = false
    #endif

    var body: some View {
        Group {
            if let pdf {
                PDFKitView(
                    document: pdf, handle: handle, place: document.place, onSingleTap: toggleImmersive,
                    onOpen: { saver?.opened() }, onScroll: { saver?.scrolled() },
                    onBackChange: { backPageNumber = $0 })
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) {
            if let backPageNumber {
                BackCapsule(pageNumber: backPageNumber) { handle.view?.goBack() }
                    .padding(.bottom)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: backPageNumber)
        .task {
            guard pdf == nil else { return }
            saver = ReadingProgressSaver(library: library, document: document, handle: handle)
            let opened = PDFDocument(url: document.file)
            contents = opened.map(TableOfContents.init)
            pdf = opened
        }
        .onDisappear { saver?.saveIfMoved() }
        .onChange(of: scenePhase) { if scenePhase == .background { saver?.saveIfMoved() } }
        .navigationTitle(document.title)
        .toolbar {
            if let contents = availableContents {
                ToolbarItem(placement: .primaryAction) {
                    Button("Table of Contents", systemImage: "list.bullet") { isShowingContents = true }
                        .popover(isPresented: $isShowingContents) {
                            TableOfContentsView(contents: contents, position: position(in: contents)) {
                                handle.view?.jump(to: $0)
                            }
                                .presentationCompactAdaptation(.sheet)
                        }
                }
            }
            if showsToolbarButtons {
                ToolbarItem(placement: .primaryAction) {
                    Button("Find", systemImage: "magnifyingglass") { handle.view?.presentFind() }
                        #if os(iOS)
                            .keyboardShortcut("f", modifiers: .command)
                        #endif
                }
            }
        }
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
            .focusedSceneValue(\.backPageNumber, backPageNumber)
            .focusedSceneValue(\.showTableOfContents, availableContents == nil ? nil : $isShowingContents)
            .windowToolbarFullScreenVisibility(.onHover)
        #endif
    }

    /// Whether the toolbar's buttons are shown. On macOS Immersive Mode is the
    /// full screen, where the toolbar hides itself.
    private var showsToolbarButtons: Bool {
        #if os(iOS)
            !isImmersive
        #else
            true
        #endif
    }

    /// The Table of Contents, unless it is empty or Immersive Mode hides it.
    private var availableContents: TableOfContents? {
        guard showsToolbarButtons, let contents, !contents.isEmpty else { return nil }
        return contents
    }

    /// Where the top of the viewport is, as of now: the Table of Contents is
    /// built when it opens, so this is read then.
    private func position(in contents: TableOfContents) -> TableOfContents.Position? {
        handle.view?.topOfViewport.flatMap(contents.position(at:))
    }

    private func toggleImmersive() {
        #if os(iOS)
            isImmersive.toggle()
        #endif
    }
}

/// The floating "Back to p. 42" button, on a native material.
private struct BackCapsule: View {
    let pageNumber: String
    let action: () -> Void

    var body: some View {
        Button("Back to p. \(pageNumber)", systemImage: "arrow.uturn.backward", action: action)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .buttonStyle(.plain)
            .accessibilityLabel("Back to page \(pageNumber)")
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
    let onBackChange: (String?) -> Void

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
        view.onBackChange = onBackChange
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
