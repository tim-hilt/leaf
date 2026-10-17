import CoreGraphics

/// A spot in a Document: a page and a point on it in PDF page space (points,
/// origin at the page's bottom-left). Independent of zoom and window size, so
/// it survives resizing and can be stored as Reading Progress.
struct Place: Equatable {
    let pageIndex: Int
    let point: CGPoint
}
