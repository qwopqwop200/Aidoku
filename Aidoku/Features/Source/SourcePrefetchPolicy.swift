import UIKit

enum SourcePrefetchPolicy {
    /// Only changes when one next-page request starts; never fans out pages or
    /// retains decoded covers. Fast scrolling gets at most two screenfuls.
    @MainActor static func threshold(for view: UICollectionView) -> Int {
        let visible = max(1, view.indexPathsForVisibleItems.count)
        let speed = abs(view.panGestureRecognizer.velocity(in: view).y)
        let screensPerSecond = speed / max(1, view.bounds.height)
        let lookahead = Double(visible) * (1 + min(1, Double(screensPerSecond) * 0.7))
        return min(24, max(6, Int(lookahead.rounded(.up))))
    }
}
