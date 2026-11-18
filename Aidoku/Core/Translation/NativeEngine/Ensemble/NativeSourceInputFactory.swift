import CoreGraphics
import CoreFoundation
import Foundation

/// Reconstruct bounded original source packets from the actual native layout
/// and source-bound OCR/RF observations. No target/GT/corpus lookups.
enum NativeSourceInputFactory {
    static let sourceCropPolicyVersion = "max15pct-visible-box-integral-budget-v2"
    struct Owner {
        let itemIndex:Int;let polygon:[CGPoint];var input:SourceNativeInput
        var originalMemberPolygons:[[CGPoint]]=[]
        var geometryClippingAudit:[String:Any]=[:]
    }
    /// Minimal observations have their own type. Missing boundary/OCR/style187
    /// observations are absent, not zero-filled legacy feature packets.
    struct MinimalObservation {
        let segmentation: NativeMinimalSourceSegmentation.Output
        let fullRFSHA256: String
        let coarseRFSHA256: String
        let rfModelWeightsSHA256: String
    }
    struct MinimalOwner {
        let itemIndex: Int
        let polygon: [CGPoint]
        let rgb: [UInt8]
        let fontPixels: Double
        let memberPolygons: [[CGPoint]]
        let observation: MinimalObservation
        var width: Int { Int(crop.width) }
        var height: Int { Int(crop.height) }
        let bbox: CGRect
        let crop: CGRect
        let pageSize: CGSize
        let sourceIdentity: String
        let sourceText: String
        let originalMemberPolygons: [[CGPoint]]
        let mergedPolygon: [CGPoint]
        let geometryClippingAudit: [String: Any]
    }

    /// The candidate style/width family is fitted on this exact M1 policy.
    /// Only an actual primary observation and its same-output mask are admitted;
    /// rich209, boundary, OCR and RF context packets are not constructed here.
    static func makeM1StyleObservation(owner: MinimalOwner) throws -> NativeMinimalSourceStyleInput {
        let observation = owner.observation.segmentation
        guard let primary = observation.primary,
              observation.audit["policySHA256"] as? String == NativeSourceInferencePolicy.primaryM1Configuration.policySHA256,
              observation.audit["primaryExecuted"] as? Bool == true,
              observation.audit["boundaryExecuted"] as? Bool == false else { throw Failure.sourceMismatch }
        let input = NativeMinimalSourceStyleInput(width: owner.width, height: owner.height,
            rgb: owner.rgb, ownMask: observation.mask, primary: primary,
            fontPriorSourcePixels: owner.fontPixels, bbox: owner.bbox,
            sourceIdentity: owner.sourceIdentity, sourceText: owner.sourceText, memberPolygons: owner.memberPolygons)
        try input.validate()
        return input
    }
    enum Failure:Error {
        case missingOriginalText(Int),invalidGeometry(Int),sourceMismatch,geometryOutsideCrop(String)
        case invalidCropGeometry
        /// An original-resolution bbox cannot fit. The caller must report a
        /// budget failure or implement explicit tiling, never shrink the bbox.
        case sourceCropBudgetExceeded(width: Int, height: Int, budget: Int)
    }

