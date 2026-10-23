import CoreGraphics
import LeafCore
import PDFKit

/// Swift's view of the core's `Place`: a spot in a Document, independent of zoom,
/// text size and window size, so it survives resizing and can be stored as Reading
/// Progress. Its kind follows the Document's Format.
extension Place {
    /// A page and a point on it in PDF page space (points, origin at the page's
    /// bottom-left).
    static func pdf(pageIndex: Int, point: CGPoint) -> Place {
        .pdf(pageIndex: UInt32(pageIndex), x: point.x, y: point.y)
    }

    /// A spine item and a character offset into its text (ADR-0022).
    static func epub(spineIndex: Int, offset: Int) -> Place {
        .epub(spineIndex: UInt32(spineIndex), offset: UInt64(offset))
    }

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
        guard case .pdf(let pageIndex, let x, let y) = self else { return nil }
        return (Int(pageIndex), CGPoint(x: x, y: y))
    }

    /// The spine item and offset of an EPUB Place; nil for other kinds.
    var epubPosition: (spineIndex: Int, offset: Int)? {
        guard case .epub(let spineIndex, let offset) = self else { return nil }
        return (Int(spineIndex), Int(clamping: offset))
    }

    /// Whether this Place comes no later than `other` in reading order: an
    /// earlier page or spine item, or the same one and no later. PDF points less
    /// than a point apart count as the same, so rounding in scrolling can't push
    /// a heading that was just jumped to out of reach; pages read in one column,
    /// so horizontal position is ignored. Places of different kinds have no order.
    func isAtOrBefore(_ other: Place) -> Bool {
        switch (self, other) {
        case (.pdf(let page, _, let y), .pdf(let otherPage, _, let otherY)):
            return page != otherPage ? page < otherPage : y >= otherY - 1
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
