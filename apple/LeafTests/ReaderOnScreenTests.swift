#if os(iOS)
    import LeafCore
    import SwiftUI
    import Testing
    import WebKit

    @testable import Leaf

    /// The whole Reader on screen, in a `NavigationStack` as the app has it,
    /// read back as pixels.
    @MainActor @Suite struct ReaderOnScreenTests: PixelReadback {
        private struct ImportFailure: Error {}

        @Test func aDocumentOpensWithItsMarkup() async throws {
            // Drawn in the first pass, rather than drawn in after the pages.
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
            let library = try LibraryModel(
                root: root, coversFolder: root.appending(path: "covers"), defaults: defaults,
                credentials: CloudCredentials(defaults: defaults, service: "leaf-test-\(root.lastPathComponent)"),
                syncIntervals: .standard, inbox: nil)
            guard case .opened(let document) = await library.import(try writePDF(named: "a.pdf", pageCount: 2))
            else { throw ImportFailure() }
            let anchor = Anchor.pdf([PageRects(pageIndex: 0, rects: [CGRect(x: 100, y: 300, width: 400, height: 300)])])
            _ = try #require(await library.addHighlight(anchor, quotedText: "a", to: document))
            let window = host(document, library: library, settings: AppSettings(defaults: defaults))
            for _ in 0..<200 {
                if let reader = subview(ofType: ReaderPDFView.self, in: window) {
                    #expect(reader.highlights.count == 1)
                    return
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("The Reader never showed")
        }

        @Test func anEPUBOpensInTheWebView() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
            let library = try LibraryModel(
                root: root, coversFolder: root.appending(path: "covers"), defaults: defaults,
                credentials: CloudCredentials(defaults: defaults, service: "leaf-test-\(root.lastPathComponent)"),
                syncIntervals: .standard, inbox: nil)
            guard
                case .opened(let epub) = await library.import(
                    try writeEPUB(named: "b.epub", body: "<p>Hello from the book</p>"))
            else { throw ImportFailure() }

            let window = host(epub, library: library, settings: AppSettings(defaults: defaults))
            try await expectText("Hello from the book", in: try await webView(in: window))
        }

        /// The web view of the EPUB showing in `window`, once it is there.
        private func webView(in window: UIWindow) async throws -> WKWebView {
            for _ in 0..<40 {
                if let web = subview(ofType: WKWebView.self, in: window) { return web }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ImportFailure()
        }

        private func subview<V: UIView>(ofType type: V.Type, in view: UIView) -> V? {
            if let match = view as? V { return match }
            return view.subviews.lazy.compactMap { subview(ofType: type, in: $0) }.first
        }

        /// Expects the first Chapter of the book in `web` to show `text`, within two seconds.
        private func expectText(_ text: String, in web: WKWebView) async throws {
            var shown = ""
            for _ in 0..<40 where !shown.contains(text) {
                shown =
                    (try? await web.evaluateJavaScript(
                        "document.querySelector('iframe')?.contentDocument?.body?.innerText ?? ''") as? String) ?? ""
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(shown.contains(text), "\(shown)")
        }

        /// In a light window with Dark Pages, the Reader must not leave a
        /// plain white strip over the bottom safe area (the home indicator
        /// area): the pages fill the whole screen, so the bottom edge is dark.
        @Test func bottomSafeAreaShowsDarkPagesNotWhiteStrip() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
            let library = try LibraryModel(
                root: root, coversFolder: root.appending(path: "covers"), defaults: defaults,
                credentials: CloudCredentials(defaults: defaults, service: "leaf-test-\(root.lastPathComponent)"),
                syncIntervals: .standard, inbox: nil)
            guard case .opened(let first) = await library.import(try writePDF(named: "a.pdf", pageCount: 2))
            else { throw ImportFailure() }
            let settings = AppSettings(defaults: defaults)
            settings.theme = .light
            settings.pageStyle = .dark
            let window = host(first, library: library, settings: settings)
            // On the bottom edge, inside the bottom safe area inset, where
            // the white strip shows on iPad in a light system theme. There the
            // pages show their paper or, between pages, the darker gap.
            let bottomEdge = CGPoint(x: 200, y: window.bounds.height - 10)
            let paper = PageColors.default.paper
            let gap = RGB(paper.r / 2, paper.g / 2, paper.b / 2)
            var shown = pixel(at: bottomEdge, in: window)
            for _ in 0..<40
            where !shown.isClose(to: paper) && !shown.isClose(to: gap) {
                try await Task.sleep(for: .milliseconds(50))
                shown = pixel(at: bottomEdge, in: window)
            }
            #expect(shown.isClose(to: paper) || shown.isClose(to: gap), "\(shown) at \(bottomEdge)")
        }

        /// A light window showing the Reader of `document`.
        /// Full screen, so the Reader has the screen's safe areas, like on iPad.
        private func host(_ document: LibraryDocument, library: LibraryModel, settings: AppSettings) -> UIWindow {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
            window.frame = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 400, height: 800)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = UIHostingController(
                rootView: NavigationStack { ReaderView(document: document) }.environment(library).environment(settings))
            window.makeKeyAndVisible()
            windows.append(window)
            return window
        }

    }
#endif
