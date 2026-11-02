import Foundation
import LeafCore
import Testing

@testable import Leaf

@MainActor @Suite struct EPUBSearchTests {
    private func search(
        chapters: [String], manifest: String = "", files: [String: Data] = [:]
    ) async throws -> EPUBSearch {
        let book = try await importedBook(chapters: chapters, manifest: manifest, files: files)
        return EPUBSearch(book, contents: book.tableOfContents())
    }

    @Test func findsMatchesInReadingOrderAcrossChapters() async throws {
        let search = try await search(chapters: [
            "<p>apple pie, apple</p>", "<p>nothing</p>", "<p>an apple</p>",
        ])

        let matches = await search.run(Query("apple"))

        #expect(matches.map(\.spineIndex) == [0, 0, 2])
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

    @Test func anEmptyQueryHasNoMatches() async throws {
        let search = try await search(chapters: ["<p>apple</p>"])
        #expect(await search.run(Query("")).isEmpty)
    }

    @Test func aNewQueryCancelsTheOldOne() async throws {
        let search = try await search(chapters: ["<p>apple</p>", "<p>apple banana</p>"])
        var old: [EPUBSearch.Match] = []
        var oldFinished = false
        search.search(Query("apple"), onMatch: { old.append($0) }, onFinish: { oldFinished = true })

        let matches = await search.run(Query("banana"))

        #expect(matches.map(\.spineIndex) == [1])
        #expect(old.isEmpty)
        #expect(!oldFinished)
    }
}

extension EPUBSearch {
    /// Everything `query` finds, once the search has finished.
    func run(_ query: Query) async -> [Match] {
        var found: [Match] = []
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            search(query, onMatch: { found.append($0) }, onFinish: { finished.resume() })
        }
        return found
    }
}
