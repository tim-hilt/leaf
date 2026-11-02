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

        #expect(try await becomesStill(activity))
    }

    @Test func scrollingAgainRestartsTheQuietPeriod() async throws {
        let activity = ScrollActivity(quietPeriod: quiet)
        activity.scrollingChanged(isScrolling: false)
        activity.scrollingChanged(isScrolling: true)
        activity.scrollingChanged(isScrolling: false)
        #expect(try await becomesStill(activity))
    }

    /// Whether `activity` turns still within two seconds: a busy main actor delays the quiet period's end.
    private func becomesStill(_ activity: ScrollActivity) async throws -> Bool {
        for _ in 0..<100 where !activity.isStill { try await Task.sleep(for: .milliseconds(20)) }
        return activity.isStill
    }
}
