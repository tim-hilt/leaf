import LeafCore
import PDFKit
import Testing

@testable import Leaf

/// The adapters of a Table of Contents: a PDF's outline and an EPUB's contents, as the
/// core takes them. Where a place is in them is the core's, tested in Rust.
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
        let chapters = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: outline)).chapters()

        #expect(chapters.map(\.title) == ["Part One", "Part Two"])
        let partOne = chapters[0]
        #expect(partOne.place == Place.pdf(pageIndex: 0, point: CGPoint(x: 0, y: 792)))
        #expect(partOne.sections.map(\.title) == ["Setup", "Usage"])
        #expect(partOne.sections[0].place == Place.pdf(pageIndex: 1, point: CGPoint(x: 0, y: 500)))
        #expect(partOne.sections[0].sections.isEmpty)
        let advanced = partOne.sections[1].sections
        #expect(advanced.map(\.title) == ["Advanced"])
        #expect(advanced[0].place == Place.pdf(pageIndex: 3, point: CGPoint(x: 10, y: 300)))
    }

    @Test func showsPrintedPageLabels() throws {
        let labels = ["i", "ii", "1", "2", "3"]
        let chapters = TableOfContents(
            try makePDF(named: "Book.pdf", pageCount: 5, outline: outline, pageLabels: labels)
        ).chapters()

        #expect(chapters.map(\.pageLabel) == ["i", "3"])
        #expect(chapters[0].sections.map(\.pageLabel) == ["ii", "1"])
        #expect(chapters[0].sections[1].sections.map(\.pageLabel) == ["2"])
    }

    @Test func fallsBackToThePositionInTheFileWithoutPageLabels() throws {
        let chapters = TableOfContents(try makePDF(named: "Book.pdf", pageCount: 5, outline: outline)).chapters()

        #expect(chapters.map(\.pageLabel) == ["1", "5"])
        #expect(chapters[0].sections.map(\.pageLabel) == ["2", "3"])
    }

    @Test func isEmptyWithoutAnOutline() throws {
        #expect(TableOfContents(try makePDF(named: "Plain.pdf", pageCount: 3)).isEmpty())
    }

    @Test func isEmptyWhenTheOutlineHasNoEntries() throws {
        let document = try makePDF(named: "Plain.pdf", pageCount: 3)
        document.outlineRoot = PDFOutline()
        #expect(TableOfContents(document).isEmpty())
    }

    @Test func listsEntriesWithoutATargetThatCantBeChosen() throws {
        let document = try makePDF(named: "Book.pdf", pageCount: 5, outline: outline)
        let untargeted = PDFOutline()
        untargeted.label = "Dangling"
        let root = try #require(document.outlineRoot)
        try #require(root.child(at: 0)).insertChild(untargeted, at: 2)

        let sections = TableOfContents(document).chapters()[0].sections

        #expect(sections.map(\.title) == ["Setup", "Usage", "Dangling"])
        #expect(sections[2].place == nil)
        #expect(sections[2].pageLabel == nil)
    }

    @MainActor @Test func listsAnEPUBsChaptersAndSectionsWithoutPageLabels() async throws {
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

        let chapters = book.tableOfContents().chapters()

        #expect(chapters.map(\.title) == ["Prologue", "Part"])
        #expect(chapters[0].place == .epub(spineIndex: 0, offset: 0))
        let sections = chapters[1].sections
        #expect(sections.map(\.title) == ["Section", "Unlinked"])
        #expect(sections[0].place == .epub(spineIndex: 1, offset: 3))
        #expect(sections[1].place == nil)
        let all = chapters + sections
        #expect(all.allSatisfy { $0.pageLabel == nil })
        #expect(Set(all.map(\.id)).count == 4)
    }

    @MainActor @Test func anEPUBWithoutATableOfContentsHasAnEmptyOne() async throws {
        #expect(try await importedBook(chapters: ["<p>x</p>"]).tableOfContents().isEmpty())
    }
}
