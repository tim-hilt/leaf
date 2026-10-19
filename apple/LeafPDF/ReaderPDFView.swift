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
/// and a single tap, unless it is on a link, calls `onSingleTap`. It reports when it has opened and
/// whenever it scrolls, so the Reader can save Reading Progress.
///
/// Highlights are drawn into the pages (`StyledDocument`). The selection can be
/// highlighted (`highlightSelection()`, also from the selection menu), which
/// reports its anchor, and never changes the File. A single click or tap on a
/// Highlight reports it (`onHighlightTap`); drags and long presses still select.
///
/// A Jump goes to a Place and remembers where the viewport was, so that Back
/// can return there. Only the latest Jump is remembered, and only for as long
/// as the view lives. Following a link to a place in the Document is a Jump;
/// links to web pages keep PDFKit's behaviour and are not. A Document Search
/// session counts as one Jump from where the search started.
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

    /// How the pages are drawn. Changing it redraws them, keeping the viewport.
    /// Set it after the Document, which must be a `StyledDocument`.
    var pageAppearance: PageAppearance {
        get { (document as? StyledDocument)?.appearance ?? .light }
        set {
            guard newValue != pageAppearance, let styled = document as? StyledDocument else { return }
            styled.appearance = newValue
            layoutDocumentView()
        }
    }

    /// The Highlights drawn into the pages, oldest first. Changing them redraws the pages,
    /// keeping the viewport. Set it after the Document, which must be a `StyledDocument`.
    var highlights: [Highlight] = [] {
        didSet {
            guard highlights != oldValue, let styled = document as? StyledDocument else { return }
            styled.highlights = highlights
            layoutDocumentView()
        }
    }

    /// Called on a single tap on the page (iOS only; macOS clicks never fire it).
    var onSingleTap: () -> Void = {}
    /// Called once, after the Document is first laid out at fit-to-width and
    /// scrolled to its opening Place.
    var onOpen: () -> Void = {}
    /// Called whenever the viewport scrolls, however it was moved: often, so keep it cheap.
    var onScroll: () -> Void = {}
    /// Called with the anchor of the selection when the reader highlights it.
    var onHighlight: (HighlightAnchor) -> Void = { _ in }
    /// Called when the reader clicks or taps a Highlight (the newest, where they
    /// overlap) at a point, given in the view's coordinates with the origin at
    /// the top-left.
    var onHighlightTap: (Highlight, CGPoint) -> Void = { _, _ in }
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

    /// The matches of the Document Search that is going on, for the results list.
    private(set) var results = SearchResults()

    convenience init(handle: ReaderHandle, results: SearchResults = SearchResults()) {
        self.init(frame: .zero)
        handle.view = self
        self.results = results
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

    /// Where the current Document Search session started; nil outside a session.
    private var searchStart: Place?

    /// Starts a Document Search session, called when the find bar opens. Until
    /// `endSearchSession()`, every `reveal` that moves the view makes the
    /// current top of the viewport the Back place, so the session is one Jump:
    /// Back returns to where the search started, also after an earlier Back.
    func beginSearchSession() { searchStart = topOfViewport }

    /// Ends the Document Search session, called when the find bar closes. The
    /// Back place it recorded stays.
    func endSearchSession() { searchStart = nil }

    /// Scrolls a Document Search match into view, a third of the way down the
    /// viewport; does nothing if it is already fully in view. Within a search
    /// session the move is part of one Jump; see `beginSearchSession()`.
    func reveal(_ selection: PDFSelection) {
        guard let page = selection.pages.first, let document, let top = topOfViewport else { return }
        let rect = selection.bounds(for: page)
        let viewRect = convert(rect, from: page)
        guard !viewportRect.contains(viewRect) else { return }
        // Keeps the horizontal scroll, unless the match is off to the side.
        let fitsAcross = viewportRect.minX <= viewRect.minX && viewRect.maxX <= viewportRect.maxX
        let x = fitsAcross ? top.point.x : rect.minX - 20 / scaleFactor
        let y = rect.maxY + viewportRect.height / 3 / scaleFactor
        if let searchStart { backPlace = searchStart }
        go(to: Place(pageIndex: document.index(for: page), point: CGPoint(x: x, y: y)))
    }

    // MARK: Highlights

    /// The selection as an anchor: its line rectangles per page in page space,
    /// and its text. Nil without a selection, or one without text.
    var selectionAnchor: HighlightAnchor? {
        guard let document, let selection = currentSelection, let text = selection.string, !text.isEmpty
        else { return nil }
        var pages: [HighlightAnchor.Page] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                let rect = line.bounds(for: page)
                guard index != NSNotFound, !rect.isEmpty else { continue }
                if let last = pages.last, last.pageIndex == index {
                    pages[pages.count - 1] = .init(pageIndex: index, rects: last.rects + [rect])
                } else {
                    pages.append(.init(pageIndex: index, rects: [rect]))
                }
            }
        }
        return pages.isEmpty ? nil : HighlightAnchor(pages: pages, quotedText: text)
    }

    /// Highlights the selection: reports its anchor to `onHighlight` and clears
    /// the selection. Does nothing without one.
    func highlightSelection() {
        guard let anchor = selectionAnchor else { return }
        clearSelection()
        onHighlight(anchor)
    }

    /// The Highlight at `point`, in the view's coordinates: the newest one
    /// where several overlap. Nil where there is none.
    func highlight(at point: CGPoint) -> Highlight? {
        guard let document, let page = page(for: point, nearest: false) else { return nil }
        let index = document.index(for: page)
        let spot = convert(point, to: page)
        return highlights.last { highlight in
            highlight.anchor.pages.contains { $0.pageIndex == index && $0.rects.contains { $0.contains(spot) } }
        }
    }

    /// Reports the Highlight at `point` to `onHighlightTap`. Returns whether there was one.
    private func reportHighlightTap(at point: CGPoint) -> Bool {
        guard let highlight = highlight(at: point) else { return false }
        #if os(iOS)
            onHighlightTap(highlight, point)
        #else
            onHighlightTap(highlight, CGPoint(x: point.x, y: bounds.height - point.y))
        #endif
        return true
    }

    // MARK: Links

    /// Whether a link (to the Document or the web) is at `point`, in the view's
    /// coordinates.
    func hasLink(at point: CGPoint) -> Bool { areaOfInterest(for: point).contains(.linkArea) }

    /// PDFKit performs a link's action here when the reader follows it. A link
    /// to a place in the Document becomes a Jump, so Back can undo it.
    override func perform(_ action: PDFAction) {
        guard let goTo = action as? PDFActionGoTo, let document,
            let place = Place(goTo.destination, in: document)
        else { return super.perform(action) }
        jump(to: place)
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
        /// a separate one rather than overriding PDFView's. It lets ours work
        /// alongside PDFKit's, and ignores taps that start on a link: PDFKit
        /// follows those, and that is all a link tap should do. It decides at
        /// touch-down, since following the link moves the page from under the finger.
        private final class SingleTapFilter: NSObject, UIGestureRecognizerDelegate {
            private weak var view: ReaderPDFView?

            init(view: ReaderPDFView) { self.view = view }

            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
                guard let view else { return false }
                return !view.hasLink(at: touch.location(in: view))
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool { true }
        }

        // Recognizers hold their delegate weakly.
        private var singleTapFilter: SingleTapFilter?

        private var scrollObservation: NSKeyValueObservation?

        private func observeScrolling() {
            scrollObservation = subviews.lazy.compactMap { $0 as? UIScrollView }.first?
                .observe(\.contentOffset) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.onScroll() }
                }
        }

        /// Below any part of the view hidden behind bars.
        private var viewportTopLeft: CGPoint { CGPoint(x: 0, y: safeAreaInsets.top) }

        /// The part of the view showing pages, in the view's coordinates.
        private var viewportRect: CGRect {
            CGRect(x: 0, y: safeAreaInsets.top, width: bounds.width, height: bounds.height - safeAreaInsets.top)
        }

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

        /// The native find bar over Document Search.
        private(set) lazy var find = DocumentFind(view: self, results: results)

        /// Shows the find bar; matches are revealed and marked as they are found.
        func presentFind() { find.present() }

        // The find bar is presented from the first responder.
        override var canBecomeFirstResponder: Bool { true }

        /// Adds "Highlight" to the edit menu of a selection.
        override func buildMenu(with builder: any UIMenuBuilder) {
            super.buildMenu(with: builder)
            guard builder.system == .context, selectionAnchor != nil else { return }
            let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                self?.highlightSelection()
            }
            builder.insertChild(UIMenu(options: .displayInline, children: [highlight]), atStartOfMenu: .standardEdit)
        }

        /// The edit menu is built from the selection as it is when the menu is rebuilt.
        @objc private func selectionDidChange(_ notification: Notification) {
            UIMenuSystem.context.setNeedsRebuild()
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
            let filter = SingleTapFilter(view: self)
            singleTapFilter = filter
            singleTap.delegate = filter
            addGestureRecognizer(singleTap)
            NotificationCenter.default.addObserver(
                self, selector: #selector(selectionDidChange), name: .PDFViewSelectionChanged, object: self)
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
            if reportHighlightTap(at: tap.location(in: self)) { return }
            onSingleTap()
        }

        @objc private func didDoubleTap(_ tap: UITapGestureRecognizer) {
            guard let range = zoomRange else { return }
            zoom(to: range.doubleTapTarget(from: scaleFactor), keeping: tap.location(in: self))
        }
    #else
        /// The native find bar over the Document's text.
        private(set) lazy var find = DocumentFind(view: self, results: results)

        /// Shows the find bar; the current match is the view's selection.
        func presentFind() { find.present() }

        /// PDFView isn't flipped: its top edge is at `bounds.maxY`.
        private var viewportTopLeft: CGPoint { CGPoint(x: 0, y: bounds.maxY) }

        /// The part of the view showing pages, in the view's coordinates.
        private var viewportRect: CGRect { bounds }

        private func observeScrolling() {
            guard let clip = documentView?.enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: clip)
        }

        @objc private func didScroll(_ notification: Notification) { onScroll() }

        /// Adds "Highlight" to the context menu of a selection.
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for: event)
            guard let menu, selectionAnchor != nil,
                !menu.items.contains(where: { $0.action == #selector(highlightFromMenu) })
            else { return menu }
            let item = NSMenuItem(title: "Highlight", action: #selector(highlightFromMenu), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc private func highlightFromMenu(_ sender: Any?) { highlightSelection() }

        /// Lets our click recognizers work alongside PDFKit's own mouse handling
        /// (selecting, links), and makes a single click wait for a possible double click.
        private final class ClickFilter: NSObject, NSGestureRecognizerDelegate {
            private weak var view: ReaderPDFView?
            var doubleClick: NSClickGestureRecognizer?

            init(view: ReaderPDFView) { self.view = view }

            func gestureRecognizer(
                _ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer
            ) -> Bool { true }

            func gestureRecognizer(
                _ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer
            ) -> Bool { other === doubleClick }

            /// Not on a link: PDFKit follows those.
            func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
                guard let view else { return false }
                return !view.hasLink(at: gestureRecognizer.location(in: view))
            }
        }

        // Recognizers hold their delegate weakly.
        private var clickFilter: ClickFilter?

        override init(frame: NSRect) {
            super.init(frame: frame)
            let filter = ClickFilter(view: self)
            clickFilter = filter
            let doubleClick = NSClickGestureRecognizer()
            doubleClick.numberOfClicksRequired = 2
            doubleClick.delegate = filter
            filter.doubleClick = doubleClick
            addGestureRecognizer(doubleClick)
            let click = NSClickGestureRecognizer(target: self, action: #selector(didClick))
            click.delegate = filter
            addGestureRecognizer(click)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        @objc private func didClick(_ click: NSClickGestureRecognizer) {
            _ = reportHighlightTap(at: click.location(in: self))
        }

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
