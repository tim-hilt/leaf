import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// The saved Cover of every Document: its first page as an image, one file per
/// Document ID in `folder`. Meant for the system Caches folder, so Covers are
/// never synced and the system may clear them; `cover(id:file:)` then renders
/// them again. Covers never go stale because Files never change (ADR-0007).
///
/// All methods read or write files and may render, so call them off the main
/// thread.
struct CoverStore: Sendable {
    let folder: URL
    /// Every Cover has this width: 300 pt at the screen scale. Smaller cells scale it down.
    private let pixelWidth: CGFloat

    @MainActor init(folder: URL) {
        self.folder = folder
        #if canImport(UIKit)
            pixelWidth = 300 * UIScreen.main.scale
        #else
            pixelWidth = 300 * (NSScreen.main?.backingScaleFactor ?? 2)
        #endif
    }

    /// The Cover of Document `id`: the saved one, or else page 1 of the PDF at
    /// `file`, rendered and saved. Nil if it can't be rendered.
    func cover(id: String, file: URL) -> CGImage? {
        if let saved = load(id) { return saved }
        guard let pdf = PDFDocument(url: file), let cover = render(pdf) else { return nil }
        save(cover, id: id)
        return cover
    }

    /// Page 1 of `pdf` as a Cover, not saved. Nil if the PDF has no pages.
    func render(_ pdf: PDFDocument) -> CGImage? { pdf.cover(pixelWidth: pixelWidth) }

    /// Saves `cover` for Document `id`. A failed write is ignored: the Cover is rendered again when needed.
    func save(_ cover: CGImage, id: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard
            let destination = CGImageDestinationCreateWithURL(
                url(id) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(
            destination, cover, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// Deletes the saved Cover of Document `id`, if any.
    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: url(id))
    }

    /// The saved Cover of Document `id`, or nil if there is none. Never renders.
    func saved(_ id: String) -> CGImage? { load(id) }

    private func load(_ id: String) -> CGImage? {
        CGImageSourceCreateWithURL(url(id) as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private func url(_ id: String) -> URL { folder.appending(path: "\(id).jpg") }
}

private extension PDFDocument {
    /// Page 1 as an image `pixelWidth` wide, or nil if there is no first page.
    func cover(pixelWidth: CGFloat) -> CGImage? {
        guard let page = page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0 else { return nil }
        let size = CGSize(width: pixelWidth, height: (pixelWidth * bounds.height / bounds.width).rounded())
        let image = page.thumbnail(of: size, for: .cropBox)
        #if canImport(UIKit)
            return image.cgImage
        #else
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}
