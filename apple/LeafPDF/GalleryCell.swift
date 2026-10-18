import SwiftUI

/// A Gallery grid cell: an A4-portrait page area with a caption of up to 2
/// lines under it. The caption always reserves both lines, so cells in a row
/// line up whatever their text. A `percentRead` shows a progress indicator
/// along the page area's bottom edge, over whatever `page` shows;
/// `pageIsDark` tells it which look that is, so it stays readable.
struct GalleryCell<Page: View>: View {
    let caption: String
    var percentRead: Int?
    var pageIsDark = false
    @ViewBuilder let page: Page

    /// A4 portrait.
    private static var pageAspect: CGFloat { 1 / 1.414 }

    var body: some View {
        VStack(spacing: 6) {
            page
                .aspectRatio(Self.pageAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    if let percentRead { ReadingProgressIndicator(percent: percentRead).environment(\.colorScheme, pageIsDark ? .dark : .light) }
                }
            Text(caption)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
        }
        .contentShape(.rect)
    }
}

/// A thin bar across the full width, filled to `percent`, with the number in
/// a capsule above it in the bottom-right corner. The material keeps the
/// number readable on a Cover: the cell sets the color scheme to the Cover's
/// look, which the interface's Theme may not match.
private struct ReadingProgressIndicator: View {
    let percent: Int
    private static let barHeight: CGFloat = 3

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("\(percent) %")
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(.trailing, 4)
            Rectangle().fill(.ultraThinMaterial)
                .overlay(alignment: .leading) {
                    GeometryReader { bar in
                        Rectangle().fill(Color.accentColor).frame(width: bar.size.width * Double(percent) / 100)
                    }
                }
                .frame(height: Self.barHeight)
        }
        .accessibilityHidden(true)
    }
}

extension LibraryDocument {
    /// What VoiceOver reads for the Document's cell: the Title, then how far
    /// it has been read if it was opened.
    var accessibilityLabel: String {
        guard let percentRead else { return title }
        return String(localized: "\(title), \(percentRead) % read")
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
/// the cell's page shape is scaled to fit and centred vertically; the
/// space around it is transparent. The progress indicator stays on the
/// cell's bottom edge. The Cover is shown the way page 1 looks in the Reader
/// (Light or Dark Pages) and follows the Page Style, Page Colors and Theme;
/// the saved Cover stays original.
struct DocumentCell: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ScrollActivity.self) private var scroll
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let document: LibraryDocument
    /// As saved.
    @State private var cover: CGImage?
    /// `cover` in the current appearance, restyled off the main thread.
    @State private var shown: CGImage?

    private var appearance: PageAppearance { settings.pageAppearance(systemScheme: colorScheme) }

    var body: some View {
        GalleryCell(
            caption: document.title, percentRead: document.percentRead,
            pageIsDark: settings.arePagesDark(systemScheme: colorScheme)
        ) {
            ZStack {
                if let shown {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    Color.placeholderGrey.transition(.opacity)
                }
            }
            .animation(.default, value: shown == nil)
        }
        .task(id: StyleKey(hasCover: cover != nil, appearance: appearance)) {
            guard let cover else { return }
            let appearance = appearance
            shown = await Task.detached { cover.shown(as: appearance) }.value
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

/// Restarts restyling when the Cover arrives or the appearance changes.
private struct StyleKey: Equatable {
    let hasCover: Bool
    let appearance: PageAppearance
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
