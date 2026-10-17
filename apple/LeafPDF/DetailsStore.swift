import Foundation

/// What the Gallery shows and searches for a Document, read from its PDF once.
struct DocumentDetails: Codable, Equatable, Sendable {
    /// The PDF's title, or its file name (without extension) if it has none.
    var title: String
    var author: String?
}

/// The saved `DocumentDetails` of every Document, in one JSON file keyed by
/// Document ID, so the Gallery never opens a PDF to list its Documents. Kept
/// outside the Library folder and never synced. Losing the file is harmless:
/// the Library reads the details again. Writes that fail are ignored for the
/// same reason.
@MainActor
final class DetailsStore {
    private var entries: [String: DocumentDetails]
    private let file: URL

    /// Loads the entries saved in `file`; none if it is missing or unreadable.
    init(file: URL) {
        self.file = file
        entries = (try? JSONDecoder().decode([String: DocumentDetails].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// The details saved for Document `id`. Setting saves them to disk; setting nil forgets them.
    subscript(id: String) -> DocumentDetails? {
        get { entries[id] }
        set {
            entries[id] = newValue
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
        }
    }
}
