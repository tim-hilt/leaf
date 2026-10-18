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
}

/// A Reader on an eight-page Document, laid out in a window of `size`. With
/// `openingAt`, it is asked to open there before the Document is set.
@MainActor
private func makeReader(size: CGSize, openingAt place: Place? = nil) throws -> ReaderPDFView {
    let reader = ReaderPDFView(handle: ReaderHandle())
    if let place { reader.open(at: place) }
    reader.displayMode = .singlePageContinuous
    reader.autoScales = true
    reader.frame = CGRect(origin: .zero, size: size)
    #if os(iOS)
        let window = UIWindow(frame: reader.frame)
        window.addSubview(reader)
        window.isHidden = false
    #else
        let window = NSWindow(
            contentRect: reader.frame, styleMask: [.titled, .resizable], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader
    #endif
    reader.document = try makePDF(named: "Long.pdf", pageCount: 8)
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
