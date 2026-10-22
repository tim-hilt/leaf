import Foundation
import LeafCore
import Testing

@testable import LeafPDF

@MainActor @Suite struct EPUBSearchTests {
    private func search(
        chapters: [String], manifest: String = "", files: [String: Data] = [:]
    ) async throws -> EPUBSearch {
        let book = try await importedBook(chapters: chapters, manifest: manifest, files: files)
        return EPUBSearch(ChunkedText(book), contents: TableOfContents(book))
    }

    @Test func findsMatchesInReadingOrderAcrossChapters() async throws {
        let search = try await search(chapters: [
            "<p>apple pie, apple</p>", "<p>nothing</p>", "<p>an apple</p>",
        ])

        let matches = await search.run(.init("apple"))

        #expect(matches.map(\.spineIndex) == [0, 0, 2])
        #expect(matches.map(\.range.location) == [0, 11, 3])
        #expect(matches.allSatisfy { $0.range.length == 5 })
    }

    @Test func aMatchsRangeIsInTheCoresText() async throws {
        let book = try await importedBook(chapters: ["<p>One <b>two</b> three</p><p>two</p>"])
        let search = EPUBSearch(ChunkedText(book), contents: TableOfContents(book))

        let matches = await search.run(.init("two"))

        let text = try #require(book.text(index: 0)) as NSString
        #expect(matches.map { text.substring(with: $0.range) } == ["two", "two"])
    }

    @Test func ignoresCaseUnlessAskedNotTo() async throws {
        let search = try await search(chapters: ["<p>Apple apple APPLE</p>"])

        let insensitive = await search.run(.init("apple"))
        let sensitive = await search.run(.init("apple", caseSensitive: true))
        let capitalised = await search.run(.init("Apple", caseSensitive: true))

        #expect(insensitive.map(\.range.location) == [0, 6, 12])
        #expect(sensitive.map(\.range.location) == [6])
        #expect(capitalised.map(\.range.location) == [0])
    }

    // "cat" is a word at the start and end, among punctuation, and inside "category", "bobcat" and "cats".
    private static let cats = "<p>cat category, (cat) bobcat cats cat-food. cat</p>"

    @Test func wordMatchMethodsDecideOnWordBoundaries() async throws {
        let search = try await search(chapters: [Self.cats])

        #expect(await search.run(.init("cat", wordMatch: .contains)).count == 7)
        #expect(await search.run(.init("cat", wordMatch: .startsWith)).count == 6)
        #expect(await search.run(.init("cat", wordMatch: .endsWith)).count == 5)
        #expect(await search.run(.init("cat", wordMatch: .fullWord)).count == 4)
    }

    @Test func aMatchHasAnExcerptAroundIt() async throws {
        let search = try await search(chapters: ["<p>The quick brown fox</p>\n<p>jumps over the lazy dog</p>"])

        let match = try #require(await search.run(.init("fox")).first)

        #expect(match.excerpt.text == "The quick brown fox jumps over the lazy dog")
        #expect(match.excerpt.text[match.excerpt.matchRange] == "fox")
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

        let matches = await search.run(.init("apple"))

        // Nothing contains the preface.
        #expect(matches.map { $0.section?.title } == [nil, "Chapter 1", "Section 1.1", "Chapter 2"])
    }

    @Test func anEmptyQueryHasNoMatches() async throws {
        let search = try await search(chapters: ["<p>apple</p>"])
        #expect(await search.run(.init("")).isEmpty)
    }

    @Test func aNewQueryCancelsTheOldOne() async throws {
        let search = try await search(chapters: ["<p>apple</p>", "<p>apple banana</p>"])
        var old: [EPUBSearch.Match] = []
        var oldFinished = false
        search.search(.init("apple"), onMatch: { old.append($0) }, onFinish: { oldFinished = true })

        let matches = await search.run(.init("banana"))

        #expect(matches.map(\.spineIndex) == [1])
        #expect(old.isEmpty)
        #expect(!oldFinished)
    }
}

extension EPUBSearch {
    /// Everything `query` finds, once the search has finished.
    func run(_ query: DocumentSearch.Query) async -> [Match] {
        var found: [Match] = []
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            search(query, onMatch: { found.append($0) }, onFinish: { finished.resume() })
        }
        return found
    }
}
