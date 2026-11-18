import CoreGraphics
import Foundation

/// A temporal dependent clause followed by its request can share a handwritten
/// column block even when slant inflates their axis-aligned boxes. This is an
/// admission witness only: callers retain their ownership and speaker vetoes.
enum NativeOCRSlantedDependentColumns {
    struct Column {
        let id: Int
        let text: String
        let polygon: [CGPoint]
        let isVertical: Bool
    }

    static func accepts(
        _ first: Column, _ second: Column, nearby: [Column],
        ownershipSeparated: Bool, inkContrasted: Bool, polarityContrasted: Bool
    ) -> Bool {
        guard first.id != second.id, !ownershipSeparated, !inkContrasted, !polarityContrasted,
              let a = geometry(first), let b = geometry(second) else { return false }
        // Use quad centerlines, never inflated bounding-box widths, for order
        // and printed size. Reversing detector enumeration changes no decision.
        let right = a.center.x > b.center.x ? (first, a) : (second, b)
        let left = a.center.x > b.center.x ? (second, b) : (first, a)
        guard dependentRequest(right.0.text, left.0.text) else { return false }
        let width = min(a.width, b.width)
        let horizontal = right.1.center.x - left.1.center.x
        let overlap = min(a.bottom, b.bottom) - max(a.top, b.top)
        guard max(a.width, b.width) <= width * 1.35,
              abs(a.slant - b.slant) <= 0.12, a.slant * b.slant > 0,
              horizontal >= width * 0.35, horizontal <= width * 1.5,
              abs(a.top - b.top) <= width * 1.3,
              overlap >= min(a.length, b.length) * 0.7 else { return false }
        // A third column in this local block makes pair ownership ambiguous.
        // Do not use a short dependent phrase to bridge neighbouring speakers.
        return !nearby.contains { other in
            guard other.id != first.id, other.id != second.id,
                  let c = geometry(other) else { return false }
            let vertical = min(max(a.bottom, b.bottom), c.bottom) - max(min(a.top, b.top), c.top)
            return c.center.x >= left.1.center.x - width * 1.5
                && c.center.x <= right.1.center.x + width * 1.5
                && vertical > min(c.length, min(a.length, b.length)) * 0.35
        }
    }

    private static func dependentRequest(_ head: String, _ tail: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: "「」『』\"“”！？!?。:：")
        guard head.rangeOfCharacter(from: forbidden) == nil,
              tail.rangeOfCharacter(from: forbidden) == nil else { return false }
        let pause = CharacterSet(charactersIn: "…‥・. \n\t")
        let first = head.trimmingCharacters(in: pause)
        let second = tail.trimmingCharacters(in: pause)
        // A pause alone is not syntax. Require an unfinished temporal clause
        // and an explicit request ending, not two independent sentences.
        return first.count >= 4 && second.count >= 4
            && ["ときも", "時も", "ときは", "時は"].contains(where: first.hasSuffix)
            && ["てね", "でね", "てください", "でください"].contains(where: second.hasSuffix)
    }

    private struct Geometry {
        let center: CGPoint
        let width: CGFloat
        let length: CGFloat
        let top: CGFloat
        let bottom: CGFloat
        let slant: CGFloat
    }

    private static func geometry(_ column: Column) -> Geometry? {
        let p = column.polygon
        guard column.isVertical, p.count == 4,
              p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let top = CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2)
        let bottom = CGPoint(x: (p[2].x + p[3].x) / 2, y: (p[2].y + p[3].y) / 2)
        let width = (hypot(p[1].x - p[0].x, p[1].y - p[0].y)
            + hypot(p[2].x - p[3].x, p[2].y - p[3].y)) / 2
        let length = bottom.y - top.y
        let slant = atan2(bottom.x - top.x, length)
        guard width > 0, length >= width * 3, abs(slant) >= 0.1, abs(slant) <= 0.4 else { return nil }
        return Geometry(center: CGPoint(x: (top.x + bottom.x) / 2, y: (top.y + bottom.y) / 2),
                        width: width, length: length, top: top.y, bottom: bottom.y, slant: slant)
    }
}
