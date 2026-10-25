import LeafCore
import Testing
import WebKit

@testable import Leaf

#if os(iOS)
    import UIKit.UIGestureRecognizerSubclass
#endif

@MainActor @Suite struct ReaderEPUBViewTests {
    @Test func opensAndShowsTheFirstChaptersText() async throws {
        let reader = try await openReader(chapters: ["<p>First chapter text</p>", "<p>Second</p>"])

        #expect(try await reader.chapterText(0).contains("First chapter text"))
    }

    @Test func allChaptersAreReachableByScrollingOneColumn() async throws {
        let chapters = (1...3).map { "<div style=\"height: 1000px\">Chapter \($0)</div>" }
        let reader = try await openReader(
            book: importedBook(chapters: chapters), size: CGSize(width: 400, height: 800), onScreen: true)
        // Chapters load as they come near the viewport.
        try await eventually {
            try await reader.scrollAsReader("window.scrollTo(0, document.documentElement.scrollHeight)")
            try await Task.sleep(for: .milliseconds(100))
            return try await reader.chapterText(2).contains("Chapter 3")
        }

        let frames = try await reader.chapterFrames()
        // Without a trackpad, macOS shows a scroll bar that narrows the view.
        let width = Double(try await reader.evaluate("document.documentElement.clientWidth")) ?? 0
        #expect(frames.count == 3)
        // Stacked, one under the other, each as wide as the view.
        #expect(frames.allSatisfy { $0.minX == 0 && $0.width == width })
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

    @Test func rasterImagesAreNeverBlownUpBeyondTheirPixels() async throws {
        let reader = try await openReader(
            chapters: [
                """
                <img id="i" src="pic.png" style="width: 100%"/>\
                <svg id="s" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
                viewBox="0 0 40 60" width="100%" height="100%"><image width="40" height="60" xlink:href="pic.png"/></svg>
                """
            ],
            manifest: "<item id=\"pic\" href=\"pic.png\" media-type=\"image/png\"/>",
            files: ["OEBPS/pic.png": solidPNG(red: 255, green: 0, blue: 0)])

        #expect(try await reader.evaluate("frame(0).getElementById('i').getBoundingClientRect().width") == "40")
        #expect(try await reader.evaluate("frame(0).getElementById('s').getBoundingClientRect().width") == "40")
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

        try await reader.scrollAsReader("window.scrollTo(0, document.documentElement.scrollHeight)")
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
        try await first.scrollAsReader("window.scrollTo(0, 3000)")
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

    @Test func aBurstOfTextSizesAsInAPinchEndsAtTheLastAndKeepsThePlace() async throws {
        let book = try await importedBook(chapters: [paragraphs(20), paragraphs(60)])
        let place = Place.epub(spineIndex: 1, offset: try offset(of: "Paragraph 30 ", in: 1, of: book))
        let reader = try await openReader(book: book, state: ReaderViewState(place: place), onScreen: true)

        for step in 1...30 { reader.textSize = 1 + CGFloat(step) / 30 }
        try await reader.settle()

        #expect(try await reader.evaluate("getComputedStyle(frame(1).body).zoom") == "2")
        #expect(reader.topOfViewport == place, "\(String(describing: reader.topOfViewport)) vs \(place)")
    }

    #if os(iOS)
        @Test func aPinchChangesTheTextSizeWithoutScrolling() async throws {
            let reader = try await openReader(book: importedBook(chapters: [paragraphs(5)]), onScreen: true)
            let pinch = try #require(reader.gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer }.first)
            let pan = reader.scrollView.panGestureRecognizer

            pinch.state = .began
            try await eventually { !pan.isEnabled }
            #expect(!pan.isEnabled)

            pinch.state = .ended
            try await eventually { pan.isEnabled }
            #expect(pan.isEnabled)
        }
    #endif

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
    private func eventually(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<40 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
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

    // MARK: Document Search

    @Test func foundMatchesAreListedInReadingOrderAndMarkedInTheText() async throws {
        let book = try await importedBook(chapters: [
            "<p>alpha beta</p>", "<p>beta</p>", "<p>Beta gamma <b>beta</b></p>",
        ])
        let reader = try await openReader(book: book, onScreen: true)

        reader.matches.search(.init("beta"))
        try await eventually { reader.results.matches.count == 4 }

        #expect(
            reader.results.matches.map(\.excerpt.text) == ["alpha beta", "beta", "Beta gamma beta", "Beta gamma beta"])
        #expect(reader.results.matches.allSatisfy { $0.pageNumber == nil })
        // Every match is marked, the current one apart.
        reader.matches.makeCurrent(2)
        for _ in 0..<40 where try await reader.marks("leaf-find-current") != [0, 0, 1] {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await reader.marks("leaf-find") == [1, 1, 1])
        #expect(try await reader.marks("leaf-find-current") == [0, 0, 1])
        // They cover the matched text, also across elements.
        #expect(
            try await reader.evaluateClient(
                "[...document.querySelectorAll('iframe')[2].contentWindow.CSS.highlights.get('leaf-find-current')].map(r => r.toString())"
            ) == "Beta")
        #expect(reader.results.current == 2)
    }

    @Test func aNewSearchReplacesTheMatchesAndEndingItClearsThem() async throws {
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>apple banana</p><p>apple</p>"]), onScreen: true)
        reader.matches.search(.init("apple"))
        try await eventually { reader.results.matches.count == 2 }

        reader.matches.search(.init("banana"))
        try await eventually { reader.results.matches.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(reader.results.matches.count == 1)

        for _ in 0..<40 where try await reader.marks("leaf-find") != [1] {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await reader.marks("leaf-find") == [1])

        reader.matches.clear()
        #expect(reader.results.matches.isEmpty)
        for _ in 0..<40 where try await reader.marks("leaf-find") != [0] {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await reader.marks("leaf-find") == [0])
    }

    @Test func choosingAResultJumpsThereAndBackReturns() async throws {
        let book = try await importedBook(chapters: [paragraphs(20), paragraphs(60)])
        let reader = try await openReader(book: book, onScreen: true)
        let start = try #require(reader.topOfViewport)
        reader.beginSearchSession()
        reader.matches.search(.init("Paragraph 30 "))
        try await eventually { reader.results.matches.count == 1 }

        reader.results.onChoose(0)

        try await eventually { reader.backPlace != nil }
        #expect(reader.backPlace == start)
        try await eventually { reader.topOfViewport?.isSameSpot(as: start) == false }
        // The match is on screen.
        let top = try await reader.evaluate(
            "document.querySelectorAll('iframe')[1].getBoundingClientRect().top + frame(1).querySelectorAll('p')[30].getBoundingClientRect().top"
        )
        #expect((0..<800).contains(try #require(Double(top))))

        reader.back()
        try await eventually { reader.topOfViewport == start }
        #expect(reader.topOfViewport == start)
        #expect(reader.backPlace == nil)
    }

    #if os(iOS)
        @Test func theFindBarIsDrivenByDocumentSearch() async throws {
            let book = try await importedBook(chapters: ["<p>apple</p>", "<p>nothing</p>", "<p>an apple, apple</p>"])
            let reader = try await openReader(book: book, onScreen: true)
            reader.presentFind()
            let interaction = reader.find.interaction
            #expect(interaction.isFindNavigatorVisible)

            // As the bar does when the reader types (and "next" when they press it).
            let session = try #require(interaction.activeFindSession)
            session.performSearch(query: "app", options: nil)
            try await eventually { session.resultCount == 3 }
            #expect(session.resultCount == 3)
            #expect(session.highlightedResultIndex == 0)
            session.highlightNextResult(in: .forward)
            #expect(session.highlightedResultIndex == 1)
            session.highlightNextResult(in: .backward)
            session.highlightNextResult(in: .backward)
            #expect(session.highlightedResultIndex == 2)

            // The results list reads the same matches, and choosing one makes it current.
            #expect(reader.results.matches.count == 3)
            #expect(reader.results.current == 2)
            reader.results.onChoose(0)
            #expect(session.highlightedResultIndex == 0)

            interaction.dismissFindNavigator()
            #expect(reader.results.matches.isEmpty)
            #expect(!reader.results.isFindBarOpen)
        }
    #endif

    #if os(macOS)
        @Test func theFindBarStepsThroughMatchesInTheBooksText() async throws {
            let book = try await importedBook(chapters: ["<p>x Apple</p>", "<p>nothing</p>", "<p>an apple, apple</p>"])
            let reader = try await openReader(book: book, onScreen: true)
            // The bar's options are remembered on the find pasteboard.
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setPropertyList(
                [NSPasteboard.PasteboardType.TextFinderOptionKey.textFinderCaseInsensitiveKey: true],
                forType: .textFinderOptions)
            reader.presentFind()
            #expect(reader.isFindBarVisible)
            #expect(reader.results.isFindBarOpen)

            // As the reader does when they type, and when they press ⌘G.
            func searchField(in view: NSView) -> NSSearchField? {
                (view as? NSSearchField) ?? view.subviews.lazy.compactMap(searchField(in:)).first
            }
            let field = try #require(reader.findBarView.flatMap(searchField(in:)))
            field.stringValue = "app"
            field.sendAction(field.action, to: field.target)

            // The results list follows the bar's search, and its current match.
            try await eventually { reader.results.matches.count == 3 && reader.results.current == 0 }
            #expect(reader.results.matches.map(\.pageNumber) == [nil, nil, nil])
            #expect(reader.results.matches.map(\.excerpt.text) == ["x Apple", "an apple, apple", "an apple, apple"])
            #expect(reader.results.current == 0)

            reader.find.next()
            try await eventually { reader.results.current == 1 }
            #expect(reader.results.current == 1)

            // Choosing a match makes it current, and the bar goes on from there.
            reader.results.onChoose(2)
            #expect(reader.results.current == 2)
            try await Task.sleep(for: .milliseconds(300))
            reader.find.previous()
            try await eventually { reader.results.current == 1 }
            #expect(reader.results.current == 1)

            reader.find.finder.performAction(.hideFindInterface)
            #expect(!reader.isFindBarVisible)
            #expect(reader.results.matches.isEmpty)
            #expect(!reader.results.isFindBarOpen)
        }

    #endif

    @Test func aMatchAlreadyInViewDoesNotMoveTheText() async throws {
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>needle</p>" + paragraphs(40)]), onScreen: true)
        let start = try #require(reader.topOfViewport)
        reader.beginSearchSession()
        reader.matches.search(.init("needle"))
        try await eventually { reader.results.matches.count == 1 }

        reader.results.onChoose(0)
        try await Task.sleep(for: .milliseconds(300))

        #expect(reader.topOfViewport == start)
        #expect(reader.backPlace == nil)
    }

    // MARK: The core's text

    @Test func offsetsInTheDOMEqualTheCoresOffsets() async throws {
        // With the XHTML 1.1 doctype many EPUB 2 books have, the web view resolves HTML's entities.
        let book = try await importedBook(
            chapters: [
                "<h1>Title</h1><p>Plain <b id=\"b\">bold</b> &amp; &#233;<i>\u{1F600}x</i> <![CDATA[<cdata>]]> tail</p>",
                "<p><span><em id=\"e\">deep</em></span>\n  <span>last&nbsp;&mdash;&rsquo;</span></p>",
            ],
            doctype: #"<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "#
                + #""http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">"#)
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

    // MARK: Highlights

    /// What `onHighlight` reports.
    private struct Passage: Equatable {
        let anchor: Anchor
        let quotedText: String
    }

    /// An EPUB Highlight of the characters from `start` to `end` (spine index, offset).
    private func highlight(
        _ id: String, from start: (Int, Int), to end: (Int, Int), quoting quoted: String,
        color: RGB = .sampleYellow, note: String? = nil
    ) -> Highlight {
        Highlight(
            id: id,
            anchor: .epub(
                start: EpubPosition(spineIndex: start.0, offset: start.1),
                end: EpubPosition(spineIndex: end.0, offset: end.1)),
            quotedText: quoted, color: color, note: note)
    }

    private let yellow = "leaf-hl-ffeb3c"

    /// Selects, in chapter 0, from `startNode`'s character `start` to `endNode`'s character `end`,
    /// the nodes found by the JavaScript expressions in `frame`'s document.
    private func select(
        in reader: ReaderEPUBView, from startNode: String, _ start: Int, to endNode: String, _ end: Int
    ) async throws {
        _ = try await reader.evaluate(
            """
            (() => { const d = frame(0), r = d.createRange(); r.setStart(\(startNode), \(start)); \
            r.setEnd(\(endNode), \(end)); const s = d.defaultView.getSelection(); s.removeAllRanges(); \
            s.addRange(r); })()
            """)
    }

    /// What the Highlight drawn in `name` covers in chapter `index`, range by range.
    private func covered(_ reader: ReaderEPUBView, _ name: String, in index: Int = 0) async throws -> [String] {
        let list = try await reader.evaluateClient(
            """
            JSON.stringify([...(document.querySelectorAll('iframe')[\(index)].contentWindow.CSS.highlights.get('\(name)') \
            ?? [])].map(r => r.toString()))
            """)
        return (try? JSONDecoder().decode([String].self, from: Data(list.utf8))) ?? []
    }

    @Test func highlightingTheSelectionReportsItsPositionsAndQuotedText() async throws {
        var reported: [Passage] = []
        let reader = try await openReader(
            chapters: ["<p id=\"p\">Call me <b id=\"b\">Ishmael</b>. Some years ago</p>"],
            onHighlight: { reported.append(Passage(anchor: $0, quotedText: $1)) })

        try await select(
            in: reader, from: "frame(0).getElementById('b').firstChild", 2,
            to: "frame(0).getElementById('p').lastChild", 6)
        reader.highlightSelection()
        try await eventually { !reported.isEmpty }

        let anchor = Anchor.epub(
            start: EpubPosition(spineIndex: 0, offset: 10), end: EpubPosition(spineIndex: 0, offset: 21))
        #expect(reported == [Passage(anchor: anchor, quotedText: "hmael. Some")])
        // The selection is cleared once it is highlighted.
        #expect(try await reader.evaluate("frame(0).getSelection().isCollapsed") == "true")
    }

    @Test func aSelectionBetweenElementsHasTheOffsetsOfItsText() async throws {
        var reported: [Passage] = []
        let reader = try await openReader(
            chapters: ["<h1>Title</h1><p id=\"p\">One <i>two</i> three</p>"],
            onHighlight: { reported.append(Passage(anchor: $0, quotedText: $1)) })

        // From after the heading to the end of the paragraph, by element boundaries.
        try await select(
            in: reader, from: "frame(0).body", 1, to: "frame(0).getElementById('p')", 3)
        reader.highlightSelection()
        try await eventually { !reported.isEmpty }

        let anchor = Anchor.epub(
            start: EpubPosition(spineIndex: 0, offset: 5), end: EpubPosition(spineIndex: 0, offset: 18))
        #expect(reported == [Passage(anchor: anchor, quotedText: "One two three")])
    }

    @Test func highlightingWithoutASelectionDoesNothing() async throws {
        var reported: [Passage] = []
        let reader = try await openReader(
            chapters: ["<p>Text</p>"], onHighlight: { reported.append(Passage(anchor: $0, quotedText: $1)) })

        reader.highlightSelection()
        try await Task.sleep(for: .milliseconds(300))

        #expect(reported.isEmpty)
    }

    @Test func aHighlightIsDrawnOverItsWords() async throws {
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>Call me <b>Ishmael</b>. Some years ago</p>"]),
            highlights: [highlight("a", from: (0, 5), to: (0, 12), quoting: "me Ishm")])

        #expect(try await covered(reader, yellow) == ["me Ishm"])
    }

    @Test func aHighlightMaySpanChaptersAndOverlappingOnesStaySeparate() async throws {
        let green = RGB(0, 1, 0)
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>Call me Ishmael.</p>", "<p>Some years ago</p>"]),
            highlights: [
                highlight("a", from: (0, 8), to: (1, 4), quoting: "Ishmael.\nSome"),
                highlight("b", from: (0, 5), to: (0, 11), quoting: "e Ishm", color: green),
            ])

        #expect(try await covered(reader, yellow, in: 0) == ["Ishmael."])
        // Chapter 1 loads after the one that opens, and is drawn once it has.
        try await eventually { try await self.covered(reader, self.yellow, in: 1) == ["Some"] }
        #expect(try await covered(reader, yellow, in: 1) == ["Some"])
        #expect(try await covered(reader, "leaf-hl-00ff00") == ["e Ishm"])
    }

    @Test func highlightsStayOnTheSameWordsWhenTheTextSizeChanges() async throws {
        let text = String(repeating: "filler words that wrap onto several lines ", count: 30)
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>\(text)</p><p>The target words are here</p>"]),
            onScreen: true,
            highlights: [highlight("a", from: (0, text.count + 4), to: (0, text.count + 10), quoting: "target")])
        let before = try await reader.highlightBox(yellow)

        reader.textSize = TextSize.zoomedIn(from: reader.textSize)
        try await reader.settle()

        #expect(try await covered(reader, yellow) == ["target"])
        let after = try await reader.highlightBox(yellow)
        // It moved and grew with the text it covers.
        #expect(after.width > before.width)
        #expect(after.maxY != before.maxY)
    }

    @Test func aHighlightWhoseOffsetsNoLongerMatchIsFoundByItsQuotedText() async throws {
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>Call me Ishmael. Some years ago</p>"]),
            highlights: [highlight("a", from: (0, 0), to: (0, 4), quoting: "Some years")])

        #expect(try await covered(reader, yellow) == ["Some years"])
    }

