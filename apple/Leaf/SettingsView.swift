import LeafCore
import SwiftUI

/// The Settings: Theme, Highlight Colors (the Default Highlight Color), Cloud Backing
/// and the Version.
/// Page Style and Page Colors live in the Reader's cog popover.
/// A window on Mac (⌘,), a sheet from the Gallery's gear on iPhone and iPad.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryModel.self) private var library
    @State private var isEditingColors = false

    var body: some View {
        @Bindable var settings = settings
        let hasCustomColors = library.highlightColors.contains(where: \.isCustom)
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
            Section {
                HighlightColorGrid(
                    colors: library.highlightColors, selected: library.defaultHighlightColor.tint,
                    onSelect: { color in Task { await library.setDefaultHighlightColor(color) } },
                    onRemove: { color in Task { await library.removeCustomColor(color) } },
                    isEditing: isEditingColors,
                    trailing: { AddCustomColorButton { color in Task { await library.addCustomColor(color) } } })
            } header: {
                HStack {
                    Text("Highlight Colors")
                    Spacer()
                    if hasCustomColors {
                        Button(isEditingColors ? "Done" : "Edit") { isEditingColors.toggle() }
                            .textCase(nil)
                    }
                }
            }
            CloudBackingSection()
            Section { LabeledContent("Version", value: AppVersion.current.label) }
        }
        .onChange(of: hasCustomColors) { if !hasCustomColors { isEditingColors = false } }
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
