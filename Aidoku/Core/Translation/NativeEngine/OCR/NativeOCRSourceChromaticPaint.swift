import Foundation

/// Additive source observations only. No model, recognition, GT, request routing,
/// source-index lookup, ROI probability upperBounds, or fabricated RF mask.
///
/// A DB hit authenticates a pixel intersection, NOT detached component membership.
/// Collinear continuation and enclosed paint therefore retain UNKNOWN membership.
/// Distinct admitted chains/shells/layers are returned; a measured finite rim
/// represents its near-identical DB fill envelope. The caller preserves incumbents
/// and counts/deduplicates observations. There is no best-output/GT selection here.
@available(iOS 18.0, *)
enum NativeOCRSourceChromaticPaint {
    private typealias API = NativeOCRSourcePaintGeometry
    static let recoveryV3EnvironmentKey = "AIDOKU_OCR_GENERATION_RECOVERY_V3"
    static var recoveryV3Enabled: Bool { ProcessInfo.processInfo.environment[recoveryV3EnvironmentKey] == "1" }

    struct RecoveryV3Support: Codable, Equatable {
        var available = false
        var sampledPoints = 0, coloredPoints = 0, supportedComponents = 0
        var omittedColoredPoints = 0, omittedComponents = 0, pixelReads = 0
        var coherence = 0.0
        var preferChromatic: Bool {
            available && supportedComponents >= 2 && sampledPoints >= 8 &&
                Double(coloredPoints) >= 0.25 * Double(sampledPoints) && coherence >= 0.5
        }
        var shouldRecoverAfterMedial: Bool {
            preferChromatic && omittedColoredPoints >= 2 &&
                (Double(omittedColoredPoints) >= 0.1 * Double(coloredPoints) || omittedComponents >= 2)
        }
    }

    /// Caller supplies the original query's ACTUAL private CC evidence, not an
    /// index-derived owner. Candidate/ambiguous CCs never become private samples.
    /// Bounded 32 CCs x 8 cells x (9 local + 2 flank) source reads; no mask/model.
    /// A color is physical local contrast, never a content/semantic classification.
    static func recoveryV3Support(roi: NativeOCRSourcePaintGeometry.PixelROI,
                                  queryPolygon: [[Double]], evidence: NativeOCRDetectorSeedEvidence?,
                                  incumbentPolygon: [[Double]]? = nil) -> RecoveryV3Support {
        var report = RecoveryV3Support()
        guard recoveryV3Enabled, let e = evidence, e.isValid, e.completeCCScan == true,
              fits(roi, frameWidth: e.sourceWidth, frameHeight: e.sourceHeight),
              roi.width <= 1_500_000 / roi.height, roi.rgb.count == roi.width * roi.height * 3,
              let f = basis(queryPolygon), f.bounds.width >= 3,
              incumbentPolygon == nil || valid(incumbentPolygon!) else { return report }
        report.available = true
        let sx = Double(e.sourceWidth) / Double(e.mapFullWidth)
        let sy = Double(e.sourceHeight) / Double(e.mapFullHeight)
        var vx = 0.0, vy = 0.0, vz = 0.0
        func inside(_ p: V, _ polygon: [[Double]]) -> Bool {
            var positive = false, negative = false
            for j in polygon.indices {
                let a = polygon[j], b = polygon[(j + 1) % polygon.count]
                let cross = (b[0]-a[0])*(p.y-a[1]) - (b[1]-a[1])*(p.x-a[0])
                positive = positive || cross > 1e-8; negative = negative || cross < -1e-8
            }
            return !(positive && negative)
        }
        func read(_ x: Int, _ y: Int) -> [Double]? {
            guard x >= 0, y >= 0, x < roi.width, y < roi.height else { return nil }
            report.pixelReads += 1
            let (r,g,b) = roi.pixel(x:x,y:y)
            return [r,g,b]
        }
        let componentCount = min(32, e.components.count)
        for ordinal in 0..<componentCount {
            let c = e.components[ordinal * e.components.count / componentCount]
            var componentColored = 0, componentOmitted = 0
            let n = min(8, c.pixelCount)
            var runIndex = 0, preceding = 0
            for k in 0..<n {
                let target = (2*k+1)*c.pixelCount/(2*n)
                while runIndex+1 < c.runs.count && preceding+c.runs[runIndex].count <= target {
                    preceding += c.runs[runIndex].count; runIndex += 1
                }
                let run = c.runs[runIndex]
                let wx = (Double(run.x+target-preceding)+0.5)*sx
                let wy = (Double(run.y)+0.5)*sy
                let x = Int(floor(wx))-roi.originX, y = Int(floor(wy))-roi.originY
                let offset = 0.75*f.bounds.width
                guard let left = read(x+Int((f.n.x*offset).rounded()), y+Int((f.n.y*offset).rounded())),
                      let right = read(x-Int((f.n.x*offset).rounded()), y-Int((f.n.y*offset).rounded())) else { continue }
                report.sampledPoints += 1
                let bg = zip(left,right).map { ($0+$1)/2 }
                var best: (strength:Double, vector:[Double], point:V)?
                for dy in -1...1 { for dx in -1...1 {
                    guard let rgb = read(x+dx,y+dy) else { continue }
                    let chroma = rgb.max()!-rgb.min()!
                    guard chroma >= 0.24*255, chroma >= 0.45*rgb.max()! else { continue }
                    let delta = zip(rgb,bg).map(-), mean = delta.reduce(0,+)/3
                    let opponent = delta.map { $0-mean }
                    let norm = sqrt(opponent.reduce(0) { $0+$1*$1 })
                    guard norm >= 25, abs(mean) >= 10 else { continue }
                    if best == nil || norm > best!.strength {
                        best = (norm,opponent.map { $0/norm },
                                V(x:Double(roi.originX+x+dx)+0.5,y:Double(roi.originY+y+dy)+0.5))
                    }
                }}
                if let best {
                    report.coloredPoints += 1; componentColored += 1
                    vx += best.vector[0]; vy += best.vector[1]; vz += best.vector[2]
                    if let polygon = incumbentPolygon, !inside(best.point,polygon) {
                        report.omittedColoredPoints += 1; componentOmitted += 1
                    }
                }
            }
            if componentColored >= 2 { report.supportedComponents += 1 }
            if componentOmitted >= 2 { report.omittedComponents += 1 }
        }
        if report.coloredPoints > 0 {
            report.coherence = sqrt(vx*vx+vy*vy+vz*vz)/Double(report.coloredPoints)
        }
        return report
    }

    /// Lazy scheduler entry: at most one chromatic primary, only after measured
    /// omitted private color support. Caller retains incumbent if this abstains.
    /// Parent may widen physical ROI beforehand, without changing query identity.
    static func recoverAfterMedialV3(roi: NativeOCRSourcePaintGeometry.PixelROI,
                                     query: NativeOCRSourcePaintGeometry.Query,
                                     evidence: NativeOCRDetectorSeedEvidence?, incumbentPolygon: [[Double]],
                                     originals: [NativeOCRSourceOwnedRailPartition.Original],
                                     rf: [NativeOCRSourceContext50V2.Primitive]) -> [NativeOCRSourcePaintGeometry.Measurement] {
        let support = recoveryV3Support(roi:roi,queryPolygon:query.polygon,evidence:evidence,incumbentPolygon:incumbentPolygon)
        guard support.shouldRecoverAfterMedial else { return [] }
        return measure(roi:roi,query:query,originals:originals,rf:rf).prefix(1).map {
            var d = $0.diagnostics
            d["recoveryV3"] = 1; d["privateColorOmittedSamples"] = Double(support.omittedColoredPoints)
            d["privateColorCoherence"] = support.coherence; d["privateColorProbeReads"] = Double(support.pixelReads)
            return .init(polygon:$0.polygon,layer:$0.layer,mechanism:$0.mechanism,diagnostics:d)
        }
    }

    static let generationBudgetV2EnvironmentKey = "AIDOKU_OCR_SOURCE_GENERATION_BUDGET"
    static var generationBudgetV2Enabled: Bool {
        API.sourceFirstGeneration || ["v2", "source-first-v2"].contains(ProcessInfo.processInfo.environment[generationBudgetV2EnvironmentKey] ?? "")
    }

    static var sourceFirstV2Enabled: Bool {
        recoveryV3Enabled || API.sourceFirstGeneration || ProcessInfo.processInfo.environment[generationBudgetV2EnvironmentKey] == "source-first-v2"
    }

