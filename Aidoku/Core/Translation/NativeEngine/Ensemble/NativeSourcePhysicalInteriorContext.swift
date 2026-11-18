import CoreGraphics
import Foundation

/// Terminal, fixed-raster evidence refinement only. A source-seeded component
/// is not physical certainty. Unknown/unsafe evidence never removes an owner.
/// The parent scopes fresh original RGB + effective erasure in this TaskLocal.
final class NativeSourcePhysicalInteriorContext: @unchecked Sendable {
    typealias Primitive = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    typealias Tuple = (fills: [Primitive], audit: [[String: Any]])
    @TaskLocal static var current: NativeSourcePhysicalInteriorContext?
    /// Original-source evidence exclusively for exterior cohort motion. Never
    /// promotes legacy shape/body/edge consumers into having a physical scope.
    @TaskLocal static var cohortBoundaryContext: NativeSourcePhysicalInteriorContext?


    private let rgb: [UInt8], erased: [UInt8]
    private let sourceOpaque: Bool
    private let width: Int, height: Int
    let sourceIdentity: String
    var sourcePageSize: CGSize {CGSize(width:width,height:height)}
    /// Same authenticated source RGB/erasure already supplied for placement;
    /// this fallback never decodes a page or synthesizes foreground pixels.
    func sourceTextRotation(raw:[String:Any],guide:[String:Any])->NativeSourceTextRotation.PixelObservation? {
        guard sourceOpaque,let packet=try? NativeTextPlacementGuide.decode(guide),
              let style=(raw["sourcePredictedStyle"] ?? raw["sourceAppearance"])as?[String:Any],
              style["sourceOnly"]as?Bool==true,
              let background=(style["background"]as?[String:Any])?["rgb"]as?[Double],background.count==3,
              let font=(raw["sourceFontSize"]as?NSNumber)?.doubleValue else{return nil}
        var colors:[[Double]]=[]
        if let fill=(style["fill"]as?[String:Any])?["rgb"]as?[Double],fill.count==3 {colors.append(fill)}
        if let outline=style["outline"]as?[String:Any],outline["present"]as?Bool==true,
           let color=outline["rgb"]as?[Double],color.count==3 {colors.append(color)}
        func contrast(_ color:[Double])->Double {zip(color,background).reduce(0.0){$0+pow($1.0-$1.1,2)}}
        guard let foreground=colors.max(by:{contrast($0)<contrast($1)})else{return nil}
        return NativeSourceTextRotation.estimatePixels(rgb:rgb,mask:erased,width:width,height:height,
            rect:packet.rect(in:CGRect(x:0,y:0,width:width,height:height)),
            foreground:foreground,background:background,font:font)
    }
    private let lock = NSLock()
    private struct Key: Hashable { let owner: String; let source: [Double]; let policy: Data }
    private struct Evidence {
        let report: NativeSourcePixelInterior.Report
        let domain: Domain?
        /// Raw mask coordinates are always global; the two evidence kinds
        /// must not share an assumed ROI origin.
        let rawMask: NativeSourcePixelInterior.Mask?
        let barrier: NativeSourceClosedBarrierInterior.Report?
        var available: Bool { report.available || barrier?.available == true }
        var status: String { report.available ? report.status : (barrier?.status ?? report.status) }
        var kind: String { report.available ? "source-uniform-background-component" : "source-closed-colour-barrier" }
    }
    private var cache: [Key: Evidence] = [:]
    private var cachedBytes = 0
    private static let maxROI = 8_000_000
    private static let maxIntervals = 250_000
    private static let maxWork = 2_000_000
    // Component evidence is conditional. A fixed-raster repair may move at
    // most half a glyph; larger corrections require a separate layout plan.
    static let maxFixedRasterShiftEm: CGFloat = 0.5