    /// Largest symmetric fractional padding up to 15% that fits the existing
    /// original-resolution pixel budget after integral rounding + page clipping.
    /// Normal crops take the exact old expression. Only optional context is
    /// reduced; the entire page-visible bbox remains inside the result.
    static func sourceCrop(box: CGRect, pageSize: CGSize, pixelBudget: Int = 1_500_000) throws -> CGRect {
        guard [box.minX, box.minY, box.maxX, box.maxY, box.width, box.height, pageSize.width, pageSize.height].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0, pageSize.width > 0, pageSize.height > 0,
              pageSize.width.rounded(.down) == pageSize.width, pageSize.height.rounded(.down) == pageSize.height,
              pageSize.width < CGFloat(Int.max), pageSize.height < CGFloat(Int.max), pixelBudget > 0 else {
            throw Failure.invalidCropGeometry
        }
        let page = CGRect(origin: .zero, size: pageSize)
        let visible = page.contains(box) ? box : box.intersection(page)
        guard !visible.isEmpty else { throw Failure.invalidCropGeometry }
        func padded(_ fraction: CGFloat) -> CGRect {
            visible.insetBy(dx: -visible.width * fraction, dy: -visible.height * fraction).integral.intersection(page)
        }
        func fits(_ crop: CGRect) -> Bool {
            guard !crop.isNull, crop.width > 0, crop.height > 0 else { return false }
            return Int(crop.width) <= pixelBudget / Int(crop.height)
        }
        let maximum: CGFloat = 0.15
        let ordinary = padded(maximum)
        if fits(ordinary) { return ordinary }
        let base = padded(0)
        guard !base.isNull, base.width > 0, base.height > 0 else { throw Failure.invalidCropGeometry }
        guard fits(base) else {
            throw Failure.sourceCropBudgetExceeded(width: Int(base.width), height: Int(base.height), budget: pixelBudget)
        }
        // Integral rectangle area is monotone in padding, including at page
        // edges. Keep the last feasible rectangle at a rounding discontinuity.
        var lower: CGFloat = 0, upper = maximum, best = base
        for _ in 0..<64 {
            let middle = lower + (upper - lower) / 2
            if middle == lower || middle == upper { break }
            let candidate = padded(middle)
            if fits(candidate) { lower = middle; best = candidate } else { upper = middle }
        }
        return best
    }

    /// Only the visible portion of the original box has pixels in this packet.
    static func localVisibleBox(_ box: CGRect, crop: CGRect) -> CGRect {
        let visible = crop.contains(box) ? box : box.intersection(crop)
        return visible.offsetBy(dx: -crop.minX, dy: -crop.minY)
    }

    /// The crop comes from sourceCrop: integral, nonempty and inside the
    /// validated packed RGB page. Borrow the page and copy only complete rows.
    private static func sourceRGB(_ source: NativeRFDETRSourceImage, crop: CGRect) -> [UInt8] {
        let rowBytes = Int(crop.width) * 3
        let rows = Int(crop.height)
        let origin = (Int(crop.minY) * source.width + Int(crop.minX)) * 3
        let step = source.width * 3
        return [UInt8](unsafeUninitializedCapacity: rowBytes * rows) { output, initialized in
            source.rgb.withUnsafeBytes { input in
                let base = input.baseAddress! + origin
                let target = UnsafeMutableRawPointer(output.baseAddress!)
                for row in 0..<rows {
                    (target + row * rowBytes).copyMemory(from: base + row * step, byteCount: rowBytes)
                }
            }
            initialized = rowBytes * rows
        }
    }

