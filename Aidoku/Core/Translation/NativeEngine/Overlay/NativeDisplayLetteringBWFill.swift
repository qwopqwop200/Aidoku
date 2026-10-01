import Foundation

extension NativeDisplayLetteringPixels {
    static func fillBW(_ p: [UInt8],_ w: Int,_ h: Int,_ glyph: Double,_ inside: [UInt8],_ boxCount: Int,_ lum: [Float],_ best: Best,
        _ width: Double,_ reach: Double,_ mask: [UInt8],_ known: [UInt8],_ masked: Int,_ maskAll: Int,
        _ fillRGB: [Double]?,_ outlineRGB: [Double]?,_ mixed: Double,_ chroma: Double,_ ambiguity: Double,
        _ strokeRatio: Double,_ leftoverShare: Double,_ paperShare: Double) -> Result {
        let n = w*h, dist = best.dist, R = Int(max(8,min(32,floor(glyph*0.35+0.5))))
        struct Offset { var x: Int; var y: Int; var votes: Int }
        var histogram: [Offset] = [], seed: UInt32 = 12345
        func random()->Double { seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff; return Double(seed)/Double(0x7fffffff) }
        let candidates = (0..<n).filter { known[$0] != 0 && Double(dist[$0]) <= reach+glyph*0.4 && $0%w >= 4 && $0/w >= 4 && $0%w < w-4 && $0/w < h-4 }
        func patchOK(_ x: Int,_ y: Int)->Bool {
            for dy in stride(from: -4,through: 4,by: 2) { for dx in stride(from: -4,through: 4,by: 2) where known[(y+dy)*w+x+dx] == 0 { return false } }; return true
        }
        var selfCost = 0.0, selfCount = 0
        for _ in 0..<min(240,candidates.count) {
            let i = candidates[Int(floor(random()*Double(candidates.count)))], x = i%w, y = i/w
            if !patchOK(x,y) { continue }
            var bestCost = 1e9, bdx = 0, bdy = 0
            for oy in -R...R { let ty = y+oy; if ty < 4 || ty >= h-4 { continue }
                for ox in -R...R {
                    if abs(ox) < 3 && abs(oy) < 3 { continue }
                    let tx = x+ox; if tx < 4 || tx >= w-4 { continue }
                    var cost = 0.0
                    for dy in stride(from: -4,through: 4,by: 2) { if cost >= bestCost { break }
                        let r1 = (y+dy)*w+x, r2 = (ty+dy)*w+tx
                        for dx in stride(from: -4,through: 4,by: 2) { let j = r2+dx
                            if known[j] == 0 { cost = 1e9; break }; cost += abs(Double(lum[r1+dx])-Double(lum[j]))
                        }
                    }
                    if cost < bestCost { bestCost = cost; bdx = ox; bdy = oy }
                }
            }
            if bestCost >= 1e9 { continue }; selfCost += bestCost/25; selfCount += 1
            for (ax,ay) in [(bdx,bdy),(-bdx,-bdy)] {
                if let k = histogram.firstIndex(where: { $0.x == ax && $0.y == ay }) { histogram[k].votes += 1 }
                else { histogram.append(.init(x: ax,y: ay,votes: 1)) }
            }
        }
        if selfCount < 8 { return .init(reject: "bw-offsets") }; selfCost /= Double(selfCount)
        let peaks = histogram.enumerated().sorted { $0.element.votes == $1.element.votes ? $0.offset < $1.offset : $0.element.votes > $1.element.votes }.map(\.element)
        var offsets: [Offset] = []
        for peak in peaks { if offsets.count >= 8 { break }; if offsets.contains(where: { abs($0.x-peak.x) <= 1 && abs($0.y-peak.y) <= 1 }) { continue }; offsets.append(peak) }
        var shifts: [(Int,Int)] = []
        for (rank,o) in offsets.enumerated() { for k in 1...(rank < 3 ? 6 : 2) {
            let sx = o.x*k, sy = o.y*k; if Double(abs(sx)) > Double(w)/2 || Double(abs(sy)) > Double(h)/2 { break }
            if !shifts.contains(where: { $0.0 == sx && $0.1 == sy }) { shifts.append((sx,sy)) }
        } }
        let fromKnown = distance(known,w,h)
        let order = (0..<n).filter { mask[$0] != 0 }.sorted {
            let a = floor(Double(fromKnown[$0])*3+0.5)*1e7+Double($0), b = floor(Double(fromKnown[$1])*3+0.5)*1e7+Double($1); return a < b
        }
        var value = [Float](repeating: 0,count: n*3), avail = known, gv = lum, used = [Int](repeating: -1,count: n)
        for i in 0..<n { for c in 0..<3 { value[i*3+c] = Float(p[i*4+c]) } }
        let probe = [(-1,0),(1,0),(0,-1),(0,1),(-2,-2),(2,-2),(-2,2),(2,2),(-3,0),(3,0),(0,-3),(0,3)]
        func fillPixel(_ i: Int,_ need: Int)->Bool {
            let x = i%w, y = i/w; var bestBiased = 1e9, bestShift = -1, prefer = Set<Int>()
            for j in [i-1,i+1,i-w,i+w] where j >= 0 && j < n && used[j] >= 0 { prefer.insert(used[j]) }
            for (s,shift) in shifts.enumerated() {
                let tx = x+shift.0, ty = y+shift.1
                if tx < 0 || ty < 0 || tx >= w || ty >= h || avail[ty*w+tx] == 0 { continue }
                var cost = 0.0, count = 0
                for (dx,dy) in probe {
                    let xx = x+dx, yy = y+dy, sx = tx+dx, sy = ty+dy
                    if xx < 0 || xx >= w || yy < 0 || yy >= h || sx < 0 || sx >= w || sy < 0 || sy >= h { continue }
                    let a = yy*w+xx, b = sy*w+sx; if avail[a] == 0 || avail[b] == 0 { continue }
                    cost += abs(Double(gv[a])-Double(gv[b])); count += 1
                }
                if count < need { continue }; cost /= Double(count)
                let biased = prefer.contains(s) ? cost*0.75 : cost
                if biased < bestBiased { bestBiased = biased; bestShift = s }
            }
            if bestShift < 0 { return false }; let shift = shifts[bestShift], src = (y+shift.1)*w+x+shift.0
            for c in 0..<3 { value[i*3+c] = value[src*3+c] }; gv[i] = gv[src]; avail[i] = 1; used[i] = bestShift; return true
        }
        var pending = order.filter { !fillPixel($0,4) }
        for pass in 0..<3 { if pending.isEmpty { break }; pending = pending.filter { !fillPixel($0,pass == 0 ? 2 : 1) } }
        if Double(pending.count) > Double(maskAll)*0.02 { return .init(reject: "bw-unmatched \(pending.count)") }
        for i in pending { let x = i%w; var count = 0, sum = [Double](repeating: 0,count: 3)
            for j in [i-1,i+1,i-w,i+w,i-w-1,i-w+1,i+w-1,i+w+1] where j >= 0 && j < n && abs(j%w-x) <= 1 && avail[j] != 0 {
                count += 1; for c in 0..<3 { sum[c] += Double(value[j*3+c]) }
            }
            if count > 0 { for c in 0..<3 { value[i*3+c] = Float(sum[c]/Double(count)) } }
        }
        let radius = Int(max(3,min(8,floor(glyph*0.05+0.5))))
        func blur(_ src: [Float])->[Float] {
            var tmp = [Float](repeating: 0,count: n*3), out = tmp
            for y in 0..<h { for c in 0..<3 { var sum = 0.0; let row = y*w
                for x in -radius...radius { sum += Double(src[(row+min(w-1,max(0,x)))*3+c]) }
                for x in 0..<w { tmp[(row+x)*3+c] = Float(sum/Double(2*radius+1))
                    sum += Double(src[(row+min(w-1,x+radius+1))*3+c])-Double(src[(row+max(0,x-radius))*3+c])
                }
            } }
            for x in 0..<w { for c in 0..<3 { var sum = 0.0
                for y in -radius...radius { sum += Double(tmp[(min(h-1,max(0,y))*w+x)*3+c]) }
                for y in 0..<h { out[(y*w+x)*3+c] = Float(sum/Double(2*radius+1))
                    sum += Double(tmp[(min(h-1,y+radius+1)*w+x)*3+c])-Double(tmp[(max(0,y-radius)*w+x)*3+c])
                }
            } }; return out
        }
        var donors = [UInt8](repeating: 0,count: n), base = [Float](repeating: 0,count: n*3), weight = base
        for i in 0..<n where known[i] != 0 { for c in 0..<3 { base[i*3+c] = Float(p[i*4+c]); weight[i*3+c] = 1 } }
        var blurredSource = blur(base); let blurredWeight = blur(weight)
        for i in 0..<n { let wgt = Double(blurredWeight[i*3]); donors[i] = known[i] != 0 && wgt > 0.2 ? 1 : 0
            for c in 0..<3 { blurredSource[i*3+c] = donors[i] != 0 ? Float(Double(blurredSource[i*3+c])/wgt) : 0 }
        }
        guard NativeSlantedInkSafety.pushPull(values: &blurredSource,known: donors,width: w,height: h) else { return .init(reject: "bw-diffusion") }
        let smooth = selfCost < 2.5 || chroma > 40
        if smooth && mixed > 0.12 { return .init(reject: "bw-mixed \(fixed(mixed,2))") }
        var raw = [Float](repeating: 0,count: n*3)
        if smooth { for i in 0..<n { for c in 0..<3 { raw[i*3+c] = Float(p[i*4+c]) } }
            guard NativeSlantedInkSafety.pushPull(values: &raw,known: known,width: w,height: h) else { return .init(reject: "bw-diffusion") }
        }
        let low = blur(value); var invented = 0
        for i in 0..<n where mask[i] != 0 { var gap = 0.0
            for c in 0..<3 { let d = Double(low[i*3+c])-Double(blurredSource[i*3+c]), excess = d-max(-40,min(40,d)); gap = max(gap,abs(d))
                value[i*3+c] = smooth ? raw[i*3+c] : Float(max(0,min(255,Double(value[i*3+c])-excess)))
            }; if gap > 48 { invented += 1 }
        }
        let inventedShare = Double(invented)/Double(max(1,maskAll)), blobArea = max(30,pow(glyph*0.06,2))
        let rl = (0..<n).map { mask[$0] != 0 ? Float(Double(value[$0*3])*0.299+Double(value[$0*3+1])*0.587+Double(value[$0*3+2])*0.114) : lum[$0] }
        func blobs(_ source: [Float],_ region: (Int)->Bool)->Int {
            var seen = [UInt8](repeating: 0,count: n), area = 0
            let f: (Int)->Bool = { best.polarity == "dark" ? source[$0] < 96 : source[$0] > 168 }
            let o: (Int)->Bool = { best.polarity == "dark" ? source[$0] > 150 : source[$0] < 110 }
            for s in 0..<n where f(s) && seen[s] == 0 && region(s) {
                var queue = [s], head = 0, a = 0, ring = 0, ringO = 0; seen[s] = 1
                while head < queue.count { let i = queue[head]; head += 1; a += 1
                    for j in neighbours(i,w,n) where seen[j] == 0 {
                        if f(j) { seen[j] = 1; queue.append(j) } else { ring += 1; if o(j) { ringO += 1 } }
                    }
                }
                if Double(a) >= blobArea && ring > 0 && Double(ringO) >= Double(ring)*0.6 { area += a }
            }; return area
        }
        let near: (Int)->Bool = { inside[$0] != 0 && Double(dist[$0]) <= reach+glyph*0.25 }
        let far: (Int)->Bool = { inside[$0] == 0 && Double(dist[$0]) > reach+glyph*0.25 }
        let residual = Double(blobs(rl,near))/Double(max(1,(0..<n).filter(near).count))
        let baseline = Double(blobs(lum,far))/Double(max(1,(0..<n).filter(far).count))
        if inventedShare > 0.2 { return .init(reject: "bw-invented \(fixed(inventedShare,2))") }
        if residual > baseline*1.5+0.03 { return .init(reject: "bw-residual \(fixed(residual,3)) \(fixed(baseline,3))") }
        var result = Result(); result.output = [UInt8](repeating: 0,count: n*4)
        for i in 0..<n where mask[i] != 0 { for c in 0..<3 { result.output[i*4+c] = byte(Double(value[i*3+c])) }; result.output[i*4+3] = 255 }
        result.fill = fillRGB; result.outline = outlineRGB; result.width = width; result.ends = best.ends
        result.masked = Double(masked)/Double(boxCount); result.polarity = best.polarity
        result.stats = ["mixed": mixed,"chroma": chroma,"ambiguity": ambiguity,"strokeRatio": strokeRatio,
            "leftoverShare": leftoverShare,"paperShare": paperShare,"smooth": smooth,"inventedShare": inventedShare,
            "selfCost": selfCost,"residual": residual,"baseline": baseline]
        return result
    }
}
