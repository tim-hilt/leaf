import LeafCore
import WebKit

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The system web view showing an EPUB as one continuous vertical column: all
/// spine items stacked, each frame as tall as its content, so the page scrolls
/// through every Chapter. The book's own CSS is kept; the Reader adds a fixed
/// side margin and keeps images within the width. The text reflows when the
/// view's size changes.
///
/// Only the Chapters near the viewport are loaded, those within a viewport above and
/// below it; a Chapter far away is released and keeps its height, and one never loaded
/// has a height estimated from the core's text lengths, so the column keeps its full
/// height. Highlights, page Notes, search marks, the text size and the Page Style are
/// applied to each Chapter as it loads, and going to a place loads its Chapter first
/// (`ReaderEPUBScript`).
///
/// Files come from the core through `EPUBSchemeHandler`. Web links open in the
/// browser through `openExternally`; links inside the book are Jumps. A Jump goes
/// to a place and remembers the top of the viewport as the Back place, named by
/// its Chapter in the Table of Contents (`contents`); only the latest is kept.
/// `onOpen` is called once the opening Chapter is laid out and the view has scrolled
/// to its opening place, the other Chapters loading on from there; a tap on text that isn't a link is reported to
/// `onSingleTap`. The page reports the position at the top of the viewport as it
/// scrolls (`ReaderEPUBScript`), which `topOfViewport` gives and `onScroll` announces.
///
/// Zooming is changing the text size (`TextSize`): pinching, ⌘+ and ⌘− reflow the
/// text, keep its place and announce the new size through `onTextSizeChange`. The
/// side margin keeps its size.
///
/// The `pageAppearance` is the Page Style: Light Pages show the book's colors, Dark Pages
/// the Page Colors instead (`ReaderEPUBScript`). Switching keeps the place, and the view
/// behind the page has the paper's color from the start, so nothing flashes.
///
/// Document Search runs in the core's text of the spine items (`EPUBSearch`), so a match is
/// a position, also in a Chapter that isn't loaded. The native find bar (`find`) searches as
/// the reader types; the matches are listed in `results` and marked in the text, each Chapter
/// as it loads. Going to a match scrolls it into view, loading its Chapter, and
/// during one search session that is one Jump: Back returns to where the search started.
///
/// Highlights are drawn over their words by the page (`ReaderEPUBScript`), so they follow
/// the text when it reflows. A Highlight is placed at the positions it stores, or, when the
/// text there isn't its quoted text, where the core finds that text (`EpubBook.relocate`);
/// one that is found nowhere isn't drawn. Choosing "Highlight" in the selection menu, or
/// `highlightSelection()`, reports the selection's positions and text to `onHighlight` and
/// clears it. A click on a Highlight, or its Note icon, is reported to `onHighlightTap`;
/// dragging still selects.
///
/// Page Notes have their icon in the left margin at the line of their spot, drawn by the
/// page (`ReaderEPUBScript`) so it follows the text when it reflows, in `pageNoteColor`
/// whatever the Page Style; a click on it is reported to `onPageNoteTap`. A long press (iOS)
/// or right-click (macOS) on an empty spot, one without text, link, Highlight or icon,
/// offers "Add Note", which reports the spot in the text to `onAddNote`.
final class ReaderEPUBView: WKWebView, ReaderDocumentView {
    /// Opens a web link outside the Reader.
    var openExternally: (URL) -> Void = { url in
        #if os(iOS)
            UIApplication.shared.open(url)
        #else
            NSWorkspace.shared.open(url)
        #endif
    }

    let book: EpubBook
    private let callbacks: ReaderCallbacks

    /// The matches of the Document Search that is going on, for the results list.
    let results: SearchResults

    /// The matches of the Document Search, marked in the text.
    private(set) lazy var matches = EPUBMatches(view: self, results: results)

    /// The native find bar over Document Search.
    #if os(iOS)
        private(set) lazy var find = DocumentFind(view: self, matches: matches)
    #else
        /// The view hosts the bar itself, and reports it showing and hiding.
        private(set) lazy var find = DocumentFind(view: self, matches: matches) { [weak self] in self }
    #endif

