import LeafCore
import SwiftUI
import Testing

@testable import Leaf

/// A popover is sized to its content's ideal size. That height must be the
/// height the content has at that width, or the popover has empty space.
@MainActor @Suite struct PopoverSizeTests {
    let colors = (0..<8).map { HighlightColor(id: "\($0)", rgb: Rgb(RGB(Double($0) / 8, 0, 0)), isCustom: false) }

    @Test func highlightPopoverIsAsTallAsItsContent() {
        let popover = HighlightPopover(
            colors: colors, color: colors[0].tint, note: "A note", onColor: { _ in }, onNote: { _ in },
            onRemove: {})
        expectFitted(popover)
    }

    @Test func pageNotePopoverIsAsTallAsItsContent() {
        let popover = PageNotePopover(
            text: String(repeating: "A long page note. ", count: 20), startsEditing: false, onText: { _ in },
            onRemove: {})
        expectFitted(popover)
    }

    private func expectFitted(_ view: some View) {
        let ideal = size(of: view, proposed: .unspecified)
        let laidOut = size(of: view, proposed: ProposedViewSize(width: ideal.width, height: nil))
        #expect(ideal.height == laidOut.height)
        #expect(ideal.width < 400)
    }

    private func size(of view: some View, proposed: ProposedViewSize) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = proposed
        guard let image = renderer.cgImage else { return .zero }
        return CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
    }
}
