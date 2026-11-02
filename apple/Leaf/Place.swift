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
}