    @Test func aHighlightWhoseTextIsNowhereIsNotDrawn() async throws {
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>Call me Ishmael.</p>"]),
            highlights: [highlight("a", from: (0, 0), to: (0, 4), quoting: "Queequeg")])
        try await Task.sleep(for: .milliseconds(300))

        #expect(try await covered(reader, yellow) == [])
    }

    @Test func changedHighlightsAreRedrawn() async throws {
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>Call me Ishmael.</p>"]),
            highlights: [highlight("a", from: (0, 0), to: (0, 4), quoting: "Call")])

        reader.highlights = [highlight("b", from: (0, 8), to: (0, 15), quoting: "Ishmael", color: RGB(0, 1, 0))]
        try await eventually { try await !self.covered(reader, "leaf-hl-00ff00").isEmpty }

        #expect(try await covered(reader, yellow) == [])
        #expect(try await covered(reader, "leaf-hl-00ff00") == ["Ishmael"])
    }

    /// Clicks the element `selector` of chapter 0 at `dx` points right of and 2 below its top-left corner.
    private func click(_ reader: ReaderEPUBView, _ selector: String, dx: Int = 2) async throws {
        _ = try await reader.evaluate(
            """
            (() => { const e = frame(0).querySelector('\(selector)'), r = e.getBoundingClientRect(); \
            e.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: r.left + \(dx), clientY: r.top + 2 })); })()
            """)
    }

    @Test func clickingAHighlightReportsTheNewestOneThereWithItsPoint() async throws {
        var tapped: [(String, CGPoint)] = []
        var taps = 0
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>Plain text, <b id=\"b\">marked words</b>, plain text.</p>"]),
            highlights: [
                highlight("old", from: (0, 12), to: (0, 24), quoting: "marked words"),
                highlight("new", from: (0, 14), to: (0, 20), quoting: "rked w"),
            ],
            onSingleTap: { taps += 1 }, onHighlightTap: { tapped.append(($0.id, $1)) })

        // Left of the newer one: only the older covers it.
        try await click(reader, "b")
        try await eventually { tapped.count == 1 }
        #expect(tapped.map(\.0) == ["old"])
        // Where both do, the newer one is reported.
        try await click(reader, "b", dx: 30)
        try await eventually { tapped.count == 2 }
        #expect(tapped.map(\.0) == ["old", "new"])
        // Plain text is a tap on the page, not on a Highlight.
        try await click(reader, "p")
        try await Task.sleep(for: .milliseconds(200))
        #expect(tapped.count == 2)
        #expect(taps == 1)
        let box = try await reader.highlightBox(yellow)
        #expect(abs(tapped[0].1.x - (box.minX + 2)) < 3)
    }

    @Test func aClickWhileTextIsSelectedIsNotATapOnAHighlight() async throws {
        var tapped: [String] = []
        let reader = try await openReader(
            book: importedBook(chapters: ["<p id=\"p\">Some <b id=\"b\">marked</b> text</p>"]),
            highlights: [highlight("a", from: (0, 5), to: (0, 11), quoting: "marked")],
            onHighlightTap: { highlight, _ in tapped.append(highlight.id) })
        try await select(
            in: reader, from: "frame(0).getElementById('p').firstChild", 0,
            to: "frame(0).getElementById('b').firstChild", 3)

        try await click(reader, "b")
        try await Task.sleep(for: .milliseconds(200))

        #expect(tapped.isEmpty)
    }

    @Test func aHighlightWithANoteHasAnIconAtItsEndOfTheSameSizeAtAnyTextSize() async throws {
        let green = RGB(0, 1, 0)
        var tapped: [(String, CGPoint)] = []
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>Call me Ishmael. Some years ago</p>"]), onScreen: true,
            highlights: [
                highlight("a", from: (0, 8), to: (0, 15), quoting: "Ishmael", color: green, note: "whale"),
                highlight("b", from: (0, 17), to: (0, 21), quoting: "Some"),
            ],
            onHighlightTap: { tapped.append(($0.id, $1)) })

        // Only the Highlight with a Note has one, at the right end of its last line.
        var icons = try await reader.noteIcons()
        #expect(icons.map { $0.id } == ["a"])
        #expect(icons[0].box.size == CGSize(width: 18, height: 18))
        #expect(icons[0].color == "rgb(0, 255, 0)")
        let end = try await reader.highlightBox("leaf-hl-00ff00")
        #expect(abs(icons[0].box.midX - end.maxX) < 2)

        reader.textSize = TextSize.zoomedIn(from: reader.textSize)
        try await reader.settle()

        icons = try await reader.noteIcons()
        #expect(icons[0].box.size == CGSize(width: 18, height: 18))
        let moved = try await reader.highlightBox("leaf-hl-00ff00")
        #expect(abs(icons[0].box.midX - moved.maxX) < 2)
        #expect(moved.maxX > end.maxX)

        // Clicking the icon opens the Highlight's popover at it.
        _ = try await reader.evaluate("document.querySelector('.leaf-note').click()")
        try await eventually { !tapped.isEmpty }
        #expect(tapped.map(\.0) == ["a"])
        #expect(abs(tapped[0].1.x - icons[0].box.midX) < 2)
    }

    @Test func noteIconsKeepTheirColorsInDarkPages() async throws {
        let reader = try await openReader(
            book: importedBook(chapters: ["<p>Call me Ishmael.</p>"]), appearance: .dark(night),
            highlights: [highlight("a", from: (0, 8), to: (0, 15), quoting: "Ishmael", note: "whale")])

        #expect(try await reader.noteIcons().map { $0.color } == ["rgb(255, 235, 60)"])
    }

    // MARK: Page Notes

    private func pageNote(_ id: String, at offset: Int, in spine: Int = 0) -> PageNote {
        PageNote(id: id, place: .epub(spineIndex: spine, offset: offset), text: "x")
    }

    /// Chapter 0: a short line, several wrapped lines, then the line `t`.
    private func bookWithATargetLine() async throws -> EpubBook {
        let filler = String(repeating: "filler words that wrap onto several lines ", count: 30)
        return try await importedBook(chapters: [
            "<p id=\"c\">Call me Ishmael.</p><p>\(filler)</p><p id=\"t\">Target line.</p>"
        ])
    }

    @Test func aPageNoteHasItsIconInTheMarginAtTheLineOfItsSpot() async throws {
        let book = try await bookWithATargetLine()
        let reader = try await openReader(book: book, onScreen: true)

        reader.pageNotes = [pageNote("n", at: try offset(of: "Target", in: 0, of: book) + 3)]
        try await eventually { try await !reader.noteIcons().isEmpty }

        let icons = try await reader.noteIcons()
        #expect(icons.map { $0.id } == ["n"])
        #expect(icons[0].box.size == CGSize(width: 18, height: 18))
        #expect(icons[0].box.minX >= 0 && icons[0].box.maxX <= 24)
        // The default color of page Note icons.
        #expect(icons[0].color == "rgb(255, 235, 61)")
        let line = try await reader.elementBox("t")
        #expect(abs(icons[0].box.midY - line.midY) < 2)
    }

    @Test func aPageNotesIconFollowsItsLineWhenTheTextReflowsAndKeepsItsSize() async throws {
        let book = try await bookWithATargetLine()
        let reader = try await openReader(book: book, onScreen: true)
        reader.pageNotes = [pageNote("n", at: try offset(of: "Target", in: 0, of: book))]
        try await eventually { try await !reader.noteIcons().isEmpty }
        let before = try await reader.noteIcons()[0].box

        reader.textSize = TextSize.zoomedIn(from: reader.textSize)
        try await reader.settle()

        let icon = try await reader.noteIcons()[0].box
        let line = try await reader.elementBox("t")
        #expect(icon.size == CGSize(width: 18, height: 18))
        #expect(icon.midY > before.midY)
        #expect(abs(icon.midY - line.midY) < 2)
    }

    @Test func pageNoteIconsKeepTheirColorInDarkPagesAndFollowTheColorGiven() async throws {
        let reader = try await openReader(
            book: bookWithATargetLine(), appearance: .dark(night), onScreen: true)

        reader.pageNoteColor = RGB(0, 1, 0)
        reader.pageNotes = [pageNote("n", at: 0)]
        try await eventually { try await !reader.noteIcons().isEmpty }

        #expect(try await reader.noteIcons().map { $0.color } == ["rgb(0, 255, 0)"])
    }

    @Test func clickingAPageNotesIconReportsItWithItsPoint() async throws {
        var tapped: [(String, CGPoint)] = []
        var taps = 0
        let reader = try await openReader(
            book: bookWithATargetLine(), onScreen: true, onSingleTap: { taps += 1 },
            onPageNoteTap: { tapped.append(($0.id, $1)) })
        reader.pageNotes = [pageNote("n", at: 0)]
        try await eventually { try await !reader.noteIcons().isEmpty }

        _ = try await reader.evaluate("document.querySelector('.leaf-note').click()")
        try await eventually { !tapped.isEmpty }

        let icon = try await reader.noteIcons()[0].box
        #expect(tapped.map(\.0) == ["n"])
        #expect(abs(tapped[0].1.x - icon.midX) < 2 && abs(tapped[0].1.y - icon.midY) < 2)
        #expect(taps == 0)
    }

    @Test func thePopoverOfAPageNoteIsAttachedToItsIcon() async throws {
        let book = try await bookWithATargetLine()
        let reader = try await openReader(book: book, onScreen: true)
        let note = pageNote("n", at: try offset(of: "Target", in: 0, of: book))

        // Before the note is shown, as when it was just added.
        let point = try #require(await reader.popoverPoint(of: note))

        reader.pageNotes = [note]
        try await eventually { try await !reader.noteIcons().isEmpty }
        let icon = try await reader.noteIcons()[0].box
        #expect(abs(point.x - icon.midX) < 1 && abs(point.y - icon.midY) < 1)
    }

    @Test func addNoteAtAnEmptySpotReportsTheSpotInTheText() async throws {
        var reported: [Place] = []
        let reader = try await openReader(
            book: bookWithATargetLine(), onScreen: true, onAddNote: { reported.append($0) })
        let line = try await reader.elementBox("c")

        // To the right of the line's text, and in the margin beside it.
        reader.addNote(at: CGPoint(x: line.maxX - 5, y: line.midY))
        try await eventually { reported.count == 1 }
        reader.addNote(at: CGPoint(x: 5, y: line.midY))
        try await eventually { reported.count == 2 }

        #expect(reported == [.epub(spineIndex: 0, offset: 16), .epub(spineIndex: 0, offset: 0)])
    }

    @Test func addNoteOnTextOrAHighlightOrOffTheBookReportsNothing() async throws {
        var reported: [Place] = []
        let reader = try await openReader(
            book: importedBook(chapters: ["<p id=\"c\">Call me Ishmael.</p>"]), onScreen: true,
            highlights: [highlight("a", from: (0, 8), to: (0, 15), quoting: "Ishmael")],
            onAddNote: { reported.append($0) })
        let line = try await reader.elementBox("c")

        reader.addNote(at: CGPoint(x: line.minX + 4, y: line.midY))
        reader.addNote(at: CGPoint(x: line.minX + 60, y: line.midY))
        reader.addNote(at: CGPoint(x: line.minX + 4, y: 5000))
        try await Task.sleep(for: .milliseconds(300))

        #expect(reported.isEmpty)
    }

    @Test func onlyAnEPUBOpensAsABook() async throws {
        let library = try makeLibrary()
        guard case .opened(let pdf) = await library.import(try writePDF(named: "a.pdf", pageCount: 1))
        else { throw ImportFailed() }

        #expect(await library.epub(of: pdf) == nil)
    }
}

