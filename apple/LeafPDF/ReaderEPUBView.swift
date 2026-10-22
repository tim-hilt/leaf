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
/// Not yet there for EPUBs: Markup and the find bar, so the
/// parts of `ReaderDocumentView` for them do nothing.
final class ReaderEPUBView: WKWebView, ReaderDocumentView {
    /// Opens a web link outside the Reader.
    var openExternally: (URL) -> Void = { url in
        #if os(iOS)
            UIApplication.shared.open(url)
        #else
            NSWorkspace.shared.open(url)
        #endif
    }

    private let book: EpubBook
    private let callbacks: ReaderCallbacks

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
    init(
        book: EpubBook, state: ReaderViewState?, contents: TableOfContents, textSize: CGFloat,
        appearance: PageAppearance, handle: ReaderHandle, callbacks: ReaderCallbacks
    ) {
        self.book = book
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
                view.callbacks.onOpen()
            case let text as String where text == "tap":
                view.callbacks.onSingleTap()
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
    func highlightSelection() {}
    func presentFind() {}
    #if os(macOS)
        func findNext() {}
        func findPrevious() {}
    #endif
    func popoverPoint(of note: PageNote) -> CGPoint? { nil }

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
    #else
        override func magnify(with event: NSEvent) {
            changeTextSize(to: TextSize.clamped(textSize * (1 + event.magnification)))
        }
    #endif
}

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
