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
                            .background(NavigationBarFollower(isHidden: tabs.isImmersive, top: $top))
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
                        .accessibilityHidden(tabs.isImmersive)
                        .animation(.default, value: tabs.isImmersive)
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
        let isHidden: Bool
        @Binding var top: CGFloat?

        func makeUIView(context: Context) -> FollowerView { FollowerView() }

        func updateUIView(_ view: FollowerView, context: Context) {
            view.onMove = { top = $0 }
            view.isHidden(isHidden)
        }
    }

    private final class FollowerView: UIView {
        var onMove: (CGFloat) -> Void = { _ in }
        private var link: CADisplayLink?
        private var wasHidden: Bool?
        /// The bar's resting frame while shown and while hidden, as UIKit sets it at once.
        private var ends: (shown: CGFloat, hidden: CGFloat)?
        private var lastMoved = CACurrentMediaTime()

        private var bar: UINavigationBar? {
            sequence(first: self as UIResponder, next: \.next)
                .lazy.compactMap { ($0 as? UIViewController)?.navigationController }.first?.navigationBar
        }

        /// Follows the bar for as long as it moves, when `hidden` changes.
        func isHidden(_ hidden: Bool) {
            defer { wasHidden = hidden }
            guard wasHidden != nil, wasHidden != hidden, window != nil, link == nil else { return }
            lastMoved = CACurrentMediaTime()
            link = CADisplayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            link?.invalidate()
            link = nil
            // After the update that added this view.
            if window != nil { DispatchQueue.main.async { [weak self] in self?.follow() } }
        }

        @objc private func tick() {
            follow()
            if CACurrentMediaTime() - lastMoved > 0.25 {
                link?.invalidate()
                link = nil
            }
        }

        private func follow() {
            guard let bar else { return }
            let target = bar.frame.minY
            let shownNow = bar.layer.presentation()?.frame.minY ?? target
            if abs(shownNow - target) > 0.5 { lastMoved = CACurrentMediaTime() }
            // `target` is one of the two ends; the higher one is the bar shown.
            var current = ends ?? (target, target)
            if target >= (current.shown + current.hidden) / 2 {
                current.shown = target
            } else {
                current.hidden = target
            }
            ends = current
            let travel = current.shown - current.hidden
            let hiddenAmount = travel > 0 ? min(max((current.shown - shownNow) / travel, 0), 1) : 0
            let rest = current.shown + bar.frame.height
            onMove(rest - hiddenAmount * (rest + TabStrip.height))
        }
    }
#endif

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