// MARK: Long books: Chapters load near the viewport

/// Books of many tall Chapters, most of them outside what the Reader keeps loaded.
extension ReaderEPUBViewTests {
    /// `count` Chapters of twelve numbered paragraphs each, about 3000 points tall; the paragraphs are
    /// "C<chapter> Paragraph <n> ...". `extra` adds markup after a Chapter's paragraphs.
    private func longChapters(_ count: Int = 12, extra: [Int: String] = [:]) -> [String] {
        (0..<count).map { paragraphs(12, prefix: "C\($0) ") + (extra[$0] ?? "") }
    }

    private func longBook(_ count: Int = 12, extra: [Int: String] = [:]) async throws -> EpubBook {
        try await importedBook(chapters: longChapters(count, extra: extra))
    }

    /// Where paragraph `number` of Chapter `chapter` starts.
    private func paragraph(_ number: Int, of chapter: Int, in book: EpubBook) throws -> Place {
        .epub(spineIndex: chapter, offset: try offset(of: "C\(chapter) Paragraph \(number) ", in: chapter, of: book))
    }

    /// The distance from the top of the viewport to the top of paragraph `number` of Chapter `chapter`;
    /// nil while the Chapter isn't loaded.
    private func distance(_ reader: ReaderEPUBView, toParagraph number: Int, of chapter: Int) async throws -> Double? {
        Double(
            try await reader.evaluate(
                """
                (() => { const f = document.querySelectorAll('iframe')[\(chapter)], \
                p = f.contentDocument.querySelectorAll('p')[\(number)]; \
                return p ? f.getBoundingClientRect().top + p.getBoundingClientRect().top : 'none'; })()
                """))
    }

