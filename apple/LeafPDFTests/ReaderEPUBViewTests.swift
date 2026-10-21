import LeafCore
import Testing
import WebKit

@testable import LeafPDF

@MainActor @Suite struct ReaderEPUBViewTests {
    @Test func opensAndShowsTheFirstChaptersText() async throws {
        let reader = try await openReader(chapters: ["<p>First chapter text</p>", "<p>Second</p>"])

        #expect(try await reader.chapterText(0).contains("First chapter text"))
    }

    @Test func allChaptersAreReachableByScrollingOneColumn() async throws {
        let chapters = (1...3).map { "<div style=\"height: 1000px\">Chapter \($0)</div>" }
        let reader = try await openReader(chapters: chapters, size: CGSize(width: 400, height: 800))

        let frames = try await reader.chapterFrames()
        #expect(frames.count == 3)
        // Stacked, one under the other, each as wide as the view.
        #expect(frames.allSatisfy { $0.minX == 0 && $0.width == 400 })
        #expect(frames[1].minY >= frames[0].minY + 1000)
        #expect(frames[2].minY >= frames[1].minY + 1000)
        #expect(try await reader.scrollHeight() >= 3000)
        #expect(try await reader.chapterText(2).contains("Chapter 3"))
    }

    @Test func rotatingReflowsTheText() async throws {
        let reader = try await openReader(
            chapters: [String(repeating: "<p>Some words that fill the lines of the page.</p>", count: 20)],
            size: CGSize(width: 400, height: 800))
        let portrait = try await reader.scrollHeight()

        reader.frame.size = CGSize(width: 800, height: 400)
        try await reader.settle()

        #expect(try await reader.scrollHeight() < portrait)
    }

    @Test func theBooksOwnStylesAreKeptWithAFixedSideMargin() async throws {
        let reader = try await openReader(chapters: ["<style>p { color: rgb(1, 2, 3); }</style><p>Styled</p>"])

        #expect(
            try await reader.evaluate("frame(0).defaultView.getComputedStyle(frame(0).querySelector('p')).color")
                == "rgb(1, 2, 3)")
        #expect(
            try await reader.evaluate("frame(0).defaultView.getComputedStyle(frame(0).documentElement).paddingLeft")
                == "24px")
    }

    @Test func imagesAndOtherResourcesComeFromTheBook() async throws {
        let png = solidPNG(red: 255, green: 0, blue: 0)
        let reader = try await openReader(
            chapters: ["<p>Picture</p><img id=\"i\" src=\"pic.png\"/>"],
            manifest: "<item id=\"pic\" href=\"pic.png\" media-type=\"image/png\"/>",
            files: ["OEBPS/pic.png": png])

        #expect(try await reader.evaluate("frame(0).getElementById('i').naturalWidth") == "40")
    }

    @Test func webLinksOpenInTheBrowserAndNeverNavigateTheBook() async throws {
        var opened: [URL] = []
        let reader = try await openReader(
            chapters: [
                "<p><a id=\"web\" href=\"https://example.com/page\">Web</a> <a id=\"in\" href=\"chapter1.xhtml\">Next</a></p>",
                "<p>Second</p>",
            ],
            openExternally: { opened.append($0) })

        _ = try await reader.evaluate("frame(0).getElementById('web').click()")
        _ = try await reader.evaluate("frame(0).getElementById('in').click()")
        try await Task.sleep(for: .milliseconds(300))

        #expect(opened == [URL(string: "https://example.com/page")!])
        #expect(try await reader.chapterText(0).contains("Web"))
    }

    @Test func aTapOnTheTextIsReportedButNotOnALink() async throws {
        var taps = 0
        let reader = try await openReader(
            chapters: ["<p id=\"p\">Text</p><a id=\"a\" href=\"https://example.com\">Link</a>"],
            onSingleTap: { taps += 1 }, openExternally: { _ in })

        _ = try await reader.evaluate("frame(0).getElementById('a').click()")
        try await Task.sleep(for: .milliseconds(200))
        #expect(taps == 0)
        _ = try await reader.evaluate("frame(0).getElementById('p').click()")
        try await Task.sleep(for: .milliseconds(200))
        #expect(taps == 1)
    }

    @Test func theBooksOwnScriptsDontRun() async throws {
        let reader = try await openReader(
            chapters: ["<p>Text</p><script>document.body.setAttribute('data-ran', 'yes')</script>"])

        #expect(try await reader.evaluate("frame(0).body.getAttribute('data-ran')") == "null")
    }

    @Test func onlyAnEPUBOpensAsABook() async throws {
        let library = try makeLibrary()
        guard case .opened(let pdf) = await library.import(try writePDF(named: "a.pdf", pageCount: 1))
        else { throw ImportFailed() }

        #expect(library.epub(of: pdf) == nil)
    }
}

private struct ImportFailed: Error {}

@MainActor
private func makeLibrary() throws -> LibraryModel {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
    return try LibraryModel(
        root: root, coversFolder: root.appending(path: "covers"), defaults: defaults,
        credentials: CloudCredentials(defaults: defaults, service: "leafpdf-test-\(root.lastPathComponent)"),
        syncIntervals: .standard, inbox: nil)
}

/// A Reader on an imported EPUB of `chapters`, once it has opened.
@MainActor
private func openReader(
    chapters: [String], manifest: String = "", files: [String: Data] = [:],
    size: CGSize = CGSize(width: 400, height: 800), onSingleTap: @escaping () -> Void = {},
    openExternally: @escaping (URL) -> Void = { _ in }
) async throws -> ReaderEPUBView {
    let library = try makeLibrary()
    let source = try writeEPUB(named: "book.epub", chapters: chapters, manifest: manifest, files: files)
    guard case .opened(let document) = await library.import(source), let book = library.epub(of: document)
    else { throw ImportFailed() }
    var reader: ReaderEPUBView?
    await withCheckedContinuation { opened in
        var once: CheckedContinuation<Void, Never>? = opened
        reader = ReaderEPUBView(
            book: book, handle: ReaderHandle(),
            callbacks: ReaderCallbacks(
                onSingleTap: onSingleTap,
                onOpen: {
                    once?.resume()
                    once = nil
                }))
        reader?.openExternally = openExternally
        reader?.frame = CGRect(origin: .zero, size: size)
    }
    return try #require(reader)
}

extension ReaderEPUBView {
    /// The result of the JavaScript `script`, as text. `frame(i)` is the document of chapter `i`.
    fileprivate func evaluate(_ script: String) async throws -> String {
        let value = try await evaluateJavaScript(
            "(() => { const frame = i => document.querySelectorAll('iframe')[i].contentDocument; return String(\(script)); })()"
        )
        return value as? String ?? ""
    }

    fileprivate func chapterText(_ index: Int) async throws -> String {
        try await evaluate("frame(\(index)).body.innerText")
    }

    fileprivate func scrollHeight() async throws -> Double {
        Double(try await evaluate("document.documentElement.scrollHeight")) ?? 0
    }

    /// The chapters' frames in the page.
    fileprivate func chapterFrames() async throws -> [CGRect] {
        let rects = try await evaluate(
            "[...document.querySelectorAll('iframe')].map(f => { const r = f.getBoundingClientRect(); return [r.left, r.top + scrollY, r.width, r.height].join(','); }).join(';')"
        )
        return rects.split(separator: ";").map { rect in
            let n = rect.split(separator: ",").compactMap { Double($0) }
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
    }

    /// Waits for the page to reflow after a size change.
    fileprivate func settle() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }
}
