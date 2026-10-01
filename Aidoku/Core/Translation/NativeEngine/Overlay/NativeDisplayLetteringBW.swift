import CoreGraphics
import Foundation

extension NativeDisplayLetteringPixels {
    struct Component {
        var id: Int; var area = 0; var core = 0; var coreInside = 0; var maxR = 0.0; var edge = false
        var x0: Int; var y0: Int; var x1 = 0; var y1 = 0
    }
    struct Part {
        var id: Int; var core = 0; var coreInside = 0; var maxR = 0.0; var edge = false
        var ring = 0; var ringO = 0; var m = [Double](repeating: 0,count: 6)
        var across = 0.0; var along = 0.0; var art = false; var ok = false
    }
    struct Best {
        var polarity: String; var fill: [UInt8]; var dist: [Float]; var width: Double; var ends: Bool
        var score: Double; var rCore: Int; var bandRGB: [Double]; var label: [Int]; var comps: [Component]
        var thick: [Float]; var strokeR: Double; var partOf: [Int]?; var parts: [Part]
    }
    static func blackWhite(rgba p: [UInt8],width w: Int,height h: Int,box: CGRect,glyph: Double,borders: [Bool] = []) -> Result {
        guard valid(p,w,h,glyph) else { return .init(reject: "bw-size") }
        let n = w*h, (inside,boxCount) = inside(w,h,box)
        guard boxCount >= 64 else { return .init(reject: "bw-size") }
        let bx0 = max(0,floor(Double(box.minX)+0.5)), by0 = max(0,floor(Double(box.minY)+0.5))
        let bx1 = min(Double(w),floor(Double(box.maxX)+0.5)), by1 = min(Double(h),floor(Double(box.maxY)+0.5))
        var lum = [Float](repeating: 0,count: n)
        for i in 0..<n { let r = Double(p[i*4]), g = Double(p[i*4+1]), b = Double(p[i*4+2]); lum[i] = Float(r*0.299+g*0.587+b*0.114) }
        let rMin = max(1.5,glyph*0.035)
        func atBorder(_ x: Int,_ y: Int) -> Bool {
            (x == 0 && !(borders.count > 0 && borders[0])) || (y == 0 && !(borders.count > 1 && borders[1])) ||
            (x == w-1 && !(borders.count > 2 && borders[2])) || (y == h-1 && !(borders.count > 3 && borders[3]))
        }
        var best: Best?, reasons: [String] = [], unexplainedBy: [String:Int] = [:], valid: [String] = []
        for polarity in ["dark","light"] {
            let isF: (Int)->Bool = { polarity == "dark" ? lum[$0] < 96 : lum[$0] > 168 }
            let isO: (Int)->Bool = { polarity == "dark" ? lum[$0] > 150 : lum[$0] < 110 }
            let F = (0..<n).map { UInt8(isF($0) ? 1 : 0) }, thick = distance(F.map { 1-$0 },w,h)
            var label = [Int](repeating: -1,count: n), comps: [Component] = []
            for s in 0..<n where F[s] != 0 && label[s] < 0 {
                var c = Component(id: comps.count,x0: w,y0: h), queue = [s], head = 0; label[s] = c.id
                while head < queue.count { let i = queue[head], x = i%w, y = i/w; head += 1; c.area += 1
                    if Double(thick[i]) >= rMin { c.core += 1; if inside[i] != 0 { c.coreInside += 1 } }
                    c.maxR = max(c.maxR,Double(thick[i])); if atBorder(x,y) { c.edge = true }
                    c.x0 = min(c.x0,x); c.x1 = max(c.x1,x); c.y0 = min(c.y0,y); c.y1 = max(c.y1,y)
                    for j in neighbours(i,w,n) where F[j] != 0 && label[j] < 0 { label[j] = c.id; queue.append(j) }
                }
                comps.append(c)
            }
            let cDist = distance(F,w,h)
            var ringAll = [Double](repeating: 0,count: comps.count), ringO = ringAll
            var near = [Int](repeating: -1,count: n), queue: [Int] = [], head = 0
            for i in 0..<n where F[i] != 0 { near[i] = label[i]; queue.append(i) }
            while head < queue.count { let i = queue[head]; head += 1
                for j in neighbours(i,w,n) where near[j] < 0 && cDist[j] <= 2.5 { near[j] = near[i]; queue.append(j) }
            }
            for i in 0..<n where F[i] == 0 && near[i] >= 0 && cDist[i] <= 2.5 { ringAll[near[i]] += 1; if isO(i) { ringO[near[i]] += 1 } }
            func ringOf(_ c: Component)->Double { ringAll[c.id] > 0 ? ringO[c.id]/ringAll[c.id] : 0 }
            var accepted = [UInt8](repeating: 0,count: comps.count), coreAccepted = 0, unexplained = 0, radii: [Double] = []
            for c in comps where c.core > 0 && Double(c.coreInside) >= Double(c.core)*0.5 && c.maxR <= glyph*0.3 {
                if !c.edge && ringOf(c) >= 0.7 { accepted[c.id] = 1; coreAccepted += c.core; radii.append(c.maxR) }
                else { unexplained += c.coreInside }
            }
            let largest = comps.filter { accepted[$0.id] != 0 }.map(\.core).max() ?? 0, minInk = max(24,pow(glyph*0.03,2))
            for c in comps where accepted[c.id] != 0 && Double(c.core) < Double(largest)*0.08 {
                var touches = false
                let x0 = max(0,Int(floor(Double(c.x0)-2.5))), x1 = min(w-1,Int(ceil(Double(c.x1)+2.5)))
                let y0 = max(0,Int(floor(Double(c.y0)-2.5))), y1 = min(h-1,Int(ceil(Double(c.y1)+2.5)))
                if x0 <= x1 && y0 <= y1 { for y in y0...y1 { if touches { break }; for x in x0...x1 {
                    let l = label[y*w+x]
                    if l >= 0 && l != c.id && accepted[l] == 0 && Double(comps[l].area) >= minInk && comps[l].maxR <= glyph*0.3 { touches = true; break }
                } } }
                if touches { accepted[c.id] = 0; coreAccepted -= c.core }
            }
            radii.sort(); let strokeR = radii.isEmpty ? 1e9 : radii[radii.count>>1]
            var split = [UInt8](repeating: 0,count: n), partOf: [Int]?, parts: [Part] = []
            if !radii.isEmpty {
                var cand = [UInt8](repeating: 0,count: comps.count)
                for c in comps where accepted[c.id] == 0 && c.core > 0 && Double(c.coreInside) >= Double(c.core)*0.5 && c.maxR <= glyph*0.3 && (c.edge || ringOf(c) < 0.7) { cand[c.id] = 1 }
                if cand.contains(1) {
                    let rCut = max(rMin,strokeR*0.55)
                    let E = (0..<n).map { UInt8(F[$0] != 0 && cand[label[$0]] != 0 && Double(thick[$0]) >= rCut ? 1 : 0) }
                    let dE = distance(E,w,h), P = (0..<n).map { UInt8(F[$0] != 0 && cand[label[$0]] != 0 && Double(dE[$0]) <= rCut+0.5 ? 1 : 0) }
                    var part = [Int](repeating: -1,count: n)
                    for s in 0..<n where P[s] != 0 && part[s] < 0 {
                        var a = Part(id: parts.count), queue = [s], head = 0; part[s] = a.id
                        while head < queue.count { let i = queue[head], x = i%w, y = i/w; head += 1
                            if Double(thick[i]) >= rMin { a.core += 1; if inside[i] != 0 { a.coreInside += 1 } }
                            a.maxR = max(a.maxR,Double(thick[i])); let dx = Double(x), dy = Double(y)
                            a.m[0] += 1; a.m[1] += dx; a.m[2] += dy; a.m[3] += dx*dx; a.m[4] += dy*dy; a.m[5] += dx*dy
                            if atBorder(x,y) { a.edge = true }
                            for j in neighbours(i,w,n) where P[j] != 0 && part[j] < 0 { part[j] = a.id; queue.append(j) }
                        }; parts.append(a)
                    }
                    let dP = distance(P,w,h); var nearP = [Int](repeating: -1,count: n), queue: [Int] = [], head = 0
                    for i in 0..<n where P[i] != 0 { nearP[i] = part[i]; queue.append(i) }
                    while head < queue.count { let i = queue[head]; head += 1
                        for j in neighbours(i,w,n) where nearP[j] < 0 && dP[j] <= 2.5 { nearP[j] = nearP[i]; queue.append(j) }
                    }
                    for i in 0..<n where P[i] == 0 && nearP[i] >= 0 && dP[i] <= 2.5 { let k = nearP[i]; parts[k].ring += 1; if isO(i) { parts[k].ringO += 1 } }
                    for c in comps where cand[c.id] != 0 { unexplained -= c.coreInside }
                    for k in parts.indices { let m = parts[k].m, count = m[0], vx = m[3]/count-pow(m[1]/count,2), vy = m[4]/count-pow(m[2]/count,2), cv = m[5]/count-m[1]/count*m[2]/count
                        let t = sqrt(pow((vx-vy)/2,2)+cv*cv)
                        parts[k].across = sqrt(max(0,(vx+vy)/2-t)); parts[k].along = sqrt(max(0,(vx+vy)/2+t))*sqrt(12)
                        let a = parts[k]
                        if a.core == 0 || Double(a.coreInside) < Double(a.core)*0.5 || a.maxR > strokeR*1.8 || a.edge && a.across <= max(2,a.maxR) && a.along >= glyph*0.8 { parts[k].art = true; continue }
                        if !a.edge && a.ring > 0 && Double(a.ringO) >= Double(a.ring)*0.7 { parts[k].ok = true; coreAccepted += a.core }
                        else { unexplained += a.coreInside }
                    }
                    for i in 0..<n where P[i] != 0 && parts[part[i]].ok { split[i] = 1 }; partOf = part
                }
            }
            for c in comps where c.core == 0 && c.maxR >= max(1.5,strokeR*0.6) && Double(c.area) >= max(24,rMin*rMin*2) && !c.edge && Double(c.x0) >= bx0-rMin && Double(c.x1) < bx1+rMin && Double(c.y0) >= by0-rMin && Double(c.y1) < by1+rMin {
                if ringOf(c) >= 0.8 { accepted[c.id] = 1 }
            }
            unexplainedBy[polarity] = unexplained
            if coreAccepted == 0 { reasons.append("\(polarity):none"); continue }
            if Double(unexplained) > Double(coreAccepted)*0.05 { reasons.append("\(polarity):unexplained \(fixed(Double(unexplained)/Double(coreAccepted),2))"); continue }
            var fill = [UInt8](repeating: 0,count: n), fillInside = 0
            for i in 0..<n where F[i] != 0 && (accepted[label[i]] != 0 || split[i] != 0) { fill[i] = 1; if inside[i] != 0 { fillInside += 1 } }
            if Double(fillInside) < Double(boxCount)*0.03 { reasons.append("\(polarity):small"); continue }
            let dist = distance(fill,w,h)
            guard let bandRGB = median(p,{ dist[$0] > 1 && dist[$0] <= 3 && isO($0) }) else { reasons.append("\(polarity):band"); continue }
            let isBand: (Int)->Bool = { isO($0) && NativeDisplayLetteringPixels.near(p,$0,bandRGB,40) }
            let rings = Int(ceil(max(8,glyph*0.25+6)))
            var allD = [Double](repeating: 0,count: rings+1), oD = allD
            for i in 0..<n where dist[i] > 0 && Double(dist[i]) <= Double(rings) { let k = Int(ceil(Double(dist[i]))); allD[k] += 1; if isBand(i) { oD[k] += 1 } }
            func share(_ from: Double,_ to: Double)->Double {
                var all = 0.0, close = 0.0
                let start = Int(ceil(from+1e-6)), end = min(rings,Int(floor(to)))
                if start <= end { for k in start...end { all += allD[k]; close += oD[k] } }
                return all > 0 ? close/all : 0
            }
            var width = 1.0, d = 2.0
            while d <= max(3,glyph*0.25) { if share(d-1,d) < 0.5 { break }; width = d; d += 1 }
            let ends = share(width+2,width+4) < 0.5
            if width >= glyph*0.25 { reasons.append("\(polarity):band \(Int(width))"); continue }
            let score = share(0,max(2,width))
            let outside = floodOutside((0..<n).map { UInt8(fill[$0] != 0 || isBand($0) ? 1 : 0) },w,h)
            var edge = 0, leak = 0
            for i in 0..<n where fill[i] != 0 {
                var open = false, border = false
                for j in neighbours(i,w,n) where fill[j] == 0 {
                    border = true
                    if outside[j] != 0 { open = true }
                    else if !isBand(j) && ((j>=1 && outside[j-1] != 0) || (j+1<n && outside[j+1] != 0) || (j>=w && outside[j-w] != 0) || (j+w<n && outside[j+w] != 0)) { open = true }
                }
                if border { edge += 1; if open { leak += 1 } }
            }
            let leakShare = edge > 0 ? Double(leak)/Double(edge) : 1
            if leakShare > 0.1 { reasons.append("\(polarity):leak \(fixed(leakShare,2))"); continue }
            let free = floodOutside(fill,w,h); var bandNear = 0, bandInner = 0
            for i in 0..<n where dist[i] > 0 && dist[i] <= 2 && isBand(i) { bandNear += 1; if free[i] == 0 { bandInner += 1 } }
            let inner = bandNear > 0 ? Double(bandInner)/Double(bandNear) : 1
            if inner > 0.35 { reasons.append("\(polarity):inner-band \(fixed(inner,2))"); continue }
            valid.append(polarity)
            if best == nil || score > best!.score { best = Best(polarity: polarity,fill: fill,dist: dist,width: width,ends: ends,score: score,rCore: coreAccepted,bandRGB: bandRGB,label: label,comps: comps,thick: thick,strokeR: strokeR,partOf: partOf,parts: parts) }
        }
        guard let best else { return .init(reject: "bw \(reasons.joined(separator: " "))") }
        if valid.count > 1 { return .init(reject: "bw-polarity") }
        return finishBW(p,w,h,box,glyph,inside,boxCount,lum,best,unexplainedBy)
    }
}