    #if os(macOS)
        /// The find bar the text finder hands over; it sits at the top of the view, and
        /// the page starts below it.
        var findBarView: NSView? {
            didSet {
                oldValue?.removeFromSuperview()
                layOutFindBar()
            }
        }

        var isFindBarVisible = false {
            didSet {
                layOutFindBar()
                find.barVisibilityChanged(isFindBarVisible)
            }
        }

        var contentView: NSView? { self }

        func findBarViewDidChangeHeight() { layOutFindBar() }

        private func layOutFindBar() {
            guard let bar = findBarView else { return }
            guard isFindBarVisible else {
                bar.removeFromSuperview()
                insetPage(by: 0)
                return
            }
            let height = bar.frame.height
            bar.frame = CGRect(x: 0, y: isFlipped ? 0 : bounds.height - height, width: bounds.width, height: height)
            bar.autoresizingMask = isFlipped ? [.width, .maxYMargin] : [.width, .minYMargin]
            if bar.superview !== self { addSubview(bar) }
            insetPage(by: height)
        }

        /// Starts the page `top` points down, under the find bar.
        private func insetPage(by top: CGFloat) {
            obscuredContentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        }
    #endif

    /// The Table of Contents, which names the Back place.
    var contents: TableOfContents

    /// Back and Document Search session places; changes are reported as `onBackChange`.
    private var history = JumpHistory() {
        didSet {
            guard history.backPlace != oldValue.backPlace else { return }
            callbacks.onBackChange(backPlace.map(contents.backTarget(at:)))
        }
    }

    /// Where Back returns to: the top of the viewport before the latest Jump.
    /// Nil before any Jump and after Back.
    var backPlace: Place? { history.backPlace }

    /// The Back place to reopen with, reported once the book is open.
    private let restoredBackPlace: Place?

    /// The position at the top of the viewport, as last reported; nil until opened.
    private var top: Place?
    private var isOpen = false
    /// The Highlights to draw. Setting them draws the change.
    var highlights: [Highlight] {
        didSet { if highlights != oldValue { syncHighlights() } }
    }

    /// The page Notes to show an icon for. Setting them draws the change.
    var pageNotes: [PageNote] = [] {
        didSet { if pageNotes.map(\.id) != oldValue.map(\.id) { syncPageNotes() } }
    }

    /// The color of the icons of page Notes.
    var pageNoteColor = RGB(1, 0.92, 0.24) {
        didSet { if pageNoteColor != oldValue { syncPageNotes() } }
    }

    /// Where a Note can be added at the last right-click, if anywhere.
    private var contextSpot: Place?

    #if os(iOS)
        /// The edit menu offering "Add Note", and the spot it was asked at.
        private lazy var addNoteMenu = UIEditMenuInteraction(delegate: self)
        fileprivate var noteSpot: Place?
    #endif

    /// Where each Highlight's words are now, by its ID; nil for one found nowhere. A
    /// Highlight's anchor and quoted text never change, so this is asked of the core once.
    private var placements: [String: (start: EpubPosition, end: EpubPosition)?] = [:]

    /// Whether the page has a selection.
    private var hasSelection = false {
        didSet {
            #if os(iOS)
                if hasSelection != oldValue { UIMenuSystem.context.setNeedsRebuild() }
            #endif
        }
    }

    /// The text size the page has been told, to tell it only what changed.
    private var pageTextSize: CGFloat

    /// The Page Style the page has been told, to tell it only what changed.
    private var toldAppearance: PageAppearance

    /// The text size of the book. Setting it reflows the text, keeping the place.
    var textSize: CGFloat {
        didSet { syncTextSize() }
    }

    /// How the pages look. Setting it restyles them, keeping the place.
    var pageAppearance: PageAppearance {
        didSet {
            styleBackground()
            syncAppearance()
        }
    }

