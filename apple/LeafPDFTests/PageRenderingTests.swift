import PDFKit
import Testing

@testable import LeafPDF

@Suite struct PageRenderingTests {
    /// A page 100 × 100 pt of white paper with a black square on the left and
    /// a red one on the right, at 1 px per pt: its x-range 10…30 is black and
    /// 60…80 is red; the rest is paper.
    func document(in appearance: PageAppearance) throws -> StyledDocument {
        let url = try writePDF(
            named: "colors.pdf",
            inks: [
                Ink(rect: CGRect(x: 10, y: 10, width: 20, height: 20), color: CGColor(gray: 0, alpha: 1)),
                Ink(rect: CGRect(x: 60, y: 10, width: 20, height: 20), color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            ])
        let document = try #require(StyledDocument(url: url))
        document.appearance = appearance
        return document
    }

    /// The pixel at the middle of the black square, the red square and the paper.
    func samples(_ appearance: PageAppearance) throws -> (black: RGB, red: RGB, paper: RGB) {
        let document = try document(in: appearance)  // pages only hold their document weakly
        let image = try #require(document.page(at: 0)?.image(pixelWidth: 612))
        // 612 px for a 612 pt page: 1 px per pt. `y` is in PDF page space, from the bottom.
        func pixel(_ x: Int, _ y: Int) -> RGB { image.pixel(x: x, y: 792 - y) }
        return (pixel(20, 20), pixel(70, 20), pixel(300, 400))
    }

    @Test func lightPagesLeaveThePixelsUnchanged() throws {
        let (black, red, paper) = try samples(.light)
        #expect(black.isClose(to: RGB(0, 0, 0)))
        #expect(red.isClose(to: RGB(1, 0, 0), tolerance: 0.2))  // PDF red is converted into sRGB
        #expect(paper.isClose(to: RGB(1, 1, 1)))
    }

    @Test func darkPagesShowPaperInThePageColorAndBlackInkInTheTextColor() throws {
        let colors = PageColors.default
        let (black, _, paper) = try samples(.dark(colors))
        #expect(paper.isClose(to: colors.paper))
        #expect(black.isClose(to: colors.ink))
    }

    @Test func darkPagesKeepTheHueOfColoredInk() throws {
        let (_, red, paper) = try samples(.dark(.default))
        #expect(red.r > red.g + 0.2 && red.r > red.b + 0.2)
        #expect(red.r > paper.r)  // brightness reversed: ink is lighter than paper
    }

    @Test func darkPagesHonorCustomPageColors() throws {
        let sepia = PageColors(paper: RGB(0x2B / 255, 0x21 / 255, 0x16 / 255), ink: RGB(0xE0 / 255, 0xC8 / 255, 0xA0 / 255))
        let (black, _, paper) = try samples(.dark(sepia))
        #expect(paper.isClose(to: sepia.paper))
        #expect(black.isClose(to: sepia.ink))
    }

    @Test func aPageCanBeRestyledAfterItWasDrawn() throws {
        let document = try document(in: .light)
        let page = try #require(document.page(at: 0))
        let before = try #require(page.image(pixelWidth: 612)).pixel(x: 300, y: 400)
        document.appearance = .dark(.default)
        let after = try #require(page.image(pixelWidth: 612)).pixel(x: 300, y: 400)
        #expect(before.isClose(to: RGB(1, 1, 1)))
        #expect(after.isClose(to: PageColors.default.paper))
    }

    @Test func darkPagesPaintNothingOutsideThePage() throws {
        let document = try document(in: .dark(.default))
        let page = try #require(document.page(at: 0))
        // A blue canvas with 10 pt around the page and no clip, so the page alone limits what it paints.
        let context = try #require(
            CGContext(
                data: nil, width: 632, height: 812, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 632, height: 812))
        context.translateBy(x: 10, y: 10)
        page.draw(with: .cropBox, to: context)
        let image = try #require(context.makeImage())

        #expect(image.pixel(x: 5, y: 5).isClose(to: RGB(0, 0, 1)))
        #expect(image.pixel(x: 316, y: 406).isClose(to: PageColors.default.paper))
    }

    // MARK: Highlights

