import PDFKit

/// Lets window-level commands (macOS menu) reach the Reader's `PDFView`.
@MainActor
final class ReaderHandle {
    fileprivate(set) weak var view: ReaderPDFView?
}

/// A `PDFView` zoomable from fit-to-width to 5× (`ZoomRange`) that keeps
/// your place: the content at the top of the viewport stays put when the view
/// is resized or rotated, and when zooming with the keyboard. PDFKit's own
/// pinch gesture does the pinch zooming, so the content under the fingers
/// stays put; on iOS a double-tap toggles between fit-to-width and zoomed in,
/// and a single tap calls `onSingleTap`. It reports when it has opened and
/// whenever it scrolls, so the Reader can save Reading Progress.
///
/// A Jump goes to a Place and remembers where the viewport was, so that Back
/// can return there. Only the latest Jump is remembered, and only for as long
/// as the view lives.
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
    /// Where to open, until the first layout of a Document.
    private var openingPlace: Place?
    private var hasOpened = false

    /// Called on a single tap on the page (iOS only; macOS clicks never fire it).
    var onSingleTap: () -> Void = {}
    /// Called once, after the Document is first laid out at fit-to-width and
    /// scrolled to its opening Place.
    var onOpen: () -> Void = {}
    /// Called whenever the viewport scrolls, however it was moved: often, so keep it cheap.
    var onScroll: () -> Void = {}
    /// Called when the Back place appears, changes or goes, with its printed
    /// page number; nil when there is none.
    var onBackChange: (String?) -> Void = { _ in }

    /// Where Back returns to: the top of the viewport before the latest Jump.
    /// Nil before any Jump and after Back.
    private(set) var backPlace: Place? {
        didSet {
            guard backPlace != oldValue else { return }
            onBackChange(backPlace.flatMap { document?.printedPageNumber(at: $0.pageIndex) })
        }
    }

    convenience init(handle: ReaderHandle) {
        self.init(frame: .zero)
        handle.view = self
    }

    /// Makes the Document, once it is set and laid out, open with `place` at the
    /// top of the viewport at fit-to-width. Call before setting the Document.
    func open(at place: Place) { openingPlace = place }

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

    /// The content at the viewport's top-left corner. Nil without a Document.
    // Not `currentDestination`: on iOS it is the viewport's bottom-left.
    var topOfViewport: Place? {
        guard let document, let page = page(for: viewportTopLeft, nearest: true) else { return nil }
        return Place(pageIndex: document.index(for: page), point: convert(viewportTopLeft, to: page))
    }

    /// Scrolls `place` to the viewport's top-left corner, as far as the
    /// Document's edges allow.
    func go(to place: Place) {
        guard let page = document?.page(at: place.pageIndex) else { return }
        #if os(iOS)
            scroll(place.point, on: page, to: viewportTopLeft)
        #else
            go(to: PDFDestination(page: page, at: place.point))
        #endif
    }

    /// Jump: goes to `place`, remembering the top of the viewport for `goBack()`
    /// in place of any earlier Back place. Does nothing if `place` is already
    /// at the top.
    func jump(to place: Place) {
        guard let top = topOfViewport, !place.isSameSpot(as: top) else { return }
        backPlace = top
        go(to: place)
    }

    /// Back: returns to the Back place at the current zoom and forgets it.
    /// Does nothing without one.
    func goBack() {
        guard let place = backPlace else { return }
        backPlace = nil
        go(to: place)
    }

    /// Remembers the viewport; call just before the view's size changes.
    private func sizeWillChange(to size: CGSize, from oldSize: CGSize) {
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
        if !hasOpened {
            hasOpened = true
            if let place = openingPlace {
                openingPlace = nil
                scaleFactor = range.fitToWidth
                go(to: place)
            }
            observeScrolling()
            onOpen()
        } else if let viewpoint {
            self.viewpoint = nil
            scaleFactor = range.rescaled(viewpoint.scale, from: viewpoint.range)
            go(to: viewpoint.place)
        }
    }

    #if os(iOS)
        /// PDFView is already the delegate of its own recognizers, so ours gets
        /// a separate one rather than overriding PDFView's.
        private final class SimultaneousTaps: NSObject, UIGestureRecognizerDelegate {
            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool { true }
        }

        // Recognizers hold their delegate weakly.
        private static let simultaneousTaps = SimultaneousTaps()

        private var scrollObservation: NSKeyValueObservation?

        private func observeScrolling() {
            scrollObservation = subviews.lazy.compactMap { $0 as? UIScrollView }.first?
                .observe(\.contentOffset) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.onScroll() }
                }
        }

        /// Below any part of the view hidden behind bars.
        private var viewportTopLeft: CGPoint { CGPoint(x: 0, y: safeAreaInsets.top) }

        /// Scrolls so that `point` on `page` lands at `viewPoint`, as far as the
        /// Document's edges allow. PDFKit's `go(to:)` can't do this: on iOS it
        /// lands up to a page off, so this moves PDFKit's scroll view directly.
        private func scroll(_ point: CGPoint, on page: PDFPage, to viewPoint: CGPoint) {
            guard let scrollView = subviews.lazy.compactMap({ $0 as? UIScrollView }).first
            else { return }
            let current = convert(point, from: page)
            let inset = scrollView.adjustedContentInset
            let minimum = CGPoint(x: -inset.left, y: -inset.top)
            let maximum = CGPoint(
                x: scrollView.contentSize.width + inset.right - scrollView.bounds.width,
                y: scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
            var offset = scrollView.contentOffset
            offset.x = min(max(offset.x + current.x - viewPoint.x, minimum.x), max(maximum.x, minimum.x))
            offset.y = min(max(offset.y + current.y - viewPoint.y, minimum.y), max(maximum.y, minimum.y))
            scrollView.contentOffset = offset
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(didDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            // A double-tap zooms, so a single tap only counts once it can no
            // longer become one.
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(didSingleTap))
            singleTap.require(toFail: doubleTap)
            // PDFKit's own tap handling (links, selection) must keep working.
            singleTap.delegate = Self.simultaneousTaps
            addGestureRecognizer(singleTap)
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
            scroll(anchor, on: page, to: point)
        }

        @objc private func didSingleTap(_ tap: UITapGestureRecognizer) {
            onSingleTap()
        }

        @objc private func didDoubleTap(_ tap: UITapGestureRecognizer) {
            guard let range = zoomRange else { return }
            zoom(to: range.doubleTapTarget(from: scaleFactor), keeping: tap.location(in: self))
        }
    #else
        /// PDFView isn't flipped: its top edge is at `bounds.maxY`.
        private var viewportTopLeft: CGPoint { CGPoint(x: 0, y: bounds.maxY) }

        private func observeScrolling() {
            guard let clip = documentView?.enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: clip)
        }

        @objc private func didScroll(_ notification: Notification) { onScroll() }

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