    /// Waits until paragraph `number` of Chapter `chapter` is at the top of the viewport, within `tolerance`.
    private func expectParagraphAtTop(
        _ reader: ReaderEPUBView, _ number: Int, of chapter: Int, tolerance: Double = 2
    ) async throws {
        try await eventually {
            guard let distance = try await self.distance(reader, toParagraph: number, of: chapter) else { return false }
            return abs(distance) < tolerance
        }
        let found = try #require(try await distance(reader, toParagraph: number, of: chapter))
        #expect(abs(found) < tolerance, "Paragraph \(number) of Chapter \(chapter) is \(found) pt from the top")
    }

    @Test func aLongBookOpensDeepAtItsPlaceAndKeepsItsFullHeight() async throws {
        let book = try await longBook()
        let place = try paragraph(6, of: 9, in: book)

        let reader = try await openReader(book: book, state: ReaderViewState(place: place), onScreen: true)

        try await expectParagraphAtTop(reader, 6, of: 9)
        #expect(reader.topOfViewport == place)
        #expect(reader.viewState?.place == place)
        // The column has the height of the whole book, not of what is loaded: 12 Chapters of about 3000.
        let height = try await reader.scrollHeight()
        #expect(height > 12 * 1500 && height < 12 * 6000, "\(height)")
    }

