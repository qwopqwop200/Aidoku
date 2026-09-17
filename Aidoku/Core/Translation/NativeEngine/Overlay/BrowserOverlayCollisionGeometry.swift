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

    /// Boolean callers need no total score: one qualifying intersection is
    /// enough. Preserve the same extent threshold as the full packing score.
    static func hasOverlap(in rects: [CGRect], external: [CGRect] = []) -> Bool {
        let geometry = rects.map(Self.init)
        let obstacles = external.map(Self.init)
        for left in geometry.indices {
            for right in (left + 1)..<geometry.count {
                if geometry[left].overlapArea(with: geometry[right], minimumExtent: 0.25) > 0 {
                    return true
                }
            }
            for obstacle in obstacles {
                if geometry[left].overlapArea(with: obstacle, minimumExtent: 0.25) > 0 {
                    return true
                }
            }
        }
        return false
    }

}
