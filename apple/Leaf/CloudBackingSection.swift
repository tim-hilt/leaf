import AuthenticationServices
import LeafCore
import SwiftUI

/// Settings' Cloud Backing: pick a Cloud Provider, Connect (with Server URL,
/// username and password for WebDAV, with one button for the others), see
/// how Sync stands, Reconnect when access was lost, Disconnect.
struct CloudBackingSection: View {
    @Environment(CloudBackingModel.self) private var cloud
    @Environment(\.webAuthenticationSession) private var webAuthentication

    /// The Cloud Provider picked, but not Connected yet.
    @State private var choosing: CloudProvider?
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isConnecting = false
    @State private var newPassword = ""
    @State private var isPickingFolder = false
    /// Picked while Connected to another: waits for the user to confirm Disconnecting.
    @State private var switchingTo: CloudProvider?

    var body: some View {
        Section("Cloud Backing") {
            Picker("Cloud Provider", selection: provider) {
                Text("None").tag(CloudProvider?.none)
                ForEach(CloudProvider.allCases, id: \.self) { provider in
                    Label {
                        Text(provider.name)
                    } icon: {
                        provider.icon.image
                    }
                    .tag(CloudProvider?.some(provider))
                }
            }
            if let connection = cloud.connection {
                LabeledContent {
                    Text(connection.detail)
                } label: {
                    Label {
                        Text(connection.provider.detailLabel)
                    } icon: {
                        connection.provider.icon.image
                    }
                }
                LabeledContent(
                    "Status",
                    value: cloud.isOnline
                        ? cloud.syncState.line(for: connection.provider) : "No internet connection")
                if cloud.syncState == .accessLost { reconnect(connection.provider) }
                Button("Disconnect", role: .destructive) { Task { await cloud.disconnect() } }
            } else if choosing == .webDAV {
                form
            } else if choosing == .iCloudDrive {
                errorText
                Button("Connect", action: pickICloudDrive).disabled(isConnecting)
            } else if let choosing, let drive = OAuthDrive(choosing) {
                errorText
                Button("Connect") {
                    attempt { try await cloud.connectOAuth(choosing, refreshToken: signIn(to: drive)) }
                }
                .disabled(isConnecting)
            }
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { picked in
            connectICloudDrive(picked)
        }
        .fileDialogMessage("Choose iCloud Drive")
        .confirmationDialog(
            "Disconnect from \(cloud.connection?.provider.name ?? "")?",
            isPresented: Binding(isPresenting: $switchingTo),
            titleVisibility: .visible, presenting: switchingTo
        ) { provider in
            Button("Disconnect and Choose \(provider.name)", role: .destructive) {
                choosing = provider
                Task { await cloud.disconnect() }
            }
        } message: { _ in
            Text("Everything stays on this Device.")
        }
    }

    /// Picking None Disconnects, which keeps everything on this Device. Picking
    /// another Cloud Provider while Connected Disconnects too, after a confirmation.
    private var provider: Binding<CloudProvider?> {
        Binding(
            get: { cloud.connection?.provider ?? choosing },
            set: { picked in
                error = nil
                guard let connection = cloud.connection else {
                    choosing = picked
                    return
                }
                if picked == nil {
                    choosing = nil
                    Task { await cloud.disconnect() }
                } else if picked != connection.provider {
                    switchingTo = picked
                }
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
                try await cloud.connect(url: url, username: username, password: password)
                password = ""
            }
        }
        .disabled(isConnecting || url.isEmpty || username.isEmpty || password.isEmpty)
    }

    /// Connected, but access was lost: a new password for WebDAV, granting
    /// iCloud Drive again for iCloud Drive, signing in again for Google Drive and OneDrive.
    /// Sync resumes without Disconnecting.
    @ViewBuilder private func reconnect(_ provider: CloudProvider) -> some View {
        switch provider {
        case .webDAV:
            SecureField("New Password", text: $newPassword)
            errorText
            Button("Reconnect") {
                attempt {
                    try await cloud.reconnect(password: newPassword)
                    newPassword = ""
                }
            }
            .disabled(isConnecting || newPassword.isEmpty)
        case .iCloudDrive:
            errorText
            Button("Reconnect", action: pickICloudDrive).disabled(isConnecting)
        case .googleDrive, .oneDrive:
            errorText
            if let drive = OAuthDrive(provider) {
                Button("Reconnect") { attempt { try await cloud.reconnectOAuth(refreshToken: signIn(to: drive)) } }
                    .disabled(isConnecting)
            }
        }
    }

    /// Opens the provider's sign-in page and returns the refresh token it leads to.
    /// Backing out of the page is `Cancelled`, which says nothing.
    private func signIn(to drive: OAuthDrive) async throws -> String {
        let attempt = try drive.signIn()
        let callback: URL
        do {
            // The core builds the consent page's address, which is a valid URL.
            callback = try await webAuthentication.authenticate(
                using: URL(string: attempt.authorizationUrl())!, callback: .customScheme(drive.redirectScheme),
                additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw ConnectError.Cancelled
        }
        return try await drive.refreshToken(of: attempt, from: callback)
    }

    /// Opens the folder picker, unless iCloud Drive is off: then there is nothing to pick.
    private func pickICloudDrive() {
        if cloud.iCloudDriveIsAvailable {
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
            attempt { try await cloud.connectICloudDrive(granting: folder) }
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

extension CloudProvider.Icon {
    /// The icon as a view, all 20pt high: a symbol follows the text, a logo is drawn unmodified.
    @ViewBuilder var image: some View {
        switch self {
        case .symbol(let name):
            Image(systemName: name).resizable().scaledToFit().frame(height: 20)
        case .logo(let name):
            Image(name).renderingMode(.original).resizable().scaledToFit().frame(height: 20)
        }
    }
}
