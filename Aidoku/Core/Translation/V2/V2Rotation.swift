import CoreGraphics
import Foundation

// Source lettering tilt (legacy NativeSourceTextRotation): each quad votes with its longer
// edge pair; a length-weighted consensus near the median wins, and under 2.5 degrees is upright.
enum V2Rotation {
    static let agreement = CGFloat.pi / 90
    static let maximum = CGFloat.pi / 6
    static let minimum = CGFloat.pi / 72
    static let consensus: CGFloat = 0.6

    /// Radians, positive clockwise in top-left page coordinates; 0 when upright or unclear.
    static func angle(_ block: V2Block) -> CGFloat {
        var votes: [(angle: CGFloat, weight: CGFloat)] = []
        for line in block.lines where line.polygon.count == 4 {
            let p = line.polygon
            func edge(_ i: Int) -> (angle: CGFloat, length: CGFloat) {
                let a = p[i], b = p[(i + 1) % 4]
                let raw = atan2(b.y - a.y, b.x - a.x)
                // Fold into [-45, 45) degrees: the text direction modulo quarter turns.
                var folded = (raw + .pi / 4).truncatingRemainder(dividingBy: .pi / 2)
                if folded < 0 { folded += .pi / 2 }
                return (folded - .pi / 4, hypot(b.x - a.x, b.y - a.y))
            }
            let edges = (0..<4).map(edge)
            let pair = edges[0].length + edges[2].length >= edges[1].length + edges[3].length ? (0, 2) : (1, 3)
            let first = edges[pair.0], second = edges[pair.1]
            guard abs(first.angle - second.angle) <= agreement else { continue }
            let value = (first.angle + second.angle) / 2
            guard abs(value) <= maximum, value.isFinite else { continue }
            votes.append((value, first.length + second.length))
        }
        let total = votes.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        let sorted = votes.sorted { $0.angle < $1.angle }
        var running: CGFloat = 0
        var median: CGFloat = 0
        for vote in sorted {
            running += vote.weight
            if running * 2 >= total { median = vote.angle; break }
        }
        let near = votes.filter { abs($0.angle - median) <= agreement }
        let weight = near.reduce(0) { $0 + $1.weight }
        guard weight >= total * consensus, weight > 0 else { return 0 }
        let mean = near.reduce(0) { $0 + $1.angle * $1.weight } / weight
        return abs(mean) < minimum ? 0 : mean
    }

    /// Axis-aligned bounds of `rect` rotated by `angle` about its centre.
    static func bounds(_ rect: CGRect, angle: CGFloat) -> CGRect {
        guard angle != 0 else { return rect }
        let c = abs(cos(angle)), s = abs(sin(angle))
        let width = rect.width * c + rect.height * s, height = rect.width * s + rect.height * c
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// The largest unrotated extent whose rotation by `angle` fits `box`, or nil when the
    /// box is too narrow for that tilt.
    static func inscribed(_ box: CGSize, angle: CGFloat) -> CGSize? {
        let c = abs(cos(angle)), s = abs(sin(angle)), d = c * c - s * s
        guard d > 0.2 else { return nil }
        let width = (box.width * c - box.height * s) / d, height = (box.height * c - box.width * s) / d
        return width >= 1 && height >= 1 ? CGSize(width: width, height: height) : nil
    }
}
