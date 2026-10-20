import SwiftUI

/// The Reader's cog popover: Page Style and Page Colors, shared by all Documents and saved.
struct PageStylePopover: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 12) {
            Text("Page Style").font(.headline)
            PageStylePicker(selection: $settings.pageStyle, paper: settings.pageColors.paper)
            Text("Page Colors").font(.headline)
            PageColorsEditor()
        }
        .padding()
        .frame(minWidth: 280)
        .presentationCompactAdaptation(.popover)
    }
}