    @Test func theChapterOfThePlaceGrowingAboveItAfterOpeningKeepsThePlace() async throws {
        let book = try await longBook()
        let place = try paragraph(6, of: 9, in: book)
        let reader = try await openReader(book: book, state: ReaderViewState(place: place), onScreen: true)
        try await expectParagraphAtTop(reader, 6, of: 9)

        // As when its images or fonts arrive late.
        _ = try await reader.evaluate(
            "frame(9).body.prepend(Object.assign(frame(9).createElement('div'), { style: 'height: 1500px' }))")
        try await expectParagraphAtTop(reader, 6, of: 9)
        #expect(reader.topOfViewport == place)
    }

    @Test func aPinnedPlaceGoesBackWhenThePageIsScrolledBackRightAfterItMoved() async throws {
        let book = try await longBook()
        let place = try paragraph(6, of: 9, in: book)
        let reader = try await openReader(book: book, state: ReaderViewState(place: place), onScreen: true)
        try await expectParagraphAtTop(reader, 6, of: 9)

        // The page moves to keep the place as the Chapter grows (resize observers run before the next
        // frame); then, as iOS does for a moment, it is scrolled back to where its own scroll view was.
        _ = try await reader.evaluate(
            """
            (() => { const before = window.scrollY; \
            frame(9).body.prepend(Object.assign(frame(9).createElement('div'), { style: 'height: 1500px' })); \
            requestAnimationFrame(() => requestAnimationFrame(() => window.scrollTo(0, before))); })()
            """)

        try await expectParagraphAtTop(reader, 6, of: 9)
        #expect(reader.topOfViewport == place)
    }

