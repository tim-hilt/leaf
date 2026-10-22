#if os(iOS)
    import LeafCore
    import PDFKit
    import Testing

    @testable import LeafPDF

    /// What the Reader shows on screen, read back as pixels: changes must show
    /// without scrolling.
    @MainActor @Suite struct ReaderRedrawTests: PixelReadback {
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

        @Test func changingThePageAppearanceRedrawsPagesJustOutOfView() async throws {
            let reader = try makeReader(appearance: .dark(.default), pageCount: 4)
            try await settle()

            reader.pageAppearance = .light
            try await settle()
            reader.go(to: Place.pdf(pageIndex: 1, point: CGPoint(x: 0, y: 700)))
            try await expectShown(white, at: CGPoint(x: 200, y: 400), in: reader)
        }

        @Test func changingThePageAppearanceSwitchesTheShownPagesAtOnce() async throws {
            // PDFKit redraws a page in tiles, one after the other. Large enough for several.
            let reader = try makeReader(appearance: .dark(.default), size: CGSize(width: 1024, height: 1366))
            try await settle()
            let corners = [
                CGPoint(x: 100, y: 200), CGPoint(x: 900, y: 200), CGPoint(x: 100, y: 1200), CGPoint(x: 900, y: 1200),
            ]

            reader.pageAppearance = .light
            for _ in 0..<30 {
                let shown = pixels(at: corners, in: reader)
                let uniform = shown.allSatisfy { $0.isClose(to: paper) } || shown.allSatisfy { $0.isClose(to: white) }
                #expect(uniform, "\(shown)")
                guard uniform else { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await expectShown(white, at: corners[0], in: reader)
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

        @Test func darkPagesAreSeparatedByDarkEvenInALightSystem() async throws {
            let reader = try makeReader(appearance: .dark(.default))
            try await settle()
            let document = try #require(reader.document)
            let first = reader.convert(document.page(at: 0)!.bounds(for: .cropBox), from: document.page(at: 0)!)
            let second = reader.convert(document.page(at: 1)!.bounds(for: .cropBox), from: document.page(at: 1)!)
            let gap = CGPoint(x: reader.bounds.midX, y: (first.maxY + second.minY) / 2)
            #expect(second.minY > first.maxY)
            let shown = pixel(at: gap, in: reader)
            #expect(shown.r < 0.2 && shown.g < 0.2 && shown.b < 0.2, "\(shown) at \(gap)")
        }

        @Test func lightPagesShowALightGapAlsoInADarkSystem() async throws {
            // The gap is half the pages' paper, whatever the system theme: it
            // would be dark between Light Pages in a dark one otherwise.
            let reader = try makeReader(interfaceStyle: .dark)
            try await settle()
            let document = try #require(reader.document)
            let first = reader.convert(document.page(at: 0)!.bounds(for: .cropBox), from: document.page(at: 0)!)
            let second = reader.convert(document.page(at: 1)!.bounds(for: .cropBox), from: document.page(at: 1)!)
            let gap = CGPoint(x: reader.bounds.midX, y: (first.maxY + second.minY) / 2)
            #expect(second.minY > first.maxY)
            try await expectShown(RGB(0.5, 0.5, 0.5), at: gap, in: reader)
        }

        @Test func darkPagesAreSeparatedByDarkAlsoInADarkSystem() async throws {
            let reader = try makeReader(appearance: .dark(.default), interfaceStyle: .dark)
            try await settle()
            let document = try #require(reader.document)
            let first = reader.convert(document.page(at: 0)!.bounds(for: .cropBox), from: document.page(at: 0)!)
            let second = reader.convert(document.page(at: 1)!.bounds(for: .cropBox), from: document.page(at: 1)!)
            let gap = CGPoint(x: reader.bounds.midX, y: (first.maxY + second.minY) / 2)
            #expect(second.minY > first.maxY)
            let shown = pixel(at: gap, in: reader)
            #expect(shown.r < 0.2 && shown.g < 0.2 && shown.b < 0.2, "\(shown) at \(gap)")
        }

        @Test func switchingPageStylesSwitchesTheGap() async throws {
            let reader = try makeReader(appearance: .dark(.default), interfaceStyle: .dark)
            try await settle()
            let document = try #require(reader.document)
            let first = reader.convert(document.page(at: 0)!.bounds(for: .cropBox), from: document.page(at: 0)!)
            let second = reader.convert(document.page(at: 1)!.bounds(for: .cropBox), from: document.page(at: 1)!)
            let gap = CGPoint(x: reader.bounds.midX, y: (first.maxY + second.minY) / 2)
            let darkGap = PageColors.default.paper
            try await expectShown(RGB(darkGap.r / 2, darkGap.g / 2, darkGap.b / 2), at: gap, in: reader)

            reader.pageAppearance = .light
            try await expectShown(RGB(0.5, 0.5, 0.5), at: gap, in: reader)
        }

        @Test func darkPagesNeverShowLightWhileOpening() async throws {
            let reader = try makeReader(appearance: .dark(.default))
            try await expectAlwaysShown(paper, at: centre(of: marked, in: reader), in: reader)
        }

        @Test func darkPagesNeverShowLightAfterAJump() async throws {
            let reader = try makeReader(appearance: .dark(.default), pageCount: 60)
            try await settle()
            reader.go(to: Place.pdf(pageIndex: 40, point: CGPoint(x: 0, y: 700)))
            try await expectAlwaysShown(paper, at: CGPoint(x: 200, y: 400), in: reader)
        }

        @Test func darkPagesNeverShowLightWhenOpeningPartwayIn() async throws {
            // What a Tab switch does: reopen from the saved place, zoom and Back place.
            let state = ReaderViewState(
                place: Place.pdf(pageIndex: 40, point: CGPoint(x: 0, y: 700)), zoom: 1.5,
                backPlace: Place.pdf(pageIndex: 3, point: CGPoint(x: 0, y: 500)))
            let reader = try makeReader(appearance: .dark(.default), pageCount: 60, opening: state)
            try await expectAlwaysShown(paper, at: CGPoint(x: 200, y: 400), in: reader)
        }

        func highlight() -> Highlight {
            Highlight(id: "a", anchor: .pdf([PageRects(pageIndex: 0, rects: [marked])]), quotedText: "a")
        }

        func centre(of rect: CGRect, in reader: ReaderPDFView) -> CGPoint {
            reader.convert(CGPoint(x: rect.midX, y: rect.midY), from: reader.document!.page(at: 0)!)
        }

        /// A Reader on a blank two-page `StyledDocument`, set up as the app does:
        /// everything is set before the view has a size, and the Document has its
        /// Page Style and Highlights before the view gets it.
        func makeReader(
            appearance: PageAppearance = .light, highlights: [Highlight] = [], pageCount: Int = 2,
            opening state: ReaderViewState? = nil, interfaceStyle: UIUserInterfaceStyle = .light,
            size: CGSize = CGSize(width: 400, height: 800)
        ) throws -> ReaderPDFView {
            let document = try #require(StyledDocument(url: writePDF(named: "Redraw.pdf", pageCount: pageCount)))
            document.appearance = appearance
            document.highlights = highlights
            let reader = ReaderPDFView(handle: ReaderHandle())
            reader.displayMode = .singlePageContinuous
            reader.autoScales = true
            if let state { reader.open(from: state) }
            reader.document = document
            reader.highlights = highlights
            // On screen: PDFKit draws differently into windows that aren't.
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = interfaceStyle
            window.addSubview(reader)
            window.makeKeyAndVisible()
            windows.append(window)
            reader.frame = window.bounds
            reader.layoutIfNeeded()
            return reader
        }
    }
#endif
