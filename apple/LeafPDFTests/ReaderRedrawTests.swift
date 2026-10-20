#if os(iOS)
    import PDFKit
    import Testing

    @testable import LeafPDF

    /// What the Reader shows on screen, read back as pixels: changes must show
    /// without scrolling.
    @MainActor @Suite struct ReaderRedrawTests {
        let marked = CGRect(x: 100, y: 300, width: 400, height: 300)
        let white = RGB(1, 1, 1)
        let paper = PageColors.default.paper

        @Test func changingThePageAppearanceRedrawsTheShownPages() async throws {
            // Starts on what only drawn pages show.
            let reader = try makeReader(appearance: .dark(.default))
            let spot = centre(of: marked, in: reader)
            try await expectShown(paper, at: spot, in: reader)
            try await settle()

            reader.pageAppearance = .light
            try await expectShown(white, at: spot, in: reader)

            reader.pageAppearance = .dark(.default)
            try await expectShown(paper, at: spot, in: reader)
        }

        @Test func changingHighlightsRedrawsTheShownPages() async throws {
            // Starts on what only drawn pages show.
            let reader = try makeReader(highlights: [highlight()])
            let spot = centre(of: marked, in: reader)
            try await expectShown(.sampleYellow, at: spot, in: reader)
            try await settle()

            reader.highlights = []
            try await expectShown(white, at: spot, in: reader)

            reader.highlights = [highlight()]
            try await expectShown(.sampleYellow, at: spot, in: reader)
        }

        @Test func noteIconsSetBeforeTheFirstLayoutShow() async throws {
            var noted = highlight()
            noted.note = "a thought"
            let reader = try makeReader(highlights: [noted])
            let icon = try #require(reader.noteIconRect(of: noted))
            // The icon's top-left corner, inside its border.
            try await expectShown(.sampleYellow, at: CGPoint(x: icon.minX + 2, y: icon.minY + 2), in: reader)
        }

        @Test func pagesFillTheWidthAtFitToWidth() async throws {
            // No margin beside the pages, where the light background would frame Dark Pages.
            let reader = try makeReader(appearance: .dark(.default))
            try await expectShown(paper, at: CGPoint(x: 0, y: 100), in: reader)
            try await expectShown(paper, at: CGPoint(x: reader.bounds.width - 1, y: 100), in: reader)
        }

        func highlight() -> Highlight {
            Highlight(
                id: "a", anchor: HighlightAnchor(pages: [.init(pageIndex: 0, rects: [marked])], quotedText: "a"),
                color: .sampleYellow)
        }

        func centre(of rect: CGRect, in reader: ReaderPDFView) -> CGPoint {
            reader.convert(CGPoint(x: rect.midX, y: rect.midY), from: reader.document!.page(at: 0)!)
        }

        /// A Reader on a blank two-page `StyledDocument`, set up as the app does:
        /// everything is set before the view has a size.
        func makeReader(appearance: PageAppearance = .light, highlights: [Highlight] = []) throws -> ReaderPDFView {
            let reader = ReaderPDFView(handle: ReaderHandle())
            reader.displayMode = .singlePageContinuous
            reader.autoScales = true
            reader.document = try #require(StyledDocument(url: writePDF(named: "Redraw.pdf", pageCount: 2)))
            reader.pageAppearance = appearance
            reader.highlights = highlights
            // On screen: PDFKit draws differently into windows that aren't.
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            window.addSubview(reader)
            window.makeKeyAndVisible()
            windows.append(window)
            reader.frame = window.bounds
            reader.layoutIfNeeded()
            return reader
        }

        /// Waits for PDFKit to finish drawing the pages: it draws them again,
        /// sharper, after first showing them.
        func settle() async throws { try await Task.sleep(for: .seconds(1.5)) }

        /// Expects `color` on screen at `point`, within two seconds.
        func expectShown(_ color: RGB, at point: CGPoint, in reader: ReaderPDFView) async throws {
            var shown = pixel(at: point, in: reader)
            for _ in 0..<40 where !shown.isClose(to: color) {
                try await Task.sleep(for: .milliseconds(50))
                shown = pixel(at: point, in: reader)
            }
            #expect(shown.isClose(to: color), "\(shown) at \(point)")
        }

        func pixel(at point: CGPoint, in view: UIView) -> RGB {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = CGContext(
                data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let cg = image.cgImage!
            let (width, height) = (CGFloat(cg.width), CGFloat(cg.height))
            context.draw(cg, in: CGRect(x: -point.x, y: point.y - height + 1, width: width, height: height))
            return RGB(Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
        }
    }

    /// Windows of the Readers under test, which a view only holds weakly.
    @MainActor private var windows: [UIWindow] = []

    extension RGB {
        fileprivate func isClose(to other: RGB) -> Bool {
            abs(r - other.r) < 0.05 && abs(g - other.g) < 0.05 && abs(b - other.b) < 0.05
        }
    }
#endif
