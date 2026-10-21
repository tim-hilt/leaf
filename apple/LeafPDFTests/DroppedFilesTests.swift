import Foundation
import Testing

@testable import LeafPDF

@MainActor @Suite struct DroppedFilesTests {
    @Test func acceptsPDFsAndEPUBsOnly() throws {
        let pdf = NSItemProvider(contentsOf: try writePDF(named: "a.pdf"))!
        let epub = NSItemProvider(contentsOf: try writeEPUB(named: "a.epub"))!
        let text = NSItemProvider(object: "hello" as NSString)

        #expect(DroppedFiles.accepts([pdf]))
        #expect(DroppedFiles.accepts([epub]))
        #expect(DroppedFiles.accepts([text, pdf]))
        #expect(!DroppedFiles.accepts([text]))
    }

    @Test func receivesACopyOfADroppedEPUBUnderItsName() async throws {
        let dropped = DroppedFiles()
        let item = NSItemProvider(contentsOf: try writeEPUB(named: "book.epub"))!
        item.suggestedName = "book"

        let urls = await dropped.receive([item])

        #expect(urls.map(\.lastPathComponent) == ["book.epub"])
        dropped.removeCopies()
    }

    @Test func receivesCopiesOfThePDFsInDropOrderAndLeavesTheOriginals() async throws {
        let first = try writePDF(named: "first.pdf")
        let second = try writePDF(named: "second.pdf")
        let dropped = DroppedFiles()
        let firstItem = NSItemProvider(contentsOf: first)!
        let secondItem = NSItemProvider(contentsOf: second)!
        firstItem.suggestedName = "first"
        // Some sources suggest the name with its extension.
        secondItem.suggestedName = "second.pdf"

        let urls = await dropped.receive([firstItem, NSItemProvider(object: "x" as NSString), secondItem])

        #expect(urls.map(\.lastPathComponent) == ["first.pdf", "second.pdf"])
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        dropped.removeCopies()
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: first.path))
    }
}
