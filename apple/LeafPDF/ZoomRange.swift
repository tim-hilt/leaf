import CoreGraphics

/// The scales a Document may be zoomed to: from fit-to-width up to five times
/// that. Scales are PDFKit scale factors, so fit-to-width depends on the
/// Reader's width and the Document's pages.
struct ZoomRange {
    /// How far past fit-to-width the user may zoom in.
    static let maximumMultiple: CGFloat = 5
    /// How far a double-tap zooms in from fit-to-width.
    static let doubleTapMultiple: CGFloat = 2

    /// How much each ⌘+ / ⌘− step zooms in or out.
    static let keyboardStep: CGFloat = 1.25

    let fitToWidth: CGFloat

    var minimum: CGFloat { fitToWidth }
    var maximum: CGFloat { fitToWidth * Self.maximumMultiple }

    func clamped(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimum), maximum)
    }

    /// The scale a double-tap goes to: zoomed in from fit-to-width, otherwise
    /// back out to fit-to-width.
    func doubleTapTarget(from scale: CGFloat) -> CGFloat {
        let isFitToWidth = scale < fitToWidth * 1.01
        return isFitToWidth ? clamped(fitToWidth * Self.doubleTapMultiple) : fitToWidth
    }

    func zoomedIn(from scale: CGFloat) -> CGFloat {
        clamped(scale * Self.keyboardStep)
    }

    func zoomedOut(from scale: CGFloat) -> CGFloat {
        clamped(scale / Self.keyboardStep)
    }

    /// The scale in this range that is the same multiple of fit-to-width as
    /// `scale` is in `old`. Re-fits when `scale` was fit-to-width, and keeps
    /// the zoom relative to fit-to-width when zoomed in.
    func rescaled(_ scale: CGFloat, from old: ZoomRange) -> CGFloat {
        clamped(scale * (fitToWidth / old.fitToWidth))
    }
}
