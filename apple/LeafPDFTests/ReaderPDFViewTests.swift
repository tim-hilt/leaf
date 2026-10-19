import PDFKit
import Testing

@testable import LeafPDF

@MainActor @Suite struct ReaderPDFViewTests {
    let portrait = CGSize(width: 400, height: 800)
    let landscape = CGSize(width: 800, height: 400)
    let place = Place(pageIndex: 5, point: CGPoint(x: 0, y: 400))

    @Test func goesToAPlace() throws {
        let reader = try makeReader(size: portrait)
        reader.go(to: place)
        try expectAtTop(place, of: reader)
    }

    @Test func opensAtASavedPlaceAtFitToWidth() throws {
        let reader = try makeReader(size: portrait, openingAt: place)
        try expectAtTop(place, of: reader)
        #expect(reader.scaleFactor == reader.scaleFactorForSizeToFit)
    }

    @Test func keepsThePlaceWhenResizedAtFitToWidth() throws {
        let reader = try makeReader(size: portrait)
        reader.go(to: place)
        resize(reader, to: landscape)
        try expectAtTop(place, of: reader)
        #expect(reader.scaleFactor == reader.scaleFactorForSizeToFit)
    }

    @Test func keepsThePlaceAndRelativeZoomWhenResizedZoomedIn() throws {
        let reader = try makeReader(size: portrait)
        reader.zoomIn()
        reader.go(to: place)
        let multiple = reader.scaleFactor / reader.scaleFactorForSizeToFit
        resize(reader, to: landscape)
        try expectAtTop(place, of: reader)
        #expect(abs(reader.scaleFactor / reader.scaleFactorForSizeToFit - multiple) < 0.001)
    }

    @Test func keyboardZoomKeepsThePlace() throws {
        let reader = try makeReader(size: portrait)
        reader.go(to: place)
        reader.zoomIn()
        try expectAtTop(place, of: reader)
        reader.zoomToFitWidth()
        try expectAtTop(place, of: reader)
    }

    // MARK: Jump and Back

    let target = Place(pageIndex: 2, point: CGPoint(x: 0, y: 300))

    @Test func jumpGoesToTheTargetAndBackReturnsToTheExactPlace() throws {
        let reader = try makeReader(size: portrait)
        reader.go(to: place)
        let start = try #require(reader.topOfViewport)
        reader.jump(to: target)
        try expectAtTop(target, of: reader)
        #expect(reader.backPlace == start)
        reader.goBack()
        try expectAtTop(start, of: reader)
    }

    @Test func backKeepsTheCurrentZoom() throws {
        let reader = try makeReader(size: portrait)
        reader.go(to: place)
        reader.jump(to: target)
        reader.zoomIn()
        let zoom = reader.scaleFactor
        reader.goBack()
        #expect(reader.scaleFactor == zoom)
    }

    @Test func aSecondJumpReplacesTheBackPlace() throws {
        let reader = try makeReader(size: portrait)
        reader.go(to: place)
        reader.jump(to: target)
        let second = try #require(reader.topOfViewport)
        reader.jump(to: Place(pageIndex: 7, point: CGPoint(x: 0, y: 200)))
        #expect(reader.backPlace == second)
    }

