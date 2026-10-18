import PDFKit
import Testing

@testable import LeafPDF

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

extension DocumentSearch {
    /// Everything `query` finds, once the search has finished.
    func run(_ query: Query) async -> [Match] {
        var found: [Match] = []
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            search(query, onMatch: { found.append($0) }, onFinish: { finished.resume() })
        }
        return found
    }
}
