import SwiftUI

/// The Reader's cog popover: the same Page Style setting as in Settings.
struct PageStylePopover: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 12) {
            Text("Page Style").font(.headline)
            PageStylePicker(selection: $settings.pageStyle)
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }
}
