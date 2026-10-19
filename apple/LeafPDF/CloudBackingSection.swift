import LeafCore
import SwiftUI

/// Settings' Cloud Backing: pick a Cloud Provider, Connect with Server URL,
/// username and password, see how Sync stands, enter a new password when the
/// server rejects the old one, Disconnect.
struct CloudBackingSection: View {
    @Environment(LibraryModel.self) private var library

    private enum Provider: Hashable { case none, webDAV }

    /// WebDAV is picked, but not Connected yet.
    @State private var isChoosingWebDAV = false
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isConnecting = false
    @State private var newPassword = ""

    var body: some View {
        Section("Cloud Backing") {
            Picker("Cloud Provider", selection: provider) {
                Text("None").tag(Provider.none)
                Text("WebDAV").tag(Provider.webDAV)
            }
            if let connection = library.connection {
                LabeledContent("Server", value: connection.server)
                LabeledContent("Status", value: library.syncState.line())
                if library.syncState == .wrongPassword { passwordForm }
                Button("Disconnect", role: .destructive) { Task { await library.disconnect() } }
            } else if isChoosingWebDAV {
                form
            }
        }
    }

    /// Picking None Disconnects, which keeps everything on this Device.
    private var provider: Binding<Provider> {
        Binding(
            get: { library.connection != nil || isChoosingWebDAV ? .webDAV : .none },
            set: { picked in
                isChoosingWebDAV = picked == .webDAV
                if picked == .none && library.connection != nil { Task { await library.disconnect() } }
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

    /// Connected, but the server rejected the password: a new one resumes Sync.
    @ViewBuilder private var passwordForm: some View {
        SecureField("New Password", text: $newPassword)
        if let error {
            Text(error).foregroundStyle(.red)
        }
        Button("Update Password") { Task { await updatePassword() } }
            .disabled(isConnecting || newPassword.isEmpty)
    }

    private func updatePassword() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await library.updatePassword(newPassword)
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
