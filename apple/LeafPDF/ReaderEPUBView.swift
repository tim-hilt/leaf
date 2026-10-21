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
/// `onOpen` is called once every spine item is laid out; a tap on text that
/// isn't a link is reported to `onSingleTap`.
///
/// Not yet there for EPUBs: places, zoom, Jumps, Markup and the find bar, so the
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

    private let callbacks: ReaderCallbacks

    /// Opens `book` at its start, and registers as the `handle`'s view.
    init(book: EpubBook, handle: ReaderHandle, callbacks: ReaderCallbacks) {
        self.callbacks = callbacks
        let spine = book.spine()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            EPUBSchemeHandler(book: book, spine: spine), forURLScheme: EPUBSchemeHandler.scheme)
        // Books' own scripts stay off; the Reader's runs in its own world, out of their reach.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let messages = Messages()
        configuration.userContentController.add(messages, contentWorld: .defaultClient, name: Self.channel)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.script(frameCount: spine.count), injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: .defaultClient))
        super.init(frame: .zero, configuration: configuration)
        messages.view = self
        navigationDelegate = self
        uiDelegate = self
        handle.view = self
        load(URLRequest(url: EPUBSchemeHandler.rootURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: The page

    private static let channel = "reader"

    /// Run in the page that stacks the frames. As each frame loads, it adds the
    /// side margin, keeps its height equal to its content's, and reports taps.
    /// The styles have no specificity, so the book's own CSS wins over them.
    private static func script(frameCount: Int) -> String {
        """
        (() => {
          const style = ':where(html) { padding: 0 24px } :where(img, svg, video) { max-width: 100% }';
          const post = message => window.webkit.messageHandlers.\(channel).postMessage(message);
          let loaded = 0;
          document.addEventListener('load', event => {
            const frame = event.target;
            if (frame.tagName !== 'IFRAME') return;
            const doc = frame.contentDocument;
            const sheet = doc.createElement('style');
            sheet.textContent = style;
            (doc.head || doc.documentElement).append(sheet);
            const fit = () => { frame.style.height = doc.documentElement.offsetHeight + 'px'; };
            fit();
            new ResizeObserver(fit).observe(doc.documentElement);
            doc.addEventListener('click', click => {
              if (!click.target.closest('a[href]') && doc.getSelection().isCollapsed) post('tap');
            });
            if (++loaded === \(frameCount)) post('opened');
          }, true);
        })();
        """
    }

    /// Receives what the page reports. Apart so the web view's configuration
    /// doesn't keep the view alive.
    @MainActor
    private final class Messages: NSObject, WKScriptMessageHandler {
        weak var view: ReaderEPUBView?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.body as? String {
            case "opened": view?.callbacks.onOpen()
            case "tap": view?.callbacks.onSingleTap()
            default: break
            }
        }
    }

    // MARK: ReaderDocumentView

    var topOfViewport: Place? { nil }
    var viewState: ReaderViewState? { nil }

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
