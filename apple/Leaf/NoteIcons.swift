import PDFKit

#if os(iOS)
    typealias PlatformView = UIView
    typealias PlatformScrollView = UIScrollView
#else
    typealias PlatformView = NSView
    typealias PlatformScrollView = NSScrollView
#endif

/// Draws the Note icons of a `ReaderPDFView`'s Highlights and page Notes above its pages, never
/// reversed on Dark Pages. It takes no touches or clicks: the view reports them.
///
/// On iOS the icons sit in PDFKit's zooming view, one view each, so they zoom and
/// scroll with the pages, also mid-pinch. On macOS one view over the pages draws them all.
final class NoteIconsView: PlatformView {
    /// Side of an icon in page space, about a line of text: it zooms with the page.
    static let size: CGFloat = 10

    private weak var reader: ReaderPDFView?

    init(reader: ReaderPDFView) {
        self.reader = reader
        super.init(frame: .zero)
        #if os(iOS)
            isUserInteractionEnabled = false
        #else
            autoresizingMask = [.width, .height]
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if os(iOS)
        /// Places the icons again, after the Highlights, the layout or the zoom changed.
        func refresh() {
            guard let reader, let pages = reader.documentView else { return }
            if superview !== pages { pages.addSubview(self) }
            frame = pages.bounds
            pagesScrolled()
            let toDraw = reader.noteIconsToDraw
            let scale = reader.traitCollection.displayScale * reader.scaleFactor
            var icons = subviews.compactMap { $0 as? IconView }
            for extra in icons.dropFirst(toDraw.count) { extra.removeFromSuperview() }
            while icons.count < toDraw.count {
                icons.append(IconView())
                addSubview(icons[icons.count - 1])
            }
            for (icon, (rect, color)) in zip(icons, toDraw) {
                icon.frame = convert(rect, from: reader)
                icon.color = color
                if icon.contentScaleFactor != scale {
                    icon.contentScaleFactor = scale
                    icon.setNeedsDisplay()
                }
            }
        }

        /// Keeps the icons above pages PDFKit adds while scrolling.
        func pagesScrolled() {
            if let pages = superview, pages.subviews.last !== self { pages.bringSubviewToFront(self) }
        }

        /// One Note icon, drawn at its frame.
        private final class IconView: UIView {
            var color = RGB(0, 0, 0) {
                didSet { if color != oldValue { setNeedsDisplay() } }
            }

            init() {
                super.init(frame: .zero)
                isOpaque = false
                backgroundColor = .clear
                isUserInteractionEnabled = false
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

            override func draw(_ rect: CGRect) {
                guard let context = UIGraphicsGetCurrentContext() else { return }
                NoteIconsView.paint(bounds, color, in: context)
            }
        }
    #else
        /// Whether the last drawing drew no icons, so another without any can be skipped.
        private var isBlank = true

        /// Draws the icons again, after the pages moved or the Highlights changed.
        /// Cheap while there are none: it is called on every scroll.
        func refresh() {
            guard let reader else { return }
            if superview !== reader { reader.addSubview(self) }
            frame = reader.bounds
            let blank = !reader.hasNoteIcons
            guard !(blank && isBlank) else { return }
            isBlank = blank
            needsDisplay = true
        }

        func pagesScrolled() { refresh() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let reader, let context = NSGraphicsContext.current?.cgContext else { return }
            for (rect, color) in reader.noteIconsToDraw where rect.intersects(dirtyRect) {
                Self.paint(rect, color, in: context)
            }
        }
    #endif

    /// Paints an icon filling `rect`: a rounded square with lines of text.
    private static func paint(_ rect: CGRect, _ color: RGB, in context: CGContext) {
        // Drawn on an 18-unit grid.
        let unit = rect.width / 18
        let shape = CGPath(roundedRect: rect, cornerWidth: 4 * unit, cornerHeight: 4 * unit, transform: nil)
        context.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
        context.addPath(shape)
        context.fillPath()
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.3))
        context.setLineWidth(unit)
        context.addPath(shape)
        context.strokePath()
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        context.setLineWidth(1.5 * unit)
        for offset in [-4.0, 0, 4] {
            context.move(to: CGPoint(x: rect.minX + 4 * unit, y: rect.midY + offset * unit))
            context.addLine(to: CGPoint(x: rect.maxX - 4 * unit, y: rect.midY + offset * unit))
        }
        context.strokePath()
    }
}