    /// Opens `book` at the place of `state`, else at its start, with the Back place
    /// of `state`, at `textSize` in `appearance`, and registers as the `handle`'s view.
    /// Document Search lists its matches in `results`. Draws `highlights`.
    init(
        book: EpubBook, state: ReaderViewState?, contents: TableOfContents, textSize: CGFloat,
        appearance: PageAppearance, highlights: [Highlight] = [], handle: ReaderHandle,
        results: SearchResults = SearchResults(), callbacks: ReaderCallbacks
    ) {
        self.book = book
        self.highlights = highlights
        self.results = results
        self.contents = contents
        restoredBackPlace = state?.backPlace
        self.callbacks = callbacks
        self.textSize = textSize
        pageTextSize = textSize
        pageAppearance = appearance
        toldAppearance = appearance
        let spine = book.spine()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            EPUBSchemeHandler(book: book, spine: spine), forURLScheme: EPUBSchemeHandler.scheme)
        // Books' own scripts stay off; the Reader's runs in its own world, out of their reach.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let messages = Messages()
        configuration.userContentController.add(messages, contentWorld: .defaultClient, name: ReaderEPUBScript.channel)
        var start: (chapter: Int, offset: Int)?
        if let position = state?.place.epubPosition { start = (position.spineIndex, position.offset) }
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ReaderEPUBScript.source(
                    lengths: book.textLengths(), start: start, textSize: textSize, appearance: pageAppearance),
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        super.init(frame: .zero, configuration: configuration)
        messages.view = self
        navigationDelegate = self
        uiDelegate = self
        handle.view = self
        styleBackground()
        #if os(iOS)
            // The text size takes the pinch, not the page's scale.
            scrollView.pinchGestureRecognizer?.isEnabled = false
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
            pinch.delegate = self
            addGestureRecognizer(pinch)
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
            longPress.delegate = self
            addGestureRecognizer(longPress)
            addInteraction(addNoteMenu)
        #endif
        load(URLRequest(url: EPUBSchemeHandler.rootURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Receives what the page reports. Apart so the web view's configuration
    /// doesn't keep the view alive.
    @MainActor
    private final class Messages: NSObject, WKScriptMessageHandler {
        weak var view: ReaderEPUBView?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let view else { return }
            switch message.body {
            case let position as [Int] where position.count == 2:
                view.top = .epub(spineIndex: position[0], offset: position[1])
                if view.isOpen { view.callbacks.onScroll() }
            case let text as String where text == "opened":
                view.isOpen = true
                view.history = JumpHistory(backPlace: view.restoredBackPlace)
                view.syncTextSize()
                view.syncAppearance()
                view.syncHighlights()
                view.syncPageNotes()
                view.callbacks.onOpen()
            case let text as String where text == "tap":
                view.callbacks.onSingleTap()
            case let body as [String: Any]:
                if let selecting = body["selection"] as? Bool {
                    view.hasSelection = selecting
                } else if let id = body["highlight"] as? String, let x = body["x"] as? Double,
                    let y = body["y"] as? Double
                {
                    view.reportTap(onHighlight: id, at: CGPoint(x: x, y: y))
                } else if let id = body["pageNote"] as? String, let x = body["x"] as? Double,
                    let y = body["y"] as? Double
                {
                    view.reportTap(onPageNote: id, at: CGPoint(x: x, y: y))
                } else if body.keys.contains("contextSpot") {
                    view.contextSpot = (body["contextSpot"] as? [Int]).map { .epub(spineIndex: $0[0], offset: $0[1]) }
                }
            default: break
            }
        }
    }

    // MARK: ReaderDocumentView

    var topOfViewport: Place? { top }
    var viewState: ReaderViewState? { top.map { ReaderViewState(place: $0, backPlace: backPlace) } }

    /// Jump: goes to `place`, remembering the top of the viewport for `goBack()` in
    /// place of any earlier Back place. Does nothing if `place` is already at the top.
    func jump(to place: Place) {
        guard history.jump(to: place, from: top) else { return }
        go(to: place)
    }

    /// Back: returns to the Back place and forgets it. Does nothing without one.
    func goBack() {
        guard let place = history.goBack() else { return }
        go(to: place)
    }

    /// Scrolls `place` to the top of the viewport, loading its Chapter first; the page then
    /// reports the new position.
    private func go(to place: Place) {
        guard isOpen, let (spineIndex, offset) = place.epubPosition else { return }
        callPage("return await leaf.scrollToPosition([\(spineIndex), \(offset)])")
    }
    func zoomIn() { changeTextSize(to: TextSize.zoomedIn(from: textSize)) }
    func zoomOut() { changeTextSize(to: TextSize.zoomedOut(from: textSize)) }
    func zoomToFitWidth() { changeTextSize(to: TextSize.normal) }

    func popoverPoint(of note: PageNote) async -> CGPoint? {
        guard isOpen, let (spineIndex, offset) = note.place.epubPosition else { return nil }
        let icon = try? await evaluateJavaScript(
            "leaf.notePoint([\(spineIndex), \(offset)])", in: nil, contentWorld: .defaultClient)
        guard let point = icon as? [Double], point.count == 2 else { return nil }
        return CGPoint(x: point[0], y: point[1])
    }

    // MARK: Document Search

    /// Shows the find bar; matches are marked and revealed as they are found.
    func presentFind() { find.present() }

    #if os(macOS)
        func findNext() { find.next() }
        func findPrevious() { find.previous() }
    #endif

    /// Starts a Document Search session, called when the find bar opens. Until
    /// `endSearchSession()`, every `reveal` that moves the text makes the top of
    /// the viewport the Back place, so the session is one Jump: Back returns to
    /// where the search started, also after an earlier Back.
    func beginSearchSession() { history.beginSearchSession(at: top) }

    /// Ends the Document Search session, called when the find bar closes. The
    /// Back place it recorded stays.
    func endSearchSession() { history.endSearchSession() }

    /// Marks `matches` in the text, the one at `current` apart; no matches clears the marks.
    func markMatches(_ matches: [EPUBSearch.Match], current: Int?) {
        guard isOpen else { return }
        let list = matches.map { "[\($0.spineIndex), \($0.range.location), \($0.range.length)]" }
        callPage("leaf.setFindMarks([\(list.joined(separator: ","))], \(current ?? -1))")
    }

    /// Scrolls a Document Search match into view, a third of the way down the
    /// viewport, loading its Chapter first; does nothing if it is already in view. Within
    /// a search session the move is part of one Jump; see `beginSearchSession()`.
    func reveal(_ match: EPUBSearch.Match) {
        guard isOpen else { return }
        let script = "return await leaf.reveal([\(match.spineIndex), \(match.range.location), \(match.range.length)])"
        Task {
            let moved = try? await callAsyncJavaScript(script, in: nil, contentWorld: .defaultClient) as? Bool
            if moved == true { history.didReveal() }
        }
    }

    // MARK: Highlights

    /// Highlights the selection: reports its positions and text to `onHighlight` and clears
    /// the selection. Does nothing without one.
    func highlightSelection() {
        guard isOpen else { return }
        Task {
            let taken = try? await evaluateJavaScript(
                "leaf.takeSelection()", in: nil, contentWorld: .defaultClient)
            guard let parts = taken as? [Any], parts.count == 5, let startSpine = parts[0] as? Int,
                let start = parts[1] as? Int, let endSpine = parts[2] as? Int, let end = parts[3] as? Int,
                let text = parts[4] as? String
            else { return }
            callbacks.onHighlight(
                .epub(
                    start: EpubPosition(spineIndex: startSpine, offset: start),
                    end: EpubPosition(spineIndex: endSpine, offset: end)), text)
        }
    }

    /// Reports a click on Highlight `id`, or on its Note icon, at `point` in the view's coordinates.
    fileprivate func reportTap(onHighlight id: String, at point: CGPoint) {
        if let highlight = highlights.first(where: { $0.id == id }) { callbacks.onHighlightTap(highlight, point) }
    }

    /// Where the words of `highlight` are, if it is an EPUB Highlight and they can be found.
    private func span(of highlight: Highlight) -> (start: EpubPosition, end: EpubPosition)? {
        guard case .epub(let start, let end) = highlight.anchor else { return nil }
        if let known = placements[highlight.id] { return known }
        let found = book.relocate(start: start, end: end, quotedText: highlight.quotedText)
        var span: (start: EpubPosition, end: EpubPosition)?
        if case .epub(let foundStart, let foundEnd) = found { span = (foundStart, foundEnd) }
        placements.updateValue(span, forKey: highlight.id)
        return span
    }

    /// Tells the page the Highlights once it is open.
    private func syncHighlights() {
        guard isOpen else { return }
        let drawn: [[String: Any]] = highlights.compactMap { highlight in
            guard let span = span(of: highlight) else { return nil }
            return [
                "id": highlight.id, "color": highlight.tint.hex, "note": highlight.note != nil,
                "start": [span.start.spine, span.start.utf16Offset], "end": [span.end.spine, span.end.utf16Offset],
            ]
        }
        callPage("setHighlights", with: drawn)
    }

    /// Calls `leaf.<function>` of the page with `argument` as JSON.
    private func callPage(_ function: String, with argument: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: argument),
            let json = String(data: data, encoding: .utf8)
        else { return }
        callPage("leaf.\(function)(\(json))")
    }

