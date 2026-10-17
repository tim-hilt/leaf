import PDFKit

/// Lets window-level commands (macOS menu) reach the Reader's `PDFView`.
@MainActor
final class ReaderHandle {
    fileprivate(set) weak var view: ReaderPDFView?
}

/// A `PDFView` zoomable from fit-to-width to 5× that (`ZoomRange`) that keeps
/// your place: the content at the top of the viewport stays put when the view
/// is resized or rotated, and when zooming with the keyboard. PDFKit's own
/// pinch gesture does the pinch zooming, so the content under the fingers
/// stays put; on iOS a double-tap toggles between fit-to-width and zoomed in.
final class ReaderPDFView: PDFView {
    /// Where the viewport was before a size change, to be restored once the
    /// new layout is known.
    private struct Viewpoint {
        let place: Place
        let scale: CGFloat
        let range: ZoomRange
    }

    /// PDFKit's fit-to-width changes with the view's width, so it is
    /// refreshed on every layout. Nil until the first layout.
    private var zoomRange: ZoomRange?
    private var viewpoint: Viewpoint?

    convenience init(handle: ReaderHandle) {
        self.init(frame: .zero)
        handle.view = self
    }

    // MARK: Keyboard zoom, anchored at the top of the viewport

    func zoomIn() {
        guard let range = zoomRange else { return }
        zoom(to: range.zoomedIn(from: scaleFactor))
    }

    func zoomOut() {
        guard let range = zoomRange else { return }
        zoom(to: range.zoomedOut(from: scaleFactor))
    }

    func zoomToFitWidth() {
        guard let range = zoomRange else { return }
        zoom(to: range.fitToWidth)
    }

    private func zoom(to scale: CGFloat) {
        let place = topOfViewport
        scaleFactor = scale
        if let place { go(to: place) }
    }

    // MARK: Keeping your place

    /// The content at the viewport's top-left corner.
    private var topOfViewport: Place? {
        guard let destination = currentDestination, let page = destination.page,
            let document
        else { return nil }
        return Place(pageIndex: document.index(for: page), point: destination.point)
    }

    private func go(to place: Place) {
        guard let page = document?.page(at: place.pageIndex) else { return }
        // Scrolling puts a destination at the view's top-left.
        go(to: PDFDestination(page: page, at: place.point))
    }

    /// Remembers the viewport; call just before the view's size changes.
    fileprivate func sizeWillChange(to size: CGSize, from oldSize: CGSize) {
        guard size != oldSize, viewpoint == nil, let range = zoomRange,
            let place = topOfViewport
        else { return }
        viewpoint = Viewpoint(place: place, scale: scaleFactor, range: range)
    }

    /// Refreshes the zoom limits for the current width, then restores the
    /// remembered viewpoint at the new fit-to-width.
    private func layoutDidChange() {
        let fit = scaleFactorForSizeToFit
        guard fit > 0 else { return }
        let range = ZoomRange(fitToWidth: fit)
        if minScaleFactor != range.minimum { minScaleFactor = range.minimum }
        if maxScaleFactor != range.maximum { maxScaleFactor = range.maximum }
        zoomRange = range
        if let viewpoint {
            self.viewpoint = nil
            scaleFactor = range.rescaled(viewpoint.scale, from: viewpoint.range)
            go(to: viewpoint.place)
        }
    }

    #if os(iOS)
        override init(frame: CGRect) {
            super.init(frame: frame)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(didDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        // UIKit may resize through either property.
        override var bounds: CGRect {
            willSet { sizeWillChange(to: newValue.size, from: bounds.size) }
        }

        override var frame: CGRect {
            willSet { sizeWillChange(to: newValue.size, from: frame.size) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutDidChange()
        }

        /// Zooms to `scale`, keeping the content at `point` (in view coordinates)
        /// under that point.
        private func zoom(to scale: CGFloat, keeping point: CGPoint) {
            guard let page = page(for: point, nearest: true) else { return }
            let anchor = convert(point, to: page)
            scaleFactor = scale
            // Aim for the page-space point that has the same offset from the
            // anchor as the view's corner has from `point`.
            let anchorNow = convert(anchor, from: page)
            let corner = CGPoint(x: anchorNow.x - point.x, y: anchorNow.y - point.y)
            go(to: PDFDestination(page: page, at: convert(corner, to: page)))
        }

        @objc private func didDoubleTap(_ tap: UITapGestureRecognizer) {
            guard let range = zoomRange else { return }
            zoom(to: range.doubleTapTarget(from: scaleFactor), keeping: tap.location(in: self))
        }
    #else
        override func setFrameSize(_ newSize: NSSize) {
            sizeWillChange(to: newSize, from: frame.size)
            super.setFrameSize(newSize)
        }

        override func layout() {
            super.layout()
            layoutDidChange()
        }
    #endif
}
