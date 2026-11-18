import CoreGraphics
import Foundation

/// Source-only neutral ink inside a bright shell, corroborated by exterior surface.
/// No text, identity, prediction cache, restored pixels, or removal mask is read.
enum NativeNeutralShellObserver {
    struct Observation {
        let fill: [Double]
        let stroke: [Double]
        let evidence: [String: Any]
    }

    static func observe(original: CGImage, bounds: [Double], geometry: [String: Any]) -> Observation? {
        guard bounds.count == 4, bounds.allSatisfy(\.isFinite), bounds[0] >= 0, bounds[1] >= 0,
              bounds[2] > 0, bounds[3] > 0, bounds[0]+bounds[2] <= 1.000001,
              bounds[1]+bounds[3] <= 1.000001 else { return nil }
        let iw = Double(original.width), ih = Double(original.height)
        let box = CGRect(x: bounds[0]*iw, y: bounds[1]*ih, width: bounds[2]*iw, height: bounds[3]*ih)
        let crop = box.insetBy(dx: -12, dy: -12).integral.intersection(CGRect(x: 0,y: 0,width: iw,height: ih))
        guard let image = original.cropping(to: crop) else { return nil }
        // Bounded observation of every owner, never a page-budget skip.
        let scale = min(1, sqrt(262144 / (crop.width*crop.height)))
        let w = Int(crop.width*scale), h = Int(crop.height*scale)
        guard w >= 5, h >= 5 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data: bytes.baseAddress,width: w,height: h,bitsPerComponent: 8,
                bytesPerRow: w*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.interpolationQuality = .high; c.draw(image,in: CGRect(x: 0,y: 0,width: w,height: h)); return true
        }
        guard ok else { return nil }
        let polygon = geometry["sourcePolygon"] as? [[Double]] ?? [
            [bounds[0],bounds[1]],[bounds[0]+bounds[2],bounds[1]],
            [bounds[0]+bounds[2],bounds[1]+bounds[3]],[bounds[0],bounds[1]+bounds[3]]]
        guard polygon.count >= 3, polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let path = CGMutablePath()
        path.addLines(between: polygon.map { CGPoint(x: ($0[0]*iw-crop.minX)*scale,y: ($0[1]*ih-crop.minY)*scale) })
        path.closeSubpath()
        func rgb(_ p: Int) -> [Double] { (0..<3).map { Double(pixels[p*4+$0]) } }
        func distance(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).map { abs($0-$1) }.max()! }
        func white(_ p: Int) -> Bool { let c = rgb(p); return c.min()! >= 232 && c.max()!-c.min()! <= 18 }
        var owned = [Bool](repeating: false,count: w*h)
        for y in 0..<h { for x in 0..<w { owned[y*w+x] = path.contains(CGPoint(x: Double(x)+0.5,y: Double(y)+0.5)) } }
        let reach = max(4,min(20,Int(min(box.width,box.height)*scale*0.32)))
        var candidates = [Int: [Int]](), surfaces = [Int: [[Double]]](), shellPixels = [Int: Set<Int>]()
        for y in 1..<(h-1) { for x in 1..<(w-1) {
            let p = y*w+x, c = rgb(p)
            guard owned[p], pixels[p*4+3] >= 250, c.min()! >= 28, c.max()! <= 220,
                  c.max()!-c.min()! <= 18,
                  [p-1,p+1,p-w,p+w].filter({ distance(rgb($0),c) <= 12 }).count >= 2 else { continue }
            var whiteHits = [Int](), outside = [[Double]](), directions = [Bool]()
            for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                var hit: Int?, exterior: [Double]?
                for d in 1...reach {
                    let xx = x+dx*d, yy = y+dy*d
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { break }
                    let q = yy*w+xx
                    if white(q) { hit = q }
                    else if hit != nil {
                        let e = rgb(q)
                        // Cross antialias transition before testing the exterior surface.
                        if e.min()! < 220 && distance(e,c) >= 30 {
                            exterior = e; break
                        }
                    } else {
                        let e = rgb(q)
                        // A neutral brightening ramp belongs to the shell edge.
                        if e.max()!-e.min()! > 30 || e.min()! < c.min()!-24 { break }
                    }
                }
                directions.append(hit != nil)
                if let hit { whiteHits.append(hit) }
                if let exterior { outside.append(exterior) }
            }
            // Opposite bright sides + distinct backing beyond shell, not a bbox mode.
            guard (directions[0] && directions[1]) || (directions[2] && directions[3]),
                  outside.count >= 2 else { continue }
            let key = Int((c.reduce(0,+)/3)/16)
            candidates[key,default: []].append(p)
            surfaces[key,default: []].append(contentsOf: outside)
            shellPixels[key,default: []].formUnion(whiteHits)
        }}
        for key in candidates.keys.sorted(by: { candidates[$0]!.count == candidates[$1]!.count ? $0 < $1 : candidates[$0]!.count > candidates[$1]!.count }) {
            let seeds = Set(candidates[key]!), n = seeds.count
            guard n >= 12, shellPixels[key]!.count >= 12 else { continue }
            // Require independent spatial repetition; isolated highlights are insufficient.
            var unseen = seeds, components = [[Int]]()
            while let start = unseen.first {
                unseen.remove(start); var queue = [start], i = 0
                while i < queue.count {
                    let p = queue[i]; i += 1
                    for q in [p-1,p+1,p-w,p+w] where unseen.contains(q) { unseen.remove(q); queue.append(q) }
                }
                if queue.count >= 3 { components.append(queue) }
            }
            guard components.count >= 2 else { continue }
            let used = components.flatMap { $0 }, tiles = Set(used.map { (($0/w)*6/h)*6+($0%w)*6/w })
            guard used.count >= 12, tiles.count >= 3 else { continue }
            let fill = (0..<3).map { k in (used.map { Double(pixels[$0*4+k]) }.reduce(0,+)/Double(used.count)).rounded() }
            let edge = shellPixels[key]!
            let stroke = (0..<3).map { k in (edge.map { Double(pixels[$0*4+k]) }.reduce(0,+)/Double(edge.count)).rounded() }
            return .init(fill: fill,stroke: stroke,evidence: ["corePixels": used.count,"components": components.count,
                "repeatedTiles": tiles.count,"shellPixels": edge.count,"exteriorSurfaceProbes": surfaces[key]!.count,
                "sampleScale": scale,"authority": "owned neutral stable core, opposite bright shell, distinct exterior source surface; no GT"])
        }
        return nil
    }
}
