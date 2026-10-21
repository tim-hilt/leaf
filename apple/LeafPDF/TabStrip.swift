import SwiftUI

/// The `TabStrip` above the Reader, once a second Tab is open. Immersive Mode
/// collapses it instead of removing it, so it keeps its layout and scroll position.
struct ReaderTabStrip: View {
    @Environment(Tabs.self) private var tabs

    var body: some View {
        if tabs.openIDs.count > 1 {
            TabStrip()
                .frame(height: tabs.isImmersive ? 0 : TabStrip.height, alignment: .top)
                .clipped()
                .allowsHitTesting(!tabs.isImmersive)
                .accessibilityHidden(tabs.isImmersive)
                .animation(.default, value: tabs.isImmersive)
        }
    }
}

/// The strip of Tabs under the toolbar: each Tab's Title and an (x), the active
/// one emphasized, scrolling sideways when they don't fit.
struct TabStrip: View {
    @Environment(Tabs.self) private var tabs
    @Environment(LibraryModel.self) private var library

    static let height: CGFloat = 36
    /// Wide enough for 3 Tabs on an iPhone in portrait.
    private static let minimumTabWidth: CGFloat = 120
    private static let maximumTabWidth: CGFloat = 240

    private var documents: [LibraryDocument] {
        tabs.openIDs.compactMap { id in library.documents.first { $0.id == id } }
    }

    /// Tabs share `width` until they get narrower than the minimum.
    private func tabWidth(in width: CGFloat) -> CGFloat {
        min(max(width / CGFloat(max(documents.count, 1)), Self.minimumTabWidth), Self.maximumTabWidth)
    }

    var body: some View {
        // The reader knows the width on the first layout pass, so Tabs never resize.
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(documents) { document in
                            TabItem(document: document, isActive: document.id == tabs.activeID)
                                .frame(width: tabWidth(in: geometry.size.width))
                                .id(document.id)
                        }
                    }
                }
                .onAppear { scrollToActive(with: proxy, animated: false) }
                .onChange(of: tabs.activeID) { scrollToActive(with: proxy, animated: true) }
            }
        }
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Scrolls just far enough to bring the active Tab into view.
    private func scrollToActive(with proxy: ScrollViewProxy, animated: Bool) {
        guard let id = tabs.activeID else { return }
        if animated {
            withAnimation { proxy.scrollTo(id) }
        } else {
            proxy.scrollTo(id)
        }
    }
}

/// One Tab: its Document's Title, truncated, and an (x) that closes it.
private struct TabItem: View {
    let document: LibraryDocument
    let isActive: Bool
    @Environment(Tabs.self) private var tabs

    var body: some View {
        HStack(spacing: 4) {
            Text(document.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Close", systemImage: "xmark") { tabs.close(document.id) }
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color.accentColor.opacity(0.15) : .clear)
        .overlay(alignment: .bottom) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { tabs.select(document.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(document.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { tabs.select(document.id) }
        .accessibilityAction(named: "Close") { tabs.close(document.id) }
    }
}
