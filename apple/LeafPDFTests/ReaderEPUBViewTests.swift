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

    // MARK: Reading Progress

    /// A chapter of `count` numbered paragraphs, each several lines long.
    private func paragraphs(_ count: Int, prefix: String = "") -> String {
        (0..<count).map {
            "<p>\(prefix)Paragraph \($0) \(String(repeating: "and some more words to fill the line. ", count: 12))</p>"
        }.joined()
    }

    /// The offset in chapter `index` of `book` where `text` starts.
    private func offset(of text: String, in index: Int, of book: EpubBook) throws -> Int {
        let chapter = try #require(book.text(index: UInt32(index)))
        let range = try #require(chapter.range(of: text))
        return chapter.utf16.distance(from: chapter.utf16.startIndex, to: range.lowerBound)
    }

    @Test func aBookOpensAtItsStartWithoutAReadingProgress() async throws {
        let reader = try await openReader(chapters: [paragraphs(5), paragraphs(5)])

        #expect(reader.topOfViewport == .epub(spineIndex: 0, offset: 0))
    }

    @Test func openingAtASavedPlaceLandsThereAndReportsIt() async throws {
        let book = try await importedBook(chapters: [paragraphs(20), paragraphs(60), paragraphs(5)])
        let place = Place.epub(spineIndex: 1, offset: try offset(of: "Paragraph 30 ", in: 1, of: book))
        let reader = try await openReader(book: book, state: ReaderViewState(place: place))

        #expect(reader.topOfViewport == place)
        #expect(reader.viewState?.place == place)
        // The line of the paragraph is at the top of the viewport.
        let top = try await reader.evaluate(
            "document.querySelectorAll('iframe')[1].getBoundingClientRect().top + frame(1).querySelectorAll('p')[30].getBoundingClientRect().top"
        )
        let distance = try #require(Double(top))
        #expect(abs(distance) < 2)
    }

    @Test func aPlaceInTheMiddleOfAParagraphLandsOnItsLine() async throws {
        let book = try await importedBook(chapters: [paragraphs(40)])
        let start = try offset(of: "Paragraph 20 ", in: 0, of: book)
        let place = Place.epub(spineIndex: 0, offset: start + 150)
        let reader = try await openReader(book: book, state: ReaderViewState(place: place))

        guard case .epub(0, let reported)? = reader.topOfViewport else { throw ImportFailed() }
        // Reported is where its line starts: before the place, and on the same line.
        #expect(reported <= start + 150 && reported > start + 150 - 100)
    }

    @Test func scrollingReportsThePlaceAtTheTopOfTheViewport() async throws {
        var scrolls = 0
        let book = try await importedBook(chapters: [paragraphs(20), paragraphs(60)])
        let reader = try await openReader(book: book, onScreen: true, onScroll: { scrolls += 1 })

        _ = try await reader.evaluate("window.scrollTo(0, document.documentElement.scrollHeight)")
        try await Task.sleep(for: .milliseconds(300))

        #expect(scrolls > 0)
        guard case .epub(let spine, let offset)? = reader.topOfViewport else { throw ImportFailed() }
        #expect(spine == 1 && offset > 0)
        let text = try #require(book.text(index: 1))
        #expect(offset < text.utf16.count)
    }

    @Test func aPlaceIsKeptAcrossReopeningAtItsReportedPlace() async throws {
        let book = try await importedBook(chapters: [paragraphs(60)])
        let first = try await openReader(book: book)
        _ = try await first.evaluate("window.scrollTo(0, 3000)")
        try await Task.sleep(for: .milliseconds(300))
        let reported = try #require(first.viewState)

        let second = try await openReader(book: book, state: reported)

        #expect(second.topOfViewport == reported.place)
    }

    // MARK: Text size

    @Test func aLargerTextSizeReflowsTheTextAndKeepsTheMargin() async throws {
        let book = try await importedBook(chapters: [paragraphs(20)])
        let normal = try await openReader(book: book).scrollHeight()

        let large = try await openReader(book: book, textSize: 2)
        #expect(try await large.scrollHeight() > normal * 1.5)
        #expect(
            try await large.evaluate("frame(0).defaultView.getComputedStyle(frame(0).documentElement).paddingLeft")
                == "24px")
    }

    @Test func changingTheTextSizeKeepsThePlace() async throws {
        let book = try await importedBook(chapters: [paragraphs(20), paragraphs(60), paragraphs(5)])
        let place = Place.epub(spineIndex: 1, offset: try offset(of: "Paragraph 30 ", in: 1, of: book))
        let reader = try await openReader(book: book, state: ReaderViewState(place: place), onScreen: true)
        let height = try await reader.scrollHeight()

        for size in [2, 0.75, 1] as [CGFloat] {
            reader.textSize = size
            try await reader.settle()
            #expect(reader.topOfViewport == place, "at size \(size)")
        }

        reader.textSize = 2
        try await reader.settle()
        #expect(try await reader.scrollHeight() > height)
        // The line of the paragraph is still at the top of the viewport.
        let top = try await reader.evaluate(
            "document.querySelectorAll('iframe')[1].getBoundingClientRect().top + frame(1).querySelectorAll('p')[30].getBoundingClientRect().top"
        )
        let distance = try #require(Double(top))
        #expect(abs(distance) < 4)
    }

    @Test func theKeyboardStepsChangeTheTextSizeAndAnnounceIt() async throws {
        var announced: [CGFloat] = []
        let reader = try await openReader(
            book: importedBook(chapters: [paragraphs(5)]), onTextSizeChange: { announced.append($0) })

        reader.zoomIn()
        reader.zoomIn()
        reader.zoomOut()
        #expect(announced == [1.25, 1.5625, 1.25])
        #expect(reader.textSize == 1.25)

        reader.zoomToFitWidth()
        #expect(reader.textSize == TextSize.normal)
    }

    // MARK: Page Style

    @Test func darkPagesOverrideTheBooksTextAndBackgroundColors() async throws {
        let book = try await importedBook(chapters: [
            "<style>body { background: #fff; color: #111 } div { background: #eee } p { color: red }</style><div><p id=\"p\">Text</p></div>"
        ])
        let reader = try await openReader(book: book, appearance: .dark(night))
        let style = "frame(0).defaultView.getComputedStyle"

        #expect(try await reader.evaluate("\(style)(frame(0).getElementById('p')).color") == "rgb(224, 208, 160)")
        #expect(try await reader.evaluate("\(style)(frame(0).body).backgroundColor") == "rgb(16, 32, 48)")
        #expect(
            try await reader.evaluate("\(style)(frame(0).querySelector('div')).backgroundColor")
                == "rgba(0, 0, 0, 0)")
    }

    @Test func switchingBackToLightPagesRestoresTheBooksColors() async throws {
        let book = try await importedBook(chapters: ["<style>p { color: rgb(1, 2, 3) }</style><p id=\"p\">Text</p>"])
        let reader = try await openReader(book: book, appearance: .dark(night))
        let color = "frame(0).defaultView.getComputedStyle(frame(0).getElementById('p')).color"
        #expect(try await reader.evaluate(color) == "rgb(224, 208, 160)")

        reader.pageAppearance = .light
        try await reader.settle()

        #expect(try await reader.evaluate(color) == "rgb(1, 2, 3)")
    }

    @Test func switchingThePageStyleKeepsThePlace() async throws {
        let book = try await importedBook(chapters: [paragraphs(20), paragraphs(60), paragraphs(5)])
        let place = Place.epub(spineIndex: 1, offset: try offset(of: "Paragraph 30 ", in: 1, of: book))
        let reader = try await openReader(book: book, state: ReaderViewState(place: place), onScreen: true)
        let height = try await reader.scrollHeight()

        for appearance in [.dark(night), .light, .dark(.default)] as [PageAppearance] {
            reader.pageAppearance = appearance
            try await reader.settle()
            #expect(reader.topOfViewport == place)
            #expect(try await reader.scrollHeight() == height)
        }
        let top = try await reader.evaluate(
            "document.querySelectorAll('iframe')[1].getBoundingClientRect().top + frame(1).querySelectorAll('p')[30].getBoundingClientRect().top"
        )
        #expect(abs(try #require(Double(top))) < 2)
    }

    // MARK: Jumps and Back

    /// A book of three chapters whose Table of Contents names the first two and a Section in the second.
    private func navigableBook(links: String = "") async throws -> EpubBook {
        let nav = """
            <html xmlns:epub="x"><body><nav epub:type="toc"><ol>\
            <li><a href="chapter0.xhtml">Start</a></li>\
            <li><a href="chapter1.xhtml">Middle</a><ol><li><a href="chapter1.xhtml#deep">Deep</a></li></ol></li>\
            </ol></nav></body></html>
            """
        return try await importedBook(
            chapters: [
                links + paragraphs(20), paragraphs(10) + "<p id=\"deep\">Deep target</p>" + paragraphs(50),
                paragraphs(5),
            ],
            manifest: #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            files: ["OEBPS/nav.xhtml": Data(nav.utf8)])
    }

    /// Waits until `condition` holds, for up to two seconds.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<40 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func aJumpScrollsThereAndBackReturns() async throws {
        let book = try await importedBook(chapters: [paragraphs(20), paragraphs(60)])
        let reader = try await openReader(book: book, onScreen: true)
        let start = try #require(reader.topOfViewport)
        let target = Place.epub(spineIndex: 1, offset: try offset(of: "Paragraph 30 ", in: 1, of: book))

        reader.jump(to: target)
        try await eventually { reader.topOfViewport == target }
        #expect(reader.topOfViewport == target)
        #expect(reader.backPlace == start)

        reader.back()
        try await eventually { reader.topOfViewport == start }
        #expect(reader.topOfViewport == start)
        #expect(reader.backPlace == nil)
    }

    @Test func aJumpToTheCurrentPlaceRecordsNothing() async throws {
        let reader = try await openReader(book: importedBook(chapters: [paragraphs(5)]), onScreen: true)

        reader.jump(to: try #require(reader.topOfViewport))

        #expect(reader.backPlace == nil)
    }

    @Test func anInternalLinkJumpsToItsAnchorAndBackReturns() async throws {
        let book = try await navigableBook(links: #"<p><a id="go" href="chapter1.xhtml#deep">Deep</a></p>"#)
        let reader = try await openReader(book: book, onScreen: true, openExternally: { _ in })
        let start = try #require(reader.topOfViewport)

        _ = try await reader.evaluate("frame(0).getElementById('go').click()")
        try await eventually { reader.topOfViewport?.isSameSpot(as: start) == false }

        #expect(reader.topOfViewport == .epub(spineIndex: 1, offset: try offset(of: "Deep target", in: 1, of: book)))
        #expect(reader.backPlace == start)
        reader.back()
        try await eventually { reader.topOfViewport == start }
        #expect(reader.topOfViewport == start)
    }

    @Test func theBackCapsuleNamesTheChapterOfTheBackPlace() async throws {
        let book = try await navigableBook()
        var reported: [BackTarget?] = []
        let reader = try await openReader(
            book: book, onScreen: true, contents: TableOfContents(book), onBackChange: { reported.append($0) })

        reader.jump(to: .epub(spineIndex: 1, offset: 0))
        try await eventually { reader.topOfViewport == .epub(spineIndex: 1, offset: 0) }
        reader.jump(to: .epub(spineIndex: 2, offset: 0))
        reader.back()

        #expect(reported == [.chapter("Start"), .chapter("Middle"), nil])
    }

    @Test func theBackPlaceSurvivesReopeningAndIsReportedAgain() async throws {
        let book = try await navigableBook()
        let first = try await openReader(book: book, onScreen: true, contents: TableOfContents(book))
        first.jump(to: .epub(spineIndex: 1, offset: 0))
        try await eventually { first.topOfViewport == .epub(spineIndex: 1, offset: 0) }
        let state = try #require(first.viewState)
        var reported: [BackTarget?] = []

        let second = try await openReader(
            book: book, state: state, contents: TableOfContents(book), onBackChange: { reported.append($0) })

        #expect(second.backPlace == .epub(spineIndex: 0, offset: 0))
        #expect(reported == [.chapter("Start")])
    }

    // MARK: The core's text

    @Test func offsetsInTheDOMEqualTheCoresOffsets() async throws {
        let book = try await importedBook(chapters: [
            "<h1>Title</h1><p>Plain <b id=\"b\">bold</b> &amp; &#233;<i>\u{1F600}x</i> <![CDATA[<cdata>]]> tail</p>",
            "<p><span><em id=\"e\">deep</em></span>\n  <span>last</span></p>",
        ])
        let reader = try await openReader(book: book)

        for index in 0..<2 {
            let core = try #require(book.text(index: UInt32(index)))
            let dom = try await reader.evaluateClient("leaf.text(\(index))")
            #expect(Array(dom.utf16) == Array(core.utf16), "chapter \(index)")
        }
        // A spot inside a node, found by id, is where the core's text has the same character.
        for (index, id, k, character) in [(0, "b", 2, "l"), (1, "e", 3, "p")] {
            let offset = try await reader.evaluateClient(
                "leaf.offset(\(index), document.querySelectorAll('iframe')[\(index)].contentDocument.getElementById('\(id)').firstChild, \(k))"
            )
            let core = try #require(book.text(index: UInt32(index)))
            let at = core.utf16.index(core.utf16.startIndex, offsetBy: try #require(Int(offset)))
            #expect(core.utf16[at] == character.utf16.first)
        }
    }

    @Test func onlyAnEPUBOpensAsABook() async throws {
        let library = try makeLibrary()
        guard case .opened(let pdf) = await library.import(try writePDF(named: "a.pdf", pageCount: 1))
        else { throw ImportFailed() }

        #expect(library.epub(of: pdf) == nil)
    }
}

#if os(iOS)
    /// What the Reader shows on screen in each Page Style, read back as pixels.
    @MainActor @Suite struct ReaderEPUBAppearanceTests: PixelReadback {
        let white = RGB(1, 1, 1)
        /// Below the book's content: nothing but the page's background.
        let empty = CGPoint(x: 5, y: 790)
        let picture = CGPoint(x: 100, y: 400)
        /// Inside the letter-block, and beside it but inside the white box the book gives it.
        let text = CGPoint(x: 100, y: 100)
        let box = CGPoint(x: 350, y: 20)

        /// A book of black on white: one huge letter-block, and a red picture under it.
        func book() async throws -> EpubBook {
            try await importedBook(
                chapters: [
                    """
                    <style>body { margin: 0 } div { margin: 0; background: #fff; color: #000; font: 900 300px/1 sans-serif }</style>\
                    <div>\u{2588}</div><img src=\"pic.png\" style=\"display: block; width: 200px; height: 200px\"/>
                    """
                ],
                manifest: "<item id=\"pic\" href=\"pic.png\" media-type=\"image/png\"/>",
                files: ["OEBPS/pic.png": solidPNG(red: 255, green: 0, blue: 0)])
        }

        @Test func darkPagesShowTheBackgroundAndTextInPageColors() async throws {
            let reader = try await openReader(book: book(), appearance: .dark(night), onScreen: true)

            try await expectShown(night.ink, at: text, in: reader)
            try await expectShown(night.paper, at: box, in: reader)
            try await expectShown(night.paper, at: empty, in: reader)
        }

        @Test func lightPagesShowTheBooksOwnColors() async throws {
            let reader = try await openReader(book: book(), appearance: .light, onScreen: true)

            try await expectShown(RGB(0, 0, 0), at: text, in: reader)
            try await expectShown(white, at: box, in: reader)
            try await expectShown(white, at: empty, in: reader)
        }

        @Test func imagesKeepTheirColorsInDarkPages() async throws {
            let reader = try await openReader(book: book(), appearance: .dark(night), onScreen: true)

            try await expectShown(RGB(1, 0, 0), at: picture, in: reader)
        }

        @Test func switchingThePageStyleChangesTheColors() async throws {
            let reader = try await openReader(book: book(), appearance: .dark(night), onScreen: true)
            try await expectShown(night.ink, at: text, in: reader)

            reader.pageAppearance = .light
            try await expectShown(white, at: box, in: reader)
            try await expectShown(white, at: empty, in: reader)
            try await expectShown(RGB(0, 0, 0), at: text, in: reader)
            try await expectShown(RGB(1, 0, 0), at: picture, in: reader)

            reader.pageAppearance = .dark(night)
            try await expectShown(night.paper, at: box, in: reader)
            try await expectShown(night.paper, at: empty, in: reader)
            try await expectShown(night.ink, at: text, in: reader)
            try await expectShown(RGB(1, 0, 0), at: picture, in: reader)
        }

        @Test func theBackgroundIsPaperFromTheFirstFrame() async throws {
            let reader = ReaderEPUBView(
                book: try await book(), state: nil, contents: TableOfContents(), textSize: TextSize.normal,
                appearance: .dark(night),
                handle: ReaderHandle(), callbacks: ReaderCallbacks())
            reader.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            show(reader)

            try await expectAlwaysShown(night.paper, at: empty, in: reader)
        }
    }
#endif

/// Page Colors that CSS spells without rounding: paper rgb(16, 32, 48), ink rgb(224, 208, 160).
private let night = PageColors(
    paper: RGB(16 / 255, 32 / 255, 48 / 255), ink: RGB(224 / 255, 208 / 255, 160 / 255))

struct ImportFailed: Error {}

@MainActor
func makeLibrary() throws -> LibraryModel {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
    return try LibraryModel(
        root: root, coversFolder: root.appending(path: "covers"), defaults: defaults,
        credentials: CloudCredentials(defaults: defaults, service: "leafpdf-test-\(root.lastPathComponent)"),
        syncIntervals: .standard, inbox: nil)
}

/// An EPUB of `chapters`, imported.
@MainActor
func importedBook(
    chapters: [String], manifest: String = "", files: [String: Data] = [:]
) async throws -> EpubBook {
    let library = try makeLibrary()
    let source = try writeEPUB(named: "book.epub", chapters: chapters, manifest: manifest, files: files)
    guard case .opened(let document) = await library.import(source), let book = library.epub(of: document)
    else { throw ImportFailed() }
    return book
}

/// A Reader on an imported EPUB of `chapters`, once it has opened.
@MainActor
private func openReader(
    chapters: [String], manifest: String = "", files: [String: Data] = [:],
    size: CGSize = CGSize(width: 400, height: 800), onSingleTap: @escaping () -> Void = {},
    openExternally: @escaping (URL) -> Void = { _ in }
) async throws -> ReaderEPUBView {
    try await openReader(
        book: importedBook(chapters: chapters, manifest: manifest, files: files), size: size,
        onSingleTap: onSingleTap, openExternally: openExternally)
}

/// A Reader on `book`, once it has opened.
@MainActor
private func openReader(
    book: EpubBook, state: ReaderViewState? = nil, size: CGSize = CGSize(width: 400, height: 800),
    textSize: CGFloat = TextSize.normal, appearance: PageAppearance = .light, onScreen: Bool = false,
    contents: TableOfContents = TableOfContents(), onSingleTap: @escaping () -> Void = {},
    onScroll: @escaping () -> Void = {}, onTextSizeChange: @escaping (CGFloat) -> Void = { _ in },
    onBackChange: @escaping (BackTarget?) -> Void = { _ in }, openExternally: @escaping (URL) -> Void = { _ in }
) async throws -> ReaderEPUBView {
    var reader: ReaderEPUBView?
    await withCheckedContinuation { opened in
        var once: CheckedContinuation<Void, Never>? = opened
        reader = ReaderEPUBView(
            book: book, state: state, contents: contents, textSize: textSize, appearance: appearance,
            handle: ReaderHandle(),
            callbacks: ReaderCallbacks(
                onSingleTap: onSingleTap,
                onOpen: {
                    once?.resume()
                    once = nil
                },
                onScroll: onScroll, onTextSizeChange: onTextSizeChange, onBackChange: onBackChange))
        reader?.openExternally = openExternally
        reader?.frame = CGRect(origin: .zero, size: size)
        if onScreen, let reader { show(reader) }
    }
    return try #require(reader)
}

/// The windows showing the views under test, which a view only holds weakly. A web view
/// only reports scrolling while it is on screen.
@MainActor private var openWindows: [AnyObject] = []

@MainActor
private func show(_ reader: ReaderEPUBView) {
    #if os(iOS)
        let window = UIWindow(frame: reader.frame)
        window.addSubview(reader)
        window.makeKeyAndVisible()
    #else
        let window = NSWindow(
            contentRect: reader.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader
        window.orderFrontRegardless()
    #endif
    openWindows.append(window)
}

extension ReaderEPUBView {
    /// Back, as the Reader asks for it; `WKWebView` has a `goBack()` of its own.
    fileprivate func back() { (self as any ReaderDocumentView).goBack() }

    /// The result of the JavaScript `script`, as text. `frame(i)` is the document of chapter `i`.
    fileprivate func evaluate(_ script: String) async throws -> String {
        let value = try await evaluateJavaScript(
            "(() => { const frame = i => document.querySelectorAll('iframe')[i].contentDocument; return String(\(script)); })()"
        )
        return value as? String ?? ""
    }

    /// The result of `script` in the Reader's own content world, where `leaf` is, as text.
    fileprivate func evaluateClient(_ script: String) async throws -> String {
        let value = try await evaluateJavaScript("String(\(script))", in: nil, contentWorld: .defaultClient)
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
