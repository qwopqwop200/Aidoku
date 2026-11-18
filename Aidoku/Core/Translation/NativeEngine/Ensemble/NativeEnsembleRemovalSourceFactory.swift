import Accelerate
import CoreGraphics
import Foundation

/// Frozen full-manifest mask producer graph, namespaced to avoid production type collisions.
/// Default morphology/role/DB decisions are preserved. Only contrast, radius multiplier
/// and role-branch enablement are parameterized by the parent-owned fresh mask adapter.
/// Opt-in foreign-target scoping changes only the authority of local negative
/// refinement; source extraction and final protection remain unchanged.
/// No model inference, image I/O, paths, page identity branches or runtime labels.
enum NativeMainRemovalSourceFactory {
    // Port provenance: round3/01-native-role-mask/NativeSourceRoleMask.swift
    /// Source-coordinate, tightly bounded ownership ROI. Ownership is a caller-supplied
    /// binary raster, NOT authorization to remove every enclosed pixel. No page IDs,
    /// predictions, background panels or legacy text-box preparation enter this core.
    struct NativeSourceRoleROI {
        let width: Int
        let height: Int
        let rgb: [UInt8]
        let owned: [UInt8]
        let fontPixels: Double
        let branch: Branch
        enum Branch { case chromatic, tintedOrClipped }
    }
    
    struct NativeSourceRoleResult {
        let core: [UInt8]
        let halo: [UInt8]
        let support: [UInt8]
        let surfaceRGB: [Double]
        let components: Int
        let enabled: Bool
        let neutralGate: Bool
    }
    
    enum NativeSourceRoleMask {
        enum Failure: Error { case invalidROI }
        enum HaloPolicy { case referenceV2, compactExperiment }
        // A caller must tile/reject larger owners explicitly, never silently clip
        // glyphs or allocate an unbounded page-sized scratch bitmap.
        // Large display lettering can have a multi-megapixel source polygon.
        // The caller still bounds cumulative work and the page's decoded size.
        static let maximumROIPixels = 4_000_000
    
        fileprivate struct Prepared {
            let radius: Int
            let hasRing: Bool
            let surface: [Double]
            let neutralGate: Bool
            let extended: [UInt8]
            let bright: [UInt8]
            let colored: [UInt8]
            let neutral: [UInt8]
        }

        fileprivate static func prepare(_ input: NativeSourceRoleROI) throws -> Prepared {
            let w = input.width, h = input.height
            guard w > 0, h > 0, w <= maximumROIPixels / h,
                  input.rgb.count == w * h * 3, input.owned.count == w * h,
                  input.owned.allSatisfy({ $0 <= 1 }), input.fontPixels.isFinite,
                  input.fontPixels > 0 else { throw Failure.invalidROI }
            let n = w * h, env = input.owned
            let radius = max(2, min(14, Int(ceil(input.fontPixels * 0.18))))
            let env2 = dilate(env, width: w, height: h, radius: 2)
            var ring = [Int]()
            for i in 0..<n where env2[i] != 0 && env[i] == 0 { ring.append(i) }
            let sample = ring.isEmpty ? (0..<n).filter { env[$0] != 0 } : ring
            var surface = [Double](repeating: 0, count: 3)
            var std = [Double](repeating: 0, count: 3)
            for channel in 0..<3 where !sample.isEmpty {
                var histogram = [Int](repeating: 0, count: 256)
                var sum = 0.0, square = 0.0
                for i in sample {
                    let value = Int(input.rgb[3 * i + channel])
                    histogram[value] += 1; sum += Double(value); square += Double(value * value)
                }
                var cumulative = 0, lower = 0, upper = 0
                for value in 0..<256 {
                    let previous = cumulative; cumulative += histogram[value]
                    if previous <= (sample.count - 1) / 2 && cumulative > (sample.count - 1) / 2 { lower = value }
                    if previous <= sample.count / 2 && cumulative > sample.count / 2 { upper = value }
                }
                surface[channel] = Double(lower + upper) / 2
                let mean = sum / Double(sample.count)
                std[channel] = sqrt(max(0, square / Double(sample.count) - mean * mean))
            }
            let neutralGate = !ring.isEmpty && surface.min()! >= 160 && surface.max()! <= 248 && std.max()! < 35
            let extended = dilate(env, width: w, height: h, radius: radius)
            var bright = [UInt8](repeating: 0, count: n), colored = bright, neutral = bright
            for i in 0..<n {
                let r = Int(input.rgb[3 * i]), g = Int(input.rgb[3 * i + 1]), b = Int(input.rgb[3 * i + 2])
                let hi = max(r, max(g, b)), lo = min(r, min(g, b)), chroma = hi - lo
                let distance = max(abs(Double(r) - surface[0]), max(abs(Double(g) - surface[1]), abs(Double(b) - surface[2])))
                bright[i] = lo >= 190 && chroma <= 38 ? 1 : 0
                colored[i] = chroma >= 48 && distance >= 45 && extended[i] != 0 ? 1 : 0
                neutral[i] = neutralGate && env[i] != 0 && hi < 110 && chroma < 38 ? 1 : 0
            }
            return Prepared(radius: radius, hasRing: !ring.isEmpty, surface: surface, neutralGate: neutralGate,
                            extended: extended, bright: bright, colored: colored, neutral: neutral)
        }

        static func extract(_ input: NativeSourceRoleROI, haloPolicy: HaloPolicy = .referenceV2) throws -> NativeSourceRoleResult {
            try extract(input, prepared: prepare(input), haloPolicy: haloPolicy)
        }

        fileprivate static func extract(_ input: NativeSourceRoleROI, prepared: Prepared, haloPolicy: HaloPolicy = .referenceV2) throws -> NativeSourceRoleResult {
            let w = input.width, h = input.height, n = w * h, env = input.owned
            let radius = prepared.radius, extended = prepared.extended, bright = prepared.bright
            let raw = input.branch == .chromatic
                ? [zip(prepared.colored, env).map { $0 & $1 }]
                : [prepared.neutral, prepared.colored]
            var body = [UInt8](repeating: 0, count: n), accepted = 0
            for (index, mask) in raw.enumerated() {
                for component in connected(mask, width: w, height: h) {
                    var minX = w, minY = h, maxX = 0, maxY = 0
                    var touches = false, outside = false
                    for i in component {
                        minX = min(minX, i % w); maxX = max(maxX, i % w)
                        minY = min(minY, i / w); maxY = max(maxY, i / w)
                        touches = touches || env[i] != 0; outside = outside || env[i] == 0
                    }
                    let clipped = input.branch == .tintedOrClipped && index == 1
                    if component.count >= 2 && Double(max(maxX - minX + 1, maxY - minY + 1)) <= 1.8 * input.fontPixels &&
                        Double(component.count) <= 1.5 * input.fontPixels * input.fontPixels && touches && (!clipped || outside) {
                        for i in component { body[i] = 1 }; accepted += 1
                    }
                }
            }
            // Experimental alternative changes ONLY halo reach, retaining reference
            // core/ownership/surface decisions. It is NOT the default or accepted.
            let haloReach = haloPolicy == .referenceV2 ? radius : min(radius, max(2, min(6, Int(ceil(input.fontPixels * 0.06)))))
            let near = dilate(body, width: w, height: h, radius: haloReach)
            var halo = bright
            for i in 0..<n { halo[i] = bright[i] & near[i] & (input.branch == .chromatic ? extended[i] : 1) }
            if input.branch == .chromatic {
                let contact = dilate(body, width: w, height: h, radius: 2)
                var connectedHalo = [UInt8](repeating: 0, count: n)
                for component in connected(halo, width: w, height: h) where component.contains(where: { contact[$0] != 0 }) {
                    for i in component { connectedHalo[i] = 1 }
                }
                halo = connectedHalo
            }
            let bodyCount = body.reduce(0) { $0 + Int($1) }, haloCount = halo.reduce(0) { $0 + Int($1) }
            let enabled = accepted >= 3 && haloCount >= max(8, Int(Double(bodyCount) * 0.08)) &&
                (input.branch == .chromatic || prepared.hasRing)
            var support = [UInt8](repeating: 0, count: n)
            if enabled {
                let united = zip(body, halo).map { $0 | $1 }
                support = dilate(united, width: w, height: h, radius: 1)
                let limit = dilate(env, width: w, height: h, radius: radius + 1)
                for i in 0..<n { support[i] &= limit[i] }
            }
            return NativeSourceRoleResult(core: body, halo: halo, support: support, surfaceRGB: prepared.surface,
                                          components: accepted, enabled: enabled, neutralGate: prepared.neutralGate)
        }
    
