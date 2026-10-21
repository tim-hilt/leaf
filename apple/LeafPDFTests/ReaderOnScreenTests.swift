#if os(iOS)
    import LeafCore
    import SwiftUI
    import Testing

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
                syncIntervals: SyncIntervals(debounceMs: 3000, pollMs: 10000), inbox: nil)
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

        /// A light window showing the active Tab's Reader, rebuilt for each Tab as the app does.
        private func host(library: LibraryModel, settings: AppSettings, tabs: Tabs) -> UIWindow {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
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
