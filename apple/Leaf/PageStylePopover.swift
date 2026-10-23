import SwiftUI

/// The Reader's cog popover: Page Style and Page Colors, shared by all Documents and saved.
struct PageStylePopover: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var settings = settings
        // In a ScrollView so the content stays pinned to the top while the popover resizes.
        // Otherwise it is centered in the in-between size and the swatches fly in.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Page Style").font(.headline)
                PageStylePicker(selection: $settings.pageStyle, paper: settings.pageColors.paper)
                if settings.arePagesDark(systemScheme: colorScheme) {
                    Text("Dark Page Colors").font(.headline)
                    PageColorsEditor()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: 280)
        .presentationCompactAdaptation(.popover)
    }
}