    /// Runs `script`, the body of a function that may wait for the page, in the Reader's world.
    private func callPage(_ script: String) {
        Task { _ = try? await callAsyncJavaScript(script, in: nil, contentWorld: .defaultClient) }
    }

    // MARK: Page Notes

    /// Reports a click on the icon of page Note `id` at `point` in the view's coordinates.
    fileprivate func reportTap(onPageNote id: String, at point: CGPoint) {
        if let note = pageNotes.first(where: { $0.id == id }) { callbacks.onPageNoteTap(note, point) }
    }

    /// Tells the page the page Notes once it is open.
    private func syncPageNotes() {
        guard isOpen else { return }
        let drawn: [[String: Any]] = pageNotes.compactMap { note in
            guard let (spineIndex, offset) = note.place.epubPosition else { return nil }
            return ["id": note.id, "color": pageNoteColor.hex, "at": [spineIndex, offset]]
        }
        callPage("setPageNotes", with: drawn)
    }

    /// Reports the spot in the text at `point`, in the view's coordinates, to `onAddNote`.
    /// Does nothing unless the spot is empty.
    func addNote(at point: CGPoint) {
        Task { if let spot = await emptySpot(at: point) { callbacks.onAddNote(spot) } }
    }

    /// Where a Note added at `point` would be in the text; nil unless the spot is empty.
    private func emptySpot(at point: CGPoint) async -> Place? {
        guard isOpen else { return nil }
        let spot = try? await evaluateJavaScript(
            "leaf.emptySpot(\(point.x), \(point.y))", in: nil, contentWorld: .defaultClient)
        guard let parts = spot as? [Int], parts.count == 2 else { return nil }
        return .epub(spineIndex: parts[0], offset: parts[1])
    }

