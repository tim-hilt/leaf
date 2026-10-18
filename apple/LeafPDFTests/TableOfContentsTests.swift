import PDFKit
import Testing

@testable import LeafPDF

@Suite struct TableOfContentsTests {
    let outline = [
        OutlineEntry(
            "Part One", pageIndex: 0,
            children: [
                OutlineEntry("Setup", pageIndex: 1, at: CGPoint(x: 0, y: 500)),
                OutlineEntry(
                    "Usage", pageIndex: 2,
                    children: [OutlineEntry("Advanced", pageIndex: 3, at: CGPoint(x: 10, y: 300))]),
            ]),
        OutlineEntry("Part Two", pageIndex: 4),
    ]

    @Test func listsChaptersWithNestedSectionsAndTheirPlaces() throws {
        let contents = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: outline))

        #expect(contents.chapters.map(\.title) == ["Part One", "Part Two"])
        let partOne = contents.chapters[0]
        #expect(partOne.place == Place(pageIndex: 0, point: CGPoint(x: 0, y: 792)))
        #expect(partOne.sections.map(\.title) == ["Setup", "Usage"])
        #expect(partOne.sections[0].place == Place(pageIndex: 1, point: CGPoint(x: 0, y: 500)))
        #expect(partOne.sections[0].sections.isEmpty)
        let advanced = partOne.sections[1].sections
        #expect(advanced.map(\.title) == ["Advanced"])
        #expect(advanced[0].place == Place(pageIndex: 3, point: CGPoint(x: 10, y: 300)))
    }

    @Test func showsPrintedPageNumbers() throws {
        let labels = ["i", "ii", "1", "2", "3"]
        let contents = TableOfContents(
            try makePDF(named: "Book.pdf", pageCount: 5, outline: outline, pageLabels: labels))

        #expect(contents.chapters.map(\.pageNumber) == ["i", "3"])
        #expect(contents.chapters[0].sections.map(\.pageNumber) == ["ii", "1"])
        #expect(contents.chapters[0].sections[1].sections.map(\.pageNumber) == ["2"])
    }

    @Test func fallsBackToThePositionInTheFileWithoutPageLabels() throws {
        let contents = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: outline))

        #expect(contents.chapters.map(\.pageNumber) == ["1", "5"])
        #expect(contents.chapters[0].sections.map(\.pageNumber) == ["2", "3"])
    }

    @Test func isEmptyWithoutAnOutline() throws {
        #expect(TableOfContents(try makePDF(named: "Plain.pdf", pageCount: 3)).isEmpty)
    }

    @Test func isEmptyWhenTheOutlineHasNoEntries() throws {
        let document = try makePDF(named: "Plain.pdf", pageCount: 3)
        document.outlineRoot = PDFOutline()
        #expect(TableOfContents(document).isEmpty)
    }

    @Test func listsEntriesWithoutATargetThatCantBeChosen() throws {
        let document = try makePDF(named: "Book.pdf", pageCount: 5, outline: outline)
        let untargeted = PDFOutline()
        untargeted.label = "Dangling"
        let root = try #require(document.outlineRoot)
        try #require(root.child(at: 0)).insertChild(untargeted, at: 2)

        let contents = TableOfContents(document)

        let sections = contents.chapters[0].sections
        #expect(sections.map(\.title) == ["Setup", "Usage", "Dangling"])
        #expect(sections[2].place == nil)
        #expect(sections[2].pageNumber == "")
    }

    // MARK: Where you are

    private func locate(
        at pageIndex: Int, _ y: CGFloat = 792, in contents: TableOfContents
    ) -> (current: String, containing: [String])? {
        contents.position(at: Place(pageIndex: pageIndex, point: CGPoint(x: 0, y: y))).map {
            ($0.current.title, $0.containing.map(\.title))
        }
    }

    @Test func currentIsTheDeepestEntryAtOrBeforeThePlace() throws {
        let contents = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: outline))

        #expect(locate(at: 1, 500, in: contents)?.current == "Setup")  // exactly at its target
        #expect(locate(at: 1, 100, in: contents)?.current == "Setup")  // further down the page
        #expect(locate(at: 2, in: contents)?.current == "Usage")
        #expect(locate(at: 4, 1, in: contents)?.current == "Part Two")
    }

    @Test func anEntryBelowThePlaceOnItsPageIsNotYetCurrent() throws {
        let contents = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: outline))

        #expect(locate(at: 1, 502, in: contents)?.current == "Part One")
    }

    @Test func aHairBelowAnEntrysTargetStillCountsAsAtIt() throws {
        let contents = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: outline))

        #expect(locate(at: 1, 500.4, in: contents)?.current == "Setup")
    }

    @Test func hasNoCurrentEntryBeforeTheFirstOne() throws {
        let later = [OutlineEntry("Chapter", pageIndex: 2, at: CGPoint(x: 0, y: 400))]
        let contents = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: later))

        #expect(locate(at: 1, in: contents) == nil)
        #expect(locate(at: 2, 402, in: contents) == nil)
    }

    @Test func currentCanBeInsideANestedSection() throws {
        let contents = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: outline))

        let found = try #require(locate(at: 3, 10, in: contents))
        #expect(found.current == "Advanced")
        #expect(found.containing == ["Part One", "Usage"])
    }

    @Test func aChapterIsContainedInNothing() throws {
        let contents = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: outline))

        #expect(locate(at: 4, in: contents)?.containing == [])
    }

    @Test func currentIgnoresEntriesWithoutATarget() throws {
        let document = try makePDF(named: "Book.pdf", pageCount: 5, outline: outline)
        let untargeted = PDFOutline()
        untargeted.label = "Dangling"
        let root = try #require(document.outlineRoot)
        try #require(root.child(at: 0)).insertChild(untargeted, at: 2)

        #expect(locate(at: 3, in: TableOfContents(document))?.current == "Usage")
    }

    @Test func aLaterEntryAtTheSamePlaceWinsAndTheDeepestOneAtItDoes() throws {
        let nested = [
            OutlineEntry("Chapter", pageIndex: 1, children: [OutlineEntry("Opening Section", pageIndex: 1)])
        ]
        let contents = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 3, outline: nested))

        let found = try #require(locate(at: 1, in: contents))
        #expect(found.current == "Opening Section")
        #expect(found.containing == ["Chapter"])
    }
}