    @Test func aScrollTheReaderDidntMakeAfterOpeningIsNotTheirPlace() async throws {
        let book = try await longBook()
        let place = try paragraph(6, of: 9, in: book)
        let reader = try await openReader(book: book, state: ReaderViewState(place: place), onScreen: true)

        // iOS can scroll the page back for a moment to where its own scroll view was.
        _ = try await reader.evaluate("window.scrollTo(0, 0)")
        try await Task.sleep(for: .milliseconds(300))

        #expect(reader.topOfViewport == place)
    }

    @Test func resizingKeepsThePlace() async throws {
        let book = try await longBook()
        let place = try paragraph(6, of: 9, in: book)
        let reader = try await openReader(
            book: book, state: ReaderViewState(place: place), size: CGSize(width: 400, height: 800), onScreen: true)
        try await expectParagraphAtTop(reader, 6, of: 9)

        let size = CGSize(width: 800, height: 400)
        #if os(iOS)
            reader.window?.frame.size = size
            reader.frame.size = size
        #else
            reader.window?.setContentSize(size)
        #endif

        try await expectParagraphAtTop(reader, 6, of: 9, tolerance: 30)
    }

    @Test func scrollingReachesTheEndOfALongBook() async throws {
        let reader = try await openReader(book: longBook(), onScreen: true)

        // The end moves while Chapters on the way are measured, so scroll until it holds still.
        try await eventually {
            try await reader.scrollAsReader("window.scrollTo(0, document.documentElement.scrollHeight)")
            try await Task.sleep(for: .milliseconds(100))
            guard case .epub(11, _)? = reader.topOfViewport else { return false }
            return try await reader.evaluate("document.documentElement.scrollHeight - scrollY - innerHeight") == "0"
        }

        guard case .epub(11, let offset)? = reader.topOfViewport else { throw ImportFailed() }
        #expect(offset > 0)
        #expect(try await reader.chapterText(11).contains("C11 Paragraph 11 "))
        let height = try await reader.scrollHeight()
        #expect(height > 12 * 1500 && height < 12 * 6000, "\(height)")
    }

    @Test func aJumpAcrossFarChaptersLandsOnItsLineAndBackReturnsEvenAfterItWasReleased() async throws {
        let book = try await longBook()
        let reader = try await openReader(book: book, onScreen: true)
        let start = try #require(reader.topOfViewport)
        let far = try paragraph(6, of: 10, in: book)
        let other = try paragraph(3, of: 2, in: book)

        reader.jump(to: far)
        try await expectParagraphAtTop(reader, 6, of: 10)
        #expect(reader.topOfViewport == far)
        #expect(reader.backPlace == start)

        // Another far Jump releases Chapter 10 meanwhile; Back still lands on its line.
        reader.jump(to: other)
        try await expectParagraphAtTop(reader, 3, of: 2)
        #expect(reader.backPlace == far)
        reader.back()
        try await expectParagraphAtTop(reader, 6, of: 10)
        #expect(reader.topOfViewport == far)
        #expect(reader.backPlace == nil)
    }

