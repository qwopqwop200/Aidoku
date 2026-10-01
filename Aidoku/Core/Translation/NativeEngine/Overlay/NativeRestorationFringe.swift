import CoreGraphics
import Foundation

extension NativeRestorationPixels {
    static func refineFringe(_ original: Self, repaired: Self, outlined: Bool, foreground: NativeRestorationRGB?) -> Self {
        guard let safe = repaired.layoutSafe else { return repaired }
        var output = repaired
        if let foreground, foreground.maximum - foreground.minimum >= 90 {
            let hue = foreground.channels.map { ($0 - foreground.minimum) * 255 / (foreground.maximum - foreground.minimum) }
            var remaining = [UInt8](repeating: 0, count: original.count)
            for y in 2..<original.height - 2 {
                for x in 2..<original.width - 2 {
                    let index = y * original.width + x, color = original.color(index), span = color.maximum - color.minimum
                    guard output.rgba[index * 4 + 3] == 0, (!outlined || color.distance(foreground) <= 48), span >= 30 else { continue }
                    if zip(color.channels.map { ($0 - color.minimum) * 255 / span }, hue).map({ abs($0 - $1) }).max()! <= 45 { remaining[index] = 1 }
                }
            }
            var changed = 0
            for part in original.components(remaining) {
                guard part.points.count <= (outlined ? 512 : 16), changed + part.points.count <= (outlined ? 2048 : 128) else { continue }
                var patches: [(Int, NativeRestorationRGB)] = []
                for index in part.points {
                    let x = index % original.width, y = index / original.width, radius = outlined ? 6 : 3
                    var donors: [Int] = []
                    for yy in max(0, y - radius)...min(original.height - 1, y + radius) {
                        for xx in max(0, x - radius)...min(original.width - 1, x + radius) {
                            let next = yy * original.width + xx
                            if output.rgba[next * 4 + 3] == 255, safe[next] != 0 { donors.append(next) }
                        }
                    }
                    guard donors.count >= 4 else { break }
                    let color = NativeRestorationRGB((0..<3).map { channel in
                        floor(donors.reduce(0.0) { $0 + Double(output.rgba[$1 * 4 + channel]) } / Double(donors.count) + 0.5)
                    })
                    patches.append((index, color))
                }
                guard patches.count == part.points.count else { continue }
                for (index, color) in patches { output.paint(index, color); output.layoutSafe?[index] = 1 }
                changed += patches.count
            }
        }
        for _ in 0..<2 {
            var patches: [(Int, NativeRestorationRGB)] = []
            for y in 2..<original.height - 2 {
                for x in 2..<original.width - 2 {
                    let index = y * original.width + x, color = original.color(index)
                    guard output.rgba[index * 4 + 3] == 0, output.layoutSafe?[index] != 0,
                          color.minimum >= 240, color.maximum - color.minimum <= 20 else { continue }
                    let donors = original.neighbors(index).filter { output.rgba[$0 * 4 + 3] == 255 && output.layoutSafe?[$0] != 0 }
                    guard donors.count >= 3 else { continue }
                    let fill = NativeRestorationRGB((0..<3).map { channel in
                        donors.reduce(0.0) { $0 + Double(output.rgba[$1 * 4 + channel]) } / Double(donors.count)
                    })
                    guard fill.maximum <= 238, fill.minimum >= 150, color.minimum - fill.maximum >= 8 else { continue }
                    patches.append((index, fill))
                }
            }
            if patches.isEmpty { break }
            for (index, color) in patches { output.paint(index, color) }
        }
        return output
    }
}