    static var closedBarrierEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_SOURCE_CLOSED_BARRIER"] == "1"
    }

    /// RGB decoding elsewhere composites alpha onto white. That canvas alone
    /// cannot establish a real closed contour in an originally transparent ROI.
    static func opaqueSourceProof(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default:
            guard let bytes = try? NativeMandatoryDisplayStroke.rgba(image) else { return false }
            return stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 }
        }
    }

    init?(rgb: [UInt8], width: Int, height: Int, erased: [UInt8], sourceIdentity: String,
          sourceOpaque: Bool = false) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 16_777_216 / height, rgb.count == width * height * 3,
              erased.count == width * height, !sourceIdentity.isEmpty, sourceIdentity.utf8.count <= 4096 else { return nil }
        self.rgb = rgb; self.erased = erased; self.width = width; self.height = height
        self.sourceOpaque = sourceOpaque
        self.sourceIdentity = sourceIdentity
    }

    // Fixed, source-only preservation veto. Distances are exact Chebyshev,
    // saturated at 4 (sufficient for new<=2 && old-new>1), NOT Euclidean.
    // A pass is not a physical-interior certificate. No predicted mask is used.
    // Immutable rank-prefix representation: 4-bit exact distance + two 64-bit
    // row masks. Payload 3072B/tile versus previous 4096B/tile; 512 tiles unchanged.
    struct BoundaryTile {
        let packed:[UInt8]
        let near:[UInt64]
        let missing:[UInt64]
        init?(distances:[UInt8]) {
            guard distances.count==4096 else{return nil}
            var bytes=[UInt8](repeating:0,count:2048),n=[UInt64](repeating:0,count:64),u=n
            for i in distances.indices {
                let d=distances[i];guard d<=4 || d==255 else{return nil}
                let v:UInt8=d==255 ? 15:d
                bytes[i/2] |= v << UInt8((i%2)*4)
                if d<=2 {n[i/64] |= UInt64(1)<<UInt64(i%64)}
                if d==255 {u[i/64] |= UInt64(1)<<UInt64(i%64)}
            }
            // Self-certify decoded distances and EVERY row-prefix rank exactly.
            for y in 0..<64 {
                var nc=0,uc=0
                for x in 0...64 {
                    let mask=Self.low(x)
                    guard (n[y]&mask).nonzeroBitCount==nc,(u[y]&mask).nonzeroBitCount==uc else{return nil}
                    if x<64 {
                        let i=y*64+x,v=(bytes[i/2]>>UInt8((i%2)*4))&15,d:UInt8=v==15 ? 255:v
                        guard d==distances[i] else{return nil}
                        if d<=2 {nc+=1};if d==255 {uc+=1}
                    }
                }
            }
            packed=bytes;near=n;missing=u
        }
        static func low(_ n:Int)->UInt64 {n==64 ? UInt64.max:(n==0 ? 0:(UInt64(1)<<UInt64(n))-1)}
        func distance(_ i:Int)->UInt8 {let n=(packed[i/2]>>UInt8((i%2)*4))&15;return n==15 ? 255:n}
        func counts(y:Int,left:Int,right:Int)->(near:Int,unknown:Int,firstNear:Int?) {
            let mask=Self.low(right) & ~Self.low(left),hits=near[y]&mask
            return ((near[y]&Self.low(right)).nonzeroBitCount-(near[y]&Self.low(left)).nonzeroBitCount,
                (missing[y]&Self.low(right)).nonzeroBitCount-(missing[y]&Self.low(left)).nonzeroBitCount,
                hits==0 ? nil:hits.trailingZeroBitCount)
        }
    }
    private var sourceClassifiedPixels=0
    private var shapeIntervalQueries=0
    private var prefixReferenceEarly=0,prefixReferencePassing=0,prefixReferencePixels=0
    private var prefixParityChecks=0

    private var boundaryTiles: [Int: BoundaryTile] = [:]
    private var boundaryWork = 0
    private var boundarySamples = 0
    private var shapeEvidencePixels = 0
    private static let boundaryTileSide = 64
    private static let maxBoundaryTiles = 512
    private static let maxBoundarySamples = 2_000_000
    private static let maxBoundaryWork = 8_000_000

    /// The lock covers cache construction and measurement, bounding concurrent
    /// work as well as storage. Cache keys are local to immutable source RGB /
    /// effective erasure / sourceIdentity held by this context.
    func boundaryClearance(before: NativeFinalTextPaintAdmission.Footprint,
                           after: NativeFinalTextPaintAdmission.Footprint,
                           maximumAllowedDecreasePixels: Int = 1,
                           minimumChannelContrast: Int = 64) -> (allowed: Bool?, audit: [String:Any]) {
        var audit: [String:Any] = ["policy":"source-preserved-boundary-chebyshev-v1",
            "sourceIdentity":sourceIdentity,"contrastRange":minimumChannelContrast,"erasureDilationPixels":1,
            "closeDistancePixels":2,"maximumAllowedDecreasePixels":maximumAllowedDecreasePixels,"distanceSaturationPixels":4,
            "distanceMetric":"Chebyshev","physicalContainmentMeasured":false]
        func unknown(_ reason: String) -> (allowed: Bool?, audit: [String:Any]) {
            audit["status"] = reason; audit["evidenceAvailable"] = false
            return (nil,audit)
        }
        guard (0...1).contains(maximumAllowedDecreasePixels) else { return unknown("invalid-margin-loss-policy") }
        guard minimumChannelContrast == 32 || minimumChannelContrast == 64 else { return unknown("invalid-boundary-contrast-policy") }
        guard before.pixels > 0, before.pixels <= Self.maxBoundarySamples,
              before.pixels == after.pixels, before.runs.count == after.runs.count,
              before.runs.count <= 1_000_000,
              [before.bounds.minX,before.bounds.minY,after.bounds.minX,after.bounds.minY].allSatisfy(\.isFinite)
        else { return unknown("footprint-budget-or-unmatched") }
        let sx = after.bounds.minX-before.bounds.minX, sy = after.bounds.minY-before.bounds.minY
        guard sx == floor(sx), sy == floor(sy), abs(sx) <= 16_384, abs(sy) <= 16_384 else {
            return unknown("not-fixed-integral-translation")
        }
        let dx = Int(sx), dy = Int(sy)
        // Validate ALL corresponding runs before sampling or returning a veto.
        var samples = 0
        for (a,b) in zip(before.runs,after.runs) {
            guard a.left >= 0, a.right <= width, a.left < a.right, a.y >= 0, a.y < height,
                  b.left >= 0, b.right <= width, b.y >= 0, b.y < height,
                  b.left == a.left+dx, b.right == a.right+dx, b.y == a.y+dy else {
                return unknown("unmatched-or-clipped-support")
            }
            samples += a.right-a.left
            guard samples <= Self.maxBoundarySamples else { return unknown("sample-budget") }
        }
        guard samples == before.pixels else { return unknown("inconsistent-alpha-count") }
        if Task<Never,Never>.isCancelled { return unknown("cancelled") }
        lock.lock(); defer { lock.unlock() }
        guard boundarySamples <= 16_000_000-samples else { return unknown("context-sample-budget") }
        boundarySamples += samples
        var compared = 0, skipped = 0, adverse = 0, first: [Int]?
        for a in before.runs {
            if Task<Never,Never>.isCancelled { return unknown("cancelled") }
            for x in a.left..<a.right {
                let xx = x+dx, yy = a.y+dy
                guard let old = boundaryDistance(x:x,y:a.y,minimumChannelContrast:minimumChannelContrast),
                      let new = boundaryDistance(x:xx,y:yy,minimumChannelContrast:minimumChannelContrast) else {
                    if adverse > 0 {
                        audit["status"] = "preserved-source-boundary-veto-partial-budget"
                        audit["evidenceAvailable"] = true; audit["observationComplete"] = false
                        audit["adverseAlphaPixels"] = adverse
                        audit["firstAdverseOldNewXYDistance"] = first as Any? ?? NSNull()
                        return (false,audit)
                    }
                    return unknown("boundary-cache-or-work-budget")
                }
                // 255 means no complete original 3x3 observation (image edge).
                if old == 255 || new == 255 { skipped += 1; continue }
                compared += 1
                if new <= 2 && Int(old)-Int(new) > maximumAllowedDecreasePixels {
                    adverse += 1
                    if first == nil { first = [x,a.y,xx,yy,Int(old),Int(new)] }
                }
            }
        }
        audit["comparedAlphaPixels"] = compared; audit["unobservedAlphaPixels"] = skipped
        audit["adverseAlphaPixels"] = adverse; audit["firstAdverseOldNewXYDistance"] = first as Any? ?? NSNull()
        audit["evidenceAvailable"] = compared > 0
        audit["observationComplete"] = skipped == 0
        audit["status"] = adverse > 0 ? "preserved-source-boundary-veto" :
            (skipped == 0 ? "no-local-boundary-regression" : "partial-source-observation")
        // A measured violation remains decisive with partially unknown support.
        return (adverse > 0 ? false : (compared > 0 && skipped == 0 ? true : nil),audit)
    }

    /// Shape-changing veto against an ORIGINAL immutable incumbent. The caller
    /// must keep the same incumbent/before pair across both reflow passes.
    /// Old alpha is exempt ONLY at its original page coordinates. Evidence and
    /// boundary caches remain source-only; no candidate creates hole permission.
    func shapeClearance(incumbent: Primitive, before: NativeFinalTextPaintAdmission.Footprint,
                        after: NativeFinalTextPaintAdmission.Footprint, page: CGRect,
                        minimumChannelContrast: Int = 64)
        -> (allowed: Bool?, audit: [String:Any]) {
        typealias N = NativeFinalTextPaintAdmission
        var audit: [String:Any] = ["policy":"frozen-incumbent-new-alpha-shape-clearance-v1",
            "sourceIdentity":sourceIdentity,"contrastRange":minimumChannelContrast,"erasureDilationPixels":1,
            "requiredNewAlphaBoundaryDistanceGreaterThan":2,"distanceMetric":"Chebyshev",
            "distanceSaturationPixels":4,"oldAlphaExemptionsFixedInPageCoordinates":true,
            "candidateHoleGrandfatheringPerformed":false,"universalPhysicalCertificate":false,
            "physicalContainmentMeasured":false,"componentEvidenceAvailable":false,
            "componentContainmentConditional":true,"maxNewSamplesPerCandidate":Self.maxBoundarySamples]
        func unknown(_ reason: String) -> (allowed: Bool?, audit: [String:Any]) {
            audit["status"] = reason; audit["observationComplete"] = false
            return (nil,audit)
        }
        func cancelled() -> Bool { Task<Never,Never>.isCancelled }
        guard !cancelled() else { return unknown("cancelled") }
        guard minimumChannelContrast == 32 || minimumChannelContrast == 64 else {
            return unknown("invalid-boundary-contrast-policy")
        }
        guard page == CGRect(x:0,y:0,width:width,height:height),
              let owner = incumbent.ownerID, !owner.isEmpty,
              incumbent.frame == incumbent.frame.integral, page.contains(incumbent.frame),
              incumbent.frame.width == CGFloat(incumbent.image.width),
              incumbent.frame.height == CGFloat(incumbent.image.height), incumbent.image.height > 0,
              incumbent.image.width > 0, incumbent.image.width <= Self.maxROI/incumbent.image.height,
              incumbent.fontOutputPixels.isFinite, incumbent.fontOutputPixels > 0 else {
            return unknown("invalid-incumbent-or-page")
        }
        audit["owner"] = owner
        func valid(_ support: N.Footprint) -> Bool {
            let b = support.bounds
            guard !b.isNull, !b.isEmpty, b == b.integral,
                  [b.minX,b.minY,b.width,b.height].allSatisfy(\.isFinite), page.contains(b),
                  support.pixels > 0, support.pixels <= Self.maxROI,
                  !support.runs.isEmpty, support.runs.count <= 250_000 else { return false }
            var count=0, previousY = -1, previousRight = -1
            var left=width, top=height, right=0, bottom=0
            for run in support.runs {
                guard run.y >= 0, run.y < height, run.left >= 0, run.left < run.right, run.right <= width,
                      run.y >= previousY, run.y != previousY || run.left >= previousRight else { return false }
                previousY=run.y; previousRight=run.right
                count += run.right-run.left; if count > Self.maxROI { return false }
                left=min(left,run.left);right=max(right,run.right);top=min(top,run.y);bottom=max(bottom,run.y+1)
            }
            return count == support.pixels && b == CGRect(x:left,y:top,width:right-left,height:bottom-top)
        }
        guard valid(before),valid(after) else { return unknown("invalid-footprint-runs-bounds-or-count") }
        guard let actual = try? N.retainedFootprint(incumbent), actual.bounds == before.bounds,
              actual.pixels == before.pixels, actual.runs.count == before.runs.count,
              zip(actual.runs,before.runs).allSatisfy({ $0.y == $1.y && $0.left == $1.left && $0.right == $1.right }) else {
            return unknown("before-does-not-match-original-incumbent")
        }
        audit["beforePixels"]=before.pixels; audit["afterPixels"]=after.pixels
        audit["beforeBounds"]=[before.bounds.minX,before.bounds.minY,before.bounds.width,before.bounds.height]
        audit["afterBounds"]=[after.bounds.minX,after.bounds.minY,after.bounds.width,after.bounds.height]
        var oldRows: [Int:[N.Run]] = [:]
        for run in before.runs { oldRows[run.y,default:[]].append(run) }
        var additions: [N.Run] = [], samples=0, subtractionWork=0
        for run in after.runs {
            if cancelled() { return unknown("cancelled") }
            var cursor=run.left
            for old in oldRows[run.y] ?? [] {
                subtractionWork += 1
                guard subtractionWork <= Self.maxWork else { return unknown("alpha-difference-work-budget") }
                if old.right <= cursor { continue }
                if old.left >= run.right { break }
                if cursor < old.left {
                    let end=min(run.right,old.left)
                    additions.append(.init(y:run.y,left:cursor,right:end));samples += end-cursor
                }
                cursor=max(cursor,old.right)
                if cursor >= run.right { break }
            }
            if cursor < run.right { additions.append(.init(y:run.y,left:cursor,right:run.right));samples += run.right-cursor }
            guard samples <= Self.maxBoundarySamples, additions.count <= 250_000 else { return unknown("new-alpha-sample-or-run-budget") }
        }
        audit["newAlphaPixels"]=samples; audit["originalAlphaPixelsExempt"]=after.pixels-samples
        audit["newAlphaRuns"]=additions.count
        if samples == 0 {
            audit["status"]="no-new-alpha-original-support-only";audit["componentEvidenceStatus"]="not-needed-no-new-alpha"
            audit["observationComplete"]=true;audit["newAlphaBoundaryObservationComplete"]=true
            audit["comparedNewAlphaPixels"]=0;audit["unobservedNewAlphaPixels"]=0
            return (true,audit)
        }
        // A known raw component vetoes NEW pixels outside it. This is exactly
        // raw | ORIGINAL-alpha at fixed page coordinates, without filling any
        // additional enclosed hole or granting an external-rim paint allowance.
        var knownComponent=false
        if let policy=incumbent.textExpansionPolicy, policy.valid, policy.insideBalloon,
           let guide=incumbent.textPlacementGuide, guide.valid,
           policy.maskRectNormalized != nil, policy.maskSpansNormalized != nil {
            let roi=NativeTextExpansionPolicy.rect(policy.maskRectNormalized!,page:page).integral.intersection(page)
            guard !roi.isNull,roi.width > 0,roi.height > 0,roi.width <= CGFloat(Self.maxROI)/roi.height,
                  let policyData=encoded(policy) else { return unknown("component-roi-or-policy-budget") }
            let source=guide.rect(in:page)
            let key=Key(owner:owner,source:[Double(source.minX),Double(source.minY),Double(source.width),Double(source.height)],policy:policyData)
            lock.lock()
            let cached=cache[key] != nil, pixels=Int(roi.width*roi.height)
            let budgetOK=cached || shapeEvidencePixels <= 32_000_000-pixels
            if !cached && budgetOK { shapeEvidencePixels += pixels }
            lock.unlock()
            guard budgetOK else { return unknown("component-context-roi-budget") }
            guard let evidence=evidence(owner:owner,source:source,policy:policy,page:page) else {
                return unknown("component-evidence-work-or-interval-budget")
            }
            audit["componentEvidenceStatus"]=evidence.status
            audit["componentEvidenceKind"]=evidence.kind
            if evidence.available {
                guard let mask=evidence.rawMask else { return unknown("available-component-missing-mask") }
                let w=Int(mask.rect.width),h=Int(mask.rect.height)
                let global=mask.rect
                guard w > 0,h > 0,w <= Self.maxROI/h,mask.bytes.count == w*h,
                      global == global.integral,page.contains(global) else { return unknown("invalid-raw-component") }
                knownComponent=true;audit["componentEvidenceAvailable"]=true
                audit["componentDomainPolicy"]="source-raw-union-original-alpha-fixed-page-coordinates"
                let ox=Int(global.minX),oy=Int(global.minY)
                var measured=0
                for run in additions {
                    if cancelled() { return unknown("cancelled") }
                    for x in run.left..<run.right {
                        measured += 1
                        let xx=x-ox,yy=run.y-oy
                        if xx < 0 || yy < 0 || xx >= w || yy >= h || mask.bytes[yy*w+xx] == 0 {
                            audit["status"]="known-component-new-alpha-veto"
                            audit["firstNewAlphaOutsideRawXY"]=[x,run.y]
                            audit["componentComparedNewAlphaPixels"]=measured
                            audit["newAlphaOutsideKnownRawPixelsAtLeast"]=1
                            audit["componentObservationComplete"]=measured == samples
                            audit["observationComplete"]=false
                            return (false,audit)
                        }
                    }
                }
                audit["componentComparedNewAlphaPixels"]=measured;audit["componentObservationComplete"]=true
                audit["newAlphaOutsideKnownRawPixels"]=0
            }
        } else { audit["componentEvidenceStatus"]="unavailable-no-usable-original-component-policy" }
        // Unknown COMPONENT evidence is not a pass/certificate. It may still
        // pass this source-preserved-boundary veto, with that distinction explicit.
        guard !cancelled() else { return unknown("cancelled") }
        lock.lock(); defer { lock.unlock() }
        guard boundarySamples <= 16_000_000-samples else { return unknown("context-new-alpha-sample-budget") }
        boundarySamples += samples
        audit["sharedBoundarySamplesReserved"]=boundarySamples
        var compared=0,unobserved=0,adverse=0,first:[Int]?
        for run in additions {
            if cancelled() {
                if adverse > 0 { break }
                return unknown("cancelled")
            }
            for x in run.left..<run.right {
                guard let distance=boundaryDistance(x:x,y:run.y,minimumChannelContrast:minimumChannelContrast), distance != 255 else { unobserved += 1; continue }
                compared += 1
                if distance <= 2 {
                    adverse += 1
                    if first == nil { first=[x,run.y,Int(distance)] }
                }
            }
        }
        audit["comparedNewAlphaPixels"]=compared;audit["unobservedNewAlphaPixels"]=unobserved
        audit["adverseNewAlphaPixels"]=adverse;audit["firstAdverseNewAlphaXYDistance"]=first as Any? ?? NSNull()
        let complete=compared == samples && unobserved == 0
        audit["observationComplete"]=complete;audit["newAlphaBoundaryObservationComplete"]=complete
        if adverse > 0 { audit["status"]="new-alpha-preserved-source-boundary-veto";return (false,audit) }
        guard complete else { return unknown("new-alpha-boundary-observation-or-cache-budget") }
        audit["physicalContainmentMeasured"]=knownComponent
        audit["status"]=knownComponent ? "conditional-component-and-new-alpha-boundary-clearance" : "new-alpha-boundary-clearance-component-uncertified"
        return (true,audit)
    }

    /// Quality-only prefix accounting; legacy shape gate remains unchanged.
    func qualityShapeClearance(incumbent: Primitive, before: NativeFinalTextPaintAdmission.Footprint,
                        after: NativeFinalTextPaintAdmission.Footprint, page: CGRect,
                        minimumChannelContrast: Int = 64)
        -> (allowed: Bool?, audit: [String:Any]) {
        typealias N = NativeFinalTextPaintAdmission
        var audit: [String:Any] = ["policy":"frozen-incumbent-new-alpha-shape-clearance-v1",
            "sourceIdentity":sourceIdentity,"contrastRange":minimumChannelContrast,"erasureDilationPixels":1,
            "requiredNewAlphaBoundaryDistanceGreaterThan":2,"distanceMetric":"Chebyshev",
            "distanceSaturationPixels":4,"oldAlphaExemptionsFixedInPageCoordinates":true,
            "candidateHoleGrandfatheringPerformed":false,"universalPhysicalCertificate":false,
            "physicalContainmentMeasured":false,"componentEvidenceAvailable":false,
            "componentContainmentConditional":true,"maxNewSamplesPerCandidate":Self.maxBoundarySamples]
        func unknown(_ reason: String) -> (allowed: Bool?, audit: [String:Any]) {
            audit["status"] = reason; audit["observationComplete"] = false
            return (nil,audit)
        }
        func cancelled() -> Bool { Task<Never,Never>.isCancelled }
        guard !cancelled() else { return unknown("cancelled") }
        guard minimumChannelContrast == 32 || minimumChannelContrast == 64 else {
            return unknown("invalid-boundary-contrast-policy")
        }
        guard page == CGRect(x:0,y:0,width:width,height:height),
              let owner = incumbent.ownerID, !owner.isEmpty,
              incumbent.frame == incumbent.frame.integral, page.contains(incumbent.frame),
              incumbent.frame.width == CGFloat(incumbent.image.width),
              incumbent.frame.height == CGFloat(incumbent.image.height), incumbent.image.height > 0,
              incumbent.image.width > 0, incumbent.image.width <= Self.maxROI/incumbent.image.height,
              incumbent.fontOutputPixels.isFinite, incumbent.fontOutputPixels > 0 else {
            return unknown("invalid-incumbent-or-page")
        }
        audit["owner"] = owner
        func valid(_ support: N.Footprint) -> Bool {
            let b = support.bounds
            guard !b.isNull, !b.isEmpty, b == b.integral,
                  [b.minX,b.minY,b.width,b.height].allSatisfy(\.isFinite), page.contains(b),
                  support.pixels > 0, support.pixels <= Self.maxROI,
                  !support.runs.isEmpty, support.runs.count <= 250_000 else { return false }
            var count=0, previousY = -1, previousRight = -1
            var left=width, top=height, right=0, bottom=0
            for run in support.runs {
                guard run.y >= 0, run.y < height, run.left >= 0, run.left < run.right, run.right <= width,
                      run.y >= previousY, run.y != previousY || run.left >= previousRight else { return false }
                previousY=run.y; previousRight=run.right
                count += run.right-run.left; if count > Self.maxROI { return false }
                left=min(left,run.left);right=max(right,run.right);top=min(top,run.y);bottom=max(bottom,run.y+1)
            }
            return count == support.pixels && b == CGRect(x:left,y:top,width:right-left,height:bottom-top)
        }
        guard valid(before),valid(after) else { return unknown("invalid-footprint-runs-bounds-or-count") }
        guard let actual = try? N.retainedFootprint(incumbent), actual.bounds == before.bounds,
              actual.pixels == before.pixels, actual.runs.count == before.runs.count,
              zip(actual.runs,before.runs).allSatisfy({ $0.y == $1.y && $0.left == $1.left && $0.right == $1.right }) else {
            return unknown("before-does-not-match-original-incumbent")
        }
        audit["beforePixels"]=before.pixels; audit["afterPixels"]=after.pixels
        audit["beforeBounds"]=[before.bounds.minX,before.bounds.minY,before.bounds.width,before.bounds.height]
        audit["afterBounds"]=[after.bounds.minX,after.bounds.minY,after.bounds.width,after.bounds.height]
        var oldRows: [Int:[N.Run]] = [:]
        for run in before.runs { oldRows[run.y,default:[]].append(run) }
        var additions: [N.Run] = [], samples=0, subtractionWork=0
        for run in after.runs {
            if cancelled() { return unknown("cancelled") }
            var cursor=run.left
            for old in oldRows[run.y] ?? [] {
                subtractionWork += 1
                guard subtractionWork <= Self.maxWork else { return unknown("alpha-difference-work-budget") }
                if old.right <= cursor { continue }
                if old.left >= run.right { break }
                if cursor < old.left {
                    let end=min(run.right,old.left)
                    additions.append(.init(y:run.y,left:cursor,right:end));samples += end-cursor
                }
                cursor=max(cursor,old.right)
                if cursor >= run.right { break }
            }
            if cursor < run.right { additions.append(.init(y:run.y,left:cursor,right:run.right));samples += run.right-cursor }
            guard samples <= Self.maxBoundarySamples, additions.count <= 250_000 else { return unknown("new-alpha-sample-or-run-budget") }
        }
        audit["newAlphaPixels"]=samples; audit["originalAlphaPixelsExempt"]=after.pixels-samples
        audit["newAlphaRuns"]=additions.count
        if samples == 0 {
            audit["status"]="no-new-alpha-original-support-only";audit["componentEvidenceStatus"]="not-needed-no-new-alpha"
            audit["observationComplete"]=true;audit["newAlphaBoundaryObservationComplete"]=true
            audit["comparedNewAlphaPixels"]=0;audit["unobservedNewAlphaPixels"]=0
            return (true,audit)
        }
        // A known raw component vetoes NEW pixels outside it. This is exactly
        // raw | ORIGINAL-alpha at fixed page coordinates, without filling any
        // additional enclosed hole or granting an external-rim paint allowance.
        var knownComponent=false
        if let policy=incumbent.textExpansionPolicy, policy.valid, policy.insideBalloon,
           let guide=incumbent.textPlacementGuide, guide.valid,
           policy.maskRectNormalized != nil, policy.maskSpansNormalized != nil {
            let roi=NativeTextExpansionPolicy.rect(policy.maskRectNormalized!,page:page).integral.intersection(page)
            guard !roi.isNull,roi.width > 0,roi.height > 0,roi.width <= CGFloat(Self.maxROI)/roi.height,
                  let policyData=encoded(policy) else { return unknown("component-roi-or-policy-budget") }
            let source=guide.rect(in:page)
            let key=Key(owner:owner,source:[Double(source.minX),Double(source.minY),Double(source.width),Double(source.height)],policy:policyData)
            lock.lock()
            let cached=cache[key] != nil, pixels=Int(roi.width*roi.height)
            let budgetOK=cached || shapeEvidencePixels <= 32_000_000-pixels
            if !cached && budgetOK { shapeEvidencePixels += pixels }
            lock.unlock()
            guard budgetOK else { return unknown("component-context-roi-budget") }
            guard let evidence=evidence(owner:owner,source:source,policy:policy,page:page) else {
                return unknown("component-evidence-work-or-interval-budget")
            }
            audit["componentEvidenceStatus"]=evidence.status
            audit["componentEvidenceKind"]=evidence.kind
            if evidence.available {
                guard let mask=evidence.rawMask else { return unknown("available-component-missing-mask") }
                let w=Int(mask.rect.width),h=Int(mask.rect.height)
                let global=mask.rect
                guard w > 0,h > 0,w <= Self.maxROI/h,mask.bytes.count == w*h,
                      global == global.integral,page.contains(global) else { return unknown("invalid-raw-component") }
                knownComponent=true;audit["componentEvidenceAvailable"]=true
                audit["componentDomainPolicy"]="source-raw-union-original-alpha-fixed-page-coordinates"
                let ox=Int(global.minX),oy=Int(global.minY)
                var measured=0
                for run in additions {
                    if cancelled() { return unknown("cancelled") }
                    for x in run.left..<run.right {
                        measured += 1
                        let xx=x-ox,yy=run.y-oy
                        if xx < 0 || yy < 0 || xx >= w || yy >= h || mask.bytes[yy*w+xx] == 0 {
                            audit["status"]="known-component-new-alpha-veto"
                            audit["firstNewAlphaOutsideRawXY"]=[x,run.y]
                            audit["componentComparedNewAlphaPixels"]=measured
                            audit["newAlphaOutsideKnownRawPixelsAtLeast"]=1
                            audit["componentObservationComplete"]=measured == samples
                            audit["observationComplete"]=false
                            return (false,audit)
                        }
                    }
                }
                audit["componentComparedNewAlphaPixels"]=measured;audit["componentObservationComplete"]=true
                audit["newAlphaOutsideKnownRawPixels"]=0
            }
        } else { audit["componentEvidenceStatus"]="unavailable-no-usable-original-component-policy" }
        // Unknown COMPONENT evidence is not a pass/certificate. It may still
        // pass this source-preserved-boundary veto, with that distinction explicit.
        guard !cancelled() else { return unknown("cancelled") }
        lock.lock(); defer { lock.unlock() }
        // Source classification is charged once per immutable (contrast,tile,XY),
        // not once per candidate alpha visit. Source builder work remains <=8M;
        // interval rank queries have a separate cumulative <=2M work bound.
        var compared=0,unobserved=0,adverse=0,first:[Int]?
        var intervalBudget=false,cacheUnavailable=false
        let queryStart=shapeIntervalQueries,classifiedStart=sourceClassifiedPixels
        for run in additions {
            if cancelled() {if adverse>0 {break};return unknown("cancelled")}
            var left=run.left
            while left<run.right {
                let end=min(run.right,(left/64+1)*64),length=end-left
                guard shapeIntervalQueries<2_000_000 else {intervalBudget=true;unobserved+=length;left=end;continue}
                shapeIntervalQueries+=1
                if let tile=boundaryTile(tx:left/64,ty:run.y/64,minimumChannelContrast:minimumChannelContrast) {
                    let counts=tile.counts(y:run.y%64,left:left%64,right:(end-1)%64+1)
                    compared+=length-counts.unknown;unobserved+=counts.unknown;adverse+=counts.near
                    if first==nil,let x=counts.firstNear {first=[(left/64)*64+x,run.y,Int(tile.distance((run.y%64)*64+x))]}
                } else {cacheUnavailable=true;unobserved+=length}
                left=end
            }
        }
        if cancelled() {unobserved=samples-compared}
        audit["sourceClassificationAccounting"]="unique immutable contrast/tile/sourceXY classifications; source builder ROI/halo work separately bounded"
        audit["newUniqueSourceClassifications"]=sourceClassifiedPixels-classifiedStart
        audit["sharedUniqueSourceClassifications"]=sourceClassifiedPixels
        audit["shapeIntervalQueries"]=shapeIntervalQueries-queryStart
        audit["sharedShapeIntervalQueries"]=shapeIntervalQueries
        audit["shapeIntervalQueryLimit"]=2_000_000
        audit["prefixIntervalBudgetExceeded"]=intervalBudget
        audit["prefixTileCacheOrWorkUnavailable"]=cacheUnavailable
        audit["sourceTileCount"]=boundaryTiles.count
        audit["sourceTileLimit"]=Self.maxBoundaryTiles
        audit["sourceBuilderROIPixelWork"]=boundaryWork
        audit["sourceBuilderROIPixelWorkLimit"]=Self.maxBoundaryWork
        audit["sourceTilePayloadBytes"]=boundaryTiles.count*3072
        audit["originalSourceTilePayloadByteLimit"]=Self.maxBoundaryTiles*4096
        audit["legacyTranslationAlphaQuerySamples"]=boundarySamples
        // Exact scalar oracle over the SAME source-only cache. It has its OWN
        // explicitly bounded diagnostic work and does not charge production work.
        let passing=adverse==0 && unobserved==0
        let referenceEnabled=ProcessInfo.processInfo.environment["AIDOKU_SOURCE_PREFIX_REFERENCE"] == "1"
        let sample=prefixReferenceEarly<24 || (passing && prefixReferencePassing<8)
        if referenceEnabled,sample,!cacheUnavailable,!intervalBudget,prefixReferencePixels<=16_000_000-samples {
            var rc=0,ru=0,ra=0,rf:[Int]?
            for run in additions {for x in run.left..<run.right {
                guard let d=boundaryDistance(x:x,y:run.y,minimumChannelContrast:minimumChannelContrast),d != 255 else{ru+=1;continue}
                rc+=1;if d<=2 {ra+=1;if rf==nil {rf=[x,run.y,Int(d)]}}
            }}
            let equal=rc==compared && ru==unobserved && ra==adverse && rf==first
            precondition(equal,"prefix/scalar actual-support mismatch")
            prefixParityChecks+=1;prefixReferencePixels+=samples
            if prefixReferenceEarly<24 {prefixReferenceEarly+=1}else{prefixReferencePassing+=1}
            audit["perPixelReferenceCompared"]=true;audit["perPixelReferenceExact"]=equal
            audit["perPixelReferenceComparedPixels"]=samples
        } else {audit["perPixelReferenceCompared"]=false}
        audit["referenceDiagnosticPixelsCumulative"]=prefixReferencePixels
        audit["referenceParityChecksCumulative"]=prefixParityChecks
        audit["comparedNewAlphaPixels"]=compared;audit["unobservedNewAlphaPixels"]=unobserved
        audit["adverseNewAlphaPixels"]=adverse;audit["firstAdverseNewAlphaXYDistance"]=first as Any? ?? NSNull()
        let complete=compared == samples && unobserved == 0
        audit["observationComplete"]=complete;audit["newAlphaBoundaryObservationComplete"]=complete
        if adverse > 0 { audit["status"]="new-alpha-preserved-source-boundary-veto";return (false,audit) }
        guard complete else { return unknown("new-alpha-boundary-observation-or-cache-budget") }
        audit["physicalContainmentMeasured"]=knownComponent
        audit["status"]=knownComponent ? "conditional-component-and-new-alpha-boundary-clearance" : "new-alpha-boundary-clearance-component-uncertified"
        return (true,audit)
    }

    /// Absolute measured source-boundary exposure of an actual retained support.
    /// Quality metric only: does not declare a physical interior or edit a mask.
    func obstructionExposure(_ support:NativeFinalTextPaintAdmission.Footprint,page:CGRect)->(pixels:Int?,audit:[String:Any]) {
        var a:[String:Any]=["sourceIdentity":sourceIdentity,"policy":"actual-retained-source-exposure-contrast32-near2-v1",
            "physicalContainmentCertified":false,"contrast":32,"nearDistance":2]
        guard page==CGRect(x:0,y:0,width:width,height:height),support.pixels>0,support.pixels<=2_000_000,
            support.runs.count<=250_000,page.contains(support.bounds) else{return(nil,a)}
        lock.lock();defer{lock.unlock()}
        var count=0,near=0,unknown=0,previousY = -1,previousRight = -1
        for run in support.runs {
            guard run.y>=0,run.y<height,run.left>=0,run.right<=width,run.left<run.right,
                run.y>=previousY,(run.y != previousY || run.left>=previousRight),!Task<Never,Never>.isCancelled else{return(nil,a)}
            previousY=run.y;previousRight=run.right;count+=run.right-run.left
            var left=run.left
            while left<run.right {
                guard shapeIntervalQueries<2_000_000 else{a["reason"]="interval-budget";return(nil,a)}
                shapeIntervalQueries+=1;let end=min(run.right,(left/64+1)*64)
                guard let tile=boundaryTile(tx:left/64,ty:run.y/64,minimumChannelContrast:32)else{a["reason"]="source-cache-budget";return(nil,a)}
                let q=tile.counts(y:run.y%64,left:left%64,right:(end-1)%64+1)
                near+=q.near;unknown+=q.unknown;left=end
            }
        }
        a["nearBoundaryAlphaPixels"]=near;a["unknownPixels"]=unknown;a["observedPixels"]=count
        a["sourceClassifiedPixels"]=sourceClassifiedPixels;a["intervalQueries"]=shapeIntervalQueries
        guard count==support.pixels,unknown==0 else{return(nil,a)}
        a["observationComplete"]=true;return(near,a)
    }

    /// Fixed-glyph paint counterpart of translation-only boundaryClearance.
    /// Does NOT pretend different stroke masks are corresponding translated runs.
    /// Original/shared alpha stays at fixed coordinates (zero margin loss there).
    /// Every NEW alpha pixel must be >2px from preserved ORIGINAL contrast32
    /// edges, a stricter new-contact veto than grandfathering an inherited rim.
    /// Known raw component restrictions and all observation/work budgets remain.
    func paintBoundaryClearance(incumbent: Primitive,
        before: NativeFinalTextPaintAdmission.Footprint, after: NativeFinalTextPaintAdmission.Footprint,
        page: CGRect) -> (allowed: Bool?, audit: [String:Any]) {
        let result = shapeClearance(incumbent:incumbent,before:before,after:after,page:page,
            minimumChannelContrast:32)
        var audit = result.audit
        audit["underlyingPolicy"] = audit["policy"]
        audit["policy"] = "fixed-glyph-stroke-original-new-alpha-boundary-v1"
        audit["translationCorrespondenceClaimed"] = false
        audit["sharedOriginalAlphaFixedAtPageCoordinates"] = true
        audit["maximumAllowedDecreasePixels"] = 0
        audit["marginLossScope"] = "shared original alpha fixed; added alpha rejects all preserved edges at distance<=2"
        return (result.allowed,audit)
    }

    /// Caller holds lock. Source edge = any channel range>=64 in a 3x3
    /// neighborhood, unless ANY pixel in the same 3x3 has effective erasure.
    func boundaryDistance(x: Int, y: Int, minimumChannelContrast: Int = 64) -> UInt8? {
        if x < 1 || y < 1 || x >= width-1 || y >= height-1 { return 255 }
        let side=Self.boundaryTileSide
        return boundaryTile(tx:x/side,ty:y/side,minimumChannelContrast:minimumChannelContrast)?.distance((y%side)*side+x%side)
    }
    private func boundaryTile(tx:Int,ty:Int,minimumChannelContrast:Int)->BoundaryTile? {
        let side=Self.boundaryTileSide,columns=(width+side-1)/side
        let key=(ty*columns+tx)*2+(minimumChannelContrast==32 ? 1:0)
        if let hit=boundaryTiles[key] {return hit}
        guard boundaryTiles.count < Self.maxBoundaryTiles else { return nil }
        let ox = tx*side, oy = ty*side
        let left = max(0,ox-4), top = max(0,oy-4)
        let right = min(width,ox+side+4), bottom = min(height,oy+side+4)
        let w = right-left, h = bottom-top
        guard w > 0, h > 0, boundaryWork <= Self.maxBoundaryWork-w*h else { return nil }
        boundaryWork += w*h
        var distance = [UInt8](repeating:4,count:w*h)
        for yy in 0..<h {
            if Task<Never,Never>.isCancelled { return nil }
            let py = top+yy
            for xx in 0..<w {
                let px = left+xx
                if px < 1 || py < 1 || px >= width-1 || py >= height-1 { continue }
                var excluded = false
                var lo0 = 255, lo1 = 255, lo2 = 255, hi0 = 0, hi1 = 0, hi2 = 0
                for v in py-1...py+1 { for u in px-1...px+1 {
                    let p = v*width+u
                    if erased[p] != 0 { excluded = true }
                    let a = Int(rgb[p*3]), b = Int(rgb[p*3+1]), c = Int(rgb[p*3+2])
                    lo0 = min(lo0,a); lo1 = min(lo1,b); lo2 = min(lo2,c)
                    hi0 = max(hi0,a); hi1 = max(hi1,b); hi2 = max(hi2,c)
                }}
                if !excluded && max(hi0-lo0,max(hi1-lo1,hi2-lo2)) >= minimumChannelContrast {
                    distance[yy*w+xx] = 0
                }
            }
        }
        // L-infinity dilation: min in each 3x3, four iterations.
        // Padding four source pixels makes tile samples exact through radius4.
        for _ in 0..<4 {
            if Task<Never,Never>.isCancelled { return nil }
            var next = distance
            for yy in 0..<h { for xx in 0..<w {
                var value = distance[yy*w+xx]
                for v in max(0,yy-1)...min(h-1,yy+1) { for u in max(0,xx-1)...min(w-1,xx+1) {
                    value = min(value,min(4,distance[v*w+u]+1))
                }}
                next[yy*w+xx] = value
            }}
            distance = next
        }
        var tile = [UInt8](repeating:255,count:side*side)
        for yy in oy..<min(height,oy+side) { for xx in ox..<min(width,ox+side) {
            if xx > 0 && yy > 0 && xx < width-1 && yy < height-1 {
                tile[(yy-oy)*side+xx-ox] = distance[(yy-top)*w+xx-left]
            }
        }}
        let uniquePixels=(min(width,ox+side)-ox)*(min(height,oy+side)-oy)
        guard sourceClassifiedPixels<=16_000_000-uniquePixels,let certified=BoundaryTile(distances:tile) else{return nil}
        sourceClassifiedPixels+=uniquePixels
        boundaryTiles[key]=certified
        return certified
    }

    private struct Span { let lo: Int; let hi: Int } // exclusive upper for mask rows
    private final class Domain {
        let rect: CGRect
        let rows: [[Span]], insetRows: [[Span]]
        let cost: Int
        init?(mask: NativeSourcePixelInterior.Mask, offset: CGPoint) {
            let w = Int(mask.rect.width), h = Int(mask.rect.height)
            guard w > 0, h > 0, w <= NativeSourcePhysicalInteriorContext.maxROI / h,
                  mask.bytes.count == w*h else { return nil }
            rect = mask.rect.offsetBy(dx: offset.x, dy: offset.y)
            let ox = Int(rect.minX)
            var plain = [[Span]](repeating: [], count: h), inset = plain, count = 0
            for y in 0..<h {
                for erode in [false, true] {
                    var start: Int?
                    for x in 0...w {
                        var good = x < w && mask.bytes[y*w+x] != 0
                        if good && erode {
                            good = x > 0 && x < w-1 && y > 0 && y < h-1
                            if good {
                                for yy in y-1...y+1 { for xx in x-1...x+1 where mask.bytes[yy*w+xx] == 0 { good = false }}
                            }
                        }
                        if good && start == nil { start = x }
                        if !good, let left = start {
                            let span = Span(lo: ox+left, hi: ox+x)
                            if erode { inset[y].append(span) } else { plain[y].append(span) }
                            count += 1; start = nil
                            guard count <= NativeSourcePhysicalInteriorContext.maxIntervals else { return nil }
                        }
                    }
                }
            }
            rows = plain; insetRows = inset; cost = count * 16 + h * 48
        }
        func row(_ y: Int, inset: Bool = false) -> [Span] {
            let i = y - Int(rect.minY)
            guard i >= 0, i < rows.count else { return [] }
            return inset ? insetRows[i] : rows[i]
        }
        func allows(_ box: CGRect, inset: Bool = false) -> Bool {
            guard !box.isNull, !box.isEmpty,
                  [box.minX,box.minY,box.maxX,box.maxY].allSatisfy(\.isFinite), rect.contains(box) else { return false }
            let x0 = Int(floor(box.minX)), x1 = Int(ceil(box.maxX))
            let y0 = Int(floor(box.minY)), y1 = Int(ceil(box.maxY))
            return y0 < y1 && (y0..<y1).allSatisfy { y in row(y,inset:inset).contains { $0.lo <= x0 && $0.hi >= x1 } }
        }
        func outside(_ support: NativeFinalTextPaintAdmission.Footprint, inset: Bool = false) -> Int {
            var outside = 0
            for run in support.runs {
                let covered = row(run.y,inset:inset).reduce(0) { $0 + max(0,min(run.right,$1.hi)-max(run.left,$1.lo)) }
                outside += run.right - run.left - covered
            }
            return outside
        }
    }

    private func encoded(_ policy: NativeTextExpansionPolicy) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(policy)
    }

    private func evidence(owner: String, source: CGRect, policy: NativeTextExpansionPolicy, page: CGRect) -> Evidence? {
        guard policy.valid, let raw = policy.maskRectNormalized, let spans = policy.maskSpansNormalized,
              let data = encoded(policy), data.count <= 2_000_000 else { return nil }
        let key = Key(owner: owner, source: [Double(source.minX),Double(source.minY),Double(source.width),Double(source.height)], policy: data)
        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit { return hit }
        let maskRect = NativeTextExpansionPolicy.rect(raw,page:page)
        let crop = maskRect.integral.intersection(page)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return nil }
        let x0 = Int(crop.minX), y0 = Int(crop.minY), w = Int(crop.width), h = Int(crop.height)
        guard w <= Self.maxROI/h else { return nil }
        var predicted = [UInt8](repeating:0,count:w*h)
        let n = spans.count/2, step = maskRect.height/CGFloat(n)
        guard step.isFinite, step > 0 else { return nil }
        var work = 0
        // Conservative original-pixel raster: a pixel must be wholly inside
        // every normalized band it touches. Never enlarge disjoint intervals.
        let firstY = max(y0,Int(ceil(maskRect.minY))), endY = min(y0+h,Int(floor(maskRect.maxY)))
        guard firstY < endY else { return nil }
        for y in firstY..<endY {
            let first = max(0,Int(floor((CGFloat(y)-maskRect.minY)/step)))
            let last = min(n-1,Int(ceil((CGFloat(y+1)-maskRect.minY)/step))-1)
            guard first <= last else { continue }
            var allowed = [Span(lo:max(x0,Int(ceil(maskRect.minX))),hi:min(x0+w,Int(floor(maskRect.maxX))))]
            for band in first...last {
                let values = policy.maskIntervals(row:band)
                var next: [Span] = []
                for current in allowed {
                    for k in stride(from:0,to:values.count,by:2) {
                        work += 1; guard work <= Self.maxWork else { return nil }
                        let a = max(current.lo,Int(ceil(values[k]*Double(width))))
                        let b = min(current.hi,Int(floor(values[k+1]*Double(width))))
                        if a < b { next.append(Span(lo:a,hi:b)) }
                    }
                }
                allowed = next
                if allowed.isEmpty { break }
            }
            for span in allowed { for x in span.lo..<span.hi { predicted[(y-y0)*w+x-x0] = 1 } }
        }
        var localRGB = [UInt8](), localErased = [UInt8]()
        localRGB.reserveCapacity(w*h*3); localErased.reserveCapacity(w*h)
        for y in y0..<y0+h {
            localRGB.append(contentsOf:rgb[(y*width+x0)*3..<(y*width+x0+w)*3])
            localErased.append(contentsOf:erased[y*width+x0..<y*width+x0+w])
        }
        let report = NativeSourcePixelInterior.make(rgb:localRGB,width:w,height:h,predicted:predicted,
            erased:localErased,source:source.offsetBy(dx:-crop.minX,dy:-crop.minY))
        // Cache only outer-containment evidence. It is NOT a paint domain:
        // per-incumbent static hole allowances are built later from actual alpha.
        // The source report stays raw and parity-stable.
        var rawMask = report.mask.map { NativeSourcePixelInterior.Mask(
            rect:$0.rect.offsetBy(dx:crop.minX,dy:crop.minY),bytes:$0.bytes) }
        var domain = report.available ? rawMask.flatMap(NativeSourcePixelInterior.outerEnvelope)
            .flatMap { Domain(mask:$0,offset:.zero) } : nil
        var barrier: NativeSourceClosedBarrierInterior.Report?
        if !report.available, Self.closedBarrierEnabled, sourceOpaque {
            let padding = max(min(source.width,source.height),min(maskRect.width,maskRect.height)*0.15)
            let roi = maskRect.insetBy(dx:-padding,dy:-padding).integral.intersection(page)
            if !roi.isNull, roi.width > 0, roi.height > 0, roi.width <= 4_000_000/roi.height,
               roi.contains(source) {
                let bx=Int(roi.minX),by=Int(roi.minY),bw=Int(roi.width),bh=Int(roi.height)
                var pixels=[UInt8](), associated=[UInt8](repeating:0,count:bw*bh)
                pixels.reserveCapacity(bw*bh*3)
                for y in by..<by+bh {
                    pixels.append(contentsOf:rgb[(y*width+bx)*3..<(y*width+bx+bw)*3])
                }
                for y in y0..<y0+h {
                    for x in x0..<x0+w where predicted[(y-y0)*w+x-x0] != 0 {
                        associated[(y-by)*bw+x-bx]=1
                    }
                }
                let closed=NativeSourceClosedBarrierInterior.make(rgb:pixels,width:bw,height:bh,
                    predicted:associated,source:source.offsetBy(dx:-roi.minX,dy:-roi.minY),
                    sourceOpaque:sourceOpaque,isCancelled:{ Task<Never,Never>.isCancelled })
                barrier=closed
                if closed.available, let mask=closed.mask {
                    rawMask = .init(rect:mask.rect.offsetBy(dx:roi.minX,dy:roi.minY),bytes:mask.bytes)
                    domain = rawMask.flatMap { Domain(mask:$0,offset:.zero) }
                }
            }
        }
        let result = Evidence(report:report,domain:domain,rawMask:rawMask,barrier:barrier)
        let cost = (report.mask?.bytes.count ?? 0) + (barrier?.mask?.bytes.count ?? 0) + (domain?.cost ?? 0) + data.count
        lock.lock()
        if cache.count < 128, cost <= 32_000_000-cachedBytes, cache[key] == nil {
            cache[key] = result; cachedBytes += cost
        }
        lock.unlock()
        return result
    }

    /// Raw domain plus only closed-hole page pixels already covered by this
    /// incumbent's actual effect alpha. Never translate these allowances with
    /// a proposal or cache them as owner/source evidence.
    private func occlusionDomain(raw: NativeSourcePixelInterior.Mask, outer: Domain,
                                 incumbent: NativeFinalTextPaintAdmission.Footprint) -> (Domain, Int)? {
        let w = Int(outer.rect.width), h = Int(outer.rect.height)
        guard w > 0, h > 0, w <= Self.maxROI/h, raw.bytes.count == w*h else { return nil }
        var bytes = raw.bytes, added = 0, work = 0
        let ox = Int(outer.rect.minX), oy = Int(outer.rect.minY)
        for run in incumbent.runs {
            let y = run.y-oy
            guard y >= 0, y < h else { continue }
            for span in outer.row(run.y) {
                work += 1; guard work <= Self.maxWork else { return nil }
                let left = max(run.left,span.lo), right = min(run.right,span.hi)
                if left < right {
                    for x in left..<right {
                        let p = y*w+x-ox
                        if bytes[p] == 0 { bytes[p] = 1; added += 1 }
                    }
                }
            }
        }
        guard let domain = Domain(mask:.init(rect:outer.rect,bytes:bytes),offset:.zero) else { return nil }
        return (domain,added)
    }

    private struct Shift: Hashable { let x: Int; let y: Int }
    private func proposals(_ support: NativeFinalTextPaintAdmission.Footprint, domain: Domain,
                           inset: Bool, radius: Int, source: CGRect,
                           locked: NativeSourceClusterAlignment.Axis?) -> [Shift]? {
        var all: [Shift] = [], seen = Set<Shift>(), work = 0
        let desired = Int((source.midX-support.bounds.midX).rounded())
        for dy in -radius...radius {
            if locked == .top && dy != 0 { continue }
            let extent = Int(sqrt(Double(radius*radius-dy*dy)).rounded(.down))
            var feasible = [Span(lo:-extent,hi:extent)] // inclusive for shifts
            for run in support.runs {
                let row = domain.row(run.y+dy,inset:inset)
                var next: [Span] = []
                for a in feasible { for b in row {
                    work += 1; guard work <= Self.maxWork else { return nil }
                    let lo = max(a.lo,b.lo-run.left), hi = min(a.hi,b.hi-run.right)
                    if lo <= hi { next.append(Span(lo:lo,hi:hi)) }
                    guard next.count <= 4096 else { return nil }
                }}
                var merged: [Span] = []
                for span in next.sorted(by: { $0.lo < $1.lo }) {
                    if let last = merged.last, span.lo <= last.hi+1 {
                        merged[merged.count-1] = Span(lo:last.lo,hi:max(last.hi,span.hi))
                    } else { merged.append(span) }
                }
                feasible = merged
                if feasible.isEmpty { break }
            }
            for interval in feasible {
                for dx in [min(interval.hi,max(interval.lo,0)), min(interval.hi,max(interval.lo,desired)), interval.lo, interval.hi] {
                    if locked == .left && dx != 0 { continue }
                    let shift = Shift(x:dx,y:dy)
                    if shift != Shift(x:0,y:0), seen.insert(shift).inserted { all.append(shift) }
                    guard all.count <= 32_768 else { return nil }
                }
            }
        }
        all.sort {
            let a = $0.x*$0.x+$0.y*$0.y, b = $1.x*$1.x+$1.y*$1.y
            if a != b { return a < b }
            let ad = pow(Double(support.bounds.midX-source.midX)+Double($0.x),2) + pow(Double(support.bounds.midY-source.midY)+Double($0.y),2)
            let bd = pow(Double(support.bounds.midX-source.midX)+Double($1.x),2) + pow(Double(support.bounds.midY-source.midY)+Double($1.y),2)
            if ad != bd { return ad < bd }
            return $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y
        }
        var selected: [Shift] = [], sectors = Set<Int>()
        for shift in all {
            let angle = atan2(Double(shift.y),Double(shift.x)) + .pi
            let sector = min(7,Int(angle/(2 * .pi)*8))
            if sectors.insert(sector).inserted { selected.append(shift) }
            if selected.count == 8 { break }
        }
        for shift in all where selected.count < 8 && !selected.contains(shift) { selected.append(shift) }
        // Try minimum movement first even after sector diversification.
        return selected.sorted { a,b in all.firstIndex(of:a)! < all.firstIndex(of:b)! }
    }

    func refine(_ incumbent: Tuple, page: CGRect) -> Tuple {
        guard ProcessInfo.processInfo.environment["AIDOKU_SOURCE_PHYSICAL_INTERIOR"] != "0",
              page == CGRect(x:0,y:0,width:width,height:height), incumbent.fills.count == incumbent.audit.count,
              incumbent.fills.count <= 256 else { return incumbent }
        var current = incumbent
        let owners = current.fills.compactMap(\.ownerID)
        guard owners.count == current.fills.count, Set(owners).count == owners.count,
              !owners.contains(where: \.isEmpty) else { return incumbent }
        // A retained tuple is expected to be page-admitted already. Reject
        // malformed carriers before APIs that convert frame coordinates to Int.
        var rasterPixels = 0
        for fill in current.fills {
            guard fill.frame == fill.frame.integral, page.contains(fill.frame),
                  fill.frame.width == CGFloat(fill.image.width), fill.frame.height == CGFloat(fill.image.height),
                  fill.image.width <= Self.maxROI / fill.image.height else { return incumbent }
            rasterPixels += fill.image.width * fill.image.height
            guard rasterPixels <= 16_777_216 else { return incumbent }
        }
        var processedPixels = 0
        var supportCache: [NativeFinalTextPaintAdmission.Footprint]?
        var supportFailed = false
        for i in current.fills.indices {
            let fill = current.fills[i]
            guard let policy = fill.textExpansionPolicy, policy.insideBalloon else { continue }
            var info: [String:Any] = ["evidenceAvailable":false,"status":"unusable-policy-or-source",
                "sourceIdentity":sourceIdentity,"fixedRasterOnly":true]
            func annotate() { current.audit[i]["sourcePhysicalInterior"] = info }
            guard policy.valid, let guide = fill.textPlacementGuide, guide.valid,
                  policy.sourceFontPixels.isFinite, policy.sourceFontPixels > 0,
                  fill.fontOutputPixels.isFinite, fill.fontOutputPixels > 0,
                  let maskRect = policy.maskRectNormalized else { annotate(); continue }
            let roi = NativeTextExpansionPolicy.rect(maskRect,page:page).integral.intersection(page)
            guard !roi.isNull, roi.width > 0, roi.height > 0 else { annotate(); continue }
            processedPixels += Int(roi.width*roi.height)
            guard processedPixels <= 32_000_000 else { info["status"] = "call-budget"; annotate(); continue }
            guard let evidence = evidence(owner:owners[i],source:guide.rect(in:page),policy:policy,page:page) else {
                info["status"] = "evidence-budget-or-unusable-mask"; annotate(); continue
            }
            let report = evidence.report
            info["sourceEvidenceStatus"] = evidence.status
            info["sourceEvidenceKind"] = evidence.kind
            if let barrier = evidence.barrier {
                info["closedBarrierAssociation"] = barrier.metrics
                info["constantBackgroundEvidenceStatus"] = report.status
            }
            info["sourceErasedCoverage"] = report.sourceErasedCoverage
            info["predictedBoundaryContact"] = report.predictedBoundaryContact
            info["sampleCount"] = report.sampleCount
            info["backgroundRGB"] = report.background as Any? ?? NSNull()
            guard evidence.available, let outer = evidence.domain, let rawMask = evidence.rawMask else {
                info["status"] = evidence.available ? "interval-budget" : "source-evidence-unavailable"
                annotate(); continue
            }
            info["evidenceAvailable"] = true
            info["domainPolicy"] = "outer-containment-raw-plus-static-incumbent-holes-v3"
            info["outerDomainPolicy"] = "outer-envelope-complementary4-hole-fill-v1"
            info["occlusionDomainPolicy"] = "raw-plus-incumbent-alpha-in-enclosed-holes-at-fixed-page-coordinates"
            info["envelopePermitsSourceOcclusion"] = false
            info["rawDomainPixels"] = rawMask.bytes.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
            info["envelopeDomainPixels"] = outer.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.hi - $1.lo } }
            info["pixelDomainRect"] = [outer.rect.minX,outer.rect.minY,outer.rect.width,outer.rect.height]
            if supportCache == nil && !supportFailed {
                supportCache = try? current.fills.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
                supportFailed = supportCache == nil
            }
            guard let supports = supportCache,
                  supports.reduce(0, { $0 + $1.runs.count }) <= 1_000_000,
                  supports.allSatisfy({ $0.runs.count <= 250_000 && $0.pixels <= Self.maxROI }) else {
                info["status"] = "footprint-unavailable-or-budget"; annotate(); continue
            }
            let old = supports[i], outside = outer.outside(old)
            guard let (domain,grandfathered) = occlusionDomain(raw:rawMask,outer:outer,incumbent:old) else {
                info["status"] = "occlusion-domain-budget"; annotate(); continue
            }
            info["beforeOutsidePixels"] = outside
            info["outerBeforeOutsidePixels"] = outside
            info["occlusionBeforeOutsidePixels"] = domain.outside(old)
            info["rawBeforeOutsidePixels"] = domain.outside(old)+grandfathered
            info["incumbentHolePixelsAllowed"] = grandfathered
            info["holeAllowancesFixedInPageCoordinates"] = true
            info["occlusionDomainPixels"] = domain.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.hi - $1.lo } }
            let originalDomain = fill.placementDomain
            let combined: (CGRect)->Bool = { domain.allows($0) && (originalDomain?($0) ?? true) }
            if outside == 0 {
                current.fills[i].placementDomain = combined
                current.audit[i]["domainAvailable"] = true
                current.audit[i]["domainContained"] = true
                info["status"] = "contained-no-move"; info["afterOutsidePixels"] = 0
                info["blankMarginPixels"] = domain.outside(old,inset:true) == 0 ? 1 : 0
                info["outerBlankMarginPixels"] = outer.outside(old,inset:true) == 0 ? 1 : 0
                info["outerAfterOutsidePixels"] = 0; info["occlusionAfterOutsidePixels"] = 0
                info["newEnclosedHoleAlphaPixels"] = 0
                info["retainedAlphaContained"] = true
                info["shiftOutputPixels"] = [0,0]; annotate(); continue
            }
            let rawRadius = floor(fill.fontOutputPixels*Self.maxFixedRasterShiftEm)
            info["maxFixedRasterShiftEm"] = Self.maxFixedRasterShiftEm
            guard rawRadius.isFinite, rawRadius <= 512 else { info["status"] = "radius-budget"; annotate(); continue }
            let radius = Int(rawRadius)
            guard let anchors = NativeReadablePeerGutter.retainedAnchors(packets:current.fills.map(\.sourceClusterAlignment),
                origins:supports.map { $0.bounds.origin }) else {
                info["status"] = "inconsistent-retained-cluster"; annotate(); continue
            }
            let locked = fill.sourceClusterAlignment.flatMap { anchors[$0.groupID] == nil ? nil : $0.axis }
            var accepted = false, attempts = 0, generated = 0, budgetFailure = false
            for inset in outside > 0 ? [true,false] : [true] {
                guard let shifts = proposals(old,domain:domain,inset:inset,radius:radius,source:guide.rect(in:page),locked:locked) else {
                    budgetFailure = true; break
                }
                generated += shifts.count
                let quota = inset && outside > 0 ? min(4,8-attempts) : 8-attempts
                for shift in shifts.prefix(quota) {
                    attempts += 1
                    var fixed = Dictionary(uniqueKeysWithValues:owners.indices.map { (owners[$0],supports[$0].bounds.origin) })
                    fixed[owners[i]] = CGPoint(x:old.bounds.minX+CGFloat(shift.x),y:old.bounds.minY+CGFloat(shift.y))
                    var replacements = current.fills
                    replacements[i].placementDomain = combined
                    guard var admitted = try? NativeFinalTextPaintAdmission.place(replacements,page:page,
                        fixedOrigins:fixed,retainedClusterAnchors:anchors), admitted.fills.count == current.fills.count,
                        admitted.audit.count == current.audit.count else { continue }
                    let transitionedBodies = Set(current.fills.indices.filter {
                        !current.fills[$0].balloonTargetRelaxed && admitted.fills[$0].balloonTargetRelaxed
                    }.compactMap { current.fills[$0].balloonPlacement?.bodyID })
                    guard let retainedAudit = try? NativeBalloonPlacement.RetainedState.preservingPhysicalReadmission(
                        priorAudit: current.audit, admittedAudit: admitted.audit, transitionedBodyIDs: transitionedBodies,
                        unknownPolicy: .preservePriorUncertainty)
                    else { continue }
                    admitted.audit = retainedAudit
                    // Admission may tighten rasters. Reject rather than silently
                    // alter transparent padding, image bytes or unrelated state.
                    var unchanged = true
                    for j in current.fills.indices {
                        let dx = j == i ? CGFloat(shift.x) : 0, dy = j == i ? CGFloat(shift.y) : 0
                        let a = current.fills[j], b = admitted.fills[j]
                        guard let beforeRGBA = try? NativeMandatoryDisplayStroke.rgba(a.image),
                              let afterRGBA = try? NativeMandatoryDisplayStroke.rgba(b.image) else {
                            unchanged = false; break
                        }
                        if b.frame != a.frame.offsetBy(dx:dx,dy:dy) || b.fontOutputPixels != a.fontOutputPixels ||
                            b.ownerID != a.ownerID || b.textExpansionPolicy != a.textExpansionPolicy ||
                            b.textPlacementGuide != a.textPlacementGuide || b.sourceClusterAlignment != a.sourceClusterAlignment ||
                            b.sourceContourOnly != a.sourceContourOnly || b.hasFinalEffects != a.hasFinalEffects || b.image.width != a.image.width || b.image.height != a.image.height ||
                            afterRGBA != beforeRGBA {
                            unchanged = false; break
                        }
                    }
                    guard unchanged, let next = try? admitted.fills.map({ try NativeFinalTextPaintAdmission.retainedFootprint($0) }),
                          next.indices.allSatisfy({ j in next[j].bounds == supports[j].bounds.offsetBy(
                            dx:j == i ? CGFloat(shift.x):0,dy:j == i ? CGFloat(shift.y):0) && next[j].pixels == supports[j].pixels }),
                          domain.outside(next[i],inset:inset) == 0,
                          (try? NativeFinalTextPaintAdmission.verifyRetainedPlacement(admitted.fills,
                            footprints:next,page:page,retainedClusterAnchors:anchors)) != nil else { continue }
                    if let risk = NativeFinalTextPaintAdmission.retainedSourceRiskGate,
                       risk.evaluate(old,next[i]) != true { continue }
                    var audit = current.audit
                    for j in audit.indices {
                        audit[j].merge(admitted.audit[j]) { _,new in new }
                        if current.audit[j]["retainedSourceClusterAnchorApplied"] as? Bool != true {
                            audit[j].removeValue(forKey:"retainedSourceClusterAnchorApplied")
                        }
                    }
                    if audit[i]["preSourcePhysicalInteriorPlacement"] == nil {
                        audit[i]["preSourcePhysicalInteriorPlacement"] = current.audit[i]
                    }
                    current.fills = admitted.fills
                    current.audit = audit
                    supportCache = next
                    info["status"] = "translated"; info["afterOutsidePixels"] = 0
                    info["outerAfterOutsidePixels"] = outer.outside(next[i])
                    info["occlusionAfterOutsidePixels"] = 0; info["newEnclosedHoleAlphaPixels"] = 0
                    info["outerBlankMarginPixels"] = outer.outside(next[i],inset:true) == 0 ? 1 : 0
                    info["retainedAlphaContained"] = true; info["blankMarginPixels"] = inset ? 1 : 0
                    info["shiftOutputPixels"] = [shift.x,shift.y]
                    accepted = true; break
                }
                if accepted { break }
            }
            info["proposalCount"] = generated; info["admissionAttempts"] = attempts
            if !accepted { info["status"] = budgetFailure ? "proposal-budget-unresolved" : "no-safe-proposal-unresolved" }
            annotate()
        }
        return current
    }
}
