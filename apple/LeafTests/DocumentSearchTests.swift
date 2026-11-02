import LeafCore
import PDFKit
import Testing

@testable import Leaf

#if os(macOS)
    import AppKit
#endif

@MainActor @Suite struct DocumentSearchTests {
    @Test func findsMatchesInReadingOrderAcrossPages() async throws {
        let search = DocumentSearch(
            try makePDF(named: "Fruit.pdf", pageCount: 3, pageTexts: ["apple pie, apple", "", "an apple"]))

        let matches = await search.run(Query("apple"))

        #expect(matches.map(\.chunkIndex) == [0, 0, 2])
        #expect(matches.map(\.range.length) == [5, 5, 5])
    }

    @Test func theQueryDecidesWhichOccurrencesMatch() async throws {
        let search = DocumentSearch(try makePDF(named: "Cats.pdf", pageTexts: ["Cat category, cat bobcat"]))

        let insensitive = await search.run(Query("cat", wordMatch: .fullWord))
        let sensitive = await search.run(Query("cat", caseSensitive: true, wordMatch: .fullWord))

        #expect(insensitive.map { $0.textRange.location } == [0, 14])
        #expect(sensitive.map { $0.textRange.location } == [14])
    }

    // MARK: Printed page number

    @Test func aMatchCarriesThePrintedNumberOfItsPage() async throws {
        let search = DocumentSearch(
            try makePDF(
                named: "Labelled.pdf", pageCount: 3, pageLabels: ["i", "ii", "1"],
                pageTexts: ["apple", "apple", "apple"]))

        let matches = await search.run(Query("apple"))

        #expect(matches.map(\.pageNumber) == ["i", "ii", "1"])
    }

    @Test func aPageWithoutALabelIsNumberedByItsPositionInTheFile() async throws {
        let search = DocumentSearch(
            try makePDF(named: "Plain.pdf", pageCount: 2, pageTexts: ["", "apple"]))

        let matches = await search.run(Query("apple"))

        #expect(matches.map(\.pageNumber) == ["2"])
    }

    // MARK: Containing Chapter or Section

    @Test func aMatchKnowsItsChapterOrSection() async throws {
        let top = CGPoint(x: 0, y: 792)
        let search = DocumentSearch(
            try makePDF(
                named: "Book.pdf", pageCount: 4,
                outline: [
                    OutlineEntry(
                        "Chapter 1", pageIndex: 1, at: top,
                        children: [OutlineEntry("Section 1.1", pageIndex: 2, at: top)]),
                    OutlineEntry("Chapter 2", pageIndex: 3, at: top),
                ],
                pageTexts: ["preface apple", "apple", "apple", "apple"]))

        let matches = await search.run(Query("apple"))

        // Nothing contains the preface.
        #expect(matches.map { $0.section?.title } == [nil, "Chapter 1", "Section 1.1", "Chapter 2"])
    }

    @Test func aMatchHasNoChapterOrSectionWithoutATableOfContents() async throws {
        let search = DocumentSearch(try makePDF(named: "Plain.pdf", pageTexts: ["apple"]))

        let matches = await search.run(Query("apple"))

        #expect(matches.map { $0.section?.title } == [nil])
    }

    @Test func anEmptyQueryHasNoMatches() async throws {
        let search = DocumentSearch(try makePDF(named: "Fruit.pdf", pageTexts: ["apple"]))
        let matches = await search.run(Query(""))
        #expect(matches.isEmpty)
    }

    @Test func pagesWithoutTextHaveNoMatches() async throws {
        let search = DocumentSearch(try makePDF(named: "Scan.pdf", pageCount: 3))
        let matches = await search.run(Query("apple"))
        #expect(matches.isEmpty)
    }

    @Test func aNewQueryCancelsTheOldOne() async throws {
        let search = DocumentSearch(
            try makePDF(named: "Fruit.pdf", pageCount: 2, pageTexts: ["apple", "apple banana"]))
        var old: [DocumentSearch.Match] = []
        var oldFinished = false
        search.search(Query("apple"), onMatch: { old.append($0) }, onFinish: { oldFinished = true })

        let matches = await search.run(Query("banana"))

        #expect(matches.map(\.chunkIndex) == [1])
        #expect(old.isEmpty)
        #expect(!oldFinished)
    }

    @Test func theMatchAtAPlaceInTheTextIsFoundByItsNumber() async throws {
        let search = DocumentSearch(try makePDF(named: "Fruit.pdf", pageTexts: ["apple pie, apple", ""]))

        let matches = await search.run(Query("apple"))

        #expect(matches.map { search.number(ofMatchAt: $0.textRange.location) } == [0, 1])
        #expect(search.number(ofMatchAt: 1) == nil)
    }
}

@MainActor @Suite struct EPUBDocumentSearchTests {
    private func search(
        chapters: [String], manifest: String = "", files: [String: Data] = [:]
    ) async throws -> DocumentSearch {
        let book = try await importedBook(chapters: chapters, manifest: manifest, files: files)
        return DocumentSearch(text: DocumentText.of(book), contents: book.tableOfContents(), results: SearchResults())
    }

    @Test func findsMatchesInReadingOrderAcrossChapters() async throws {
        let search = try await search(chapters: [
            "<p>apple pie, apple</p>", "<p>nothing</p>", "<p>an apple</p>",
        ])

        let matches = await search.run(Query("apple"))

        #expect(matches.map(\.chunkIndex) == [0, 0, 2])
        #expect(matches.map(\.range.location) == [0, 11, 3])
        #expect(matches.allSatisfy { $0.range.length == 5 })
    }

