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
/// and a single tap clears the selection or, without one and unless it is on a link, calls `onSingleTap`. It reports when it has opened and
/// whenever it scrolls, so the Reader can save Reading Progress.
///
/// Highlights are drawn into the pages (`StyledDocument`); a Highlight with a
/// Note has a Note icon at its end, drawn above the pages at a constant size
/// (`NoteIconsView`), which opens the same popover when clicked or tapped. The selection can be
/// highlighted (`highlightSelection()`, also from the selection menu), which
/// reports its anchor, and never changes the File. A single click or tap on a
/// Highlight reports it (`onHighlightTap`); drags and long presses still select.
///
/// Page Notes have a Note icon at their spot, centred on it. A right-click (macOS)
/// or long press (iOS) on an empty spot offers "Add Note", which reports the Place
/// to `onAddNote`. A click or tap on a page Note's icon reports it (`onPageNoteTap`).
///
/// A Jump goes to a Place and remembers where the viewport was, so that Back
/// can return there. Only the latest Jump is remembered, and only for as long
/// as the view lives, unless it is carried over by a `viewState` (a Tab's).
/// Following a link to a place in the Document is a Jump; links to web pages
/// keep PDFKit's behaviour and are not. A Document Search session counts as
/// one Jump from where the search started.
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
    /// How to open, until the first layout of a Document.
    private var openingState: ReaderViewState?
    private var hasOpened = false

    /// How the pages are drawn. Changing it redraws them, keeping the viewport.
    /// Set it after the Document, which must be a `StyledDocument`.
    var pageAppearance: PageAppearance {
        get { (document as? StyledDocument)?.appearance ?? .light }
        set {
            guard newValue != pageAppearance, let styled = document as? StyledDocument else { return }
            styled.appearance = newValue
            redrawPages()
            #if os(iOS)
                styleBackdrops()
            #endif
        }
    }

    /// The Highlights drawn into the pages, oldest first. Changing them redraws the pages,
    /// keeping the viewport. Set it after the Document, which must be a `StyledDocument`.
    var highlights: [Highlight] = [] {
        didSet {
            guard highlights != oldValue else { return }
            noteIcons.refresh()
            // Notes aren't drawn into the pages.
            guard highlights.map(\.look) != oldValue.map(\.look), let styled = document as? StyledDocument else {
                return
            }
            styled.highlights = highlights
            redrawPages()
        }
    }

    /// Redraws the pages, keeping the viewport.
    private func redrawPages() {
        #if os(iOS)
            // `layoutDocumentView()` keeps the drawn tiles on iOS: only scrolling
            // to new ones would show the change. PDFKit's own layers (tiles
            // among them) redraw themselves; plain ones would lose their contents.
            func redraw(_ layer: CALayer) {
                if type(of: layer) != CALayer.self { layer.setNeedsDisplay() }
                layer.sublayers?.forEach(redraw)
            }
            documentView.map { redraw($0.layer) }
        #else
            layoutDocumentView()
        #endif
    }

    /// The page Notes, each with a Note icon above the pages.
    var pageNotes: [PageNote] = [] {
        didSet { if pageNotes != oldValue { noteIcons.refresh() } }
    }

    /// The color of page Notes' icons. The owner sets it to the core's built-in yellow;
    /// this is only a stand-in until then.
    var pageNoteColor = RGB(1, 0.92, 0.24) {
        didSet { if pageNoteColor != oldValue { noteIcons.refresh() } }
    }

    /// The Note icons, above the pages. Hidden from hit-testing.
    private lazy var noteIcons = NoteIconsView(reader: self)

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
    /// Called when the reader asks for a page Note at a Place.
    var onAddNote: (Place) -> Void = { _ in }
    /// Called when the reader clicks or taps the icon of a page Note, with the
    /// point as for `onHighlightTap`.
    var onPageNoteTap: (PageNote, CGPoint) -> Void = { _, _ in }
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
    func open(at place: Place) { open(from: ReaderViewState(place: place)) }

    /// Makes the Document, once it is set and laid out, open as `state` was
    /// captured: same place, zoom and Back place. Call before setting the Document.
    func open(from state: ReaderViewState) { openingState = state }

    /// The place, zoom and Back place as they are now, to reopen from with
    /// `open(from:)`. Nil until the Document is laid out.
    var viewState: ReaderViewState? {
        guard let place = topOfViewport, let range = zoomRange else { return nil }
        return ReaderViewState(place: place, zoom: scaleFactor / range.fitToWidth, backPlace: backPlace)
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

    /// Where the Note icon of `highlight` is, in the view's coordinates: at the
    /// end of its last rectangle, centred on its top-right corner so it covers
    /// little text, at the same size on screen at any zoom. Nil without a Note.
    func noteIconRect(of highlight: Highlight) -> CGRect? {
        guard highlight.note != nil, let last = highlight.anchor.pages.last, let rect = last.rects.last,
            let page = document?.page(at: last.pageIndex)
        else { return nil }
        let corner = convert(CGPoint(x: rect.maxX, y: rect.maxY), from: page)
        let side = NoteIconsView.size
        return CGRect(x: corner.x - side / 2, y: corner.y - side / 2, width: side, height: side)
    }

    /// The Highlight whose Note icon is at `point`, in the view's coordinates:
    /// the newest where several overlap. Nil where there is none.
    func noteIcon(at point: CGPoint) -> Highlight? {
        highlights.last { noteIconRect(of: $0)?.contains(point) == true }
    }

    /// Reports the page Note icon, Highlight Note icon or Highlight at `point`,
    /// in that order, to `onPageNoteTap` or `onHighlightTap`. Returns whether
    /// there was one.
    @discardableResult
    func reportMarkupTap(at point: CGPoint) -> Bool {
        if let note = pageNote(at: point) {
            onPageNoteTap(note, fromTopLeft(point))
        } else if let highlight = noteIcon(at: point) ?? highlight(at: point) {
            onHighlightTap(highlight, fromTopLeft(point))
        } else {
            return false
        }
        return true
    }

    /// `point`, given in the view's coordinates, with the origin at the top-left.
    func fromTopLeft(_ point: CGPoint) -> CGPoint {
        #if os(iOS)
            point
        #else
            CGPoint(x: point.x, y: bounds.height - point.y)
        #endif
    }

    // MARK: Page Notes

    /// Where the Note icon of `note` is, in the view's coordinates: centred on
    /// its spot, at the same size on screen at any zoom.
    func noteIconRect(of note: PageNote) -> CGRect? {
        guard let page = document?.page(at: note.place.pageIndex) else { return nil }
        let spot = convert(note.place.point, from: page)
        let side = NoteIconsView.size
        return CGRect(x: spot.x - side / 2, y: spot.y - side / 2, width: side, height: side)
    }

    /// The page Note whose icon is at `point`, in the view's coordinates: the
    /// newest where several overlap. Nil where there is none.
    func pageNote(at point: CGPoint) -> PageNote? {
        pageNotes.last { noteIconRect(of: $0)?.contains(point) == true }
    }

    /// Every Note icon, in the view's coordinates, in its color; also those
    /// scrolled out of view.
    var noteIconsToDraw: [(rect: CGRect, color: RGB)] {
        highlights.compactMap { h in noteIconRect(of: h).map { ($0, h.color) } }
            + pageNotes.compactMap { n in noteIconRect(of: n).map { ($0, pageNoteColor) } }
    }

    /// The Place at `point`, in the view's coordinates. Nil off the pages.
    func place(at point: CGPoint) -> Place? {
        guard let document, let page = page(for: point, nearest: false) else { return nil }
        return Place(pageIndex: document.index(for: page), point: convert(point, to: page))
    }

    /// Whether nothing is at `point`, in the view's coordinates, but page: no
    /// text, link, Highlight or Note icon.
    func isEmptySpot(at point: CGPoint) -> Bool {
        guard let page = page(for: point, nearest: false), !hasLink(at: point),
            pageNote(at: point) == nil, noteIcon(at: point) == nil, highlight(at: point) == nil
        else { return false }
        return page.characterIndex(at: convert(point, to: page)) == NSNotFound
    }

    /// Reports the Place at `point`, in the view's coordinates, to `onAddNote`.
    /// Does nothing off the pages.
    func addNote(at point: CGPoint) {
        if let place = place(at: point) { onAddNote(place) }
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
        if noteIcons.superview == nil { addSubview(noteIcons) }
        // It may have been made before the view had a size.
        noteIcons.frame = bounds
        noteIcons.refresh()
        if !hasOpened {
            hasOpened = true
            if let state = openingState {
                openingState = nil
                scaleFactor = range.clamped(range.fitToWidth * state.zoom)
                go(to: state.place)
                backPlace = state.backPlace
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
        /// A tap that stops a scroll only stops it: by the time the tap is
        /// recognized the scroll has already stopped, so this too is decided at touch-down.
        private final class SingleTapFilter: NSObject, UIGestureRecognizerDelegate {
            private weak var view: ReaderPDFView?

            /// Where the current long press went down.
            private var pressPoint: CGPoint?

            init(view: ReaderPDFView) { self.view = view }

            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
                guard let view else { return false }
                if gestureRecognizer is UITapGestureRecognizer && view.isScrolling { return false }
                let point = touch.location(in: view)
                if gestureRecognizer is UILongPressGestureRecognizer { pressPoint = point }
                return !view.hasLink(at: point)
            }

            /// Asked lazily, once the long press has its touch.
            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
            ) -> Bool {
                guard gestureRecognizer is UILongPressGestureRecognizer, let view, let pressPoint else { return false }
                return view.addNotePressPreempts(other, at: pressPoint)
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool { true }
        }

        // Recognizers hold their delegate weakly.
        private var singleTapFilter: SingleTapFilter?

        private var scrollObservation: NSKeyValueObservation?

        /// Whether the pages are still moving after the finger left them.
        fileprivate var isScrolling: Bool {
            subviews.lazy.compactMap { $0 as? UIScrollView }.first?.isDecelerating ?? false
        }

        /// The edit menu offering "Add Note", and the spot it was asked at.
        private lazy var addNoteMenu = UIEditMenuInteraction(delegate: self)
        fileprivate var notePoint: CGPoint?

        private func observeScrolling() {
            letScrollIndicatorScrub()
            scrollObservation = subviews.lazy.compactMap { $0 as? UIScrollView }.first?
                .observe(\.contentOffset) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.styleBackdrops()
                        self?.noteIcons.refresh()
                        self?.onScroll()
                    }
                }
        }

        /// The native scroll indicator can be grabbed with a press while it shows, then
        /// dragged to scrub through the Document. PDFKit's and our presses, and text
        /// selection, would take that press first, so they wait for the indicator's,
        /// which fails at once off the indicator.
        private func letScrollIndicatorScrub() {
            guard let scrollView = subviews.lazy.compactMap({ $0 as? UIScrollView }).first, let documentView
            else { return }
            // The scroll view's only long presses are its indicators'.
            let indicatorPresses = (scrollView.gestureRecognizers ?? []).filter { $0 is UILongPressGestureRecognizer }
            let presses = ((gestureRecognizers ?? []) + (documentView.gestureRecognizers ?? [])).filter {
                $0 is UILongPressGestureRecognizer || $0 is UIPanGestureRecognizer
            }
            for press in presses {
                for indicatorPress in indicatorPresses { press.require(toFail: indicatorPress) }
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

        /// Until a page is drawn, PDFKit shows a backdrop: white, with a light preview
        /// of the page. On Dark Pages that flashes, so there the backdrop is hidden
        /// and the page shows plain paper until drawn. Run whenever PDFKit may have
        /// added pages.
        private func styleBackdrops() {
            guard let documentView else { return }
            let paper: UIColor? =
                if case .dark(let colors) = pageAppearance {
                    UIColor(red: colors.paper.r, green: colors.paper.g, blue: colors.paper.b, alpha: 1)
                } else { nil }
            for pageView in documentView.subviews where pageView.backgroundColor != paper {
                pageView.backgroundColor = paper
                // The backdrop: the opaque layer right under the page's own layer.
                for pageLayer in pageView.layer.sublayers ?? [] {
                    for layer in pageLayer.sublayers ?? [] where layer.backgroundColor?.alpha == 1 {
                        layer.isHidden = paper != nil
                    }
                }
            }
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
            // Pages span the full width: PDFKit's side margins frame Dark Pages in the light background.
            pageBreakMargins.left = 0
            pageBreakMargins.right = 0
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(didDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            // A double-tap zooms, so a single tap only counts once it can no
            // longer become one.
            // PDFKit's own tap handling (links, selection) must keep working.
            let filter = SingleTapFilter(view: self)
            singleTapFilter = filter
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress))
            longPress.delegate = filter
            addGestureRecognizer(longPress)
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(didSingleTap))
            singleTap.require(toFail: doubleTap)
            // A long press selects (or offers "Add Note"); lifting the finger
            // must not also open a popover or toggle Immersive Mode.
            singleTap.require(toFail: longPress)
            singleTap.delegate = filter
            addGestureRecognizer(singleTap)
            addInteraction(addNoteMenu)
            NotificationCenter.default.addObserver(
                self, selector: #selector(selectionDidChange), name: .PDFViewSelectionChanged, object: self)
            NotificationCenter.default.addObserver(
                self, selector: #selector(scaleDidChange), name: .PDFViewScaleChanged, object: self)
        }

        @objc private func scaleDidChange(_ notification: Notification) { noteIcons.refresh() }

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
            insetBySafeArea()
            styleBackdrops()
            layoutDidChange()
        }

        /// Insets the pages by the safe area without moving them. Bars come and go
        /// over the pages (Immersive Mode), changing only the safe area; adjusting
        /// for it itself, UIKit's scroll view would move the pages along with the bars.
        private func insetBySafeArea() {
            guard let scrollView = subviews.lazy.compactMap({ $0 as? UIScrollView }).first else { return }
            scrollView.contentInsetAdjustmentBehavior = .never
            let insets = UIEdgeInsets(top: safeAreaInsets.top, left: 0, bottom: safeAreaInsets.bottom, right: 0)
            guard scrollView.contentInset != insets else { return }
            scrollView.contentInset = insets
            // Until it opens, the Document starts below the bars.
            if !hasOpened { scrollView.contentOffset.y = -insets.top }
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
            singleTap(at: tap.location(in: self))
        }

        /// A single tap at `point`: with a selection it only clears it, as our
        /// recognizers keep PDFKit from doing so; otherwise it reports any
        /// markup there, or else calls `onSingleTap`.
        func singleTap(at point: CGPoint) {
            if currentSelection != nil {
                clearSelection()
                return
            }
            if reportMarkupTap(at: point) { return }
            onSingleTap()
        }

        /// Whether `other` must wait for a long press at `point` to fail. At an
        /// empty spot PDFKit would select the nearest text and replace "Add Note"
        /// with its own menu; so there its gestures wait, but scrolling never does.
        func addNotePressPreempts(_ other: UIGestureRecognizer, at point: CGPoint) -> Bool {
            guard let otherView = other.view, otherView.isDescendant(of: self), !(otherView is UIScrollView)
            else { return false }
            return isEmptySpot(at: point)
        }

        /// Offers "Add Note" at an empty spot; elsewhere PDFKit's own long press selects.
        @objc private func didLongPress(_ press: UILongPressGestureRecognizer) {
            let point = press.location(in: self)
            guard press.state == .began, isEmptySpot(at: point) else { return }
            notePoint = point
            addNoteMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
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

        @objc private func didScroll(_ notification: Notification) {
            noteIcons.refresh()
            onScroll()
        }

        /// Adds "Highlight" to the context menu of a selection, and "Add Note" to
        /// that of an empty spot.
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let menu = super.menu(for: event) else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            if selectionAnchor != nil {
                insert("Highlight", #selector(highlightFromMenu), into: menu)
            } else if isEmptySpot(at: point) {
                insert("Add Note", #selector(addNoteFromMenu), into: menu).representedObject = NSValue(point: point)
            }
            return menu
        }

        /// The item for `action` at the top of `menu`, new unless it already has one.
        @discardableResult
        private func insert(_ title: String, _ action: Selector, into menu: NSMenu) -> NSMenuItem {
            if let existing = menu.items.first(where: { $0.action == action }) { return existing }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return item
        }

        @objc private func highlightFromMenu(_ sender: Any?) { highlightSelection() }

        @objc private func addNoteFromMenu(_ sender: NSMenuItem) {
            if let point = (sender.representedObject as? NSValue)?.pointValue { addNote(at: point) }
        }

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
            NotificationCenter.default.addObserver(
                self, selector: #selector(scaleDidChange), name: .PDFViewScaleChanged, object: self)
        }

        @objc private func scaleDidChange(_ notification: Notification) { noteIcons.refresh() }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        @objc private func didClick(_ click: NSClickGestureRecognizer) {
            _ = reportMarkupTap(at: click.location(in: self))
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

extension Highlight {
    /// What is drawn into the pages: everything but the Note.
    fileprivate struct Look: Equatable {
        let id: String
        let anchor: HighlightAnchor
        let color: RGB
    }

    fileprivate var look: Look { Look(id: id, anchor: anchor, color: color) }
}

#if os(iOS)
    extension ReaderPDFView: @MainActor UIEditMenuInteractionDelegate {
        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let point = notePoint else { return nil }
            let add = UIAction(title: "Add Note", image: UIImage(systemName: "note.text.badge.plus")) { [weak self] _ in
                self?.addNote(at: point)
            }
            return UIMenu(children: [add])
        }
    }
#endif
