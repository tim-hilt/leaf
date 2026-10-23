import PDFKit
import Testing

@testable import Leaf

#if os(macOS)
    import AppKit
#endif

@MainActor @Suite struct DocumentSearchTests {
    @Test func findsMatchesInReadingOrderAcrossPages() async throws {
        let search = DocumentSearch(
            try makePDF(
                named: "Fruit.pdf", pageCount: 3, pageTexts: ["apple pie, apple", "", "an apple"]))

        let matches = await search.run(DocumentSearch.Query("apple"))

        #expect(matches.map(\.pageIndex) == [0, 0, 2])
        #expect(matches.allSatisfy { $0.selection.string == "apple" })
    }

    @Test func ignoresCaseUnlessAskedNotTo() async throws {
        let search = DocumentSearch(try makePDF(named: "Fruit.pdf", pageTexts: ["Apple apple APPLE"]))

        let insensitive = await search.run(.init("apple"))
        let sensitive = await search.run(.init("apple", caseSensitive: true))
        let capitalised = await search.run(.init("Apple", caseSensitive: true))

        #expect(insensitive.map(\.selection.string) == ["Apple", "apple", "APPLE"])
        #expect(sensitive.map(\.selection.string) == ["apple"])
        #expect(capitalised.map(\.selection.string) == ["Apple"])
    }

    // "cat" appears as a word at the start and end of the page, among punctuation,
    // and inside "category", "bobcat" and "cats".
    static let cats = "cat category, (cat) bobcat cats cat-food. cat"

    @Test func containsMatchesInsideWords() async throws {
        let search = DocumentSearch(try makePDF(named: "Cats.pdf", pageTexts: [Self.cats]))
        let matches = await search.run(.init("cat", wordMatch: .contains))
        #expect(matches.count == 7)
    }

    @Test func startsWithMatchesAtTheStartOfAWord() async throws {
        let search = DocumentSearch(try makePDF(named: "Cats.pdf", pageTexts: [Self.cats]))
        let matches = await search.run(.init("cat", wordMatch: .startsWith))
        // Not "bobcat": it is the end of a word.
        #expect(matches.count == 6)
    }

    @Test func fullWordMatchesWholeWordsOnly() async throws {
        let search = DocumentSearch(try makePDF(named: "Cats.pdf", pageTexts: [Self.cats]))
        let matches = await search.run(.init("cat", wordMatch: .fullWord))
        // The first and last on the page, "(cat)" and "cat-food".
        #expect(matches.count == 4)
    }

    @Test func fullWordMatchesAWordThatIsAllOfThePage() async throws {
        let search = DocumentSearch(try makePDF(named: "One.pdf", pageTexts: ["cat"]))
        let matches = await search.run(.init("cat", wordMatch: .fullWord))
        #expect(matches.count == 1)
    }

    @Test func endsWithMatchesAtTheEndOfAWord() async throws {
        let search = DocumentSearch(try makePDF(named: "Cats.pdf", pageTexts: [Self.cats]))
        let matches = await search.run(.init("cat", wordMatch: .endsWith))
        // Not "category" or "cats": a letter follows.
        #expect(matches.count == 5)
    }

    // MARK: Excerpt

    @Test func anExcerptIsTheTextAroundTheMatchWithItsRange() async throws {
        let search = DocumentSearch(
            try makePDF(named: "Fox.pdf", pageTexts: ["The quick brown fox jumps over the lazy dog"]))

        let match = try #require(await search.run(.init("fox")).first)

        #expect(match.excerpt.text == "The quick brown fox jumps over the lazy dog")
        #expect(match.excerpt.text[match.excerpt.matchRange] == "fox")
    }

    @Test func anExcerptIsShortAndOnOneLine() async throws {
        let filler = Array(repeating: "lorem ipsum dolor sit amet", count: 20).joined(separator: " ")
        let search = DocumentSearch(
            try makePDF(named: "Long.pdf", pageTexts: ["\(filler) needle \(filler)"]))

        let match = try #require(await search.run(.init("needle")).first)

        #expect(match.excerpt.text[match.excerpt.matchRange] == "needle")
        #expect(match.excerpt.text.count < 200)
        #expect(!match.excerpt.text.contains { $0.isNewline })
        #expect(!match.excerpt.text.hasPrefix(" ") && !match.excerpt.text.hasSuffix(" "))
    }

