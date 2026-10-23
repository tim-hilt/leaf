import LeafCore
import SwiftUI

/// Settings' Cloud Backing: pick a Cloud Provider, Connect with Server URL,
/// username and password, see how Sync stands, Reconnect with a new password
/// when the server rejects the old one, Disconnect.
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
                if library.syncState == .accessLost { reconnectForm }
                Button("Disconnect", role: .destructive) { Task { await library.disconnect() } }
            } else if choosing == .webDAV {
                form
            }
        }
    }

    /// Picking None Disconnects, which keeps everything on this Device.
    private var provider: Binding<CloudProvider?> {
        Binding(
            get: { library.connection?.provider ?? choosing },
            set: { picked in
                choosing = picked
                if picked == nil && library.connection != nil { Task { await library.disconnect() } }
            })
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
        if let error {
            Text(error).foregroundStyle(.red)
        }
        Button("Connect") { Task { await connect() } }
            .disabled(isConnecting || url.isEmpty || username.isEmpty || password.isEmpty)
    }

    /// Connected, but access was lost: for WebDAV, a new password resumes Sync.
    @ViewBuilder private var reconnectForm: some View {
        SecureField("New Password", text: $newPassword)
        if let error {
            Text(error).foregroundStyle(.red)
        }
        Button("Reconnect") { Task { await reconnect() } }
            .disabled(isConnecting || newPassword.isEmpty)
    }

    private func reconnect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await library.reconnect(password: newPassword)
            error = nil
            newPassword = ""
        } catch let failure as ConnectError {
            error = failure.message
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await library.connect(url: url, username: username, password: password)
            error = nil
            password = ""
        } catch let failure as ConnectError {
            error = failure.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}
