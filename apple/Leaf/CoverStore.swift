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

/// Where a Document's Cover comes from.
enum CoverSource: Sendable {
    /// The first page of the PDF at this URL.
    case pdf(URL)
    /// The EPUB's cover `image`, if it has one; else a plain Cover with its Title and Author.
    case epub(title: String, author: String?, image: @Sendable () -> Data?)
}

/// The saved Cover of every Document: an image, one file per
/// Document ID in `folder`. Meant for the system Caches folder, so Covers are
/// never synced and the system may clear them; `cover(id:source:)` then makes
/// them again. Covers never go stale because Files never change (ADR-0007).
///
/// All methods read or write files and may render, so call them off the main
/// thread.
struct CoverStore: Sendable {
    let folder: URL
    /// A Cover is this wide: 300 pt at the scale of the densest display the app
    /// is on when the store is made. Smaller cells scale it down. (An EPUB's image is no wider.)
    private let pixelWidth: CGFloat

    /// Make one per use rather than keeping it: Covers made later then suit the
    /// displays in use by then.
    @MainActor init(folder: URL) {
        self.folder = folder
        pixelWidth = 300 * Self.densestDisplayScale
    }

    /// The highest scale among the app's windows (iOS) or the attached screens
    /// (macOS). The saved Covers serve all of them. Before any window exists,
    /// that of the densest display of the platform.
    @MainActor private static var densestDisplayScale: CGFloat {
        #if canImport(UIKit)
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.traitCollection.displayScale }
                .max() ?? 3
        #else
            NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        #endif
    }

    /// The Cover of Document `id`: the saved one, or else one made from `source`
    /// and saved. Nil if it can't be made.
    func cover(id: String, source: CoverSource) -> CGImage? {
        if let saved = saved(id) { return saved }
        guard let cover = render(source) else { return nil }
        save(cover, id: id)
        return cover
    }

    private func render(_ source: CoverSource) -> CGImage? {
        switch source {
        case .pdf(let file):
            return PDFDocument(url: file).flatMap(render)
        case .epub(let title, let author, let image):
            return image().flatMap { EPUBCover.image(from: $0, pixelWidth: pixelWidth) }
                ?? EPUBCover.plain(title: title, author: author, pixelWidth: pixelWidth)
        }
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
    /// Decoded here, so drawing it on the main thread doesn't stall scrolling.
    func saved(_ id: String) -> CGImage? {
        CGImageSourceCreateWithURL(url(id) as CFURL, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
    }

    private func url(_ id: String) -> URL { folder.appending(path: "\(id).jpg") }
}

extension PDFDocument {
    /// Page 1 as an image `pixelWidth` wide, or nil if there is no first page.
    fileprivate func cover(pixelWidth: CGFloat) -> CGImage? {
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