    @Test func aLinkToAFarChapterLandsOnItsAnchor() async throws {
        var chapters = longChapters(extra: [9: "<p id=\"deep\">Deep target</p>" + paragraphs(3)])
        chapters[0] = #"<p><a id="go" href="chapter9.xhtml#deep">Deep</a></p>"# + chapters[0]
        let book = try await importedBook(chapters: chapters)
        let reader = try await openReader(book: book, onScreen: true, openExternally: { _ in })
        let start = try #require(reader.topOfViewport)

        _ = try await reader.evaluate("frame(0).getElementById('go').click()")

        let target = Place.epub(spineIndex: 9, offset: try offset(of: "Deep target", in: 9, of: book))
        try await eventually { reader.topOfViewport == target }
        #expect(reader.topOfViewport == target)
        let top = try await reader.evaluate(
            "document.querySelectorAll('iframe')[9].getBoundingClientRect().top + frame(9).getElementById('deep').getBoundingClientRect().top"
        )
        #expect(abs(try #require(Double(top))) < 2)
        #expect(reader.backPlace == start)
    }

    @Test func theTextSizeKeepsThePlaceInALongBookAndChaptersLoadedLaterUseIt() async throws {
        let book = try await longBook()
        let place = try paragraph(6, of: 9, in: book)
        let reader = try await openReader(book: book, state: ReaderViewState(place: place), onScreen: true)
        try await expectParagraphAtTop(reader, 6, of: 9)
        let height = try await reader.scrollHeight()

        for size in [2, 0.75, 1] as [CGFloat] {
            reader.textSize = size
            try await reader.settle()
            #expect(reader.topOfViewport == place, "at size \(size)")
            try await expectParagraphAtTop(reader, 6, of: 9, tolerance: 4)
        }
        reader.textSize = 2
        try await reader.settle()
        // Unloaded Chapters are taller too, so the whole column grows.
        #expect(try await reader.scrollHeight() > height * 1.5)

        reader.jump(to: try paragraph(2, of: 2, in: book))
        try await expectParagraphAtTop(reader, 2, of: 2, tolerance: 4)
        #expect(try await reader.evaluate("getComputedStyle(frame(2).body).zoom") == "2")
    }

    @Test func thePageStyleKeepsThePlaceInALongBookAndChaptersLoadedLaterUseIt() async throws {
        let book = try await longBook()
        let place = try paragraph(6, of: 9, in: book)
        let reader = try await openReader(book: book, state: ReaderViewState(place: place), onScreen: true)
        try await expectParagraphAtTop(reader, 6, of: 9)
        try await reader.settle()  // the Chapters around load and are measured
        let height = try await reader.scrollHeight()

        reader.pageAppearance = .dark(night)
        try await reader.settle()

        #expect(reader.topOfViewport == place)
        #expect(try await reader.scrollHeight() == height)
        reader.jump(to: try paragraph(2, of: 2, in: book))
        try await expectParagraphAtTop(reader, 2, of: 2)
        let color = "getComputedStyle(frame(2).querySelectorAll('p')[2]).color"
        #expect(try await reader.evaluate(color) == "rgb(224, 208, 160)")
    }

    @Test func highlightsAndPageNotesAppearInChaptersOnceTheyLoad() async throws {
        let book = try await longBook()
        let reader = try await openReader(book: book, onScreen: true)
        let words = "C8 Paragraph 3"
        let start = try offset(of: words, in: 8, of: book)
        reader.highlights = [
            highlight("h", from: (8, start), to: (8, start + words.count), quoting: words, note: "why")
        ]
        reader.pageNotes = [pageNote("n", at: try offset(of: "C8 Paragraph 5 ", in: 8, of: book), in: 8)]
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await reader.noteIcons().isEmpty)

        reader.jump(to: try paragraph(3, of: 8, in: book))

        try await eventually { try await self.covered(reader, self.yellow, in: 8) == [words] }
        #expect(try await covered(reader, yellow, in: 8) == [words])
        try await eventually { try await reader.noteIcons().map(\.id).sorted() == ["h", "n"] }
        let icons = try await reader.noteIcons().map(\.id).sorted()
        #expect(icons == ["h", "n"], "\(icons) \(String(describing: reader.topOfViewport))")
    }

    @Test func aSearchMatchInAnUnloadedChapterIsRevealedAndMarked() async throws {
        let book = try await longBook(extra: [8: "<p>The needle is here</p>", 10: "<p>Another needle</p>"])
        let reader = try await openReader(book: book, onScreen: true)
        let start = try #require(reader.topOfViewport)
        reader.beginSearchSession()
        reader.matches.search(.init("needle"))
        try await eventually { reader.results.matches.count == 2 }

        reader.results.onChoose(0)

        try await eventually { reader.topOfViewport?.isSameSpot(as: start) == false }
        try await eventually { try await reader.marks("leaf-find-current")[8] == 1 }
        #expect(try await reader.marks("leaf-find-current")[8] == 1)
        guard case .epub(8, _)? = reader.topOfViewport else { throw ImportFailed() }
        // The match is on screen, and the reveal is one Jump.
        let top = try await reader.evaluate(
            "(() => { const f = document.querySelectorAll('iframe')[8]; return f.getBoundingClientRect().top + [...f.contentDocument.querySelectorAll('p')].find(p => p.textContent.includes('needle')).getBoundingClientRect().top; })()"
        )
        #expect((0..<800).contains(try #require(Double(top))))
        try await eventually { reader.backPlace != nil }
        #expect(reader.backPlace == start)

        // The other match is marked once its Chapter loads.
        reader.jump(to: .epub(spineIndex: 10, offset: 0))
        try await eventually { try await reader.marks("leaf-find")[10] == 1 }
        #expect(try await reader.marks("leaf-find")[10] == 1)
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
        credentials: CloudCredentials(defaults: defaults, service: "leaf-test-\(root.lastPathComponent)"),
        syncIntervals: .standard, inbox: nil)
}

/// An EPUB of `chapters`, imported.
@MainActor
func importedBook(
    chapters: [String], manifest: String = "", files: [String: Data] = [:], doctype: String = ""
) async throws -> EpubBook {
    let library = try makeLibrary()
    let source = try writeEPUB(
        named: "book.epub", chapters: chapters, manifest: manifest, files: files, doctype: doctype)
    guard case .opened(let document) = await library.import(source), let book = await library.epub(of: document)
    else { throw ImportFailed() }
    return book
}

