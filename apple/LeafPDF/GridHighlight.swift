/// Where an arrow key moves the highlight in a grid of equal cells filled row
/// by row. Cells are numbered from 0 at the top left.
struct GridHighlight {
    enum Arrow { case up, down, left, right }

    let columns: Int
    /// Every cell, including a "+" cell if there is one. At least 1.
    let cellCount: Int

    /// The cell highlighted after `arrow`, from `current` (nil: nothing yet).
    /// The first press highlights the first cell. Moves past an edge stay
    /// put, and so does Left/Right at a row's end (no wrapping). Down into the
    /// last, partial row goes to its last cell.
    func moved(from current: Int?, _ arrow: Arrow) -> Int {
        guard let current else { return 0 }
        let last = cellCount - 1
        let cell = min(current, last)
        let column = cell % columns
        switch arrow {
        case .left: return column > 0 ? cell - 1 : cell
        case .right: return column < columns - 1 && cell < last ? cell + 1 : cell
        case .up: return cell >= columns ? cell - columns : cell
        case .down:
            if cell + columns <= last { return cell + columns }
            let isInLastRow = cell / columns == last / columns
            return isInLastRow ? cell : last
        }
    }
}
