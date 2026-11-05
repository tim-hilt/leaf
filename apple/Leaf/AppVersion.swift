import Foundation

/// What the app says it is: the git tag make built it from, and the commit count as
/// build number (see the Makefile), as "1.1.0 (262)".
struct AppVersion: Sendable {
    /// Empty when the build didn't set a version, as in a plain Xcode build.
    let short: String
    let build: String

    var label: String { "\(short) (\(build))" }

    static var current: AppVersion {
        let info = Bundle.main.infoDictionary
        return AppVersion(
            short: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "")
    }
}
