import LeafCore
import SwiftUI

/// Settings' Cloud Backing: pick a Cloud Provider, Connect (with Server URL,
/// username and password for WebDAV, with one button for iCloud Drive), see
/// how Sync stands, Reconnect when access was lost, Disconnect.
struct CloudBackingSection: View {
    @Environment(LibraryModel.self) private var library

    /// The Cloud Provider picked, but not Connected yet.
    @State private var choosing: CloudProvider?
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isConnecting = false
    @State private var newPassword = ""
    @State private var isPickingFolder = false

    var body: some View {
        Section("Cloud Backing") {
            Picker("Cloud Provider", selection: provider) {
                Text("None").tag(CloudProvider?.none)
                ForEach(CloudProvider.allCases, id: \.self) { provider in
                    Label(provider.name, systemImage: provider.icon).tag(CloudProvider?.some(provider))
                }
            }
            if let connection = library.connection {
                LabeledContent {
                    Text(connection.detail)
                } label: {
                    Label(connection.provider.detailLabel, systemImage: connection.provider.icon)
                }
                LabeledContent("Status", value: library.syncState.line(for: connection.provider))
                if library.syncState == .accessLost { reconnect(connection.provider) }
                Button("Disconnect", role: .destructive) { Task { await library.disconnect() } }
            } else if choosing == .webDAV {
                form
            } else if choosing == .iCloudDrive {
                errorText
                Button("Connect", action: pickICloudDrive).disabled(isConnecting)
            }
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { picked in
            connectICloudDrive(picked)
        }
        .fileDialogMessage("Choose iCloud Drive")
    }

    /// Picking None Disconnects, which keeps everything on this Device.
    private var provider: Binding<CloudProvider?> {
        Binding(
            get: { library.connection?.provider ?? choosing },
            set: { picked in
                choosing = picked
                error = nil
                if picked == nil && library.connection != nil { Task { await library.disconnect() } }
            })
    }

    @ViewBuilder private var errorText: some View {
        if let error {
            Text(error).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var form: some View {
        TextField("Server URL", text: $url, prompt: Text("https://example.com/dav"))
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            #endif
        TextField("Username", text: $username)
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
        SecureField("Password", text: $password)
        errorText
        Button("Connect") {
            attempt {
                try await library.connect(url: url, username: username, password: password)
                password = ""
            }
        }
        .disabled(isConnecting || url.isEmpty || username.isEmpty || password.isEmpty)
    }

    /// Connected, but access was lost: a new password for WebDAV, granting
    /// iCloud Drive again for iCloud Drive. Sync resumes without Disconnecting.
    @ViewBuilder private func reconnect(_ provider: CloudProvider) -> some View {
        switch provider {
        case .webDAV:
            SecureField("New Password", text: $newPassword)
            errorText
            Button("Reconnect") {
                attempt {
                    try await library.reconnect(password: newPassword)
                    newPassword = ""
                }
            }
            .disabled(isConnecting || newPassword.isEmpty)
        case .iCloudDrive:
            errorText
            Button("Reconnect", action: pickICloudDrive).disabled(isConnecting)
        }
    }

    /// Opens the folder picker, unless iCloud Drive is off: then there is nothing to pick.
    private func pickICloudDrive() {
        if library.iCloudDriveIsAvailable {
            error = nil
            isPickingFolder = true
        } else {
            error = ConnectError.ICloudDriveUnavailable.message
        }
    }

    /// Backing out of the picker is no error.
    private func connectICloudDrive(_ picked: Result<URL, any Error>) {
        switch picked {
        case .success(let folder):
            attempt { try await library.connectICloudDrive(granting: folder) }
        case .failure(let failure):
            if (failure as? CocoaError)?.code != .userCancelled { error = failure.localizedDescription }
        }
    }

    /// Runs `connecting`, shows why it failed, if it did.
    private func attempt(_ connecting: @escaping () async throws -> Void) {
        Task {
            isConnecting = true
            defer { isConnecting = false }
            do {
                try await connecting()
                error = nil
            } catch let failure as ConnectError {
                error = failure.message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
