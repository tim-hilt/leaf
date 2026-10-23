import LeafCore
import PDFKit
import Testing

@testable import Leaf

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
        #expect(partOne.place == Place.pdf(pageIndex: 0, point: CGPoint(x: 0, y: 792)))
        #expect(partOne.sections.map(\.title) == ["Setup", "Usage"])
        #expect(partOne.sections[0].place == Place.pdf(pageIndex: 1, point: CGPoint(x: 0, y: 500)))
        #expect(partOne.sections[0].sections.isEmpty)
        let advanced = partOne.sections[1].sections
        #expect(advanced.map(\.title) == ["Advanced"])
        #expect(advanced[0].place == Place.pdf(pageIndex: 3, point: CGPoint(x: 10, y: 300)))
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
        #expect(sections[2].pageNumber == nil)
    }

    // MARK: Where you are

    private func locate(
        at pageIndex: Int, _ y: CGFloat = 792, in contents: TableOfContents
    ) -> (current: String, containing: [String])? {
        contents.position(at: Place.pdf(pageIndex: pageIndex, point: CGPoint(x: 0, y: y))).map {
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

    @Test func locatesEPUBPlacesInEntriesWithoutPageNumbers() throws {
        func entry(_ id: Int, _ title: String, spine: Int, offset: Int, _ sections: [TableOfContents.Entry] = [])
            -> TableOfContents.Entry
        {
            .init(
                id: id, title: title, pageNumber: nil, place: .epub(spineIndex: spine, offset: offset),
                sections: sections)
        }
        let contents = TableOfContents(chapters: [
            entry(0, "One", spine: 0, offset: 0, [entry(1, "Opening", spine: 0, offset: 120)]),
            entry(2, "Two", spine: 1, offset: 0),
        ])

        func current(_ spine: Int, _ offset: Int) -> String? {
            contents.position(at: .epub(spineIndex: spine, offset: offset))?.current.title
        }
        #expect(current(0, 50) == "One")
        #expect(current(0, 120) == "Opening")
        #expect(current(1, 5) == "Two")
        #expect(contents.position(at: .pdf(pageIndex: 0, point: .zero)) == nil)
    }

    // MARK: EPUB

    @MainActor @Test func listsAnEPUBsChaptersAndSectionsWithoutPageNumbers() async throws {
        let nav = """
            <html xmlns:epub="x"><body><nav epub:type="toc"><ol>\
            <li><a href="chapter0.xhtml">Prologue</a></li>\
            <li><a href="chapter1.xhtml">Part</a><ol>\
            <li><a href="chapter1.xhtml#s">Section</a></li><li><span>Unlinked</span></li></ol></li>\
            </ol></nav></body></html>
            """
        let book = try await importedBook(
            chapters: ["<p>One</p>", "<p>Two</p><p id=\"s\">Three</p>"],
            manifest: #"<item id="n" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            files: ["OEBPS/nav.xhtml": Data(nav.utf8)])

        let contents = TableOfContents(book)

        #expect(contents.chapters.map(\.title) == ["Prologue", "Part"])
        #expect(contents.chapters[0].place == .epub(spineIndex: 0, offset: 0))
        let sections = contents.chapters[1].sections
        #expect(sections.map(\.title) == ["Section", "Unlinked"])
        #expect(sections[0].place == .epub(spineIndex: 1, offset: 3))
        #expect(sections[1].place == nil)
        let all = contents.chapters + sections
        #expect(all.allSatisfy { $0.pageNumber == nil })
        #expect(Set(all.map(\.id)).count == 4)
    }

    @MainActor @Test func anEPUBWithoutATableOfContentsHasAnEmptyOne() async throws {
        #expect(TableOfContents(try await importedBook(chapters: ["<p>x</p>"])).isEmpty)
    }

    @Test func theBackCapsuleNamesTheChapterAPlaceIsIn() {
        func entry(_ id: Int, _ title: String, _ offset: Int, _ sections: [TableOfContents.Entry] = [])
            -> TableOfContents.Entry
        {
            .init(
                id: id, title: title, pageNumber: nil, place: .epub(spineIndex: 0, offset: offset),
                sections: sections)
        }
        let contents = TableOfContents(chapters: [
            entry(0, "One", 10, [entry(1, "Opening", 20)]), entry(2, "Two", 100),
        ])

        #expect(contents.backTarget(at: .epub(spineIndex: 0, offset: 15)) == .chapter("One"))
        // In a Section: still named by its Chapter, as the glossary has it.
        #expect(contents.backTarget(at: .epub(spineIndex: 0, offset: 20)) == .chapter("One"))
        #expect(contents.backTarget(at: .epub(spineIndex: 0, offset: 500)) == .chapter("Two"))
        // Before the first entry.
        #expect(contents.backTarget(at: .epub(spineIndex: 0, offset: 5)) == .beginning)
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
