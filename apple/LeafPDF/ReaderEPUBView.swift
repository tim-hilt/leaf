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
/// Files come from the core through `EPUBSchemeHandler`. Web links open in the
/// browser through `openExternally`; links inside the book are Jumps. A Jump goes
/// to a place and remembers the top of the viewport as the Back place, named by
/// its Chapter in the Table of Contents (`contents`); only the latest is kept.
/// `onOpen` is called once every spine item is laid out and the view has scrolled
/// to its opening place; a tap on text that isn't a link is reported to
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
/// a position. The native find bar (`find`) searches as the reader types; the matches are
/// listed in `results` and marked in the text. Going to a match scrolls it into view, and
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
/// Not yet there for EPUBs: page Notes, so `popoverPoint(of:)` has none.
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
    private(set) lazy var find = EPUBFind(view: self, matches: matches, results: results)

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

        /// Starts the page `top` points down, under the find bar. Before macOS 26 the bar covers the page.
        private func insetPage(by top: CGFloat) {
            if #available(macOS 26, *) {
                obscuredContentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
            }
        }
    #endif

    /// Where the current Document Search session started; nil outside a session.
    private var searchStart: Place?

    /// The Table of Contents, which names the Back place.
    var contents: TableOfContents

    /// Where Back returns to: the top of the viewport before the latest Jump.
    /// Nil before any Jump and after Back.
    private(set) var backPlace: Place? {
        didSet {
            guard backPlace != oldValue else { return }
            callbacks.onBackChange(backPlace.map(contents.backTarget(at:)))
        }
    }

    /// The Back place to reopen with, reported once the book is open.
    private let restoredBackPlace: Place?

    /// The position at the top of the viewport, as last reported; nil until opened.
    private var top: Place?
    private var isOpen = false
    /// The Highlights to draw. Setting them draws the change.
    var highlights: [Highlight] {
        didSet { if highlights != oldValue { syncHighlights() } }
    }

    /// Where each Highlight's words are now, by its ID; nil for one found nowhere. A
    /// Highlight's anchor and quoted text never change, so this is asked of the core once.
    private var placements: [String: HighlightAnchor.Span?] = [:]

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
        if case .epub(let spineIndex, let offset) = state?.place { start = (spineIndex, offset) }
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ReaderEPUBScript.source(
                    frameCount: spine.count, start: start, textSize: textSize, appearance: pageAppearance),
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
                view.backPlace = view.restoredBackPlace
                view.syncTextSize()
                view.syncAppearance()
                view.syncHighlights()
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
        guard let top, !place.isSameSpot(as: top) else { return }
        backPlace = top
        go(to: place)
    }

    /// Back: returns to the Back place and forgets it. Does nothing without one.
    func goBack() {
        guard let place = backPlace else { return }
        backPlace = nil
        go(to: place)
    }

    /// Scrolls `place` to the top of the viewport; the page then reports the new position.
    private func go(to place: Place) {
        guard isOpen, case .epub(let spineIndex, let offset) = place else { return }
        let script = "leaf.scrollToPosition([\(spineIndex), \(offset)])"
        Task { _ = try? await evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) }
    }
    func zoomIn() { changeTextSize(to: TextSize.zoomedIn(from: textSize)) }
    func zoomOut() { changeTextSize(to: TextSize.zoomedOut(from: textSize)) }
    func zoomToFitWidth() { changeTextSize(to: TextSize.normal) }
    func popoverPoint(of note: PageNote) -> CGPoint? { nil }

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
    func beginSearchSession() { searchStart = top }

    /// Ends the Document Search session, called when the find bar closes. The
    /// Back place it recorded stays.
    func endSearchSession() { searchStart = nil }

    /// Marks `matches` in the text, the one at `current` apart; no matches clears the marks.
    func markMatches(_ matches: [EPUBSearch.Match], current: Int?) {
        guard isOpen else { return }
        let list = matches.map { "[\($0.spineIndex), \($0.range.location), \($0.range.length)]" }
        let script = "leaf.setFindMarks([\(list.joined(separator: ","))], \(current ?? -1))"
        Task { _ = try? await evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) }
    }

    /// Scrolls a Document Search match into view, a third of the way down the
    /// viewport; does nothing if it is already in view. Within a search session the
    /// move is part of one Jump; see `beginSearchSession()`.
    func reveal(_ match: EPUBSearch.Match) {
        guard isOpen else { return }
        let script = "leaf.reveal([\(match.spineIndex), \(match.range.location), \(match.range.length)])"
        Task {
            let moved = try? await evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? Bool
            if moved == true, let searchStart { backPlace = searchStart }
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
            let span = HighlightAnchor.Span(
                start: .init(spineIndex: startSpine, offset: start), end: .init(spineIndex: endSpine, offset: end))
            callbacks.onHighlight(HighlightAnchor(location: .epub(span), quotedText: text))
        }
    }

    /// Reports a click on Highlight `id`, or on its Note icon, at `point` in the view's coordinates.
    fileprivate func reportTap(onHighlight id: String, at point: CGPoint) {
        if let highlight = highlights.first(where: { $0.id == id }) { callbacks.onHighlightTap(highlight, point) }
    }

    /// Where the words of `highlight` are, if it is an EPUB Highlight and they can be found.
    private func span(of highlight: Highlight) -> HighlightAnchor.Span? {
        guard case .epub(let stored) = highlight.anchor.location else { return nil }
        if let known = placements[highlight.id] { return known }
        let found = book.relocate(
            start: stored.start.stored, end: stored.end.stored, quotedText: highlight.anchor.quotedText)
        var span: HighlightAnchor.Span?
        if case .epub(let foundStart, let foundEnd) = found {
            span = HighlightAnchor.Span(start: .init(foundStart), end: .init(foundEnd))
        }
        placements.updateValue(span, forKey: highlight.id)
        return span
    }

    /// Tells the page the Highlights once it is open.
    private func syncHighlights() {
        guard isOpen else { return }
        let drawn: [[String: Any]] = highlights.compactMap { highlight in
            guard let span = span(of: highlight) else { return nil }
            return [
                "id": highlight.id, "color": highlight.color.hex, "note": highlight.note != nil,
                "start": [span.start.spineIndex, span.start.offset], "end": [span.end.spineIndex, span.end.offset],
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: drawn),
            let json = String(data: data, encoding: .utf8)
        else { return }
        Task { _ = try? await evaluateJavaScript("leaf.setHighlights(\(json))", in: nil, contentWorld: .defaultClient) }
    }

    // MARK: Text size

    private func changeTextSize(to size: CGFloat) {
        guard size != textSize else { return }
        textSize = size
        callbacks.onTextSizeChange(size)
    }

    /// Tells the page the text size once it is open; it reflows and keeps its place.
    private func syncTextSize() {
        guard isOpen, textSize != pageTextSize else { return }
        pageTextSize = textSize
        let script = "leaf.setTextSize(\(textSize))"
        Task { _ = try? await evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) }
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

        @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
            if pinch.state == .began { sizeBeforePinch = textSize }
            changeTextSize(to: TextSize.clamped(sizeBeforePinch * pinch.scale))
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
        /// Adds "Highlight" to the context menu of a selection.
        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            super.willOpenMenu(menu, with: event)
            guard hasSelection, !menu.items.contains(where: { $0.action == #selector(highlightFromMenu) }) else {
                return
            }
            let item = NSMenuItem(title: "Highlight", action: #selector(highlightFromMenu), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        @objc private func highlightFromMenu(_ sender: Any?) { highlightSelection() }

        override func magnify(with event: NSEvent) {
            changeTextSize(to: TextSize.clamped(textSize * (1 + event.magnification)))
        }
    #endif
}

#if os(macOS)
    extension ReaderEPUBView: @preconcurrency NSTextFinderBarContainer {}
#endif

#if os(iOS)
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
                jump(to: Place(place))
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