    @Test func anExcerptAtTheEdgesOfThePageIsCutThere() async throws {
        let search = DocumentSearch(try makePDF(named: "Edge.pdf", pageTexts: ["cat sat on a cat"]))

        let matches = await search.run(.init("cat"))

        #expect(matches.map(\.excerpt.text) == ["cat sat on a cat", "cat sat on a cat"])
        #expect(
            matches.map {
                $0.excerpt.text.distance(from: $0.excerpt.text.startIndex, to: $0.excerpt.matchRange.lowerBound)
            } == [0, 13])
    }

    // MARK: Printed page number

    @Test func aMatchCarriesThePrintedNumberOfItsPage() async throws {
        let search = DocumentSearch(
            try makePDF(
                named: "Labelled.pdf", pageCount: 3, pageLabels: ["i", "ii", "1"],
                pageTexts: ["apple", "apple", "apple"]))

        let matches = await search.run(.init("apple"))

        #expect(matches.map(\.pageNumber) == ["i", "ii", "1"])
    }

    @Test func aPageWithoutALabelIsNumberedByItsPositionInTheFile() async throws {
        let search = DocumentSearch(
            try makePDF(named: "Plain.pdf", pageCount: 2, pageTexts: ["", "apple"]))

        let matches = await search.run(.init("apple"))

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

        let matches = await search.run(.init("apple"))

        // Nothing contains the preface.
        #expect(matches.map { $0.section?.title } == [nil, "Chapter 1", "Section 1.1", "Chapter 2"])
    }

    @Test func aMatchHasNoChapterOrSectionWithoutATableOfContents() async throws {
        let search = DocumentSearch(try makePDF(named: "Plain.pdf", pageTexts: ["apple"]))

        let matches = await search.run(.init("apple"))

        #expect(matches.map { $0.section?.title } == [nil])
    }

    @Test func anEmptyQueryHasNoMatches() async throws {
        let search = DocumentSearch(try makePDF(named: "Fruit.pdf", pageTexts: ["apple"]))
        let matches = await search.run(.init(""))
        #expect(matches.isEmpty)
    }

    @Test func pagesWithoutTextHaveNoMatches() async throws {
        let search = DocumentSearch(try makePDF(named: "Scan.pdf", pageCount: 3))
        let matches = await search.run(.init("apple"))
        #expect(matches.isEmpty)
    }

    @Test func aNewQueryCancelsTheOldOne() async throws {
        let search = DocumentSearch(
            try makePDF(named: "Fruit.pdf", pageCount: 2, pageTexts: ["apple", "apple banana"]))
        var old: [DocumentSearch.Match] = []
        var oldFinished = false
        search.search(.init("apple"), onMatch: { old.append($0) }, onFinish: { oldFinished = true })

        let matches = await search.run(.init("banana"))

        #expect(matches.map(\.pageIndex) == [1])
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

            let query = DocumentSearch.Query(
                findPasteboard: try pasteboard("cat", options: [caseKey: false, matchKey: 3]))

            #expect(query == DocumentSearch.Query("cat", caseSensitive: true, wordMatch: .endsWith))
        }

        @Test func withoutOptionsItIsCaseInsensitiveAndContains() {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            pasteboard.clearContents()
            pasteboard.setString("cat", forType: .string)

            #expect(DocumentSearch.Query(findPasteboard: pasteboard) == DocumentSearch.Query("cat"))
        }
    }
#endif

// MARK: PDF text, for clients that search the text themselves

@MainActor @Suite struct PDFChunkedTextTests {
    @Test func joinsThePagesTextEndToEnd() throws {
        let text = ChunkedText(try makePDF(named: "Fruit.pdf", pageCount: 3, pageTexts: ["apple", "", "banana"]))
        let first = text.chunk(at: 0)
        let last = text.chunk(at: text.length - 1)

        #expect(first.range == NSRange(location: 0, length: first.string.utf16.count))
        #expect(first.string.hasPrefix("apple"))
        #expect(last.string.hasPrefix("banana"))
        #expect(last.range.location == first.string.utf16.count)
        #expect(NSMaxRange(last.range) == text.length)
    }

    @Test func aRangeIsTheSelectionOnItsPage() throws {
        let document = try makePDF(named: "Fruit.pdf", pageCount: 2, pageTexts: ["apple", "pie, banana"])
        let text = ChunkedText(document)
        let second = text.chunk(at: text.length - 1).range
        let range = NSRange(location: second.location + 5, length: 6)

        let selection = try #require(document.selection(for: range, in: text))

        #expect(selection.string == "banana")
        #expect(selection.pages.count == 1)
        #expect(selection.pages.first.map { document.index(for: $0) } == 1)
    }

    @Test func aRangeOnAPageIsPlacedInTheWholeText() {
        let text = ChunkedText(["apple", "", "pie, banana"])
        let onPage = NSRange(location: 5, length: 6)

        let whole = text.range(onPage, inChunkAt: 2)

        #expect(whole == NSRange(location: 10, length: 6))
        #expect(text.inChunk(whole)?.chunkIndex == 2)
        #expect(text.inChunk(whole)?.range == onPage)
    }

    @Test func aDocumentWithoutTextIsEmpty() throws {
        let document = try makePDF(named: "Scan.pdf", pageCount: 2)
        let text = ChunkedText(document)
        #expect(text.length == 0)
        #expect(document.selection(for: NSRange(location: 0, length: 1), in: text) == nil)
    }
}

extension DocumentSearch {
    convenience init(_ document: PDFDocument) { self.init(document, contents: TableOfContents(document)) }

    /// Everything `query` finds, once the search has finished.
    func run(_ query: Query) async -> [Match] {
        var found: [Match] = []
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            search(query, onMatch: { found.append($0) }, onFinish: { finished.resume() })
        }
        return found
    }
}
