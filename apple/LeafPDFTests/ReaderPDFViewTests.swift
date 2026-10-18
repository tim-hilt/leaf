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

            session.highlightNextResult(in: .forward)
            for _ in 0..<40 where reader.highlightedSelections?.count != 3 { try await Task.sleep(for: .milliseconds(50)) }
            #expect(session.highlightedResultIndex == 0)
            #expect(reader.highlightedSelections?.count == 3)
        }
    #endif

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

/// A Reader on a Document with "apple" on page 6, and that match.
@MainActor
private func makeReaderWithMatch() throws -> (ReaderPDFView, PDFSelection) {
    let reader = try makeReader(size: CGSize(width: 400, height: 800), pageTexts: ["", "", "", "", "", "apple"])
    let match = try #require(reader.document?.findString("apple", withOptions: []).first)
    return (reader, match)
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
