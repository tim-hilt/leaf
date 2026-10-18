import CoreGraphics
import PDFKit

/// A spot in a Document: a page and a point on it in PDF page space (points,
/// origin at the page's bottom-left). Independent of zoom and window size, so
/// it survives resizing and can be stored as Reading Progress.
struct Place: Equatable {
    let pageIndex: Int
    let point: CGPoint

    /// Where `destination` points in `document`, with a coordinate the
    /// destination leaves open (PDF's "null") taken as the page's top-left
    /// corner. Nil when it has no page in the Document.
    init?(_ destination: PDFDestination, in document: PDFDocument) {
        guard let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let point = destination.point
        self.init(
            pageIndex: index,
            point: CGPoint(
                x: point.x == kPDFDestinationUnspecifiedValue ? bounds.minX : point.x,
                y: point.y == kPDFDestinationUnspecifiedValue ? bounds.maxY : point.y))
    }

    init(pageIndex: Int, point: CGPoint) {
        self.pageIndex = pageIndex
        self.point = point
    }

    /// Whether this Place comes no later than `other` in reading order: an
    /// earlier page, or the same page and no lower. Points less than a point
    /// apart count as the same, so rounding in scrolling can't push a heading
    /// that was just jumped to out of reach. Pages read in one column, so
    /// horizontal position is ignored.
    func isAtOrBefore(_ other: Place) -> Bool {
        pageIndex != other.pageIndex ? pageIndex < other.pageIndex : point.y >= other.point.y - 1
    }

    /// Whether this Place is the same spot as `other`: neither comes before the
    /// other (see `isAtOrBefore`).
    func isSameSpot(as other: Place) -> Bool { isAtOrBefore(other) && isAtOrAfter(other) }

    /// Whether this Place comes no earlier than `other`; see `isAtOrBefore`.
    func isAtOrAfter(_ other: Place) -> Bool { other.isAtOrBefore(self) }
}
