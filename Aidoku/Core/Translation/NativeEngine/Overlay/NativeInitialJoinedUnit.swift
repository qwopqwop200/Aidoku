import CoreGraphics
import Foundation

/// Joined captions keep their planned line length while moving onto native balloon bands.
/// Runs after restoration establishes residue ownership and before initial typography.
enum NativeInitialJoinedUnit {
    struct Entry {
        var rect: CGRect
        var font: Double
        var frame: [Double]
        var source: [Double]
        var interior: [Double] = []
        var spans: [Double] = []
        var joined = false
        var residue = false
        var rotated = false
        var vertical = false
        var kept = false
        var planned: CGRect?
    }

    static func fit(_ input: [Entry]) -> [Entry] {
        var entries = input
        for index in entries.indices {
            let e = entries[index], f = e.frame, r = e.interior, spans = e.spans
            guard e.joined, !e.kept, !e.residue, !e.rotated, !e.vertical,
                  f.count == 4, f.allSatisfy(\.isFinite), r.count == 4, r.allSatisfy(\.isFinite),
                  spans.count >= 2, spans.count.isMultiple(of: 2), spans.allSatisfy(\.isFinite),
                  [e.rect.origin.x, e.rect.origin.y, e.rect.size.width, e.rect.size.height].allSatisfy(\.isFinite)
            else { continue }
            let count = spans.count / 2, top = f[1] + r[1] * f[3], band = r[3] * f[3] / Double(count)
            guard band.isFinite, band > 0 else { continue }
            let runs: [(Double, Double)?] = (0..<count).map { i in
                spans[2 * i] >= 0 && spans[2 * i + 1] > spans[2 * i]
                    ? (f[0] + spans[2 * i] * f[2], f[0] + spans[2 * i + 1] * f[2]) : nil
            }
            let font = e.font.isFinite && e.font != 0 ? e.font : 10
            let margin = max(2, font * 0.25)
            let x = Double(e.rect.origin.x), y = Double(e.rect.origin.y)
            let width = Double(e.rect.size.width), height = Double(e.rect.size.height)
            let first = floor((y - margin - top) / band), last = floor((y + height + margin - top - 1e-6) / band)
            if first >= 0, last < Double(count), last >= first {
                let inside = (Int(first)...Int(last)).allSatisfy { i in
                    guard let run = runs[i] else { return false }
                    return x - margin >= run.0 && x + width + margin <= run.1
                }
                if inside { continue }
            }
            // Earlier accepted units are already moved, matching the original sequential pass.
            var others: [[Double]] = []
            for otherIndex in entries.indices where otherIndex != index {
                let other = entries[otherIndex], o = other.rect
                let values = [Double(o.origin.x), Double(o.origin.y), Double(o.size.width), Double(o.size.height)]
                if values.allSatisfy(\.isFinite) {
                    others.append([values[0], values[1], values[0] + values[2], values[1] + values[3]])
                }
                let g = other.frame, b = other.source
                if g.count == 4, b.count == 4, (g + b).allSatisfy(\.isFinite) {
                    others.append([g[0] + b[0] * g[2], g[1] + b[1] * g[3],
                                   g[0] + (b[0] + b[2]) * g[2], g[1] + (b[1] + b[3]) * g[3]])
                }
            }
            let cx = x + width / 2, cy = y + height / 2
            var best: (score: Double, rect: CGRect)?
            for i in 0..<count {
                var left = -Double.infinity, right = Double.infinity
                for j in i..<count {
                    guard let run = runs[j] else { break }
                    left = max(left, run.0); right = min(right, run.1)
                    let w = right - left - 2 * margin, h = Double(j - i + 1) * band - 2 * margin
                    if w <= 0 { break }
                    if h <= 0 { continue }
                    let x0 = left + margin, y0 = top + Double(i) * band + margin
                    let score = w * h - hypot(x0 + w / 2 - cx, y0 + h / 2 - cy) * min(w, h) * 0.5
                    if w >= width * 0.9, best == nil || score > best!.score,
                       !others.contains(where: { x0 < $0[2] && x0 + w > $0[0] && y0 < $0[3] && y0 + h > $0[1] }) {
                        best = (score, CGRect(x: x0, y: y0, width: w, height: h))
                    }
                }
            }
            guard let best, best.rect.width >= width * 0.9, best.rect.height >= font * 1.2 else { continue }
            entries[index].planned = e.rect
            entries[index].rect = best.rect
        }
        return entries
    }
}
