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
final class NoteIconsView: PlatformView {
    /// Side of an icon on screen, at any zoom.
    static let size: CGFloat = 18

    private weak var reader: ReaderPDFView?
    /// Whether the last drawing drew no icons, so another without any can be skipped.
    private var isBlank = true

    init(reader: ReaderPDFView) {
        self.reader = reader
        super.init(frame: reader.bounds)
        #if os(iOS)
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
            contentMode = .redraw
        #else
            autoresizingMask = [.width, .height]
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the icons again, after the pages moved or the Highlights changed.
    /// Cheap while there are none: it is called on every scroll.
    func refresh() {
        let blank = reader?.hasNoteIcons != true
        guard !(blank && isBlank) else { return }
        isBlank = blank
        #if os(iOS)
            setNeedsDisplay()
        #else
            needsDisplay = true
        #endif
    }

    private func paint(in context: CGContext, dirty: CGRect) {
        guard let reader else { return }
        for (rect, color) in reader.noteIconsToDraw where rect.intersects(dirty) {
            let shape = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
            context.addPath(shape)
            context.fillPath()
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.3))
            context.setLineWidth(1)
            context.addPath(shape)
            context.strokePath()
            // Lines of text.
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
            context.setLineWidth(1.5)
            for offset in [-4.0, 0, 4] {
                context.move(to: CGPoint(x: rect.minX + 4, y: rect.midY + offset))
                context.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.midY + offset))
            }
            context.strokePath()
        }
    }

    #if os(iOS)
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            paint(in: context, dirty: rect)
        }
    #else
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            paint(in: context, dirty: dirtyRect)
        }
    #endif
}