        /// Separable square dilation: identical to PIL MaxFilter, with O(ROI pixels)
        /// sliding windows; no per-radius full neighborhood walk.
        static func dilate(_ mask: [UInt8], width w: Int, height h: Int, radius: Int) -> [UInt8] {
            // Max over a square clipped to the image equals a replicated-edge max.
            // Normalize arbitrary positive bytes to retain the original binary result.
            if radius >= max(w, h) { return [UInt8](repeating: mask.contains(where: { $0 != 0 }) ? 1 : 0, count: mask.count) }
            var accelerated = [UInt8](repeating: 0, count: mask.count)
            let error = mask.withUnsafeBytes { input in
                accelerated.withUnsafeMutableBytes { output in
                    var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    var dst = vImage_Buffer(data: output.baseAddress, height: src.height, width: src.width, rowBytes: w)
                    let side = vImagePixelCount(radius * 2 + 1)
                    return vImageMax_Planar8(&src, &dst, nil, 0, 0, side, side, vImage_Flags(kvImageDoNotTile))
                }
            }
            if error == kvImageNoError { return accelerated.map { $0 == 0 ? 0 : 1 } }
            var horizontal = mask, result = mask
            for y in 0..<h {
                var count = 0
                for x in 0..<min(w, radius) { count += Int(mask[y * w + x]) }
                for x in 0..<w {
                    if x + radius < w { count += Int(mask[y * w + x + radius]) }
                    if x - radius - 1 >= 0 { count -= Int(mask[y * w + x - radius - 1]) }
                    horizontal[y * w + x] = count > 0 ? 1 : 0
                }
            }
            for x in 0..<w {
                var count = 0
                for y in 0..<min(h, radius) { count += Int(horizontal[y * w + x]) }
                for y in 0..<h {
                    if y + radius < h { count += Int(horizontal[(y + radius) * w + x]) }
                    if y - radius - 1 >= 0 { count -= Int(horizontal[(y - radius - 1) * w + x]) }
                    result[y * w + x] = count > 0 ? 1 : 0
                }
            }
            return result
        }
    
        static func connected(_ mask: [UInt8], width w: Int, height h: Int) -> [[Int]] {
            var seen = mask, results = [[Int]]()
            for start in mask.indices where seen[start] != 0 {
                var stack = [start], component = [Int](); seen[start] = 0
                while let i = stack.popLast() {
                    component.append(i)
                    let x = i % w, y = i / w
                    for neighbor in [x > 0 ? i - 1 : -1, x + 1 < w ? i + 1 : -1,
                                     y > 0 ? i - w : -1, y + 1 < h ? i + w : -1] where neighbor >= 0 && seen[neighbor] != 0 {
                        seen[neighbor] = 0; stack.append(neighbor)
                    }
                }
                results.append(component)
            }
            return results
        }
    }

    // Port provenance: round14/06-native-base-mask/NativeSourceBaseMask.swift
    /// Builds the initial removal contribution from ORIGINAL pixels and OCR ownership.
    /// No incoming removal mask, restored image, expected mask or runtime label exists in this API.
    enum NativeSourceBaseMask {
        struct Result { let mask: [UInt8]; let audit: [[String: Any]] }
    
        static func median(_ a: [Int]) -> Double {
            guard !a.isEmpty else { return 0 }
            let b = a.sorted(), m = b.count / 2
            return b.count % 2 == 0 ? Double(b[m - 1] + b[m]) / 2 : Double(b[m])
        }
    
