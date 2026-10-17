import PDFKit
import SwiftUI

/// Shows one Document's pages in a single continuously scrolling vertical
/// column, titled with the Document's Title. Must be pushed onto a
/// `NavigationStack`, which provides the back chevron and iOS edge swipe.
struct ReaderView: View {
    let document: PDFDocument

    var body: some View {
        PDFKitView(document: document)
            .navigationTitle(document.title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #else
                .background(BackShortcut())
            #endif
    }
}

#if os(macOS)
    /// Invisible button that makes ⌘[ pop the Reader, as in other macOS apps.
    private struct BackShortcut: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            Button("Back", action: dismiss.callAsFunction)
                .keyboardShortcut("[", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
#endif

/// PDFKit's native viewer, laid out as one vertical, continuously scrolling
/// column. Opens at fit-to-width; see `ReaderPDFView` for zooming.
private struct PDFKitView {
    let document: PDFDocument

    @MainActor
    fileprivate func makePDFView() -> PDFView {
        let view = ReaderPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.document = document
        return view
    }
}

/// A `PDFView` zoomable from fit-to-width to 5× that (`ZoomRange`). PDFKit's
/// own pinch gesture does the zooming, so the content under the fingers stays
/// put; on iOS a double-tap toggles between fit-to-width and zoomed in.
private final class ReaderPDFView: PDFView {
    /// PDFKit's fit-to-width changes with the view's width, so the limits are
    /// refreshed on every layout. It is 0 until the first layout.
    private func updateZoomLimits() {
        let fit = scaleFactorForSizeToFit
        guard fit > 0 else { return }
        let range = ZoomRange(fitToWidth: fit)
        if minScaleFactor != range.minimum { minScaleFactor = range.minimum }
        if maxScaleFactor != range.maximum { maxScaleFactor = range.maximum }
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

        override func layoutSubviews() {
            super.layoutSubviews()
            updateZoomLimits()
        }

        /// Zooms to `scale`, keeping the content at `point` (in view coordinates)
        /// under that point.
        private func zoom(to scale: CGFloat, keeping point: CGPoint) {
            guard let page = page(for: point, nearest: true) else { return }
            let anchor = convert(point, to: page)
            scaleFactor = scale
            // Scrolling puts a destination at the view's top-left, so aim for the
            // page-space point that has the same offset from the anchor as the
            // view's corner has from `point`.
            let anchorNow = convert(anchor, from: page)
            let corner = CGPoint(x: anchorNow.x - point.x, y: anchorNow.y - point.y)
            go(to: PDFDestination(page: page, at: convert(corner, to: page)))
        }

        @objc private func didDoubleTap(_ tap: UITapGestureRecognizer) {
            let fit = scaleFactorForSizeToFit
            guard fit > 0 else { return }
            let target = ZoomRange(fitToWidth: fit).doubleTapTarget(from: scaleFactor)
            zoom(to: target, keeping: tap.location(in: self))
        }
    #else
        override func layout() {
            super.layout()
            updateZoomLimits()
        }
    #endif
}

#if os(iOS)
    extension PDFKitView: UIViewRepresentable {
        func makeUIView(context: Context) -> PDFView { makePDFView() }
        func updateUIView(_ view: PDFView, context: Context) {}
    }
#else
    extension PDFKitView: NSViewRepresentable {
        func makeNSView(context: Context) -> PDFView { makePDFView() }
        func updateNSView(_ view: PDFView, context: Context) {}
    }
#endif
