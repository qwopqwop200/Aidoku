import Foundation

/// Same ordered rays, thresholds and arithmetic order as frozen r30.
enum NativeGradientShell {
    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
        init(_ values: [Double]) { r = values[0]; g = values[1]; b = values[2] }
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        func distance(_ other: RGB) -> Double {
            max(max(abs(r - other.r), abs(g - other.g)), abs(b - other.b))
        }
    }
    private struct Segment {
        let a: RGB
        let v: RGB
        let denominator: Double
        init(_ a: RGB, _ b: RGB) {
            self.a = a
            v = RGB(b.r - a.r, b.g - a.g, b.b - a.b)
            denominator = max(1, ((0 + v.r * v.r) + v.g * v.g) + v.b * v.b)
        }
        func error(_ c: RGB) -> Double {
            let dot = ((0 + (c.r - a.r) * v.r) + (c.g - a.g) * v.g) + (c.b - a.b) * v.b
            let t = max(0, min(1, dot / denominator))
            return max(max(abs(c.r - a.r - t * v.r), abs(c.g - a.g - t * v.g)), abs(c.b - a.b - t * v.b))
        }
    }
    static func recover(rgba: [UInt8], width: Int, height: Int, ownership: [UInt8], fill: [Double],
                        background: [Double], stroke: [Double]?) -> [String: Any]? {
        func rgb(_ p: Int) -> RGB { RGB(Double(rgba[4*p]), Double(rgba[4*p+1]), Double(rgba[4*p+2])) }
        guard width > 4, height > 4, width <= 4_194_304 / height,
              rgba.count == width * height * 4, ownership.count == width * height,
              [fill, background].allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.isFinite && (0...255).contains($0) }) }),
              stroke == nil || (stroke!.count == 3 && stroke!.allSatisfy({ $0.isFinite && (0...255).contains($0) })) else { return nil }
        let core = RGB(fill), surface = RGB(background)
        guard core.distance(surface) > 36 else { return nil }
        guard stroke == nil || RGB(stroke!).distance(surface) < 48 else { return nil }
        let reach = max(4, min(24, min(width, height)/8))
        let surfaceSegment = Segment(core, surface)
        var counts = [Int: Int](), sums = [Int: RGB](), origins = [Int: Set<Int>]()
        var samples = [RGB]()
        samples.reserveCapacity(reach)
        for y in 1..<(height-1) { for x in 1..<(width-1) {
            let p = y*width+x
            guard ownership[p] != 0, rgb(p).distance(core) <= 20 else { continue }
            for (dx, dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                let q = (y+dy)*width+x+dx
                guard rgb(q).distance(core) > 20 else { continue }
                samples.removeAll(keepingCapacity: true)
                for d in 1...reach {
                    let xx = x+dx*d, yy = y+dy*d
                    guard xx >= 0, yy >= 0, xx < width, yy < height, ownership[yy*width+xx] != 0 else { break }
                    samples.append(rgb(yy*width+xx))
                }
                guard samples.count >= 3 else { continue }
                guard let peak = samples.indices.max(by: { surfaceSegment.error(samples[$0]) < surfaceSegment.error(samples[$1]) }),
                      peak < samples.count-1 else { continue }
                let shell = samples[peak], error = surfaceSegment.error(shell)
                guard error >= 22, shell.distance(core) > 42, shell.distance(surface) > 32,
                      samples.suffix(from: peak+1).contains(where: { $0.distance(surface) <= 28 }) else { continue }
                let shellSegment = Segment(core, shell)
                guard samples.prefix(peak+1).allSatisfy({ shellSegment.error($0) <= 22 }) else { continue }
                let key = (Int(shell.r)/16)*256+(Int(shell.g)/16)*16+Int(shell.b)/16
                counts[key, default: 0] += 1
                var sum = sums[key] ?? RGB(0,0,0)
                sum.r += shell.r; sum.g += shell.g; sum.b += shell.b
                sums[key] = sum
                origins[key, default: []].insert((y*6/height)*6+x*6/width)
            }
        }}
        guard let key = counts.keys.sorted(by: { counts[$0]! == counts[$1]! ? $0 < $1 : counts[$0]! > counts[$1]! }).first,
              counts[key]! >= 64, origins[key]!.count >= 4 else { return nil }
        let sum = sums[key]!, count = Double(counts[key]!)
        let shell = [(sum.r/count).rounded(), (sum.g/count).rounded(), (sum.b/count).rounded()]
        guard stroke == nil || RGB(shell).distance(RGB(stroke!)) > 32 else { return nil }
        return ["rgb": shell, "rays": counts[key]!, "spatialSupport": origins[key]!.count,
                "authority": "ordered owned original core-shell-surface rays with AA segment rejection; not gold"]
    }
}
