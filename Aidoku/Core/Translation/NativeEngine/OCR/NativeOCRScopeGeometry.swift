// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

@available(iOS 18.0, *)
enum NativeOCRScopeGeometry {
    /// Clockwise quad with its upper cross-edge first. Sorting into left/right
    /// halves turns a clockwise-leaning vertical crop upside down. Select an
    /// actual edge instead, independent of the detector's starting vertex.
    static func canonicalQuad(_ points: [CGPoint], vertical: Bool? = nil) -> [CGPoint]? {
        if NativeOCRDirectionGeometry.enabled("quad") {
            return NativeOCRDirectionGeometry.readingQuad(points, vertical: vertical)
        }
        guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let center = CGPoint(x: points.reduce(0) { $0 + $1.x } / 4,
                             y: points.reduce(0) { $0 + $1.y } / 4)
        let ordered = points.sorted { atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x) }
        let lengths = (0..<4).map { hypot(ordered[($0 + 1) % 4].x - ordered[$0].x, ordered[($0 + 1) % 4].y - ordered[$0].y) }
        guard let shortest = lengths.min(), let longest = lengths.max(), shortest > 0 else { return nil }
        let candidates = (0..<4).filter { i in
            let dx = ordered[(i + 1) % 4].x - ordered[i].x
            guard dx > 0 else { return false }
            guard let vertical, longest > shortest * 1.25 else { return true }
            return vertical ? lengths[i] < (shortest + longest) / 2 : lengths[i] > (shortest + longest) / 2
        }
        guard let start = candidates.min(by: { a, b in
            abs(ordered[(a + 1) % 4].y - ordered[a].y) / lengths[a]
                < abs(ordered[(b + 1) % 4].y - ordered[b].y) / lengths[b]
        }) else { return nil }
        return (0..<4).map { ordered[(start + $0) % 4] }
    }

    static func isLatinWord(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.count >= 2 && letters.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
    }

    static func alternateHorizontalQuad(_ points: [CGPoint]) -> [CGPoint]? {
        if NativeOCRDirectionGeometry.enabled("latin") {
            guard var target = NativeOCRDirectionGeometry.directedQuad(points, longAlong: false),
                  let size = NativeOCRDirectionGeometry.edgeSize(target), size.width >= size.height * 1.1,
                  let original = canonicalQuad(points) else { return nil }
            let dx = target[1].x+target[2].x-target[0].x-target[3].x
            let dy = target[1].y+target[2].y-target[0].y-target[3].y
            // Detector vertex zero is untyped. Equivalent 180-degree cyclic
            // starts must not turn alternating words into opposite baselines.
            if dx < -0.000001 || (abs(dx) <= 0.000001 && dy < 0) {
                target = [target[2],target[3],target[0],target[1]]
            }
            return target == original ? nil : target
        }
        guard let canonical = canonicalQuad(points) else { return nil }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        let left = Array(sorted.prefix(2)).sorted { $0.y < $1.y }
        let right = Array(sorted.suffix(2)).sorted { $0.y < $1.y }
        let alternate = [left[0], right[0], right[1], left[1]]
        let width = hypot(alternate[1].x - alternate[0].x, alternate[1].y - alternate[0].y)
        let height = hypot(alternate[3].x - alternate[0].x, alternate[3].y - alternate[0].y)
        let a = atan2(alternate[1].y - alternate[0].y, alternate[1].x - alternate[0].x)
        let b = atan2(canonical[1].y - canonical[0].y, canonical[1].x - canonical[0].x)
        guard width >= height * 1.1, abs(a) >= .pi / 60, abs(a) <= 80 * .pi / 180,
              abs(a - b) > .pi / 3 else { return nil }
        return alternate
    }

    static func bounds(for polygon: [CGPoint]) -> CGRect? {
        guard let minimumX = polygon.map(\.x).min(),
              let maximumX = polygon.map(\.x).max(),
              let minimumY = polygon.map(\.y).min(),
              let maximumY = polygon.map(\.y).max(),
              minimumX.isFinite,
              maximumX.isFinite,
              minimumY.isFinite,
              maximumY.isFinite,
              maximumX > minimumX,
              maximumY > minimumY
        else {
            return nil
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        ).standardized
    }

    static func intersectionArea(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.standardized.intersection(right.standardized)
        guard !intersection.isNull,
              !intersection.isEmpty,
              intersection.width.isFinite,
              intersection.height.isFinite
        else {
            return 0
        }
        let area = intersection.width * intersection.height
        return area.isFinite && area > 0 ? area : 0
    }
}