    /// Original geometry and RGB + actual RF only. Deliberately does not call
    /// ocr(), wordEvidence(), contexts(), or SourceNativeInput.validate(). The
    /// prior is always recomputed; inherited learned sourceFontSize is ignored.
    static func makeMinimal(source: NativeRFDETRSourceImage, items: [[String: Any]],
                            sourceEvidence: [String: Any], rf: NativePixelRFEvidence,
                            observationMode: NativeSourceOwnerMeasurements.Mode = .serial,
                            observe: (NativeMinimalSourceSegmentation.Input) throws -> MinimalObservation) throws -> [MinimalOwner] {
        let sourceIdentity = source.identity
        guard sourceIdentity == rf.imageIdentity, source.width == rf.width, source.height == rf.height else {
            throw Failure.sourceMismatch
        }
        let w = source.width, h = source.height
        let rows = (sourceEvidence["originalOCR"] as? [String: Any])?["regions"] as? [[String: Any]] ?? []
        let recognized = (sourceEvidence["originalRecognizer"] as? [String: Any])?["regions"] as? [[String: Any]] ?? []
        struct CropPlan {
            let index: Int
            let text: String
            let box: CGRect
            let crop: CGRect
            var pixels: Int { Int(crop.width) * Int(crop.height) }
        }
        // Defer each geometry failure until its source-order slot. An earlier
        // segmentation error still wins over a later owner's malformed box.
        var plans: [Result<CropPlan, Error>] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            if item["keptLettering"] as? Bool == true || item["sourceTextOnly"] as? Bool == true ||
                (item["text"] as? String ?? "").isEmpty { continue }
            plans.append(Result {
                guard let b = item["sourceBounds"] as? [Double], b.count == 4,
                      b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0 else { throw Failure.invalidGeometry(index) }
                let matching = rows.filter { row in
                    guard let a = row["sourceBounds"] as? [Double], a.count == 4 else { return false }
                    return zip(a, b).allSatisfy { abs($0 - $1) <= 1e-8 }
                }
                let original = matching.count == 1 ? matching[0] : [:]
                guard let text = (item["sourceOriginalText"] as? String) ?? (original["source"] as? String),
                      !text.isEmpty else { throw Failure.missingOriginalText(index) }
                let box = CGRect(x: b[0] * Double(w), y: b[1] * Double(h),
                    width: b[2] * Double(w), height: b[3] * Double(h))
                let crop = try sourceCrop(box: box, pageSize: CGSize(width: w, height: h))
                return CropPlan(index: index, text: text, box: box, crop: crop)
            })
        }
        // The default preserves serial callbacks. Production opts in only for
        // immutable segmentation and local SHA computations. map joins each pair.
        return try withoutActuallyEscaping(observe) { observe in
            try NativeSourceOwnerMeasurements.map(count: plans.count, pixels: { index in
                // Failed plans run alone and throw in their original slot.
                (try? plans[index].get().pixels) ?? Int.max
            }, mode: observationMode) { slot in
                let plan = try plans[slot].get()
                let index = plan.index, item = items[index], box = plan.box, crop = plan.crop, text = plan.text
                let pairs = item["sourcePolygon"] as? [[Double]] ?? []
                guard pairs.count <= 16, pairs.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
                    throw Failure.invalidGeometry(index)
                }
                let rectangle = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
                let polygon = pairs.count >= 3 ? pairs.map { CGPoint(x: $0[0] * Double(w), y: $0[1] * Double(h)) } : rectangle
                let members = try memberPolygons(item: item, originalRows: rows, recognizedRows: recognized,
                    pageSize: CGSize(width: w, height: h), fallback: polygon)
                let geometry = try featureGeometry(members: members, merged: polygon, crop: crop)
                let support = try rf.support(crop: crop, polygons: geometry.polygons, sourceIdentity: sourceIdentity)
                let cw = Int(crop.width), ch = Int(crop.height)
                let rgb = sourceRGB(source, crop: crop)
                func local(_ points: [CGPoint]) -> [CGPoint] {
                    points.map { CGPoint(x: $0.x - crop.minX, y: $0.y - crop.minY) }
                }
                let prior = try NativeSimpleSourceFont.prior(bounds: box, originalCharacterCount: text.unicodeScalars.count)
                let input = NativeMinimalSourceSegmentation.Input(width: cw, height: ch, rgb: rgb,
                    fullRF: support.full, coarseRF: support.coarse, memberPolygons: geometry.polygons.map(local),
                    fontPixels: prior, rfModelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256)
                let removal = pairs.isEmpty ? polygon : NativeIndependentPanelGutter.clip(polygon,
                    to: CGRect(x: 0, y: 0, width: w - 1, height: h - 1))
                // Consume the 27+4 RF planes inside this iteration. Only the observation and
                // its native-byte digests accompany the crop into the page-wide style cohort.
                let observation = try observe(input)
                return MinimalOwner(itemIndex: index, polygon: removal, rgb: rgb, fontPixels: prior,
                    memberPolygons: input.memberPolygons, observation: observation,
                    bbox: localVisibleBox(box, crop: crop), crop: crop,
                    pageSize: CGSize(width: w, height: h), sourceIdentity: sourceIdentity, sourceText: text,
                    originalMemberPolygons: members, mergedPolygon: local(geometry.merged), geometryClippingAudit: geometry.audit)
            }
        }
    }

    static func make(source:NativeRFDETRSourceImage,items:[[String:Any]],sourceEvidence:[String:Any],
                     rf:NativePixelRFEvidence,ops:any NativeAppearanceImageOperations,
                     geometryFontPriorOnly:Bool=false) throws -> [Owner] {
        let sourceIdentity = source.identity
        guard sourceIdentity==rf.imageIdentity,source.width==rf.width,source.height==rf.height else {throw Failure.sourceMismatch}
        let w=source.width,h=source.height
        let rows=(sourceEvidence["originalOCR"] as? [String:Any])?["regions"] as? [[String:Any]] ?? []
        let recognized=(sourceEvidence["originalRecognizer"] as? [String:Any])?["regions"] as? [[String:Any]] ?? []
        var result:[Owner]=[]
        for (index,item) in items.enumerated() {
            if item["keptLettering"] as? Bool == true || item["sourceTextOnly"] as? Bool == true || (item["text"] as? String ?? "").isEmpty {continue}
            guard let b=item["sourceBounds"] as? [Double],b.count==4,b.allSatisfy(\.isFinite),b[2]>0,b[3]>0 else {throw Failure.invalidGeometry(index)}
            let matching=rows.filter {row in
                guard let a=row["sourceBounds"] as? [Double],a.count==4 else {return false}
                return zip(a,b).allSatisfy {abs($0-$1)<=1e-8}
            }
            let original=matching.count==1 ? matching[0]:[:]
            guard let text=(item["sourceOriginalText"] as? String) ?? (original["source"] as? String),!text.isEmpty else {
                throw Failure.missingOriginalText(index)
            }
            let box=CGRect(x:b[0]*Double(w),y:b[1]*Double(h),width:b[2]*Double(w),height:b[3]*Double(h))
            let crop=try sourceCrop(box:box,pageSize:CGSize(width:w,height:h))
            let pairs=item["sourcePolygon"] as? [[Double]] ?? []
            guard pairs.count<=16,pairs.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else {throw Failure.invalidGeometry(index)}
            func rectangle(_ r:CGRect)->[CGPoint] {[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)]}
            let owner=pairs.count>=3 ? pairs.map {CGPoint(x:$0[0]*Double(w),y:$0[1]*Double(h))}:rectangle(box)
            let polygons=try memberPolygons(item:item,originalRows:rows,recognizedRows:recognized,
                pageSize:CGSize(width:w,height:h),fallback:owner)
            let features=try featureGeometry(members:polygons,merged:owner,crop:crop)
            let support=try rf.support(crop:crop,polygons:features.polygons,sourceIdentity:sourceIdentity)
            let cw=Int(crop.width),ch=Int(crop.height)
            let rgb=sourceRGB(source,crop:crop)
            func local(_ p:[CGPoint])->[CGPoint] {p.map {CGPoint(x:$0.x-crop.minX,y:$0.y-crop.minY)}}
            let prior:Double
            if geometryFontPriorOnly {
                prior=try NativeSimpleSourceFont.prior(bounds:box,originalCharacterCount:text.unicodeScalars.count)
            } else {
                let declared=(item["sourceFontSize"] as? NSNumber)?.doubleValue
                prior=declared.flatMap {$0.isFinite && $0>0 ? $0:nil} ??
                    max(8,min(Double(min(box.width,box.height)),sqrt(Double(box.width*box.height)/Double(max(1,text.count)))))
            }
            var input=SourceNativeInput(width:cw,height:ch,rgb:rgb,rf:support.full,coarseRF:support.coarse,
                affinityScores:support.affinityScores,rfModelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                memberPolygons:features.polygons.map(local),mergedPolygon:local(features.merged),
                bbox:localVisibleBox(box,crop:crop),fontPriorSourcePixels:prior,crop:crop,
                pageSize:CGSize(width:w,height:h),sourceIdentity:sourceIdentity,sourceText:text,
                confidence:(item["sourceConfidence"] as? NSNumber)?.doubleValue ?? (original["confidence"] as? NSNumber)?.doubleValue,
                role:(item["sourceRole"] as? String) ?? (original["textRole"] as? String))
            input.ocr=try ocr(sourceEvidence,pageSize:input.pageSize,crop:crop,ops:ops)
            input.wordEvidence=try wordEvidence(recognizedRows:recognized,members:polygons,crop:crop)
            try input.validate(requirePredictions:false)
            let removal=pairs.isEmpty ? owner:NativeIndependentPanelGutter.clip(owner,to:CGRect(x:0,y:0,width:w-1,height:h-1))
            result.append(.init(itemIndex:index,polygon:removal,input:input,
                originalMemberPolygons:polygons,geometryClippingAudit:features.audit))
        }
        return result
    }

    /// Associate whole observed rows by exact member geometry, never paragraph
    /// text, row position, owner IDs, overlap thresholds or target classification.
    /// Missing observations stay absent. Preserve recognizer order and duplicates.
    static func wordEvidence(recognizedRows:[[String:Any]],members:[[CGPoint]],crop:CGRect) throws -> [SourceWordEvidence] {
        func same(_ a:[CGPoint],_ b:[CGPoint])->Bool {
            guard a.count==b.count else {return false}
            return b.indices.contains { start in
                [1,-1].contains { direction in
                    a.indices.allSatisfy { i in
                        let p=b[(start+direction*i+b.count)%b.count]
                        return abs(a[i].x-p.x)<=1e-5 && abs(a[i].y-p.y)<=1e-5
                    }
                }
            }
        }
        var result:[SourceWordEvidence]=[]
        var bytes=0
        for row in recognizedRows {
            guard let pairs=row["polygon"] as? [[Double]],(3...256).contains(pairs.count),
                  pairs.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else {continue}
            let polygon=pairs.map {CGPoint(x:$0[0],y:$0[1])}
            guard members.contains(where:{same($0,polygon)}) else {continue}
            // No fabricated index or split/trimmed source text when the row is incomplete.
            guard let text=row["text"] as? String,let number=row["sourceIndex"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,
                  number.doubleValue>=0,number.doubleValue<Double(Int.max),
                  number.doubleValue.rounded(.towardZero)==number.doubleValue else {continue}
            bytes+=text.utf8.count
            guard result.count<256,text.utf8.count<=65_536,bytes<=262_144 else {throw Failure.sourceMismatch}
            let xs=polygon.map(\.x),ys=polygon.map(\.y)
            let bbox=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
            result.append(SourceWordEvidence(text:text,sourceIndex:number.intValue,
                bbox:bbox.offsetBy(dx:-crop.minX,dy:-crop.minY),
                polygon:polygon.map {CGPoint(x:$0.x-crop.minX,y:$0.y-crop.minY)}))
        }
        return result
    }

    /// Authoritative member geometry is GLOBAL original-image pixels. An empty
    /// legacy export means absent; a malformed nonempty export must never be
    /// replaced with rectangular proxies. Normalized member rects only match rows.
    static func memberPolygons(item:[String:Any],originalRows:[[String:Any]],recognizedRows:[[String:Any]],
                               pageSize:CGSize,fallback:[CGPoint]) throws -> [[CGPoint]] {
        func authoritative(_ row:[String:Any]) throws -> [[CGPoint]]? {
            guard let value=row["sourceMemberPolygons"],!(value is NSNull) else {return nil}
            guard let polygons=value as? [[[Double]]] else {throw Failure.sourceMismatch}
            if polygons.isEmpty {return nil}
            return try polygons.map { points in
                guard points.count>=3,points.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite) &&
                    $0[0]>=0 && $0[1]>=0 && $0[0]<=Double(pageSize.width) && $0[1]<=Double(pageSize.height)}) else {
                    throw Failure.sourceMismatch
                }
                var twiceArea=0.0
                for i in points.indices {let next=points[(i+1)%points.count];twiceArea+=points[i][0]*next[1]-next[0]*points[i][1]}
                guard abs(twiceArea)>1e-8 else {throw Failure.sourceMismatch}
                return points.map {CGPoint(x:$0[0],y:$0[1])}
            }
        }
        func matching(_ bounds:[Double]) -> [[String:Any]] {
            originalRows.filter { row in
                // A clipped row's visible box is not its identity: two distinct source
                // owners can project onto the same page-edge rectangle.
                let observation = row["sourceGeometryObservation"] as? [String: Any]
                let b: [Double]?
                if observation?["rectClipped"] as? Bool == true,
                   observation?["inputCoordinateSpace"] as? String == "normalized-top-left" {
                    b = observation?["rawRect"] as? [Double]
                } else { b = row["sourceBounds"] as? [Double] }
                guard let b, b.count == 4 else {return false}
                return zip(b,bounds).allSatisfy {$0.isFinite && $1.isFinite && abs($0-$1)<=1e-8}
            }
        }
        func unique(_ polygons:[[CGPoint]]) -> [[CGPoint]] {
            var result:[[CGPoint]]=[]
            for polygon in polygons where !result.contains(polygon) {result.append(polygon)}
            return result
        }
        if let direct=try authoritative(item) {return direct}
        if let bounds=item["sourceBounds"] as? [Double],bounds.count==4 {
            let fromRows=try matching(bounds).flatMap {try authoritative($0) ?? []}
            if !fromRows.isEmpty {return unique(fromRows)}
        }
        guard let rawRects=item["unitMemberRects"] else {return [fallback]}
        guard let rects=rawRects as? [[Double]],rects.allSatisfy({$0.count==4 && $0.allSatisfy(\.isFinite) &&
            $0[2]>0 && $0[3]>0 && ($0[0]+$0[2]).isFinite && ($0[1]+$0[3]).isFinite &&
            $0[0]<1 && $0[1]<1 && $0[0]+$0[2]>0 && $0[1]+$0[3]>0}) else {
            throw Failure.sourceMismatch
        }
        if rects.isEmpty {return [fallback]}
        var members:[[CGPoint]]=[]
        for rect in rects {
            let fromRows=try matching(rect).flatMap {try authoritative($0) ?? []}
            if !fromRows.isEmpty {members.append(contentsOf:fromRows);continue}
            let x=rect[0]*Double(pageSize.width),y=rect[1]*Double(pageSize.height)
            let w=rect[2]*Double(pageSize.width),h=rect[3]*Double(pageSize.height)
            let observed=recognizedRows.compactMap {row -> [CGPoint]? in
                guard let points=row["polygon"] as? [[Double]],points.count>=3,
                      points.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite) && $0[0]>=0 && $0[1]>=0 &&
                          $0[0]<=Double(pageSize.width) && $0[1]<=Double(pageSize.height)}) else {return nil}
                let xs=points.map {$0[0]},ys=points.map {$0[1]}
                guard abs(xs.min()!-x)<=1e-5,abs(ys.min()!-y)<=1e-5,
                      abs(xs.max()!-x-w)<=1e-5,abs(ys.max()!-y-h)<=1e-5 else {return nil}
                return points.map {CGPoint(x:$0[0],y:$0[1])}
            }
            if observed.count==1 {members.append(observed[0])}
            else if observed.count>1 {throw Failure.sourceMismatch}
            else {
                let left=max(0,x), top=max(0,y), right=min(pageSize.width,x+w), bottom=min(pageSize.height,y+h)
                members.append([CGPoint(x:left,y:top),CGPoint(x:right,y:top),
                                CGPoint(x:right,y:bottom),CGPoint(x:left,y:bottom)])
            }
        }
        return unique(members)
    }

    /// Intersect actual polygon edges with the fixed source crop. This only
    /// bounds feature geometry; original evidence and predicted masks stay separate.
    static func featureGeometry(members:[[CGPoint]],merged:[CGPoint],crop:CGRect) throws ->
        (polygons:[[CGPoint]],merged:[CGPoint],audit:[String:Any]) {
        func clip(_ polygon:[CGPoint])->[CGPoint] {
            var points=polygon
            for axis in 0..<4 {
                let boundary=axis==0 ? crop.minX:axis==1 ? crop.maxX:axis==2 ? crop.minY:crop.maxY
                func value(_ p:CGPoint)->CGFloat {axis<2 ? p.x:p.y}
                func inside(_ p:CGPoint)->Bool {axis%2==0 ? value(p)>=boundary:value(p)<=boundary}
                var output:[CGPoint]=[]
                guard var previous=points.last else {return []}
                for current in points {
                    if inside(previous) != inside(current) {
                        let t=(boundary-value(previous))/(value(current)-value(previous))
                        var crossing=CGPoint(x:previous.x+t*(current.x-previous.x),y:previous.y+t*(current.y-previous.y))
                        if axis<2 {crossing.x=boundary} else {crossing.y=boundary}
                        output.append(crossing)
                    }
                    if inside(current) {output.append(current)}
                    previous=current
                }
                points=output
            }
            var distinct:[CGPoint]=[]
            for point in points {
                // Roundoff at an already intersected edge must remain in the
                // closed crop domain accepted by both source feature validators.
                let p=CGPoint(x:min(crop.maxX,max(crop.minX,point.x)),y:min(crop.maxY,max(crop.minY,point.y)))
                if distinct.last != p {distinct.append(p)}
            }
            if distinct.count>1,distinct.first==distinct.last {distinct.removeLast()}
            guard distinct.count>=3 else {return []}
            let area=distinct.indices.reduce(CGFloat(0)) {sum,i in
                let next=distinct[(i+1)%distinct.count];return sum+distinct[i].x*next.y-next.x*distinct[i].y
            }
            return abs(area)>1e-8 ? distinct:[]
        }
        let clipped=members.map(clip),kept=clipped.filter {!$0.isEmpty},owner=clip(merged)
        guard !kept.isEmpty,owner.count>=3 else {
            let all=members.flatMap {$0}+merged,x=all.map(\.x),y=all.map(\.y)
            throw Failure.geometryOutsideCrop("crop=\(crop); global geometry min=(\(x.min() ?? 0),\(y.min() ?? 0)) max=(\(x.max() ?? 0),\(y.max() ?? 0)); members=\(members.count)")
        }
        let changed=zip(members,clipped).filter {$0 != $1}.count
        return (kept,owner,["policy":"true-polygon-intersection-supplied-source-crop-v2",
            "originalMemberCount":members.count,"featureMemberCount":kept.count,
            "intersectedMemberCount":changed,"outsideMemberCount":clipped.filter {$0.isEmpty}.count,
            "mergedPolygonIntersected":owner != merged,"cropExpanded":false,"predictedMaskBBoxClipped":false])
    }

    static func contexts(_ owners:inout [Owner]) {
        for index in owners.indices {
            let own=owners[index].input,r=own.crop,w=own.width
            var context=own.ownMask
            for peer in owners {
                let other=peer.input,overlap=r.intersection(other.crop)
                guard !overlap.isNull,!overlap.isEmpty else {continue}
                let left=Int(overlap.minX),top=Int(overlap.minY),right=Int(overlap.maxX),bottom=Int(overlap.maxY)
                for y in top..<bottom {for x in left..<right {
                    let p=(y-Int(r.minY))*w+x-Int(r.minX),q=(y-Int(other.crop.minY))*other.width+x-Int(other.crop.minX)
                    context[p]=max(context[p],other.ownMask[q])
                }}
            }
            owners[index].input.contextMask=context
        }
    }
    private static func ocr(_ evidence:[String:Any],pageSize:CGSize,crop:CGRect,
                            ops:any NativeAppearanceImageOperations) throws -> [Float] {
        let w=Int(crop.width),h=Int(crop.height);var output=[Float](repeating:0,count:w*h*8)
        for (key,container,normalized,detector) in [("originalOCR","regions",true,false),("originalDetector","boxes",false,true)] {
            let rows=(evidence[key] as? [String:Any])?[container] as? [[String:Any]] ?? []
            for row in rows {
                guard let pairs=row["polygon"] as? [[Double]],pairs.count>=3,pairs.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else {continue}
                let polygon=pairs.map {CGPoint(x:$0[0]*(normalized ? Double(pageSize.width):1)-Double(crop.minX),
                    y:$0[1]*(normalized ? Double(pageSize.height):1)-Double(crop.minY))}
                let support=try ops.raster(polygons:[polygon],width:w,height:h)
                var values:[Float]=[1,0,0,0,0,0,0,0]
                if let confidence=(row["confidence"] as? NSNumber)?.doubleValue {
                    guard confidence.isFinite,(0...1).contains(confidence) else {throw Failure.sourceMismatch}
                    values[detector ? 1:3]=1;values[detector ? 2:4]=Float(confidence)
                }
                if row["recTokensAvailable"] as? Bool == true,
                   let minimum=(row["recMinTokenConfidence"] as? NSNumber)?.floatValue,
                   let mean=(row["recMeanTokenConfidence"] as? NSNumber)?.floatValue {
                    values[5]=1;values[6]=minimum;values[7]=mean
                }
                for p in support.indices where support[p] != 0 {for c in 0..<8 {output[p*8+c]=max(output[p*8+c],values[c])}}
            }
        }
        return output
    }
}
