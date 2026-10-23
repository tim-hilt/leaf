import Testing

@testable import Leaf

@Suite struct GridHighlightTests {
    // 3 columns, 8 cells (the "+" cell is 0):
    //   0 1 2
    //   3 4 5
    //   6 7
    let grid = GridHighlight(columns: 3, cellCount: 8)

    @Test(arguments: [GridHighlight.Arrow.up, .down, .left, .right])
    func firstPressHighlightsTheFirstCell(arrow: GridHighlight.Arrow) {
        #expect(grid.moved(from: nil, arrow) == 0)
    }

    @Test func movesInAllFourDirections() {
        #expect(grid.moved(from: 4, .up) == 1)
        #expect(grid.moved(from: 4, .down) == 7)
        #expect(grid.moved(from: 4, .left) == 3)
        #expect(grid.moved(from: 4, .right) == 5)
    }

    @Test func staysPutAtTheTopAndSideEdges() {
        #expect(grid.moved(from: 1, .up) == 1)
        #expect(grid.moved(from: 3, .left) == 3)
        #expect(grid.moved(from: 5, .right) == 5)
    }

    @Test func doesNotWrapAcrossRows() {
        #expect(grid.moved(from: 2, .right) == 2)
        #expect(grid.moved(from: 3, .left) == 3)
    }

    @Test func staysPutAtTheBottomEdge() {
        #expect(grid.moved(from: 6, .down) == 6)
        #expect(grid.moved(from: 7, .down) == 7)
    }

    // MARK: Last, partial row

    @Test func downIntoTheLastPartialRowGoesToItsLastCell() {
        #expect(grid.moved(from: 5, .down) == 7)
        #expect(grid.moved(from: 2, .down) == 5)
    }

    @Test func staysPutRightOfTheLastCell() {
        #expect(grid.moved(from: 7, .right) == 7)
    }

    // MARK: Degenerate grids

    @Test func aSingleCellStaysPut() {
        let single = GridHighlight(columns: 4, cellCount: 1)
        for arrow in [GridHighlight.Arrow.up, .down, .left, .right] {
            #expect(single.moved(from: 0, arrow) == 0)
        }
    }

    @Test func aSingleColumnMovesOnlyUpAndDown() {
        let column = GridHighlight(columns: 1, cellCount: 3)
        #expect(column.moved(from: 1, .down) == 2)
        #expect(column.moved(from: 1, .up) == 0)
        #expect(column.moved(from: 1, .left) == 1)
        #expect(column.moved(from: 1, .right) == 1)
    }

    @Test func aHighlightPastTheEndAfterTheGridShrankMovesFromTheLastCell() {
        let shrunk = GridHighlight(columns: 3, cellCount: 3)
        #expect(shrunk.moved(from: 9, .left) == 1)
    }

    // MARK: Column count changes

    @Test func usesTheNewColumnCountForVerticalMoves() {
        let narrower = GridHighlight(columns: 2, cellCount: 8)
        #expect(narrower.moved(from: 4, .up) == 2)
        #expect(narrower.moved(from: 4, .down) == 6)
        let wider = GridHighlight(columns: 4, cellCount: 8)
        #expect(wider.moved(from: 5, .up) == 1)
        #expect(wider.moved(from: 2, .down) == 6)
    }
}
