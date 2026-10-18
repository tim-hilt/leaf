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
}
