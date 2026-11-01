#if os(iOS)
    import LeafCore
    import Testing
    import UIKit

    @testable import Leaf

    @MainActor @Suite(.serialized) struct ThemeAppearanceTests {
        /// A popover open in a window of the app's scene.
        private func openPopover() throws -> (UIWindowScene, UIWindow, UIViewController) {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            let popover = UIViewController()
            popover.modalPresentationStyle = .popover
            popover.popoverPresentationController?.sourceView = window.rootViewController?.view
            window.rootViewController?.present(popover, animated: false)
            return (scene, window, popover)
        }

        @Test func anOpenPopoverTakesTheTheme() throws {
            let (_, window, popover) = try openPopover()
            defer {
                Theme.system.apply()
                window.isHidden = true
            }

            Theme.dark.apply()
            #expect(popover.traitCollection.userInterfaceStyle == .dark)
            Theme.light.apply()
            #expect(popover.traitCollection.userInterfaceStyle == .light)
        }

        @Test func anOpenPopoverFollowsTheSystemUnderTheSystemTheme() throws {
            let (scene, window, popover) = try openPopover()
            defer { window.isHidden = true }
            Theme.dark.apply()

            Theme.system.apply()

            #expect(popover.traitCollection.userInterfaceStyle == scene.traitCollection.userInterfaceStyle)
        }
    }
#endif
