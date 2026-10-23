import LeafCore
import WebKit

/// Serves an EPUB to a web view under `leaf-epub://book/`, straight from the
/// core: nothing is unzipped to disk. The root is a page stacking the spine items
/// as frames, in reading order, that load their items on demand; every other path is a file of the EPUB, so the
/// relative references inside the book resolve as its author wrote them. Files
/// are read off the main thread.
@MainActor
final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "leaf-epub"
    /// The page that stacks the spine items.
    nonisolated static let rootURL = URL(string: "\(scheme)://book/")!

    private struct Reply: Sendable {
        let status: Int
        let mediaType: String
        let data: Data
    }

    private let book: EpubBook
    private let spine: [String]
    /// The requests being answered; keeps each alive until answered or stopped.
    private var running: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    init(book: EpubBook, spine: [String]) {
        self.book = book
        self.spine = spine
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        running[key] = urlSchemeTask
        let url = urlSchemeTask.request.url ?? Self.rootURL
        let path = String(url.path(percentEncoded: false).dropFirst())
        Task {
            let reply = await Task.detached { [book, spine] in Self.reply(to: path, book: book, spine: spine) }.value
            // Stopped meanwhile: the web view no longer wants the answer.
            guard running[key] === urlSchemeTask else { return }
            running[key] = nil
            let headers = ["Content-Type": reply.mediaType, "Content-Length": String(reply.data.count)]
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(reply.data)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running[ObjectIdentifier(urlSchemeTask)] = nil
    }

    private nonisolated static func reply(to path: String, book: EpubBook, spine: [String]) -> Reply {
        if path.isEmpty {
            return Reply(status: 200, mediaType: "text/html", data: Data(page(of: spine).utf8))
        }
        guard let file = book.resource(path: path) else {
            return Reply(status: 404, mediaType: "text/plain", data: Data())
        }
        return Reply(status: 200, mediaType: file.mediaType, data: file.bytes)
    }

    /// The page with a frame for each spine item `paths`, each as wide as the view. A frame
    /// has no source but the `data-src` it is given while it is near the viewport; the page's
    /// script (`ReaderEPUBScript`) does that and sizes the frames.
    private nonisolated static func page(of paths: [String]) -> String {
        let frames = paths.map { path in
            let source = rootURL.appending(path: path).absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            return "<iframe data-src=\"\(source)\" scrolling=\"no\"></iframe>"
        }
        return """
            <!DOCTYPE html><html><head>\
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">\
            <style>html, body { margin: 0 } iframe { display: block; width: 100%; height: 0; border: 0 }</style>\
            </head><body>\(frames.joined())</body></html>
            """
    }
}
