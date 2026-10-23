import Testing

@testable import Leaf

@MainActor @Suite struct ScrollActivityTests {
    let quiet = Duration.milliseconds(40)

    @Test func isStillBeforeAnyScrolling() {
        #expect(ScrollActivity(quietPeriod: quiet).isStill)
    }

    @Test func isNotStillWhileScrolling() async throws {
        let activity = ScrollActivity(quietPeriod: quiet)
        activity.scrollingChanged(isScrolling: true)
        try await Task.sleep(for: quiet * 3)
        #expect(!activity.isStill)
    }

    @Test func isStillOnlyOnceScrollingHasStoppedForTheQuietPeriod() async throws {
        let activity = ScrollActivity(quietPeriod: quiet)
        activity.scrollingChanged(isScrolling: true)
        activity.scrollingChanged(isScrolling: false)
        #expect(!activity.isStill)

        try await Task.sleep(for: quiet * 4)
        #expect(activity.isStill)
    }

    @Test func scrollingAgainRestartsTheQuietPeriod() async throws {
        let activity = ScrollActivity(quietPeriod: quiet)
        activity.scrollingChanged(isScrolling: false)
        activity.scrollingChanged(isScrolling: true)
        activity.scrollingChanged(isScrolling: false)
        try await Task.sleep(for: quiet * 4)
        #expect(activity.isStill)
    }
}
