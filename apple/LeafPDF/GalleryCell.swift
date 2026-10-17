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

extension View {
    /// Rings a cell with the accent colour while the keyboard highlight is on
    /// it. The ring sits in the gap between cells, so nothing shifts.
    func galleryHighlight(_ isOn: Bool) -> some View {
        overlay {
            if isOn {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(-6)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension ShapeStyle where Self == Color {
    /// The grey of a Document's placeholder and of the "+" cell.
    static var placeholderGrey: Color { Color.gray.opacity(0.3) }
}

/// A Document's cell. The placeholder stands in until the Cover exists, then
/// the Cover fades in. A saved Cover loads as soon as the cell appears; a new
/// one is rendered only while the Gallery is still (see `ScrollActivity`), and
/// that request is dropped if the cell scrolls away first. A Cover wider than
/// the cell's page shape is scaled to fit and sits on the bottom edge; the
/// space above it is transparent.
struct DocumentCell: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ScrollActivity.self) private var scroll
    let document: LibraryDocument
    @State private var cover: CGImage?

    var body: some View {
        GalleryCell(caption: document.title) {
            ZStack {
                if let cover {
                    Image(decorative: cover, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                } else {
                    Color.placeholderGrey.transition(.opacity)
                }
            }
            .animation(.default, value: cover == nil)
        }
        .task(id: LoadKey(document: document.id, galleryIsStill: scroll.isStill)) {
            if cover == nil { cover = await library.savedCover(for: document) }
            guard cover == nil, scroll.isStill else { return }
            cover = await library.cover(for: document)
        }
    }
}

/// Restarts a cell's Cover loading when its Document changes or the Gallery
/// stops (a new render may start) or starts moving (a pending one is dropped).
private struct LoadKey: Equatable {
    let document: String
    let galleryIsStill: Bool
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
