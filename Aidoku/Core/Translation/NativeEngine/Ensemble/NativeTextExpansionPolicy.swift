import CoreGraphics
import Foundation

/// Source-inferred capacity, not permission to erase background or cross a balloon.
struct NativeTextExpansionPolicy: Codable, Equatable, Sendable {
    let allowedRectNormalized: [Double]
    let candidates: [[Double]]
    let maskCoverage: [Double]
    let backgroundRisk: [Double]
    let sourceFontPixels: Double
    let kind: String
    let maskRectNormalized: [Double]?
    let maskSpansNormalized: [Double]?
    var sourceLineWidthScale: Double? = nil
    var sourceAnchorLimitEm: Double? = nil
    /// All disjoint safe intervals per mask band. Nil keeps the legacy domain.
    var maskIntervalRowsNormalized: [[Double]]? = nil
    /// Original candidate palette, retained when optional denser word-fit
    /// candidates are rejected. Nil keeps historical policies unchanged.
    var ordinaryCandidateIndices:[Int]? = nil
    /// Exterior captions may expand around, never newly into, other balloons.
    var forbiddenBalloonRectNormalized:[Double]? = nil
    var forbiddenBalloonRowsNormalized:[[Double]]? = nil
    var balloonExclusionSourceRectNormalized:[Double]? = nil
    func candidateIndices(ordinary:Bool)->[Int] {
        ordinary ? ordinaryCandidateIndices ?? Array(candidates.indices):Array(candidates.indices)
    }
    var insideBalloon: Bool { kind == "inside-balloon-mask" }
    /// A confidently detected source container can bound expansion even when
    /// its segmentation was not retained. A box is not a mask certificate:
    /// callers keep exterior/contour admission and preserve the source extent.
    static func sourceContainerBound(source:CGRect,container:CGRect,confidence:Double,
                                     font:CGFloat,page:CGRect)->CGRect? {
        guard confidence.isFinite,confidence>=0.9,font.isFinite,font>0,
              !source.isEmpty,!source.isNull,!container.isEmpty,!container.isNull else{return nil}
        let box=container.intersection(page),intersection=source.intersection(box)
        guard !box.isNull,!intersection.isNull,
              intersection.width*intersection.height>=source.width*source.height*0.98 else{return nil}
        let insetX=max(0,min(font*0.12,source.minX-box.minX,box.maxX-source.maxX))
        let insetY=max(0,min(font*0.12,source.minY-box.minY,box.maxY-source.maxY))
        let bound=box.insetBy(dx:insetX,dy:insetY).union(source).intersection(page)
        return bound.isNull || bound.isEmpty ? nil:bound
    }
    /// A coarse predicted instance can contain several neighbouring captions.
    /// Removing a short tail must not flatten an established tall paragraph
    /// across that whole instance. Exterior captions retain wider expansion.
    func allowsRefinementShape(original:CGRect,proposed:CGRect,font:CGFloat,requiredWordWidth:CGFloat?=nil)->Bool {
        guard insideBalloon,original.height>=original.width*1.4 else{return true}
        // A measured lexical word may exceed the coarse paragraph-shape cap.
        // Permit only its required width; actual mask/peer admission still owns
        // containment and placement. Unmeasured paragraph flattening stays capped.
        let word=requiredWordWidth.flatMap {$0.isFinite && $0>0 ? $0:nil} ?? 0
        return proposed.width<=max(original.width*1.35,font*3.5,word)+0.01
    }
    /// Keep explicit narration start anchors near their source when that source
    /// rectangle is itself certified inside the same predicted domain.
    func sourceAnchorAllows(_ paint:CGRect,page:CGRect,guide:NativeTextPlacementGuide?)->Bool {
        guard let limit=sourceAnchorLimitEm,insideBalloon,let guide,
              guide.horizontal == .left,guide.vertical == .top,allows(guide.rect(in:page),page:page)else{return true}
        let delta=guide.preferredShift(bounds:paint,page:page)
        return hypot(delta.x,delta.y)<=CGFloat(limit*sourceFontPixels)+1
    }
    /// A source single horizontal line must not become a tall poster just to
    /// preserve the estimated em. Fit the translation within modest shape growth.
    func sourceLineSizeLimit(source:CGRect)->CGSize? {
        let em=CGFloat(sourceFontPixels)
        guard !insideBalloon,source.height>=em*0.5,source.height<=em*1.6,
              source.width>=em*3.5,source.width>=source.height*3 else { return nil }
        return CGSize(width:source.width*CGFloat(sourceLineWidthScale ?? 1.35),height:source.height*1.2+em*0.1)
    }
    static func validRect(_ r: [Double]) -> Bool {
        r.count == 4 && r.allSatisfy(\.isFinite) && r[2] > 0 && r[3] > 0 &&
        CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -1e-9, dy: -1e-9)
            .contains(CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))
    }
    var valid: Bool {
        Self.validRect(allowedRectNormalized) && !candidates.isEmpty && candidates.count <= 32 &&
        candidates.allSatisfy(Self.validRect) && maskCoverage.count == candidates.count &&
        backgroundRisk.count == candidates.count && (maskCoverage + backgroundRisk).allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        sourceFontPixels.isFinite && sourceFontPixels > 0 &&
        (sourceLineWidthScale.map { $0.isFinite && (1...8).contains($0) } ?? true) && (!insideBalloon || validMask)
        && (sourceAnchorLimitEm.map {$0.isFinite && (1...8).contains($0)} ?? true)
        && (ordinaryCandidateIndices.map { !$0.isEmpty && Set($0).count==$0.count && $0.allSatisfy(candidates.indices.contains) } ?? true)
        && validBalloonExclusion
    }
    private var validBalloonExclusion:Bool {
        if forbiddenBalloonRectNormalized==nil,forbiddenBalloonRowsNormalized==nil,balloonExclusionSourceRectNormalized==nil {return true}
        guard let rect=forbiddenBalloonRectNormalized,Self.validRect(rect),let rows=forbiddenBalloonRowsNormalized,
              !rows.isEmpty,rows.count<=4096,
              balloonExclusionSourceRectNormalized.map(Self.validRect) ?? true else{return false}
        return rows.allSatisfy { row in
            row.count<=1024 && row.count%2==0 && row.allSatisfy {$0.isFinite && (0...1).contains($0)} &&
                stride(from:0,to:row.count,by:2).allSatisfy { k in row[k]<row[k+1] && (k==0 || row[k]>=row[k-1]) }
        }
    }
    private func newlyOverlapsBalloon(_ paint:CGRect,page:CGRect)->Bool {
        guard let raw=forbiddenBalloonRectNormalized,let rows=forbiddenBalloonRowsNormalized,!rows.isEmpty else{return false}
        let region=Self.rect(raw,page:page),clipped=paint.intersection(region)
        guard !clipped.isNull,!clipped.isEmpty else{return false}
        var parts=[clipped]
        if let rawSource=balloonExclusionSourceRectNormalized {
            let own=clipped.intersection(Self.rect(rawSource,page:page))
            if !own.isNull,!own.isEmpty {
                parts=[CGRect(x:clipped.minX,y:clipped.minY,width:clipped.width,height:own.minY-clipped.minY),
                    CGRect(x:clipped.minX,y:own.maxY,width:clipped.width,height:clipped.maxY-own.maxY),
                    CGRect(x:clipped.minX,y:own.minY,width:own.minX-clipped.minX,height:own.height),
                    CGRect(x:own.maxX,y:own.minY,width:clipped.maxX-own.maxX,height:own.height)]
            }
        }
        let step=region.height/CGFloat(rows.count)
        for part in parts where part.width>0 && part.height>0 {
            let first=max(0,Int(floor((part.minY-region.minY)/step)))
            let last=min(rows.count-1,Int(ceil((part.maxY-region.minY)/step))-1)
            guard first<=last else{continue}
            for row in first...last {
                let values=rows[row]
                for k in stride(from:0,to:values.count,by:2) where
                    part.minX<CGFloat(values[k+1])*page.width && part.maxX>CGFloat(values[k])*page.width {return true}
            }
        }
        return false
    }
    private var validMask: Bool {
        guard let r = maskRectNormalized, Self.validRect(r), let spans = maskSpansNormalized,
              spans.count >= 4, spans.count <= 2048, spans.count % 2 == 0 else { return false }
        guard spans.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
            stride(from: 0, to: spans.count, by: 2).allSatisfy({ spans[$0] <= spans[$0 + 1] }) else{return false}
        guard let rows=maskIntervalRowsNormalized else{return true}
        return rows.count==spans.count/2 && rows.allSatisfy { row in
            row.count<=128 && row.count%2==0 && row.allSatisfy {$0.isFinite && (0...1).contains($0)} &&
                stride(from:0,to:row.count,by:2).allSatisfy { k in
                    row[k]<row[k+1] && (k==0 || row[k]>=row[k-1])
                }
        }
    }
    func maskIntervals(row:Int)->[Double] {
        if let rows=maskIntervalRowsNormalized,rows.indices.contains(row) {return rows[row]}
        guard let spans=maskSpansNormalized,row>=0,row*2+1<spans.count else{return []}
        return [spans[row*2],spans[row*2+1]]
    }
    static func rect(_ r: [Double], page: CGRect) -> CGRect {
        CGRect(x: r[0] * page.width, y: r[1] * page.height, width: r[2] * page.width, height: r[3] * page.height)
    }
    func allows(_ paint: CGRect, page: CGRect) -> Bool {
        guard Self.rect(allowedRectNormalized, page: page).insetBy(dx: 0.01, dy: 0.01)
            .insetBy(dx: -0.02, dy: -0.02).contains(paint) else { return false }
        guard insideBalloon else { return !newlyOverlapsBalloon(paint,page:page) }
        guard let r = maskRectNormalized, let spans = maskSpansNormalized else { return false }
        let region = Self.rect(r, page: page)
        guard region.contains(paint), !paint.isEmpty else { return false }
        let count = spans.count / 2, step = region.height / CGFloat(count)
        let a = max(0, Int(floor((paint.minY - region.minY) / step)))
        let b = min(count - 1, Int(ceil((paint.maxY - region.minY) / step)) - 1)
        return a <= b && (a...b).allSatisfy { row in
            let intervals=maskIntervals(row:row)
            return stride(from:0,to:intervals.count,by:2).contains { k in
                paint.minX>=CGFloat(intervals[k])*page.width && paint.maxX<=CGFloat(intervals[k+1])*page.width
            }
        }
    }
    /// Safe free-axis intervals at an exact shared cross-axis anchor. Feeding
    /// these into joint wrapping prevents a later collision repair from turning
    /// one neighbour into a needlessly narrow column. Source exceptions apply
    /// only to the actual original rectangle, never a previous translated box.
    func exteriorPackingIntervals(crossStart:CGFloat,crossExtent:CGFloat,horizontal:Bool,page:CGRect)->[(CGFloat,CGFloat)] {
        let capacity=Self.rect(allowedRectNormalized,page:page)
        let near=horizontal ? capacity.minY:capacity.minX,far=horizontal ? capacity.maxY:capacity.maxX
        guard crossStart>=near,crossStart+crossExtent<=far,crossExtent>0 else{return []}
        let lower=horizontal ? capacity.minX:capacity.minY,upper=horizontal ? capacity.maxX:capacity.maxY
        guard !insideBalloon,let raw=forbiddenBalloonRectNormalized,let rows=forbiddenBalloonRowsNormalized,!rows.isEmpty else{return [(lower,upper)]}
        let mask=Self.rect(raw,page:page),step=mask.height/CGFloat(rows.count)
        let source=balloonExclusionSourceRectNormalized.map {Self.rect($0,page:page)}
        var blocks:[(CGFloat,CGFloat)]=[]
        let first=horizontal ? max(0,Int(floor((crossStart-mask.minY)/step))):0
        let last=horizontal ? min(rows.count-1,Int(ceil((crossStart+crossExtent-mask.minY)/step))-1):rows.count-1
        if first<=last {
            for row in first...last {
                let values=rows[row]
                for k in stride(from:0,to:values.count,by:2) {
                    let left=CGFloat(values[k])*page.width,right=CGFloat(values[k+1])*page.width
                    let rectangle=CGRect(x:left,y:mask.minY+CGFloat(row)*step,width:right-left,height:step)
                    var parts=[rectangle]
                    if let source {
                        let own=rectangle.intersection(source)
                        if !own.isNull,!own.isEmpty {
                            parts=[CGRect(x:left,y:rectangle.minY,width:rectangle.width,height:own.minY-rectangle.minY),
                                CGRect(x:left,y:own.maxY,width:rectangle.width,height:rectangle.maxY-own.maxY),
                                CGRect(x:left,y:own.minY,width:own.minX-left,height:own.height),
                                CGRect(x:own.maxX,y:own.minY,width:right-own.maxX,height:own.height)]
                        }
                    }
                    for part in parts where part.width>0 && part.height>0 {
                        let a=horizontal ? part.minY:part.minX,b=horizontal ? part.maxY:part.maxX
                        if crossStart<b && crossStart+crossExtent>a {
                            blocks.append((horizontal ? part.minX:part.minY,horizontal ? part.maxX:part.maxY))
                        }
                    }
                }
            }
        }
        blocks.sort {$0.0<$1.0}
        var result:[(CGFloat,CGFloat)]=[],cursor=lower
        for block in blocks {
            let a=max(lower,block.0),b=min(upper,block.1)
            guard a<b else{continue}
            if cursor<a {result.append((cursor,a))}
            cursor=max(cursor,b)
        }
        if cursor<upper {result.append((cursor,upper))}
        return result
    }
    /// Project toward the source anchor on safe segmentation spans, rather than
    /// relying on a coarse page grid that can jump to a distant empty position.
    func projectedShifts(bounds: CGRect, page: CGRect, preferred: CGPoint, font: CGFloat) -> [CGPoint] {
        let capacity=Self.rect(allowedRectNormalized,page:page)
        guard bounds.width<=capacity.width,bounds.height<=capacity.height else { return [] }
        let desired=CGPoint(x:bounds.minX+preferred.x,y:bounds.minY+preferred.y)
        var ys=[desired.y,capacity.midY-bounds.height/2,capacity.minY,capacity.maxY-bounds.height]
        for step in -4...4 { ys.append(desired.y+CGFloat(step)*max(1,font*0.25)) }
        var result:[CGPoint]=[],seen=Set<String>()
        for proposedY in ys {
            let y=min(max(ceil(capacity.minY),proposedY.rounded()),floor(capacity.maxY-bounds.height))
            var intervals:[(CGFloat,CGFloat)]=[(capacity.minX,capacity.maxX)]
            if insideBalloon,let r=maskRectNormalized,let spans=maskSpansNormalized {
                let mask=Self.rect(r,page:page),n=spans.count/2,pitch=mask.height/CGFloat(n)
                guard y>=mask.minY,y+bounds.height<=mask.maxY else { continue }
                let a=max(0,Int(floor((y-mask.minY)/pitch))),b=min(n-1,Int(ceil((y+bounds.height-mask.minY)/pitch))-1)
                guard a<=b else { continue }
                for row in a...b {
                    let values=maskIntervals(row:row)
                    var next:[(CGFloat,CGFloat)]=[]
                    for current in intervals {
                        for k in stride(from:0,to:values.count,by:2) {
                            let left=max(current.0,CGFloat(values[k])*page.width),right=min(current.1,CGFloat(values[k+1])*page.width)
                            if left+bounds.width<=right {next.append((left,right))}
                        }
                    }
                    intervals=next
                    if intervals.isEmpty {break}
                }
            }
            if !insideBalloon {
                intervals=exteriorPackingIntervals(crossStart:y,crossExtent:bounds.height,horizontal:true,page:page)
            }
            for (left,right) in intervals {
                guard ceil(left)+bounds.width<=floor(right) else {continue}
                let x=min(max(ceil(left),desired.x.rounded()),floor(right-bounds.width))
                let delta=CGPoint(x:x-bounds.minX,y:y-bounds.minY),key="\(delta.x),\(delta.y)"
                if seen.insert(key).inserted { result.append(delta) }
            }
        }
        return result
    }

    func score(font: CGFloat, frame: CGRect, source: CGRect, index: Int) -> Double {
        let ratio = min(1, Double(font) / sourceFontPixels)
        let distance = hypot(frame.midX - source.midX, frame.midY - source.midY) / CGFloat(sourceFontPixels)
        return 12 * pow(1 - ratio, 2) + Double(distance) * 0.8 + backgroundRisk[index] * 2.0 +
            (insideBalloon ? (1 - maskCoverage[index]) * 0.7 : 0) +
            max(0, Double(frame.width * frame.height / max(1, source.width * source.height)) - 1) * 0.012
    }
    static func decode(_ value: Any?) throws -> Self? {
        guard let value, !(value is NSNull) else { return nil }
        let p = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        guard p.valid else { throw NativeSourceClusterAlignment.Failure.invalidPacket }
        return p
    }
}