        static func extract(source: NativeCurrentMaskCaller.Source,
                            owners: [NativeCurrentMaskCaller.Owner], contrast: Double = 32,
                            radiusScale: Double = 1, roleSupport: Bool = true) throws -> Result {
            let w = source.width, h = source.height
            guard w > 0, h > 0, w <= 16_777_216 / h, source.rgb.count == w * h * 3 else {
                throw NativeCurrentMaskCaller.Failure.invalidEvidence
            }
            var out = [UInt8](repeating: 0, count: w * h), records = [[String: Any]]()
            for owner in owners where owner.translated {
                let font = owner.fontPixels
                guard font.isFinite, font > 0, !owner.polygon.isEmpty else {
                    throw NativeCurrentMaskCaller.Failure.invalidEvidence
                }
                // Source base factory uses rounded source vertices, unlike the later
                // completion/protection adapter's integer truncation convention.
                let polygon = owner.polygon.map { CGPoint(x: $0.x.rounded(.toNearestOrEven), y: $0.y.rounded(.toNearestOrEven)) }
                let margin = max(18, Int(ceil(font * 0.18)) + 3)
                let x0 = max(0, Int(polygon.map(\.x).min()!) - margin)
                let y0 = max(0, Int(polygon.map(\.y).min()!) - margin)
                let x1 = min(w, Int(polygon.map(\.x).max()!) + margin + 1)
                let y1 = min(h, Int(polygon.map(\.y).max()!) + margin + 1)
                let cw = x1 - x0, ch = y1 - y0
                guard cw > 0, ch > 0, cw <= NativeSourceRoleMask.maximumROIPixels / ch else {
                    throw NativeCurrentMaskCaller.Failure.invalidEvidence
                }
                let env = NativeCurrentMaskCaller.raster(polygon.map { CGPoint(x: $0.x - CGFloat(x0), y: $0.y - CGFloat(y0)) }, width: cw, height: ch)
                var rgb = [UInt8]()
                rgb.reserveCapacity(cw * ch * 3)
                for y in y0..<y1 {
                    rgb.append(contentsOf: source.rgb[(y * w + x0) * 3..<(y * w + x1) * 3])
                }
                let prepared = roleSupport ? try NativeSourceRoleMask.prepare(.init(
                    width: cw, height: ch, rgb: rgb, owned: env, fontPixels: font, branch: .chromatic)) : nil
                let bg: [Double]
                if let prepared {
                    bg = prepared.surface
                } else {
                    let vicinity = NativeSourceRoleMask.dilate(env, width: cw, height: ch, radius: 2)
                    var ring = env.indices.filter { vicinity[$0] != 0 && env[$0] == 0 }
                    if ring.isEmpty { ring = env.indices.filter { env[$0] != 0 } }
                    bg = (0..<3).map { c in median(ring.map { Int(rgb[$0 * 3 + c]) }) }
                }
                var ink = env
                for k in env.indices where env[k] != 0 {
                    let p = k * 3
                    let delta = max(abs(Double(rgb[p]) - bg[0]), abs(Double(rgb[p+1]) - bg[1]),
                                    abs(Double(rgb[p+2]) - bg[2]))
                    ink[k] = delta >= contrast ? 1 : 0
                }
                // A replicated-edge binary square erosion survives exactly as many
                // layers as the Chebyshev distance to the nearest in-image zero.
                // An all-ink ROI retains all 16 layers.
                var depth = ink.map { $0 == 0 ? UInt8(0) : 16 }
                for y in 0..<ch {
                    for x in 0..<cw where depth[y * cw + x] != 0 {
                        let i = y * cw + x
                        var nearest = UInt8(16)
                        if x > 0 { nearest = depth[i - 1] }
                        if y > 0 {
                            let top = i - cw
                            nearest = min(nearest, depth[top])
                            if x > 0 { nearest = min(nearest, depth[top - 1]) }
                            if x + 1 < cw { nearest = min(nearest, depth[top + 1]) }
                        }
                        depth[i] = min(16, nearest + 1)
                    }
                }
                for y in (0..<ch).reversed() {
                    for x in (0..<cw).reversed() where depth[y * cw + x] > 1 {
                        let i = y * cw + x
                        var nearest = UInt8(16)
                        if x + 1 < cw { nearest = depth[i + 1] }
                        if y + 1 < ch {
                            let below = i + cw
                            nearest = min(nearest, depth[below])
                            if x > 0 { nearest = min(nearest, depth[below - 1]) }
                            if x + 1 < cw { nearest = min(nearest, depth[below + 1]) }
                        }
                        depth[i] = min(depth[i], nearest + 1)
                    }
                }
                var maxima = [Int]()
                for y in 0..<ch { for x in 0..<cw where ink[y*cw+x] != 0 {
                    let k = y*cw+x
                    var local: UInt8 = 0
                    for yy in max(0,y-1)...min(ch-1,y+1) { for xx in max(0,x-1)...min(cw-1,x+1) { local = max(local, depth[yy*cw+xx]) } }
                    if depth[k] >= local { maxima.append(Int(depth[k])) }
                }}
                let stroke = maxima.isEmpty ? 1 : median(maxima)
                let radius = Int(ceil(min(font*0.18, max(1, 0.55*stroke + 0.65*Double(max(w,h))/1024 + 0.5)) * radiusScale))
                var support = NativeSourceRoleMask.dilate(ink, width: cw, height: ch, radius: radius)
                if let prepared {
                    for branch in [NativeSourceRoleROI.Branch.chromatic, .tintedOrClipped] {
                        let roles = try NativeSourceRoleMask.extract(.init(width: cw, height: ch, rgb: rgb,
                            owned: env, fontPixels: font, branch: branch), prepared: prepared)
                        for k in support.indices { support[k] |= roles.support[k] }
                    }
                }
                for y in 0..<ch { for x in 0..<cw { out[(y0+y)*w+x0+x] |= support[y*cw+x] } }
                records.append(["owner": owner.id, "backgroundRGB": bg, "sourceContrastInk": ink.filter { $0 != 0 }.count,
                    "strokeRadiusProxy": stroke, "radiusSourcePixels": radius, "fontPixels": font])
            }
            // Four-connected exterior flood: enclosed counters only, with the same
            // bounded aggregate policy as the source factory. No artwork-hole GT.
            let counters = fillEnclosedCounters(&out, width: w, height: h)
            records.append(["enclosedCounterPixels": counters.pixels, "counterFillAccepted": counters.accepted,
                "authority": "source/OCR hypothesis, not glyph truth; DB enters downstream neutral/protection"])
            return .init(mask: out, audit: records)
        }

        private static func fillEnclosedCounters(_ mask: inout [UInt8], width: Int, height: Int)
            -> (pixels: Int, accepted: Bool) {
            var seen = mask
            var stack = [Int]()
            // A horizontal run is entirely four-connected. One seed per open
            // run on either adjacent row is sufficient to reach the exterior.
            func enqueueRuns(_ start: Int, _ end: Int) {
                var i = start
                while i < end {
                    if seen[i] != 0 { i += 1; continue }
                    stack.append(i)
                    repeat { i += 1 } while i < end && seen[i] == 0
                }
            }
            enqueueRuns(0, width)
            if height > 1 { enqueueRuns(mask.count - width, mask.count) }
            for y in 0..<height {
                let left = y * width, right = left + width - 1
                if seen[left] == 0 { stack.append(left) }
                if seen[right] == 0 { stack.append(right) }
            }
            while let seed = stack.popLast() {
                guard seen[seed] == 0 else { continue }
                let row = seed / width * width
                var left = seed, end = seed + 1
                while left > row && seen[left - 1] == 0 { left -= 1 }
                while end < row + width && seen[end] == 0 { end += 1 }
                seen.withUnsafeMutableBufferPointer {
                    ($0.baseAddress! + left).update(repeating: 1, count: end - left)
                }
                if row > 0 { enqueueRuns(left - width, end - width) }
                if row + width < mask.count { enqueueRuns(left + width, end + width) }
            }
            let holes = seen.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
            let ink = mask.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
            let accepted = holes <= max(32, Int(Double(ink) * 0.30))
            if accepted && holes > 0 {
                for i in seen.indices where seen[i] == 0 { mask[i] = 1 }
            }
            return (holes, accepted)
        }
    }

