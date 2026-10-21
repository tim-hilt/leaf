import CoreGraphics
import PDFKit

/// A spot in a Document, independent of zoom, text size and window size, so it
/// survives resizing and can be stored as Reading Progress. Its kind follows the
/// Document's Format.
enum Place: Equatable {
    /// A page and a point on it in PDF page space (points, origin at the
    /// page's bottom-left).
    case pdf(pageIndex: Int, point: CGPoint)
    /// A spine item and a character offset into its text (ADR-0022).
    case epub(spineIndex: Int, offset: Int)

    /// Where `destination` points in `document`, with a coordinate the
    /// destination leaves open (PDF's "null") taken as the page's top-left
    /// corner. Nil when it has no page in the Document.
    init?(_ destination: PDFDestination, in document: PDFDocument) {
        guard let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let point = destination.point
        self = .pdf(
            pageIndex: index,
            point: CGPoint(
                x: point.x == kPDFDestinationUnspecifiedValue ? bounds.minX : point.x,
                y: point.y == kPDFDestinationUnspecifiedValue ? bounds.maxY : point.y))
    }

    /// The page and point of a PDF Place; nil for other kinds.
    var pdfPosition: (pageIndex: Int, point: CGPoint)? {
        guard case .pdf(let pageIndex, let point) = self else { return nil }
        return (pageIndex, point)
    }

    /// Whether this Place comes no later than `other` in reading order: an
    /// earlier page or spine item, or the same one and no later. PDF points less
    /// than a point apart count as the same, so rounding in scrolling can't push
    /// a heading that was just jumped to out of reach; pages read in one column,
    /// so horizontal position is ignored. Places of different kinds have no order.
    func isAtOrBefore(_ other: Place) -> Bool {
        switch (self, other) {
        case (.pdf(let page, let point), .pdf(let otherPage, let otherPoint)):
            return page != otherPage ? page < otherPage : point.y >= otherPoint.y - 1
        case (.epub(let spine, let offset), .epub(let otherSpine, let otherOffset)):
            return spine != otherSpine ? spine < otherSpine : offset <= otherOffset
        default:
            return false
        }
    }

    /// Whether this Place is the same spot as `other`: neither comes before the
    /// other (see `isAtOrBefore`).
    func isSameSpot(as other: Place) -> Bool { isAtOrBefore(other) && isAtOrAfter(other) }

    /// Whether this Place comes no earlier than `other`; see `isAtOrBefore`.
    func isAtOrAfter(_ other: Place) -> Bool { other.isAtOrBefore(self) }
}
