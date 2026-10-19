import PDFKit
import SwiftUI

/// Opens a Document's File and shows its pages in a single continuously
/// scrolling vertical column, titled with the Document's Title. Must be pushed onto a
/// `NavigationStack`, which provides the back chevron and iOS edge swipe. The
/// window makes a new one for each Tab, so only the active Tab's Document is
/// loaded; under the toolbar, the `TabStrip` shows once a second Tab is open.
///
/// Immersive Mode hides everything but the pages, the Tab strip too. On iOS a
/// single tap toggles it; on macOS it is the native full screen, with the toolbar
/// shown on hover.
/// Scrolling never changes it, and the Reader always opens with its UI showing.
///
/// Pages are drawn per the Page Style in Settings, and redrawn live when it changes.
/// ⇧⌘D switches to the opposite of what is showing; on macOS the View menu also
/// has the three Page Styles.
///
/// Selecting text and choosing "Highlight" in the selection menu (⌃⌘H on macOS)
/// adds a Highlight in the default color, stored in the Library, never in the
/// File. Highlights are drawn into the pages, so Dark Pages reverse them.
/// Clicking or tapping a Highlight, or its Note icon, opens a popover (a sheet
/// on iPhone) to recolor it, write its Note or remove it, all stored at once.
///
/// A Note can also sit on an empty spot of a page: "Add Note" in the context menu
/// (macOS) or after a long press (iOS), or the toolbar's "Add Note", which puts it
/// in the middle of the viewport. Its popover opens in editing and also has "Remove
/// Note"; emptying the Note removes it. Page Notes can't be moved.
///
/// Opens at the Tab's place, zoom and Back place if it was shown before (kept
/// in `Tabs`, in memory), else at the Document's Reading Progress at
/// fit-to-width, or at page 1. It saves Reading Progress (see `ReadingProgressSaver`) when opened, after scrolling stops,
/// when it disappears and when the scene goes to the background. Reading
/// Progress from another Device never moves it; Markup from another Device
/// shows up live.
///
/// A trailing toolbar button opens the Table of Contents, in a popover (a sheet
/// on iPhone), unless the Document has none. It shows where the top of the
/// page is, and choosing an entry is a Jump. After a Jump, a floating capsule
/// "Back to p. 42" returns to where the reader was; it also shows in Immersive
/// Mode, where it is the only way back. Following a link in the Document is a
/// Jump too, and tapping a link doesn't switch Immersive Mode.
///
/// A trailing toolbar cog opens a popover, on iPhone too, to change Page Style
/// while reading, unless Immersive Mode hides it.
///
/// A trailing toolbar button opens the native find bar for Document Search,
/// unless Immersive Mode hides it. ⌘F opens it too: on iOS with a keyboard, on
/// macOS from Edit > Find, which also has ⌘G and ⇧⌘G. All matches are listed
/// with their surrounding text and page numbers: in a leading sidebar while the
/// find bar is open and has matches, or on compact widths in a sheet that the
/// find bar's options open.
struct ReaderView: View {
    let document: LibraryDocument
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Tabs.self) private var tabs
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pdf: StyledDocument?
    @State private var handle = ReaderHandle()
    @State private var saver: ReadingProgressSaver?
    @State private var contents: TableOfContents?
    @State private var isShowingContents = false
    @State private var isShowingPageStyle = false
    @State private var results = SearchResults()
    @State private var highlights: [Highlight] = []
    @State private var isShowingResults = false
    @State private var pageNotes: [PageNote] = []
    @State private var openMarkup: OpenMarkup?
    /// Printed page number of the Back place; nil when there is none.
    @State private var backPageNumber: String?
    /// Immersive Mode; on macOS, whether the window is in full screen.
    @State private var isImmersive = false

    var body: some View {
        VStack(spacing: 0) {
            if tabs.openIDs.count > 1 && !isImmersive { TabStrip() }
            HStack(spacing: 0) {
                if showsResultsSidebar {
                    SearchResultsList(results: results)
                        .frame(width: 320)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                pages
            }
        }
        .animation(.default, value: showsResultsSidebar)
        .sheet(isPresented: $isShowingResults) { SearchResultsSheet(results: results) }
        .task {
            guard pdf == nil else { return }
            saver = ReadingProgressSaver(library: library, document: document, handle: handle)
            let opened = StyledDocument(url: document.file)
            highlights = await library.highlights(of: document)
            pageNotes = await library.pageNotes(of: document)
            contents = opened.map(TableOfContents.init)
            pdf = opened
        }
        // Markup from another Device shows live. Reading Progress never moves the Reader.
        .onChange(of: library.markupRevision(of: document)) {
            Task {
                highlights = await library.highlights(of: document)
                pageNotes = await library.pageNotes(of: document)
            }
        }
        .onDisappear {
            saver?.saveIfMoved()
            if let state = handle.view?.viewState { tabs.store(state, for: document.id) }
        }
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
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Note", systemImage: "note.text.badge.plus") { handle.view?.addNoteInVisiblePage() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Page Style", systemImage: "gearshape") { isShowingPageStyle = true }
                        .popover(isPresented: $isShowingPageStyle) { PageStylePopover() }
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
            .background(switchPageStyleShortcut)
        #else
            .onAppear { isImmersive = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                isImmersive = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                isImmersive = false
            }
            .background(BackShortcut())
            .focusedSceneValue(\.reader, handle)
            .focusedSceneValue(\.backPageNumber, backPageNumber)
            .focusedSceneValue(\.switchPageStyle, switchPageStyle)
            .focusedSceneValue(\.showTableOfContents, availableContents == nil ? nil : $isShowingContents)
            .windowToolbarFullScreenVisibility(.onHover)
        #endif
    }

    private func switchPageStyle() {
        settings.switchToOppositePageStyle(systemScheme: colorScheme)
    }

    #if os(iOS)
        /// Invisible button giving ⇧⌘D to iPad keyboards; on macOS the View menu has it.
        private var switchPageStyleShortcut: some View {
            Button("Switch Light and Dark Pages", action: switchPageStyle)
                .keyboardShortcut("d", modifiers: [.shift, .command])
                .opacity(0)
                .accessibilityHidden(true)
        }
    #endif

    private var pages: some View {
        Group {
            if let pdf {
                PDFKitView(
                    document: pdf, appearance: settings.pageAppearance(systemScheme: colorScheme),
                    highlights: highlights,
                    pageNotes: pageNotes, pageNoteColor: library.highlightColors[0].color,
                    handle: handle, results: results,
                    state: tabs.viewState(of: document.id) ?? document.place.map { ReaderViewState(place: $0) },
                    onHighlight: highlight,
                    onHighlightTap: { openMarkup = OpenMarkup(target: .highlight($0.id), point: $1) },
                    onAddNote: addPageNote,
                    onPageNoteTap: { openMarkup = OpenMarkup(target: .pageNote($0.id), point: $1) },
                    onSingleTap: toggleImmersive, onOpen: { saver?.opened() }, onScroll: { saver?.scrolled() },
                    onBackChange: { backPageNumber = $0 }, onShowResults: { isShowingResults = true })
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
        .popover(
            item: $openMarkup,
            attachmentAnchor: .rect(
                .rect(CGRect(origin: openMarkup?.point ?? .zero, size: CGSize(width: 1, height: 1))))
        ) { open in
            popover(for: open)
        }
    }

    /// The popover of the Highlight or page Note `open`; nothing if it is gone.
    @ViewBuilder private func popover(for open: OpenMarkup) -> some View {
        switch open.target {
        case .highlight(let id):
            if let highlight = highlights.first(where: { $0.id == id }) {
                HighlightPopover(
                    colors: library.highlightColors, color: highlight.color, note: highlight.note,
                    onColor: { recolor(highlight, to: $0) }, onNote: { setNote($0, of: highlight) },
                    onRemove: { remove(highlight) }
                )
                .presentationCompactAdaptation(.sheet)
            }
        case .pageNote(let id):
            if let note = pageNotes.first(where: { $0.id == id }) {
                PageNotePopover(
                    text: note.text, startsEditing: open.startsEditing, onText: { setText($0, of: note) },
                    onRemove: { remove(note) }
                )
                .presentationCompactAdaptation(.sheet)
            }
        }
    }

    /// Whether the matches are listed in a sidebar: while the find bar is open
    /// and has matches, unless the width is compact, which has a sheet instead.
    private var showsResultsSidebar: Bool { results.isListable && sizeClass != .compact }

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

    /// Adds a Highlight over `anchor`; it shows once the Library has stored it.
    private func highlight(_ anchor: HighlightAnchor) {
        Task {
            guard let added = await library.addHighlight(anchor, to: document)
            else { return }
            highlights.append(added)
        }
    }

    /// Recolors `highlight`; it shows at once, and the Library stores it.
    private func recolor(_ highlight: Highlight, to color: RGB) {
        guard let index = highlights.firstIndex(where: { $0.id == highlight.id }) else { return }
        highlights[index].color = color
        Task { await library.setHighlightColor(color, of: highlight, in: document) }
    }

    /// Sets the Note of `highlight`, empty to remove it; it shows at once, and the Library stores it.
    private func setNote(_ note: String, of highlight: Highlight) {
        guard let index = highlights.firstIndex(where: { $0.id == highlight.id }),
            (highlights[index].note ?? "") != note
        else { return }
        highlights[index].note = note.isEmpty ? nil : note
        Task { await library.setNote(note, of: highlight, in: document) }
    }

    /// Removes `highlight` and closes its popover; the Library stores the removal.
    private func remove(_ highlight: Highlight) {
        openMarkup = nil
        highlights.removeAll { $0.id == highlight.id }
        Task { await library.removeHighlight(highlight, from: document) }
    }

    /// Adds a page Note at `place`, empty, and opens its popover in editing; it
    /// shows once the Library has stored it.
    private func addPageNote(at place: Place) {
        Task {
            guard let added = await library.addPageNote(at: place, to: document), let view = handle.view,
                let icon = view.noteIconRect(of: added)
            else { return }
            pageNotes.append(added)
            let point = view.fromTopLeft(CGPoint(x: icon.midX, y: icon.midY))
            openMarkup = OpenMarkup(target: .pageNote(added.id), point: point, startsEditing: true)
        }
    }

    /// Sets the text of `note`; empty removes it and closes its popover. It shows
    /// at once, and the Library stores it.
    private func setText(_ text: String, of note: PageNote) {
        guard let index = pageNotes.firstIndex(where: { $0.id == note.id }) else { return }
        if text.isEmpty {
            openMarkup = nil
            pageNotes.remove(at: index)
        } else if pageNotes[index].text != text {
            pageNotes[index].text = text
        } else {
            return
        }
        Task { await library.setText(text, of: note, in: document) }
    }

    /// Removes the page Note `note` and closes its popover; the Library stores the removal.
    private func remove(_ note: PageNote) {
        openMarkup = nil
        pageNotes.removeAll { $0.id == note.id }
        Task { await library.removePageNote(note, from: document) }
    }

    private func toggleImmersive() {
        #if os(iOS)
            isImmersive.toggle()
        #endif
    }
}

/// The Highlight or page Note whose popover is open, and the spot it opened
/// from, in the pages' coordinates with the origin at the top-left. A new page
/// Note opens in editing.
private struct OpenMarkup: Identifiable {
    enum Target: Hashable {
        case highlight(String)
        case pageNote(String)
    }

    let target: Target
    let point: CGPoint
    var startsEditing = false

    var id: Target { target }
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
    /// Invisible button that makes ⌘[ Go to Gallery, as in other macOS apps.
    private struct BackShortcut: View {
        @Environment(Tabs.self) private var tabs

        var body: some View {
            Button("Back", action: tabs.goToGallery)
                .keyboardShortcut("[", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
#endif

/// PDFKit's native viewer, laid out as one vertical, continuously scrolling
/// column. Opens as `state` if there is one, else at page 1 at fit-to-width; see
/// `ReaderPDFView` for zooming, keeping your place, taps and scrolling.
private struct PDFKitView {
    let document: StyledDocument
    let appearance: PageAppearance
    let highlights: [Highlight]
    let pageNotes: [PageNote]
    let pageNoteColor: RGB
    let handle: ReaderHandle
    let results: SearchResults
    let state: ReaderViewState?
    let onHighlight: (HighlightAnchor) -> Void
    let onHighlightTap: (Highlight, CGPoint) -> Void
    let onAddNote: (Place) -> Void
    let onPageNoteTap: (PageNote, CGPoint) -> Void
    let onSingleTap: () -> Void
    let onOpen: () -> Void
    let onScroll: () -> Void
    let onBackChange: (String?) -> Void
    /// Called when the reader asks for the list of matches in the find bar (iOS only).
    let onShowResults: () -> Void

    @MainActor
    fileprivate func makePDFView() -> PDFView {
        let view = ReaderPDFView(handle: handle, results: results)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        if let state { view.open(from: state) }
        view.document = document
        view.pageAppearance = appearance
        view.highlights = highlights
        view.pageNotes = pageNotes
        view.pageNoteColor = pageNoteColor
        view.onHighlight = onHighlight
        view.onHighlightTap = onHighlightTap
        view.onAddNote = onAddNote
        view.onPageNoteTap = onPageNoteTap
        view.onSingleTap = onSingleTap
        view.onOpen = onOpen
        view.onScroll = onScroll
        view.onBackChange = onBackChange
        #if os(iOS)
            view.find.onShowResults = onShowResults
        #endif
        return view
    }
}

extension PDFKitView {
    @MainActor
    fileprivate func update(_ view: PDFView) {
        guard let reader = view as? ReaderPDFView else { return }
        reader.pageAppearance = appearance
        reader.highlights = highlights
        reader.pageNotes = pageNotes
        reader.pageNoteColor = pageNoteColor
    }
}

#if os(iOS)
    extension PDFKitView: UIViewRepresentable {
        func makeUIView(context: Context) -> PDFView { makePDFView() }
        func updateUIView(_ view: PDFView, context: Context) { update(view) }
    }
#else
    extension PDFKitView: NSViewRepresentable {
        func makeNSView(context: Context) -> PDFView { makePDFView() }
        func updateNSView(_ view: PDFView, context: Context) { update(view) }
    }
#endif
