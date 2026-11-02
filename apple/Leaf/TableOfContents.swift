import LeafCore
import PDFKit

/// The core's Table of Contents (`LeafCore.TableOfContents`) as the Reader shows it. An
/// EPUB's comes from the core; a PDF's is built here from its outline, which is
/// PDFKit's. Nothing is stored or synced.
extension TableOfContents {
    /// The Table of Contents of `document`'s outline: a Chapter per top-level entry,
    /// Sections nested under them.
    convenience init(_ document: PDFDocument) {
        self.init(entries: document.outlineRoot.map { Self.entries(under: $0, in: document) } ?? [])
    }

    /// How Back names `place`: by its Chapter, or the beginning of the Document before the first one.
    func backTarget(at place: Place) -> BackTarget {
        chapterTitle(place: place).map(BackTarget.chapter) ?? .beginning
    }

    private static func entries(under outline: PDFOutline, in document: PDFDocument) -> [ContentsEntry] {
        (0..<outline.numberOfChildren).compactMap { outline.child(at: $0) }.map { child in
            let target = target(of: child, in: document)
            return ContentsEntry(
                title: child.label ?? "", pageLabel: target?.pageLabel, place: target?.place,
                sections: entries(under: child, in: document))
        }
    }

    /// Where `outline` points, and the printed number of that page.
    private static func target(
        of outline: PDFOutline, in document: PDFDocument
    ) -> (place: Place, pageLabel: String)? {
        let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        guard let destination, let place = Place(destination, in: document),
            let pageIndex = place.pdfPosition?.pageIndex
        else { return nil }
        return (place, document.printedPageNumber(at: pageIndex))
    }
}
