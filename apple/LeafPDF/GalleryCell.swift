import SwiftUI

/// A Gallery grid cell: an A4-portrait page area with a caption of up to 2
/// lines under it. The caption always reserves both lines, so cells in a row
/// line up whatever their text.
struct GalleryCell<Page: View>: View {
    let caption: String
    @ViewBuilder let page: Page

    /// A4 portrait.
    private static var pageAspect: CGFloat { 1 / 1.414 }

    var body: some View {
        VStack(spacing: 6) {
            page
                .aspectRatio(Self.pageAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
            Text(caption)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
        }
        .contentShape(.rect)
    }
}

extension ShapeStyle where Self == Color {
    /// The grey of a Document's placeholder and of the "+" cell.
    static var placeholderGrey: Color { Color.gray.opacity(0.3) }
}

/// A Document's cell. The placeholder stands in until the Cover exists.
struct DocumentCell: View {
    let document: LibraryDocument

    var body: some View {
        GalleryCell(caption: document.title) { Color.placeholderGrey }
    }
}

/// The first cell: a white "+" on the placeholder grey.
struct ImportCell: View {
    var body: some View {
        GalleryCell(caption: String(localized: "Import…")) {
            Color.placeholderGrey.overlay {
                Image(systemName: "plus")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
            }
        }
    }
}
