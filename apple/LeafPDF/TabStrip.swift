import SwiftUI

/// The strip of Tabs under the toolbar: each Tab's Title and an (x), the active
/// one emphasized, scrolling sideways when they don't fit.
struct TabStrip: View {
    @Environment(Tabs.self) private var tabs
    @Environment(LibraryModel.self) private var library
    @State private var width: CGFloat = 0

    /// Wide enough for 3 Tabs on an iPhone in portrait.
    private static let minimumTabWidth: CGFloat = 120
    private static let maximumTabWidth: CGFloat = 240

    private var documents: [LibraryDocument] {
        tabs.openIDs.compactMap { id in library.documents.first { $0.id == id } }
    }

    /// Tabs share the width until they get narrower than the minimum.
    private var tabWidth: CGFloat {
        min(max(width / CGFloat(max(documents.count, 1)), Self.minimumTabWidth), Self.maximumTabWidth)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(documents) { document in
                        TabItem(document: document, isActive: document.id == tabs.activeID)
                            .frame(width: tabWidth)
                            .id(document.id)
                    }
                }
            }
            .onChange(of: tabs.activeID, initial: true) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
