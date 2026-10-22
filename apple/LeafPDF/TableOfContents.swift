import LeafCore
import PDFKit

/// The Chapters and Sections of a Document, in reading order, as `Place`s.
/// Empty when the Document has none. A PDF's outline is one source of entries;
/// nothing is stored or synced.
struct TableOfContents: Sendable {
    /// A Chapter (top level) or Section (nested under another entry).
    struct Entry: Identifiable, Sendable {
        /// Unique within a Table of Contents; numbers entries in reading order.
        let id: Int
        let title: String
        /// The printed page number (page label), or the 1-based position in the
        /// File when the target page has none. Nil when the entry has no page
        /// number: without a target, or in a Format without pages.
        let pageNumber: String?
        /// Where the entry points. Nil when the source gives it no target:
        /// such an entry is listed but can't be chosen.
        let place: Place?
        let sections: [Entry]
    }

    /// The entries of `book`'s Table of Contents, which has no page numbers.
    init(_ book: EpubBook) {
        var nextID = 0
        func entries(of stored: [ContentsEntry]) -> [Entry] {
            stored.map { entry in
                let id = nextID
                nextID += 1
                return Entry(
                    id: id, title: entry.title, pageNumber: nil, place: entry.place,
                    sections: entries(of: entry.sections))
            }
        }
        chapters = entries(of: book.contents())
    }

    /// Where a Place is in the Table of Contents.
    struct Position {
        /// The deepest Chapter or Section starting at or before the Place.
        let current: Entry
        /// The Chapters and Sections that contain `current`, outermost first.
        let containing: [Entry]
    }

    let chapters: [Entry]

    var isEmpty: Bool { chapters.isEmpty }

    /// An empty Table of Contents.
    init() { chapters = [] }

    init(chapters: [Entry]) { self.chapters = chapters }

    /// The entries of `document`'s outline.
    init(_ document: PDFDocument) {
        var nextID = 0
        func entries(under outline: PDFOutline) -> [Entry] {
            (0..<outline.numberOfChildren).compactMap { outline.child(at: $0) }.map { child in
                let id = nextID
                nextID += 1
                let target = Self.target(of: child, in: document)
                return Entry(
                    id: id, title: child.label ?? "", pageNumber: target?.pageNumber, place: target?.place,
                    sections: entries(under: child))
            }
        }
        chapters = document.outlineRoot.map(entries(under:)) ?? []
    }

    /// Where `place` is: the last Chapter or Section, in reading order, that
    /// starts at or before it (a Section wins over the entry containing it when
    /// both start at the same spot). Nil before the first entry. Entries
    /// without a target are skipped.
    func position(at place: Place) -> Position? {
        var best: (entry: Entry, containing: [Entry])?
        func search(_ entries: [Entry], containing: [Entry]) {
            for entry in entries {
                if let start = entry.place, start.isAtOrBefore(place) {
                    // `best` always has a Place, so a missing one means no rival.
                    let isLater = best?.entry.place.map(start.isAtOrAfter) ?? true
                    if isLater { best = (entry, containing) }
                }
                search(entry.sections, containing: containing + [entry])
            }
        }
        search(chapters, containing: [])
        return best.map { Position(current: $0.entry, containing: $0.containing) }
    }

    /// How Back names `place`: by the Chapter it is in, also within one of its Sections,
    /// or the beginning of the Document before the first one.
    func backTarget(at place: Place) -> BackTarget {
        position(at: place).map { .chapter(($0.containing.first ?? $0.current).title) } ?? .beginning
    }

    private static func target(
        of outline: PDFOutline, in document: PDFDocument
    ) -> (place: Place, pageNumber: String)? {
        let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        guard let destination, let place = Place(destination, in: document),
            let pageIndex = place.pdfPosition?.pageIndex
        else { return nil }
        return (place, document.printedPageNumber(at: pageIndex))
    }
}
