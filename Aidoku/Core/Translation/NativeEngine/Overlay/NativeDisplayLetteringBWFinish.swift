import CoreGraphics
import Foundation

extension NativeDisplayLetteringPixels {
    static func finishBW(_ p: [UInt8],_ w: Int,_ h: Int,_ box: CGRect,_ glyph: Double,_ inside: [UInt8],_ boxCount: Int,
                         _ lum: [Float],_ best: Best,_ unexplainedBy: [String:Int]) -> Result {
        let n = w*h, fill = best.fill, dist = best.dist, polarity = best.polarity, rMin = max(1.5,glyph*0.035)
        let isF: (Int)->Bool = { polarity == "dark" ? lum[$0] < 96 : lum[$0] > 168 }
        let isO: (Int)->Bool = { polarity == "dark" ? lum[$0] > 150 : lum[$0] < 110 }
        let ambiguity = Double(unexplainedBy[polarity == "dark" ? "light" : "dark"] ?? 0)/Double(best.rCore)
        var fillArea = 0, perimeter = 0
        for i in 0..<n where fill[i] != 0 { fillArea += 1; let x = i%w
            if x == 0 || x == w-1 || i < w || i >= n-w || fill[i-1] == 0 || fill[i+1] == 0 || fill[i-w] == 0 || fill[i+w] == 0 { perimeter += 1 }
        }
        let strokeRatio = 2*Double(fillArea)/Double(max(1,perimeter))/glyph, strokePx = strokeRatio*glyph
        let width = best.ends && best.width <= max(4,strokePx*2) ? best.width : min(best.width,2), reach = width+3
        var mask = [UInt8](repeating: 0,count: n), masked = 0, maskAll = 0
        for i in 0..<n where Double(dist[i]) <= reach { mask[i] = 1; maskAll += 1; if inside[i] != 0 { masked += 1 } }
        if Double(masked) > Double(boxCount)*0.85 || maskAll > 40000 { return .init(reject: "bw-mask \(fixed(Double(masked)/Double(boxCount),2)) \(maskAll)") }
        let minArea = max(24,pow(glyph*0.03,2)), open = floodOutside(fill,w,h)
        for clsO in [false,true] {
            let cls = clsO ? isO : isF; var seen = [UInt8](repeating: 0,count: n)
            for s in 0..<n where seen[s] == 0 && fill[s] == 0 && Double(dist[s]) > width+1 && cls(s) {
                var queue = [s], head = 0, cut = 0, beyond = 0, outer = 0; seen[s] = 1
                while head < queue.count { let i = queue[head]; head += 1
                    if open[i] != 0 { outer += 1 }
                    if Double(dist[i]) <= reach { cut += 1 } else if Double(dist[i]) > reach+(clsO ? max(4,glyph*0.15) : 2) { beyond += 1 }
                    for j in neighbours(i,w,n) where seen[j] == 0 && fill[j] == 0 && Double(dist[j]) > width+1 && cls(j) { seen[j] = 1; queue.append(j) }
                }
                if Double(queue.count) < minArea || Double(queue.count) > Double(n)*0.15 || outer == 0 || cut < 4 || Double(beyond) < minArea*0.5 { continue }
                var deep = 0, zone: [Int] = [], h2 = 0; let cap = min(n,4096)
                for i in queue { if zone.count >= cap { break }; if Double(dist[i]) > reach { continue }
                    for j in neighbours(i,w,n) where fill[j] == 0 && Double(dist[j]) <= width+1 && cls(j) && seen[j] != 2 {
                        seen[j] = 2; zone.append(j); if zone.count >= cap { break }
                    }
                }
                while h2 < zone.count { let i = zone[h2]; h2 += 1; deep += 1
                    for j in neighbours(i,w,n) where fill[j] == 0 && Double(dist[j]) <= width+1 && cls(j) && seen[j] != 2 {
                        if zone.count < cap { seen[j] = 2; zone.append(j) }
                    }
                }
                if clsO && (!best.ends || width < best.width) && deep > cut { continue }
                return .init(reject: "bw-art \(clsO ? "O" : "F") \(queue.count) \(cut) \(deep)")
            }
        }
        let nearReach = reach+glyph*0.4
        var count = [Int](repeating: 0,count: best.comps.count), far = [UInt8](repeating: 0,count: best.comps.count), big = count
        for i in 0..<n { let l = best.label[i]; if l < 0 || fill[i] != 0 { continue }
            if Double(dist[i]) > nearReach { far[l] = 1 }
            else if mask[i] == 0 && inside[i] != 0 { count[l] += 1; if Double(best.thick[i]) >= max(1.5,best.strokeR*0.6) { big[l] += 1 } }
        }
        if let partOf = best.partOf {
            var pc = [Int](repeating: 0,count: best.parts.count), pf = [UInt8](repeating: 0,count: best.parts.count)
            for i in 0..<n { let k = partOf[i]; if k < 0 || fill[i] != 0 || best.parts[k].ok || best.parts[k].art { continue }
                if Double(dist[i]) > nearReach { pf[k] = 1 } else if mask[i] == 0 && inside[i] != 0 { pc[k] += 1 }
            }
            for a in best.parts where pf[a.id] == 0 && Double(pc[a.id]) >= max(12,rMin*rMin*2) { return .init(reject: "bw-left part \(pc[a.id])") }
        }
        for c in best.comps where far[c.id] == 0 && big[c.id] != 0 && Double(count[c.id]) >= max(12,rMin*rMin*2) && !c.edge { return .init(reject: "bw-left \(count[c.id])") }
        let fillRGB = median(p,{ fill[$0] != 0 && dist[$0] == 0 }), outlineRGB = median(p,{ dist[$0] > 1 && Double(dist[$0]) <= max(2,width) })
        var known = mask.map { UInt8($0 == 0 ? 1 : 0) }
        if ambiguity > 40 { return .init(reject: "bw-ambiguous \(fixed(ambiguity,1))") }
        var bh = [Double](repeating: 0,count: 512), rh = bh, ringCount = 0
        for i in 0..<n { let q = Int(p[i*4]>>5)*64+Int(p[i*4+1]>>5)*8+Int(p[i*4+2]>>5)
            if inside[i] != 0 { if mask[i] == 0 { bh[q] += 1 } }
            else if Double(dist[i]) > reach { rh[q] += 1; ringCount += 1 }
        }
        var leftoverShare = 0.0
        for q in 0..<512 { let pb = bh[q]/Double(boxCount), pr = rh[q]/Double(max(1,ringCount)); if pb >= 0.004 && pb/(pr+0.001) >= 4 { leftoverShare += pb } }
        var paper = 0, around = 0
        for i in 0..<n where Double(dist[i]) > reach && Double(dist[i]) <= reach+glyph*0.3 { around += 1; if lum[i] > 235 { paper += 1 } }
        let paperShare = around > 0 ? Double(paper)/Double(around) : 0
        if leftoverShare > 0.03 { return .init(reject: "bw-leftover \(fixed(leftoverShare,3))") }
        if paperShare > 0.75 && !best.ends || paperShare > 0.5 && strokeRatio < 0.08 { return .init(reject: "bw-paper \(fixed(paperShare,2)) \(fixed(strokeRatio,3))") }
        var chroma = 0.0, chromaCount = 0
        for i in 0..<n where known[i] != 0 && Double(dist[i]) <= reach+glyph*0.3 { chroma += Double(max(p[i*4],p[i*4+1],p[i*4+2])-min(p[i*4],p[i*4+1],p[i*4+2])); chromaCount += 1 }
        chroma /= Double(max(1,chromaCount))
        let ringRGB = median(p,{ known[$0] != 0 && Double(dist[$0]) <= reach+3 }); var mixed = 1.0
        if let ringRGB { var all = 0, off = 0
            for i in 0..<n where known[i] != 0 && Double(dist[i]) <= reach+3 { all += 1; if !near(p,i,ringRGB,40) { off += 1 } }
            mixed = all > 0 ? Double(off)/Double(all) : 1
        }
        if chroma > 40 && mixed > 0.12 { return .init(reject: "bw-mixed \(fixed(mixed,2))") }
        if let ringRGB, mixed <= 0.12 {
            let off: (Int)->Bool = { !near(p,$0,ringRGB,40) }; var seen = [UInt8](repeating: 0,count: n); let limit = pow(glyph*0.2,2)
            for s in 0..<n where seen[s] == 0 && known[s] != 0 && inside[s] != 0 && Double(dist[s]) <= reach+glyph*0.2 && off(s) {
                var queue = [s], head = 0, far = false; seen[s] = 1
                while head < queue.count && !far { let i = queue[head]; head += 1
                    if Double(dist[i]) > reach+glyph*0.25 || Double(queue.count) > limit { far = true; break }
                    for j in neighbours(i,w,n) where seen[j] == 0 && known[j] != 0 && off(j) { seen[j] = 1; queue.append(j) }
                }
                if far { continue }
                if queue.allSatisfy({ Double(dist[$0]) > reach+2 }) {
                    var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
                    for i in queue { let x = Double(i%w), y = Double(i/w); sx += x; sy += y; sxx += x*x; syy += y*y; sxy += x*y }
                    let tail = Double(queue.count), vx = sxx/tail-pow(sx/tail,2), vy = syy/tail-pow(sy/tail,2), cv = sxy/tail-sx/tail*sy/tail
                    let t = sqrt(pow((vx-vy)/2,2)+cv*cv), long = sqrt(max(0,(vx+vy)/2+t)*12), short = sqrt(max(0,(vx+vy)/2-t)*12)+1
                    if long > max(6,glyph*0.08) && long > short*2.5 { continue }
                }
                for i in queue { mask[i] = 1; known[i] = 0; maskAll += 1; if inside[i] != 0 { masked += 1 } }
            }
        }
        return fillBW(p,w,h,glyph,inside,boxCount,lum,best,width,reach,mask,known,masked,maskAll,
            fillRGB,outlineRGB,mixed,chroma,ambiguity,strokeRatio,leftoverShare,paperShare)
    }
}
