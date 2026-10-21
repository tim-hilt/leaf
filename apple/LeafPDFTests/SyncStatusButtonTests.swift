import SwiftUI
import Testing

@testable import LeafPDF

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The checkmark and cross cut out of the filled sync icons must stay readable
/// against their green and red fills in both appearances.
@MainActor @Suite struct SyncStatusButtonTests {
    #if os(iOS)
        private func resolved(_ color: Color, dark: Bool) -> UIColor {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            return UIColor(color).resolvedColor(with: traits)
        }

        private func assert(_ color: UIColor, isWhite: Bool) {
            #expect(color == (isWhite ? UIColor.white : UIColor.black))
        }
    #else
        private func resolved(_ color: Color, dark: Bool) -> (CGFloat, CGFloat, CGFloat) {
            NSAppearance.current = NSAppearance(named: dark ? .darkAqua : .aqua)
            let rgb = NSColor(color).usingColorSpace(.deviceRGB)!
            return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }

        private func assert(_ rgb: (CGFloat, CGFloat, CGFloat), isWhite: Bool) {
            let expected: CGFloat = isWhite ? 1 : 0
            #expect(rgb.0 == expected && rgb.1 == expected && rgb.2 == expected)
        }
    #endif

    @Test func glyphIsWhiteInLightMode() {
        assert(resolved(SyncStatusButton.glyphColor, dark: false), isWhite: true)
    }

    @Test func glyphIsBlackInDarkMode() {
        assert(resolved(SyncStatusButton.glyphColor, dark: true), isWhite: false)
    }
}