    // MARK: Text size

    private func changeTextSize(to size: CGFloat) {
        guard size != textSize else { return }
        textSize = size
        callbacks.onTextSizeChange(size)
    }

    /// Whether the page is still reflowing to a text size it has been told.
    private var reflowing = false

    /// Tells the page the text size once it is open; it reflows and keeps its place.
    /// One size at a time: a pinch changes it faster than the whole book reflows, so
    /// the page gets the latest size once done, instead of a backlog it lags behind on.
    private func syncTextSize() {
        guard isOpen, !reflowing, textSize != pageTextSize else { return }
        pageTextSize = textSize
        reflowing = true
        let script = "leaf.setTextSize(\(textSize))"
        Task {
            _ = try? await evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
            reflowing = false
            syncTextSize()
        }
    }

    // MARK: Page Style

    /// The paper's color behind the page, whatever the Theme: before the page has loaded
    /// and where it scrolls past its end.
    private func styleBackground() {
        let paper = pageAppearance.paper
        #if os(iOS)
            let color = UIColor(red: paper.r, green: paper.g, blue: paper.b, alpha: 1)
            isOpaque = false
            backgroundColor = color
            scrollView.backgroundColor = color
        #else
            let color = NSColor(srgbRed: paper.r, green: paper.g, blue: paper.b, alpha: 1)
        #endif
        underPageBackgroundColor = color
    }

