import Foundation
import Testing

@testable import LeafPDF

@MainActor @Suite struct TabsTests {
    /// This device's user defaults: one suite per test.
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let a = doc("a"), b = doc("b"), c = doc("c")

    static func doc(_ id: String) -> LibraryDocument {
        LibraryDocument(id: id, file: URL(fileURLWithPath: "/\(id).pdf"))
    }

    func makeTabs(in library: [LibraryDocument]? = nil) -> Tabs {
        Tabs(defaults: defaults, library: library ?? [a, b, c])
    }

    @Test func startsInTheGalleryWithoutTabs() {
        let tabs = makeTabs()
        #expect(tabs.openIDs.isEmpty)
        #expect(tabs.activeID == nil)
        #expect(!tabs.isShowingReader)
    }

    // MARK: Open

    @Test func openAppendsAtTheEndAndShowsTheReader() {
        let tabs = makeTabs()
        tabs.open([a])
        tabs.open([b])
        #expect(tabs.openIDs == ["a", "b"])
        #expect(tabs.activeID == "b")
        #expect(tabs.isShowingReader)
    }

    @Test func openingAnOpenDocumentSwitchesToItsTab() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.open([a])
        #expect(tabs.openIDs == ["a", "b"])
        #expect(tabs.activeID == "a")
    }

    @Test func openingSeveralMakesTheFirstActive() {
        let tabs = makeTabs()
        tabs.open([a])
        tabs.open([c, b, a])
        #expect(tabs.openIDs == ["a", "c", "b"])
        #expect(tabs.activeID == "c")
    }

    @Test func openingNothingChangesNothing() {
        let tabs = makeTabs()
        tabs.open([])
        #expect(!tabs.isShowingReader)
    }

    // MARK: Close

    @Test func closingTheActiveTabShowsTheOneToItsRight() {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.select("b")
        tabs.close("b")
        #expect(tabs.openIDs == ["a", "c"])
        #expect(tabs.activeID == "c")
    }

    @Test func closingTheLastActiveTabShowsTheOneToItsLeft() {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.select("c")
        tabs.close("c")
        #expect(tabs.activeID == "b")
    }

    @Test func closingABackgroundTabKeepsTheActiveOne() {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.close("c")
        #expect(tabs.openIDs == ["a", "b"])
        #expect(tabs.activeID == "a")
    }

    @Test func closingTheLastTabGoesToTheGallery() {
        let tabs = makeTabs()
        tabs.open([a])
        tabs.close("a")
        #expect(tabs.openIDs.isEmpty)
        #expect(tabs.activeID == nil)
        #expect(!tabs.isShowingReader)
    }

    @Test func closeActiveClosesTheActiveTab() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.closeActive()
        #expect(tabs.openIDs == ["b"])
    }

    @Test func closeActiveDoesNothingInTheGallery() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.goToGallery()
        tabs.closeActive()
        #expect(tabs.openIDs == ["a", "b"])
    }

    // MARK: View state

    let state = ReaderViewState(
        place: Place(pageIndex: 3, point: CGPoint(x: 0, y: 200)), zoom: 2,
        backPlace: Place(pageIndex: 1, point: CGPoint(x: 0, y: 700)))

    @Test func aTabKeepsItsViewState() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.store(state, for: "a")
        tabs.select("b")
        tabs.select("a")
        #expect(tabs.viewState(of: "a") == state)
        #expect(tabs.viewState(of: "b") == nil)
    }

    @Test func aClosedTabForgetsItsViewState() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.store(state, for: "a")
        tabs.close("a")
        tabs.store(state, for: "a")
        tabs.open([a])
        #expect(tabs.viewState(of: "a") == nil)
    }

    @Test func aRestoredTabHasNoViewState() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.store(state, for: "a")
        #expect(makeTabs().viewState(of: "a") == nil)
    }

    // MARK: Select

    @Test func selectingATabShowsTheReaderOnIt() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.goToGallery()
        tabs.select("b")
        #expect(tabs.activeID == "b")
        #expect(tabs.isShowingReader)
    }

    @Test func selectingAnUnknownTabChangesNothing() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.select("zzz")
        #expect(tabs.activeID == "a")
    }

    @Test func nextAndPreviousWrapAroundTheEnds() {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.selectPrevious()
        #expect(tabs.activeID == "c")
        tabs.selectNext()
        #expect(tabs.activeID == "a")
        tabs.selectNext()
        #expect(tabs.activeID == "b")
    }

    @Test func numbersPickTabsByPositionFromOne() {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.select(number: 3)
        #expect(tabs.activeID == "c")
        tabs.select(number: 1)
        #expect(tabs.activeID == "a")
    }

    @Test(arguments: [0, 4, 9, -1])
    func aNumberOutOfRangeDoesNothing(number: Int) {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.select(number: 2)
        tabs.select(number: number)
        #expect(tabs.activeID == "b")
    }

    @Test func switchingByKeyboardDoesNothingInTheGallery() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.goToGallery()
        tabs.selectNext()
        tabs.select(number: 2)
        #expect(!tabs.isShowingReader)
        #expect(tabs.activeID == "a")
    }

    // MARK: Gallery and Reader

    @Test func goToGalleryKeepsTheTabsAndShowReaderReturnsToTheActiveOne() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.select("a")
        tabs.goToGallery()
        #expect(!tabs.isShowingReader)
        #expect(tabs.openIDs == ["a", "b"])
        #expect(tabs.activeID == "a")
        tabs.showReader()
        #expect(tabs.isShowingReader)
        #expect(tabs.activeID == "a")
    }

    @Test func showReaderWithoutTabsStaysInTheGallery() {
        let tabs = makeTabs()
        tabs.showReader()
        #expect(!tabs.isShowingReader)
    }

    // MARK: Remove

    @Test func aRemovedActiveTabClosesLikeAClose() {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.select("b")
        tabs.keep(onlyIn: [a, c])
        #expect(tabs.openIDs == ["a", "c"])
        #expect(tabs.activeID == "c")
        #expect(tabs.isShowingReader)
    }

    @Test func aRemovedBackgroundTabLeavesTheActiveOne() {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.keep(onlyIn: [a, b])
        #expect(tabs.openIDs == ["a", "b"])
        #expect(tabs.activeID == "a")
    }

    @Test func removingTheLastTabGoesToTheGallery() {
        let tabs = makeTabs()
        tabs.open([a])
        tabs.keep(onlyIn: [b, c])
        #expect(tabs.openIDs.isEmpty)
        #expect(!tabs.isShowingReader)
    }

    @Test func removingEveryTabGoesToTheGallery() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.keep(onlyIn: [])
        #expect(tabs.openIDs.isEmpty)
        #expect(!tabs.isShowingReader)
    }

    @Test func removingATabInTheGalleryKeepsTheGallery() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.goToGallery()
        tabs.keep(onlyIn: [b])
        #expect(tabs.openIDs == ["b"])
        #expect(tabs.activeID == "b")
        #expect(!tabs.isShowingReader)
    }

    // MARK: Restore

    @Test func tabsTheActiveOneAndTheReaderSurviveARestart() {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.select("b")

        let restored = makeTabs()
        #expect(restored.openIDs == ["a", "b", "c"])
        #expect(restored.activeID == "b")
        #expect(restored.isShowingReader)
    }

    @Test func theGalleryShowingSurvivesARestart() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.goToGallery()

        let restored = makeTabs()
        #expect(restored.openIDs == ["a", "b"])
        #expect(!restored.isShowingReader)
    }

    @Test func closedTabsStayClosedAfterARestart() {
        let tabs = makeTabs()
        tabs.open([a, b])
        tabs.close("a")
        #expect(makeTabs().openIDs == ["b"])
    }

    @Test func restoringDropsDocumentsNoLongerInTheLibrary() {
        let tabs = makeTabs()
        tabs.open([a, b, c])
        tabs.select("b")

        let restored = makeTabs(in: [a, c])
        #expect(restored.openIDs == ["a", "c"])
        #expect(restored.activeID == "c")
    }

    @Test func restoringWithNoDocumentLeftShowsTheGallery() {
        let tabs = makeTabs()
        tabs.open([a])

        let restored = makeTabs(in: [])
        #expect(restored.openIDs.isEmpty)
        #expect(restored.activeID == nil)
        #expect(!restored.isShowingReader)
    }
}