    struct GenerationWorkV2Snapshot: Codable, Equatable {
        var sourceFirstCalls = 0, sourcePalettes = 0, sourceCanonicalFits = 0
        var sourceBodies = 0, sourceCompleteFallbacks = 0
        var axisColorFits = 0, axisColorCacheHits = 0
        var seedContinuationFits = 0, seedContinuationCacheHits = 0
        var maskSegmentations = 0, maskSegmentationCacheHits = 0
        var finiteRimMeasurements = 0, finiteRimCacheHits = 0, disabledRimMeasurementsSkipped = 0
        var cachedBytes = 0, peakCachedBytes = 0, cacheEvictions = 0
    }
    /// One SOURCE TRANSACTION only. Parent may share this between chromatic
    /// calls, never between frames. Reuse returns the same measurements/offers;
    /// it cannot retire provenance or bypass layout-restoration accounting.
    final class GenerationWorkV2Context {
        private struct Key: Hashable {
            let width: Int, height: Int, originX: Int, originY: Int
            let rgb: [UInt8], roots: [Bool], seedBounds: [Double]
            let axis: Bool
        }
        private struct Entry { let measurements: [NativeOCRSourcePaintGeometry.Measurement]; let bytes: Int }
        private let lock = NSLock()
        private let maximumBytes: Int
        private var entries: [Key: Entry] = [:], order: [Key] = []
        private var counters = GenerationWorkV2Snapshot()
        init(maximumBytes: Int = 8*1024*1024) { self.maximumBytes = max(0, min(8*1024*1024, maximumBytes)) }
        func snapshot() -> GenerationWorkV2Snapshot { lock.lock(); defer { lock.unlock() }; return counters }
        fileprivate func note(_ update: (inout GenerationWorkV2Snapshot) -> Void) {
            lock.lock(); defer { lock.unlock() }; update(&counters)
        }
        fileprivate func measurements(roi: NativeOCRSourcePaintGeometry.PixelROI, roots: [Bool],
                                      seedBounds: [Double] = [], axis: Bool,
                                      build: () -> [NativeOCRSourcePaintGeometry.Measurement]) -> [NativeOCRSourcePaintGeometry.Measurement] {
            let key=Key(width:roi.width,height:roi.height,originX:roi.originX,originY:roi.originY,
                        rgb:roi.rgb,roots:roots,seedBounds:seedBounds,axis:axis)
            lock.lock()
            if let entry=entries[key] {
                if axis { counters.axisColorCacheHits += 1 } else { counters.seedContinuationCacheHits += 1 }
                lock.unlock(); return entry.measurements
            }
            if axis { counters.axisColorFits += 1 } else { counters.seedContinuationFits += 1 }
            lock.unlock()
            let result=build()
            // Conservative logical charge includes buffers, dictionary metadata,
            // polygons, strings and diagnostics. Exact arrays use Swift COW.
            var bytes=roi.rgb.count+roots.count+seedBounds.count*8+4096
            for measurement in result {
                bytes += 4096+measurement.diagnostics.count*128
                bytes += measurement.polygon.reduce(0) { $0+$1.count*8 }
                bytes += measurement.mechanism.utf8.count+measurement.layer.utf8.count
            }
            guard bytes<=maximumBytes else { return result }
            lock.lock(); defer { lock.unlock() }
            if entries[key] != nil { return result }
            while counters.cachedBytes+bytes>maximumBytes, !order.isEmpty {
                let old=order.removeFirst()
                if let entry=entries.removeValue(forKey:old) { counters.cachedBytes-=entry.bytes; counters.cacheEvictions+=1 }
            }
            entries[key]=Entry(measurements:result,bytes:bytes);order.append(key)
            counters.cachedBytes+=bytes;counters.peakCachedBytes=max(counters.peakCachedBytes,counters.cachedBytes)
            return result
        }
    }
    private struct V {
        let x: Double, y: Double
        static func - (l: V, r: V) -> V { .init(x: l.x-r.x, y: l.y-r.y) }
        func dot(_ p: V) -> Double { x*p.x+y*p.y }
    }
    private struct B {
        var l = Double.infinity, t = Double.infinity
        var r = -Double.infinity, b = -Double.infinity
        var width: Double { r-l }
        var height: Double { b-t }
        var area: Double { max(0,width)*max(0,height) }
        mutating func add(_ p: V) { l=min(l,p.x); r=max(r,p.x); t=min(t,p.y); b=max(b,p.y) }
        func overlap(_ q: B) -> Double { max(0,min(r,q.r)-max(l,q.l))*max(0,min(b,q.b)-max(t,q.t)) }
    }
    private struct Basis {
        let o: V, n: V, a: V
        let bounds: B
        func project(_ p: V) -> V { let d=p-o; return .init(x:d.dot(n),y:d.dot(a)) }
        func polygon(_ b: B) -> [[Double]] {
            [(b.l,b.t),(b.r,b.t),(b.r,b.b),(b.l,b.b)].map { u,v in
                [o.x+n.x*u+a.x*v,o.y+n.y*u+a.y*v]
            }
        }
    }
    private struct Component {
        let id: Int, pixels: [Int], local: B, projected: B
        let roots: Int, foreign: Int, inside: Int
        let clipped: Bool
    }
    private struct Segmentation { let labels: [Int]; let components: [Component] }
    private struct PaintMask { let pixels: [Bool]; let name: String }

    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI,
                        query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original],
                        rf: [NativeOCRSourceContext50V2.Primitive],
                        generationWorkV2: GenerationWorkV2Context? = nil) -> [NativeOCRSourcePaintGeometry.Measurement] {
        let w=roi.width, h=roi.height
        guard w>2, h>2, w<=1_500_000/h, roi.rgb.count==w*h*3,
              let f=basis(query.polygon), f.bounds.width>=3,
              f.bounds.height>=1.8*f.bounds.width else { return [] }
        // PixelROI is a crop, not a frame-size declaration. Require unanimous
        // source extents from the immutable same-page original seed bank; NEVER
        // infer the full frame from the crop, query geometry or map origin.
        // Absolute validation against the decoded frame needs the explicit-size
        // overload below; this compatibility entry checks cross-seed consistency.
        guard let dimensions=sourceDimensions(originals),
              fits(roi,frameWidth:dimensions.width,frameHeight:dimensions.height),
              originals.allSatisfy({ original in
                  valid(original.polygon) && original.polygon.allSatisfy {
                      $0[0]>=0 && $0[1]>=0 && $0[0]<=Double(dimensions.width) && $0[1]<=Double(dimensions.height)
                  }
              }) else { return [] }
        // Axis-local layers use source pixel axes and original DB intersections,
        // independently of a broad/slanted query's inferred column orientation.
        let work=generationBudgetV2Enabled ? (generationWorkV2 ?? GenerationWorkV2Context()) : nil
        let axisLayers=sourceFirstV2Enabled ? [] : axisLocalLayers(roi:roi,query:query,originals:originals,work:work)
        let count=w*h, scale=f.bounds.width
        let ox=Double(roi.originX), oy=Double(roi.originY)
        func world(_ i: Int) -> V { .init(x:ox+Double(i%w)+0.5,y:oy+Double(i/w)+0.5) }
        let queryWorld=bounds(query.polygon)
        let rfCount=rf.filter { p in
            guard p.canonicalClass==1, p.confidence.isFinite, (0...1).contains(p.confidence), valid(p.polygon) else { return false }
            return queryWorld.overlap(bounds(p.polygon))/queryWorld.area>=0.7
        }.count
        var inside=[Bool](repeating:false,count:count)
        for i in 0..<count {
            let p=f.project(world(i))
            inside[i]=p.x>=f.bounds.l && p.x<=f.bounds.r && p.y>=f.bounds.t && p.y<=f.bounds.b
        }
        // Rasterize only ACTUAL private foreground runs. Unresolved candidate/
        // ambiguous cells are barriers, never promoted to private roots.
        var root=[Bool](repeating:false,count:count), foreign=root, unknown=root, intraUnitUnknown=root
        // Candidate competitor lineage may certify an intra-query observation
        // scope, but does NOT promote that component to private ownership.
        var scope=[String:Bool]()
        func belongs(_ polygon:[[Double]]) -> Bool {
            let pb=projected(polygon,f)
            return pb.width>=0.25*scale && pb.width<=1.5*scale &&
                abs((pb.l+pb.r-f.bounds.l-f.bounds.r)/2)<=0.35*scale &&
                max(0,max(pb.t-f.bounds.b,f.bounds.t-pb.b))<=2*scale
        }
        for original in originals where valid(original.polygon) {
            if let e=original.detectorSeedEvidence, e.isValid, e.completeCCScan==true {
                let own=belongs(original.polygon)
                scope[e.ownerID]=(scope[e.ownerID] ?? true) && own
            }
        }
        var certified=[(NativeOCRDetectorSeedEvidence,NativeOCRDetectorSeedEvidence.Component)]()
        for original in originals {
            guard let e=original.detectorSeedEvidence,e.isValid,e.completeCCScan==true,
                  scope[e.ownerID]==true else { continue }
            for candidate in e.candidateComponents ?? [] {
                if !candidate.competingOwnerIDs.isEmpty &&
                    candidate.competingOwnerIDs.allSatisfy({scope[$0]==true}) {
                    certified.append((e,candidate.component))
                }
            }
        }
        guard certified.count<=4096 else { return [] }
        func internalUnknown(_ c:NativeOCRDetectorSeedEvidence.Component,_ e:NativeOCRDetectorSeedEvidence) -> Bool {
            certified.contains { pair in
                let other=pair.0
                return other.mapFullWidth==e.mapFullWidth && other.mapFullHeight==e.mapFullHeight &&
                    other.sourceWidth==e.sourceWidth && other.sourceHeight==e.sourceHeight &&
                    other.mapOriginX==e.mapOriginX && other.mapOriginY==e.mapOriginY && pair.1==c
            }
        }
        var owners=0, runCount=0
        for original in originals {
            guard valid(original.polygon), let e=original.detectorSeedEvidence,
                  e.isValid, e.completeCCScan==true else { continue }
            let own=belongs(original.polygon)
            if own { owners+=1 }
            for c in e.components {
                runCount+=c.runs.count
                if runCount>200_000 { return [] }
                if own { paint(c.runs,e,roi,&root) } else { paint(c.runs,e,roi,&foreign) }
            }
            for c in (e.ambiguousComponents ?? [])+(e.candidateComponents ?? []).map(\.component) {
                if own && internalUnknown(c,e) { paint(c.runs,e,roi,&intraUnitUnknown) }
                else { paint(c.runs,e,roi,&unknown) }
            }
        }
        for i in 0..<count { if foreign[i] || unknown[i] { root[i]=false } }
        let rootCount=root.reduce(0) { $0+($1 ? 1:0) }
        guard rootCount>=4 || rfCount>0 else { return axisLayers }
        if sourceFirstV2Enabled {
            return sourceFirstMeasurements(roi:roi,f:f,inside:inside,root:root,foreign:foreign,
                unknown:unknown,rootCount:rootCount,rfCount:rfCount,work:work)
        }
        var masks=[PaintMask]()
        func maskEnabled(_ name: String) -> Bool {
            let prefix="source-chromatic-paint/"+name+"/"
            switch name {
            case "db-chromatic-mode":
                return API.shouldGenerate(prefix+"collinear-pixel-chain-v1") ||
                    API.shouldGenerate(prefix+"finite-rim-v1") || API.shouldGenerate(prefix+"closed-collar-v1")
            case "query-chromatic-mode":
                return API.shouldGenerate(prefix+"collinear-pixel-chain-v1")
            case "row-relative-chromatic-continuation":
                return API.shouldGenerate(prefix+"finite-rim-v1")
            default: return false
            }
        }
        // Two distinct observation sources, not a tolerance/coordinate grid:
        // dominant DB-private paint and dominant paint inside the current query.
        // Their modes may differ (colored shell surrounding a white glyph).
        var palettes=[[Double]]()
        for useRoot in [true,false] {
            if useRoot && rootCount<4 { continue }
            let support=useRoot ? root:inside
            if let color=palette(roi,support) {
                if palettes.contains(where: { distance($0,color)<24 }) { continue }
                palettes.append(color)
                let name=useRoot ? "db-chromatic-mode":"query-chromatic-mode"
                // Palette precedence is shared with retained modes, even when
                // this mode has no enabled outputs.
                guard maskEnabled(name) else { continue }
                var mask=[Bool](repeating:false,count:count)
                let contrast=color.max()!-color.min()!
                for i in 0..<count {
                    let (r,g,b)=roi.pixel(x:i%w,y:i/w)
                    mask[i]=abs(r-color[0])<=32 && abs(g-color[1])<=32 && abs(b-color[2])<=32 &&
                        max(r,g,b)-min(r,g,b)>=0.6*contrast
                }
                masks.append(.init(pixels:mask,name:name))
            }
        }
        // Row-relative opponent contrast handles identical ink over changing
        // background. No copied DB margin/padding is placed in the output.
        if rootCount>=4, maskEnabled("row-relative-chromatic-continuation"),
           let mask=opponentMask(roi,f: f,inside:inside,root:root) {
            masks.append(.init(pixels:mask,name:"row-relative-chromatic-continuation"))
        }
        var observations=axisLayers
        var remainingMasks: [[Bool]:Int] = [:]
        if work != nil { for mask in masks { remainingMasks[mask.pixels,default:0] += 1 } }
        var segmentCache: [[Bool]:Segmentation] = [:], failedMasks=Set<[Bool]>()
        var rimCache: [[Bool]:[Int:(pixels:Set<Int>,rays:Int)]] = [:]
        let barriers=zip(foreign,unknown).map { $0 || $1 }
        for mask in masks {
            let prefix="source-chromatic-paint/"+mask.name+"/"
            let generateFill=mask.name != "row-relative-chromatic-continuation" &&
                API.shouldGenerate(prefix+"collinear-pixel-chain-v1")
            let generateRim=mask.name != "query-chromatic-mode" && API.shouldGenerate(prefix+"finite-rim-v1")
            let generateCollar=mask.name == "db-chromatic-mode" && API.shouldGenerate(prefix+"closed-collar-v1")
            guard generateFill || generateRim || generateCollar else { continue }
            let remaining=max(0,(remainingMasks[mask.pixels] ?? 1)-1)
            if work != nil { remainingMasks[mask.pixels]=remaining }
            let segmentation: Segmentation
            if work != nil, let cached=segmentCache[mask.pixels] {
                segmentation=cached;work?.note { $0.maskSegmentationCacheHits += 1 }
            } else {
                if work != nil && failedMasks.contains(mask.pixels) {
                    work?.note { $0.maskSegmentationCacheHits += 1 };continue
                }
                work?.note { $0.maskSegmentations += 1 }
                guard let measured=segment(mask.pixels,roi:roi,f:f,root:root,foreign:barriers,inside:inside) else {
                    if work != nil { failedMasks.insert(mask.pixels) };continue
                }
                segmentation=measured
                // Labels+pixel indices and one optional rim set are bounded;
                // never keep unique masks or large fits just for reassurance.
                if work != nil && remaining>0 && count<=4*1024*1024/32 { segmentCache[mask.pixels]=measured }
            }
            if remaining==0 { segmentCache.removeValue(forKey:mask.pixels) }
            defer { if remaining==0 { rimCache.removeValue(forKey:mask.pixels) } }
            let base:[String:Double]=["inputMaskPixels":Double(mask.pixels.filter{$0}.count),
                "inputComponentCount":Double(segmentation.components.count),"privateRootPixels":Double(rootCount),
                "originalGeometryAnchors":Double(owners),"rfTextBoundsWitnesses":Double(rfCount),
                "intraQueryUnknownDBPixels":Double(intraUnitUnknown.filter{$0}.count),
                "unresolvedDBPixels":Double(unknown.filter{$0}.count),
                "rfMasksUsed":0,"recognizerUsed":0,"membershipKnown":0,"geometryPadding":0,
                "seedFrameWidth":Double(dimensions.width),"seedFrameHeight":Double(dimensions.height),
                "seedFrameAgreementValidated":1,"decodedFrameExtentValidated":0]
            if generateCollar && rootCount>=4 && rfCount>0 {
                observations += shells(segmentation,roi:roi,f:f,root:root,foreign:foreign,unknown:unknown,
                                       maskName:mask.name,base:base)
            }
            guard generateFill || generateRim else { continue }
            // Compact components may be detached marks/glyph fragments. Their
            // collinearity is reported; it never certifies sourceMembers.
            let compact=segmentation.components.filter { c in
                let b=c.projected
                return !c.clipped && c.foreign==0 && c.pixels.count>=max(4,Int(scale*scale*0.003)) &&
                    b.width<=1.5*scale && b.height<=1.8*scale &&
                    abs((b.l+b.r-f.bounds.l-f.bounds.r)/2)<=0.5*scale &&
                    Double(c.pixels.count)/max(1,c.local.area)<0.85
            }
            guard compact.count<=1024 else { continue }
            var groups=[[Int]](), visited=Set<Int>()
            for start in compact.indices where !visited.contains(start) {
                var group=[start]; visited.insert(start); var head=0
                while head<group.count {
                    let a=compact[group[head]].projected; head+=1
                    for j in compact.indices where !visited.contains(j) {
                        let b=compact[j].projected
                        let cross=min(a.r,b.r)-max(a.l,b.l)
                        let gap=max(0,max(a.t-b.b,b.t-a.b))
                        if cross>=0.5*min(a.width,b.width) && gap<=0.75*scale &&
                            abs((a.l+a.r-b.l-b.r)/2)<=0.5*scale {
                            visited.insert(j); group.append(j)
                        }
                    }
                }
                groups.append(group)
            }
            for group in groups {
                let cs=group.map{compact[$0]}
                let roots=cs.reduce(0){$0+$1.roots}
                let isRFRooted=rfCount>0 && cs.contains { Double($0.inside)/Double($0.pixels.count)>=0.6 }
                guard cs.count>=2, roots>=4 || isRFRooted else { continue }
                var fill=B(), fillPixels=0, detached=0
                var rim=B(), rimPixels=Set<Int>(), finiteRays=0, rimComponents=0
                for c in cs {
                    fillPixels+=c.pixels.count
                    if c.roots==0 { detached+=1 }
                    for i in c.pixels { addPixel(i,roi:roi,f:f,to:&fill) }
                    let measured: (pixels:Set<Int>,rays:Int)
                    if work != nil && !generateRim {
                        measured=([],0);work?.note { $0.disabledRimMeasurementsSkipped += 1 }
                    } else if work != nil, let cached=rimCache[mask.pixels]?[c.id] {
                        measured=cached;work?.note { $0.finiteRimCacheHits += 1 }
                    } else {
                        work?.note { $0.finiteRimMeasurements += 1 }
                        measured=finiteRim(c,segmentation:segmentation,roi:roi,scale:scale,foreign:foreign,unknown:unknown)
                        if work != nil && remaining>0 && segmentCache[mask.pixels] != nil {
                            rimCache[mask.pixels,default:[:]][c.id]=measured
                        }
                    }
                    if measured.rays>0 {
                        rimComponents+=1; finiteRays+=measured.rays
                        for i in measured.pixels { rimPixels.insert(i) }
                    }
                }
                guard fill.height>=2*fill.width, fill.height>=0.5*f.bounds.height else { continue }
                var diagnostics=base
                diagnostics["componentCount"]=Double(cs.count)
                diagnostics["fillPixels"]=Double(fillPixels)
                diagnostics["actualPrivateHitPixels"]=Double(roots)
                diagnostics["detachedComponentsUnknownMembership"]=Double(detached)
                if work != nil && !generateRim {
                    diagnostics["finiteRimMeasurementSkippedDisabledProducer"]=1
                } else { diagnostics["finiteRimRayCount"]=Double(finiteRays) }
                let hasRim=generateRim && rimComponents>=2 && !rimPixels.isEmpty
                if hasRim {
                    rim=fill
                    for i in rimPixels { addPixel(i,roi:roi,f:f,to:&rim) }
                }
                // These are nested bounds of the SAME observed component chain,
                // not nearby candidates with inferred common ownership. When
                // the physically measured white rim changes at most 5% of the
                // envelope area, emit that complete paint envelope once. Keep
                // distinct fill/rim layers and every query-palette chain; an
                // unavailable rim producer can never suppress the fill producer.
                let rimRepresentsFill=mask.name == "db-chromatic-mode" && hasRim && fill.area>=0.95*rim.area
                if generateFill && !rimRepresentsFill {
                    observations.append(.init(polygon:f.polygon(fill),layer:"fill",
                        mechanism:prefix+"collinear-pixel-chain-v1",diagnostics:diagnostics))
                }
                if hasRim {
                    diagnostics["measuredWhiteRimPixels"]=Double(rimPixels.count)
                    observations.append(.init(polygon:f.polygon(rim),layer:"fill-and-finite-white-rim",
                        mechanism:prefix+"finite-rim-v1",diagnostics:diagnostics))
                }
            }
        }
        // Exact-geometry accounting across queries/producers remains the
        // wrapper's job; only the nested same-chain DB layers coalesce above.
        return observations
    }

    /// Aggressive generation experiment: observed source colors, one integer-
    /// moment canonical axis per physical chain, and one measured outer fallback.
    /// No query-angle/threshold grid, transverse query-envelope hybrid, caption
    /// interpretation, source ownership or late proposal selection is involved.
    private static func sourceFirstMeasurements(roi:API.PixelROI,f:Basis,inside:[Bool],root:[Bool],
                                                foreign:[Bool],unknown:[Bool],rootCount:Int,rfCount:Int,
                                                work:GenerationWorkV2Context?) -> [API.Measurement] {
        work?.note { $0.sourceFirstCalls += 1 }
        let bodyMechanism="source-chromatic-paint/source-first-v2/canonical-body"
        let completeMechanism="source-chromatic-paint/source-first-v2/canonical-complete"
        let bodyEnabled=API.shouldGenerate(bodyMechanism),completeEnabled=API.shouldGenerate(completeMechanism)
        guard bodyEnabled || completeEnabled else { return [] }
        let bridgePrivateEndpoints = recoveryV3Enabled
        let count=roi.width*roi.height,scale=f.bounds.width,barriers=zip(foreign,unknown).map { $0 || $1 }
        var support=rootCount>=4 ? root:inside,seenMasks=Set<[Bool]>(),result=[API.Measurement]()
        // A second distinct private palette is a LAZY fallback only when the
        // first cannot yield a canonical source chain. Different layers/fragments
        // never merge: the first valid source observation ends variant creation.
        for mode in 0..<2 {
            guard let color=palette(roi,support) else { break }
            var mask=[Bool](repeating:false,count:count)
            let contrast=color.max()!-color.min()!
            for i in 0..<count {
                let (r,g,b)=roi.pixel(x:i%roi.width,y:i/roi.width)
                mask[i]=abs(r-color[0])<=32 && abs(g-color[1])<=32 && abs(b-color[2])<=32 &&
                    max(r,g,b)-min(r,g,b)>=0.6*contrast
            }
            // Remove this exact color support only for discovery of the next
            // physical layer; no components/pixels from separate layers merge.
            support=root.indices.map { root[$0] && !mask[$0] }
            guard seenMasks.insert(mask).inserted else { continue }
            work?.note { $0.sourcePalettes += 1; $0.maskSegmentations += 1 }
            guard let segmentation=segment(mask,roi:roi,f:f,root:root,foreign:barriers,inside:inside) else { continue }
            let compact=segmentation.components.filter { c in
                !c.clipped && c.foreign==0 && c.pixels.count>=max(4,Int(scale*scale*0.003)) &&
                    c.projected.width<=1.5*scale && c.projected.height<=max(1.8*scale,1.1*f.bounds.height) &&
                    abs((c.projected.l+c.projected.r-f.bounds.l-f.bounds.r)/2)<=0.5*scale
            }
            guard compact.count<=1024 else { continue }
            var visited=Set<Int>()
            for start in compact.indices where !visited.contains(start) {
                var group=[start],head=0,endpointBridges=0;visited.insert(start)
                while head<group.count {
                    let a=compact[group[head]].projected;head+=1
                    for j in compact.indices where !visited.contains(j) {
                        let b=compact[j].projected
                        let gap=max(0,max(a.t-b.b,b.t-a.b))
                        let overlap=min(a.r,b.r)-max(a.l,b.l)
                        // V3 bridges a bounded measured endpoint gap only when
                        // BOTH actual same-palette CCs intersect private DB cells.
                        // No extrapolated box padding or detached-owner assertion.
                        let privateEndpointBridge=bridgePrivateEndpoints &&
                            compact[group[head-1]].roots>=2 && compact[j].roots>=2 &&
                            overlap>=0.65*min(a.width,b.width) && gap<=1.5*scale
                        if overlap>=0.5*min(a.width,b.width) &&
                            (gap<=0.75*scale || privateEndpointBridge) &&
                            abs((a.l+a.r-b.l-b.r)/2)<=0.5*scale {
                            if gap>0.75*scale { endpointBridges+=1 }
                            visited.insert(j);group.append(j)
                        }
                    }
                }
                let components=group.map {compact[$0]}.sorted {$0.id<$1.id}
                let roots=components.reduce(0){$0+$1.roots}
                let rfRooted=rfCount>0 && components.contains {Double($0.inside)/Double($0.pixels.count)>=0.6}
                guard roots>=4 || rfRooted else { continue }
                let pixels=components.flatMap(\.pixels)
                guard let canonical=sourceCanonicalBasis(pixels,roi:roi) else { continue }
                var body=B()
                for i in pixels {addPixel(i,roi:roi,f:canonical,to:&body)}
                guard body.height>=2*body.width,body.height>=0.5*f.bounds.height else { continue }
                work?.note {$0.sourceCanonicalFits += 1}
                var d:[String:Double]=["sourceFirstV2":1,"canonicalAxisFromSourcePixels":1,"paletteOrdinal":Double(mode),
                    "componentCount":Double(components.count),"fillPixels":Double(pixels.count),
                    "actualPrivateHitPixels":Double(roots),"membershipKnown":0,"geometryPadding":0,
                    "detachedComponentsUnknownMembership":Double(components.filter {$0.roots==0}.count),
                    "rfTextBoundsWitnesses":Double(rfCount),"recognizerUsed":0,"rfMasksUsed":0,"queryAngleHypotheses":0]
                if bridgePrivateEndpoints {
                    d["recoveryV3BoundedPrivateEndpointChainEnabled"]=1
                    d["recoveryV3MeasuredPrivateEndpointBridges"]=Double(endpointBridges)
                    d["recoveryV3MaximumEndpointGapWidths"]=1.5
                }
                var selectedBounds=body,selectedLayer="canonical-source-fill",selectedMechanism=bodyMechanism
                var hasComplete=false
                if completeEnabled {
                    var complete=body,completePixels=Set<Int>(),rimComponents=0,rays=0
                    for c in components {
                        work?.note {$0.finiteRimMeasurements += 1}
                        let rim=finiteRim(c,segmentation:segmentation,roi:roi,scale:body.width,foreign:foreign,unknown:unknown)
                        if rim.rays>0 {rimComponents+=1;rays+=rim.rays;completePixels.formUnion(rim.pixels)}
                    }
                    if rimComponents>=min(2,components.count),!completePixels.isEmpty {
                        for i in completePixels {addPixel(i,roi:roi,f:canonical,to:&complete)}
                        if complete.l != body.l || complete.r != body.r || complete.t != body.t || complete.b != body.b {
                            d["measuredWhiteRimPixels"]=Double(completePixels.count);d["finiteRimRayCount"]=Double(rays)
                            selectedBounds=complete;selectedLayer="canonical-source-fill-and-finite-white-rim"
                            selectedMechanism=completeMechanism;hasComplete=true
                        }
                    }
                }
                // One canonical source offer, created only AFTER deciding whether
                // physically bounded outer paint supplies the complete fallback.
                // Never instantiate body+rim+other-angle records and prune later.
                if hasComplete || bodyEnabled {
                    d["lazyCanonicalSourceOffer"]=1
                    result.append(.init(polygon:canonical.polygon(selectedBounds),layer:selectedLayer,
                                        mechanism:selectedMechanism,diagnostics:d))
                    if hasComplete {work?.note {$0.sourceCompleteFallbacks += 1}}
                    else {work?.note {$0.sourceBodies += 1}}
                    return result
                }
            }
        }
        return result
    }

    /// Integer raw moments make the axis independent of enumeration order,
    /// query corner/start/angle, and crop-local coordinates for identical pixels.
    /// Frame validation above bounds doubled coordinates to262145; <=1.5m pixels
    /// keeps all Int64 moment accumulators below their representable limit.
    private static func sourceCanonicalBasis(_ pixels:[Int],roi:API.PixelROI) -> Basis? {
        guard pixels.count>=4 else {return nil}
        var sx:Int64=0,sy:Int64=0,sxx:Int64=0,syy:Int64=0,sxy:Int64=0
        for i in pixels {
            let x=Int64(2*(roi.originX+i%roi.width)+1),y=Int64(2*(roi.originY+i/roi.width)+1)
            sx+=x;sy+=y;sxx+=x*x;syy+=y*y;sxy+=x*y
        }
        let n=Double(pixels.count),mx=Double(sx)/n,my=Double(sy)/n
        let xx=Double(sxx)/n-mx*mx,yy=Double(syy)/n-my*my,xy=Double(sxy)/n-mx*my
        guard xx.isFinite,yy.isFinite,xy.isFinite,xx+yy>0 else {return nil}
        let angle=0.5*atan2(2*xy,xx-yy)
        var along=V(x:cos(angle),y:sin(angle))
        if along.y<0 || (along.y==0 && along.x<0) {along=V(x:-along.x,y:-along.y)}
        return .init(o:.init(x:mx/2,y:my/2),n:.init(x:along.y,y:-along.x),a:along,bounds:B())
    }

    /// Parent can pass the ACTUAL decoded frame extents without changing PixelROI.
    /// This overload fails closed on any mismatched/malformed seed dimensions,
    /// including foreign/ambiguous evidence: such evidence can veto paint too.
    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI,
                        query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original],
                        rf: [NativeOCRSourceContext50V2.Primitive],
                        frameWidth: Int, frameHeight: Int,
                        generationWorkV2: GenerationWorkV2Context? = nil) -> [NativeOCRSourcePaintGeometry.Measurement] {
        guard let dimensions=sourceDimensions(originals),dimensions.width==frameWidth,
              dimensions.height==frameHeight,fits(roi,frameWidth:frameWidth,frameHeight:frameHeight) else { return [] }
        return measure(roi:roi,query:query,originals:originals,rf:rf,generationWorkV2:generationWorkV2).map { observation in
            var d=observation.diagnostics
            d["decodedFrameExtentValidated"]=1
            return .init(polygon:observation.polygon,layer:observation.layer,
                         mechanism:observation.mechanism,diagnostics:d)
        }
    }
    private static func sourceDimensions(_ originals:[NativeOCRSourceOwnedRailPartition.Original]) -> (width:Int,height:Int)? {
        var common:(width:Int,height:Int)?
        for original in originals {
            guard let e=original.detectorSeedEvidence else { continue }
            guard e.sourceWidth>0,e.sourceHeight>0,e.sourceWidth<=131072,e.sourceHeight<=131072 else { return nil }
            if let existing=common {
                guard existing.width==e.sourceWidth,existing.height==e.sourceHeight else { return nil }
            } else { common=(e.sourceWidth,e.sourceHeight) }
        }
        return common
    }
    private static func fits(_ roi:API.PixelROI,frameWidth:Int,frameHeight:Int) -> Bool {
        // Subtraction guards avoid overflow for a malformed externally supplied ROI.
        roi.originX>=0 && roi.originY>=0 && roi.originX<=frameWidth && roi.originY<=frameHeight &&
            roi.width>0 && roi.height>0 && roi.width<=frameWidth-roi.originX && roi.height<=frameHeight-roi.originY
    }

    private static func valid(_ q:[[Double]]) -> Bool {
        guard q.count==4,q.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else { return false }
        let turns=(0..<4).map { i -> Double in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
            return (b[0]-a[0])*(c[1]-b[1])-(b[1]-a[1])*(c[0]-b[0])
        }
        return turns.allSatisfy{$0>0} || turns.allSatisfy{$0<0}
    }
    private static func bounds(_ q:[[Double]]) -> B {
        var b=B(); for p in q { b.add(.init(x:p[0],y:p[1])) }; return b
    }
    private static func projected(_ q:[[Double]],_ f:Basis) -> B {
        var b=B(); for p in q { b.add(f.project(.init(x:p[0],y:p[1]))) }; return b
    }
    private static func basis(_ q:[[Double]]) -> Basis? {
        guard valid(q) else { return nil }
        var length=0.0, edge=V(x:0,y:0)
        for i in 0..<4 {
            let d=V(x:q[(i+1)%4][0]-q[i][0],y:q[(i+1)%4][1]-q[i][1]), l=hypot(d.x,d.y)
            if l>length { length=l; edge=d }
        }
        guard length>0 else { return nil }
        var a=V(x:edge.x/length,y:edge.y/length)
        if a.y<0 || (a.y==0 && a.x<0) { a=V(x:-a.x,y:-a.y) }
        let n=V(x:a.y,y:-a.x),o=V(x:q[0][0],y:q[0][1])
        let provisional=Basis(o:o,n:n,a:a,bounds:B())
        let b=projected(q,provisional)
        guard b.width.isFinite,b.height.isFinite,b.width>0,b.height>0 else { return nil }
        return .init(o:o,n:n,a:a,bounds:b)
    }
    private static func addPixel(_ i:Int,roi:API.PixelROI,f:Basis,to b:inout B) {
        let x=Double(roi.originX)+Double(i%roi.width),y=Double(roi.originY)+Double(i/roi.width)
        // Exact square support in query basis: no interpolated/fitted boundaries.
        for (dx,dy) in [(0.0,0.0),(1.0,0.0),(1.0,1.0),(0.0,1.0)] {
            b.add(f.project(.init(x:x+dx,y:y+dy)))
        }
    }
    private static func paint(_ runs:[NativeOCRDetectorSeedEvidence.Run],_ e:NativeOCRDetectorSeedEvidence,
                              _ roi:API.PixelROI,_ mask:inout [Bool]) {
        let sx=Double(e.sourceWidth)/Double(e.mapFullWidth),sy=Double(e.sourceHeight)/Double(e.mapFullHeight)
        for run in runs {
            // Runs already carry FULL-grid coordinates, including tile origin.
            // mapOrigin describes the capture window; adding it double-shifts.
            let left=Double(run.x)*sx-Double(roi.originX)
            let right=left+Double(run.count)*sx
            let top=Double(run.y)*sy-Double(roi.originY),bottom=top+sy
            guard right>0,left<Double(roi.width),bottom>0,top<Double(roi.height) else { continue }
            let x0=Int(max(0,ceil(left-0.5))),x1=Int(min(Double(roi.width),ceil(right-0.5)))
            let y0=Int(max(0,ceil(top-0.5))),y1=Int(min(Double(roi.height),ceil(bottom-0.5)))
            if x0<x1 && y0<y1 { for y in y0..<y1 { for x in x0..<x1 { mask[y*roi.width+x]=true } } }
        }
    }
    private static func median(_ values:[Double]) -> Double {
        guard !values.isEmpty else { return 0 }; let s=values.sorted(),m=s.count/2
        return s.count%2==0 ? (s[m-1]+s[m])/2:s[m]
    }
    private static func distance(_ a:[Double],_ b:[Double]) -> Double {
        sqrt(zip(a,b).reduce(0){$0+($1.0-$1.1)*($1.0-$1.1)})
    }
    private static func palette(_ roi:API.PixelROI,_ support:[Bool]) -> [Double]? {
        var hist=[Int](repeating:0,count:4096),samples=0
        for i in support.indices where support[i] {
            let (r,g,b)=roi.pixel(x:i%roi.width,y:i/roi.width)
            if max(r,g,b)-min(r,g,b)>=25 {
                let key=Int(r)/16*256+Int(g)/16*16+Int(b)/16; hist[key]+=1; samples+=1
            }
        }
        guard samples>=16,let maximum=hist.max(),maximum>=4 else { return nil }
        let mode=hist.firstIndex(of:maximum)!
        var red=[Double](),green=[Double](),blue=[Double]()
        for i in support.indices where support[i] {
            let (r,g,b)=roi.pixel(x:i%roi.width,y:i/roi.width)
            if Int(r)/16*256+Int(g)/16*16+Int(b)/16==mode { red.append(r);green.append(g);blue.append(b) }
        }
        return [median(red),median(green),median(blue)]
    }
    private static func darkMask(_ roi:API.PixelROI,inside:[Bool]) -> [Bool]? {
        var hist=[Double](repeating:0,count:256),chromatic=0,total=0
        for i in inside.indices where inside[i] {
            let (r,g,b)=roi.pixel(x:i%roi.width,y:i/roi.width)
            total+=1; if max(r,g,b)-min(r,g,b)>30 { chromatic+=1 }
            if min(r,g,b)<210 { hist[Int((0.299*r+0.587*g+0.114*b).rounded())]+=1 }
        }
        guard total>0,Double(chromatic)>=0.08*Double(total) else { return nil }
        let weight=hist.reduce(0,+),sum=hist.enumerated().reduce(0){$0+Double($1.offset)*$1.element}
        guard weight>0 else { return nil }
        var below=0.0,partial=0.0,best=0.0,threshold=0
        for i in 0..<256 {
            below+=hist[i]; partial+=Double(i)*hist[i]
            let denom=below*(weight-below)
            if denom>0 {
                let d=sum*below-partial*weight,v=d*d/denom
                if v>best { best=v; threshold=i }
            }
        }
        guard best>0,threshold<190 else { return nil }
        return inside.indices.map { i in
            let (r,g,b)=roi.pixel(x:i%roi.width,y:i/roi.width)
            return 0.299*r+0.587*g+0.114*b<=Double(threshold)
        }
    }
    private static func opponentMask(_ roi:API.PixelROI,f:Basis,inside:[Bool],root:[Bool],localFlanks:Bool=false) -> [Bool]? {
        // Row flank estimates are only meaningful for nearly upright columns.
        guard abs(f.a.x)<0.05 else { return nil }
        let width=roi.width,height=roi.height
        var backgrounds=[[Double]](repeating:[0,0,0],count:height),noise=[Double](repeating:12,count:height)
        for y in 0..<height {
            var rs=[Double](),gs=[Double](),bs=[Double]()
            for x in 0..<width {
                let p=f.project(.init(x:Double(roi.originX)+Double(x)+0.5,y:Double(roi.originY)+Double(y)+0.5))
                let flank=p.x<f.bounds.l-0.15*f.bounds.width || p.x>f.bounds.r+0.15*f.bounds.width
                let local=p.x>=f.bounds.l-0.5*f.bounds.width && p.x<=f.bounds.r+0.5*f.bounds.width
                if flank && (!localFlanks || local) {
                    let (r,g,b)=roi.pixel(x:x,y:y);rs.append(r);gs.append(g);bs.append(b)
                }
            }
            guard rs.count>=4 else { return nil }
            backgrounds[y]=[median(rs),median(gs),median(bs)]
        }
        var dr=[Double](),dg=[Double](),db=[Double]()
        for i in root.indices where root[i] && inside[i] {
            let y=i/width,(r,g,b)=roi.pixel(x:i%width,y:y),bg=backgrounds[y]
            let d=[r-bg[0],g-bg[1],b-bg[2]]
            if d.reduce(0,+)/3 < -30 { dr.append(d[0]);dg.append(d[1]);db.append(d[2]) }
        }
        guard dr.count>=16 else { return nil }
        var direction=[median(dr),median(dg),median(db)]
        let mean=direction.reduce(0,+)/3
        direction=direction.map{$0-mean};let norm=sqrt(direction.reduce(0){$0+$1*$1})
        guard norm>=25 else { return nil };direction=direction.map{$0/norm}
        for y in 0..<height {
            var deviations=[Double]()
            for x in 0..<width where !inside[y*width+x] {
                let p=f.project(.init(x:Double(roi.originX)+Double(x)+0.5,y:Double(roi.originY)+Double(y)+0.5))
                if localFlanks && !(p.x>=f.bounds.l-0.5*f.bounds.width && p.x<=f.bounds.r+0.5*f.bounds.width &&
                    (p.x<f.bounds.l-0.15*f.bounds.width || p.x>f.bounds.r+0.15*f.bounds.width)) { continue }
                let (r,g,b)=roi.pixel(x:x,y:y),bg=backgrounds[y]
                deviations.append(abs((r-bg[0])*direction[0]+(g-bg[1])*direction[1]+(b-bg[2])*direction[2]))
            }
            noise[y]=max(12,3*median(deviations))
        }
        return root.indices.map { i in
            let y=i/width,(r,g,b)=roi.pixel(x:i%width,y:y),bg=backgrounds[y]
            let p=f.project(.init(x:Double(roi.originX)+Double(i%width)+0.5,y:Double(roi.originY)+Double(y)+0.5))
            let d=[r-bg[0],g-bg[1],b-bg[2]],value=zip(d,direction).reduce(0){$0+$1.0*$1.1}
            return p.x>=f.bounds.l-0.15*f.bounds.width && p.x<=f.bounds.r+0.15*f.bounds.width &&
                value>noise[y] && d.reduce(0,+)/3 < -10
        }
    }
    private static func segment(_ mask:[Bool],roi:API.PixelROI,f:Basis,root:[Bool],foreign:[Bool],inside:[Bool],diagonal:Bool=false) -> Segmentation? {
        let w=roi.width,h=roi.height
        var labels=[Int](repeating:0,count:mask.count),components=[Component]()
        let neighbors=diagonal ? [(1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)] : [(1,0),(-1,0),(0,1),(0,-1)]
        for start in mask.indices where mask[start] && labels[start]==0 {
            if components.count>=4096 { return nil }
            let id=components.count+1
            var queue=[start],head=0,local=B(),projection=B(),roots=0,foreignHits=0,insideHits=0,clipped=false
            labels[start]=id
            while head<queue.count {
                let i=queue[head];head+=1;let x=i%w,y=i/w
                local.add(.init(x:Double(x),y:Double(y)));local.add(.init(x:Double(x+1),y:Double(y+1)))
                addPixel(i,roi:roi,f:f,to:&projection)
                if root[i] { roots+=1 };if foreign[i] { foreignHits+=1 };if inside[i] { insideHits+=1 }
                if x==0 || x==w-1 || y==0 || y==h-1 { clipped=true }
                for (dx,dy) in neighbors {
                    let nx=x+dx,ny=y+dy
                    if nx>=0 && nx<w && ny>=0 && ny<h {
                        let ni=ny*w+nx
                        if mask[ni] && labels[ni]==0 { labels[ni]=id;queue.append(ni) }
                    }
                }
            }
            components.append(.init(id:id,pixels:queue,local:local,projected:projection,roots:roots,
                                    foreign:foreignHits,inside:insideHits,clipped:clipped))
        }
        return .init(labels:labels,components:components)
    }
    private static func finiteRim(_ c:Component,segmentation:Segmentation,roi:API.PixelROI,scale:Double,
                                  foreign:[Bool],unknown:[Bool]) -> (pixels:Set<Int>,rays:Int) {
        let w=roi.width,h=roi.height,maxRay=min(256,max(3,Int(ceil(scale*0.3))))
        var rows=[Int:(Int,Int)](),columns=[Int:(Int,Int)]()
        for i in c.pixels {
            let x=i%w,y=i/w
            if let p=rows[y] { rows[y]=(min(p.0,x),max(p.1,x)) } else { rows[y]=(x,x) }
            if let p=columns[x] { columns[x]=(min(p.0,y),max(p.1,y)) } else { columns[x]=(y,y) }
        }
        var rays=[(Int,Int,Int,Int,Int)]()
        for y in rows.keys.sorted() { let p=rows[y]!;rays.append((p.0,y,-1,0,0));rays.append((p.1,y,1,0,1)) }
        for x in columns.keys.sorted() { let p=columns[x]!;rays.append((x,p.0,0,-1,2));rays.append((x,p.1,0,1,3)) }
        var endpoints=[([Int],Int)](),directions=Set<Int>()
        for (x,y,dx,dy,direction) in rays {
            var white=[Int]()
            for step in 1...maxRay {
                let nx=x+step*dx,ny=y+step*dy
                guard nx>=0,nx<w,ny>=0,ny<h else { break }
                let i=ny*w+nx
                if foreign[i] || unknown[i] { break }
                let label=segmentation.labels[i]
                if label != 0 { break } // Another paint core never proves a finite exterior rim.
                let (r,g,b)=roi.pixel(x:nx,y:ny)
                if min(r,g,b)>=210 && max(r,g,b)-min(r,g,b)<=48 { white.append(i) }
                else if !white.isEmpty {
                    endpoints.append((white,direction));break
                } else if step>2 { break }
            }
        }
        guard endpoints.count>=max(8,Int(Double(rays.count)*0.2)) else { return ([],0) }
        let typical=median(endpoints.map{Double($0.0.count)})
        var result=Set<Int>(),kept=0
        for (pixels,direction) in endpoints where Double(pixels.count)<=1.5*typical {
            for i in pixels { result.insert(i) };kept+=1;directions.insert(direction)
        }
        guard directions.count>=3 else { return ([],0) }
        return (result,kept)
    }

    /// Closed chromatic collar/shell: flood only its measured complement to find
    /// enclosed holes. No polygon-fill or white-paper flood becomes paint support.
    /// Foreign private cells or unresolved ambiguity inside the filled shell veto
    /// it. All qualifying shells are emitted separately; no strongest-shell pick.
    private static func shells(_ s:Segmentation,roi:API.PixelROI,f:Basis,root:[Bool],foreign:[Bool],unknown:[Bool],
                               maskName:String,base:[String:Double]) -> [API.Measurement] {
        var output=[API.Measurement](),work=0
        for c in s.components {
            let p=c.projected
            guard !c.clipped,p.width<=2*f.bounds.width,p.height>=0.7*f.bounds.height,
                  abs((p.l+p.r-f.bounds.l-f.bounds.r)/2)<=0.5*f.bounds.width,
                  Double(c.pixels.count)<0.8*c.local.area else { continue }
            let x0=Int(c.local.l),y0=Int(c.local.t),w=Int(c.local.width),h=Int(c.local.height)
            work+=w*h
            if work>6_000_000 { return [] } // Whole shell pass abstains on work exhaustion.
            var visited=[Bool](repeating:false,count:w*h),holes=0,filledRoots=c.roots,blocked=c.foreign>0
            var brightHoles=0,enclosedPixels=0
            for sy in 0..<h { for sx in 0..<w {
                let start=sy*w+sx,global=(sy+y0)*roi.width+sx+x0
                if visited[start] || s.labels[global]==c.id { continue }
                visited[start]=true
                var queue=[start],head=0,touches=false,bright=0,roots=0,barrier=false
                while head<queue.count {
                    let i=queue[head];head+=1;let x=i%w,y=i/w,g=(y+y0)*roi.width+x+x0
                    if x==0 || y==0 || x==w-1 || y==h-1 { touches=true }
                    let (r,green,b)=roi.pixel(x:x+x0,y:y+y0)
                    if min(r,green,b)>=192 && max(r,green,b)-min(r,green,b)<=48 { bright+=1 }
                    if root[g] { roots+=1 };if foreign[g] || unknown[g] { barrier=true }
                    for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                        let nx=x+dx,ny=y+dy
                        if nx>=0 && nx<w && ny>=0 && ny<h {
                            let ni=ny*w+nx,ng=(ny+y0)*roi.width+nx+x0
                            if !visited[ni] && s.labels[ng] != c.id { visited[ni]=true;queue.append(ni) }
                        }
                    }
                }
                if !touches {
                    holes+=1;filledRoots+=roots;enclosedPixels+=queue.count
                    if barrier { blocked=true }
                    if bright>=4 && Double(bright)>=0.4*Double(queue.count) { brightHoles+=1 }
                }
            } }
            if c.pixels.contains(where:{unknown[$0]}) { blocked=true }
            guard !blocked,filledRoots>=12,holes>=2,brightHoles>=2 else { continue }
            var d=base
            d["shellPixels"]=Double(c.pixels.count);d["enclosedPixels"]=Double(enclosedPixels)
            d["closedHoleCount"]=Double(holes);d["brightClosedHoleCount"]=Double(brightHoles)
            d["actualPrivateHitPixels"]=Double(filledRoots);d["foreignOrUnresolvedHits"]=0
            d["detachedMembershipUnknown"]=1
            output.append(.init(polygon:f.polygon(p),layer:"closed-chromatic-shell",
                mechanism:"source-chromatic-paint/"+maskName+"/closed-collar-v1",diagnostics:d))
        }
        return output
    }

    /// Additional CROP CONTEXT only, not a measurement or ownership declaration.
    /// Parent appends these before cropping, once per original bank. This lets
    /// measured ink traverse several collinear original detector fragments when
    /// no incumbent query's ROI contains the whole chain. sourceIndex is context
    /// provenance only; sourceMembers deliberately remains empty/UNKNOWN.
    static func contextualQueries(originals:[NativeOCRSourceOwnedRailPartition.Original]) -> [NativeOCRSourcePaintGeometry.Query] {
        guard sourceDimensions(originals) != nil else { return [] }
        let candidates=originals.indices.filter { i in
            let o=originals[i]
            guard valid(o.polygon),let e=o.detectorSeedEvidence,e.isValid,e.completeCCScan==true,
                  !e.components.isEmpty else { return false }
            let b=bounds(o.polygon)
            return b.width>=3 && b.height>=1.8*b.width &&
                abs(o.polygon[0][0]-o.polygon[3][0])<=0.25*b.width
        }
        guard candidates.count<=512 else { return [] }
        var seen=Set<Int>(),result=[API.Query]()
        for start in candidates where !seen.contains(start) {
            var group=[start],head=0;seen.insert(start)
            while head<group.count {
                let a=bounds(originals[group[head]].polygon);head+=1
                for j in candidates where !seen.contains(j) {
                    let b=bounds(originals[j].polygon),width=max(a.width,b.width)
                    let gap=max(0,max(a.t-b.b,b.t-a.b))
                    if min(a.width,b.width)/width>=0.65 && gap<=width &&
                        abs((a.l+a.r-b.l-b.r)/2)<=0.22*width {
                        seen.insert(j);group.append(j)
                    }
                }
            }
            if group.count>=2 {
                var union=B()
                for i in group { for p in originals[i].polygon { union.add(.init(x:p[0],y:p[1])) } }
                result.append(.init(polygon:[[union.l,union.t],[union.r,union.t],[union.r,union.b],[union.l,union.b]],
                                    sourceIndex:start,sourceMembers:[],contextSourceIndices:group))
            }
        }
        return result
    }

    /// Actual DB foreground intersections corroborate paint, never certify a
    /// query's parent/child lineage. Broad owner polygons are NOT rasterized.
    private static func axisLocalLayers(roi:API.PixelROI,query:API.Query,
                                        originals:[NativeOCRSourceOwnedRailPartition.Original],
                                        work:GenerationWorkV2Context?) -> [API.Measurement] {
        let generateAxis=API.shouldGenerate("source-chromatic-paint/source-axis-color-direction-chain-v2")
        let generateCore=API.shouldGenerate("source-chromatic-paint/outlined-core-transverse-source-axis-v2")
        let generateContinuation=API.shouldGenerate("source-chromatic-paint/seed-envelope-observed-continuation-v2")
        // Use the same immutable opt-in producer plan as DB/query/row layers.
        // Keep shared DB intersections whenever a retained sibling needs them.
        guard generateAxis || generateCore || generateContinuation else { return [] }
        let count=roi.width*roi.height,q=bounds(query.polygon)
        let upright=Basis(o:.init(x:0,y:0),n:.init(x:1,y:0),a:.init(x:0,y:1),bounds:q)
        var roots=[Bool](repeating:false,count:count),runCount=0
        for original in originals {
            guard let e=original.detectorSeedEvidence,e.isValid,e.completeCCScan==true else { continue }
            for c in e.components {
                runCount+=c.runs.count
                if runCount>200_000 { return [] }
                paint(c.runs,e,roi,&roots)
            }
        }
        guard roots.contains(true) else { return [] }
        let empty=[Bool](repeating:false,count:count)
        var inside=empty
        for i in 0..<count {
            let x=Double(roi.originX+i%roi.width)+0.5,y=Double(roi.originY+i/roi.width)+0.5
            inside[i]=x>=q.l && x<q.r && y>=q.t && y<q.b
        }
        var result=[API.Measurement]()
        if generateAxis {
            if let work {
                result += work.measurements(roi:roi,roots:roots,axis:true) { axisColorChains(roi:roi,roots:roots) }
            } else { result += axisColorChains(roi:roi,roots:roots) }
        }
        // Hybrid measurement from the original core-axis prototype: observed
        // dark transverse ink plus EXISTING query longitudinal endpoints. This
        // is explicitly a source-envelope layer, not fully observed fill extent.
        if generateCore {
            result += coreTransverseLayer(roi:roi,query:query,roots:roots,inside:inside,upright:upright)
        }
        result += sourceSeedContinuations(roi:roi,originals:originals,work:work)
        return result
    }

    /// Reads only actual crop bytes/origin and the union of measured private
    /// DB cells. No current query orientation, bounds, RF, membership or IDs.
    private static func axisColorChains(roi:API.PixelROI,roots:[Bool]) -> [API.Measurement] {
        let count=roi.width*roi.height,empty=[Bool](repeating:false,count:count),all=[Bool](repeating:true,count:count)
        let upright=Basis(o:.init(x:0,y:0),n:.init(x:1,y:0),a:.init(x:0,y:1),bounds:B())
        var saturated=empty,result=[API.Measurement]()
        for i in 0..<count {
            let (r,g,b)=roi.pixel(x:i%roi.width,y:i/roi.width),high=max(r,g,b),chroma=high-min(r,g,b)
            saturated[i]=chroma>=0.24*255 && chroma>=0.45*max(1,high)
        }
        if let s=segment(saturated,roi:roi,f:upright,root:roots,foreign:empty,inside:all,diagonal:true) {
            let compact=s.components.filter { c in
                let b=c.projected
                return !c.clipped && c.pixels.count>=4 && Double(c.pixels.count)/c.local.area>=0.10 &&
                    max(b.width,b.height)<=6*min(b.width,b.height)
            }
            if compact.count<=512 {
                let colors=compact.map { c -> [Double] in
                    var channels=[[Double]](repeating:[],count:3)
                    for i in c.pixels {
                        let (r,g,b)=roi.pixel(x:i%roi.width,y:i/roi.width),mean=(r+g+b)/3
                        channels[0].append(r-mean);channels[1].append(g-mean);channels[2].append(b-mean)
                    }
                    let v=channels.map{median($0)},norm=sqrt(v.reduce(0){$0+$1*$1})
                    return norm>0 ? v.map{$0/norm}:[0,0,0]
                }
                var visited=Set<Int>()
                for start in compact.indices where !visited.contains(start) {
                    var chain=[start],head=0;visited.insert(start)
                    while head<chain.count {
                        let index=chain[head],a=compact[index].projected;head+=1
                        for j in compact.indices where !visited.contains(j) {
                            let b=compact[j].projected,gap=max(0,max(a.t-b.b,b.t-a.b))
                            let overlap=max(0,min(a.r,b.r)-max(a.l,b.l))/min(a.width,b.width)
                            let agreement=zip(colors[index],colors[j]).reduce(0){$0+$1.0*$1.1}
                            if overlap>=0.5 && abs((a.l+a.r-b.l-b.r)/2)<=0.5*max(a.width,b.width) &&
                                gap<=1.25*max(a.width,b.width) && agreement>=0.95 {
                                visited.insert(j);chain.append(j)
                            }
                        }
                    }
                    var measured=B(),ink=0,hits=0
                    for j in chain {
                        for i in compact[j].pixels { addPixel(i,roi:roi,f:upright,to:&measured) }
                        ink+=compact[j].pixels.count;hits+=compact[j].roots
                    }
                    let anchors=chain.filter { j in
                        let b=compact[j].projected
                        return b.width>=0.5*measured.width && b.height>=0.35*measured.width
                    }.count
                    if chain.count>=3 && anchors>=2 && measured.height>=2*measured.width &&
                        Double(hits)>=0.10*Double(ink) {
                        result.append(.init(polygon:upright.polygon(measured),layer:"saturated-upright-fill",
                            mechanism:"source-chromatic-paint/source-axis-color-direction-chain-v2",
                            diagnostics:["componentCount":Double(chain.count),"substantialAnchors":Double(anchors),
                                "fillPixels":Double(ink),"actualDBIntersectingPixels":Double(hits),
                                "queryAxisUsed":0,"geometryPadding":0,"membershipKnown":0,
                                "detachedMembershipUnknown":1,"recognizerUsed":0,"rfMasksUsed":0]))
                    }
                }
            }
        }
        return result
    }

    private static func coreTransverseLayer(roi:API.PixelROI,query:API.Query,roots:[Bool],inside:[Bool],upright:Basis) -> [API.Measurement] {
        let q=upright.bounds,scale=q.width
        guard scale>=3,q.height>=2.5*scale,q.height<=15*scale,
              abs(query.polygon[1][1]-query.polygon[0][1])<=0.1*scale,
              let mask=darkMask(roi,inside:inside) else { return [] }
        let empty=[Bool](repeating:false,count:roots.count)
        guard let s=segment(mask,roi:roi,f:upright,root:roots,foreign:empty,inside:inside,diagonal:true) else { return [] }
        let cores=s.components.filter { c in
            let b=c.projected
            return c.pixels.count>=max(4,Int(0.01*scale*scale)) && b.width>=0.3*scale &&
                abs((b.l+b.r-q.l-q.r)/2)<=0.3*scale
        }
        guard cores.count>=3,cores.count<=64,cores.allSatisfy({!$0.clipped && $0.projected.t>=q.t && $0.projected.b<=q.b}),
              cores.reduce(0,{$0+$1.roots})>=4 else { return [] }
        let centers=cores.map{($0.projected.l+$0.projected.r)/2}
        let along=cores.map{($0.projected.t+$0.projected.b)/2}
        let mx=centers.reduce(0,+)/Double(centers.count),my=along.reduce(0,+)/Double(along.count)
        let denom=along.reduce(0){$0+($1-my)*($1-my)}
        guard denom>0 else { return [] }
        let slope=zip(centers,along).reduce(0){$0+($1.0-mx)*($1.1-my)}/denom
        guard abs(slope)<=0.04,centers.max()!-centers.min()!<=0.18*scale else { return [] }
        var minWhite=1.0,measured=B(),ink=0
        let radius=max(1,Int((0.03*scale).rounded())),width=roi.width,height=roi.height
        for c in cores {
            var ring=Set<Int>()
            for i in c.pixels {
                let x=i%width,y=i/width
                for dy in -radius...radius { for dx in -radius...radius {
                    let nx=x+dx,ny=y+dy
                    if nx>=0 && nx<width && ny>=0 && ny<height {
                        let ni=ny*width+nx
                        if s.labels[ni] != c.id { ring.insert(ni) }
                    }
                } }
                addPixel(i,roi:roi,f:upright,to:&measured)
            }
            guard !ring.isEmpty else { return [] }
            let white=ring.filter { i in
                let (r,g,b)=roi.pixel(x:i%width,y:i/width);return min(r,g,b)>=210
            }.count
            minWhite=min(minWhite,Double(white)/Double(ring.count));ink+=c.pixels.count
        }
        guard minWhite>=0.6,measured.width>=0.55*scale,measured.width<=0.95*scale else { return [] }
        measured.t=q.t;measured.b=q.b
        return [.init(polygon:upright.polygon(measured),layer:"measured-core-transverse-source-longitudinal",
            mechanism:"source-chromatic-paint/outlined-core-transverse-source-axis-v2",
            diagnostics:["componentCount":Double(cores.count),"corePixels":Double(ink),"minimumWhiteRingShare":minWhite,
                "centerSlope":slope,"longitudinalEndpointsFromQuery":1,"geometryPadding":0,"membershipKnown":0,
                "detachedMembershipUnknown":1,"recognizerUsed":0,"rfMasksUsed":0])]
    }

    /// A palette belongs to an ACTUAL seed observation, not every nearby query
    /// or lower detector box. Same-color continuation remains unknown membership.
    /// Returns the source-envelope hybrid using measured ink; it never
    /// extrapolates beyond the RGB crop or adds label padding.
    private static func sourceSeedContinuations(roi:API.PixelROI,
                                               originals:[NativeOCRSourceOwnedRailPartition.Original],
                                               work:GenerationWorkV2Context?) -> [API.Measurement] {
        guard API.shouldGenerate("source-chromatic-paint/seed-envelope-observed-continuation-v2") else { return [] }
        var output=[API.Measurement]()
        let count=roi.width*roi.height,empty=[Bool](repeating:false,count:count)
        let left=Double(roi.originX),top=Double(roi.originY)
        let right=left+Double(roi.width),bottom=top+Double(roi.height)
        for original in originals {
            guard valid(original.polygon),let e=original.detectorSeedEvidence,e.isValid,
                  e.completeCCScan==true,!e.components.isEmpty else { continue }
            let q=bounds(original.polygon),scale=q.width
            guard scale>=6,q.height>=1.8*scale,
                  abs(original.polygon[0][0]-original.polygon[3][0])<=0.05*scale,
                  q.l-0.5*scale>=left,q.r+0.5*scale<=right,q.t>=top,q.b<bottom else { continue }
            let f=Basis(o:.init(x:0,y:0),n:.init(x:1,y:0),a:.init(x:0,y:1),bounds:q)
            var roots=empty,inside=empty
            for c in e.components { paint(c.runs,e,roi,&roots) }
            for i in 0..<count {
                let x=left+Double(i%roi.width)+0.5,y=top+Double(i/roi.width)+0.5
                inside[i]=x>=q.l && x<q.r && y>=q.t && y<q.b
            }
            if let work {
                output += work.measurements(roi:roi,roots:roots,seedBounds:[q.l,q.t,q.r,q.b],axis:false) {
                    seedContinuation(roi:roi,q:q,roots:roots,inside:inside,f:f)
                }
            } else { output += seedContinuation(roi:roi,q:q,roots:roots,inside:inside,f:f) }
        }
        return output
    }
    private static func seedContinuation(roi:API.PixelROI,q:B,roots:[Bool],inside:[Bool],f:Basis) -> [API.Measurement] {
        let scale=q.width,count=roi.width*roi.height,empty=[Bool](repeating:false,count:count)
            guard let mask=opponentMask(roi,f:f,inside:inside,root:roots,localFlanks:true),
                  let s=segment(mask,roi:roi,f:f,root:roots,foreign:empty,inside:inside) else { return [] }
            let compact=s.components.filter { c in
                !c.clipped && c.pixels.count>=max(4,Int(scale*scale*0.005)) &&
                    c.projected.width<=1.2*scale && c.projected.height<=1.4*scale
            }
            var accepted=compact.filter { $0.projected.overlap(q)>0 }
            guard accepted.reduce(0,{$0+$1.roots})>0,let initialEnd=accepted.map({$0.projected.b}).max() else { return [] }
            var end=initialEnd
            // No upward borrowing of unrelated title strokes. Growth stops at
            // the first unsupported blank interval; only actual components grow.
            for c in compact.filter({$0.projected.t>=q.b}).sorted(by:{$0.projected.t<$1.projected.t}) {
                if c.projected.t-end>0.65*scale { break }
                accepted.append(c);end=max(end,c.projected.b)
            }
            guard end-q.b>=0.4*scale else { return [] }
            var measured=B(),pixels=0,hits=0,detached=0
            for c in accepted {
                for i in c.pixels { addPixel(i,roi:roi,f:f,to:&measured) }
                pixels+=c.pixels.count;hits+=c.roots;if c.roots==0 { detached+=1 }
            }
            let d:[String:Double]=["componentCount":Double(accepted.count),"fillPixels":Double(pixels),
                "actualSeedIntersectingPixels":Double(hits),"detachedComponentsUnknownMembership":Double(detached),
                "seedPaletteScope":1,"localFlankScope":1,"measuredDownwardGrowth":end-q.b,
                "geometryPadding":0,"membershipKnown":0,"recognizerUsed":0,"rfMasksUsed":0]
            var envelope=measured
            envelope.add(.init(x:q.l,y:q.t));envelope.add(.init(x:q.r,y:q.b))
            var hybrid=d;hybrid["existingSourceEnvelopeIncluded"]=1
            return [.init(polygon:f.polygon(envelope),layer:"source-envelope-and-measured-continuation",
                mechanism:"source-chromatic-paint/seed-envelope-observed-continuation-v2",diagnostics:hybrid)]
    }

}
