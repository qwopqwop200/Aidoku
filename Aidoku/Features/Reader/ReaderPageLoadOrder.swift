enum ReaderPageLoadOrder {
    /// Reorder the existing bounded window; never widen it or decode more pages.
    static func indices(in range: ClosedRange<Int>, pageCount: Int, currentPage: Int, visible: Set<Int>) -> [Int] {
        let lower = max(1, range.lowerBound)
        let upper = min(pageCount, range.upperBound)
        guard lower <= upper else { return [] }
        return (lower...upper).sorted { lhs, rhs in
            let lhsVisible = lhs == currentPage || visible.contains(lhs)
            let rhsVisible = rhs == currentPage || visible.contains(rhs)
            if lhsVisible != rhsVisible { return lhsVisible }
            let lhsDistance = abs(lhs - currentPage)
            let rhsDistance = abs(rhs - currentPage)
            return lhsDistance == rhsDistance ? lhs > rhs : lhsDistance < rhsDistance
        }
    }
}
