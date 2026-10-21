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
/// browser through `openExternally`; links inside the book do nothing yet.
/// `onOpen` is called once every spine item is laid out and the view has scrolled
/// to its opening place; a tap on text that isn't a link is reported to
/// `onSingleTap`. The page reports the position at the top of the viewport as it
/// scrolls (`ReaderEPUBScript`), which `topOfViewport` gives and `onScroll` announces.
///
/// Not yet there for EPUBs: zoom, Jumps, Markup and the find bar, so the
/// parts of `ReaderDocumentView` for them do nothing.
/// The text doesn't keep its place when it reflows yet.
final class ReaderEPUBView: WKWebView, ReaderDocumentView {
    /// Opens a web link outside the Reader.
    var openExternally: (URL) -> Void = { url in
        #if os(iOS)
            UIApplication.shared.open(url)
        #else
            NSWorkspace.shared.open(url)
        #endif
    }

    private let callbacks: ReaderCallbacks
    /// The position at the top of the viewport, as last reported; nil until opened.
    private var top: Place?
    private var isOpen = false

    /// Opens `book` at the place of `state`, else at its start, and registers as the
    /// `handle`'s view.
    init(book: EpubBook, state: ReaderViewState?, handle: ReaderHandle, callbacks: ReaderCallbacks) {
        self.callbacks = callbacks
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
                source: ReaderEPUBScript.source(frameCount: spine.count, start: start),
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        super.init(frame: .zero, configuration: configuration)
        messages.view = self
        navigationDelegate = self
        uiDelegate = self
        handle.view = self
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
                view.callbacks.onOpen()
            case let text as String where text == "tap":
                view.callbacks.onSingleTap()
            default: break
            }
        }
    }

    // MARK: ReaderDocumentView

    var topOfViewport: Place? { top }
    var viewState: ReaderViewState? { top.map { ReaderViewState(place: $0) } }

    func jump(to place: Place) {}
    func goBack() {}
    func zoomIn() {}
    func zoomOut() {}
    func zoomToFitWidth() {}
    func highlightSelection() {}
    func presentFind() {}
    #if os(macOS)
        func findNext() {}
        func findPrevious() {}
    #endif
    func popoverPoint(of note: PageNote) -> CGPoint? { nil }
}

extension ReaderEPUBView: WKNavigationDelegate {
    /// Web links go to the browser. Nothing else navigates a frame away from its Chapter.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        guard navigationAction.navigationType == .linkActivated else { return .allow }
        openWebLink(navigationAction.request.url)
        return .cancel
    }

    fileprivate func openWebLink(_ url: URL?) {
        guard let url, let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) else { return }
        openExternally(url)
    }
}

extension ReaderEPUBView: WKUIDelegate {
    /// Links that ask for a new window (`target="_blank"`) go to the browser too.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        openWebLink(navigationAction.request.url)
        return nil
    }
}