/// A Reader on an imported EPUB of `chapters`, once it has opened.
@MainActor
private func openReader(
    chapters: [String], manifest: String = "", files: [String: Data] = [:],
    size: CGSize = CGSize(width: 400, height: 800), onSingleTap: @escaping () -> Void = {},
    onHighlight: @escaping (Anchor, String) -> Void = { _, _ in }, openExternally: @escaping (URL) -> Void = { _ in }
) async throws -> ReaderEPUBView {
    try await openReader(
        book: importedBook(chapters: chapters, manifest: manifest, files: files), size: size,
        onSingleTap: onSingleTap, onHighlight: onHighlight, openExternally: openExternally)
}

/// A Reader on `book`, once it has opened.
@MainActor
private func openReader(
    book: EpubBook, state: ReaderViewState? = nil, size: CGSize = CGSize(width: 400, height: 800),
    textSize: CGFloat = TextSize.normal, appearance: PageAppearance = .light, onScreen: Bool = false,
    contents: TableOfContents = TableOfContents(), highlights: [Highlight] = [],
    onSingleTap: @escaping () -> Void = {}, onScroll: @escaping () -> Void = {},
    onHighlight: @escaping (Anchor, String) -> Void = { _, _ in },
    onHighlightTap: @escaping (Highlight, CGPoint) -> Void = { _, _ in },
    onAddNote: @escaping (Place) -> Void = { _ in },
    onPageNoteTap: @escaping (PageNote, CGPoint) -> Void = { _, _ in },
    onTextSizeChange: @escaping (CGFloat) -> Void = { _ in },
    onBackChange: @escaping (BackTarget?) -> Void = { _ in }, openExternally: @escaping (URL) -> Void = { _ in }
) async throws -> ReaderEPUBView {
    var reader: ReaderEPUBView?
    await withCheckedContinuation { opened in
        var once: CheckedContinuation<Void, Never>? = opened
        reader = ReaderEPUBView(
            book: book, state: state, contents: contents, textSize: textSize, appearance: appearance,
            highlights: highlights, handle: ReaderHandle(),
            callbacks: ReaderCallbacks(
                onSingleTap: onSingleTap,
                onOpen: {
                    once?.resume()
                    once = nil
                },
                onScroll: onScroll, onHighlight: onHighlight, onHighlightTap: onHighlightTap,
                onAddNote: onAddNote, onPageNoteTap: onPageNoteTap, onTextSizeChange: onTextSizeChange,
                onBackChange: onBackChange))
        reader?.openExternally = openExternally
        reader?.frame = CGRect(origin: .zero, size: size)
        if onScreen, let reader { show(reader) }
    }
    let opened = try #require(reader)
    // Highlights are drawn right after opening; those found nowhere never are.
    if !highlights.isEmpty {
        for _ in 0..<20 {
            if try await opened.hasHighlightDrawn() { break }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    return opened
}

/// The windows showing the views under test, which a view only holds weakly. A web view
/// only reports scrolling while it is on screen.
@MainActor private var openWindows: [AnyObject] = []

@MainActor
private func show(_ reader: ReaderEPUBView) {
    #if os(iOS)
        // In the app's scene, which the find bar needs to show.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = reader.frame
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

    /// Runs `script` as the reader's scrolling: their input comes first, as a wheel event.
    fileprivate func scrollAsReader(_ script: String) async throws {
        _ = try await evaluate("(window.dispatchEvent(new WheelEvent('wheel')), \(script))")
    }

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

    /// How many matches the highlight `name` marks in each chapter.
    fileprivate func marks(_ name: String) async throws -> [Int] {
        try await evaluateClient(
            "[...document.querySelectorAll('iframe')].map(f => f.contentWindow.CSS.highlights.get('\(name)')?.size ?? 0)"
        ).split(separator: ",").compactMap { Int($0) }
    }

    /// Whether the page has drawn a Highlight, of any color, in any chapter.
    fileprivate func hasHighlightDrawn() async throws -> Bool {
        try await evaluateClient(
            """
            [...document.querySelectorAll('iframe')].some(f => \
            [...f.contentWindow.CSS.highlights.keys()].some(name => name.startsWith('leaf-hl-')))
            """) == "true"
    }

    /// The bounding box, in the page's coordinates, of what the Highlight `name` covers in chapter 0.
    fileprivate func highlightBox(_ name: String) async throws -> CGRect {
        let box = try await evaluateClient(
            """
            (() => { const f = document.querySelector('iframe'), r = [...f.contentWindow.CSS.highlights.get('\(name)')][0]\
            .getBoundingClientRect(), o = f.getBoundingClientRect(); \
            return [r.left + o.left, r.top + o.top, r.width, r.height].join(','); })()
            """
        ).split(separator: ",").compactMap { Double($0) }
        return CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
    }

    /// The box, in the page's coordinates, of the element `id` of chapter 0.
    fileprivate func elementBox(_ id: String) async throws -> CGRect {
        let box = try await evaluate(
            """
            (() => { const f = document.querySelector('iframe').getBoundingClientRect(), \
            r = frame(0).getElementById('\(id)').getBoundingClientRect(); \
            return [r.left + f.left, r.top + f.top, r.width, r.height].join(','); })()
            """
        ).split(separator: ",").compactMap { Double($0) }
        return CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
    }

    /// The Note icons in the page: Highlight or page Note ID, box and color.
    fileprivate func noteIcons() async throws -> [(id: String, box: CGRect, color: String)] {
        let icons = try await evaluate(
            """
            [...document.querySelectorAll('.leaf-note')].map(e => { const r = e.getBoundingClientRect(); \
            return [e.dataset.id, r.left, r.top, r.width, r.height, e.style.backgroundColor].join('|'); \
            }).join('~')
            """)
        return icons.split(separator: "~").map { icon in
            let parts = icon.split(separator: "|").map(String.init)
            let n = parts[1...4].compactMap { Double($0) }
            return (parts[0], CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), parts[5])
        }
    }

    /// Waits for the page to reflow after a size change.
    fileprivate func settle() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }
}