    /// Tells the page the Page Style once it is open.
    private func syncAppearance() {
        guard isOpen, pageAppearance != toldAppearance else { return }
        toldAppearance = pageAppearance
        let script = "leaf.setAppearance(\(ReaderEPUBScript.literal(of: pageAppearance)))"
        Task { _ = try? await evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) }
    }

    #if os(iOS)
        private var sizeBeforePinch = TextSize.normal

        /// Changes the text size; the page doesn't scroll meanwhile: a scroll in progress fights
        /// the page keeping its place and leaves the old size on screen until the next scroll.
        @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
            if pinch.state == .began { sizeBeforePinch = textSize }
            scrollView.panGestureRecognizer.isEnabled = ![.began, .changed].contains(pinch.state)
            changeTextSize(to: TextSize.clamped(sizeBeforePinch * pinch.scale))
        }

        @objc private func longPressed(_ press: UILongPressGestureRecognizer) {
            guard press.state == .began else { return }
            let point = press.location(in: self)
            Task {
                guard let spot = await emptySpot(at: point) else { return }
                noteSpot = spot
                addNoteMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            }
        }

        // The find bar is presented from the first responder.
        override var canBecomeFirstResponder: Bool { true }

        /// Adds "Highlight" to the edit menu of a selection.
        override func buildMenu(with builder: any UIMenuBuilder) {
            super.buildMenu(with: builder)
            guard builder.system == .context, hasSelection else { return }
            let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                self?.highlightSelection()
            }
            builder.insertChild(UIMenu(options: .displayInline, children: [highlight]), atStartOfMenu: .standardEdit)
        }
    #else
        /// Adds "Highlight" to the context menu of a selection, and "Add Note" to that of an empty spot.
        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            super.willOpenMenu(menu, with: event)
            if hasSelection {
                insert("Highlight", #selector(highlightFromMenu), into: menu)
            } else if contextSpot != nil {
                insert("Add Note", #selector(addNoteFromMenu), into: menu)
            }
        }

        /// Puts an item for `action` at the top of `menu`, unless it has one.
        private func insert(_ title: String, _ action: Selector, into menu: NSMenu) {
            guard !menu.items.contains(where: { $0.action == action }) else { return }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        @objc private func highlightFromMenu(_ sender: Any?) { highlightSelection() }

        @objc private func addNoteFromMenu(_ sender: Any?) {
            if let contextSpot { callbacks.onAddNote(contextSpot) }
        }

        override func magnify(with event: NSEvent) {
            changeTextSize(to: TextSize.clamped(textSize * (1 + event.magnification)))
        }
    #endif
}

#if os(macOS)
    extension ReaderEPUBView: @preconcurrency NSTextFinderBarContainer {}
#endif

#if os(iOS)
    extension ReaderEPUBView: @MainActor UIEditMenuInteractionDelegate {
        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let spot = noteSpot else { return nil }
            let add = UIAction(title: "Add Note", image: UIImage(systemName: "note.text.badge.plus")) { [weak self] _ in
                self?.callbacks.onAddNote(spot)
            }
            return UIMenu(children: [add])
        }
    }

    extension ReaderEPUBView: UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
#endif

extension ReaderEPUBView: WKNavigationDelegate {
    /// Links in the book are Jumps and web links go to the browser. Nothing else
    /// navigates a frame away from its Chapter.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        guard navigationAction.navigationType == .linkActivated else { return .allow }
        follow(navigationAction.request.url)
        return .cancel
    }

    /// Follows a link the reader activated: a Jump if it points into the book, else the browser.
    fileprivate func follow(_ url: URL?) {
        guard let url, let scheme = url.scheme else { return }
        if scheme == EPUBSchemeHandler.scheme {
            let path = String(url.path(percentEncoded: false).dropFirst())
            if let place = book.locate(path: path, fragment: url.fragment(percentEncoded: false)) {
                jump(to: place)
            }
        } else if ["http", "https", "mailto"].contains(scheme) {
            openExternally(url)
        }
    }
}

extension ReaderEPUBView: WKUIDelegate {
    /// Links that ask for a new window (`target="_blank"`) go to the browser too.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        follow(navigationAction.request.url)
        return nil
    }
}
