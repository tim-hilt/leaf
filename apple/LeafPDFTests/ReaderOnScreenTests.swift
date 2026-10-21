#if os(iOS)
    import LeafCore
    import SwiftUI
    import Testing
    import WebKit

    @testable import LeafPDF

    /// The whole Reader on screen, in a `NavigationStack` as the app has it,
    /// read back as pixels.
    @MainActor @Suite struct ReaderOnScreenTests: PixelReadback {
        @Test func switchingTabsOnDarkPagesNeverShowsWhite() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
            let library = try LibraryModel(
                root: root, coversFolder: root.appending(path: "covers"), defaults: defaults,
                credentials: CloudCredentials(defaults: defaults, service: "leafpdf-test-\(root.lastPathComponent)"),
                syncIntervals: .standard, inbox: nil)
            guard case .opened(let first) = await library.import(try writePDF(named: "a.pdf", pageCount: 2)),
                case .opened(let second) = await library.import(try writePDF(named: "b.pdf", pageCount: 3))
            else { throw ImportFailure() }
            let settings = AppSettings(defaults: defaults)
            settings.theme = .light
            settings.pageStyle = .dark
            let tabs = Tabs(defaults: defaults, library: library.documents)
            tabs.open([first, second])

            let window = host(library: library, settings: settings, tabs: tabs)
            let page = CGPoint(x: 200, y: 400)
            try await expectShown(PageColors.default.paper, at: page, in: window)
            try await settle()

            tabs.select(second.id)
            try await expectAlwaysShown(PageColors.default.paper, at: page, in: window)
        }

        private struct ImportFailure: Error {}

        @Test func tabsMixPDFsAndEPUBs() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
            let library = try LibraryModel(
                root: root, coversFolder: root.appending(path: "covers"), defaults: defaults,
                credentials: CloudCredentials(defaults: defaults, service: "leafpdf-test-\(root.lastPathComponent)"),
                syncIntervals: .standard, inbox: nil)
            guard case .opened(let pdf) = await library.import(try writePDF(named: "a.pdf", pageCount: 2)),
                case .opened(let epub) = await library.import(
                    try writeEPUB(named: "b.epub", body: "<p>Hello from the book</p>"))
            else { throw ImportFailure() }
            let tabs = Tabs(defaults: defaults, library: library.documents)
            tabs.open([epub, pdf])

            let window = host(library: library, settings: AppSettings(defaults: defaults), tabs: tabs)
            let web = try await webView(in: window)
            try await expectText("Hello from the book", in: web)

            tabs.select(pdf.id)
            try await Task.sleep(for: .milliseconds(300))
            #expect(subview(ofType: WKWebView.self, in: window) == nil)
            #expect(subview(ofType: ReaderPDFView.self, in: window) != nil)

            tabs.select(epub.id)
            try await expectText("Hello from the book", in: try await webView(in: window))
        }

        /// The web view of the EPUB Tab showing in `window`, once it is there.
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
                credentials: CloudCredentials(defaults: defaults, service: "leafpdf-test-\(root.lastPathComponent)"),
                syncIntervals: .standard, inbox: nil)
            guard case .opened(let first) = await library.import(try writePDF(named: "a.pdf", pageCount: 2))
            else { throw ImportFailure() }
            let settings = AppSettings(defaults: defaults)
            settings.theme = .light
            settings.pageStyle = .dark
            let tabs = Tabs(defaults: defaults, library: library.documents)
            tabs.open([first])

            let window = host(library: library, settings: settings, tabs: tabs)
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

        /// A light window showing the active Tab's Reader, rebuilt for each Tab as the app does.
        /// Full screen, so the Reader has the screen's safe areas, like on iPad.
        private func host(library: LibraryModel, settings: AppSettings, tabs: Tabs) -> UIWindow {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
            window.frame = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 400, height: 800)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = UIHostingController(
                rootView: Host().environment(library).environment(settings).environment(tabs))
            window.makeKeyAndVisible()
            windows.append(window)
            return window
        }

        private struct Host: View {
            @Environment(LibraryModel.self) private var library
            @Environment(Tabs.self) private var tabs

            var body: some View {
                NavigationStack {
                    if let document = library.documents.first(where: { $0.id == tabs.activeID }) {
                        ReaderView(document: document).id(document.id)
                    }
                }
            }
        }
    }
#endif