    /// The Document of `document(in:)` with a yellow Highlight over the left half of the black square and a
    /// bit of paper above it, on the page's first line: x 10…20, y 20…40.
    func highlightedDocument(in appearance: PageAppearance) throws -> StyledDocument {
        let document = try document(in: appearance)
        let anchor = HighlightAnchor(
            pages: [.init(pageIndex: 0, rects: [CGRect(x: 10, y: 20, width: 10, height: 20)])], quotedText: "x")
        document.highlights = [Highlight(id: "a", anchor: anchor, color: RGB.sampleYellow)]
        return document
    }

    /// The pixels of the Highlight's rectangle: over the black square (lower half) and over paper (upper half).
    func samplesOfHighlight(_ appearance: PageAppearance) throws -> (ink: RGB, paper: RGB, outside: RGB) {
        let document = try highlightedDocument(in: appearance)
        let image = try #require(document.page(at: 0)?.image(pixelWidth: 612))
        func pixel(_ x: Int, _ y: Int) -> RGB { image.pixel(x: x, y: 792 - y) }
        return (pixel(15, 25), pixel(15, 35), pixel(25, 25))
    }

    @Test func lightPagesMultiplyHighlightsIntoThePage() throws {
        let (ink, paper, outside) = try samplesOfHighlight(.light)
        #expect(paper.isClose(to: RGB.sampleYellow))  // paper is white: multiplying gives the color
        #expect(ink.isClose(to: RGB(0, 0, 0)))  // black ink stays readable
        #expect(outside.isClose(to: RGB(0, 0, 0)))
    }

    @Test func darkPagesReverseHighlightsWithThePage() throws {
        let colors = PageColors.default
        let (ink, paper, outside) = try samplesOfHighlight(.dark(colors))
        #expect(ink.isClose(to: colors.ink))  // the text on a Highlight stays as readable as other text
        #expect(outside.isClose(to: colors.ink))
        // Not the plain paper, and not the Highlight's own color: reversed with the page, hue kept.
        #expect(!paper.isClose(to: colors.paper, tolerance: 0.1))
        #expect(!paper.isClose(to: RGB.sampleYellow, tolerance: 0.1))
        #expect(paper.r > paper.b + 0.1 && paper.g > paper.b + 0.1)
    }

    @Test func aHighlightOnAnotherPageDoesNotShowHere() throws {
        let document = try document(in: .light)
        let anchor = HighlightAnchor(
            pages: [.init(pageIndex: 1, rects: [CGRect(x: 10, y: 20, width: 10, height: 20)])], quotedText: "x")
        document.highlights = [Highlight(id: "a", anchor: anchor, color: RGB.sampleYellow)]
        let image = try #require(document.page(at: 0)?.image(pixelWidth: 612))
        #expect(image.pixel(x: 15, y: 792 - 35).isClose(to: RGB(1, 1, 1)))
    }

    @Test func defaultPageColorsAreDarkGreyPaperAndLightGreyInk() {
        #expect(PageColors.default.paper.isClose(to: RGB(0x1E / 255, 0x1E / 255, 0x1E / 255)))
        #expect(PageColors.default.ink.isClose(to: RGB(0xD6 / 255, 0xD6 / 255, 0xD6 / 255)))
    }
}

extension RGB {
    func isClose(to other: RGB, tolerance: Double = 0.02) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }
}

extension PDFPage {
    /// The whole page on white, as drawn in its document, `pixelWidth` pixels wide.
    func image(pixelWidth: Int) -> CGImage? {
        let box = bounds(for: .cropBox).applying(transform(for: .cropBox))
        let scale = CGFloat(pixelWidth) / box.width
        let context = CGContext(
            data: nil, width: pixelWidth, height: Int((box.height * scale).rounded()), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.scaleBy(x: scale, y: scale)
        context?.setFillColor(gray: 1, alpha: 1)
        context?.fill(box)
        context.map { draw(with: .cropBox, to: $0) }
        return context?.makeImage()
    }
}

extension CGImage {
    /// The color at `x`, `y` (from the top left) of an image drawn by `PDFPage.image(pixelWidth:)`.
    func pixel(x: Int, y: Int) -> RGB {
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(self, in: CGRect(x: -x, y: y - height + 1, width: width, height: height))
        return RGB(Double(rgba[0]) / 255, Double(rgba[1]) / 255, Double(rgba[2]) / 255)
    }
}