    @Test func aMatchKnowsItsChapterOrSection() async throws {
        let nav = """
            <html xmlns:epub="x"><body><nav epub:type="toc"><ol>\
            <li><a href="chapter1.xhtml">Chapter 1</a><ol><li><a href="chapter2.xhtml">Section 1.1</a></li></ol></li>\
            <li><a href="chapter3.xhtml">Chapter 2</a></li></ol></nav></body></html>
            """
        let search = try await search(
            chapters: ["<p>preface apple</p>", "<p>apple</p>", "<p>apple</p>", "<p>apple</p>"],
            manifest: #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            files: ["OEBPS/nav.xhtml": Data(nav.utf8)])

        let matches = await search.run(Query("apple"))

        // Nothing contains the preface.
        #expect(matches.map { $0.section?.title } == [nil, "Chapter 1", "Section 1.1", "Chapter 2"])
    }

    @Test func aMatchHasNoPrintedPageNumber() async throws {
        let search = try await search(chapters: ["<p>apple</p>"])
        let matches = await search.run(Query("apple"))
        #expect(matches.allSatisfy { $0.pageNumber == nil })
    }

    @Test func anEmptyQueryHasNoMatches() async throws {
        let search = try await search(chapters: ["<p>apple</p>"])
        #expect(await search.run(Query("")).isEmpty)
    }

    @Test func aNewQueryCancelsTheOldOne() async throws {
        let search = try await search(chapters: ["<p>apple</p>", "<p>apple banana</p>"])
        var old: [DocumentSearch.Match] = []
        var oldFinished = false
        search.search(Query("apple"), onMatch: { old.append($0) }, onFinish: { oldFinished = true })

        let matches = await search.run(Query("banana"))

        #expect(matches.map(\.chunkIndex) == [1])
        #expect(old.isEmpty)
        #expect(!oldFinished)
    }
}

#if os(macOS)
    // MARK: The macOS find bar's search

    @MainActor @Suite struct FindPasteboardQueryTests {
        /// A find pasteboard of its own, as the find bar fills it.
        private func pasteboard(_ text: String, options: [String: Any]) throws -> NSPasteboard {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            pasteboard.setData(
                try PropertyListSerialization.data(fromPropertyList: options, format: .binary, options: 0),
                forType: .textFinderOptions)
            return pasteboard
        }

        @Test func readsTheSearchStringAndOptions() throws {
            let caseKey = NSPasteboard.PasteboardType.TextFinderOptionKey.textFinderCaseInsensitiveKey.rawValue
            let matchKey = NSPasteboard.PasteboardType.TextFinderOptionKey.textFinderMatchingTypeKey.rawValue

            let query = Query(
                findPasteboard: try pasteboard("cat", options: [caseKey: false, matchKey: 3]))

            #expect(query == Query("cat", caseSensitive: true, wordMatch: .endsWith))
        }

        @Test func withoutOptionsItIsCaseInsensitiveAndContains() {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            pasteboard.clearContents()
            pasteboard.setString("cat", forType: .string)

            #expect(Query(findPasteboard: pasteboard) == Query("cat"))
        }
    }
#endif

// MARK: The Document's text, for clients that search it themselves

@MainActor @Suite struct PDFDocumentTextTests {
    @Test func joinsThePagesTextEndToEnd() throws {
        let text = DocumentText.of(try makePDF(named: "Fruit.pdf", pageCount: 3, pageTexts: ["apple", "", "banana"]))
        let first = try #require(text.chunk(index: 0))
        let last = try #require(text.chunk(index: 2))

        #expect(first.range == NSRange(location: 0, length: 5))
        #expect(text.text(index: 0)?.hasPrefix("apple") == true)
        #expect(text.text(index: 2)?.hasPrefix("banana") == true)
        #expect(last.range.location == 5)
        #expect(NSMaxRange(last.range) == text.length())
    }

    @Test func aRangeIsTheSelectionOnItsPage() throws {
        let document = try makePDF(named: "Fruit.pdf", pageCount: 2, pageTexts: ["apple", "pie, banana"])
        let text = DocumentText.of(document)
        let second = try #require(text.chunk(index: 1)).range
        let range = NSRange(location: second.location + 5, length: 6)

        let selection = try #require(document.selection(for: range, in: text))

        #expect(selection.string == "banana")
        #expect(selection.pages.count == 1)
        #expect(selection.pages.first.map { document.index(for: $0) } == 1)
    }

    @Test func aDocumentWithoutTextIsEmpty() throws {
        let document = try makePDF(named: "Scan.pdf", pageCount: 2)
        let text = DocumentText.of(document)
        #expect(text.length() == 0)
        #expect(document.selection(for: NSRange(location: 0, length: 1), in: text) == nil)
    }
}

extension DocumentSearch {
    /// The Document Search of `document`, for its tests.
    convenience init(_ document: PDFDocument) {
        self.init(text: DocumentText.of(document), contents: TableOfContents(document), results: SearchResults())
    }

    /// Everything `query` finds, once the search has finished.
    func run(_ query: Query) async -> [Match] {
        var found: [Match] = []
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            search(query, onMatch: { found.append($0) }, onFinish: { finished.resume() })
        }
        return found
    }
}
