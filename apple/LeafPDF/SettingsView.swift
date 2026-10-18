import SwiftUI

/// The Settings: Theme and Page Style. A window on Mac (⌘,), a sheet from the
/// Gallery's gear on iPhone and iPad.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

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
            Section("Page Style") {
                PageStylePicker(selection: $settings.pageStyle)
            }
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
            .presentationDetents([.medium])
        }
    }
#endif
