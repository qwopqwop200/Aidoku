import CoreGraphics

/// Cache standardized edges once when scoring many placements against the same
/// obstacles. No temporary intersection CGRect or repeated edge extraction is
/// needed in the candidate loop. Nonpositive intersections contribute no area.
struct BrowserOverlayCollisionGeometry {
    let minX: CGFloat
    let minY: CGFloat
    let maxX: CGFloat
    let maxY: CGFloat

    init(_ rect: CGRect) {
        minX = rect.minX
        minY = rect.minY
        maxX = rect.maxX
        maxY = rect.maxY
    }

    func overlapArea(with other: Self, minimumExtent: CGFloat = 0) -> CGFloat {
        let width = min(maxX, other.maxX) - max(minX, other.minX)
        guard width > minimumExtent else { return 0 }
        let height = min(maxY, other.maxY) - max(minY, other.minY)
        guard height > minimumExtent else { return 0 }
        return width * height
    }
}
