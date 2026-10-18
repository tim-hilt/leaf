import CoreGraphics

/// A spot in a Document: a page and a point on it in PDF page space (points,
/// origin at the page's bottom-left). Independent of zoom and window size, so
/// it survives resizing and can be stored as Reading Progress.
struct Place: Equatable {
    let pageIndex: Int
    let point: CGPoint

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
