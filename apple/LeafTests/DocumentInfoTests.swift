import Foundation
import Testing

@testable import Leaf

struct DocumentInfoTests {
    @Test func separatesFileSizeFromTheDataNextToIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "A.pdf")
        try Data(count: 100).write(to: file)
        try Data(count: 7).write(to: folder.appending(path: ".state-x.automerge"))
        try Data(count: 3).write(to: folder.appending(path: ".progress-x"))

        let sizes = DocumentInfo.sizes(of: file)

        #expect(sizes.file == 100)
        #expect(sizes.data == 10)
    }
}