    @Test func aJumpToTheCurrentPlaceRecordsNothing() throws {
        let reader = try makeReader(size: portrait)
        reader.go(to: place)
        reader.jump(to: try #require(reader.topOfViewport))
        #expect(reader.backPlace == nil)
        reader.jump(to: place)
        #expect(reader.backPlace == nil)
    }

    @Test func thereIsNoBackPlaceAfterBack() throws {
        let reader = try makeReader(size: portrait)
        reader.jump(to: target)
        reader.goBack()
        #expect(reader.backPlace == nil)
        let top = try #require(reader.topOfViewport)
        reader.goBack()
        try expectAtTop(top, of: reader)
    }

    @Test func reportsTheBackPlaceAsItComesAndGoes() throws {
        let reader = try makeReader(size: portrait)
        var reported: [String?] = []
        reader.onBackChange = { reported.append($0) }
        reader.jump(to: target)
        reader.goBack()
        #expect(reported == ["1", nil])
    }

    @Test func jumpsAndBackReportScrolling() throws {
        let reader = try makeReader(size: portrait)
        var scrolls = 0
        reader.onScroll = { scrolls += 1 }
        reader.jump(to: target)
        #expect(scrolls > 0)
        scrolls = 0
        reader.goBack()
        #expect(scrolls > 0)
    }

    // MARK: Revealing a search match

    @Test func revealingAnOffScreenMatchBringsItIntoView() throws {
        let (reader, match) = try makeReaderWithMatch()
        reader.go(to: Place(pageIndex: 0, point: CGPoint(x: 0, y: 792)))
        reader.reveal(match)
        try expectVisible(match, in: reader)
    }

    @Test func revealingAMatchAlreadyInViewDoesNotScroll() throws {
        let (reader, match) = try makeReaderWithMatch()
        reader.reveal(match)
        let top = try #require(reader.topOfViewport)
        reader.reveal(match)
        try expectAtTop(top, of: reader)
    }

    // MARK: Search session

    @Test func aSearchSessionRecordsASingleBackPlaceWhereItStarted() throws {
        let (reader, matches) = try makeReaderWithMatches()
        reader.go(to: Place(pageIndex: 3, point: CGPoint(x: 0, y: 400)))
        let start = try #require(reader.topOfViewport)
        reader.beginSearchSession()
        reader.reveal(matches[0])
        #expect(reader.backPlace == start)
        reader.reveal(matches[1])
        reader.reveal(matches[0])
        #expect(reader.backPlace == start)
        reader.endSearchSession()
        #expect(reader.backPlace == start)
        reader.goBack()
        try expectAtTop(start, of: reader)
    }

    @Test func aSearchMoveAfterBackRecordsWhereTheSearchStartedAgain() throws {
        let (reader, matches) = try makeReaderWithMatches()
        reader.go(to: Place(pageIndex: 3, point: CGPoint(x: 0, y: 400)))
        let start = try #require(reader.topOfViewport)
        reader.beginSearchSession()
        reader.reveal(matches[0])
        reader.goBack()
        reader.reveal(matches[1])
        #expect(reader.backPlace == start)
    }

    @Test func aSearchMoveThatLeavesTheViewWhereItIsRecordsNothing() throws {
        let (reader, matches) = try makeReaderWithMatches()
        reader.reveal(matches[0])
        reader.beginSearchSession()
        reader.reveal(matches[0])
        #expect(reader.backPlace == nil)
    }

    @Test func aNewSearchSessionReplacesTheBackPlace() throws {
        let (reader, matches) = try makeReaderWithMatches()
        reader.beginSearchSession()
        reader.reveal(matches[0])
        reader.endSearchSession()
        let second = try #require(reader.topOfViewport)
        reader.beginSearchSession()
        reader.reveal(matches[1])
        #expect(reader.backPlace == second)
    }

    @Test func revealingOutsideASearchSessionRecordsNothing() throws {
        let (reader, matches) = try makeReaderWithMatches()
        reader.reveal(matches[0])
        #expect(reader.backPlace == nil)
    }

    #if os(iOS)
        @Test func theFindBarIsDrivenByDocumentSearch() async throws {
            let reader = try makeReader(size: portrait, pageTexts: ["apple", "", "an apple, apple"], inScene: true)
            reader.presentFind()
            let interaction = reader.find.interaction
            #expect(interaction.isFindNavigatorVisible)

            // As the bar does when the reader types (and "next" when they press it).
            let session = try #require(interaction.activeFindSession)
            session.performSearch(query: "app", options: nil)
            for _ in 0..<40 where session.resultCount != 3 { try await Task.sleep(for: .milliseconds(50)) }
            #expect(session.resultCount == 3)

            // The first match is current, and all are marked on the pages.
            for _ in 0..<40 where reader.highlightedSelections?.count != 3 { try await Task.sleep(for: .milliseconds(50)) }
            #expect(session.highlightedResultIndex == 0)
            #expect(reader.highlightedSelections?.count == 3)

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
            #expect(reader.results.current == 0)

            interaction.dismissFindNavigator()
            #expect(reader.results.matches.isEmpty)
            #expect(!reader.results.isFindBarOpen)
        }
    #endif

    #if os(macOS)
        @Test func theFindBarStepsThroughMatchesInTheDocumentText() async throws {
            let reader = try makeReader(size: portrait, pageTexts: ["x Apple", "", "an apple, apple"])
            // The bar's options are remembered on the find pasteboard.
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setPropertyList(
                [NSPasteboard.PasteboardType.TextFinderOptionKey.textFinderCaseInsensitiveKey: true],
                forType: .textFinderOptions)
            reader.presentFind()
            #expect(reader.documentView?.enclosingScrollView?.isFindBarVisible == true)

            func waitForANewMatch(after action: () -> Void) async throws {
                let before = reader.currentSelection
                action()
                // The search runs on a background queue.
                for _ in 0..<40 where reader.currentSelection == before { try await Task.sleep(for: .milliseconds(50)) }
            }
            // As the reader does when they type, and when they press ⌘G.
            let field = try #require(findBarSearchField(in: reader))
            try await waitForANewMatch {
                field.stringValue = "app"
                field.sendAction(field.action, to: field.target)
            }
            #expect(reader.currentSelection?.string == "App")
            #expect(reader.currentSelection?.pages.first == reader.document?.page(at: 0))

            try await waitForANewMatch { reader.find.next() }
            #expect(reader.currentSelection?.string == "app")
            #expect(reader.currentSelection?.pages.first == reader.document?.page(at: 2))

            // The results list follows the bar's search, and its current match.
            for _ in 0..<40 where reader.results.matches.count != 3 { try await Task.sleep(for: .milliseconds(50)) }
            #expect(reader.results.isFindBarOpen)
            #expect(reader.results.matches.map(\.pageIndex) == [0, 2, 2])
            #expect(reader.results.current == 1)

            // Choosing a match makes it current, and the bar goes on from there.
            reader.results.onChoose(2)
            #expect(reader.currentSelection?.pages.first == reader.document?.page(at: 2))
            try await Task.sleep(for: .milliseconds(300))
            #expect(reader.results.current == 2)
            reader.find.previous()
            for _ in 0..<40 where reader.results.current != 1 { try await Task.sleep(for: .milliseconds(50)) }
            #expect(reader.results.current == 1)
        }
    #endif

    // MARK: Highlights

    /// Page 1 reads "Alpha beta gamma", page 2 "Delta epsilon zeta".
    func readerWithText() throws -> ReaderPDFView {
        try makeReader(size: portrait, pageTexts: ["Alpha beta gamma", "Delta epsilon zeta"])
    }

    /// The selection from character `first` on page 1 to character `last` on page `lastPage`, indexed from 0.
    func select(_ reader: ReaderPDFView, from first: Int, to last: Int, onPage lastPage: Int = 0) throws {
        let document = try #require(reader.document)
        reader.currentSelection = document.selection(
            from: try #require(document.page(at: 0)), atCharacterIndex: first,
            to: try #require(document.page(at: lastPage)), atCharacterIndex: last)
    }

    @Test func aSelectionIsAnAnchorWithLineRectsInPageSpaceAndTheQuotedText() throws {
        let reader = try readerWithText()
        try select(reader, from: 6, to: 9)  // "beta"

        let anchor = try #require(reader.selectionAnchor)

        #expect(anchor.quotedText == "beta")
        #expect(anchor.pages.map(\.pageIndex) == [0])
        let rect = try #require(anchor.pages.first?.rects.first)
        // The first line of text, at the top of the page inside a one-inch margin, to the right of "Alpha ".
        #expect(rect.minX > 72 + 20 && rect.maxX < 72 + 100)
        #expect(rect.minY > 690 && rect.maxY < 725)
        #expect(anchor.pages.first?.rects.count == 1)
    }

    @Test func aSelectionAcrossAPageBreakIsOneAnchorWithRectsOnBothPages() throws {
        let reader = try readerWithText()
        try select(reader, from: 11, to: 4, onPage: 1)  // "gamma" … "Delta"

        let anchor = try #require(reader.selectionAnchor)

        #expect(anchor.pages.map(\.pageIndex) == [0, 1])
        #expect(anchor.pages.allSatisfy { !$0.rects.isEmpty })
        #expect(anchor.quotedText.hasPrefix("gamma"))
        #expect(anchor.quotedText.hasSuffix("Delta"))
    }

    @Test func withoutASelectionThereIsNoAnchor() throws {
        let reader = try readerWithText()
        #expect(reader.selectionAnchor == nil)
    }

    @Test func highlightingTheSelectionReportsItsAnchorAndClearsTheSelection() throws {
        let reader = try readerWithText()
        var reported: [HighlightAnchor] = []
        reader.onHighlight = { reported.append($0) }
        try select(reader, from: 6, to: 9)
        let anchor = try #require(reader.selectionAnchor)

        reader.highlightSelection()

        #expect(reported == [anchor])
        #expect(reader.currentSelection == nil)
    }

    @Test func highlightingWithoutASelectionDoesNothing() throws {
        let reader = try readerWithText()
        var reported = 0
        reader.onHighlight = { _ in reported += 1 }

        reader.highlightSelection()

        #expect(reported == 0)
    }

    // MARK: Highlight hit-testing

    /// A Highlight on page 1 over `rect` (page space).
    func marked(_ id: String, _ rect: CGRect, onPage pageIndex: Int = 0) -> Highlight {
        Highlight(
            id: id, anchor: HighlightAnchor(pages: [.init(pageIndex: pageIndex, rects: [rect])], quotedText: id),
            color: RGB.sampleYellow)
    }

    /// The centre of `rect` on page `pageIndex` + 1, in the view's coordinates.
    func centre(ofRect rect: CGRect, onPage pageIndex: Int, in reader: ReaderPDFView) -> CGPoint {
        reader.convert(CGPoint(x: rect.midX, y: rect.midY), from: reader.document!.page(at: pageIndex)!)
    }

    @Test func reportsTheHighlightAtAViewPoint() throws {
        let reader = try readerWithText()
        let rect = CGRect(x: 100, y: 690, width: 80, height: 20)
        reader.highlights = [marked("a", rect)]

        #expect(reader.highlight(at: centre(ofRect: rect, onPage: 0, in: reader))?.id == "a")
        let outside = CGRect(x: 300, y: 400, width: 10, height: 10)
        #expect(reader.highlight(at: centre(ofRect: outside, onPage: 0, in: reader)) == nil)
    }

    @Test func reportsNoHighlightOnAnotherPageThanTheirs() throws {
        let reader = try readerWithText()
        let rect = CGRect(x: 100, y: 690, width: 80, height: 20)
        reader.highlights = [marked("a", rect, onPage: 1)]

        #expect(reader.highlight(at: centre(ofRect: rect, onPage: 0, in: reader)) == nil)
        #expect(reader.highlight(at: centre(ofRect: rect, onPage: 1, in: reader))?.id == "a")
    }

    @Test func whereHighlightsOverlapTheNewestIsReported() throws {
        let reader = try readerWithText()
        let older = CGRect(x: 100, y: 690, width: 80, height: 20)
        let newer = CGRect(x: 150, y: 690, width: 80, height: 20)
        reader.highlights = [marked("older", older), marked("newer", newer)]

        #expect(reader.highlight(at: centre(ofRect: CGRect(x: 165, y: 700, width: 0, height: 0), onPage: 0, in: reader))?.id == "newer")
        #expect(reader.highlight(at: centre(ofRect: CGRect(x: 110, y: 700, width: 0, height: 0), onPage: 0, in: reader))?.id == "older")
    }

    // MARK: Note icons

    /// A Highlight over `rect` on page 1 with a Note.
    func noted(_ id: String, _ rect: CGRect) -> Highlight {
        var highlight = marked(id, rect)
        highlight.note = "a thought"
        return highlight
    }

    @Test func theNoteIconSitsAtTheEndOfTheLastRectOfItsHighlight() throws {
        let reader = try readerWithText()
        let rect = CGRect(x: 100, y: 690, width: 80, height: 20)
        reader.highlights = [noted("a", rect)]

        let icon = try #require(reader.noteIconRect(of: reader.highlights[0]))

        let end = reader.convert(CGPoint(x: rect.maxX, y: rect.midY), from: try #require(reader.document?.page(at: 0)))
        #expect(abs(icon.minX - end.x) < 0.001)
        #expect(abs(icon.midY - end.y) < 0.001)
        #expect(icon.width == icon.height && icon.width > 0)
    }

    @Test func theNoteIconIsAtTheEndOfTheLastPageOfAHighlightAcrossAPageBreak() throws {
        let reader = try readerWithText()
        let anchor = HighlightAnchor(
            pages: [
                .init(pageIndex: 0, rects: [CGRect(x: 100, y: 100, width: 80, height: 20)]),
                .init(pageIndex: 1, rects: [CGRect(x: 72, y: 690, width: 50, height: 20)]),
            ], quotedText: "a")
        let highlight = Highlight(id: "a", anchor: anchor, color: .sampleYellow, note: "a thought")
        reader.highlights = [highlight]

        let icon = try #require(reader.noteIconRect(of: highlight))

        let end = reader.convert(CGPoint(x: 122, y: 700), from: try #require(reader.document?.page(at: 1)))
        #expect(abs(icon.minX - end.x) < 0.001 && abs(icon.midY - end.y) < 0.001)
    }

    @Test func aHighlightWithoutANoteHasNoNoteIcon() throws {
        let reader = try readerWithText()
        let plain = marked("a", CGRect(x: 100, y: 690, width: 80, height: 20))
        reader.highlights = [plain]

        #expect(reader.noteIconRect(of: plain) == nil)
    }

    @Test func theNoteIconKeepsItsOnScreenSizeAtAnyZoom() throws {
        let reader = try readerWithText()
        let highlight = noted("a", CGRect(x: 100, y: 690, width: 80, height: 20))
        reader.highlights = [highlight]
        let before = try #require(reader.noteIconRect(of: highlight))

        reader.zoomIn()
        reader.zoomIn()

        #expect(reader.noteIconRect(of: highlight)?.size == before.size)
    }

    @Test func reportsTheNoteIconAtAViewPoint() throws {
        let reader = try readerWithText()
        let highlight = noted("a", CGRect(x: 100, y: 690, width: 80, height: 20))
        reader.highlights = [highlight]
        let icon = try #require(reader.noteIconRect(of: highlight))

        #expect(reader.noteIcon(at: CGPoint(x: icon.midX, y: icon.midY))?.id == "a")
        #expect(reader.noteIcon(at: CGPoint(x: icon.maxX + 40, y: icon.midY)) == nil)
    }

    @Test func clickingTheNoteIconReportsItsHighlightForThePopover() throws {
        let reader = try readerWithText()
        let highlight = noted("a", CGRect(x: 100, y: 690, width: 80, height: 20))
        reader.highlights = [highlight]
        let icon = try #require(reader.noteIconRect(of: highlight))
        var reported: [String] = []
        reader.onHighlightTap = { highlight, _ in reported.append(highlight.id) }

        #expect(reader.reportHighlightTap(at: CGPoint(x: icon.midX, y: icon.midY)))

        #expect(reported == ["a"])
    }

    // MARK: Links

    /// A link on page 6 to `target`, and one to a web page just below it.
    let linkRect = CGRect(x: 50, y: 500, width: 200, height: 50)
    let webRect = CGRect(x: 50, y: 400, width: 200, height: 50)
    var links: [LinkEntry] {
        [
            LinkEntry(pageIndex: place.pageIndex, rect: linkRect, target: .place(pageIndex: target.pageIndex, point: target.point)),
            LinkEntry(pageIndex: place.pageIndex, rect: webRect, target: .web(URL(string: "https://example.com")!)),
        ]
    }

    @Test func followingALinkInTheDocumentIsAJump() throws {
        let reader = try makeReader(size: portrait, links: links)
        reader.go(to: Place(pageIndex: place.pageIndex, point: CGPoint(x: 0, y: 700)))
        let start = try #require(reader.topOfViewport)
        reader.perform(try #require(action(of: linkRect, in: reader)))
        try expectAtTop(target, of: reader)
        #expect(reader.backPlace == start)
        reader.goBack()
        try expectAtTop(start, of: reader)
    }

    @Test func recognizesLinksAtAPointInTheView() throws {
        let reader = try makeReader(size: portrait, links: links)
        reader.go(to: Place(pageIndex: place.pageIndex, point: CGPoint(x: 0, y: 700)))
        #expect(reader.hasLink(at: viewPoint(of: linkRect, in: reader)))
        #expect(reader.hasLink(at: viewPoint(of: webRect, in: reader)))
        #expect(!reader.hasLink(at: viewPoint(of: CGRect(x: 50, y: 100, width: 10, height: 10), in: reader)))
    }
}

#if os(macOS)
    /// The search field of the Reader's find bar.
    @MainActor
    private func findBarSearchField(in reader: ReaderPDFView) -> NSSearchField? {
        func find(in view: NSView) -> NSSearchField? {
            (view as? NSSearchField) ?? view.subviews.lazy.compactMap(find(in:)).first
        }
        return reader.documentView?.enclosingScrollView?.findBarView.flatMap(find(in:))
    }
#endif

/// A Reader on a Document with "apple" on page 6, and that match.
@MainActor
private func makeReaderWithMatch() throws -> (ReaderPDFView, PDFSelection) {
    let reader = try makeReader(size: CGSize(width: 400, height: 800), pageTexts: ["", "", "", "", "", "apple"])
    let match = try #require(reader.document?.findString("apple", withOptions: []).first)
    return (reader, match)
}

/// A Reader on a Document with "apple" on pages 3 and 6, and those matches.
@MainActor
private func makeReaderWithMatches() throws -> (ReaderPDFView, [PDFSelection]) {
    let reader = try makeReader(size: CGSize(width: 400, height: 800), pageTexts: ["", "", "apple", "", "", "apple"])
    let matches = try #require(reader.document?.findString("apple", withOptions: []))
    return (reader, matches)
}

@MainActor
private func expectVisible(_ match: PDFSelection, in reader: ReaderPDFView) throws {
    let page = try #require(match.pages.first)
    let rect = reader.convert(match.bounds(for: page), from: page)
    #expect(reader.bounds.contains(rect))
}

/// The action of the link annotation on page 6 inside `rect`.
@MainActor
private func action(of rect: CGRect, in reader: ReaderPDFView) -> PDFAction? {
    reader.document?.page(at: 5)?.annotation(at: CGPoint(x: rect.midX, y: rect.midY))?.action
}

/// The centre of `rect` on page 6, in the view's coordinates.
@MainActor
private func viewPoint(of rect: CGRect, in reader: ReaderPDFView) -> CGPoint {
    reader.convert(CGPoint(x: rect.midX, y: rect.midY), from: reader.document!.page(at: 5)!)
}

#if os(iOS)
    /// Windows of the Readers under test, which a view only holds weakly.
    @MainActor private var openWindows: [UIWindow] = []
#endif

/// A Reader on an eight-page Document, laid out in a window of `size`. With
/// `openingAt`, it is asked to open there before the Document is set. On iOS,
/// `inScene` puts the window in the app's scene, as the find bar needs.
@MainActor
private func makeReader(
    size: CGSize, openingAt place: Place? = nil, links: [LinkEntry] = [], pageTexts: [String] = [],
    inScene: Bool = false
) throws -> ReaderPDFView {
    let reader = ReaderPDFView(handle: ReaderHandle())
    if let place { reader.open(at: place) }
    reader.displayMode = .singlePageContinuous
    reader.autoScales = true
    reader.frame = CGRect(origin: .zero, size: size)
    #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = inScene ? scene.map(UIWindow.init(windowScene:)) ?? UIWindow() : UIWindow()
        window.frame = reader.frame
        window.addSubview(reader)
        window.makeKeyAndVisible()
        openWindows.append(window)
    #else
        let window = NSWindow(
            contentRect: reader.frame, styleMask: [.titled, .resizable], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader
    #endif
    reader.document = try makePDF(named: "Long.pdf", pageCount: 8, links: links, pageTexts: pageTexts)
    layout(reader)
    return reader
}

@MainActor
private func resize(_ reader: ReaderPDFView, to size: CGSize) {
    reader.frame = CGRect(origin: .zero, size: size)
    layout(reader)
}

@MainActor
private func layout(_ reader: ReaderPDFView) {
    #if os(iOS)
        reader.layoutIfNeeded()
    #else
        reader.layoutSubtreeIfNeeded()
    #endif
}

/// Expects `place` at the top of the viewport, to within a point; the left edge
/// may be clamped to the page margin.
@MainActor
private func expectAtTop(_ place: Place, of reader: ReaderPDFView) throws {
    let top = try #require(reader.topOfViewport)
    #expect(top.pageIndex == place.pageIndex)
    #expect(abs(top.point.y - place.point.y) < 1)
    #expect(abs(top.point.x - place.point.x) < 5)
}
