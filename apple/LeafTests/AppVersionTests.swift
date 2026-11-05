import Testing

@testable import Leaf

/// Settings shows the version make built the app from: the git tag and the commit
/// count as build number (see the Makefile).
@MainActor @Suite struct AppVersionTests {
    @Test func theLabelNamesVersionAndBuildNumber() {
        #expect(AppVersion(short: "1.1.0", build: "262").label == "1.1.0 (262)")
    }

    /// An empty version means the build didn't inject one, and Settings would show a
    /// blank row: the mistake that had every local build report 0.1.0.
    @Test func theAppHasAVersionToShow() {
        #expect(!AppVersion.current.short.isEmpty)
        #expect(!AppVersion.current.build.isEmpty)
    }
}
