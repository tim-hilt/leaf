import SwiftUI

/// The Settings: Theme, Highlight Colors (the Default Highlight Color) and Cloud Backing.
/// Page Style and Page Colors live in the Reader's cog popover.
/// A window on Mac (⌘,), a sheet from the Gallery's gear on iPhone and iPad.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryModel.self) private var library

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Theme") {
                Picker("Theme", selection: $settings.theme) {
                    Text("System").tag(Theme.system)
                    Text("Light").tag(Theme.light)
                    Text("Dark").tag(Theme.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Highlight Colors") {
                HighlightColorGrid(
                    colors: library.highlightColors, selected: library.defaultHighlightColor.color,
                    onSelect: { color in Task { await library.setDefaultHighlightColor(color) } },
                    onRemove: { color in Task { await library.removeCustomColor(color) } },
                    trailing: { AddCustomColorButton { color in Task { await library.addCustomColor(color) } } })
            }
            CloudBackingSection()
        }
        .formStyle(.grouped)
    }
}

#if os(iOS)
    /// `SettingsView` in a sheet with a Done button.
    struct SettingsSheet: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { dismiss() } }
            }
        }
    }
#endif
