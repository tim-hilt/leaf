import SwiftUI

extension View {
    /// Shows the `TabStrip` under the toolbar, once a second Tab is open. Immersive
    /// Mode hides it instead of removing it, so it keeps its layout and scroll position.
    func readerTabStrip() -> some View { modifier(ReaderTabStrip()) }
}

private struct ReaderTabStrip: ViewModifier {
    @Environment(Tabs.self) private var tabs
    #if os(iOS)
        /// Top edge of the strip while it follows the navigation bar; nil until the bar is known.
        @State private var top: CGFloat?
    #endif

    private var isShown: Bool { tabs.openIDs.count > 1 }

    func body(content: Content) -> some View {
        #if os(iOS)
            // An inset only for the safe area, which changes at once: the pages stay put.
            // The strip itself is an overlay that moves with the bar, in one motion.
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: isShown && !tabs.isImmersive ? TabStrip.height : 0)
                }
                .overlay(alignment: .top) {
                    if isShown {
                        TabStrip()
                            .background(NavigationBarFollower(isBarHidden: tabs.isImmersive, top: $top))
                            .allowsHitTesting(!tabs.isImmersive)
                            .accessibilityHidden(tabs.isImmersive)
                            .offset(y: top ?? -TabStrip.height)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .ignoresSafeArea(.container, edges: .top)
                    }
                }
        #else
            content.safeAreaInset(edge: .top, spacing: 0) {
                if isShown {
                    TabStrip()
                        .frame(height: tabs.isImmersive ? 0 : TabStrip.height, alignment: .top)
                        .clipped()
                        .allowsHitTesting(!tabs.isImmersive)
                        .accessibilityHidden(tabs.isImmersive)
                }
            }
        #endif
    }
}

#if os(iOS)
    /// Reports where the `TabStrip` goes to follow the navigation bar: right under it
    /// while shown, off the top of the screen once hidden, and in between at the same
    /// pace as the bar's own slide. The bar's animation is UIKit's, so the strip reads
    /// the bar's frame on screen instead of guessing its timing.
    private struct NavigationBarFollower: UIViewRepresentable {
        /// Changes as the bar starts to slide.
        let isBarHidden: Bool
        @Binding var top: CGFloat?

        func makeUIView(context: Context) -> FollowerView { FollowerView() }

        func updateUIView(_ view: FollowerView, context: Context) {
            view.onMove = { top = $0 }
            view.isBarHidden = isBarHidden
        }
    }

    private final class FollowerView: UIView {
        var onMove: (CGFloat) -> Void = { _ in }
        var isBarHidden = false {
            didSet { if isBarHidden != oldValue { follow() } }
        }
        private var link: CADisplayLink?
        private var lastMoved = CACurrentMediaTime()
        /// The bar's top edge while shown; while hidden, its frame only says where it hides.
        private var shownBarTop: CGFloat = 0
        private var size = CGSize.zero

        private var bar: UINavigationBar? {
            sequence(first: self as UIResponder, next: \.next)
                .lazy.compactMap { ($0 as? UIViewController)?.navigationController }.first?.navigationBar
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { follow() } else { stop() }
        }

        // Rotating or resizing the window moves the bar too.
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != size else { return }
            size = bounds.size
            follow()
        }

        /// Follows the bar, frame by frame, until it has rested for a moment: UIKit
        /// starts the bar's slide only after the update that hides or shows it.
        private func follow() {
            lastMoved = CACurrentMediaTime()
            guard link == nil, window != nil else { return }
            link = CADisplayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
        }

        private func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() {
            guard let bar else { return stop() }
            let target = bar.frame
            let now = bar.layer.presentation()?.frame ?? target
            // UIKit sets the frame to where the bar slides at once, and hides the bar
            // right above the screen, ending at 0.
            if target.maxY > 0 { shownBarTop = target.minY }
            let shownBottom = shownBarTop + target.height
            let shownAmount = min(max(now.maxY / shownBottom, 0), 1)
            onMove(-TabStrip.height + shownAmount * (shownBottom + TabStrip.height))
            if abs(now.minY - target.minY) > 0.5 {
                lastMoved = CACurrentMediaTime()
            } else if CACurrentMediaTime() - lastMoved > 0.25 {
                stop()
            }
        }
    }
#endif

/// The strip of Tabs under the toolbar: each Tab's Title and an (x), the active
/// one on a raised shape, scrolling sideways when they don't fit.
struct TabStrip: View {
    @Environment(Tabs.self) private var tabs
    @Environment(LibraryModel.self) private var library
    @Namespace private var marker

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
                    TabMarkerContainer {
                        HStack(spacing: 0) {
                            ForEach(documents) { document in
                                TabItem(
                                    document: document, isActive: document.id == tabs.activeID,
                                    marker: marker
                                )
                                .frame(width: tabWidth(in: geometry.size.width))
                                .id(document.id)
                            }
                        }
                        .animation(.default, value: tabs.activeID)
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

/// Groups the Tabs so the marker's Liquid Glass (iOS 26+) slides between them.
private struct TabMarkerContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

/// The raised shape behind the active Tab, like the selected tab in native tab bars:
/// Liquid Glass on iOS 26+, a plain system fill before.
private struct TabMarker: ViewModifier {
    let isActive: Bool
    let namespace: Namespace.ID

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    /// One ID, moving to the active Tab, so the glass slides there instead of fading.
    private static let glassID = "active Tab"

    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content
                .glassEffect(isActive ? .regular : .identity, in: shape)
                .glassEffectID(isActive ? Self.glassID : nil, in: namespace)
        } else {
            content.background {
                if isActive { shape.fill(.quaternary) }
            }
        }
    }
}

/// One Tab: its Document's Title, truncated, and an (x) that closes it.
private struct TabItem: View {
    let document: LibraryDocument
    let isActive: Bool
    let marker: Namespace.ID
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
        .modifier(TabMarker(isActive: isActive, namespace: marker))
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { tabs.select(document.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(document.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { tabs.select(document.id) }
        .accessibilityAction(named: "Close") { tabs.close(document.id) }
    }
}