    // Port provenance: NativeChromaticMaskCompletion.swift
    /// Native source-only port of the controlled connected-component completion.
    /// Removal is an ownership seed, not glyph truth. Neutral/ambiguous ink abstains.
    enum NativeChromaticMaskCompletion {
        struct Owner {
            let id: String
            let polygon: [CGPoint]
            let fontPixels: Double
        }
        struct Result {
            let mask: [UInt8]
            let audit: [[String:Any]]
        }
        static func complete(rgb:[UInt8],width w:Int,height h:Int,base:[UInt8],
                             protection:[UInt8],owners:[Owner]) throws -> Result {
            guard w>0,h>0,w<=16_777_216/h,rgb.count==w*h*3,base.count==w*h,
                  protection.count==w*h else{throw CocoaError(.fileReadCorruptFile)}
            var result=base.map{$0 == 0 ? UInt8(0):1},records=[[String:Any]]()
            for owner in owners {
                let f=owner.fontPixels,poly=owner.polygon
                guard f.isFinite,f>0,f<=Double(max(w,h))*4,poly.count>=3,
                    poly.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.x>=CGFloat(-w) && $0.x<=CGFloat(w*2) && $0.y>=CGFloat(-h) && $0.y<=CGFloat(h*2)})
                    else{throw CocoaError(.fileReadCorruptFile)}
                let margin=Int(ceil(0.55*f))+3
                let x0=max(0,Int(floor(poly.map(\.x).min()!))-margin)
                let y0=max(0,Int(floor(poly.map(\.y).min()!))-margin)
                let x1=min(w,Int(ceil(poly.map(\.x).max()!))+margin)
                let y1=min(h,Int(ceil(poly.map(\.y).max()!))+margin)
                guard x1>x0,y1>y0 else{throw CocoaError(.fileReadCorruptFile)}
                let bw=x1-x0,bh=y1-y0,n=bw*bh
                // Pillow's supplied ownership polygons use integer-lattice vertices.
                // Preserve that explicit convention; not CGPath pixel-center truth.
                let points=poly.map{CGPoint(x:Int($0.x-CGFloat(x0)),y:Int($0.y-CGFloat(y0)))}
                let path=CGMutablePath();path.addLines(between:points);path.closeSubpath()
                func owned(_ x:Int,_ y:Int)->Bool {
                    let p=CGPoint(x:x,y:y)
                    for i in points.indices {
                        let a=points[i],b=points[(i+1)%points.count]
                        let cross=(p.x-a.x)*(b.y-a.y)-(p.y-a.y)*(b.x-a.x)
                        if cross==0,p.x>=min(a.x,b.x),p.x<=max(a.x,b.x),
                            p.y>=min(a.y,b.y),p.y<=max(a.y,b.y){return true}
                    }
                    return path.contains(p)
                }
                var own=[UInt8](repeating:0,count:n),hist=[Int](repeating:0,count:4096)
                var witnesses=[Int](),red=[Int](),green=[Int](),blue=[Int]()
                func global(_ k:Int)->Int{(y0+k/bw)*w+x0+k%bw}
                func extrema(_ p:Int)->(Int,Int) {
                    let k=p*3,r=Int(rgb[k]),g=Int(rgb[k+1]),b=Int(rgb[k+2])
                    return (min(r,g,b),max(r,g,b))
                }
                func bin(_ p:Int)->Int{Int(rgb[p*3]/16)*256+Int(rgb[p*3+1]/16)*16+Int(rgb[p*3+2]/16)}
                for y in 0..<bh {for x in 0..<bw {
                    let k=y*bw+x,p=global(k)
                    if owned(x,y){own[k]=1}
                    let e=extrema(p)
                    if own[k] != 0,base[p] != 0,e.1-e.0>=90,e.0<145 {
                        witnesses.append(k);hist[bin(p)]+=1
                    }
                }}
                guard witnesses.count>=40 else {
                    records.append(["owner":owner.id,"status":"neutral-or-insufficient-chromatic-witness"]);continue
                }
                let maximum=hist.max()!,key=hist.firstIndex(of:maximum)!
                guard maximum>=40,Double(maximum)>=0.18*Double(witnesses.count) else{continue}
                for k in witnesses {
                    let p=global(k)
                    if bin(p)==key {red.append(Int(rgb[p*3]));green.append(Int(rgb[p*3+1]));blue.append(Int(rgb[p*3+2]))}
                }
                func median(_ values:[Int])->Double {
                    let a=values.sorted(),m=a.count/2
                    return a.count%2==1 ? Double(a[m]):Double(a[m-1]+a[m])/2
                }
                let ink=[median(red),median(green),median(blue)]
                var weak=[UInt8](repeating:0,count:n),strong=[UInt8](repeating:0,count:n)
                for k in 0..<n {
                    let p=global(k),q=p*3,e=extrema(p)
                    let distance=max(abs(Double(rgb[q])-ink[0]),max(abs(Double(rgb[q+1])-ink[1]),abs(Double(rgb[q+2])-ink[2])))
                    if distance<=80,e.1-e.0>=45 {weak[k]=1}
                    if distance<=32,e.1-e.0>=70 {strong[k]=1}
                }
                var accepted=[[String:Any]](),added=0
                for first in 0..<n where weak[first] != 0 {
                    weak[first]=0
                    var stack=[first],component=[Int]()
                    while let k=stack.popLast() {
                        component.append(k);let x=k%bw,y=k/bw
                        for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                            let xx=x+dx,yy=y+dy
                            if xx>=0,xx<bw,yy>=0,yy<bh,weak[yy*bw+xx] != 0 {
                                weak[yy*bw+xx]=0;stack.append(yy*bw+xx)
                            }
                        }
                    }
                    let size=component.count
                    let overlap=component.reduce(0){$0+(base[global($1)] == 0 ? 0:1)}
                    if overlap==size{continue}
                    let inside=component.reduce(0){$0+Int(own[$1])}
                    guard Double(overlap)>=max(8,0.3*Double(size)),Double(inside)>=max(8,0.25*Double(size)),
                        component.contains(where:{strong[$0] != 0}),
                        !component.contains(where:{protection[global($0)] != 0}) else{continue}
                    let xs=component.map{$0%bw},ys=component.map{$0/bw}
                    let left=xs.min()!,right=xs.max()!,top=ys.min()!,bottom=ys.max()!
                    guard left>0,top>0,right<bw-1,bottom<bh-1 else{continue}
                    let glyph=Double(max(right-left+1,bottom-top+1))<=1.7*f && Double(size)<=1.1*f*f
                    let tail=Double(overlap)>=0.95*Double(size) && Double(inside)>=0.95*Double(size) && Double(size-overlap)<=0.2*f*f
                    guard glyph || tail else{continue}
                    for k in component {
                        let p=global(k)
                        if base[p]==0,protection[p]==0 {if result[p]==0{added+=1};result[p]=1}
                    }
                    accepted.append(["bounds":[x0+left,y0+top,right-left+1,bottom-top+1],
                                     "pixels":size,"masked":overlap,"owned":inside,"added":size-overlap])
                }
                records.append(["owner":owner.id,"ink":ink,"fontPixels":f,"added":added,
                                "components":accepted,"status":"source-component-proposal"])
            }
            return .init(mask:result,audit:records)
        }
    }

    // Port provenance: round12/01-neutral-mask-native/NativeNeutralMaskRefinement.swift
    /// Revision 1 of NeutralSupport.py. No labels, IDs, restored pixels or text style.
    /// Ownership is an upstream source polygon raster, in crop coordinates.
    enum NativeNeutralMaskRefinement {
        struct Result {
            var remove: [Bool]
            var status: String
            var ridgePixels: Int
            var inkPixels: Int
            var sourceSupportRemoved: Int
        }
    
        static func propagate(_ seeds: [Bool], through allowed: [Bool], width: Int, height: Int) -> [Bool] {
            var result = zip(seeds, allowed).map { $0 && $1 }
            var stack = result.indices.filter { result[$0] }
            while let k = stack.popLast() {
                let x = k % width, y = k / width
                for q in [x > 0 ? k - 1 : -1, x + 1 < width ? k + 1 : -1,
                          y > 0 ? k - width : -1, y + 1 < height ? k + width : -1] {
                    if q >= 0 && allowed[q] && !result[q] { result[q] = true; stack.append(q) }
                }
            }
            return result
        }
    
        /// Square max filter, clipped at the crop boundary (Pillow edge replication parity).
        static func dilate(_ input: [Bool], radius: Double, width: Int, height: Int) -> [Bool] {
            let r = Int(ceil(radius)), stride = width + 1
            var sums = [Int](repeating: 0, count: stride * (height + 1))
            for y in 0..<height {
                var row = 0
                for x in 0..<width {
                    row += input[y * width + x] ? 1 : 0
                    sums[(y + 1) * stride + x + 1] = sums[y * stride + x + 1] + row
                }
            }
            var output = input
            for y in 0..<height {
                let top = max(0, y - r), bottom = min(height, y + r + 1)
                for x in 0..<width {
                    let left = max(0, x - r), right = min(width, x + r + 1)
                    output[y * width + x] = sums[bottom * stride + right] - sums[top * stride + right]
                        - sums[bottom * stride + left] + sums[top * stride + left] > 0
                }
            }
            return output
        }
    
        static func refine(rgb: [UInt8], base: [Bool], probability: [Float], owned: [Bool],
                           width: Int, height: Int, fontPixels: Double) -> Result {
            let n = width * height
            precondition(width > 0 && height > 0 && rgb.count == n * 3 && base.count == n
                && probability.count == n && owned.count == n && fontPixels > 0)
            precondition(probability.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
            var neutral = base, dark = base, ridge = base
            var endpoints = [UInt8](), ownedCount = 0, neutralCount = 0
            for k in 0..<n {
                let r = rgb[k * 3], g = rgb[k * 3 + 1], b = rgb[k * 3 + 2]
                let hi = max(r, max(g, b)), lo = min(r, min(g, b))
                neutral[k] = Int(hi) - Int(lo) < 20
                dark[k] = hi < 110
                ridge[k] = probability[k] >= Float(0.45) && owned[k]
                if owned[k] {
                    ownedCount += 1; neutralCount += neutral[k] ? 1 : 0
                    endpoints.append(contentsOf: [r, g, b])
                }
            }
            let ridgeCount = ridge.filter { $0 }.count
            func abstain(_ status: String) -> Result {
                Result(remove: [Bool](repeating: false, count: n), status: status,
                       ridgePixels: ridgeCount, inkPixels: 0, sourceSupportRemoved: 0)
            }
            guard ridgeCount >= 12 && ownedCount > 0 && Double(neutralCount) / Double(ownedCount) >= 0.9 else {
                return abstain("insufficient-neutral-ridge")
            }
            endpoints.sort()
            let mid = endpoints.count / 2
            let median = endpoints.count % 2 == 1 ? Double(endpoints[mid])
                : (Double(endpoints[mid - 1]) + Double(endpoints[mid])) / 2
            guard median >= 90 else { return abstain("dark-source-abstain") }
            let expanded = dilate(ridge, radius: max(2, 0.22 * fontPixels), width: width, height: height)
            let allowed = (0..<n).map { dark[$0] && owned[$0] }
            let ink = propagate(zip(expanded, allowed).map { $0 && $1 }, through: allowed, width: width, height: height)
            var border = [Bool](repeating: false, count: n)
            for x in 0..<width { border[x] = true; border[(height - 1) * width + x] = true }
            for y in 0..<height { border[y * width] = true; border[y * width + width - 1] = true }
            let support = propagate(border, through: ink.map { !$0 }, width: width, height: height).map { !$0 }
            let shell = dilate(support, radius: max(2, 0.12 * fontPixels), width: width, height: height)
            let ridgeBand = dilate(ridge, radius: 0.48 * fontPixels, width: width, height: height)
            let removable = (0..<n).map { base[$0] && neutral[$0] && probability[$0] < Float(0.08) && !shell[$0] && !ridgeBand[$0] }
            let exterior = dilate(base.map { !$0 }, radius: 1, width: width, height: height)
            let remove = propagate(exterior, through: removable, width: width, height: height)
            return Result(remove: remove, status: "source-db-exterior-trim", ridgePixels: ridgeCount,
                          inkPixels: ink.filter { $0 }.count,
                          sourceSupportRemoved: zip(remove, support).filter { $0 && $1 }.count)
        }
    }

    // Port provenance: round13/01-neutral-residual-support/NativeSourceNormalSupport.swift
    /// Add only source-connected neutral glyph components and their monotone AA normals.
    /// Runs after the accepted neutral subtraction. No restoration, IDs or labels.
    enum NativeSourceNormalSupport {
        struct Result {
            var add: [Bool]
            var components: Int
            var status: String
        }
    
        static func refine(rgb: [UInt8], base: [Bool], probability: [Float], owned: [Bool],
                           width: Int, height: Int, fontPixels: Double) -> Result {
            let n = width * height
            precondition(rgb.count == n * 3 && base.count == n && probability.count == n && owned.count == n)
            let hi = (0..<n).map { max(rgb[$0 * 3], max(rgb[$0 * 3 + 1], rgb[$0 * 3 + 2])) }
            let neutral: [Bool] = (0..<n).map { k in
                let low: UInt8 = min(rgb[k * 3], min(rgb[k * 3 + 1], rgb[k * 3 + 2]))
                return Int(hi[k]) - Int(low) < 20
            }
            let samples = hi.indices.filter { owned[$0] }.map { hi[$0] }.sorted()
            var add = [Bool](repeating: false, count: n)
            guard !samples.isEmpty, samples[samples.count / 2] >= 90,
                  Double(owned.indices.filter { owned[$0] && neutral[$0] }.count) / Double(samples.count) >= 0.9 else {
                return Result(add: add, components: 0, status: "source-distribution-abstain")
            }
            let vicinity = NativeNeutralMaskRefinement.dilate(owned, radius: max(2, 0.18 * fontPixels), width: width, height: height)
            let dark = (0..<n).map { vicinity[$0] && neutral[$0] && hi[$0] < 160 }
            var seen = [Bool](repeating: false, count: n), accepted = 0
            for seed in 0..<n where dark[seed] && !seen[seed] {
                var stack = [seed], component = [Int](); seen[seed] = true
                var seeded = false, minX = width, maxX = 0, minY = height, maxY = 0
                while let k = stack.popLast() {
                    component.append(k)
                    let x = k % width, y = k / width
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    seeded = seeded || (owned[k] && probability[k] >= 0.45)
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0 && xx < width && yy >= 0 && yy < height {
                            let q = yy * width + xx
                            if dark[q] && !seen[q] { seen[q] = true; stack.append(q) }
                        }
                    }}
                }
                guard seeded, maxX - minX + 1 <= Int(ceil(1.8 * fontPixels)),
                      maxY - minY + 1 <= Int(ceil(1.8 * fontPixels)) else { continue }
                // A bright local moat distinguishes isolated lettering from connected artwork.
                var moat = 0, bright = 0
                for y in max(0, minY - 2)...min(height - 1, maxY + 2) {
                    for x in max(0, minX - 2)...min(width - 1, maxX + 2) {
                        if x < minX || x > maxX || y < minY || y > maxY {
                            moat += 1; bright += hi[y * width + x] >= 230 ? 1 : 0
                        }
                    }
                }
                guard moat > 0 && Double(bright) / Double(moat) >= 0.8 else { continue }
                accepted += 1
                for k in component {
                    add[k] = !base[k]
                    // Follow outward source intensity ramps, stopping at paper or reversals.
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        var previous = Int(hi[k])
                        for step in 1...3 {
                            let x = k % width + dx * step, y = k / width + dy * step
                            if x < 0 || x >= width || y < 0 || y >= height { break }
                            let q = y * width + x, value = Int(hi[q])
                            if !neutral[q] || value < previous || value >= 250 { break }
                            add[q] = !base[q]; previous = value
                        }
                    }}
                }
            }
            return Result(add: add, components: accepted, status: "source-component-normal-support")
        }
    }

    // Port provenance: round7/03-frame-rail-protection/NativeFrameRailProtection.swift
    /// Source-pixel evidence only. RF boundaries nominate context, never glyph truth.
    enum NativeFrameRailProtection {
        struct Input {
            let width: Int
            let height: Int
            let rgb: [UInt8]
            let structuralBoundary: [UInt8]
            let removal: [UInt8]
        }
        struct Result {
            let protection: [UInt8]
            let removal: [UInt8]
            let sustainedRuns: Int
        }
        enum Failure: Error { case invalidInput }
    
        static func protect(_ input: Input) throws -> Result {
            let w = input.width, h = input.height, n = w * h
            guard w > 0, h > 0, n <= 16_777_216, input.rgb.count == n * 3,
                  input.structuralBoundary.count == n, input.removal.count == n else { throw Failure.invalidInput }
            let minimumRun = max(40, Int(ceil(Double(min(w, h)) * 0.06)))
            var dark = [UInt8](repeating: 0, count: n)
            for i in 0..<n {
                let r = Int(input.rgb[3*i]), g = Int(input.rgb[3*i+1]), b = Int(input.rgb[3*i+2])
                if max(r, max(g, b)) <= 110 && max(r, max(g, b)) - min(r, min(g, b)) <= 28 { dark[i] = 1 }
            }
            var rail = [UInt8](repeating: 0, count: n), runs = 0
            // Complete source axes, so a cropped glyph window cannot invent a rail.
            for vertical in [false, true] {
                let outer = vertical ? w : h, inner = vertical ? h : w
                for a in 0..<outer {
                    var start = 0
                    while start < inner {
                        let p = vertical ? start*w+a : a*w+start
                        if dark[p] == 0 { start += 1; continue }
                        var end = start, boundaryCount = 0
                        while end < inner {
                            let q = vertical ? end*w+a : a*w+end
                            if dark[q] == 0 { break }
                            boundaryCount += input.structuralBoundary[q] != 0 ? 1 : 0
                            end += 1
                        }
                        if end-start >= minimumRun && boundaryCount*10 >= (end-start)*7 {
                            runs += 1
                            for b in start..<end { rail[vertical ? b*w+a : a*w+b] = 1 }
                        }
                        start = max(end, start+1)
                    }
                }
            }
            // The AOT resize footprint can synthesize a parallel gray rail in
            // white pixels adjoining a preserved core. Keep its bounded source
            // sampling footprint too; this is a rail-following band, not a bbox.
            let fringe = max(2, min(6, Int(ceil(Double(max(w,h))/1024*2))+1))
            var protection = rail
            for y in 0..<h { for x in 0..<w where rail[y*w+x] != 0 {
                for yy in max(0,y-fringe)...min(h-1,y+fringe) { for xx in max(0,x-fringe)...min(w-1,x+fringe) {
                    let p = yy*w+xx
                    protection[p] = 1
                }}
            }}
            var removal = input.removal
            for i in 0..<n where protection[i] != 0 { removal[i] = 0 }
            return Result(protection: protection, removal: removal, sustainedRuns: runs)
        }
    }

    // Port provenance: round10/02-final-union-protection/NativeFinalProtectedUnion.swift
    /// Call once, AFTER every owner's removal contribution. No later mask additions are permitted.
    enum NativeFinalProtectedUnion {
        struct Result {
            let mask: [UInt8]
            let protection: [UInt8]
            let conflicts: Int
            let excluded: Int
        }
        static func apply(width w: Int, height h: Int, rgb: [UInt8], boundary: [UInt8],
                          preserved: [UInt8], target: [UInt8], probability: [UInt8],
                          contributions: [[UInt8]]) throws -> Result {
            let n = w*h
            guard w > 0, h > 0, n <= 16_777_216, rgb.count == n*3,
                  [boundary,preserved,target,probability].allSatisfy({ $0.count == n }),
                  contributions.allSatisfy({ $0.count == n }) else { throw CocoaError(.fileReadCorruptFile) }
            var union = [UInt8](repeating: 0,count: n)
            for owner in contributions { for i in 0..<n where owner[i] != 0 { union[i] = 1 } }
            let rails = try NativeFrameRailProtection.protect(.init(width:w,height:h,rgb:rgb,
                structuralBoundary:boundary,removal:union)).protection
            var protected = [UInt8](repeating: 0,count:n), conflicts = 0, excluded = 0
            for i in 0..<n {
                // Preserved polygons are explicit OCR ownership, not a bbox ink-colour estimate.
                // Rail evidence needs source continuity plus actual RF structural support.
                let proposed = preserved[i] != 0 || rails[i] != 0
                // Strong target probability is a conflict, never silently sacrifice target coverage.
                let conflict = proposed && target[i] != 0 && probability[i] >= 128
                if conflict { conflicts += 1 }
                if proposed && !conflict {
                    protected[i] = 1
                    if union[i] != 0 { excluded += 1 }
                    union[i] = 0
                }
            }
            return .init(mask:union,protection:protected,conflicts:conflicts,excluded:excluded)
        }
    }

    // Port provenance: round14/06-native-base-mask/NativeCurrentMaskCaller.swift
    /// Source-coordinate adapter. Geometry nominates ownership; it is never glyph truth.
    enum NativeCurrentMaskCaller {
        struct Source { let width: Int; let height: Int; let rgb: [UInt8]; let revision: String }
        struct Probability { let width: Int; let height: Int; let values: [Float]; let sourceRevision: String; let revision: String }
        struct Owner {
            let id: String
            let polygon: [CGPoint] // Original pixels, top-left, integer-lattice raster convention.
            let fontPixels: Double
            let translated: Bool
            let balloon: Bool
        }
        struct Evidence {
            let sourceRevision: String
            let revision: String
            let boundary: [UInt8] // Actual RF support, zero when unavailable.
            let owners: [Owner]
            let pending: [CGRect] // Certified upstream pending source support, original pixels.
        }
        struct Result { let mask: [UInt8]; let protection: [UInt8]; let audit: [String: Any] }
        enum Failure: Error { case invalidEvidence, staleSource }

        /// Authority envelope only: never added to the erasure mask. A local
        /// neutral trim may not revoke an already accepted owned halo. The
        /// optional count mode supports excluding the current owner's halo.
        /// Use its original-source radius, not translation font or label geometry.
        static func neutralTargetEnvelope(_ target: [UInt8], owners: [Owner], baseAudit: [[String:Any]],
                                          width w: Int, height h: Int, haloScale: Double,
                                          countCoverage: Bool = false)
            -> (mask: [UInt8], crops: Int, maxCrop: Int, included: Set<String>) {
            guard haloScale.isFinite, haloScale > 0 else { return (target,0,0,[]) }
            let scale = min(1,haloScale)
            let radii = Dictionary(uniqueKeysWithValues: baseAudit.compactMap { record -> (String,Double)? in
                guard let id=record["owner"] as? String,let radius=record["radiusSourcePixels"] as? Int else { return nil }
                return (id,Double(radius))
            })
            // Counts saturate at two: enough to distinguish self-only from
            // another owner, without allocating one page raster per owner.
            var envelope=countCoverage ? target.map { _ in UInt8(0) } : target,crops=0,maxCrop=0
            var included=Set<String>()
            for owner in owners where owner.translated {
                guard let originalRadius=radii[owner.id] else { continue }
                let radius=min(32,max(0,Int(ceil(originalRadius*scale))))
                guard radius>0 else { continue }
                let x0=max(0,Int(floor(owner.polygon.map(\.x).min()!))-radius)
                let y0=max(0,Int(floor(owner.polygon.map(\.y).min()!))-radius)
                let x1=min(w,Int(ceil(owner.polygon.map(\.x).max()!))+radius+1)
                let y1=min(h,Int(ceil(owner.polygon.map(\.y).max()!))+radius+1)
                let cw=x1-x0,ch=y1-y0
                guard cw>0,ch>0,cw<=NativeSourceRoleMask.maximumROIPixels/ch else { continue }
                let local=owner.polygon.map { CGPoint(x:$0.x-CGFloat(x0),y:$0.y-CGFloat(y0)) }
                let owned=raster(local,width:cw,height:ch)
                let halo=NativeSourceRoleMask.dilate(owned,width:cw,height:ch,radius:radius)
                for y in 0..<ch {for x in 0..<cw where halo[y*cw+x] != 0 {
                    let k=(y0+y)*w+x0+x
                    envelope[k]=countCoverage ? min(2,envelope[k]+1) : 1
                }}
                crops += 1;maxCrop=max(maxCrop,cw*ch)
                included.insert(owner.id)
            }
            return (envelope,crops,maxCrop,included)
        }

        /// Crop contains the entire source polygon. Dilation here is only an
        /// ownership query; it never contributes pixels to the removal mask.
        static func neutralSelfHalo(_ owned: [Bool], owner: Owner, baseAudit: [[String:Any]],
                                    width: Int, height: Int, scale: Double) -> [UInt8] {
            let radius=baseAudit.first { $0["owner"] as? String == owner.id }?["radiusSourcePixels"] as? Int ?? 0
            let bounded=scale.isFinite ? min(1,max(0,scale)) : 0
            return NativeSourceRoleMask.dilate(owned.map { $0 ? 1 : 0 },width:width,height:height,
                radius:min(32,max(0,Int(ceil(Double(radius)*bounded)))))
        }
    
        static func convex(_ polygon: [CGPoint]) -> Bool {
            guard polygon.count>=3 else{return false}
            let p=polygon.map{CGPoint(x:Int($0.x),y:Int($0.y))}
            var positive=false,negative=false
            for i in p.indices {
                let a=p[i],b=p[(i+1)%p.count],c=p[(i+2)%p.count]
                let cross=(b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
                positive = positive || cross>0;negative = negative || cross<0
            }
            return positive != negative
        }
    
        /// Convex OCR polygon scan conversion, inclusive edges, nearest lattice with inward right ties.
        /// Unsupported nonconvex input is rejected by prepare, never silently filled as its hull.
        static func raster(_ polygon: [CGPoint], width w: Int, height h: Int) -> [UInt8] {
            let p = polygon.map { CGPoint(x: Int($0.x), y: Int($0.y)) }
            var out = [UInt8](repeating: 0, count: w*h)
            guard p.count >= 3 else { return out }
            for y in max(0,Int(p.map(\.y).min()!))...min(h-1,Int(p.map(\.y).max()!)) {
                var crossings = [Double]()
                for i in p.indices {
                    let a=p[i],b=p[(i+1)%p.count]
                    if a.y == b.y {
                        if CGFloat(y)==a.y {
                            let lo=max(0,Int(min(a.x,b.x))), hi=min(w-1,Int(max(a.x,b.x)))
                            if lo<=hi { for x in lo...hi { out[y*w+x]=1 } }
                        }
                    } else if CGFloat(y)>=min(a.y,b.y) && CGFloat(y)<=max(a.y,b.y) {
                        crossings.append(Double(a.x+(CGFloat(y)-a.y)*(b.x-a.x)/(b.y-a.y)))
                    }
                }
                if let left=crossings.min(),let right=crossings.max() {
                    let lo=max(0,Int(floor(left+0.5))),hi=min(w-1,Int(ceil(right-0.5)))
                    if lo<=hi {for x in lo...hi{out[y*w+x]=1}}
                }
            }
            return out
        }
    
        /// Separable bilinear float reconstruction with half-pixel centers and edge clamp.
        /// Probability is enlarged from detector geometry; downsampling is rejected pending certification.
        static func restore(_ p: Probability, width w: Int, height h: Int) throws -> [Float] {
            guard p.width>0,p.height>0,p.width<=w,p.height<=h,p.values.count==p.width*p.height,
                  p.values.allSatisfy({$0.isFinite && $0>=0 && $0<=1}) else{throw Failure.invalidEvidence}
            // Keep the incumbent scratch guard for tiny or unusually wide grids.
            if p.height > 6, w <= 16_384 { return restoreUsingHorizontalRows(p, width: w, height: h) }
            var row=[Float](repeating:0,count:w*p.height)
            for y in 0..<p.height {for x in 0..<w {
                let sx=max(0,min(Double(p.width-1),(Double(x)+0.5)*Double(p.width)/Double(w)-0.5))
                let a=Int(floor(sx)),b=min(p.width-1,a+1),t=sx-Double(a)
                row[y*w+x]=Float(Double(p.values[y*p.width+a])*(1-t)+Double(p.values[y*p.width+b])*t)
            }}
            var out=[Float](repeating:0,count:w*h)
            for y in 0..<h {
                let sy=max(0,min(Double(p.height-1),(Double(y)+0.5)*Double(p.height)/Double(h)-0.5))
                let a=Int(floor(sy)),b=min(p.height-1,a+1),t=sy-Double(a)
                for x in 0..<w {out[y*w+x]=Float(Double(row[a*w+x])*(1-t)+Double(row[b*w+x])*t)}
            }
            return out
        }

        /// Bound the intermediate to two Float32 rows plus horizontal weights.
        /// Both Float32 rounding boundaries and the half-pixel transform are unchanged.
        private static func restoreUsingHorizontalRows(_ p: Probability, width w: Int, height h: Int) -> [Float] {
            struct Sample { let lower: Int32; let weight: Double }
            let xSamples = (0..<w).map { x -> Sample in
                let sx=max(0,min(Double(p.width-1),(Double(x)+0.5)*Double(p.width)/Double(w)-0.5))
                let a=Int(floor(sx))
                return .init(lower:Int32(a),weight:sx-Double(a))
            }
            func sample(_ index: Int, into row: inout [Float]) {
                let start = index * p.width
                let last = p.width - 1
                for x in 0..<w {
                    let a = Int(xSamples[x].lower), b = min(last, a + 1), t = xSamples[x].weight
                    row[x] = Float(Double(p.values[start+a])*(1-t)+Double(p.values[start+b])*t)
                }
            }
            var current = [Float](repeating:0,count:w), next = current
            var currentRow = -1, nextRow = -1
            var out=[Float](repeating:0,count:w*h)
            for y in 0..<h {
                let sy=max(0,min(Double(p.height-1),(Double(y)+0.5)*Double(p.height)/Double(h)-0.5))
                let a=Int(floor(sy)),b=min(p.height-1,a+1),t=sy-Double(a)
                if currentRow != a {
                    if nextRow == a { swap(&current, &next); swap(&currentRow, &nextRow) }
                    else { sample(a, into:&current); currentRow = a }
                }
                if a != b && nextRow != b { sample(b, into:&next); nextRow = b }
                let bottom = a == b ? current : next
                for x in 0..<w {
                    out[y*w+x] = Float(Double(current[x])*(1-t)+Double(bottom[x])*t)
                }
            }
            return out
        }
    
        static func prepare(source s: Source, probability p: Probability, evidence e: Evidence,
                            contrast: Double = 32, radiusScale: Double = 1, roleSupport: Bool = true,
                            protectForeignTargets: Bool = false, foreignTargetHaloScale: Double = 0,
                            foreignHaloExcludesSelf: Bool = false) throws -> Result {
            let w=s.width,h=s.height
            guard w>0,h>0,w<=16_777_216/h,s.rgb.count==w*h*3,e.boundary.count==w*h,
                !s.revision.isEmpty,!p.revision.isEmpty,!e.revision.isEmpty,
                e.owners.allSatisfy({$0.fontPixels.isFinite && $0.fontPixels>0 && $0.fontPixels<Double(max(w,h))*4 &&
                    $0.polygon.count>=3 && $0.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.x>=0 && $0.y>=0 && $0.x<CGFloat(w) && $0.y<CGFloat(h)}) && convex($0.polygon)}),
                e.pending.allSatisfy({!$0.isEmpty && $0.minX>=0 && $0.minY>=0 && $0.maxX<=CGFloat(w) && $0.maxY<=CGFloat(h)})
                else {throw Failure.invalidEvidence}
            guard s.revision==p.sourceRevision,s.revision==e.sourceRevision else{throw Failure.staleSource}
            let prob=try restore(p,width:w,height:h),q=prob.map{UInt8(min(255,max(0,Int($0*255))))}
            var target=[UInt8](repeating:0,count:w*h),guarded=target,preserved=target
            let rasters=e.owners.map{raster($0.polygon,width:w,height:h)}
            for (i,o) in e.owners.enumerated() {for k in 0..<w*h where rasters[i][k] != 0 {
                if o.translated {target[k]=1} else {guarded[k]=1}
            }}
            var eligibility=[[String:Any]]()
            for (i,o) in e.owners.enumerated() where !o.translated {
                var lo=255,hi=0,support=0,conflicts=0
                for k in 0..<w*h where rasters[i][k] != 0 {
                    for c in 0..<3 {lo=min(lo,Int(s.rgb[k*3+c]));hi=max(hi,Int(s.rgb[k*3+c]))}
                    if q[k]>=51{support += 1};if target[k] != 0 && q[k]>=128{conflicts += 1}
                }
                let eligible=hi-lo>=48 && support>=3 && conflicts==0
                eligibility.append(["owner":o.id,"eligible":eligible,"targetConflicts":conflicts])
                if eligible {for k in 0..<w*h where rasters[i][k] != 0{preserved[k]=1}}
            }
            for r in e.pending {for y in Int(r.minY)..<Int(r.maxY) {for x in Int(r.minX)..<Int(r.maxX) {
                guarded[y*w+x]=1;preserved[y*w+x]=1
            }}}
            let initial=try NativeSourceBaseMask.extract(source:s,owners:e.owners,
                contrast:contrast,radiusScale:radiusScale,roleSupport:roleSupport)
            let chroma=try NativeChromaticMaskCompletion.complete(rgb:s.rgb,width:w,height:h,base:initial.mask,protection:guarded,
                owners:e.owners.filter{$0.translated}.map{.init(id:$0.id,polygon:$0.polygon,fontPixels:$0.fontPixels)})
            // Preserve current sequencing: final union before neutral refinement, reapply the exact protection last.
            let union=try NativeFinalProtectedUnion.apply(width:w,height:h,rgb:s.rgb,boundary:e.boundary,
                preserved:preserved,target:target,probability:q,contributions:[chroma.mask])
            var neutralTarget: (mask: [UInt8], crops: Int, maxCrop: Int, included: Set<String>)?
            var candidate=union.mask,neutral=[[String:Any]]()
            for (i,o) in e.owners.enumerated() where o.translated && !o.balloon {
                let pad=Int(ceil(o.fontPixels*0.6))+4
                let x0=max(0,Int(floor(o.polygon.map(\.x).min()!))-pad),y0=max(0,Int(floor(o.polygon.map(\.y).min()!))-pad)
                let x1=min(w,Int(ceil(o.polygon.map(\.x).max()!))+pad),y1=min(h,Int(ceil(o.polygon.map(\.y).max()!))+pad)
                let cw=x1-x0,ch=y1-y0
                var rgb=[UInt8](),base=[Bool](),owned=[Bool](),probability=[Float]()
                for y in y0..<y1 {for x in x0..<x1 {
                    let k=y*w+x;rgb.append(contentsOf:s.rgb[k*3..<k*3+3]);base.append(union.mask[k] != 0)
                    owned.append(rasters[i][k] != 0);probability.append(prob[k])
                }}
                let r=NativeNeutralMaskRefinement.refine(rgb:rgb,base:base,probability:probability,owned:owned,width:cw,height:ch,fontPixels:o.fontPixels)
                var foreignVeto = 0, removed = 0
                var selfHalo: [UInt8]?
                for k in r.remove.indices where r.remove[k] {
                    let global = (y0+k/cw)*w+x0+k%cw
                    // A local negative refinement must not revoke another
                    // translated owner's accepted union contribution.
                    if protectForeignTargets && !owned[k] {
                        if target[global] != 0 { foreignVeto += 1; continue }
                        if foreignTargetHaloScale.isFinite && foreignTargetHaloScale > 0 {
                            if neutralTarget == nil {
                                neutralTarget=neutralTargetEnvelope(target,owners:e.owners,baseAudit:initial.audit,
                                    width:w,height:h,haloScale:foreignTargetHaloScale,countCoverage:foreignHaloExcludesSelf)
                            }
                            if foreignHaloExcludesSelf && selfHalo == nil {
                                selfHalo=neutralSelfHalo(owned,owner:o,baseAudit:initial.audit,
                                    width:cw,height:ch,scale:foreignTargetHaloScale)
                            }
                            let selfContribution = foreignHaloExcludesSelf && neutralTarget!.included.contains(o.id) && selfHalo![k] != 0 ? 1 : 0
                            if Int(neutralTarget!.mask[global]) > selfContribution { foreignVeto += 1; continue }
                        }
                    }
                    candidate[global]=0; removed += 1
                }
                neutral.append(["owner":o.id,"status":r.status,"removed":removed,"ridge":r.ridgePixels,
                    "ink":r.inkPixels,"sourceSupportRemoved":r.sourceSupportRemoved,
                    "proposedRemoved":r.remove.filter{$0}.count,"foreignOwnerVeto":foreignVeto])
            }
            var normal=[[String:Any]]()
            for (i,o) in e.owners.enumerated() where o.translated && !o.balloon {
                let pad=Int(ceil(o.fontPixels*0.6))+4
                let x0=max(0,Int(floor(o.polygon.map(\.x).min()!))-pad),y0=max(0,Int(floor(o.polygon.map(\.y).min()!))-pad)
                let x1=min(w,Int(ceil(o.polygon.map(\.x).max()!))+pad),y1=min(h,Int(ceil(o.polygon.map(\.y).max()!))+pad)
                let cw=x1-x0,ch=y1-y0
                var rgb=[UInt8](),base=[Bool](),owned=[Bool](),probability=[Float]()
                for y in y0..<y1 {for x in x0..<x1 {
                    let k=y*w+x;rgb.append(contentsOf:s.rgb[k*3..<k*3+3]);base.append(candidate[k] != 0)
                    owned.append(rasters[i][k] != 0);probability.append(prob[k])
                }}
                let r=NativeSourceNormalSupport.refine(rgb:rgb,base:base,probability:probability,owned:owned,width:cw,height:ch,fontPixels:o.fontPixels)
                for k in r.add.indices where r.add[k] {candidate[(y0+k/cw)*w+x0+k%cw]=1}
                normal.append(["owner":o.id,"status":r.status,"added":r.add.filter{$0}.count])
            }
            for k in 0..<w*h where union.protection[k] != 0 {candidate[k]=0}
            return .init(mask:candidate,protection:union.protection,audit:["sourceRevision":s.revision,"probabilityRevision":p.revision,
                "ownershipRevision":e.revision,"base":initial.audit,"normal":normal,"chroma":chroma.audit,"neutral":neutral,"eligibility":eligibility,
                "conflicts":union.conflicts,"excluded":union.excluded,"PILAdapterCalls":0,
                "neutralHaloEnvelope":["scale":foreignTargetHaloScale,"croppedRasterizations":neutralTarget?.crops ?? 0,
                    "maximumCropPixels":neutralTarget?.maxCrop ?? 0,"changesErasureDirectly":false,
                    "excludesSelf":foreignHaloExcludesSelf]])
        }
    }
}
