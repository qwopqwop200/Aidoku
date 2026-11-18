import CoreGraphics
import Foundation

/// Combines RF text scopes with DB's original-pixel boxes before the first
/// recognizer call. RF supplies a paragraph scope; DB retains glyph ownership.
@available(iOS 18.0, *)
enum NativeOCRRFPrimaryEnsemble {
    static let policyVersion = "rf-db-primary-only-v313-joint-quality-source-retention"
    // Only the full-frame manga ingress supplies this default. Task-local
    // scope keeps concurrent non-manga and explicitly scoped reads isolated.
    @TaskLocal static var mainMangaEndpointPolicy = false
    /// Role admission is separate from endpoint geometry: an unambiguous RF
    /// effect without text support need not be sent to the first recognizer.
    static func primaryRoleRejection(_ polygon:[CGPoint],layout:NativeRFDETRLayoutResult?,
        width:Int,height:Int)->NativeRFDETRLayoutPrimitive? {
        guard mainMangaEndpointPolicy,let layout,layout.sourceWidth==width,layout.sourceHeight==height,
              width>0,height>0,polygon.count==4,NativeOCRDirectionGeometry.area(polygon)>0 else {return nil}
        guard !layout.primitives.contains(where:{
            $0.semanticClass == .text && $0.confidence>=0.5 && NativeOCRDirectionAdapters.coverage(polygon,by:$0)>=0.2
        }) else {return nil}
        return layout.primitives.filter {
            $0.semanticClass == .soundEffect && $0.confidence>=0.6 && NativeOCRDirectionAdapters.coverage(polygon,by:$0)>=0.8
        }.max(by:{$0.confidence<$1.confidence})
    }
    /// A shared fragment with neither an independent detector component nor
    /// a complete candidate needs measured support before the first read.
    /// Unknown provenance and independently observed source ink always abstain.
    static func sparseSharedPrimaryRejection(_ polygon:[CGPoint],evidence:NativeOCRDetectorSeedEvidence?,
        layout:NativeRFDETRLayoutResult?,width:Int,height:Int,hasSourceInkProof:Bool = false)->Int? {
        guard mainMangaEndpointPolicy,!hasSourceInkProof,let evidence,evidence.isValid,
              evidence.ownershipVersion==2,evidence.completeCCScan==true,
              evidence.components.isEmpty,evidence.candidateComponents?.isEmpty==true,
              let shared=evidence.ambiguousComponents,!shared.isEmpty,
              evidence.sourceWidth==width,evidence.sourceHeight==height,
              let layout,layout.sourceWidth==width,layout.sourceHeight==height,
              polygon.count==4,NativeOCRDirectionGeometry.area(polygon)>0,
              polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.x>=0 && $0.y>=0 &&
                $0.x<=CGFloat(width) && $0.y<=CGFloat(height)}) else {return nil}
        guard !layout.primitives.contains(where:{$0.semanticClass == .text && $0.confidence>=0.25 &&
            NativeOCRDirectionAdapters.coverage(polygon,by:$0)>=0.2}) else {return nil}
        let sx=CGFloat(width)/CGFloat(evidence.mapFullWidth),sy=CGFloat(height)/CGFloat(evidence.mapFullHeight)
        var measured=Set<Int>()
        for component in shared {for run in component.runs {for x in run.x..<(run.x+run.count) {
            let point=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
            if NativeOCRDirectionGeometry.contains(polygon,point) {
                measured.insert(run.y*evidence.mapFullWidth+x)
                if measured.count>=8 {return nil}
            }
        }}}
        return measured.count
    }

    static var refinesEndpointInk: Bool {
        if let override=ProcessInfo.processInfo.environment["AIDOKU_OCR_ENDPOINT_INK_REFINEMENT"] {
            return override == "1"
        }
        return mainMangaEndpointPolicy
    }
    static var endpointCompletionMode: String? {
        ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_ENDPOINT_COMPLETION"] ??
            (mainMangaEndpointPolicy ? "db+pixel":nil)
    }
    static var sourceAlignedColumnsEnabled: Bool {
        if let override=ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_LANE_GAP"] {
            return override == "1"
        }
        return mainMangaEndpointPolicy
    }
    // Enabled paths use one local kernel at every angle. Historical world-axis
    // controls require an explicit disabled-generalization switch.
    static func oriented(_ path: String) -> Bool {
        ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_ORIENTED_" + path] != "0"
    }

    struct EndpointCrop {
        let polygon: [CGPoint]
        let baseline: [CGPoint]?
        let pixelProof: [CGPoint]?
        let pixelInkProof: [CGPoint]?
        let terminalProof: [CGPoint]?
        let continuationPeers: Set<Int>
        var measuredTrim = false
        var pointTerminalProof: [CGPoint]? = nil
    }

    /// One production geometry kernel, shared by the recognizer ingress and
    /// the host's model-free planning audit. No reads or labels enter here.
    static func recognitionCrop(index: Int, boxes: [NativeCoreMLDetectionBox],
                                layout: NativeRFDETRLayoutResult?, frame: NativeOCRRGBAFrame,
                                probability: NativeMainEnsembleOCRProbability.Sample?,
                                pixelThreshold: Double, mode: String?, inkStyles: [EndpointInkStyle?]? = nil,
                                groups: [Group] = [], trimAudit:(([String:Any])->Void)? = nil) -> EndpointCrop? {
        guard boxes.indices.contains(index), boxes[index].polygon.count == 4 else { return nil }
        let box = boxes[index]
        if refinesEndpointInk, let group=groups.first(where:{ $0.index == index }) {
            let members=group.members.compactMap { member -> EndpointCrop? in
                guard member != index,boxes.indices.contains(member),
                      !groups.contains(where:{ $0.index == member }) else { return nil }
                return recognitionCrop(index:member,boxes:boxes,layout:layout,frame:frame,
                    probability:probability,pixelThreshold:pixelThreshold,mode:mode,inkStyles:inkStyles)
            }
            if members.count == group.members.count,let combined=groupedEndpointCrop(base:box.polygon,members:members) {
                var polygon=combined.polygon,proof=combined.terminalProof,pointProof:[CGPoint]?
                for member in group.members {
                    // A narrow terminal detector may own only the upright
                    // stem of a corner. Resolve its complete cap in the
                    // already established whole-column frame, using each
                    // member's original ink evidence. Group members are not
                    // foreign words; all other private ink remains a barrier.
                    var scoped=boxes
                    scoped[member] = .init(polygon:combined.polygon,score:boxes[member].score,
                        detectorSeedEvidence:boxes[member].detectorSeedEvidence)
                    if let cap=neutralOutlineTerminalProof(index:member,boxes:scoped,frame:frame,
                        probability:probability,pixelThreshold:pixelThreshold,
                        continuationPeers:Set(group.members),inkStyle:inkStyles?[member] ?? nil,audit:trimAudit) {
                        polygon=combiningEndpointGrowth(base:polygon,supplement:cap,minimumChange:0)
                        proof=proof.map { combiningEndpointGrowth(base:$0,supplement:cap,minimumChange:0) } ?? cap
                    }
                    if let train=compactInkTrainTerminal(index:member,boxes:boxes,frame:frame,
                        inkStyle:inkStyles?[member] ?? nil,allowingPeers:Set(group.members),sourceWindow:combined.polygon,audit:trimAudit) {
                        polygon=combiningEndpointGrowth(base:polygon,supplement:train,minimumChange:0)
                        proof=proof.map { combiningEndpointGrowth(base:$0,supplement:train,minimumChange:0) } ?? train
                        pointProof=pointProof.map { combiningEndpointGrowth(base:$0,supplement:train,minimumChange:0) } ?? train
                    }
                }
                trimAudit?(["groupMemberMeasuredCrops":group.members,"groupMemberMeasuredPolygon":polygon.map { ["x":$0.x,"y":$0.y] }])
                return .init(polygon:polygon,baseline:combined.baseline,pixelProof:polygon,
                    pixelInkProof:polygon,terminalProof:proof,continuationPeers:Set(group.members),pointTerminalProof:pointProof)
            }
        }
        let completed: [CGPoint]?
        var baseline: [CGPoint]?
        var pixelProof: [CGPoint]?
        var pixelInkProof: [CGPoint]?
        var sourceTerminalProof:[CGPoint]?
        var additionalNeutralCorner=false
        var pointTerminalProof:[CGPoint]?
        var confirmedSourcePeers=Set<Int>()
        var detectorSupportedCrop:[CGPoint]?
        if mode == "pixel" {
            completed = pixelEndpointCompletion(index: index, boxes: boxes, layout: layout, frame: frame, probability:probability,audit:trimAudit,inkStyles: inkStyles,
                terminalObserver:{ sourceTerminalProof=$0 },continuationObserver:{ confirmedSourcePeers.insert($0) })
        } else if mode == "db" || mode == "db+pixel" {
            let db = supportedEndpointCompletion(index: index, boxes: boxes, layout: layout,
                width: frame.width, height: frame.height, probability: probability, pixelThreshold: pixelThreshold)
            detectorSupportedCrop=db
            if refinesEndpointInk, mode == "db+pixel" {
                let oldDB = supportedEndpointCompletion(index: index, boxes: boxes, layout: layout,
                    width: frame.width, height: frame.height, probability: probability,
                    pixelThreshold: pixelThreshold, refineInk: false)
                let oldPixels = oldDB == nil ? pixelEndpointCompletion(index: index,
                    boxes: boxes, layout: layout, frame: frame, probability:probability,refineInk: false, inkStyles: inkStyles) : nil
                let base = oldDB ?? oldPixels ?? box.polygon
                baseline = base
                let pixels = pixelEndpointCompletion(index: index, boxes: boxes,
                    layout: layout, frame: frame, probability:probability,terminalOnly: db != nil,audit:trimAudit,inkStyles: inkStyles,
                    inkObserver: { pixelInkProof=$0 },terminalObserver:{ sourceTerminalProof=$0 },continuationObserver:{ confirmedSourcePeers.insert($0) })
                pixelProof = pixels
                let proposed = db.map { combiningEndpointGrowth(base: $0, supplement: pixels) } ?? pixels ?? box.polygon
                let gridStep = probability.map {
                    max(CGFloat(frame.width)/CGFloat(max(1,$0.resizedWidth)),
                        CGFloat(frame.height)/CGFloat(max(1,$0.resizedHeight)))
                } ?? 1
                completed = replacingEndpointExtent(base: base, proposal: proposed,
                    minimumChange: max(2,ceil(gridStep)+1))
            } else {
                completed = db ?? (mode == "db+pixel" ?
                    pixelEndpointCompletion(index: index, boxes: boxes, layout: layout, frame: frame, probability:probability,inkStyles: inkStyles) : nil)
            }
        } else if mode == "1" {
            completed = endpointCompletion(index: index, boxes: boxes, layout: layout,
                width: frame.width, height: frame.height)
        } else { completed = nil }
        var candidate=completed ?? box.polygon
        if refinesEndpointInk,mode == "pixel" || mode == "db+pixel",
           let neutral=neutralOutlineTerminalProof(index:index,boxes:boxes,frame:frame,
                detectorSupport:detectorSupportedCrop,probability:probability,pixelThreshold:pixelThreshold,
                continuationPeers:confirmedSourcePeers,inkStyle:inkStyles?[index] ?? nil,audit:trimAudit,
                additionalCornerObserver:{ _ in additionalNeutralCorner=true }) {
            // This is an observed, source-linked cap, not grid sampling slack.
            candidate=combiningEndpointGrowth(base:candidate,supplement:neutral,minimumChange:0)
            sourceTerminalProof=sourceTerminalProof.map {
                combiningEndpointGrowth(base:$0,supplement:neutral,minimumChange:0)
            } ?? neutral
            pixelProof=pixelProof.map { combiningEndpointGrowth(base:$0,supplement:neutral) } ?? neutral
            pixelInkProof=pixelInkProof.map { combiningEndpointGrowth(base:$0,supplement:neutral) } ?? neutral
        }
        if refinesEndpointInk,mode == "pixel" || mode == "db+pixel",
           let train=compactInkTrainTerminal(index:index,boxes:boxes,frame:frame,inkStyle:inkStyles?[index] ?? nil,audit:trimAudit) {
            candidate=combiningEndpointGrowth(base:candidate,supplement:train,minimumChange:0)
            sourceTerminalProof=sourceTerminalProof.map { combiningEndpointGrowth(base:$0,supplement:train,minimumChange:0) } ?? train
            pointTerminalProof=train
        }
        let trimmed=trimmingEndpointPadding(index:index,boxes:boxes,polygon:candidate,layout:layout,
            frame:frame,inkStyles:inkStyles,audit:trimAudit)
        var finalPolygon=preservingRecoveredTerminal(trimmed:trimmed,candidate:candidate,
            original:box.polygon,proof:sourceTerminalProof,audit:trimAudit)
        if additionalNeutralCorner,let baseline {
            finalPolygon=preservingMixedEndpointSource(baseline:baseline,candidate:finalPolygon,
                frame:frame,inkStyle:inkStyles?[index] ?? nil)
        }
        if refinesEndpointInk, mode == "pixel" || mode == "db+pixel",
           ProcessInfo.processInfo.environment["AIDOKU_OCR_CLIPPED_EDGE_INK"] == "1",
           let completed = completingClippedEndpointInk(index:index,boxes:boxes,polygon:finalPolygon,
                frame:frame,inkStyle:inkStyles?[index] ?? nil,audit:trimAudit) {
            finalPolygon=completed
            sourceTerminalProof=sourceTerminalProof.map {
                combiningEndpointGrowth(base:$0,supplement:completed,minimumChange:0)
            } ?? completed
            pixelInkProof=pixelInkProof.map {
                combiningEndpointGrowth(base:$0,supplement:completed,minimumChange:0)
            } ?? completed
        }
        if mode == "pixel" || mode == "db+pixel" {
            finalPolygon=fittingPrivateInkWidth(index:index,boxes:boxes,polygon:finalPolygon,
                layout:layout,frame:frame,audit:trimAudit)
            finalPolygon=completingPrivateNormalInk(index:index,boxes:boxes,polygon:finalPolygon,
                layout:layout,frame:frame,inkStyle:inkStyles?[index] ?? nil,audit:trimAudit)
        }
        return .init(polygon: finalPolygon,baseline:baseline,
            pixelProof: pixelProof, pixelInkProof: pixelInkProof,terminalProof:sourceTerminalProof,continuationPeers:confirmedSourcePeers,measuredTrim:finalPolygon != candidate &&
                !retainsOriginalReadingSpan(candidate:finalPolygon,baseline:candidate),pointTerminalProof:pointTerminalProof)
    }

    /// Finish a foreground component physically cut by the current crop edge.
    /// This measures a small connected cap, not another glyph or RF padding.
    /// The private detector palette is the only colour prior; peer private ink
    /// and a component that leaves the observation window both veto growth.
    static func completingClippedEndpointInk(index:Int,boxes:[NativeCoreMLDetectionBox],polygon:[CGPoint],
        frame:NativeOCRRGBAFrame,inkStyle:EndpointInkStyle?,audit:(([String:Any])->Void)? = nil)->[CGPoint]? {
        guard boxes.indices.contains(index),boxes[index].score >= 0.8,
              let own=boxes[index].detectorSeedEvidence,own.isValid,
              own.sourceWidth == frame.width,own.sourceHeight == frame.height,
              let style=inkStyle,!style.colors.isEmpty,let basis=EndpointFrame(polygon),
              basis.rect.width >= 6,basis.rect.height >= basis.rect.width*2 else { return nil }
        let width=basis.rect.width,margin=max(2,Int(ceil(width*0.1)))
        let columns=Int(ceil(width))+margin*2,inward=max(4,Int(ceil(width*0.6)))
        let outward=max(3,Int(ceil(width*0.35))),rows=inward+outward
        guard columns*rows <= 131_072 else { return nil }
        var first=basis.rect.minY,last=basis.rect.maxY,accepted=0
        for direction in [-1,1] {
            let edge=direction < 0 ? basis.rect.minY:basis.rect.maxY
            let start=direction < 0 ? edge-CGFloat(outward):edge-CGFloat(inward)
            let boundary=direction < 0 ? outward:inward
            var privateCells=[Bool](repeating:false,count:columns*rows)
            let sx=CGFloat(frame.width)/CGFloat(own.mapFullWidth)
            let sy=CGFloat(frame.height)/CGFloat(own.mapFullHeight)
            let rx=(abs(basis.across.x)*sx+abs(basis.across.y)*sy)/2
            let ry=(abs(basis.along.x)*sx+abs(basis.along.y)*sy)/2
            for component in own.components { for run in component.runs {
                for x in run.x..<(run.x+run.count) {
                    let world=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                    guard NativeOCRDirectionGeometry.contains(boxes[index].polygon,world) else { continue }
                    let p=basis.project(world)
                    let xx=p.x-basis.rect.minX+CGFloat(margin),yy=p.y-start
                    let x0=max(0,Int(floor(xx-rx))),x1=min(columns,Int(ceil(xx+rx)))
                    let y0=max(0,Int(floor(yy-ry))),y1=min(rows,Int(ceil(yy+ry)))
                    if x0 < x1,y0 < y1 {
                        for y in y0..<y1 { for x in x0..<x1 { privateCells[y*columns+x]=true } }
                    }
                }
            } }
            for colour in style.colors where colour.count == 3 {
                var mask=[UInt8](repeating:0,count:columns*rows),rim=0,rimSamples=0
                for y in 0..<rows { for x in 0..<columns {
                    let world=basis.restore(.init(x:basis.rect.minX+CGFloat(x-margin)+0.5,
                        y:start+CGFloat(y)+0.5))
                    let xx=Int(floor(world.x)),yy=Int(floor(world.y))
                    guard xx >= 0,yy >= 0,xx < frame.width,yy < frame.height else { continue }
                    let offset=yy*frame.bytesPerRow+xx*4
                    let distance=max(abs(Int(frame.bytes[offset])-colour[0]),
                        abs(Int(frame.bytes[offset+1])-colour[1]),abs(Int(frame.bytes[offset+2])-colour[2]))
                    if distance <= 32 { mask[y*columns+x]=1 }
                    if x < margin || x >= columns-margin {
                        rimSamples+=1;if distance <= 32 { rim+=1 }
                    }
                } }
                // A colour that also paints the lateral paper/artwork is not
                // independently measured foreground in this small window.
                guard rimSamples > 0,rim*5 <= rimSamples else { continue }
                for seed in mask.indices where mask[seed] == 1 {
                    var queue=[seed],cursor=0,left=columns,right=0,top=rows,bottom=0,inside=0,outside=0,owned=0
                    mask[seed]=0
                    while cursor < queue.count {
                        let cell=queue[cursor];cursor+=1
                        let x=cell%columns,y=cell/columns
                        left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                        let external=direction < 0 ? y < boundary:y >= boundary
                        if external { outside+=1 } else { inside+=1 }
                        if privateCells[cell] { owned+=1 }
                        for dy in -1...1 { for dx in -1...1 {
                            let xx=x+dx,yy=y+dy
                            guard xx >= 0,yy >= 0,xx < columns,yy < rows else { continue }
                            let next=yy*columns+xx
                            if mask[next] == 1 { mask[next]=0;queue.append(next) }
                        } }
                    }
                    guard outside >= 2,inside >= max(4,Int(ceil(width*0.12))),owned >= 2,
                          left > 0,right < columns-1,
                          direction < 0 ? top > 0:bottom < rows-1 else { continue }
                    let extent=direction < 0 ? start+CGFloat(top):start+CGFloat(bottom+1)
                    let growth=direction < 0 ? edge-extent:extent-edge
                    guard growth > 0.5,growth <= CGFloat(outward-1) else { continue }
                    if direction < 0 { first=min(first,extent-1) } else { last=max(last,extent+1) }
                    audit?(["clippedEdgeComponentPrivatePixels":owned])
                    accepted+=1
                }
            }
        }
        guard accepted > 0 else { return nil }
        let ownSeeds=Set(own.components.map(\.seed))
        for peer in boxes.indices where peer != index {
            let bounds=basis.bounds(boxes[peer].polygon)
            guard bounds.maxX >= basis.rect.minX,bounds.minX <= basis.rect.maxX,
                  bounds.maxY >= first,bounds.minY <= last,
                  let evidence=boxes[peer].detectorSeedEvidence,evidence.isValid,
                  evidence.sourceWidth == frame.width,evidence.sourceHeight == frame.height else { continue }
            let sx=CGFloat(frame.width)/CGFloat(evidence.mapFullWidth)
            let sy=CGFloat(frame.height)/CGFloat(evidence.mapFullHeight)
            for component in evidence.components where !ownSeeds.contains(component.seed) {
                for run in component.runs { for x in run.x..<(run.x+run.count) {
                    let p=basis.project(.init(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy))
                    if p.x >= basis.rect.minX,p.x <= basis.rect.maxX,p.y >= first,p.y <= last,
                       p.y < basis.rect.minY || p.y > basis.rect.maxY {
                        audit?(["clippedEdgeInkRejectedPeer":peer]);return nil
                    }
                } }
            }
        }
        let result=polygon.map { point -> CGPoint in
            var p=basis.project(point)
            let weight=(p.y-basis.rect.minY)/basis.rect.height
            p.y+=(1-weight)*(first-basis.rect.minY)+weight*(last-basis.rect.maxY)
            return basis.restore(p)
        }
        guard result.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height) }) else { return nil }
        audit?(["clippedEdgeInkComponents":accepted,"clippedEdgeInkHead":basis.rect.minY-first,
                "clippedEdgeInkTail":last-basis.rect.maxY])
        return result
    }

    /// Supplemental column reads use the same measured endpoint extents as
    /// their constituent reads. The old group enclosure remains a separately
    /// recognized control, never a substitute for actual source foreground.
    static func groupedEndpointCrop(base:[CGPoint],members:[EndpointCrop])->EndpointCrop? {
        guard members.count >= 2,let frame=EndpointFrame(base),
              members.allSatisfy({ $0.polygon.count == 4 && $0.polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { return nil }
        let extent=members.reduce(CGRect.null) { $0.union(frame.bounds($1.polygon)) }
        guard !extent.isNull,extent.height > 0,
              extent.width <= frame.rect.width*1.5 else { return nil }
        let proposal=[CGPoint(x:frame.rect.minX,y:extent.minY),CGPoint(x:frame.rect.maxX,y:extent.minY),
                      CGPoint(x:frame.rect.maxX,y:extent.maxY),CGPoint(x:frame.rect.minX,y:extent.maxY)].map(frame.restore)
        let polygon=replacingEndpointExtent(base:base,proposal:proposal,minimumChange:0)
        let proven=members.contains { $0.terminalProof != nil }
        return .init(polygon:polygon,baseline:base,pixelProof:polygon,pixelInkProof:polygon,
            terminalProof:proven ? polygon:nil,continuationPeers:[])
    }

    /// Reconcile an existing same-column group from its actual independent
    /// member reads after a terminal recovery. Return order and geometry only;
    /// text/tokens must come unchanged from those real recognizer outputs.
    static func observedTerminalGroup(base:[CGPoint],members:[[CGPoint]],grid:CGFloat)->(polygon:[CGPoint],order:[Int])? {
        guard (2...4).contains(members.count),let f=EndpointFrame(base),f.rect.width >= 6 else { return nil }
        let epsilon=max(2,grid),uncertainty=max(CGFloat.pi/36,atan2(epsilon*2,f.rect.width))
        var extents:[CGRect]=[]
        for member in members {
            guard let axis=EndpointFrame(member),
                  abs(axis.along.x*f.along.x+axis.along.y*f.along.y) >= cos(uncertainty*2) else { return nil }
            let r=f.bounds(member)
            guard r.width >= f.rect.width*0.5,r.width <= f.rect.width*1.5,
                  abs(r.midX-f.rect.midX) <= f.rect.width*0.3 else { return nil }
            extents.append(r)
        }
        let order=extents.indices.sorted { extents[$0].minY < extents[$1].minY }
        for (a,b) in zip(order,order.dropFirst()) {
            let gap=extents[b].minY-extents[a].maxY
            guard gap >= -epsilon*2,gap <= max(extents[a].width,extents[b].width)*1.5 else { return nil }
        }
        let first=extents.map(\.minY).min()!,last=extents.map(\.maxY).max()!
        guard first >= f.rect.minY-epsilon*2,first <= f.rect.minY+f.rect.width*0.5,
              last > f.rect.maxY+epsilon else { return nil }
        let polygon=NativeOCRDirectionGeometry.corners(CGRect(x:f.rect.minX,y:f.rect.minY,
            width:f.rect.width,height:last-f.rect.minY)).map(f.restore)
        return (polygon,order)
    }

    /// A repeated, closed ink-point train witnesses its own pitch and stroke
    /// scale. It can complete a cropped punctuation run without requiring a
    /// second print colour or treating RF paper pixels as detector ownership.
    static func compactInkTrainTerminal(index:Int,boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        inkStyle:EndpointInkStyle?,allowingPeers:Set<Int> = [],sourceWindow:[CGPoint]? = nil,
        audit:(([String:Any])->Void)? = nil,observedSource:[CGPoint]? = nil,
        unreadPeers:Set<Int> = [],pointSourceObserver:((Set<Int>)->Void)? = nil,
        protectingObservedPoints:Bool = false,allowTerminalCap:Bool = false)->[CGPoint]? {
        guard boxes.indices.contains(index),let style=inkStyle,!style.colors.isEmpty else { return nil }
        if protectingObservedPoints && (observedSource == nil || sourceWindow == nil) { return nil }
        var result:[CGPoint]?
        var pointSources=Set<Int>()
        // Outlined point trains can share one continuous border. Their private
        // fill still consists of separate, regularly spaced closed components.
        // Test each source-established ink colour with the same ownership kernel.
        for colour in style.colors {
            if let candidate=compactInkTrainTerminalColour(index:index,boxes:boxes,frame:frame,
                colour:colour,allowingPeers:allowingPeers,sourceWindow:sourceWindow,audit:audit,observedSource:observedSource,unreadPeers:unreadPeers,
                pointSourceObserver:{pointSources.formUnion($0)},trimBounds:protectingObservedPoints ? observedSource:nil,
                allowTerminalCap:allowTerminalCap) {
                result=result.map { combiningEndpointGrowth(base:$0,supplement:candidate,minimumChange:0) } ?? candidate
            }
        }
        if result == nil || style.colors.allSatisfy({ c in
            c.count==3 && style.colors[0].count==3 && zip(c,style.colors[0]).map({abs($0-$1)}).max()! <= 48
        }) {
            var counters:[[Int]]=[]
            for colour in style.colors where !counters.contains(where:{
                $0.count==3 && colour.count==3 && zip($0,colour).map({abs($0-$1)}).max()! <= 48
            }) {
                counters.append(colour)
                // A closed counter can be paper. Its bounded topology and
                // repeated, source-rooted pitch supply the point proof; this
                // does not classify its RGB as foreground ink.
                if let candidate=compactInkTrainTerminalColour(index:index,boxes:boxes,frame:frame,
                    colour:colour,allowingPeers:allowingPeers,sourceWindow:sourceWindow,audit:audit,enclosedCounters:true,observedSource:observedSource,unreadPeers:unreadPeers,
                    pointSourceObserver:{pointSources.formUnion($0)},trimBounds:protectingObservedPoints ? observedSource:nil,
                    allowTerminalCap:allowTerminalCap) {
                    result=result.map { combiningEndpointGrowth(base:$0,supplement:candidate,minimumChange:0) } ?? candidate
                }
            }
        }
        if protectingObservedPoints,let result,let observedSource,let sourceWindow,let f=EndpointFrame(observedSource) {
            let proof=f.bounds(result),cut=f.bounds(sourceWindow)
            return resizingReadSpan(observedSource,head:max(f.rect.minY,min(cut.minY,proof.minY)),
                tail:min(f.rect.maxY,max(cut.maxY,proof.maxY)))
        }
        if result != nil { pointSourceObserver?(pointSources) }
        return result
    }

    private static func compactInkTrainTerminalColour(index:Int,boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        colour:[Int],allowingPeers:Set<Int>,sourceWindow:[CGPoint]?,audit:(([String:Any])->Void)?,
        enclosedCounters:Bool=false,searchGlyphs:CGFloat=4,observedSource:[CGPoint]? = nil,
        unreadPeers:Set<Int> = [],pointSourceObserver:((Set<Int>)->Void)? = nil,trimBounds:[CGPoint]? = nil,
        allowTerminalCap:Bool = false)->[CGPoint]? {
        guard boxes.indices.contains(index),let basis=EndpointFrame(sourceWindow ?? boxes[index].polygon),
              let evidence=boxes[index].detectorSeedEvidence,evidence.isValid,
              evidence.sourceWidth==frame.width,evidence.sourceHeight==frame.height,
              colour.count==3 else { return nil }
        let glyph=basis.rect.width
        guard glyph >= 6,basis.rect.height >= glyph*0.65 else { return nil }
        let margin=Int(ceil(glyph*0.5)),columns=Int(ceil(glyph))+margin*2
        let start=floor(basis.rect.minY-glyph*searchGlyphs),rows=Int(ceil(basis.rect.maxY+glyph*searchGlyphs-start))
        guard rows > 0,columns > 0,columns <= 524_288/rows else { return nil }
        func rgb(_ y:Int,_ x:Int)->[Int]? {
            let w=basis.restore(.init(x:basis.rect.minX+CGFloat(x-margin)+0.5,y:start+CGFloat(y)+0.5))
            let xx=Int(floor(w.x)),yy=Int(floor(w.y))
            guard xx >= 0,xx < frame.width,yy >= 0,yy < frame.height else { return nil }
            let i=yy*frame.bytesPerRow+xx*4
            return [Int(frame.bytes[i]),Int(frame.bytes[i+1]),Int(frame.bytes[i+2])]
        }
        let sx=CGFloat(frame.width)/CGFloat(evidence.mapFullWidth),sy=CGFloat(frame.height)/CGFloat(evidence.mapFullHeight)
        var anchors:[CGPoint]=[],residuals:[Int]=[]
        // A retained word can already include a narrowly shared DB component
        // crossing its clipped raw boundary. Sample that established component
        // only inside the actual read. This grants RGB sampling, never new
        // ownership or permission to use a broad neighboring component.
        let observedSharedSeeds=observedSource.map {
            NativeOCRContextualColumnRecovery.sharedContinuationSeeds(evidence:evidence,
                source:boxes[index].polygon,reference:$0)
        } ?? []
        let samplingParts=evidence.components+(observedSource == nil ? []:
            (evidence.ambiguousComponents ?? [])+(evidence.candidateComponents ?? []).map(\.component))
        var sampledCells=Set<Int>()
        for component in samplingParts { for run in component.runs { for x in run.x..<(run.x+run.count) {
            let world=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
            guard (NativeOCRDirectionGeometry.contains(boxes[index].polygon,world) ||
                   observedSharedSeeds.contains(component.seed)),
                  observedSource.map({NativeOCRDirectionGeometry.contains($0,world)}) ?? true,
                  sampledCells.insert(run.y*evidence.mapFullWidth+x).inserted else { continue }
            let p=basis.project(world),xx=Int(floor(p.x-basis.rect.minX))+margin,yy=Int(floor(p.y-start))
            guard let c=rgb(yy,xx) else { continue }
            let d=zip(c,colour).map { abs($0-$1) }.max()!
            if d <= 48 { anchors.append(p);residuals.append(d) }
        } } }
        audit?(["pointColour":colour,"pointAnchors":anchors.count,"pointCounters":enclosedCounters])
        guard anchors.count >= 8 else { return nil }
        residuals.sort()
        let tolerance=max(8,min(32,residuals[residuals.count*9/10]))
        var mask=[UInt8](repeating:0,count:columns*rows)
        var foreground=enclosedCounters ? [UInt8](repeating:0,count:columns*rows):[]
        for y in 0..<rows { for x in 0..<columns {
            if let c=rgb(y,x) {
                let matches=zip(c,colour).map({abs($0-$1)}).max()! <= tolerance
                if matches != enclosedCounters { mask[y*columns+x]=1 }
                if enclosedCounters,matches { foreground[y*columns+x]=1 }
            }
        } }
        struct Mark { let rect:CGRect;let pixels:Int }
        var marks:[Mark]=[],queue:[Int]=[]
        let anchorCells=Set(anchors.compactMap { p -> Int? in
            let x=Int(floor(p.x-basis.rect.minX))+margin,y=Int(floor(p.y-start))
            return x >= 0 && x < columns && y >= 0 && y < rows ? y*columns+x:nil
        })
        let originalSource=basis.bounds(boxes[index].polygon)
        // A real retained word can already include a connected glyph cap that
        // DB clipped. Observe only that actual read's span; raw-only callers
        // retain the original detector limit and acquire no extra context.
        let measuredSource=observedSource.map(basis.bounds) ?? originalSource
        var observedSourceFirst:CGFloat?,observedSourceLast:CGFloat?
        func observeSource(_ r:CGRect) {
            guard r.width <= glyph*1.5,abs(r.midX-basis.rect.midX) <= glyph*0.35 else { return }
            let source=r.intersection(measuredSource)
            if !source.isNull {
                observedSourceFirst=min(observedSourceFirst ?? source.minY,source.minY)
                observedSourceLast=max(observedSourceLast ?? source.maxY,source.maxY)
            }
        }
        // Counter geometry describes the bounded paper holes. Its root still
        // comes from private-connected PRINT, with the same cap measurement
        // as the ordinary ink-component path.
        if enclosedCounters {
            for seed in anchorCells where foreground[seed] != 0 {
                queue.removeAll(keepingCapacity:true);queue.append(seed);foreground[seed]=0
                var cursor=0,x0=columns,x1 = -1,y0=rows,y1 = -1
                while cursor < queue.count {
                    let p=queue[cursor];cursor+=1;let x=p%columns,y=p/columns
                    x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                    for dy in -1...1 { for dx in -1...1 {
                        let xx=x+dx,yy=y+dy
                        guard xx >= 0,xx < columns,yy >= 0,yy < rows else { continue }
                        let n=yy*columns+xx
                        if foreground[n] != 0 { foreground[n]=0;queue.append(n) }
                    } }
                }
                if x0 > 0,x1 < columns-1,y0 > 0,y1 < rows-1 {
                    observeSource(CGRect(x:basis.rect.minX+CGFloat(x0-margin),y:start+CGFloat(y0),
                        width:CGFloat(x1-x0+1),height:CGFloat(y1-y0+1)))
                }
            }
        }
        for seed in mask.indices where mask[seed] != 0 {
            queue.removeAll(keepingCapacity:true);queue.append(seed);mask[seed]=0
            var cursor=0,x0=columns,x1 = -1,y0=rows,y1 = -1,owned=false
            while cursor < queue.count {
                let p=queue[cursor];cursor+=1;let x=p%columns,y=p/columns
                if anchorCells.contains(p) { owned=true }
                x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                for dy in -1...1 { for dx in -1...1 {
                    let xx=x+dx,yy=y+dy
                    guard xx >= 0,xx < columns,yy >= 0,yy < rows else { continue }
                    let n=yy*columns+xx
                    if mask[n] != 0 { mask[n]=0;queue.append(n) }
                } }
            }
            guard x0 > 0,x1 < columns-1,y0 > 0,y1 < rows-1 else { continue }
            let r=CGRect(x:basis.rect.minX+CGFloat(x0-margin),y:start+CGFloat(y0),
                width:CGFloat(x1-x0+1),height:CGFloat(y1-y0+1))
            guard r.width <= glyph*1.5,
                  abs(r.midX-basis.rect.midX) <= glyph*0.35 else { continue }
            if !enclosedCounters,owned { observeSource(r) }
            guard r.height <= glyph*1.6 else { continue }
            marks.append(.init(rect:r,pixels:queue.count))
        }
        guard marks.count <= 512 else { return nil }
        let dots=marks.filter { m in
            let r=m.rect
            return r.width >= 2 && r.height >= 2 && r.width <= glyph*0.4 && r.height <= glyph*0.4 &&
                r.height >= r.width*0.5 && r.height <= r.width*2 && CGFloat(m.pixels) >= r.width*r.height*0.25
        }.sorted { $0.rect.midY < $1.rect.midY }
        audit?(["pointDots":dots.count])
        guard dots.count >= 3 else { return nil }
        var candidatePointSources=Set<Int>(),acceptedPointSources=Set<Int>()
        // An unread detector may own these very dots. Only regular, measured
        // point components can establish this alias: all private cells must
        // fall in their local point footprints, never just the enlarged word.
        func pointSources(_ train:[Mark],pitch:CGFloat,cap:CGRect? = nil)->Set<Int> {
            guard observedSource != nil else { return [] }
            var result=Set<Int>()
            let extent=train.reduce(cap ?? CGRect.null) { $0.union($1.rect) }
            for j in unreadPeers.sorted() where j != index && boxes.indices.contains(j) {
                guard let peer=EndpointFrame(boxes[j].polygon),
                      abs(peer.along.x*basis.along.x+peer.along.y*basis.along.y) >= 0.98,
                      let owner=boxes[j].detectorSeedEvidence,owner.isValid,!owner.components.isEmpty,
                      owner.ownerID != evidence.ownerID else { continue }
                let r=basis.bounds(boxes[j].polygon)
                guard r.width <= glyph*(cap == nil ? 0.8:1.5),r.height >= pitch*1.5,
                      abs(r.midX-extent.midX) <= glyph*0.25,
                      (cap != nil || (r.minY >= extent.minY-pitch*0.5 && r.maxY <= extent.maxY+pitch*0.5)) else { continue }
                let dx=CGFloat(frame.width)/CGFloat(owner.mapFullWidth),dy=CGFloat(frame.height)/CGFloat(owner.mapFullHeight)
                var cells=0,inside=0
                for c in owner.components { for run in c.runs { for x in run.x..<(run.x+run.count) {
                    let p=basis.project(CGPoint(x:(CGFloat(x)+0.5)*dx,y:(CGFloat(run.y)+0.5)*dy))
                    cells+=1
                    // DB can join the print outlines between adjacent dot
                    // counters. Half a measured pitch covers that connection,
                    // while the normal band still excludes neighboring letters.
                    if train.contains(where: { $0.rect.insetBy(dx:-glyph*0.15,dy:-pitch*0.5).contains(p) }) ||
                        cap?.insetBy(dx:-glyph*0.15,dy:-pitch*0.5).contains(p) == true { inside+=1 }
                } } }
                if cells >= 4,inside*10 >= cells*9,
                   NativeOCRDetectorSeedEvidence.preservingUnion([[evidence],[owner]]) != nil { result.insert(j) }
            }
            return result
        }
        func foreign(_ rect:CGRect)->Bool {
            let r=enclosedCounters ? rect.insetBy(dx:-max(2,glyph*0.15),dy:-max(2,glyph*0.15)):rect
            let q=NativeOCRDirectionGeometry.corners(r).map(basis.restore)
            for j in boxes.indices where j != index && !allowingPeers.contains(j) && !candidatePointSources.contains(j) {
                guard let other=boxes[j].detectorSeedEvidence,other.isValid,other.ownerID != evidence.ownerID,
                      other.sourceWidth==frame.width,other.sourceHeight==frame.height,
                      NativeOCRDirectionGeometry.intersectionArea(q,boxes[j].polygon) > 0 else { continue }
                let dx=CGFloat(frame.width)/CGFloat(other.mapFullWidth),dy=CGFloat(frame.height)/CGFloat(other.mapFullHeight)
                for c in other.components { for run in c.runs { for x in run.x..<(run.x+run.count) {
                    let p=CGPoint(x:(CGFloat(x)+0.5)*dx,y:(CGFloat(run.y)+0.5)*dy)
                    if NativeOCRDirectionGeometry.contains(boxes[j].polygon,p),r.contains(basis.project(p)) {
                        audit?(["pointForeignOwner":j,"pointForeignX":x,"pointForeignY":run.y])
                        return true
                    }
                } } }
            }
            return false
        }
        var first=basis.rect.minY,last=basis.rect.maxY,accepted=0,reachesSearchEnd=false
        var normalLow=basis.rect.minX,normalHigh=basis.rect.maxX
        for i in 0..<(dots.count-2) {
            candidatePointSources=[]
            let initial=Array(dots[i...i+2]),a=initial[1].rect.midY-initial[0].rect.midY,b=initial[2].rect.midY-initial[1].rect.midY
            let pitch=(a+b)/2,diameter=initial.map { max($0.rect.width,$0.rect.height) }.sorted()[1]
            guard a > diameter,b > diameter,pitch <= glyph*0.8,abs(a-b) <= pitch*0.3 else { continue }
            let centre=initial.map { $0.rect.midX }.reduce(0,+)/3
            func compatible(_ m:Mark)->Bool {
                let d=max(m.rect.width,m.rect.height)
                return d >= diameter*0.6 && d <= diameter*1.7 && abs(m.rect.midX-centre) <= max(2,diameter*0.7)
            }
            guard initial.allSatisfy(compatible) else { continue }
            var train=initial
            for j in stride(from:i-1,through:0,by:-1) {
                // A tiny off-column component is not a missing point. Ignore
                // incompatible ink before checking the next same-column pitch.
                if !compatible(dots[j]) {
                    // Before any word has been read, a pale calibrated colour
                    // can still be paper. Only the late word-preserving route
                    // may look past an unrelated component.
                    if observedSource != nil { continue }
                    break
                }
                guard abs(train[0].rect.midY-dots[j].rect.midY-pitch) <= pitch*0.3 else { break }
                train.insert(dots[j],at:0)
            }
            if i+3 < dots.count { for j in (i+3)..<dots.count {
                if !compatible(dots[j]) {
                    // Before any word has been read, a pale calibrated colour
                    // can still be paper. Only the late word-preserving route
                    // may look past an unrelated component.
                    if observedSource != nil { continue }
                    break
                }
                guard abs(dots[j].rect.midY-train.last!.rect.midY-pitch) <= pitch*0.3 else { break }
                train.append(dots[j])
            } }
            if let trimBounds {
                // Existing periodic print inside an actual retained read is
                // not empty padding. A trim veto needs no permission to grow
                // into the rest of that train, and transfers no source owner.
                let old=basis.bounds(trimBounds)
                let covered=train.filter { mark in
                    let r=mark.rect,overlap=r.intersection(old)
                    return !overlap.isNull && overlap.width*overlap.height >= r.width*r.height*0.98 &&
                        abs(r.midX-basis.rect.midX) <= glyph*0.35
                }
                if !covered.isEmpty {
                    let cap=covered.reduce(CGRect.null) { $0.union($1.rect) }
                    if cap.minY < first-1 { first=max(old.minY,cap.minY-2);accepted+=1 }
                    if cap.maxY > last+1 { last=min(old.maxY,cap.maxY+2);accepted+=1 }
                }
                continue
            }
            candidatePointSources=pointSources(train,pitch:pitch)
            let owned=train.filter { basis.rect.contains(CGPoint(x:$0.rect.midX,y:$0.rect.midY)) }
            let singleOwnedPoint=owned.count==1 && anchors.filter { owned[0].rect.contains($0) }.count >= 2
            let ownsPoints=singleOwnedPoint || (owned.count >= 2 && owned.contains(where:{ m in anchors.contains { p in
                abs(p.x-m.rect.midX) <= glyph*0.3 && abs(p.y-m.rect.midY) <= glyph*0.5
            } }))
            // A complete glyph may be followed by a detector-missed point run.
            // Its first point must be directly rooted at the observed private
            // glyph edge; regular remote texture is not a continuation.
            // DB seeds can stop inside the final glyph. A closed source-colour
            // component attached to those seeds supplies its observed ink cap,
            // restricted to the original detector source, never crop padding.
            let anchorFirst=min(anchors.map(\.y).min()!,observedSourceFirst ?? .greatestFiniteMagnitude)
            let anchorLast=max(anchors.map(\.y).max()!,observedSourceLast ?? -.greatestFiniteMagnitude)
            let tailRoot=train.first!.rect.minY-anchorLast
            let headRoot=anchorFirst-train.last!.rect.maxY
            // Only a previously recognized word may nominate its own short,
            // closed terminal stroke before a directly adjacent point train.
            // This never widens the pre-REC detector endpoint policy.
            var bridged=false
            if observedSource != nil {
                var edge=train.first!.rect.minY
                for _ in 0..<2 {
                    let next=marks.filter { m in
                        let r=m.rect,gap=edge-r.maxY
                        // A curved narrow stroke can be wider than the DB
                        // lane's fixed fraction. Its resolved point diameter
                        // supplies the same print-scale bound at every angle.
                        return gap >= 0 && gap <= pitch*1.2 && r.width <= max(glyph*0.3,diameter*2+2) &&
                            r.height >= glyph*0.5 && r.height+2 >= r.width*3 &&
                            CGFloat(m.pixels) >= r.width*r.height*0.25 &&
                            abs(r.midX-centre) <= max(2,diameter*0.7) && !foreign(r)
                    }.max { $0.rect.maxY < $1.rect.maxY }
                    guard let next else { break }
                    if next.rect.minY <= anchorLast,next.rect.maxY >= anchorLast { bridged=true;break }
                    edge=next.rect.minY
                    let gap=edge-anchorLast
                    if gap >= 0,gap <= pitch*1.2 { bridged=true;break }
                }
            }
            let rootedAtGlyph=abs(centre-basis.rect.midX) <= glyph*0.2 &&
                ((tailRoot >= 0 && tailRoot <= pitch*1.2 &&
                    (observedSourceLast != nil || (owned.isEmpty && train.first!.rect.minY >= basis.rect.maxY-glyph*0.2))) ||
                 (headRoot >= 0 && headRoot <= pitch*1.2 &&
                    (observedSourceFirst != nil || (owned.isEmpty && train.last!.rect.maxY <= basis.rect.minY+glyph*0.2))) || bridged)
            audit?(["pointTrainRoot": ["first":train.first!.rect.minY,"last":train.last!.rect.maxY,
                "pitch":pitch,"diameter":diameter,"pointSizes":train.map{[$0.rect.width,$0.rect.height]},"centreOffset":centre-basis.rect.midX,"glyph":glyph,
                "anchorFirst":anchorFirst,"anchorLast":anchorLast,"headGap":headRoot,"tailGap":tailRoot,
                "ownsPoints":ownsPoints,"rooted":rootedAtGlyph,"late":observedSource != nil] as [String:Any]])
            guard ownsPoints || rootedAtGlyph else { continue }
            // A closed end symbol can straddle the initial observation rim.
            // Continue observing a proven, rooted train before deciding that
            // its unread detector is foreign; search edges are never caps.
            if allowTerminalCap,observedSource != nil,searchGlyphs < 16,
               start+CGFloat(rows)-train.last!.rect.maxY <= glyph*2,
               let further=compactInkTrainTerminalColour(index:index,boxes:boxes,frame:frame,
                colour:colour,allowingPeers:allowingPeers,sourceWindow:sourceWindow,audit:audit,
                enclosedCounters:enclosedCounters,searchGlyphs:searchGlyphs*2,observedSource:observedSource,
                unreadPeers:unreadPeers,pointSourceObserver:pointSourceObserver,trimBounds:trimBounds,
                allowTerminalCap:true) { return further }
            // Only a late paired, word-preserving read may nominate one
            // compact closed cap adjoining its actual periodic point run.
            // Its unread owner's cells must fit the measured points + cap;
            // an active peer remains an absolute private-ink barrier.
            let cap=allowTerminalCap && observedSource != nil ? marks.filter { m in
                let r=m.rect,gap=r.minY-train.last!.rect.maxY
                return gap >= 0 && gap <= pitch*1.2 && r.width >= diameter*2 && r.height >= diameter*2 &&
                    max(r.width,r.height) <= min(r.width,r.height)*1.5 &&
                    CGFloat(m.pixels) >= r.width*r.height*0.12 && CGFloat(m.pixels) <= r.width*r.height*0.7
            }.min { $0.rect.minY < $1.rect.minY }?.rect:nil
            candidatePointSources=pointSources(train,pitch:pitch,cap:cap)
            if let cap,foreign(cap) { continue }
            var extent=train.reduce(CGRect.null) { $0.union($1.rect) }
            if let cap {extent=extent.union(cap)}
            for direction in [-1,1] {
                let trainBoundary=direction < 0 ? extent.minY:extent.maxY
                for step in 0..<marks.count {
                    let boundary=direction < 0 ? extent.minY:extent.maxY
                    let next=marks.filter { m in
                        let gap=direction < 0 ? boundary-m.rect.maxY:m.rect.minY-boundary
                        let terminalSpan=direction < 0 ? trainBoundary-m.rect.minY:m.rect.maxY-trainBoundary
                        // A late punctuation-only completion cannot use a
                        // following full-width glyph as a terminal mark.
                        let terminalShape=observedSource == nil || (m.rect.width <= glyph*0.4 &&
                            (m.rect.height <= glyph*0.7 || m.rect.height >= m.rect.width*3))
                        return terminalShape && gap >= 0 && gap <= pitch*1.2 && (step < 2 || terminalSpan <= glyph*2) &&
                            m.rect.height >= diameter*0.7 &&
                            CGFloat(m.pixels) >= m.rect.width*m.rect.height*0.12 &&
                            abs(m.rect.midX-centre) <= glyph*0.25 && !extent.intersects(m.rect)
                    }.min { a,b in abs(a.rect.midY-boundary) < abs(b.rect.midY-boundary) }
                    guard let next, !basis.rect.contains(next.rect),!foreign(next.rect) else { break }
                    extent=extent.union(next.rect)
                }
            }
            let novel=train.filter { $0.rect.minY < basis.rect.minY || $0.rect.maxY > basis.rect.maxY }
            guard !novel.contains(where:{ foreign($0.rect) }) else { continue }
            if cap != nil {normalLow=min(normalLow,extent.minX-2);normalHigh=max(normalHigh,extent.maxX+2)}
            if extent.minY < first-1 || extent.maxY > last+1 { acceptedPointSources.formUnion(candidatePointSources) }
            if extent.minY-start <= pitch*2 || start+CGFloat(rows)-extent.maxY <= pitch*2 { reachesSearchEnd=true }
            if extent.minY < first-1 { first=extent.minY-2;accepted+=1 }
            if extent.maxY > last+1 { last=extent.maxY+2;accepted+=1 }
        }
        guard accepted > 0 else { return nil }
        candidatePointSources=acceptedPointSources
        if enclosedCounters {
            let outline=colour
            func matchingColumns(_ row:Int)->[Int] {
                (0..<columns).filter { x in rgb(row,x).map { zip($0,outline).map({abs($0-$1)}).max()! <= 32 } ?? false }
            }
            func cap(_ value:CGFloat,_ direction:Int)->CGFloat? {
                let edge=Int(floor(value-start)),inside=direction > 0 ? edge-1:edge
                let initial=matchingColumns(inside)
                guard let lo=initial.min(),let hi=initial.max() else { return nil }
                var left=lo,right=hi,observed:CGFloat?
                for step in 0..<max(2,Int(ceil(glyph*0.5))) {
                    let row=direction > 0 ? edge+step:edge-step-1
                    let points=matchingColumns(row).filter { $0 >= left-2 && $0 <= right+2 }
                    if points.isEmpty { return observed }
                    guard let a=points.min(),let b=points.max() else { return nil }
                    let band=CGRect(x:basis.rect.minX+CGFloat(a-margin),y:start+CGFloat(row),
                        width:CGFloat(b-a+1),height:1)
                    if foreign(band) { return nil }
                    left=a;right=b
                    observed=start+CGFloat(direction > 0 ? row+1:row)
                }
                // An unbounded matching paper strip supplies no observed cap.
                return nil
            }
            if first < basis.rect.minY,let cap=cap(first,-1) { first=min(first,cap) }
            if last > basis.rect.maxY,let cap=cap(last,1) { last=max(last,cap) }
        }
        let q=[CGPoint(x:normalLow,y:first),CGPoint(x:normalHigh,y:first),
               CGPoint(x:normalHigh,y:last),CGPoint(x:normalLow,y:last)].map(basis.restore)
        guard q.allSatisfy({$0.x >= 0 && $0.y >= 0 && $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)}) else { return nil }
        audit?(["compactInkTrainExtensions":accepted,"compactInkTrainStart":first,"compactInkTrainEnd":last])
        let result=normalLow < basis.rect.minX || normalHigh > basis.rect.maxX ? q:
            replacingEndpointExtent(base:sourceWindow ?? boxes[index].polygon,proposal:q,minimumChange:0)
        if reachesSearchEnd,searchGlyphs < 16,let further=compactInkTrainTerminalColour(index:index,boxes:boxes,frame:frame,
            colour:colour,allowingPeers:allowingPeers,sourceWindow:sourceWindow,audit:audit,enclosedCounters:enclosedCounters,searchGlyphs:searchGlyphs*2,observedSource:observedSource,unreadPeers:unreadPeers,
            pointSourceObserver:{acceptedPointSources.formUnion($0)},trimBounds:trimBounds,allowTerminalCap:allowTerminalCap) {
            pointSourceObserver?(acceptedPointSources)
            return combiningEndpointGrowth(base:result,supplement:further,minimumChange:0)
        }
        pointSourceObserver?(acceptedPointSources)
        return result
    }

    /// A coloured fill does not own the RGB of its neutral outline. Recover
    /// only a measured narrow terminal rooted beside private source glyphs;
    /// broad paper, remote rules and unresolved image-edge caps are excluded.
    static func neutralOutlineTerminalProof(index:Int,boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        detectorSupport:[CGPoint]? = nil,probability:NativeMainEnsembleOCRProbability.Sample? = nil,
        pixelThreshold:Double = 0.05,continuationPeers:Set<Int> = [],inkStyle:EndpointInkStyle? = nil,
        audit:(([String:Any])->Void)? = nil,neutralInkOverride:[Int]? = nil,
        additionalCornerObserver:(([CGPoint])->Void)? = nil,observedSourceInk:[CGPoint]? = nil,
        terminalInkObserver:(([CGPoint])->Void)? = nil,
        terminalMarkObserver:(([CGPoint])->Void)? = nil,recognizesExclamation:Bool = false,
        wideCornerOnly:Bool = false) -> [CGPoint]? {
        guard boxes.indices.contains(index),let basis=EndpointFrame(boxes[index].polygon),
              let evidence=boxes[index].detectorSeedEvidence,evidence.isValid,
              !evidence.components.isEmpty || observedSourceInk?.isEmpty == false,
              evidence.sourceWidth==frame.width,evidence.sourceHeight==frame.height,
              frame.bytesPerRow >= frame.width*4,frame.bytes.count >= frame.bytesPerRow*frame.height else { return nil }
        let width=basis.rect.width
        guard width >= 6,basis.rect.height > 0 else { return nil }
        let columns=Int(ceil(width)),start=floor(basis.rect.minY-width*4)
        let rows=Int(ceil(basis.rect.maxY+width*4-start))
        guard columns > 2,rows > 0,columns <= 524_288/rows else { return nil }
        func rgb(_ y:Int,_ x:Int)->[Int]? {
            let world=basis.restore(.init(x:basis.rect.minX+CGFloat(x)+0.5,y:start+CGFloat(y)+0.5))
            let xx=Int(floor(world.x)),yy=Int(floor(world.y))
            guard xx >= 0,xx < frame.width,yy >= 0,yy < frame.height else { return nil }
            let p=yy*frame.bytesPerRow+xx*4
            return [Int(frame.bytes[p]),Int(frame.bytes[p+1]),Int(frame.bytes[p+2])]
        }
        var anchors=Set<Int>()
        let sx=CGFloat(frame.width)/CGFloat(evidence.mapFullWidth),sy=CGFloat(frame.height)/CGFloat(evidence.mapFullHeight)
        for component in evidence.components { for run in component.runs { for x in run.x..<(run.x+run.count) {
            let world=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
            guard NativeOCRDirectionGeometry.contains(boxes[index].polygon,world) else { continue }
            let p=basis.project(world),xx=Int(floor(p.x-basis.rect.minX)),yy=Int(floor(p.y-start))
            if xx >= 0,xx < columns,yy >= 0,yy < rows { anchors.insert(yy*columns+xx) }
        } } }
        // A caller may supply separately certified source-colour components
        // of an already retained word. They seed the same RGB proof; they do
        // not become detector cells or change any source ownership metadata.
        for world in observedSourceInk ?? [] where NativeOCRDirectionGeometry.contains(boxes[index].polygon,world) {
            let p=basis.project(world),xx=Int(floor(p.x-basis.rect.minX)),yy=Int(floor(p.y-start))
            if xx >= 0,xx < columns,yy >= 0,yy < rows { anchors.insert(yy*columns+xx) }
        }
        guard anchors.count >= 8 else { return nil }
        struct Track {
            var top:Int;var bottom:Int;var left:Int;var right:Int
            var firstLeft:Int;var firstRight:Int;var lastLeft:Int;var lastRight:Int
            var lowCentre:CGFloat;var highCentre:CGFloat;var pixels:Int;var occupiedRows:Int
        }
        var tracks:[Track]=[],active:[Int]=[]
        var bright=[UInt8](repeating:0,count:columns*rows),measured=[Bool](repeating:false,count:rows)
        let rim=max(1,columns/10),gap=max(2,Int(ceil(width*0.1)))
        for y in 0..<rows {
            let probes=(0..<rim).flatMap { [rgb(y,$0),rgb(y,columns-1-$0)] }.compactMap { $0 }
            guard probes.count >= 2 else { continue }
            let paper=(0..<3).map { k -> Double in
                let values=probes.map { $0[k] }.sorted()
                return Double(values[values.count/2]+values[(values.count-1)/2])/2
            }
            measured[y]=true
            for x in 0..<columns {
                guard let c=rgb(y,x) else { measured[y]=false;continue }
                if c.min()! >= 224,c.max()!-c.min()! <= 32,
                   (0..<3).map({abs(Double(c[$0])-paper[$0])}).max()! >= 24 { bright[y*columns+x]=1 }
            }
            active.removeAll { y-tracks[$0].bottom > gap+1 }
            var used=Set<Int>(),x=0
            while x < columns {
                if bright[y*columns+x]==0 { x+=1;continue }
                let left=x
                while x < columns,bright[y*columns+x] != 0 { x+=1 }
                let right=x-1
                guard left > 0,x < columns,CGFloat(x-left) <= width*0.5 else { continue }
                let centre=CGFloat(left+right)/2
                var chosen:Int?,distance=CGFloat.greatestFiniteMagnitude
                for i in active where !used.contains(i) {
                    let t=tracks[i]
                    guard max(left,t.lastLeft) <= min(right,t.lastRight)+1,
                          max(centre,t.highCentre)-min(centre,t.lowCentre) <= width*0.2,
                          CGFloat(max(right,t.right)-min(left,t.left)+1) <= width*0.5 else { continue }
                    let delta=abs(centre-CGFloat(t.lastLeft+t.lastRight)/2)
                    if delta < distance { chosen=i;distance=delta }
                }
                let i:Int
                if let chosen { i=chosen }
                else {
                    guard tracks.count < 4_096 else { return nil }
                    i=tracks.count;tracks.append(.init(top:y,bottom:y,left:left,right:right,
                        firstLeft:left,firstRight:right,lastLeft:left,lastRight:right,lowCentre:centre,highCentre:centre,
                        pixels:0,occupiedRows:0));active.append(i)
                }
                tracks[i].bottom=y;tracks[i].left=min(left,tracks[i].left);tracks[i].right=max(right,tracks[i].right)
                tracks[i].lastLeft=left;tracks[i].lastRight=right
                tracks[i].pixels+=right-left+1;tracks[i].occupiedRows+=1
                tracks[i].lowCentre=min(centre,tracks[i].lowCentre);tracks[i].highCentre=max(centre,tracks[i].highCentre)
                used.insert(i)
            }
        }
        // Estimate the actual opaque outline colour beside private glyphs.
        // A vaguely pale RGB is not enough: a pink glow or a background stripe
        // can be neutral and bright while differing from the printed outline.
        let radius=max(2,min(16,Int(ceil(width*0.15)))),orderedAnchors=anchors.sorted()
        var profileCells=Set<Int>()
        let anchorStep=max(1,(orderedAnchors.count+127)/128)
        for i in stride(from:0,to:orderedAnchors.count,by:anchorStep) {
            let p=orderedAnchors[i],y=p/columns,x=p%columns
            for yy in max(0,y-radius)...min(rows-1,y+radius) where start+CGFloat(yy) >= basis.rect.minY && start+CGFloat(yy) < basis.rect.maxY {
                for xx in max(0,x-radius)...min(columns-1,x+radius) where bright[yy*columns+xx] != 0 {
                    profileCells.insert(yy*columns+xx)
                }
            }
        }
        let colours=profileCells.sorted().compactMap { rgb($0/columns,$0%columns) }
        guard colours.count >= 16 else { return nil }
        let ranked=colours.sorted { a,b in
            if a.min()! != b.min()! { return a.min()! > b.min()! }
            return b.lexicographicallyPrecedes(a)
        }
        let opaque=Array(ranked.prefix(max(1,ranked.count/4)))
        let sourceWhite=(0..<3).map { k in opaque.map { $0[k] }.sorted()[opaque.count/2] }
        let residuals=opaque.map { c in zip(c,sourceWhite).map { abs($0-$1) }.max()! }.sorted()
        let tolerance=max(8,min(16,residuals[min(residuals.count-1,residuals.count*9/10)]))
        let measuredWhiteInk=inkStyle?.colors.first.flatMap { c -> [Int]? in
            guard c.min()! >= 224,c.max()!-c.min()! <= 32,
                  zip(c,sourceWhite).map({abs($0-$1)}).max()! <= max(16,tolerance*2) else { return nil }
            return c
        }
        func matchesWhite(_ c:[Int])->Bool {
            zip(c,sourceWhite).map { abs($0-$1) }.max()! <= tolerance ||
                measuredWhiteInk.map { ink in zip(c,ink).map { abs($0-$1) }.max()! <= tolerance } == true
        }
        let sourceFraction=Double(colours.filter(matchesWhite).count)/Double(colours.count)
        // Calibrate opaque white stroke width from private source glyphs.
        // A much thinner nearby surface seam cannot inherit their cap proof.
        var sourceWhiteWidths:[Int]=[]
        for y in 0..<rows where start+CGFloat(y) >= basis.rect.minY && start+CGFloat(y) < basis.rect.maxY {
            var x=0
            while x < columns {
                guard bright[y*columns+x] != 0,let c=rgb(y,x),matchesWhite(c) else { x+=1;continue }
                let left=x
                while x < columns,bright[y*columns+x] != 0,let c=rgb(y,x),matchesWhite(c) { x+=1 }
                if left > 0,x < columns,CGFloat(x-left) <= width*0.5,
                   (left..<x).contains(where:{ profileCells.contains(y*columns+$0) }) { sourceWhiteWidths.append(x-left) }
            }
        }
        sourceWhiteWidths.sort()
        let sourceWhiteStroke=CGFloat(sourceWhiteWidths.isEmpty ? 1:sourceWhiteWidths[sourceWhiteWidths.count/4])
        let whiteIsInk=measuredWhiteInk != nil
        // A neutral printed core must occur in private source pixels across
        // multiple intrinsic glyph bands. A dark surface near one letter is
        // not enough to supply a new font-colour hypothesis.
        let measuredNeutral=inkStyle?.colors.first { colour in
            guard colour.count==3,colour.max()!-colour.min()! <= 32,
                  zip(colour,sourceWhite).map({abs($0-$1)}).max()! >= 96 else { return false }
            var count=0,bands=Set<Int>()
            for p in anchors {
                if let c=rgb(p/columns,p%columns),zip(c,colour).allSatisfy({abs($0-$1) <= 24}) {
                    count+=1;bands.insert(Int(floor((start+CGFloat(p/columns)-basis.rect.minY)/width)))
                }
            }
            return count >= 16 && bands.count >= 2
        }
        if let neutralInkOverride {
            guard let measuredNeutral,neutralInkOverride==measuredNeutral else { return nil }
        }
        func hasForeignPrivateInk(_ rect:CGRect)->Bool {
            for j in boxes.indices where j != index && !continuationPeers.contains(j) {
                guard let peer=boxes[j].detectorSeedEvidence,peer.isValid,peer.ownerID != evidence.ownerID,
                      peer.sourceWidth==frame.width,peer.sourceHeight==frame.height,
                      basis.bounds(boxes[j].polygon).intersects(rect.insetBy(dx:-max(sx,sy),dy:-max(sx,sy))) else { continue }
                let px=CGFloat(frame.width)/CGFloat(peer.mapFullWidth),py=CGFloat(frame.height)/CGFloat(peer.mapFullHeight)
                for c in peer.components { for run in c.runs { for x in run.x..<(run.x+run.count) {
                    let world=CGPoint(x:(CGFloat(x)+0.5)*px,y:(CGFloat(run.y)+0.5)*py)
                    if NativeOCRDirectionGeometry.contains(boxes[j].polygon,world),
                       rect.insetBy(dx:-max(px,py),dy:-max(px,py)).contains(basis.project(world)) { return true }
                } } }
            }
            return false
        }
        var first=basis.rect.minY,last=basis.rect.maxY,count=0
        for t in tracks where neutralInkOverride == nil && CGFloat(t.bottom-t.top+1) >= width*1.6 {
            let lo=start+CGFloat(t.top),hi=start+CGFloat(t.bottom+1)
            // An existing long stroke may start several glyphs before the
            // current crop edge. Its measured source root and continuous track
            // establish ownership; proximity of the track's start to that edge
            // is not a separate requirement.
            let head=lo < basis.rect.minY && hi >= basis.rect.minY
            let tail=hi > basis.rect.maxY && lo <= basis.rect.maxY
            guard head || tail else { continue }
            let root=head ? t.bottom:t.top,cap=head ? t.top-gap-1:t.bottom+gap+1
            guard cap >= 0,cap < rows,measured[cap],(t.left...t.right).allSatisfy({bright[cap*columns+$0]==0}) else { continue }
            let rootLeft=head ? t.lastLeft:t.firstLeft,rootRight=head ? t.lastRight:t.firstRight
            let stroke=CGFloat(t.pixels)/CGFloat(max(1,t.occupiedRows))
            guard stroke >= sourceWhiteStroke*0.5 else {
                audit?(["neutralRejectedThinTrack":stroke,"neutralSourceStroke":sourceWhiteStroke]);continue
            }
            let rootRadius=max(2,stroke)*3+max(sx,sy)
            let linked=anchors.filter { p in
                let dx=CGFloat(max(rootLeft-p%columns,0,p%columns-rootRight))
                let dy=CGFloat(p/columns-root)
                return hypot(dx,dy) <= rootRadius
            }.count
            guard linked >= 2 else { continue }
            var samples=0,matching=0
            for y in t.top...t.bottom { for x in t.left...t.right where bright[y*columns+x] != 0 {
                if let c=rgb(y,x) { samples+=1;if matchesWhite(c) { matching+=1 } }
            } }
            guard samples >= 8,Double(matching) >= Double(samples)*sourceFraction*0.75 else { continue }
            if !whiteIsInk,let sourceStyle=inkStyle,let primary=sourceStyle.colors.first,primary.count==3 {
                // A white outline cannot continue as a paper seam after its
                // printed fill has ended. Require the measured source fill
                // beside the new part of a long white track. White lettering
                // itself keeps its independent source-white stroke proof.
                let fills=sourceStyle.colors.filter { c in
                    c.count==3 && zip(c,primary).map({abs($0-$1)}).max()! <= 48
                }
                var observed=0,collared=0
                for y in t.top...t.bottom {
                    let position=start+CGFloat(y)+0.5
                    guard (head && position < basis.rect.minY) || (tail && position > basis.rect.maxY) else { continue }
                    observed+=1
                    let hasFill=(max(-radius,t.left-radius)...min(columns-1+radius,t.right+radius)).contains { x in
                        guard let c=rgb(y,x),!matchesWhite(c) else { return false }
                        return fills.contains { fill in zip(c,fill).map({abs($0-$1)}).max()! <= 32 }
                    }
                    if hasFill { collared+=1 }
                }
                guard observed >= 2,collared*2 >= observed else {
                    audit?(["neutralRejectedUncollaredTrackRows":observed,"neutralSourceFillRows":collared])
                    continue
                }
            }
            var extensions:[CGRect]=[]
            if head { extensions.append(.init(x:basis.rect.minX,y:lo,width:width,height:basis.rect.minY-lo)) }
            if tail { extensions.append(.init(x:basis.rect.minX,y:basis.rect.maxY,width:width,height:hi-basis.rect.maxY)) }
            guard !extensions.contains(where:hasForeignPrivateInk) else { continue }
            if head { first=min(first,lo-2) }
            if tail { last=max(last,hi+2) }
            count+=1
        }
        // A short mark needs independent detector support as well as source
        // colour. Link compact neutral components back to observed source ink;
        // this preserves punctuation after a dotted trail without treating an
        // isolated white speck, a broad panel, or a peer's glyph as new source.
        audit?(["neutralDetectorSupportAvailable":detectorSupport != nil,
                "neutralProbabilityAvailable":probability != nil,
                "neutralSourceWhiteSamples":colours.count])
        if let map=probability,map.sourceWidth==frame.width,map.sourceHeight==frame.height,
           map.width > 0,map.height > 0,map.width==map.resizedWidth,map.height==map.resizedHeight,
           map.region==CGRect(x:0,y:0,width:map.width,height:map.height),map.values.count==map.width*map.height,
           pixelThreshold.isFinite,pixelThreshold > 0,pixelThreshold <= 1 {
            // Small marks can fall below DB's weak threshold altogether. In
            // that case require their observed two-colour print border at
            // every link, rather than manufacturing detector support.
            let supported=detectorSupport.map(basis.bounds) ?? basis.rect.insetBy(dx:0,dy:-width*1.5)
            func borderSamples(_ cells:[(Int,Int)])->[[Int]] {
                var samples:[[Int]]=[]
                let step=max(1,(cells.count+255)/256)
                for i in stride(from:0,to:cells.count,by:step) {
                    let (y,x)=cells[i]
                    for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                        var best:[Int]?,chroma=0,bestLearned=false
                        for d in 1...radius {
                            let xx=x+dx*d,yy=y+dy*d
                            guard yy >= 0,yy < rows,let c=rgb(yy,xx) else { continue }
                            // A ray along the white stroke has not reached a
                            // border; neutral paper reached by a normal ray
                            // still counts against a matching colour collar.
                            if matchesWhite(c) { continue }
                            let value=c.max()!-c.min()!
                            let learned=neutralInkOverride.map { ink in zip(c,ink).allSatisfy { abs($0-$1) <= 24 } } ?? false
                            if best == nil || (learned && !bestLearned) || (learned==bestLearned && value > chroma) {
                                best=c;chroma=value;bestLearned=learned
                            }
                        }
                        if let best { samples.append(best) }
                    }
                }
                return samples
            }
            // A surrounding paper colour is not part of the font. The
            // companion must also occur in the source's private DB ink.
            let privateColours=anchors.sorted().compactMap { rgb($0/columns,$0%columns) }.filter { c in
                neutralInkOverride.map { ink in zip(c,ink).allSatisfy { abs($0-$1) <= 24 } } ?? (c.max()!-c.min()! >= 48)
            }
            let privateBins=Set(privateColours.map { ($0[0]/16)*256+($0[1]/16)*16+$0[2]/16 })
            let sourceBorder=borderSamples(profileCells.sorted().filter { p in
                if let c=rgb(p/columns,p%columns) { return matchesWhite(c) }
                return false
            }.map { ($0/columns,$0%columns) }).filter { privateBins.contains(($0[0]/16)*256+($0[1]/16)*16+$0[2]/16) }
            var borderBins:[Int:[[Int]]]=[:]
            for c in sourceBorder {
                borderBins[(c[0]/16)*256+(c[1]/16)*16+c[2]/16,default:[]].append(c)
            }
            let dominant=borderBins.sorted { a,b in
                a.value.count == b.value.count ? a.key < b.key : a.value.count > b.value.count
            }.first?.value ?? []
            let borderColour=dominant.isEmpty ? [] : (0..<3).map { k in dominant.map { $0[k] }.sorted()[dominant.count/2] }
            func sameBorder(_ c:[Int])->Bool {
                borderColour.count==3 && zip(c,borderColour).map { abs($0-$1) }.max()! <= 24
            }
            let sourceBorderFraction=sourceBorder.isEmpty ? 0:Double(sourceBorder.filter(sameBorder).count)/Double(sourceBorder.count)
            let hasSourceBorder=dominant.count >= 16 && sourceBorderFraction >= 0.5
            if supported.minY < basis.rect.minY-1 || supported.maxY > basis.rect.maxY+1 || hasSourceBorder || whiteIsInk {
                struct Mark { let left:Int;let right:Int;let top:Int;let bottom:Int;let cells:[Int];let companion:Bool;var linkOnly:Bool = false }
                // Observe beyond the crop sides before declaring a cap. A
                // punctuation corner can reach the crop edge; a bubble rule
                // or paper surface instead continues out of this wider view.
                let margin=min(Int(ceil(width*(wideCornerOnly ? 1.25:0.5))),max(0,(786_432/rows-columns)/2)),markColumns=columns+margin*2
                var neutral=[UInt8](repeating:0,count:markColumns*rows)
                for p in neutral.indices {
                    if let c=rgb(p/markColumns,p%markColumns-margin),matchesWhite(c) { neutral[p]=1 }
                }
                var marks:[Mark]=[],queue:[Int]=[],borderProven=Set<Int>()
                var stemDotProven=Set<Int>()
                // For white lettering, surrounding colour is paper/glow, not
                // a second ink. A closed dot can instead be witnessed by its
                // source-rooted stem at the same measured stroke weight.
                func whiteStemDot(left:Int,right:Int,top:Int,bottom:Int,pixels:Int)->Bool {
                    let w=CGFloat(right-left+1),h=CGFloat(bottom-top+1),centre=CGFloat(left+right)/2
                    audit?(["whiteDotShape":["top":start+CGFloat(top),"bottom":start+CGFloat(bottom+1),
                        "width":w,"height":h,"pixels":pixels,"sourceStroke":sourceWhiteStroke,"whiteIsInk":whiteIsInk]])
                    guard whiteIsInk,w >= sourceWhiteStroke*0.5,w <= width*0.5,
                          h >= w*0.5,h <= w*2,CGFloat(pixels) >= w*h*0.3 else { return false }
                    // Long-track grouping may bridge the stem/dot gap.
                    // Measure a contiguous stem independently of that grouping.
                    let scanLeft=max(0,left-1),scanRight=min(columns-1,right+1)
                    guard scanLeft <= scanRight else { return false }
                    for direction in [-1,1] {
                        let boundary=direction < 0 ? top:bottom
                        var y=boundary+direction,blank=0,firstRow:Int?,lastRow=boundary
                        var stemLeft=columns,stemRight = -1,mass=0,occupied=0
                        while y > 0 && y < rows-1 {
                            let xs=(scanLeft...scanRight).filter { x in
                                bright[y*columns+x] != 0 && rgb(y,x).map(matchesWhite) == true
                            }
                            if xs.isEmpty {
                                if firstRow != nil { break }
                                blank+=1
                                if CGFloat(blank) > max(2,w*1.5) { break }
                            } else {
                                if firstRow == nil { firstRow=y }
                                lastRow=y;occupied+=1;mass+=xs.count
                                stemLeft=min(stemLeft,xs.first!);stemRight=max(stemRight,xs.last!)
                            }
                            y+=direction
                        }
                        guard let firstRow else { continue }
                        let lo=min(firstRow,lastRow),hi=max(firstRow,lastRow)
                        let stroke=CGFloat(mass)/CGFloat(max(1,occupied))
                        // Original compact marks can connect a private DB
                        // anchor to the stem when DB missed an intervening dot.
                        var sourceRoots=Array(profileCells.filter { rgb($0/columns,$0%columns).map(matchesWhite) == true })
                        var rootMarks=Set<Int>(),changed=true
                        while changed {
                            changed=false
                            for i in marks.indices where !rootMarks.contains(i) {
                                let m=marks[i]
                                guard !m.companion,start+CGFloat(m.top) >= basis.rect.minY,
                                      start+CGFloat(m.bottom+1) <= basis.rect.maxY,
                                      sourceRoots.contains(where:{ p in
                                          CGFloat(max(m.top-p/columns,0,p/columns-m.bottom)) <= width*0.5 &&
                                          abs(CGFloat(p%columns)-CGFloat(m.left+m.right)/2) <= width*0.3
                                      }) else { continue }
                                let r=CGRect(x:basis.rect.minX+CGFloat(m.left),y:start+CGFloat(m.top),
                                    width:CGFloat(m.right-m.left+1),height:CGFloat(m.bottom-m.top+1))
                                guard !hasForeignPrivateInk(r) else { continue }
                                for p in m.cells {
                                    let x=p%markColumns-margin,y=p/markColumns
                                    if x >= 0,x < columns { sourceRoots.append(y*columns+x) }
                                }
                                rootMarks.insert(i);changed=true
                            }
                        }
                        // A retained exclamation may taper below the word's
                        // median stroke width. Its own compact dot supplies
                        // the scale; the contiguous stem still needs private
                        // source roots and the peer-ownership checks below.
                        let minimumStemStroke=recognizesExclamation ?
                            max(2,min(sourceWhiteStroke*0.5,w*0.5)):sourceWhiteStroke*0.5
                        let maximumDotGap=max(2,stroke*1.5,recognizesExclamation ? w*1.5:0)
                        guard CGFloat(hi-lo+1) >= max(h*2,width*0.4),stroke >= minimumStemStroke,
                              CGFloat(stemRight-stemLeft+1) <= w*1.8,
                              abs(centre-CGFloat(stemLeft+stemRight)/2) <= max(2,min(w,stroke)*0.6),
                              CGFloat(blank) <= maximumDotGap,
                              sourceRoots.contains(where:{ p in
                                  let dy=max(lo-p/columns,0,p/columns-hi)
                                  return CGFloat(dy) <= width*0.5 &&
                                      abs(CGFloat(p%columns)-CGFloat(stemLeft+stemRight)/2) <= width*0.3 &&
                                      rgb(p/columns,p%columns).map(matchesWhite) == true
                              }) else { continue }
                        if !hasForeignPrivateInk(CGRect(x:basis.rect.minX+CGFloat(stemLeft),
                            y:start+CGFloat(lo),width:CGFloat(stemRight-stemLeft+1),height:CGFloat(hi-lo+1))) { return true }
                    }
                    return false
                }

                func enclosedCompanion(left:Int,right:Int,top:Int,bottom:Int,whiteCells:[Int])->Bool {
                    guard hasSourceBorder else { return false }
                    let x0=left-margin-radius,x1=right-margin+radius,y0=max(0,top-radius),y1=min(rows-1,bottom+radius)
                    let w=x1-x0+1,h=y1-y0+1
                    guard w > 0,h > 0,w <= 65_536/h else { return false }
                    var ink=[UInt8](repeating:0,count:w*h)
                    for y in y0...y1 { for x in x0...x1 {
                        if let c=rgb(y,x),sameBorder(c) { ink[(y-y0)*w+x-x0]=1 }
                    } }
                    let white=Set(whiteCells)
                    var work:[Int]=[]
                    for seed in ink.indices where ink[seed] != 0 {
                        work.removeAll(keepingCapacity:true);work.append(seed);ink[seed]=0
                        var cursor=0,open=false,adjacent=false
                        while cursor < work.count {
                            let p=work[cursor];cursor+=1;let x=p%w,y=p/w
                            if x==0 || x==w-1 || y==0 || y==h-1 { open=true }
                            for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                                let xx=x+dx,yy=y+dy
                                for distance in 1...2 {
                                    let wx=x0+x+dx*distance+margin,wy=y0+y+dy*distance
                                    if wx >= 0,wx < markColumns,wy >= 0,wy < rows,
                                       white.contains(wy*markColumns+wx) { adjacent=true }
                                }
                                guard xx >= 0,xx < w,yy >= 0,yy < h else { continue }
                                let next=yy*w+xx
                                if ink[next] != 0 { ink[next]=0;work.append(next) }
                            }
                        }
                        if !open,adjacent,work.count >= 4 { return true }
                    }
                    return false
                }
                func companionBand(_ y:Int)->Bool {
                    let position=start+CGFloat(y)
                    // Keep the admitted middle available as a source root.
                    // Endpoint-only bands can sever a connected print border
                    // before it reaches the private detector observations.
                    return wideCornerOnly ? position >= basis.rect.minY-width*2 && position <= basis.rect.maxY+width*2:
                        abs(position-basis.rect.minY) <= width*2 || abs(position-basis.rect.maxY) <= width*2
                }
                func whiteCollar(_ cells:[Int])->Bool {
                    var observed=0,matching=0
                    let step=max(1,(cells.count+255)/256)
                    for i in stride(from:0,to:cells.count,by:step) {
                        let p=cells[i],y=p/markColumns,x=p%markColumns-margin
                        for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                            var nearest:[Int]?,error=Int.max
                            for distance in 1...radius {
                                let yy=y+dy*distance
                                guard yy >= 0,yy < rows,let c=rgb(yy,x+dx*distance),!sameBorder(c) else { continue }
                                let difference=zip(c,sourceWhite).map { abs($0-$1) }.max()!
                                if difference < error { nearest=c;error=difference }
                            }
                            if let nearest { observed+=1;if matchesWhite(nearest) { matching+=1 } }
                        }
                    }
                    return matching >= 8 && Double(matching)/Double(max(1,observed)) >= 0.6
                }
                func observedWhiteCap(_ mark:Mark,head:Bool)->CGFloat? {
                    let edge=head ? mark.top:mark.bottom,direction=head ? -1:1
                    var caps:[Int:CGFloat]=[:]
                    for cell in mark.cells where abs(cell/markColumns-edge) <= 1 {
                        let y=cell/markColumns,x=cell%markColumns-margin
                        var seenWhite=false,transition=0
                        for distance in 1...max(2,radius*2) {
                            let yy=y+direction*distance
                            guard yy >= 0,yy < rows,let c=rgb(yy,x) else { break }
                            if matchesWhite(c) { seenWhite=true;continue }
                            if seenWhite {
                                // The next coloured glyph is not a white cap.
                                if !sameBorder(c) { caps[x]=start+CGFloat(head ? yy+1:yy) }
                                break
                            }
                            if !sameBorder(c) { transition+=1;if transition > 2 { break } }
                        }
                    }
                    // An open white surface has no observed end. Distinct
                    // cross-section samples must agree on a finite collar.
                    let values=caps.values.sorted()
                    return values.count >= 2 ? values[values.count/2]:nil
                }
                func isCorner(_ mark:Mark)->Bool {
                    let w=mark.right-mark.left+1,h=mark.bottom-mark.top+1
                    // The local raster resamples a source pixel onto a tilted
                    // frame; allow its one-cell rounding uncertainty as well
                    // as the measured source stroke, never a glyph-sized pad.
                    let stroke=max(2,min(Int(ceil(sourceWhiteStroke*2))+1,min(w,h)/3))
                    guard min(w,h) >= max(4,stroke*2),mark.cells.count*3 < w*h*2 else { return false }
                    // Both arms must span a bounded right-angle glyph. A
                    // same-colour fragment of the next letter is not a cap.
                    // Work in this source's intrinsic frame at every angle.
                    for left in [true,false] { for top in [true,false] {
                        var horizontal=Set<Int>(),vertical=Set<Int>(),covered=0
                        for cell in mark.cells {
                            let x=cell%markColumns-margin,y=cell/markColumns
                            let inVertical=left ? x < mark.left+stroke:x > mark.right-stroke
                            let inHorizontal=top ? y < mark.top+stroke:y > mark.bottom-stroke
                            if inVertical { vertical.insert(y) };if inHorizontal { horizontal.insert(x) }
                            if inVertical || inHorizontal { covered+=1 }
                        }
                        if horizontal.count*4 >= w*3,vertical.count*4 >= h*3,
                           covered*10 >= mark.cells.count*9 { return true }
                    } }
                    return false
                }
                func observedPrintCollar(_ mark:Mark)->CGRect? {
                    guard hasSourceBorder else { return nil }
                    func isRim(_ c:[Int])->Bool { mark.companion ? matchesWhite(c):sameBorder(c) }
                    func isCore(_ c:[Int])->Bool { mark.companion ? sameBorder(c):matchesWhite(c) }
                    let cells=Set(mark.cells),reach=max(4,min(32,Int(ceil(width*0.3))))
                    var eligible=0,bounded=0,paint:[CGPoint]=[]
                    for cell in mark.cells {
                        let x=cell % markColumns-margin,y=cell/markColumns
                        for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                            let nx=x+margin+dx,ny=y+dy
                            if nx >= 0,nx < markColumns,ny >= 0,ny < rows,cells.contains(ny*markColumns+nx) { continue }
                            eligible+=1
                            var run:[CGPoint]=[],proven=false
                            for distance in 1...reach {
                                let xx=x+dx*distance,yy=y+dy*distance
                                guard yy >= 0,yy < rows,let c=rgb(yy,xx) else { break }
                                if isRim(c) {
                                    run.append(CGPoint(x:basis.rect.minX+CGFloat(xx)+0.5,y:start+CGFloat(yy)+0.5))
                                } else if !run.isEmpty {
                                    if !isCore(c),let next=rgb(yy+dy,xx+dx),!isCore(next),!isRim(next) {
                                        proven=run.count >= 2
                                    }
                                    break
                                } else if distance > max(2,Int(ceil(max(sx,sy)))+1) { break }
                            }
                            if proven { bounded+=1;paint+=run }
                        }
                    }
                    guard bounded >= 8,bounded*5 >= eligible*3,!paint.isEmpty else { return nil }
                    var r=CGRect(x:basis.rect.minX+CGFloat(mark.left),y:start+CGFloat(mark.top),
                        width:CGFloat(mark.right-mark.left+1),height:CGFloat(mark.bottom-mark.top+1))
                    for p in paint { r=r.union(CGRect(x:p.x-0.5,y:p.y-0.5,width:1,height:1)) }
                    return r
                }
                func appendMarks(_ input:[UInt8],companion:Bool) {
                    var neutral=input
                    for seed in neutral.indices where neutral[seed] != 0 {
                        queue.removeAll(keepingCapacity:true);queue.append(seed);neutral[seed]=0
                        var cursor=0,left=markColumns,right=0,top=rows,bottom=0
                        while cursor < queue.count {
                            let p=queue[cursor];cursor+=1;let y=p/markColumns,x=p%markColumns
                            left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                            for dy in -1...1 { for dx in -1...1 {
                                let yy=y+dy,xx=x+dx
                                guard yy >= 0,yy < rows,xx >= 0,xx < markColumns else { continue }
                                let next=yy*markColumns+xx
                                if neutral[next] != 0 { neutral[next]=0;queue.append(next) }
                            } }
                        }
                        let lo=start+CGFloat(top),hi=start+CGFloat(bottom+1)
                        let nearHead=hi >= basis.rect.minY-width*2 && lo <= basis.rect.minY+width*2
                        let nearTail=hi >= basis.rect.maxY-width*2 && lo <= basis.rect.maxY+width*2
                        let touchesBand=companion && queue.contains { p in
                            let y=p/markColumns
                            return !companionBand(y-1) || !companionBand(y+1)
                        }
                        let mark=Mark(left:left-margin,right:right-margin,top:top,bottom:bottom,cells:queue,companion:companion)
                        let compact=CGFloat(right-left+1) <= width*1.5 && CGFloat(bottom-top+1) <= width
                        // Dot-width detector crops can be narrower than a real
                        // closing corner. Its measured L shape, not this wider
                        // observation window, must establish the extra ink.
                        let corner=CGFloat(right-left+1) <= width*3 && CGFloat(bottom-top+1) <= width*1.5 && isCorner(mark)
                        let bridge=wideCornerOnly && companion && !compact && !corner && CGFloat(right-left+1) <= width*1.5 &&
                            CGFloat(bottom-top+1) <= basis.rect.height+width*2
                        if !touchesBand,queue.count >= 4,top > 0,bottom < rows-1,left > 0,right < markColumns-1,
                           compact || (wideCornerOnly && corner) || bridge,nearHead || nearTail {
                            let border=(!companion && hasSourceBorder) ? borderSamples(queue.map { ($0/markColumns,$0%markColumns-margin) }):[]
                            let matches=border.filter(sameBorder).count
                            let wrapped=matches >= 8 && Double(matches)/Double(max(1,border.count)) >= max(0.6,sourceBorderFraction*0.8)
                            // An outlined glyph encloses a compact companion fill;
                            // a bubble rule has matching blue paper on an open side.
                            var privateBridge=false
                            if bridge,hasSourceBorder {
                                // A long companion can link private source ink
                                // to a compact cap; it cannot itself grow a
                                // crop or acquire ownership. Require measured
                                // adjacency to the immutable private white ink.
                                let cells=Set(queue),roots=profileCells.sorted()
                                let step=max(1,(roots.count+255)/256)
                                var adjacent=0
                                for offset in stride(from:0,to:roots.count,by:step) {
                                    let root=roots[offset],y=root/columns,x=root%columns
                                    guard rgb(y,x).map(matchesWhite) == true else { continue }
                                    if (-radius...radius).contains(where:{ dy in
                                        (-radius...radius).contains { dx in
                                            let xx=x+margin+dx,yy=y+dy
                                            return xx >= 0 && xx < markColumns && yy >= 0 && yy < rows &&
                                                cells.contains(yy*markColumns+xx)
                                        }
                                    }) { adjacent+=1 }
                                }
                                privateBridge=adjacent >= 8
                            }
                            let proven=bridge ? privateBridge:(companion ? whiteCollar(queue):
                                wrapped || enclosedCompanion(left:left,right:right,top:top,bottom:bottom,whiteCells:queue))
                            let stemDot = !companion && whiteStemDot(left:left-margin,right:right-margin,
                                top:top,bottom:bottom,pixels:queue.count)
                            // With no DB corridor, every intermediate mark must
                            // have the same measured border, not merely white RGB.
                            if (!companion && detectorSupport != nil) || proven || stemDot {
                                if proven { borderProven.insert(marks.count) }
                                if stemDot { stemDotProven.insert(marks.count) }
                                marks.append(.init(left:left-margin,right:right-margin,top:top,bottom:bottom,cells:queue,companion:companion,linkOnly:bridge))
                            }
                        }
                    }
                }
                appendMarks(neutral,companion:false)
                // A glyph's white outline may join a neighbouring white region.
                // Its coloured fill can still have a complete, white-collared
                // cap. Observe only the intrinsic endpoint neighbourhoods;
                // an open colour surface or a peer's ink cannot certify it.
                if hasSourceBorder {
                    var fill=[UInt8](repeating:0,count:markColumns*rows)
                    for y in 0..<rows where companionBand(y) {
                        for x in 0..<markColumns {
                            if let c=rgb(y,x-margin),sameBorder(c) { fill[y*markColumns+x]=1 }
                        }
                    }
                    appendMarks(fill,companion:true)
                }
                if marks.count <= 512 {
                    let roots=profileCells.filter { p in
                        if let c=rgb(p/columns,p%columns) { return matchesWhite(c) }
                        return false
                    }
                    var linked=stemDotProven
                    for i in marks.indices {
                        let m=marks[i],centre=CGFloat(m.left+m.right)/2
                        if roots.contains(where:{ p in
                            let y=p/columns,x=p%columns
                            let dy=max(m.top-y,0,y-m.bottom)
                            return CGFloat(dy) <= width*0.5 && abs(CGFloat(x)-centre) <= width*0.3
                        }) { linked.insert(i) }
                    }
                    var changed=true
                    while changed {
                        changed=false
                        for i in marks.indices where !linked.contains(i) {
                            let a=marks[i],centre=CGFloat(a.left+a.right)/2
                            if linked.contains(where:{ j in
                                let b=marks[j],gap=max(a.top,b.top)-min(a.bottom,b.bottom)-1
                                return CGFloat(gap) <= width*0.5 && abs(centre-CGFloat(b.left+b.right)/2) <= width*0.3
                            }) { linked.insert(i);changed=true }
                        }
                    }
                    func observedCompanionStemDot(_ index:Int)->Bool {
                        let dot=marks[index],w=CGFloat(dot.right-dot.left+1),h=CGFloat(dot.bottom-dot.top+1)
                        guard recognizesExclamation,dot.companion,borderProven.contains(index),w >= sourceWhiteStroke*0.5,
                              w <= width*0.5,h >= w*0.5,h <= w*2 else { return false }
                        let centre=CGPoint(x:CGFloat(dot.left+dot.right)/2,y:CGFloat(dot.top+dot.bottom)/2)
                        for j in linked where j != index && borderProven.contains(j) {
                            let stem=marks[j],sw=CGFloat(stem.right-stem.left+1),sh=CGFloat(stem.bottom-stem.top+1)
                            guard stem.companion,sh >= max(h*2,width*0.4),sw <= w*1.8 else { continue }
                            let band=max(1,(stem.bottom-stem.top+1)/4)
                            func centreAt(_ top:Bool)->CGPoint? {
                                let cells=stem.cells.filter { top ? $0/markColumns < stem.top+band:$0/markColumns > stem.bottom-band }
                                guard !cells.isEmpty else { return nil }
                                return CGPoint(x:cells.reduce(CGFloat(0)){$0+CGFloat($1%markColumns-margin)}/CGFloat(cells.count),
                                    y:cells.reduce(CGFloat(0)){$0+CGFloat($1/markColumns)}/CGFloat(cells.count))
                            }
                            guard let a=centreAt(true),let b=centreAt(false) else { continue }
                            let length=hypot(b.x-a.x,b.y-a.y)
                            guard length >= max(h*1.5,width*0.25) else { continue }
                            let ux=(b.x-a.x)/length,uy=(b.y-a.y)/length
                            let head=centre.y < CGFloat(stem.top),end=head ? a:b,sign:CGFloat=head ? -1:1
                            let dx=centre.x-end.x,dy=centre.y-end.y
                            let along=(dx*ux+dy*uy)*sign,cross=abs(dx*uy-dy*ux)
                            audit?(["companionStemPair":["dot":index,"stem":j,"along":along,"cross":cross,"w":w,"sw":sw]])
                            if along >= 0,along <= w*2+sourceWhiteStroke*2,cross <= max(2,min(w,sw)*0.6) { return true }
                        }
                        return false
                    }
                    var kept=0,foreign=0
                    for i in linked.sorted() {
                        let m=marks[i]
                        if m.linkOnly { continue }
                        if wideCornerOnly && !(borderProven.contains(i) && isCorner(m)) { continue }
                        if observedCompanionStemDot(i) { stemDotProven.insert(i) }
                        // This supplemental neutral hypothesis can add only a
                        // complete, source-collared corner. Existing coloured,
                        // point and detector-supported paths run independently.
                        guard neutralInkOverride == nil || (borderProven.contains(i) && isCorner(m)) else { continue }
                        var lo=start+CGFloat(m.top),hi=start+CGFloat(m.bottom+1)
                        // Partial DB evidence is not a negative observation
                        // outside its corridor. A separately proven print
                        // border/stem keeps the same bounded RGB search it
                        // already had when no DB continuation was available.
                        let independentlyProven=stemDotProven.contains(i) ||
                            (borderProven.contains(i) && (neutralInkOverride != nil || !m.companion) && isCorner(m))
                        let markSupport=independentlyProven ? supported.union(basis.rect.insetBy(dx:0,dy:-width*1.5)):supported
                        let head=lo < basis.rect.minY && lo >= markSupport.minY-1
                        let tail=hi > basis.rect.maxY && hi <= markSupport.maxY+1
                        guard head || tail else { continue }
                        if m.companion {
                            if head,let cap=observedWhiteCap(m,head:true) { lo=min(lo,cap) }
                            if tail,let cap=observedWhiteCap(m,head:false) { hi=max(hi,cap) }
                        }
                        let rect=CGRect(x:basis.rect.minX+CGFloat(m.left),y:lo,
                            width:CGFloat(m.right-m.left+1),height:hi-lo)
                        if hasForeignPrivateInk(rect) { foreign+=1;continue }
                        var detectorCells=Set<Int>()
                        for p in m.cells {
                            let point=basis.restore(.init(x:basis.rect.minX+CGFloat(p%markColumns-margin)+0.5,y:start+CGFloat(p/markColumns)+0.5))
                            let x=Int(floor(point.x*CGFloat(map.width)/CGFloat(frame.width)))
                            let y=Int(floor(point.y*CGFloat(map.height)/CGFloat(frame.height)))
                            guard x >= 0,x < map.width,y >= 0,y < map.height else { continue }
                            let value=map.values[y*map.width+x]
                            if value.isFinite,Double(value) >= pixelThreshold { detectorCells.insert(y*map.width+x) }
                        }
                        guard (detectorSupport != nil && detectorCells.count >= 2) || borderProven.contains(i) || stemDotProven.contains(i) else { continue }
                        var markPaint=rect
                        if (terminalInkObserver != nil || terminalMarkObserver != nil),borderProven.contains(i),
                           let collar=observedPrintCollar(m),!hasForeignPrivateInk(collar) {
                            markPaint=collar
                            terminalInkObserver?(NativeOCRDirectionGeometry.corners(collar).map(basis.restore))
                        }
                        if (borderProven.contains(i) && isCorner(m)) || stemDotProven.contains(i) {
                            terminalMarkObserver?(NativeOCRDirectionGeometry.corners(markPaint).map(basis.restore))
                        }
                        audit?(["neutralCompactAccepted":["left":m.left,"right":m.right,"top":lo,"bottom":hi,
                            "borderProven":borderProven.contains(i),"stemDotProven":stemDotProven.contains(i),
                            "detectorCells":detectorCells.count,"companionFill":m.companion]])
                        if head { first=min(first,lo-2) }
                        if tail { last=max(last,hi+2) }
                        count+=1;kept+=1
                    }
                    audit?(["neutralDetectedComponents":marks.count,"neutralDetectedConnected":linked.count,
                            "neutralDetectedKept":kept,"neutralDetectedForeign":foreign,
                            "neutralDetectedStart":supported.minY,"neutralDetectedEnd":supported.maxY,
                            "neutralBorderProven":borderProven.count,"neutralSourceBorderFraction":sourceBorderFraction,
                            "neutralSourceCompanionColour":borderColour])
                }
            }
        }
        let neutralAlternative=neutralInkOverride == nil ? measuredNeutral.flatMap { colour in
            neutralOutlineTerminalProof(index:index,boxes:boxes,frame:frame,detectorSupport:detectorSupport,
                probability:probability,pixelThreshold:pixelThreshold,continuationPeers:continuationPeers,
                inkStyle:inkStyle,audit:audit,neutralInkOverride:colour,observedSourceInk:observedSourceInk,
                terminalInkObserver:terminalInkObserver,terminalMarkObserver:terminalMarkObserver,recognizesExclamation:recognizesExclamation,
                wideCornerOnly:wideCornerOnly)
        }:nil
        if let neutralAlternative { additionalCornerObserver?(neutralAlternative) }
        if !wideCornerOnly,neutralInkOverride == nil,terminalMarkObserver != nil {
            // A larger corner observation is additive. Its link-only print
            // components must not replace established endpoint, train, or
            // width measurements elsewhere in the OCR pipeline.
            _ = neutralOutlineTerminalProof(index:index,boxes:boxes,frame:frame,detectorSupport:detectorSupport,
                probability:probability,pixelThreshold:pixelThreshold,continuationPeers:continuationPeers,
                inkStyle:inkStyle,audit:audit,observedSourceInk:observedSourceInk,
                terminalMarkObserver:terminalMarkObserver,recognizesExclamation:recognizesExclamation,wideCornerOnly:true)
        }
        guard count > 0 else { return neutralAlternative }
        let proposal=[CGPoint(x:basis.rect.minX,y:first),CGPoint(x:basis.rect.maxX,y:first),
                      CGPoint(x:basis.rect.maxX,y:last),CGPoint(x:basis.rect.minX,y:last)].map(basis.restore)
        let result=replacingEndpointExtent(base:boxes[index].polygon,proposal:proposal,minimumChange:0)
        guard result.allSatisfy({$0.x >= 0 && $0.x <= CGFloat(frame.width) && $0.y >= 0 && $0.y <= CGFloat(frame.height)}) else { return nil }
        audit?(["neutralOutlineTerminals":count,"neutralOutlineStart":first,"neutralOutlineEnd":last])
        return combiningEndpointGrowth(base:result,supplement:neutralAlternative,minimumChange:0)
    }

    struct AxisFrame {
        let origin: CGPoint
        let along: CGPoint
        let across: CGPoint
        let rect: CGRect

        init?(_ polygon: [CGPoint]) {
            guard polygon.count == 4, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let edges = (0..<4).map { i in
                CGPoint(x: polygon[(i + 1) % 4].x - polygon[i].x,
                        y: polygon[(i + 1) % 4].y - polygon[i].y)
            }
            let lengths = edges.map { hypot($0.x, $0.y) }
            guard lengths.allSatisfy({ $0 > 0 }) else { return nil }
            let crosses = (0..<4).map { i in
                edges[i].x * edges[(i + 1) % 4].y - edges[i].y * edges[(i + 1) % 4].x
            }
            guard crosses.allSatisfy({ $0 > 0 }) || crosses.allSatisfy({ $0 < 0 }) else { return nil }
            let i = lengths[0] + lengths[2] >= lengths[1] + lengths[3] ? 0 : 1
            var v = CGPoint(x: edges[i].x / lengths[i] - edges[i + 2].x / lengths[i + 2],
                            y: edges[i].y / lengths[i] - edges[i + 2].y / lengths[i + 2])
            let magnitude = hypot(v.x, v.y)
            guard magnitude > 0 else { return nil }
            v = CGPoint(x: v.x / magnitude, y: v.y / magnitude)
            if v.y < 0 || (v.y == 0 && v.x < 0) { v = CGPoint(x: -v.x, y: -v.y) }
            let center = polygon.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4) }
            let u = CGPoint(x: v.y, y: -v.x)
            origin = center
            along = v
            across = u
            let points = polygon.map { p in
                let d = CGPoint(x: p.x - center.x, y: p.y - center.y)
                return CGPoint(x: d.x * u.x + d.y * u.y, y: d.x * v.x + d.y * v.y)
            }
            rect = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        }

        func project(_ p: CGPoint) -> CGPoint {
            let d = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
            return CGPoint(x: d.x * across.x + d.y * across.y, y: d.x * along.x + d.y * along.y)
        }

        func restore(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + across.x * p.x + along.x * p.y,
                    y: origin.y + across.y * p.x + along.y * p.y)
        }

        func bounds(_ polygon: [CGPoint]) -> CGRect {
            polygon.reduce(CGRect.null) { $0.union(CGRect(origin: project($1), size: .zero)) }
        }
    }

    static func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func expandedRecognitionPolygon(_ polygon: [CGPoint]) -> [CGPoint]? {
        guard let local = AxisFrame(polygon) else { return nil }
        let bounds = polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let width = oriented("REREAD") ? local.rect.width : bounds.width
        let height = oriented("REREAD") ? local.rect.height : bounds.height
        guard (40...90).contains(width), (150...360).contains(height), height >= width * 2 else { return nil }
        if !oriented("REREAD") {
            return polygon.map { CGPoint(x: bounds.midX + ($0.x - bounds.midX) * 1.17,
                                         y: bounds.midY + ($0.y - bounds.midY) * 1.045) }
        }
        return polygon.map {
            let p = local.project($0)
            return local.restore(CGPoint(x: p.x * 1.17, y: p.y * 1.045))
        }
    }
    static let supportedRecognitionThreshold = 0.65
    static let stronglySupportedRecognitionThreshold = 0.60
    static let dbRecognitionThreshold = 0.65
    /// Decode low-confidence candidates in the initial recognizer invocation;
    /// final admission below still requires independent DB/RF evidence.
    static let firstPassDecodeFloor = 0.45

    /// Experimental RF-guided column context, applied before the first read.
    /// RF describes a paragraph: preserve the DB lane and stop before a peer.
    /// This is recognition geometry, never new DB ink/erasure evidence.
    static func endpointCompletion(index: Int, boxes: [NativeCoreMLDetectionBox],
                                   layout: NativeRFDETRLayoutResult?, width: Int, height: Int) -> [CGPoint]? {
        guard boxes.indices.contains(index), let layout,
              layout.sourceWidth == width, layout.sourceHeight == height else { return nil }
        func bounds(_ polygon: [CGPoint]) -> CGRect {
            polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let polygon = boxes[index].polygon, db = bounds(polygon)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        guard polygon.count == 4, db.width > 0, db.height >= db.width * 2, canvas.contains(db),
              polygon.allSatisfy({ p in
                  (abs(p.x - db.minX) < 0.001 || abs(p.x - db.maxX) < 0.001) &&
                      (abs(p.y - db.minY) < 0.001 || abs(p.y - db.maxY) < 0.001)
              }) else { return nil }
        let matches = layout.primitives.filter { p in
            let overlap = db.intersection(p.sourceBounds)
            return p.semanticClass == .text && p.confidence >= 0.55 && !overlap.isNull &&
                overlap.width >= db.width * 0.6 && overlap.height >= db.height * 0.6
        }
        guard matches.count == 1 else { return nil }
        let rf = matches[0].sourceBounds.intersection(canvas)
        // A paragraph endpoint cannot justify an arbitrarily long blank lane
        // beside a shorter column. Bound context by the column's own scale.
        let limit = min(db.height * 0.25, db.width * 2)
        var top = min(db.minY, max(rf.minY, db.minY - limit))
        var bottom = max(db.maxY, min(rf.maxY, db.maxY + limit))
        for peerIndex in boxes.indices where peerIndex != index {
            let peer = bounds(boxes[peerIndex].polygon)
            let overlap = min(db.maxX, peer.maxX) - max(db.minX, peer.minX)
            guard overlap > min(db.width, peer.width) * 0.3 else { continue }
            if peer.maxY <= db.minY { top = max(top, min(db.minY, peer.maxY + 0.5)) }
            if peer.minY >= db.maxY { bottom = min(bottom, max(db.maxY, peer.minY - 0.5)) }
        }
        guard db.minY - top > 1 || bottom - db.maxY > 1 else { return nil }
        return [CGPoint(x: db.minX, y: top), CGPoint(x: db.maxX, y: top),
                CGPoint(x: db.maxX, y: bottom), CGPoint(x: db.minX, y: bottom)]
    }

    /// RF may nominate a corridor, but only measured DB cells may move an end.
    /// Empty RF paragraph margins cannot change the recognition crop.
    static func supportedEndpointCompletion(index: Int, boxes: [NativeCoreMLDetectionBox],
                                            layout: NativeRFDETRLayoutResult?, width: Int, height: Int,
                                            probability: NativeMainEnsembleOCRProbability.Sample?,
                                            pixelThreshold: Double, refineInk: Bool? = nil) -> [CGPoint]? {
        guard boxes.indices.contains(index) else { return nil }
        if ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_ENDPOINT_LEGACY_AXES"] != "1" {
            return orientedSupportedEndpointCompletion(index:index,boxes:boxes,layout:layout,
                width:width,height:height,probability:probability,pixelThreshold:pixelThreshold,refineInk:refineInk)
        }
        let originalBounds = boxes[index].polygon.reduce(CGRect.null) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        let legacyVertical = originalBounds.height >= originalBounds.width * 2 &&
            boxes[index].polygon.allSatisfy { p in
                (abs(p.x - originalBounds.minX) < 0.001 || abs(p.x - originalBounds.maxX) < 0.001) &&
                    (abs(p.y - originalBounds.minY) < 0.001 || abs(p.y - originalBounds.maxY) < 0.001)
            }
        guard legacyVertical else { return nil }
        guard let proposal = endpointCompletion(index: index, boxes: boxes, layout: layout,
                  width: width, height: height), let map = probability,
              map.sourceWidth == width, map.sourceHeight == height,
              map.width == map.resizedWidth, map.height == map.resizedHeight,
              map.region == CGRect(x: 0, y: 0, width: map.width, height: map.height),
              map.width > 0, map.height > 0, map.values.count == map.width * map.height,
              pixelThreshold.isFinite, pixelThreshold > 0, pixelThreshold <= 1 else { return nil }
        func bounds(_ polygon: [CGPoint]) -> CGRect {
            polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let db = bounds(boxes[index].polygon), candidate = bounds(proposal)
        let sx = CGFloat(width) / CGFloat(map.width), sy = CGFloat(height) / CGFloat(map.height)
        let x0 = max(0, Int(ceil(db.minX / sx))), x1 = min(map.width, Int(floor(db.maxX / sx)))
        let y0 = max(0, Int(ceil(candidate.minY / sy))), y1 = min(map.height, Int(floor(candidate.maxY / sy)))
        guard x1 > x0, y1 > y0, (x1 - x0) * (y1 - y0) <= 262_144 else { return nil }
        let minimumCells = max(1, Int(ceil(CGFloat(x1 - x0) * 0.1)))
        var topRows: [Int] = [], bottomRows: [Int] = []
        for y in y0..<y1 {
            let cellTop = CGFloat(y) * sy, cellBottom = CGFloat(y + 1) * sy
            guard cellBottom <= db.minY || cellTop >= db.maxY else { continue }
            var count = 0
            for x in x0..<x1 {
                let value = map.values[y * map.width + x]
                if value.isFinite && Double(value) >= pixelThreshold { count += 1 }
            }
            if count >= minimumCells {
                if cellBottom <= db.minY { topRows.append(y) } else { bottomRows.append(y) }
            }
        }
        let padding = min(db.width * 0.15, sy * 2)
        var top = db.minY, bottom = db.maxY
        if topRows.count >= 2, let first = topRows.first {
            top = max(candidate.minY, CGFloat(first) * sy - padding)
        }
        if bottomRows.count >= 2, let last = bottomRows.last {
            bottom = min(candidate.maxY, CGFloat(last + 1) * sy + padding)
        }
        guard db.minY - top > 1 || bottom - db.maxY > 1 else { return nil }
        return [CGPoint(x: db.minX, y: top), CGPoint(x: db.maxX, y: top),
                CGPoint(x: db.maxX, y: bottom), CGPoint(x: db.minX, y: bottom)]
    }

    /// Same endpoint gates in the DB quad's long-axis frame at every angle.
    static func orientedSupportedEndpointCompletion(index: Int, boxes: [NativeCoreMLDetectionBox],
                                            layout: NativeRFDETRLayoutResult?, width: Int, height: Int,
                                            probability: NativeMainEnsembleOCRProbability.Sample?,
                                            pixelThreshold: Double, refineInk: Bool? = nil) -> [CGPoint]? {
        guard boxes.indices.contains(index), let layout, let map = probability,
              layout.sourceWidth == width, layout.sourceHeight == height,
              map.sourceWidth == width, map.sourceHeight == height,
              map.width == map.resizedWidth, map.height == map.resizedHeight,
              map.region == CGRect(x: 0, y: 0, width: map.width, height: map.height),
              map.width > 0, map.height > 0, map.values.count == map.width * map.height,
              pixelThreshold.isFinite, pixelThreshold > 0, pixelThreshold <= 1 else { return nil }
        let polygon = boxes[index].polygon
        guard polygon.count == 4, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let edges = (0..<4).map { i in
            CGPoint(x: polygon[(i + 1) % 4].x - polygon[i].x,
                    y: polygon[(i + 1) % 4].y - polygon[i].y)
        }
        let lengths = edges.map { hypot($0.x, $0.y) }
        guard lengths.allSatisfy({ $0 > 0 }) else { return nil }
        let crosses = (0..<4).map { i in
            edges[i].x * edges[(i + 1) % 4].y - edges[i].y * edges[(i + 1) % 4].x
        }
        guard crosses.allSatisfy({ $0 > 0 }) || crosses.allSatisfy({ $0 < 0 }) else { return nil }
        let i = lengths[0] + lengths[2] >= lengths[1] + lengths[3] ? 0 : 1
        var v = CGPoint(x: edges[i].x / lengths[i] - edges[i + 2].x / lengths[i + 2],
                        y: edges[i].y / lengths[i] - edges[i + 2].y / lengths[i + 2])
        let magnitude = hypot(v.x, v.y)
        guard magnitude > 0 else { return nil }
        v = CGPoint(x: v.x / magnitude, y: v.y / magnitude)
        if v.y < 0 || (v.y == 0 && v.x < 0) { v = CGPoint(x: -v.x, y: -v.y) }
        let u = CGPoint(x: v.y, y: -v.x)
        func project(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * u.x + p.y * u.y, y: p.x * v.x + p.y * v.y)
        }
        func restore(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * u.x + p.y * v.x, y: p.x * u.y + p.y * v.y)
        }
        func bounds(_ points: [CGPoint]) -> CGRect {
            points.reduce(CGRect.null) { $0.union(CGRect(origin: project($1), size: .zero)) }
        }
        func corners(_ r: CGRect) -> [CGPoint] {
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height), db = bounds(polygon)
        guard db.width > 0, db.height >= db.width * 2, polygon.allSatisfy({ canvas.contains($0) }) else { return nil }
        let matches = layout.primitives.compactMap { primitive -> CGRect? in
            let rf = bounds(corners(primitive.sourceBounds)), overlap = db.intersection(rf)
            guard primitive.semanticClass == .text, primitive.confidence >= 0.55, !overlap.isNull,
                  overlap.width >= db.width * 0.6, overlap.height >= db.height * 0.6 else { return nil }
            return bounds(corners(primitive.sourceBounds.intersection(canvas)))
        }
        guard matches.count == 1 else { return nil }
        let limit = min(db.height * 0.25, db.width * 2)
        var candidateTop = min(db.minY, max(matches[0].minY, db.minY - limit))
        var candidateBottom = max(db.maxY, min(matches[0].maxY, db.maxY + limit))
        for peerIndex in boxes.indices where peerIndex != index {
            let peer = bounds(boxes[peerIndex].polygon)
            guard min(db.maxX, peer.maxX) - max(db.minX, peer.minX) > min(db.width, peer.width) * 0.3 else { continue }
            if peer.maxY <= db.minY { candidateTop = max(candidateTop, min(db.minY, peer.maxY + 0.5)) }
            if peer.minY >= db.maxY { candidateBottom = min(candidateBottom, max(db.maxY, peer.minY - 0.5)) }
        }
        guard db.minY - candidateTop > 1 || candidateBottom - db.maxY > 1 else { return nil }
        let sx = CGFloat(width) / CGFloat(map.width), sy = CGFloat(height) / CGFloat(map.height)
        // One local step corresponds to one detector-map cell along that axis.
        let dx = 1 / hypot(u.x / sx, u.y / sy), dy = 1 / hypot(v.x / sx, v.y / sy)
        let x0 = Int(ceil(db.minX / dx)), x1 = Int(floor(db.maxX / dx))
        let y0 = Int(ceil(candidateTop / dy)), y1 = Int(floor(candidateBottom / dy))
        guard x1 > x0, y1 > y0, (x1 - x0) * (y1 - y0) <= 262_144 else { return nil }
        let minimumCells = max(1, Int(ceil(CGFloat(x1 - x0) * 0.1)))
        var topRows: [Int] = [], bottomRows: [Int] = []
        for y in y0..<y1 {
            let rowTop = CGFloat(y) * dy, rowBottom = CGFloat(y + 1) * dy
            guard rowBottom <= db.minY || rowTop >= db.maxY else { continue }
            var count = 0
            for x in x0..<x1 {
                let p = restore(CGPoint(x: (CGFloat(x) + 0.5) * dx, y: (CGFloat(y) + 0.5) * dy))
                let mx = Int(floor(p.x / sx)), my = Int(floor(p.y / sy))
                guard mx >= 0, my >= 0, mx < map.width, my < map.height else { continue }
                let value = map.values[my * map.width + mx]
                if value.isFinite && Double(value) >= pixelThreshold { count += 1 }
            }
            if count >= minimumCells {
                if rowBottom <= db.minY { topRows.append(y) } else { bottomRows.append(y) }
            }
        }
        let padding = min(db.width * 0.15, dy * 2)
        // A weak DB cell elsewhere in the RF region is not a continuation.
        // Walk outward from the owner's end and stop at a whole-glyph blank
        // band. Measure the gap in this intrinsic frame, never screen X/Y.
        func connected(_ rows: [Int], from origin: CGFloat, outward: CGFloat) -> CGFloat? {
            if !(refineInk ?? refinesEndpointInk) {
                guard rows.count >= 2, let row = outward < 0 ? rows.first : rows.last else { return nil }
                return CGFloat(outward < 0 ? row : row + 1) * dy
            }
            var endpoint = origin, accepted = 0
            let ordered = outward < 0 ? rows.reversed().map { $0 } : rows
            for row in ordered {
                let near = CGFloat(outward < 0 ? row + 1 : row) * dy
                let far = CGFloat(outward < 0 ? row : row + 1) * dy
                guard (near - endpoint) * outward <= max(db.width, dy * 2) else { break }
                endpoint = far; accepted += 1
            }
            return accepted >= 2 ? endpoint : nil
        }
        var top = db.minY, bottom = db.maxY
        if let first = connected(topRows, from: db.minY, outward: -1) {
            top = max(candidateTop, first - padding)
        }
        if let last = connected(bottomRows, from: db.maxY, outward: 1) {
            bottom = min(candidateBottom, last + padding)
        }
        guard db.minY - top > 1 || bottom - db.maxY > 1 else { return nil }
        let result = polygon.map { point -> CGPoint in
            var local = project(point)
            let weight = (local.y - db.minY) / db.height
            local.y += (1 - weight) * (top - db.minY) + weight * (bottom - db.maxY)
            return restore(local)
        }
        guard result.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= CGFloat(width) && $0.y <= CGFloat(height) }) else { return nil }
        return result
    }

    /// Original-resolution, column-local components. RF bounds the search;
    /// source pixels, not DB probabilities, establish each column's endpoints.
    static func pixelEndpointCompletion(index: Int, boxes: [NativeCoreMLDetectionBox],
                                        layout: NativeRFDETRLayoutResult?, frame: NativeOCRRGBAFrame,
                                        probability:NativeMainEnsembleOCRProbability.Sample? = nil,
                                        terminalOnly: Bool = false, protectedInk: [CGPoint]? = nil,
                                        protectedEvidence: NativeOCRDetectorSeedEvidence? = nil, refineInk: Bool? = nil,
                                        admittedTrimInk: Bool = false,
                                        audit: (([String: Any]) -> Void)? = nil, inkStyles: [EndpointInkStyle?]? = nil,
                                        sourcePolygon: [CGPoint]? = nil,
                                        inkObserver: (([CGPoint]) -> Void)? = nil,
                                        terminalObserver: (([CGPoint]) -> Void)? = nil,
                                        continuationObserver: ((Int) -> Void)? = nil) -> [CGPoint]? {
        let refinesEndpointInk = refineInk ?? Self.refinesEndpointInk
        guard boxes.indices.contains(index), let layout,
              layout.sourceWidth == frame.width, layout.sourceHeight == frame.height,
              frame.bytesPerRow >= frame.width * 4,
              frame.bytes.count >= frame.bytesPerRow * frame.height else { return nil }
        func bounds(_ polygon: [CGPoint]) -> CGRect {
            polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let original = boxes[index].polygon
        // One immutable policy snapshot per call, never an environment copy
        // inside the original-resolution RGB scan (tens of thousands of cells).
        let pixelLocal = NativeOCRDirectionGeometry.enabled("pixelLocal")
        var p = original
        guard p.count == 4 else { return nil }
        let originalHead = CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2)
        let originalFoot = CGPoint(x: (p[3].x + p[2].x) / 2, y: (p[3].y + p[2].y) / 2)
        let originalLength = hypot(originalFoot.x - originalHead.x, originalFoot.y - originalHead.y)
        // The opt-in path runs the calibrated policy in the owner's basis at
        // every angle, including upright. The old branch is only its ablation
        // control, never an angle-dependent fallback within pixelLocal.
        let generalized = pixelLocal || oriented("PIXEL")
        let legacy = !generalized && originalLength > 0 && (originalFoot.y - originalHead.y) / originalLength >= 0.8 &&
            originalLength >= (hypot(p[1].x - p[0].x, p[1].y - p[0].y) +
                hypot(p[2].x - p[3].x, p[2].y - p[3].y))
        var order = [0, 1, 2, 3]
        if !legacy {
            guard oriented("PIXEL") || pixelLocal, let local = AxisFrame(p) else { return nil }
            // Choose the long pair intrinsically; do not flip it toward screen
            // down/right. A rigid rotation must retain the sampling origin.
            let crossLength = (hypot(p[1].x-p[0].x,p[1].y-p[0].y) +
                hypot(p[2].x-p[3].x,p[2].y-p[3].y))/2
            if crossLength > originalLength { order = [3, 0, 1, 2] }
            if !pixelLocal {
                // Preserve the original four-path ablation's point ordering.
                let edge0 = hypot(p[1].x-p[0].x,p[1].y-p[0].y)
                let edge1 = hypot(p[2].x-p[1].x,p[2].y-p[1].y)
                order = edge0 > edge1 ? [3, 0, 1, 2] : [0, 1, 2, 3]
            }
            p = order.map { original[$0] }
            if !pixelLocal {
                let d = CGPoint(x:(p[2].x+p[3].x-p[0].x-p[1].x)/2,
                                y:(p[2].y+p[3].y-p[0].y-p[1].y)/2)
                if d.x*local.along.x+d.y*local.along.y < 0 {
                    order = [order[2],order[3],order[0],order[1]]
                    p = order.map { original[$0] }
                }
            }
        }
        let head = CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2)
        let foot = CGPoint(x: (p[3].x + p[2].x) / 2, y: (p[3].y + p[2].y) / 2)
        let length = hypot(foot.x - head.x, foot.y - head.y)
        let thickness = (hypot(p[1].x - p[0].x, p[1].y - p[0].y) +
            hypot(p[2].x - p[3].x, p[2].y - p[3].y)) / 2
        let sourceEvidence = protectedEvidence ?? boxes[index].detectorSeedEvidence
        let privateSource = refinesEndpointInk && (sourceEvidence.map {
            $0.isValid && $0.sourceWidth == frame.width && $0.sourceHeight == frame.height
        } ?? false)
        let shortSource=length < thickness*2
        guard thickness >= 6,length >= thickness,
              !shortSource || (generalized && privateSource && boxes[index].score >= 0.8 &&
                !(sourceEvidence?.components.isEmpty ?? true)) else { return nil }
        let axis = CGPoint(x: (foot.x - head.x) / length, y: (foot.y - head.y) / length)
        let normal = CGPoint(x: axis.y, y: -axis.x)
        func localBounds(_ polygon: [CGPoint]) -> CGRect {
            legacy ? bounds(polygon) : bounds(polygon.map {
                let d = CGPoint(x: $0.x - head.x, y: $0.y - head.y)
                return CGPoint(x: d.x * normal.x + d.y * normal.y, y: d.x * axis.x + d.y * axis.y)
            })
        }
        let db = localBounds(p)
        var matches = layout.primitives.filter { primitive in
            let support = pixelLocal ? NativeOCRDirectionAdapters.support(primitive) : corners(primitive.sourceBounds)
            let overlap = localBounds(support).intersection(db)
            return primitive.semanticClass == .text && primitive.confidence >= 0.5 && !overlap.isNull &&
                overlap.width >= db.width * 0.6 && overlap.height >= db.height * 0.6
        }
        var sourceAlignedRF = false
        if matches.isEmpty,privateSource,boxes[index].score >= 0.8,pixelLocal,probability != nil,protectedEvidence == nil,
           sourceAlignedColumnsEnabled {
            let lanes=layout.primitives.compactMap { primitive -> (NativeRFDETRLayoutPrimitive,CGFloat)? in
                guard primitive.semanticClass == .text,primitive.confidence >= 0.25 else { return nil }
                let r=localBounds(NativeOCRDirectionAdapters.support(primitive)),overlap=r.intersection(db)
                guard !overlap.isNull,overlap.width >= db.width*0.85,overlap.height >= db.height*0.85,
                      r.width >= db.width*0.8,r.width <= db.width*1.8,
                      abs(r.midX-db.midX) <= db.width*0.25,r.height >= db.height else { return nil }
                return (primitive,CGFloat(primitive.confidence)/sqrt(max(1,r.width/db.width)))
            }.sorted { $0.1 > $1.1 }
            if let best=lanes.first,lanes.count == 1 || best.1 >= lanes[1].1*1.2 {
                matches=[best.0];sourceAlignedRF=true
                audit?(["sourceAlignedWeakRF":best.0.queryID,"sourceAlignedWeakRFConfidence":best.0.confidence])
            }
        }
        let canvas = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        // RF absence is not evidence that a detected line ends here. For a
        // strong, multi-glyph DB core only, examine a bounded neighboring glyph
        // in the SAME intrinsic lane. Pixel components and peer exclusion below
        // must independently corroborate growth; no RF rectangle is invented.
        // Private DB glyphs provide the lane witness when RF misses a compact
        // line. The later independent glyph-count and measured-span checks
        // still apply; padding width alone must not prevent observing them.
        let unanchored = matches.isEmpty && pixelLocal && boxes[index].score >= 0.8 &&
            (length >= thickness*3 || (privateSource && length >= thickness*2))
        audit?(["endpointRFMatches":matches.count,"shortPrivateSource":shortSource])
        guard matches.count == 1 || unanchored else { return nil }
        let projections: [CGFloat]
        if let match = matches.first {
            let rf = match.sourceBounds.intersection(canvas)
            guard !rf.isNull, !rf.isEmpty else { return nil }
            let support = pixelLocal ? NativeOCRDirectionAdapters.support(match) : corners(rf)
            projections = support.map { ($0.x-head.x)*axis.x+($0.y-head.y)*axis.y }
        } else {
            projections = [-thickness*1.8,length+thickness*1.8]
        }
        let corridorStart = floor(min(0, projections.min()!)), corridorEnd = ceil(max(length, projections.max()!))
        let extendedSearch = refinesEndpointInk && protectedEvidence == nil
        // RF enclosures can stop partway through a continuous terminal stroke.
        // Observe enough context to see its cap; admission still requires the
        // same source, lane, component shape and peer-ownership evidence.
        let start = extendedSearch ? corridorStart-thickness*4 : corridorStart
        let end = extendedSearch ? corridorEnd+thickness*4 : corridorEnd
        let columns = Int(ceil(thickness)), rows = Int(end - start)
        guard columns > 2, rows > 0, columns <= 524_288 / rows else { return nil }
        func point(_ row: CGFloat, _ column: CGFloat) -> CGPoint {
            CGPoint(x: head.x + axis.x * row + normal.x * (column - CGFloat(columns) / 2),
                    y: head.y + axis.y * row + normal.y * (column - CGFloat(columns) / 2))
        }
        func rgb(_ row: Int, _ column: Int) -> [Int]? {
            let q = point(start + CGFloat(row) + 0.5, CGFloat(column) + 0.5)
            let x = Int(floor(q.x)), y = Int(floor(q.y))
            guard x >= 0, y >= 0, x < frame.width, y < frame.height else { return nil }
            let offset = y * frame.bytesPerRow + x * 4
            return [Int(frame.bytes[offset]), Int(frame.bytes[offset + 1]), Int(frame.bytes[offset + 2])]
        }
        let ownerPolygon=sourcePolygon ?? original
        let ownerBounds=localBounds(ownerPolygon)
        var sourceMask: [Bool]?
        if refinesEndpointInk {
            var owned=[Bool](repeating:false,count:columns*rows)
            for row in 0..<rows { for column in 0..<columns {
                owned[row*columns+column]=NativeOCRDirectionGeometry.contains(ownerPolygon,
                    point(start+CGFloat(row)+0.5,CGFloat(column)+0.5))
            } }
            sourceMask=owned
        }
        var mask = [UInt8](repeating: 0, count: columns * rows)
        var polarity = [Int8](repeating: 0, count: columns * rows)
        var measuredRows = [Bool](repeating: false, count: rows)
        var darkEnergy: Int64 = 0, brightEnergy: Int64 = 0
        let rim = max(1, columns / 10)
        for row in 0..<rows {
            let border = (0..<rim).flatMap { [rgb(row, $0), rgb(row, columns - 1 - $0)] }.compactMap { $0 }
            guard border.count >= 2 else { continue }
            let background = (0..<3).map { channel in border.map { $0[channel] }.sorted()[border.count / 2] }
            let deviations = border.map { sample in zip(sample, background).map { abs($0 - $1) }.max()! }.sorted()
            let noise = deviations[deviations.count / 2]
            // A highly textured lateral rim cannot establish local paper colour.
            guard noise <= 16 else { continue }
            let cutoff = max(24, noise * 4)
            measuredRows[row] = true
            for column in 0..<columns {
                guard let sample = rgb(row, column) else { continue }
                if zip(sample, background).map({ abs($0 - $1) }).max()! > cutoff {
                    let cell = row * columns + column
                    mask[cell] = 1
                    let contrast = zip(sample, background).reduce(0) { $0 + $1.0 - $1.1 }
                    polarity[cell] = contrast < 0 ? -1 : 1
                    if start + CGFloat(row) >= 0, start + CGFloat(row + 1) <= length {
                        let energy = Int64(contrast) * Int64(contrast)
                        if contrast < 0 { darkEnergy += energy } else { brightEnergy += energy }
                    }
                }
            }
        }
        // Outlined lettering has two real foreground polarities. A global
        // energy winner cannot delete one when private text cells exist.
        if refinesEndpointInk && generalized && !privateSource, max(darkEnergy, brightEnergy) >= max(1, min(darkEnergy, brightEnergy)) * 4 {
            let ownPolarity: Int8 = darkEnergy > brightEnergy ? -1 : 1
            for cell in mask.indices where mask[cell] != 0 && polarity[cell] != ownPolarity {
                mask[cell] = 0
            }
        }
        // Keep original rim contrast separate from the selected palette. A
        // source word may change ink colour; private contrasting pixels can
        // veto trimming without teaching growth a new colour or owner.
        let privateContrast: [UInt8] = protectedEvidence == nil ? []:mask
        let observation: (mask: [UInt8], seeds: [Bool], first: CGFloat, last: CGFloat, growthMask: [UInt8], chromaticMask: [UInt8], primaryMask: [UInt8], inkStyle: EndpointInkStyle, pairedSource: Bool)? = refinesEndpointInk ? sourceEvidence.flatMap { evidence in
            guard evidence.sourceWidth == frame.width, evidence.sourceHeight == frame.height else { return nil }
            return endpointPalette(evidence:evidence,columns:columns,rows:rows,start:start,length:length,project: { q in
                let d=CGPoint(x:q.x-head.x,y:q.y-head.y)
                return CGPoint(x:d.x*normal.x+d.y*normal.y+CGFloat(columns)/2,
                    y:d.x*axis.x+d.y*axis.y-start)
            },rgb:rgb,audit:audit,sourceMask:sourceMask,
                candidatePeerPolygons:endpointFontPeerPolygons(boxes))
        } : nil
        let palette = protectedEvidence == nil ? nil : observation
        // Contrast against the lane rim also finds artwork attached to an
        // outline. When private ink can teach a palette, use that foreground
        // for growth too; mere connectivity is not text ownership.
        if let observation {
            mask = protectedEvidence == nil || admittedTrimInk ? observation.growthMask : observation.mask
        }
        // A component rejected for touching the lane rim can still be a
        // clipped real glyph. Its original foreground pixels veto trimming;
        // rejecting a CC shape must never certify that those pixels are blank.
        var visibleStart = length, visibleEnd: CGFloat = 0
        for row in 0..<rows where start+CGFloat(row) >= 0 && start+CGFloat(row+1) <= length {
            var count = 0
            for column in 0..<columns where mask[row*columns+column] != 0 { count += 1 }
            if count >= 2 || !measuredRows[row] {
                // A noisy/unmeasured gutter is UNKNOWN, never empty paper.
                visibleStart = min(visibleStart,start+CGFloat(row))
                visibleEnd = max(visibleEnd,start+CGFloat(row+1))
            }
        }
        if let palette { visibleStart=palette.first;visibleEnd=palette.last }
        struct Component {
            let left: Int; let right: Int; let top: Int; let bottom: Int; let pixels: Int; let privatePixels: Int
            var ownedCore = false
            var ownedExtension = false
            var sourceStyle = false
            var pendingTerminalFragment = false
            var width: Int { right - left + 1 }
            var height: Int { bottom - top + 1 }
        }
        var continuationPeers=Set<Int>(),continuationComponents:[Component]=[]
        if refinesEndpointInk,generalized,let observation,let scope=matches.first {
            let anchors=observation.seeds.indices.filter { observation.seeds[$0] }
            let painted=anchors.filter { observation.growthMask[$0] != 0 }.count
            if anchors.count >= 8,painted >= 12 {
                let sourceFit=Double(painted)/Double(anchors.count)
                for peer in boxes.indices where peer != index {
                    _ = confirmedEndpointContinuation(.init(polygon:ownerPolygon,score:boxes[index].score,
                        detectorSeedEvidence:sourceEvidence),peer:boxes[peer],scope:scope) { evidence,component,forward in
                        // Complete the leading fragment. The trailing observed
                        // read keeps its original identity and word extent.
                        guard forward else { return }
                        let sx=CGFloat(evidence.sourceWidth)/CGFloat(evidence.mapFullWidth)
                        let sy=CGFloat(evidence.sourceHeight)/CGFloat(evidence.mapFullHeight)
                        let rx=(abs(normal.x)*sx+abs(normal.y)*sy)/2
                        let ry=(abs(axis.x)*sx+abs(axis.y)*sy)/2
                        var measured=0,matched=0,extent=CGRect.null
                        for run in component.runs { for x in run.x..<(run.x+run.count) {
                            let dx=(CGFloat(x)+0.5)*sx-head.x,dy=(CGFloat(run.y)+0.5)*sy-head.y
                            let across=dx*normal.x+dy*normal.y+CGFloat(columns)/2
                            let along=dx*axis.x+dy*axis.y-start
                            let row=Int(floor(along)),column=Int(floor(across))
                            guard row >= 0,row < rows,column >= 0,column < columns else { continue }
                            measured+=1
                            if observation.growthMask[row*columns+column] != 0 { matched+=1 }
                            extent=extent.union(CGRect(x:across-rx,y:along-ry,width:rx*2,height:ry*2))
                        } }
                        guard measured*5 >= component.pixelCount*4,matched >= 12,
                              Double(matched) >= Double(measured)*sourceFit*0.5 else { return }
                        let left=max(0,Int(floor(extent.minX))),right=min(columns-1,Int(ceil(extent.maxX))-1)
                        let top=max(0,Int(floor(extent.minY))),bottom=min(rows-1,Int(ceil(extent.maxY))-1)
                        guard left <= right,top <= bottom else { return }
                        continuationPeers.insert(peer)
                        continuationObserver?(peer)
                        continuationComponents.append(.init(left:left,right:right,top:top,bottom:bottom,
                            pixels:matched,privatePixels:0,ownedExtension:true))
                        audit?(["confirmedColumnContinuation":peer,"continuationMatchedPixels":matched,
                                "continuationCandidatePixels":measured,"sourceFontFit":sourceFit])
                    }
                }
            }
        }
        var components: [Component] = [], queue: [Int] = []
        for seed in mask.indices where mask[seed] == 1 {
            queue.removeAll(keepingCapacity: true); queue.append(seed); mask[seed] = 0
            var cursor = 0, left = columns, right = 0, top = rows, bottom = 0, privatePixels = 0
            var coreLeft=columns,coreRight = -1,coreTop=rows,coreBottom = -1,corePixels=0
            var rowLeft=[Int](repeating:columns,count:rows),rowRight=[Int](repeating:-1,count:rows)
            var rowPixels=[Int](repeating:0,count:rows)
            while cursor < queue.count {
                let cell = queue[cursor]; cursor += 1
                if observation?.seeds[cell] == true { privatePixels+=1 }
                let x = cell % columns, y = cell / columns
                rowLeft[y]=min(rowLeft[y],x);rowRight[y]=max(rowRight[y],x);rowPixels[y]+=1
                let along=start+CGFloat(y)+0.5
                let ownedPixel: Bool
                if let sourceMask { ownedPixel=sourceMask[cell] }
                else { ownedPixel=along >= 0 && along < length }
                if ownedPixel {
                    coreLeft=min(coreLeft,x);coreRight=max(coreRight,x)
                    coreTop=min(coreTop,y);coreBottom=max(coreBottom,y);corePixels+=1
                }
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < columns, yy < rows else { continue }
                    let next = yy * columns + xx
                    if mask[next] == 1 { mask[next]=0;queue.append(next) }
                } }
            }
            if refinesEndpointInk, privatePixels >= 2, corePixels >= 12 {
                // A detector-supported connected word is not one oversized
                // character. Keep its owned core regardless of CC dimensions,
                // then measure its head and tail independently from that core.
                components.append(.init(left:coreLeft,right:coreRight,top:coreTop,bottom:coreBottom,
                    pixels:corePixels,privatePixels:privatePixels,ownedCore:true))
                func appendOwnedPart(near: Int, far: Int, step: Int) {
                    guard near >= 0,near < rows,far >= 0,far < rows,(far-near)*step >= 0 else { return }
                    var lo=rows,hi = -1,x0=columns,x1 = -1,mass=0,row=near,junctionPrefix=0
                    while (far-row)*step >= 0 {
                        // Reaching a cross-lane junction is a local stopping
                        // event. It cannot delete the word on the other side.
                        if rowPixels[row] == 0 { break }
                        let wide = rowLeft[row] == 0 || rowRight[row] == columns-1 ||
                            CGFloat(rowRight[row]-rowLeft[row]+1) > thickness*0.5
                        if wide {
                            // A DB crop can end within the glyph that owns a
                            // terminal. Observe at most that first glyph; only
                            // a long, coherent, measured narrow tail below can
                            // certify crossing this initial junction.
                            guard mass == 0,junctionPrefix < Int(ceil(thickness)) else { return }
                            junctionPrefix+=1;row+=step;continue
                        }
                        // Connectivity through outlines or punctuation does not
                        // authorize taking the next word. Only the narrow end
                        // stroke may continue beyond an established crop.
                        lo=min(lo,row);hi=max(hi,row);x0=min(x0,rowLeft[row]);x1=max(x1,rowRight[row]);mass+=rowPixels[row]
                        row+=step
                    }
                    if audit != nil, lo <= hi {
                        let widths=(lo...hi).map { rowRight[$0]-rowLeft[$0]+1 }.sorted()
                        let centers=(lo...hi).map { CGFloat(rowLeft[$0]+rowRight[$0])/2 }
                        audit?(["ownedPartTop":start+CGFloat(lo),"ownedPartBottom":start+CGFloat(hi+1),
                                "rowWidth":widths[widths.count/2],"centerDrift":centers.max()!-centers.min()!])
                    }
                    // A search-window boundary is unknown, not a glyph end.
                    guard mass >= 2,lo > 0,hi < rows-1 else { return }
                    if junctionPrefix > 0 {
                        guard CGFloat(hi-lo+1) >= thickness*1.6,
                              CGFloat(x1-x0+1) <= thickness*0.5 else { return }
                        audit?(["terminalJunctionPrefixRows":junctionPrefix,
                                "terminalJunctionStemTop":start+CGFloat(lo),"terminalJunctionStemBottom":start+CGFloat(hi+1)])
                    }
                    components.append(.init(left:x0,right:x1,top:lo,bottom:hi,pixels:mass,
                        privatePixels:0,ownedExtension:true))
                }
                let firstCore=max(0,Int(ceil(ownerBounds.minY-start-0.5)))
                let afterCore=min(rows,Int(ceil(ownerBounds.maxY-start-0.5)))
                if top < firstCore { appendOwnedPart(near:min(bottom,firstCore-1),far:top,step:-1) }
                if bottom >= afterCore { appendOwnedPart(near:max(top,afterCore),far:bottom,step:1) }
                continue
            }
            // Outside the established RF/local corridor, a normal new glyph
            // has no new owner evidence. Only a measured continuous thin stroke
            // can use the extra context; arbitrary additional words cannot.
            let extendsCorridor = start+CGFloat(top) < corridorStart || start+CGFloat(bottom+1) > corridorEnd
            let sourceStyle: Bool
            if let proof = observation {
                sourceStyle = queue.count >= 12 && queue.filter { proof.chromaticMask[$0] != 0 }.count*5 >= queue.count*4
            } else { sourceStyle = false }
            let terminalStroke = CGFloat(bottom-top+1) > thickness*1.6 && CGFloat(right-left+1) <= thickness*0.3
            let terminalFragment = refinesEndpointInk && generalized &&
                CGFloat(right-left+1) <= thickness*0.3 && bottom-top+1 >= (right-left+1)*3 &&
                CGFloat(bottom-top+1) >= thickness*0.5
            // A terminal may have a small raster/printing gap. A short thin
            // outside fragment is still owned when the same lateral stroke is
            // observed immediately inside the established crop. Do not confuse
            // individual CC length with the length of the complete terminal.
            var linkedTerminal = false
            if extendedSearch, extendsCorridor, !terminalStroke, let observation,
               CGFloat(right-left+1) <= thickness*0.3,
               bottom-top+1 >= (right-left+1)*3, CGFloat(bottom-top+1) >= thickness*0.5 {
                let gap = max(2,Int(ceil(thickness*0.25)))
                let nearRows: Range<Int>
                if start+CGFloat(top) < 0 {
                    nearRows = min(rows,bottom+1)..<min(rows,bottom+1+gap)
                } else if start+CGFloat(bottom+1) > length {
                    nearRows = max(0,top-gap)..<max(0,top)
                } else { nearRows = 0..<0 }
                linkedTerminal = nearRows.contains { row in
                    guard start+CGFloat(row) >= 0, start+CGFloat(row) < length else { return false }
                    return (left...right).filter { observation.growthMask[row*columns+$0] != 0 }.count >= 2
                }
            }
            if audit != nil {
                let occupied=(top...bottom).filter { rowPixels[$0] > 0 }
                let widths=occupied.map { rowRight[$0]-rowLeft[$0]+1 }.sorted()
                let centers=occupied.map { CGFloat(rowLeft[$0]+rowRight[$0])/2 }
                audit?(["rawShapeTop":start+CGFloat(top),"rawShapeBottom":start+CGFloat(bottom+1),
                        "rowWidth":widths[widths.count/2],"centerDrift":centers.max()!-centers.min()!])
            }
            audit?(["rawTop": start+CGFloat(top), "rawBottom": start+CGFloat(bottom+1),
                    "rawLeft": left, "rawRight": right, "rawMass": queue.count,
                    "privatePixels": privatePixels, "extendsCorridor": extendsCorridor,
                    "terminalStroke": terminalStroke, "linkedTerminal": linkedTerminal, "sourceStyle": sourceStyle])
            if extendedSearch && extendsCorridor && !terminalStroke && !linkedTerminal && !sourceStyle && !terminalFragment { continue }
            // Cross-lane rules and artwork touching the lane rim are not glyph components.
            if queue.count >= 2, left > 0, right < columns - 1, top > 0, bottom < rows - 1,
               (CGFloat(bottom - top + 1) <= thickness * 1.6 ||
                (refinesEndpointInk && generalized && CGFloat(right - left + 1) <= thickness * 0.3)) {
                components.append(.init(left: left, right: right, top: top, bottom: bottom,
                    pixels: queue.count, privatePixels: privatePixels, ownedExtension: linkedTerminal, sourceStyle: sourceStyle,
                    pendingTerminalFragment:extendedSearch && extendsCorridor && terminalFragment && !terminalStroke && !linkedTerminal && !sourceStyle))
            }
            if components.count > 4_096 { return nil }
        }
        components.append(contentsOf:continuationComponents)
        if refinesEndpointInk,generalized,let observation {
            // Printing/raster gaps split one bar into short components. Prove
            // the whole collinear chain from original ink before admitting a
            // short fragment outside RF; neither endpoint receives a shortcut.
            let thin=components.indices.filter { i in
                let c=components[i]
                return CGFloat(c.width) <= thickness*0.3 && c.height >= c.width*3 && CGFloat(c.height) >= thickness*0.5
            }
            let gap=max(2,Int(ceil(thickness*0.25)))
            var parent=Array(components.indices)
            func root(_ value:Int) -> Int {
                var p=value
                while parent[p] != p { parent[p]=parent[parent[p]];p=parent[p] }
                return p
            }
            for (offset,i) in thin.enumerated() { for j in thin.dropFirst(offset+1) {
                let a=components[i],b=components[j]
                let separation=max(a.top,b.top)-min(a.bottom,b.bottom)-1
                let overlap=min(a.right,b.right)-max(a.left,b.left)+1
                let drift=abs(CGFloat(a.left+a.right-b.left-b.right)/2)
                if separation <= gap && (CGFloat(overlap) >= CGFloat(min(a.width,b.width))*0.5 || drift <= 1) {
                    let aRoot=root(i),bRoot=root(j)
                    parent[bRoot]=aRoot
                }
            } }
            var groups:[Int:[Int]]=[:]
            for i in thin { groups[root(i),default:[]].append(i) }
            for ids in groups.values where ids.count >= 2 {
                let lo=ids.map { components[$0].top }.min()!,hi=ids.map { components[$0].bottom }.max()!
                let left=ids.map { components[$0].left }.min()!,right=ids.map { components[$0].right }.max()!
                guard CGFloat(hi-lo+1) >= thickness*1.6,CGFloat(right-left+1) <= thickness*0.3 else { continue }
                var anchors=0
                for row in max(0,lo-gap)...min(rows-1,hi+gap) where start+CGFloat(row) >= 0 && start+CGFloat(row) < length {
                    for column in left...right where observation.growthMask[row*columns+column] != 0 { anchors+=1 }
                }
                guard anchors >= 2 || ids.contains(where:{components[$0].ownedExtension || components[$0].ownedCore}) else { continue }
                for i in ids { components[i].ownedExtension=true }
                audit?(["terminalChainPieces":ids.count,"terminalChainTop":start+CGFloat(lo),"terminalChainBottom":start+CGFloat(hi+1)])
            }
            components.removeAll { $0.pendingTerminalFragment && !$0.ownedExtension }
        }
        func alongTop(_ c: Component) -> CGFloat { start + CGFloat(c.top) }
        func alongBottom(_ c: Component) -> CGFloat { start + CGFloat(c.bottom + 1) }
        let body: [Component] = components.filter { c in
            if c.ownedCore { return true }
            if observation != nil { return false }
            return min(length, alongBottom(c)) - max(0, alongTop(c)) >= CGFloat(c.height) * 0.5
        }
        audit?(["start": start, "end": end, "length": length, "thickness": thickness,
                "corridorStart": corridorStart, "corridorEnd": corridorEnd, "palette": observation != nil,
                "components": components.map { c in
                    ["left": c.left, "right": c.right, "top": c.top, "bottom": c.bottom,
                     "pixels": c.pixels, "privatePixels": c.privatePixels,
                     "ownedCore": c.ownedCore, "ownedExtension": c.ownedExtension] as [String: Any]
                }])
        guard !body.isEmpty, body.reduce(0, { $0 + $1.pixels }) >= 12 else { return nil }
        let ownedLine = body.contains { $0.ownedCore && CGFloat($0.height) >= thickness*2 && CGFloat($0.width) >= thickness*0.35 }
        let fontBody: [Component] = refinesEndpointInk ? body.filter {
            // A measured printing-gap terminal chain is one long stroke, even
            // if the original crop splits it into individually short pieces.
            // Those pieces must not inflate character pitch and bridge artwork
            // after the real cap through an oversized inter-glyph gap budget.
            let thin=CGFloat($0.width) <= thickness*0.3
            let chain=thin && $0.ownedExtension && $0.height >= $0.width*3 && CGFloat($0.height) >= thickness*0.5
            return !(thin && CGFloat($0.height) > thickness*1.6 || chain)
        } : body
        if refinesEndpointInk && unanchored && fontBody.count < 3 && !ownedLine { return nil }
        let scaleBody = fontBody.isEmpty ? body : fontBody
        func glyphScale(_ c: Component) -> Int {
            c.ownedCore && CGFloat(c.height) > thickness*1.6 ? Int(ceil(thickness)) : max(c.width,c.height)
        }
        let sizes = scaleBody.map(glyphScale).sorted()
        var pitch = max(thickness * 0.35, CGFloat(sizes[min(sizes.count - 1, sizes.count * 9 / 10)]))
        if unanchored {
            // One isolated blob or a sparse punctuation rail is not enough to
            // bootstrap an independent endpoint search without RF context.
            guard (scaleBody.count >= 3 || ownedLine),
                  scaleBody.map(alongBottom).max()! - scaleBody.map(alongTop).min()! >= pitch*2 else { return nil }
            // Numerous tiny texture specks must not outvote the measured
            // glyphs. Without RF support, estimate the glyph scale by original
            // ink mass, rather than by the number of connected components.
            let mass = scaleBody.reduce(0) { $0+$1.pixels }
            var accumulated = 0
            for c in scaleBody.sorted(by:{ glyphScale($0) < glyphScale($1) }) {
                accumulated += c.pixels
                if accumulated*10 >= mass*9 {
                    pitch=max(thickness*0.35,CGFloat(glyphScale(c)))
                    break
                }
            }
        }
        let bodyLeft = body.map(\.left).min()!, bodyRight = body.map(\.right).max()!
        let acrossMargin = max(2, CGFloat(bodyRight - bodyLeft + 1) * 0.25)
        var peerInk = [Bool](repeating: false, count: refinesEndpointInk ? columns * rows : 0)
        var sameStylePeerInk = peerInk
        let peers = boxes.indices.filter { $0 != index }.compactMap { i -> CGRect? in
            let r = localBounds(boxes[i].polygon), intersection = r.intersection(db)
            if !intersection.isNull && intersection.width * intersection.height >= db.width * db.height * 0.8 { return nil }
            if continuationPeers.contains(i) { return nil }
            if refinesEndpointInk, !legacy, let evidence = boxes[i].detectorSeedEvidence,
               evidence.isValid, evidence.sourceWidth == frame.width, evidence.sourceHeight == frame.height,
               !evidence.components.isEmpty {
                // A peer's padding is not peer ink. Project its measured cells,
                // clipped to its own read, rather than blocking its whole bbox.
                // Shared CCs are clipped here too: owner identity alone cannot
                // distinguish separate crops of one connected component.
                let peerStyle: EndpointInkStyle?
                if let inkStyles, inkStyles.indices.contains(i) { peerStyle = inkStyles[i] }
                else { peerStyle = endpointInkStyle(box:boxes[i],frame:frame) }
                let distinct = distinctEndpointInk(observation?.inkStyle,peerStyle)
                let sx = CGFloat(evidence.sourceWidth) / CGFloat(evidence.mapFullWidth)
                let sy = CGFloat(evidence.sourceHeight) / CGFloat(evidence.mapFullHeight)
                let radiusX = (abs(normal.x) * sx + abs(normal.y) * sy) / 2
                let radiusY = (abs(axis.x) * sx + abs(axis.y) * sy) / 2
                for component in evidence.components { for run in component.runs {
                    for x in run.x..<(run.x + run.count) {
                        let world = CGPoint(x: (CGFloat(x) + 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy)
                        guard NativeOCRDirectionGeometry.contains(boxes[i].polygon, world) else { continue }
                        let dx = world.x - head.x, dy = world.y - head.y
                        let across = dx * normal.x + dy * normal.y + CGFloat(columns) / 2
                        let along = dx * axis.x + dy * axis.y - start
                        let x0 = max(0, Int(floor(across - radiusX))), x1 = min(columns, Int(ceil(across + radiusX)))
                        let y0 = max(0, Int(floor(along - radiusY))), y1 = min(rows, Int(ceil(along + radiusY)))
                        guard x0 < x1, y0 < y1 else { continue }
                        for y in y0..<y1 { for column in x0..<x1 {
                            peerInk[y * columns + column] = true
                            if !distinct { sameStylePeerInk[y * columns + column] = true }
                        } }
                    }
                } }
                return nil
            }
            return r
        }
        // Calibrate small end marks from a repeated private dot train.
        // Short background texture must not acquire a glyph endpoint merely
        // because it shares the print's RGB and lies one pitch below it.
        let sourceDots=components.filter { c in
            let w=CGFloat(c.width),h=CGFloat(c.height)
            return c.privatePixels > 0 && alongTop(c) >= 0 && alongBottom(c) <= length &&
                w >= 3 && h >= 3 && w <= pitch*0.4 && h <= pitch*0.4 && h >= w*0.7 && h <= w*1.5
        }.sorted { alongTop($0) < alongTop($1) }
        var pointMeasurements=[sourceDots]
        if let observation, refinesEndpointInk, generalized {
            // A continuous outline can join several real dots into one word
            // component. Measure the private primary paint separately, without
            // admitting that paint as another source or extension candidate.
            let lo=max(0,Int(floor(ownerBounds.minY-start)))
            let hi=min(rows,Int(ceil(ownerBounds.maxY-start)))
            var primary=observation.primaryMask
            var points:[Component]=[]
            if lo < hi {
                for row in lo..<hi { for column in 0..<columns {
                    let seed=row*columns+column
                    guard primary[seed] != 0,sourceMask?[seed] != false else {continue}
                    primary[seed]=0;queue.removeAll(keepingCapacity:true);queue.append(seed)
                    var cursor=0,left=columns,right=0,top=rows,bottom=0,roots=0,open=false
                    while cursor < queue.count {
                        let cell=queue[cursor];cursor+=1
                        let x=cell%columns,y=cell/columns
                        left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                        if observation.seeds[cell] {roots+=1}
                        for dy in -1...1 {for dx in -1...1 where dx != 0 || dy != 0 {
                            let xx=x+dx,yy=y+dy
                            guard xx >= 0,xx < columns,yy >= lo,yy < hi else {open=true;continue}
                            let next=yy*columns+xx
                            guard sourceMask?[next] != false else {open=true;continue}
                            if primary[next] != 0 {primary[next]=0;queue.append(next)}
                        }}
                    }
                    let w=CGFloat(right-left+1),h=CGFloat(bottom-top+1)
                    guard !open,roots >= 2,queue.count >= 4,w >= 3,h >= 3,
                          w <= pitch*0.4,h <= pitch*0.4,h >= w*0.8,h <= w*1.25,
                          CGFloat(queue.count) >= w*h*0.6 else {continue}
                    points.append(.init(left:left,right:right,top:top,bottom:bottom,
                        pixels:queue.count,privatePixels:roots))
                }}
            }
            if points.count >= 3 {
                // Keep the two measurements separate: an outline and its fill
                // are not two different points in the same repeated train.
                audit?(["privatePrimaryPointSizes":points.map{[$0.width,$0.height]},
                        "privatePrimaryPointRows":points.map{alongTop($0)}])
                pointMeasurements.append(points.sorted {alongTop($0) < alongTop($1)})
            }
        }
        var sourcePointDiameter:CGFloat?,primaryHeadDiameter:CGFloat?,primaryTailDiameter:CGFloat?
        for (family,sourceDots) in pointMeasurements.enumerated() where sourceDots.count >= 3 {
            for i in 0..<(sourceDots.count-2) {
                let ds=Array(sourceDots[i...i+2]),sizes=ds.map { CGFloat(min($0.width,$0.height)) }.sorted()
                let diameter=sizes[1],centres=ds.map { CGFloat($0.left+$0.right)/2 }
                let positions=ds.map { (alongTop($0)+alongBottom($0))/2 }
                let a=positions[1]-positions[0],b=positions[2]-positions[1]
                if sizes[2] <= sizes[0]*1.7,centres.max()!-centres.min()! <= diameter*0.7,
                   a > diameter,b > diameter,max(a,b) <= min(a,b)*1.3 {
                    if family == 0 {sourcePointDiameter=max(sourcePointDiameter ?? 0,diameter)}
                    else {
                        // A train near one endpoint cannot change the other
                        // end of the word. Its size only calibrates unowned
                        // islands beyond the same original owner boundary.
                        let lo=alongTop(ds[0]),hi=alongBottom(ds[2]),middle=(lo+hi)/2
                        if middle < ownerBounds.midY,lo <= ownerBounds.minY+diameter {
                            primaryHeadDiameter=max(primaryHeadDiameter ?? 0,diameter)
                        }
                        if middle > ownerBounds.midY,hi >= ownerBounds.maxY-diameter {
                            primaryTailDiameter=max(primaryTailDiameter ?? 0,diameter)
                        }
                    }
                }
            }
        }
        let measuredDiameter=[sourcePointDiameter,primaryHeadDiameter,primaryTailDiameter].compactMap{$0}.max()
        if let measuredDiameter {audit?(["sourcePointDiameter":measuredDiameter,
            "primaryHeadPointDiameter":primaryHeadDiameter ?? 0,"primaryTailPointDiameter":primaryTailDiameter ?? 0])}
        let baseEligible = components.filter { c in
            let center = CGFloat(c.left + c.right + 1) / 2
            if let diameter=sourcePointDiameter,!c.ownedCore,!c.ownedExtension,c.privatePixels == 0,
               CGFloat(max(c.width,c.height)) <= pitch*0.5,CGFloat(min(c.width,c.height)) < diameter*0.8 { return false }
            // Isolated unresolved texture pixels cannot bridge a glyph-sized
            // gap. Long thin strokes and resolved punctuation remain eligible.
            if refinesEndpointInk, !c.ownedCore, !c.ownedExtension, c.width <= 2,
               c.pixels <= max(4,Int(ceil(pitch*0.15))), CGFloat(c.height) < pitch*0.35 { return false }
            guard center >= CGFloat(bodyLeft) - acrossMargin, center <= CGFloat(bodyRight + 1) + acrossMargin,
                  (c.ownedExtension || c.ownedCore || CGFloat(max(c.width, c.height)) <= pitch * 1.8 ||
                   (refinesEndpointInk && generalized && CGFloat(c.width) <= min(thickness * 0.3, pitch * 0.5))) else { return false }
            if refinesEndpointInk,unanchored,observation == nil,!c.ownedCore,!c.ownedExtension {
                let overlap=max(0,min(length,alongBottom(c))-max(0,alongTop(c)))
                if overlap < CGFloat(c.height)*0.5 {
                    // Without RF or a private paint model, isolated texture
                    // cannot bootstrap a new letter merely by forming a chain
                    // of short gaps. Keep resolved glyph-sized components and
                    // measured long along-axis strokes; preserve original ink.
                    let glyph=CGFloat(min(c.width,c.height)) >= max(2,pitch*0.08) &&
                        CGFloat(max(c.width,c.height)) >= pitch*0.5
                    let stroke=CGFloat(c.height) > thickness*1.6 &&
                        CGFloat(c.width) <= min(thickness*0.3,pitch*0.5)
                    if !glyph && !stroke {return false}
                }
            }
            if alongTop(c) >= 0 && alongBottom(c) <= length { return true }
            if refinesEndpointInk {
                for row in c.top...c.bottom where start + CGFloat(row) < 0 || start + CGFloat(row) >= length {
                    for column in c.left...c.right {
                        if c.sourceStyle ? sameStylePeerInk[row*columns+column] : peerInk[row*columns+column] { return false }
                    }
                }
            }
            let corners = [point(alongTop(c), CGFloat(c.left)), point(alongTop(c), CGFloat(c.right + 1)),
                point(alongBottom(c), CGFloat(c.right + 1)), point(alongBottom(c), CGFloat(c.left))]
            let r = localBounds(corners)
            return !peers.contains { peer in
                let intersection = r.intersection(peer)
                return !intersection.isNull && intersection.width * intersection.height >= r.width * r.height * 0.25
            }
        }
        var primaryRejectedHead=false,primaryRejectedTail=false
        let eligible=baseEligible.filter { c in
            guard !c.ownedCore,!c.ownedExtension,c.privatePixels == 0,
                  CGFloat(max(c.width,c.height)) <= pitch*0.5 else {return true}
            if let diameter=primaryHeadDiameter,alongBottom(c) <= ownerBounds.minY,
               CGFloat(min(c.width,c.height)) < diameter*0.8 {
                primaryRejectedHead=true;return false
            }
            if let diameter=primaryTailDiameter,alongTop(c) >= ownerBounds.maxY,
               CGFloat(min(c.width,c.height)) < diameter*0.8 {
                primaryRejectedTail=true;return false
            }
            return true
        }
        var first = body.map(alongTop).min()!, last = body.map(alongBottom).max()!
        func corroboratesLaneGlyph(_ c:Component)->Bool {
            guard sourceAlignedRF,c.sourceStyle,CGFloat(c.width) >= thickness*0.3,
                  CGFloat(c.height) >= pitch*0.35,let map=probability,
                  map.sourceWidth == frame.width,map.sourceHeight == frame.height,
                  map.width == map.resizedWidth,map.height == map.resizedHeight,
                  map.region == CGRect(x:0,y:0,width:map.width,height:map.height),
                  map.values.count == map.width*map.height else { return false }
            var cells=Set<Int>()
            for row in c.top...c.bottom { for column in c.left...c.right {
                let world=point(start+CGFloat(row)+0.5,CGFloat(column)+0.5)
                let x=Int(floor(world.x*CGFloat(map.width)/CGFloat(frame.width)))
                let y=Int(floor(world.y*CGFloat(map.height)/CGFloat(frame.height)))
                guard x >= 0,y >= 0,x < map.width,y < map.height else { continue }
                let value=map.values[y*map.width+x]
                if value.isFinite,value >= 0.05 { cells.insert(y*map.width+x) }
            } }
            return cells.count >= 3
        }
        for c in eligible.sorted(by: { alongTop($0) < alongTop($1) }) where alongBottom(c) > last {
            if alongTop(c) - last > pitch * 0.9 &&
                !(alongTop(c)-last <= max(pitch,thickness)*3 && corroboratesLaneGlyph(c)) { break }
            last = max(last, alongBottom(c))
        }
        for c in eligible.sorted(by: { alongBottom($0) > alongBottom($1) }) where alongTop(c) < first {
            if first - alongBottom(c) > pitch * 0.9 &&
                !(first-alongBottom(c) <= max(pitch,thickness)*3 && corroboratesLaneGlyph(c)) { break }
            first = min(first, alongTop(c))
        }
        if palette?.pairedSource == true || sourcePointDiameter != nil {
            // A colour match is not an independent glyph witness. Once the
            // source's paired style is established, disconnected or rejected
            // islands cannot bypass lane/peer admission through the trim veto.
            visibleStart=max(visibleStart,first)
            visibleEnd=min(visibleEnd,last)
        } else {
            // A primary-fill measurement is a rejection proof only. Without
            // an actually rejected outside island it cannot relax an existing
            // trim veto, authorize growth, or move the opposite endpoint.
            if primaryRejectedHead {visibleStart=max(visibleStart,first)}
            if primaryRejectedTail {visibleEnd=min(visibleEnd,last)}
        }
        if primaryRejectedHead || primaryRejectedTail {audit?([
            "primaryPointRejectedHead":primaryRejectedHead,"primaryPointRejectedTail":primaryRejectedTail])}
        audit?(["pitch": pitch, "first": first, "last": last,
                "eligible": eligible.map { ["top": alongTop($0), "bottom": alongBottom($0),
                                           "width": CGFloat($0.width)] }])
        let padding = max(1, pitch * 0.15)
        var upper = max(0, -first + padding), lower = max(0, last + padding - length)
        if terminalOnly || shortSource {
            // Supplemental pixels may override an existing DB result only for
            // a measured long thin stroke, never another arbitrary crop end.
            let terminals = eligible.filter { $0.ownedExtension || (!shortSource && ($0.sourceStyle ||
                (CGFloat($0.height) > thickness*1.6 && CGFloat($0.width) <= min(thickness*0.3,pitch*0.5)))) }
            if !terminals.contains(where: { alongTop($0) < 0 && alongBottom($0) >= first }) { upper = 0 }
            if !terminals.contains(where: { alongBottom($0) > length && alongTop($0) <= last }) { lower = 0 }
        }
        if shortSource,upper <= 1,lower <= 1 { return nil }
        if let protectedInk, refinesEndpointInk, generalized,
           palette != nil || max(darkEnergy, brightEnergy) >= max(1, min(darkEnergy, brightEnergy)) * 4 {
            var core = protectedInk.map { ($0.x-head.x)*axis.x+($0.y-head.y)*axis.y }
            if let palette {
                // DB components describe regions and may contain the coloured
                // paper too. Only source foreground at private seed cells can
                // impose an ink keep constraint; visible unseeded strokes are
                // independently protected by visibleStart/visibleEnd below.
                var secondaryColours=[Int:[[Int]]]()
                let primaryInk=inkStyles.flatMap { styles in
                    styles.indices.contains(index) ? styles[index]?.colors.first:nil
                } ?? palette.inkStyle.colors[0]
                func independentInkHue(_ colour:[Int])->Bool {
                    // Neutral paper and antialias shades must retain their
                    // existing paired-ink tests. Only a genuinely different
                    // source hue needs this additional keep constraint.
                    guard colour.max()!-colour.min()!>=32 else {return false}
                    let mean=Double(colour.reduce(0,+))/3
                    let b=colour.map{Double($0)-mean}
                    return palette.inkStyle.colors.allSatisfy { primary in
                        let center=Double(primary.reduce(0,+))/3
                        let a=primary.map{Double($0)-center},energy=a.reduce(0){$0+$1*$1}
                        guard energy>=256 else {return true}
                        let alpha=zip(a,b).reduce(0){$0+$1.0*$1.1}/energy
                        return alpha<0 || zip(a,b).map{abs($1-alpha*$0)}.max()!>16
                    }
                }
                for row in 0..<rows where measuredRows[row] {
                    var paper:[Int]?
                    for column in 0..<columns {
                        let cell=row*columns+column
                        if palette.seeds[cell],palette.mask[cell]==0,privateContrast.indices.contains(cell),
                           privateContrast[cell] != 0,let c=rgb(row,column),independentInkHue(c) {
                            if paper==nil {
                                let border=(0..<rim).flatMap{[rgb(row,$0),rgb(row,columns-1-$0)]}.compactMap{$0}
                                if border.count>=2 {paper=(0..<3).map{channel in border.map{$0[channel]}.sorted()[border.count/2]}}
                            }
                            guard let paper else {continue}
                            let source=zip(primaryInk,paper).map{$0-$1},extra=zip(c,paper).map{$0-$1}
                            let sourceStrength=source.map{abs($0)}.max()!,extraStrength=extra.map{abs($0)}.max()!
                            // New hues must remain print against this local
                            // paper, not an opposite-polarity shadow or a faint
                            // tint of the backing. Existing paired ink stays
                            // governed by its independent companion proof.
                            guard sourceStrength>=24,source.reduce(0,+)*extra.reduce(0,+)>0,
                                  Double(extraStrength)>=max(24,Double(sourceStrength)*0.5) else {continue}
                            let key=(c[0]/32)*64+(c[1]/32)*8+c[2]/32
                            secondaryColours[key,default:[]].append(c)
                        }
                    }
                }
                let secondary=secondaryColours.keys.sorted().compactMap { key -> [Int]? in
                    let samples=secondaryColours[key]!
                    guard samples.count>=8 else {return nil}
                    return (0..<3).map{channel in samples.map{$0[channel]}.sorted()[samples.count/2]}
                }
                let ownSeeds=Set((sourceEvidence?.components ?? []).map(\.seed))
                let foreign=boxes.indices.compactMap { peer -> [CGPoint]? in
                    guard peer != index,!continuationPeers.contains(peer),let e=boxes[peer].detectorSeedEvidence,
                          e.isValid,e.ownerID != sourceEvidence?.ownerID,
                          e.components.contains(where:{!ownSeeds.contains($0.seed)}),
                          NativeOCRDirectionGeometry.intersectionArea(ownerPolygon,boxes[peer].polygon)>0 else {return nil}
                    return boxes[peer].polygon
                }
                // Newly classified colours must form bounded print, not the
                // paper around it. Observe extra normal context so a clipped
                // glyph can close while a background connected to the rim fails.
                var closedKeep=[Bool](repeating:false,count:secondary.isEmpty ? 0:columns*rows)
                var closedComponents=0
                if !secondary.isEmpty {
                    let margin=max(3,Int(ceil(thickness*0.3))),wide=columns+margin*2
                    let low=max(0,Int(floor(ownerBounds.minY-start-thickness*0.5)))
                    let high=min(rows,Int(ceil(ownerBounds.maxY-start+thickness*0.5)))
                    let tall=high-low
                    if tall>0,wide<=1_048_576/tall {
                        var labels=[Int](repeating:-1,count:wide*tall)
                        for y in 0..<tall {for x in 0..<wide {
                            if let c=rgb(low+y,x-margin) {
                                var best=25,bestID = -1
                                for i in secondary.indices {
                                    let distance=zip(c,secondary[i]).map{abs($0-$1)}.max()!
                                    if distance<best {best=distance;bestID=i}
                                }
                                labels[y*wide+x]=bestID
                            }
                        }}
                        var queue:[Int]=[]
                        for seed in labels.indices where labels[seed]>=0 {
                            let family=labels[seed];labels[seed] = -1;queue.removeAll(keepingCapacity:true);queue.append(seed)
                            var cursor=0,left=wide,right=0,top=tall,bottom=0,sourcePixels=0,roots=0,open=false
                            while cursor<queue.count {
                                let cell=queue[cursor];cursor+=1;let x=cell%wide,y=cell/wide,row=low+y,column=x-margin
                                left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                                if x==0 || x==wide-1 {open=true}
                                if column>=0,column<columns {
                                    let original=row*columns+column
                                    if sourceMask?[original] != false {
                                        let world=point(start+CGFloat(row)+0.5,CGFloat(column)+0.5)
                                        if NativeOCRDirectionGeometry.contains(ownerPolygon,world),
                                           !foreign.contains(where:{NativeOCRDirectionGeometry.contains($0,world)}) {
                                            sourcePixels+=1
                                            if palette.seeds[original] {roots+=1}
                                        }
                                    }
                                }
                                for dy in -1...1 {for dx in -1...1 where dx != 0 || dy != 0 {
                                    let xx=x+dx,yy=y+dy
                                    if xx>=0,xx<wide,yy>=0,yy<tall {
                                        let next=yy*wide+xx
                                        if labels[next]==family {labels[next] = -1;queue.append(next)}
                                    }
                                }}
                            }
                            let center=CGFloat(left+right+1)/2-CGFloat(margin)
                            guard !open,queue.count>=4,center>=CGFloat(bodyLeft)-acrossMargin,
                                  center<=CGFloat(bodyRight+1)+acrossMargin,CGFloat(right-left+1)<=thickness*1.6,
                                  CGFloat(bottom-top+1)<=thickness*2,
                                  roots>=2 || (sourcePixels>=8 && sourcePixels*2>=queue.count) else {continue}
                            closedComponents+=1
                            for cell in queue {
                                let row=low+cell/wide,column=cell%wide-margin
                                if column>=0,column<columns {
                                    let original=row*columns+column
                                    let world=point(start+CGFloat(row)+0.5,CGFloat(column)+0.5)
                                    if sourceMask?[original] != false,NativeOCRDirectionGeometry.contains(ownerPolygon,world),
                                       !foreign.contains(where:{NativeOCRDirectionGeometry.contains($0,world)}) {closedKeep[original]=true}
                                }
                            }
                        }
                    }
                }
                var sourceRows: [Int] = [],contrastRows=0,secondaryRows=0
                for row in 0..<rows {
                    let along = start+CGFloat(row)
                    guard along >= 0, along < length else { continue }
                    var direct=false,contrast=0,sourceColour=0
                    for column in 0..<columns {
                        let cell = row*columns+column
                        if palette.seeds[cell] {
                            if palette.mask[cell] != 0 {direct=true}
                            if closedKeep.indices.contains(cell),closedKeep[cell] {contrast+=1}
                        } else if closedKeep.indices.contains(cell),closedKeep[cell] {sourceColour+=1
                        }
                    }
                    if direct || contrast>=2 || sourceColour>=2 {sourceRows.append(row)}
                    if !direct,contrast>=2 {contrastRows+=1}
                    if !direct,contrast<2,sourceColour>=2 {secondaryRows+=1}
                }
                if contrastRows>0 {audit?(["privateContrastKeepRows":contrastRows,
                    "privateContrastFirstRow":sourceRows.first ?? -1,"privateContrastLastRow":sourceRows.last ?? -1])}
                if secondaryRows>0 || contrastRows>0 {audit?(["sourceColourKeepRows":secondaryRows,
                    "sourceColourFamilies":secondary.count,"closedSourceColourComponents":closedComponents])}
                if let firstRow = sourceRows.first, let lastRow = sourceRows.last,
                   CGFloat(lastRow-firstRow) >= thickness*2 {
                    core = [start+CGFloat(firstRow),start+CGFloat(lastRow+1)]
                }
            }
            if let coreStart = core.min(), let coreEnd = core.max(), coreEnd-coreStart >= thickness*2 {
                audit?(["trimCoreStart":coreStart,"trimCoreEnd":coreEnd,
                        "visibleStart":visibleStart,"visibleEnd":visibleEnd,"palette":palette != nil])
                // Trimming needs BOTH empty source-pixel padding and complete
                // private detector ink inside the kept interval. A weak RF
                // mask alone cannot delete a source-pixel terminal stroke.
                let keptStart = min(first,coreStart,visibleStart)-padding
                let keptEnd = max(last,coreEnd,visibleEnd)+padding
                // Empty padding is measured in source pixels. Requiring
                // three quarters of a glyph silently retained smaller proven
                // overextensions, especially on wide outlined lettering.
                if keptStart > 1 { upper = -keptStart }
                if length-keptEnd > 1 { lower = keptEnd-length }
            }
        }
        if unanchored {
            let terminals = eligible.filter { $0.ownedExtension || (refinesEndpointInk && CGFloat($0.height) > thickness*1.6 &&
                CGFloat($0.width) <= min(thickness*0.3,pitch*0.5)) }
            let extendedHead = terminals.contains { alongTop($0) <= first+1 && alongBottom($0) >= -pitch*0.9 }
            let extendedTail = terminals.contains { alongBottom($0) >= last-1 && alongTop($0) <= length+pitch*0.9 }
            // An independently measured continuous bar may exceed one glyph.
            // Other RF-free components retain the calibrated small budget.
            let budget=pitch*1.5+padding,rounding=max(1e-6,abs(budget)*1e-12)
            guard (upper <= budget+rounding || extendedHead),
                  (lower <= budget+rounding || extendedTail) else { return nil }
        }
        guard abs(upper) > 1 || abs(lower) > 1, length+upper+lower >= thickness*2 else { return nil }
        let result = [CGPoint(x: p[0].x - axis.x * upper, y: p[0].y - axis.y * upper),
            CGPoint(x: p[1].x - axis.x * upper, y: p[1].y - axis.y * upper),
            CGPoint(x: p[2].x + axis.x * lower, y: p[2].y + axis.y * lower),
            CGPoint(x: p[3].x + axis.x * lower, y: p[3].y + axis.y * lower)]
        guard result.allSatisfy({ canvas.contains($0) }) else { return nil }
        if first < last {
            inkObserver?([point(first,0),point(first,CGFloat(columns)),
                          point(last,CGFloat(columns)),point(last,0)])
        }
        let sourceTerminals=eligible.filter { c in
            if c.ownedExtension { return true }
            guard observation != nil,CGFloat(c.height) > thickness*1.6,
                  CGFloat(c.width) <= thickness*0.3 else { return false }
            if c.ownedCore { return true }
            return body.contains { anchor in
                let overlap=min(c.right,anchor.right)-max(c.left,anchor.left)+1
                let gap=max(c.top,anchor.top)-min(c.bottom,anchor.bottom)-1
                return CGFloat(overlap) >= CGFloat(min(c.width,anchor.width))*0.5 && CGFloat(gap) <= thickness*0.5
            }
        }
        let terminalHead=min(CGFloat(0),sourceTerminals.map(alongTop).min() ?? 0)
        let terminalTail=max(length,sourceTerminals.map(alongBottom).max() ?? length)
        if terminalHead < -1 || terminalTail > length+1 {
            terminalObserver?([point(terminalHead,0),point(terminalHead,CGFloat(columns)),
                               point(terminalTail,CGFloat(columns)),point(terminalTail,0)])
        }
        var restored = original
        for i in order.indices { restored[order[i]] = result[i] }
        return restored
    }

    /// A colour family must be enriched in private DB ink over adjacent paper.
    /// Target geometry and recognized strings never participate in this fit.
    static func endpointPalette(evidence: NativeOCRDetectorSeedEvidence, columns: Int, rows: Int,
                                start: CGFloat, length: CGFloat, project: (CGPoint) -> CGPoint,
                                rgb: (Int, Int) -> [Int]?, audit: (([String: Any]) -> Void)? = nil, styleOnly: Bool = false,
                                sourceMask: [Bool]? = nil,
                                candidatePeerPolygons:[String:[[CGPoint]]] = [:]) -> (mask: [UInt8], seeds: [Bool], first: CGFloat, last: CGFloat, growthMask: [UInt8], chromaticMask: [UInt8], primaryMask: [UInt8], inkStyle: EndpointInkStyle, pairedSource: Bool)? {
        guard evidence.isValid else { return nil }
        func key(_ c: [Int]) -> Int { (c[0]/32)*64+(c[1]/32)*8+c[2]/32 }
        let sx=CGFloat(evidence.sourceWidth)/CGFloat(evidence.mapFullWidth)
        let sy=CGFloat(evidence.sourceHeight)/CGFloat(evidence.mapFullHeight)
        var seeds=[Bool](repeating:false,count:columns*rows)
        var sampleRows: [Int] = []
        var samples: [[Int]]=[],foreground=[Int](repeating:0,count:512),paper=foreground
        var paletteBands = [Set<Int>](repeating: [], count: 512)
        var occupiedBands = Set<Int>()
        func collect(_ component:NativeOCRDetectorSeedEvidence.Component,excluding peers:[[CGPoint]] = []) {
          for run in component.runs { for x in run.x..<(run.x+run.count) {
            let world=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
            guard !peers.contains(where:{NativeOCRDirectionGeometry.contains($0,world)}) else { continue }
            let p=project(world)
            let column=Int(p.x.rounded()),row=Int(p.y.rounded())
            guard column >= 0,column < columns,row >= 0,row < rows,
                  start+CGFloat(row) >= 0,start+CGFloat(row) < length,
                  let c=rgb(row,column) else { continue }
            // A shared detector CC can cross a deliberately separated crop.
            // Learn the current read's ink only; other parts are not anchors.
            let cell=row*columns+column
            if let sourceMask, !sourceMask[cell] { continue }
            if !seeds[cell] {
                seeds[cell]=true;samples.append(c);sampleRows.append(row);foreground[key(c)]+=1
                let band = Int(floor((start+CGFloat(row))/CGFloat(columns)))
                paletteBands[key(c)].insert(band);occupiedBands.insert(band)
            }
          } }
        }
        for component in evidence.components { collect(component) }
        let privateSamples=samples.count
        if samples.count < 8 {
            // A complete detector component may touch another read by only a
            // few cells. Keep its established ownership; learn colour only
            // from cells inside this source crop and outside EVERY recorded
            // competitor, whose actual polygon must be available.
            for candidate in evidence.candidateComponents ?? [] {
                guard candidate.competingOwnerIDs.allSatisfy({ !(candidatePeerPolygons[$0]?.isEmpty ?? true) }) else { continue }
                let peers=candidate.competingOwnerIDs.flatMap { candidatePeerPolygons[$0] ?? [] }
                collect(candidate.component,excluding:peers)
            }
        }
        audit?(["sourcePrivateFontSamples":privateSamples,"exclusiveCandidateFontSamples":samples.count-privateSamples])
        guard samples.count >= 8 else { return nil }
        let rim=max(2,columns/8)
        var paperCount=0
        for row in 0..<rows where start+CGFloat(row) >= 0 && start+CGFloat(row) <= length {
            for column in 1...rim {
                for position in [-column,columns+column-1,column-1,columns-column] {
                    if let c=rgb(row,position) { paper[key(c)]+=1;paperCount+=1 }
                }
            }
        }
        guard paperCount >= 8 else { return nil }
        var ranked: [(Int,Double)]=[]
        for k in 0..<512 {
            let f=Double(foreground[k])/Double(samples.count),g=Double(paper[k])/Double(paperCount)
            let enrichment=(f+0.001)/(g+0.001)
            // DB predicts text regions, including paper/artwork between
            // strokes. A rare local background patch must not teach a global
            // ink family simply because the outside gutter has another colour.
            // Weight colour evidence by repetition along the actual read.
            let repetition = sqrt(Double(paletteBands[k].count)/Double(max(1,occupiedBands.count)))
            if f >= 0.015,enrichment >= 2 { ranked.append((k,f*log(enrichment)*repetition)) }
        }
        ranked.sort { $0.1 > $1.1 }
        guard let peak=ranked.first?.1 else { return nil }
        // The inside rim is essential when lettering sits on a coloured
        // tile whose paper ends exactly at the crop boundary. Outside gutters
        // alone would incorrectly teach that entire tile as a text colour.
        let selected = ranked.prefix(5).filter { $0.1 >= peak*0.15 }
        let inkKeys = Set(selected.map { $0.0 })
        var palettes=selected.map { item -> (ink: [Int], contrast: [Double]?) in
            let indices = samples.indices.filter { key(samples[$0]) == item.0 }
            let group = indices.map { samples[$0] }
            let ink = (0..<3).map { channel in group.map { $0[channel] }.sorted()[group.count/2] }
            // Associate a palette with the paper on its own source rows. A veil
            // changes both colours; observed contrast then scales the original
            // ink-minus-paper vector, rather than pointing at the old ink RGB.
            let sourceRows = Set(indices.map { sampleRows[$0] })
            let backgroundSamples = sourceRows.flatMap { row in
                (1...rim).flatMap { [rgb(row,-$0),rgb(row,columns+$0-1),rgb(row,$0-1),rgb(row,columns-$0)] }
                    .compactMap { $0 }.filter { !inkKeys.contains(key($0)) }
            }
            let contrast: [Double]? = backgroundSamples.count >= 2 ? (0..<3).map { channel in
                Double(ink[channel])-Double(backgroundSamples.map { $0[channel] }.sorted()[backgroundSamples.count/2])
            } : nil
            return (ink, contrast)
        }
        var tolerances=palettes.map { colour -> Int in
            guard let d=colour.contrast else { return 48 }
            return max(1,min(48,Int(floor((d.map { abs($0) }.max() ?? 120)*0.4))))
        }
        var primaryFamilies=palettes.map { colour -> Bool in
            if zip(colour.ink,palettes[0].ink).map({abs($0-$1)}).max()! <= 48 { return true }
            guard let a=palettes[0].contrast,let b=colour.contrast else { return false }
            let energy=a.reduce(0) { $0+$1*$1 }
            guard energy >= 900 else { return false }
            let alpha=zip(a,b).reduce(0) { $0+$1.0*$1.1 }/energy
            // Antialias shades share the ink-minus-paper vector. Brightness
            // alone cannot turn their thin strokes into a separate paper layer.
            return alpha > 0 && zip(a,b).map { abs($1-alpha*$0) }.max()! <= 16
        }
        if styleOnly {
            return ([],seeds,length,0,[],[],[],EndpointInkStyle(colors:palettes.map(\.ink)),false)
        }
        // A private DB component may cover only the outline. A repeated
        // contrasting interior, bracketed by that observed colour in the
        // source crop, supplies a companion layer without inventing DB owners.
        let styleColours=palettes.map(\.ink)
        var orderedCompanion=false
        if let companion=sourceCompanionInk(primary:palettes[0].ink,
            tolerance:tolerances[0],seeds:seeds,sourceMask:sourceMask,columns:columns,rows:rows,
            start:start,length:length,paper:paper,paperCount:paperCount,sourceContrast:palettes[0].contrast,rgb:rgb) {
            if primaryFamilies.allSatisfy({ $0 }) {
                palettes.append((companion.ink,companion.contrast))
                tolerances.append(companion.tolerance)
                primaryFamilies.append(false)
                orderedCompanion=true
                audit?(["sourceBracketedCompanionInk":companion.ink,"sourceBracketedCompanionBands":companion.bands,
                        "sourceBracketedCompanionSamples":companion.samples])
            } else if palettes.indices.contains(where: { i in
                !primaryFamilies[i] && zip(palettes[i].ink,companion.ink).map({abs($0-$1)}).max()! <= min(tolerances[i],companion.tolerance)
            }) {
                orderedCompanion=true
                audit?(["sourceBracketedExistingCompanionInk":companion.ink,"sourceBracketedCompanionBands":companion.bands])
            }
        }
        audit?(["colourFit":palettes.map { colour in
            ["ink":colour.ink,"contrast":colour.contrast ?? []] as [String: Any]
        }])
        var unpairedPaperTones:UInt8=0
        if !orderedCompanion,let reference=palettes.first?.contrast {
            let strength=reference.map { abs($0) }.max() ?? 0
            for i in palettes.indices where !primaryFamilies[i] {
                if let contrast=palettes[i].contrast,
                   contrast.max()!-contrast.min()! < 32,
                   contrast.map({abs($0)}).max()! < strength*0.5 { unpairedPaperTones |= UInt8(1)<<i }
            }
        }
        var mask=[UInt8](repeating:0,count:columns*rows),first=length,last:CGFloat=0
        var growthMask = mask
        var chromaticMask = mask
        var primaryMask = mask
        var primaryFamilyMask = mask
        var secondaryDirectMask = mask
        var paletteVotes=[UInt8](repeating:0,count:mask.count)
        for row in 0..<rows {
            // Classification and training must observe the same local paper.
            // Outside-only paper turns a coloured tile into a false alpha mix
            // even after that tile was correctly rejected as a source palette.
            let border=(1...rim).flatMap {
                [rgb(row,-$0),rgb(row,columns+$0-1),rgb(row,$0-1),rgb(row,columns-$0)]
            }.compactMap { $0 }
            guard border.count >= 2 else {
                // Missing off-canvas search context is not missing source ink.
                // An unmeasured original row remains unknown and vetoes a fit.
                if start+CGFloat(row) >= 0, start+CGFloat(row) < length { return nil }
                continue
            }
            let background=(0..<3).map { channel in Double(border.map { $0[channel] }.sorted()[border.count/2]) }
            var visible=0
            for column in 0..<columns {
                guard let c=rgb(row,column) else {
                    if start+CGFloat(row) >= 0, start+CGFloat(row) < length { return nil }
                    continue
                }
                let matchingIDs = palettes.indices.filter { i in zip(c,palettes[i].ink).map { abs($0-$1) }.max()! <= tolerances[i] }
                // A bracketed companion certifies a pair; it is not another
                // admitted ink family or a new detector-owned foreground.
                let admittedIDs=matchingIDs.filter { $0 < styleColours.count }
                let matching=admittedIDs.map { palettes[$0] }
                for i in matchingIDs { paletteVotes[row*columns+column] |= UInt8(1)<<i }
                let direct = !matching.isEmpty
                if matchingIDs.contains(0) { primaryMask[row*columns+column]=1 }
                if matchingIDs.contains(where:{primaryFamilies[$0]}) { primaryFamilyMask[row*columns+column]=1 }
                if matchingIDs.contains(where:{ i in !primaryFamilies[i] &&
                    zip(palettes[i].ink,palettes[0].ink).map { abs($0-$1) }.max()! > 96
                }) { secondaryDirectMask[row*columns+column]=1 }
                var chromatic = matching.contains { colour in
                    guard let d = colour.contrast else { return false }
                    return d.max()!-d.min()! >= 32
                }
                mask[row*columns+column]=direct ? 1 : 0
                growthMask[row*columns+column]=direct ? 1 : 0
                var faded=false
                if !direct {
                    for (paletteIndex,colour) in palettes.enumerated() {
                        // A neutral mix can propose a connected continuation;
                        // only a chromatic mix supplies a separate trim veto.
                        if let d = colour.contrast {
                        let observed=(0..<3).map { Double(c[$0])-background[$0] }
                        let magnitude=d.reduce(0) { $0+$1*$1 }
                        guard magnitude >= 900 else { continue }
                        let alpha=zip(observed,d).reduce(0) { $0+$1.0*$1.1 }/magnitude
                        let residual=zip(observed,d).map { abs($0-alpha*$1) }.max()!
                        let cell=row*columns+column
                        let originalPixel=sourceMask?[cell] ?? (start+CGFloat(row) >= 0 && start+CGFloat(row) < length)
                        // A fixed RGB residual overwhelms the hue signal of
                        // very faded ink. Keep original pixels' tolerance;
                        // new growth must retain the measured contrast vector.
                        let inkChroma=colour.ink.max()!-colour.ink.min()!
                        let contrastChroma=d.max()!-d.min()!
                        let observedChroma=observed.max()!-observed.min()!
                        let missingInkHue=inkChroma >= 32 && contrastChroma >= 32 && observedChroma < max(0,alpha)*contrastChroma*0.5
                        let residualLimit = !originalPixel && missingInkHue ? max(4,16*min(1,alpha)):16
                        if alpha >= 0.12,alpha <= 1.2,residual <= residualLimit {
                            if paletteIndex >= styleColours.count {
                                // A common veil transforms both source colours.
                                // Companion evidence remains proof only, never growth.
                                secondaryDirectMask[row*columns+column]=1
                                continue
                            }
                            paletteVotes[row*columns+column] |= UInt8(1)<<paletteIndex
                            // Antialiased neutral strokes need growth evidence
                            // too. Achromatic shading still cannot veto a trim;
                            // that stronger keep proof remains chromatic only.
                            growthMask[row*columns+column]=1
                            // A faded outline colour also describes ordinary
                            // surface shading. It may continue connected ink,
                            // but cannot establish a detached new glyph. The
                            // source's primary chromatic fill remains a proof.
                            let primaryFamily=primaryFamilies[paletteIndex]
                            // Existing outline palettes need the same veil
                            // transform as inferred companions. This certifies
                            // pairing only; it does not admit a new glyph layer.
                            if !primaryFamily,zip(colour.ink,palettes[0].ink).map({abs($0-$1)}).max()! > 96 {
                                secondaryDirectMask[row*columns+column]=1
                            }
                            if primaryFamily,d.max()!-d.min()! >= 32 {
                                faded=true;chromatic=true;primaryFamilyMask[row*columns+column]=1
                            }
                        }
                        }
                    }
                }
                // Chromatic contrast certifies a disconnected source-style
                // glyph too; neutral shading still needs source connectivity.
                if faded { mask[row*columns+column]=1 }
                if chromatic { chromaticMask[row*columns+column]=1 }
                if direct || faded {
                    if let sourceMask { if sourceMask[row*columns+column] { visible+=1 } }
                    else { visible+=1 }
                }
            }
            if visible >= 2,start+CGFloat(row) >= 0,start+CGFloat(row+1) <= length {
                first=min(first,start+CGFloat(row));last=max(last,start+CGFloat(row+1))
            }
        }
        // A weak neutral patch inside a coloured DB region is not another
        // globally admitted print colour. Preserve its original pixels, but
        // require a measured companion pair before extending that tone alone.
        if unpairedPaperTones != 0 {
            var removed=0
            for cell in mask.indices {
                let originalPixel=sourceMask?[cell] ?? (start+CGFloat(cell/columns) >= 0 && start+CGFloat(cell/columns) < length)
                if !originalPixel,paletteVotes[cell] != 0,paletteVotes[cell] & ~unpairedPaperTones == 0 {
                    if growthMask[cell] != 0 { removed+=1 }
                    mask[cell]=0;growthMask[cell]=0;chromaticMask[cell]=0
                }
            }
            audit?(["unpairedPaperToneBits":Int(unpairedPaperTones),"unpairedPaperGrowthRemoved":removed])
        }
        var pairedSource=false
        if palettes.count > 1 {
            var surfacePalettes:UInt8=0
            let certified = certifyingSecondaryInk(mask:growthMask,primary:primaryMask,seeds:seeds,
                columns:columns,rows:rows,start:start,length:length,rgb:rgb,audit:audit,
                paletteVotes:paletteVotes,surfacePaletteObserver:{ surfacePalettes |= $0 })
            // The same source colour cannot be paper beneath the measured
            // lettering and then become an independent stroke in nearby art.
            // Primary ink and its close antialias shades retain their proofs.
            var distinctPalettes:UInt8=0
            for i in palettes.indices where !primaryFamilies[i] && zip(palettes[i].ink,palettes[0].ink).map({abs($0-$1)}).max()! > 96 {
                distinctPalettes |= UInt8(1)<<i
            }
            surfacePalettes &= distinctPalettes
            audit?(["sourceSurfacePaletteBits":Int(surfacePalettes)])
            for cell in mask.indices where certified[cell] == 0 {
                mask[cell]=0;growthMask[cell]=0;chromaticMask[cell]=0
            }
            if surfacePalettes != 0 {
                for cell in mask.indices where paletteVotes[cell] != 0 && paletteVotes[cell] & ~surfacePalettes == 0 {
                    mask[cell]=0;growthMask[cell]=0;chromaticMask[cell]=0;secondaryDirectMask[cell]=0
                }
            }
            let paired = certifyingSourceInkPair(mask:mask,primary:primaryMask,family:primaryFamilyMask,
                secondary:secondaryDirectMask,seeds:seeds,columns:columns,rows:rows,
                start:start,length:length,audit:audit,refineEnds:orderedCompanion,pairObserver:{ pairedSource=true })
            for cell in mask.indices where paired[cell] == 0 {
                mask[cell]=0;growthMask[cell]=0;chromaticMask[cell]=0
            }
            first=length;last=0
            for row in 0..<rows where start+CGFloat(row) >= 0 && start+CGFloat(row+1) <= length {
                if (0..<columns).filter({ column in
                    let cell=row*columns+column
                    return mask[cell] != 0 && (sourceMask?[cell] ?? true)
                }).count >= 2 {
                    first=min(first,start+CGFloat(row));last=max(last,start+CGFloat(row+1))
                }
            }
        }
        let textured = certifyingSourceInkTexture(mask:mask,family:primaryFamilyMask,seeds:seeds,
            columns:columns,rows:rows,start:start,length:length,rgb:rgb,audit:audit)
        for cell in mask.indices where mask[cell] != 0 && textured[cell] == 0 {
            mask[cell]=0;growthMask[cell]=0;chromaticMask[cell]=0
        }
        first=length;last=0
        for row in 0..<rows where start+CGFloat(row) >= 0 && start+CGFloat(row+1) <= length {
            if (0..<columns).filter({ mask[row*columns+$0] != 0 && (sourceMask?[row*columns+$0] ?? true) }).count >= 2 {
                first=min(first,start+CGFloat(row));last=max(last,start+CGFloat(row+1))
            }
        }
        // A neutral mixture can be arbitrary shading. Admit its weak pixels
        // only as a connected continuation of strong ink already observed in
        // the current read; disconnected neutral islands have no owner proof.
        var visited = [Bool](repeating: false, count: mask.count)
        var queue: [Int] = []
        for cell in mask.indices where mask[cell] != 0 {
            let along = start + CGFloat(cell/columns)
            if along >= 0, along < length { visited[cell] = true; queue.append(cell) }
        }
        var cursor = 0
        while cursor < queue.count {
            let cell = queue[cursor]; cursor += 1
            let row = cell/columns, column = cell%columns
            for dy in -1...1 { for dx in -1...1 {
                let y = row+dy, x = column+dx
                guard y >= 0, y < rows, x >= 0, x < columns else { continue }
                let next = y*columns+x
                if !visited[next], growthMask[next] != 0 { visited[next] = true; queue.append(next) }
            } }
        }
        for cell in growthMask.indices where mask[cell] == 0 && !visited[cell] { growthMask[cell] = 0 }
        if let audit {
            func runs(_ values:[UInt8])->[[[Int]]] {
                (0..<rows).map { row in
                    var spans:[[Int]]=[],column=0
                    while column < columns {
                        if values[row*columns+column] == 0 { column+=1;continue }
                        let first=column
                        while column < columns,values[row*columns+column] != 0 { column+=1 }
                        spans.append([first,column-first])
                    }
                    return spans
                }
            }
            audit(["maskColumns":columns,"maskRows":rows,"maskStart":start,"maskLength":length,
                   "primaryRuns":runs(primaryMask),"inkRuns":runs(mask),"growthRuns":runs(growthMask)])
        }
        return (mask,seeds,first,last,growthMask,chromaticMask,primaryMask,EndpointInkStyle(colors:styleColours),pairedSource)
    }

    /// Secondary colours need a stroke, not just a matching RGB. The existing
    /// source segmenter uses two-sided surface probes for this reason. Here the
    /// same test runs in the owner's intrinsic frame at its observed stroke scale.
    static func certifyingSecondaryInk(mask: [UInt8], primary: [UInt8], seeds: [Bool],
                                       columns: Int, rows: Int, start: CGFloat, length: CGFloat,
                                       rgb: (Int,Int) -> [Int]?,
                                       audit: (([String: Any]) -> Void)? = nil,
                                       paletteVotes:[UInt8] = [],surfacePaletteObserver:((UInt8)->Void)? = nil) -> [UInt8] {
        let count=columns*rows
        guard mask.count == count, primary.count == count, seeds.count == count, columns > 0, rows > 0 else { return mask }
        func distanceField(_ values:[UInt8])->[Int] {
            var distance=[Int](repeating:0,count:count)
        for y in 0..<rows { for x in 0..<columns {
            let p=y*columns+x
            if values[p] != 0 { distance[p]=1+min(x > 0 ? distance[p-1] : 0,y > 0 ? distance[p-columns] : 0) }
        } }
        for y in stride(from:rows-1,through:0,by:-1) { for x in stride(from:columns-1,through:0,by:-1) {
            let p=y*columns+x
            if values[p] != 0 {
                distance[p]=min(distance[p],1+min(x+1 < columns ? distance[p+1] : 0,y+1 < rows ? distance[p+columns] : 0))
            }
        } }
            return distance
        }
        let distance=distanceField(primary)
        let widths=distance.indices.filter {
            seeds[$0] && distance[$0] > 0 && start+CGFloat($0/columns) >= 0 && start+CGFloat($0/columns) < length
        }.map { distance[$0] }.sorted()
        guard !widths.isEmpty else { return mask }
        audit?(["sourceStrokeDepth":widths[min(widths.count-1,widths.count*9/10)],
                "sourceMedianDepth":widths[widths.count/2],"sourceStrokeSamples":widths.count])
        let radius=max(3,min(max(3,columns/3),widths[min(widths.count-1,widths.count*9/10)]*4))
        var pixels=[UInt8](repeating:0,count:count*3), measured=[Bool](repeating:false,count:count)
        for y in 0..<rows { for x in 0..<columns {
            let p=y*columns+x
            if let c=rgb(y,x) { measured[p]=true;for k in 0..<3 { pixels[p*3+k]=UInt8(c[k]) } }
        } }
        func colour(_ y:Int,_ x:Int)->[Int]? {
            if y >= 0,y < rows,x >= 0,x < columns {
                let p=y*columns+x
                return measured[p] ? (0..<3).map { Int(pixels[p*3+$0]) } : nil
            }
            return rgb(y,x)
        }
        var result=mask
        // A broad, dense secondary component surrounding primary glyphs is
        // their surface, not an outline. Keep independent secondary glyphs:
        // their own boxes do not enclose the primary lettering. This is the
        // same enclosure distinction used by the source glyph segmenter.
        var visited=[Bool](repeating:false,count:count), queue:[Int]=[]
        for seed in mask.indices where mask[seed] != 0 && primary[seed] == 0 && !visited[seed] {
            queue.removeAll(keepingCapacity:true);queue.append(seed);visited[seed]=true
            var cursor=0,left=columns,right=0,top=rows,bottom=0
            while cursor < queue.count {
                let cell=queue[cursor];cursor+=1;let y=cell/columns,x=cell%columns
                left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                for (dy,dx) in [(0,1),(0,-1),(1,0),(-1,0)] {
                    let yy=y+dy,xx=x+dx
                    guard yy >= 0,yy < rows,xx >= 0,xx < columns else { continue }
                    let next=yy*columns+xx
                    if !visited[next],mask[next] != 0,primary[next] == 0 {
                        visited[next]=true;queue.append(next)
                    }
                }
            }
            let area=(right-left+1)*(bottom-top+1)
            if let audit,area >= columns*columns/4 {
                var enclosed=0
                for y in top...bottom { for x in left...right where primary[y*columns+x] != 0 { enclosed+=1 } }
                audit(["secondaryComponentTop":start+CGFloat(top),"secondaryComponentBottom":start+CGFloat(bottom+1),
                       "secondaryComponentWidth":right-left+1,"secondaryComponentPixels":queue.count,
                       "secondaryComponentArea":area,"secondaryEnclosedPrimaryPixels":enclosed])
            }
            if CGFloat(right-left+1) >= CGFloat(columns)*0.75,
               bottom-top+1 >= columns/2,queue.count*5 >= area*3 {
                var contained=0
                for y in top...bottom { for x in left...right where primary[y*columns+x] != 0 { contained+=1 } }
                if contained*20 >= area {
                    for cell in queue { result[cell]=0 }
                    if paletteVotes.count == count,let surfacePaletteObserver {
                        var originalPrimary=0
                        for y in top...bottom where start+CGFloat(y) >= 0 && start+CGFloat(y) < length {
                            for x in left...right where primary[y*columns+x] != 0 && seeds[y*columns+x] { originalPrimary+=1 }
                        }
                        if originalPrimary >= 2 {
                            var paper:UInt8=0
                            for i in 0..<8 {
                                let bit=UInt8(1)<<i
                                if queue.filter({paletteVotes[$0] & bit != 0}).count*2 >= queue.count { paper |= bit }
                            }
                            surfacePaletteObserver(paper)
                        }
                    }
                }
            }
        }
        for cell in mask.indices where result[cell] != 0 && primary[cell] == 0 {
            let y=cell/columns,x=cell%columns
            guard let c=colour(y,x) else { continue }
            var stroke=false
            for (dy,dx) in [(0,1),(1,0),(1,1),(1,-1)] {
                func side(_ sign:Int)->[Double]? {
                    for step in 1...radius {
                        guard let q=colour(y+dy*step*sign,x+dx*step*sign) else { return nil }
                        let d=(0..<3).map { Double(c[$0]-q[$0]) }
                        if d.map({ abs($0) }).max()! >= 24 { return d }
                    }
                    return nil
                }
                if let a=side(-1),let b=side(1) {
                    let dot=zip(a,b).reduce(0) { $0+$1.0*$1.1 }
                    let aa=a.reduce(0) { $0+$1*$1 },bb=b.reduce(0) { $0+$1*$1 }
                    if dot > 0,dot*dot >= aa*bb*0.25 { stroke=true;break }
                }
            }
            if !stroke { result[cell]=0 }
        }
        // A colour outline may be thinner than its fill, but unrelated thin
        // drawing strokes cannot become a new glyph merely by sharing colour.
        // Calibrate that distinction from the current source's stroke weight.
        // Distance-to-background starts at one even for a single pixel. Its
        // ratio therefore overstates the width of a thin drawing fragment.
        // Compare actual complete cross-stroke runs in four intrinsic
        // directions; keep the distance radius for outline proximity only.
        func strokeSpans(_ values:[UInt8])->[Double] {
            var spans=values.map { $0 == 0 ? 0.0 : Double.infinity }
            for (dy,dx) in [(0,1),(1,0),(1,1),(1,-1)] {
                let step=hypot(Double(dx),Double(dy))
                for y in 0..<rows { for x in 0..<columns where values[y*columns+x] != 0 {
                    let previousY=y-dy,previousX=x-dx
                    if previousY >= 0,previousY < rows,previousX >= 0,previousX < columns,
                       values[previousY*columns+previousX] != 0 { continue }
                    var run=0,yy=y,xx=x
                    while yy >= 0,yy < rows,xx >= 0,xx < columns,values[yy*columns+xx] != 0 {
                        run+=1;yy+=dy;xx+=dx
                    }
                    let width=Double(run)*step
                    for offset in 0..<run {
                        let p=(y+offset*dy)*columns+x+offset*dx
                        spans[p]=min(spans[p],width)
                    }
                } }
            }
            return spans
        }
        let primarySpans=strokeSpans(primary)
        let sourceSpans=primary.indices.filter {
            seeds[$0] && primary[$0] != 0 && start+CGFloat($0/columns) >= 0 && start+CGFloat($0/columns) < length
        }.map { primarySpans[$0] }.sorted()
        let sourceWeight=sourceSpans[min(sourceSpans.count-1,sourceSpans.count*9/10)]
        let outlineRadius=max(2,widths[min(widths.count-1,widths.count*9/10)])
        audit?(["sourceStrokeSpan":sourceWeight])
        var proximity=[Int](repeating:-1,count:count),front:[Int]=[]
        for p in primary.indices where primary[p] != 0 { proximity[p]=0;front.append(p) }
        var cursor=0
        while cursor < front.count {
            let p=front[cursor];cursor+=1
            guard proximity[p] < outlineRadius else { continue }
            let y=p/columns,x=p%columns
            for (dy,dx) in [(0,1),(0,-1),(1,0),(-1,0)] {
                let yy=y+dy,xx=x+dx
                guard yy >= 0,yy < rows,xx >= 0,xx < columns else { continue }
                let next=yy*columns+xx
                if proximity[next] < 0 { proximity[next]=proximity[p]+1;front.append(next) }
            }
        }
        func cohorts(_ values:[UInt8], primaryLayer:Bool) {
            let field=primaryLayer ? primarySpans : strokeSpans(values)
            var seen=[Bool](repeating:false,count:count),pixels:[Int]=[]
            for seed in values.indices where values[seed] != 0 && !seen[seed] {
                pixels.removeAll(keepingCapacity:true);pixels.append(seed);seen[seed]=true
                var cursor=0,x0=columns,x1=0,y0=rows,y1=0,inside=0
                while cursor < pixels.count {
                    let p=pixels[cursor];cursor+=1;let y=p/columns,x=p%columns
                    x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                    if start+CGFloat(y) >= 0,start+CGFloat(y) < length { inside+=1 }
                    for (dy,dx) in [(0,1),(0,-1),(1,0),(-1,0)] {
                        let yy=y+dy,xx=x+dx
                        guard yy >= 0,yy < rows,xx >= 0,xx < columns else { continue }
                        let next=yy*columns+xx
                        if !seen[next],values[next] != 0 { seen[next]=true;pixels.append(next) }
                    }
                }
                if primaryLayer && inside*2 >= pixels.count { continue }
                let weights=pixels.map { field[$0] }.sorted()
                let weight=Double(weights[min(weights.count-1,weights.count*9/10)])
                let comparable=weight >= sourceWeight*0.45 && weight <= sourceWeight*2.2
                let terminal=y1-y0+1 >= (x1-x0+1)*8
                if !comparable && !terminal {
                    for p in pixels {
                        if primaryLayer || proximity[p] < 0 { result[p]=0 }
                    }
                    audit?(["rejectedStrokeSpan":weight,"sourceStrokeSpan":sourceWeight,
                            "rejectedStrokeTop":start+CGFloat(y0),"rejectedStrokeBottom":start+CGFloat(y1+1)])
                }
            }
        }
        var secondary=result
        for p in secondary.indices where primary[p] != 0 { secondary[p]=0 }
        cohorts(secondary,primaryLayer:false)
        cohorts(primary,primaryLayer:true)
        return result
    }

    /// Discover a repeated contrasting colour inside source-colour brackets.
    /// This samples pixels inside the original quad only; it never changes the
    /// detector's private/candidate ownership or uses recognition/GT strings.
    static func sourceCompanionInk(primary:[Int],tolerance:Int,seeds:[Bool],sourceMask:[Bool]?,
        columns:Int,rows:Int,start:CGFloat,length:CGFloat,paper:[Int],paperCount:Int,
        sourceContrast:[Double]? = nil,rgb:(Int,Int)->[Int]?)->(ink:[Int],contrast:[Double]?,bands:Int,samples:Int,tolerance:Int)? {
        guard columns > 2,rows > 0,seeds.count == columns*rows,paper.count == 512,paperCount > 0 else { return nil }
        func key(_ c:[Int])->Int { (c[0]/32)*64+(c[1]/32)*8+c[2]/32 }
        var counts=[Int](repeating:0,count:512),bands=[Set<Int>](repeating:[],count:512)
        var samples:[(colour:[Int],row:Int,key:Int)]=[]
        for y in 0..<rows where start+CGFloat(y) >= 0 && start+CGFloat(y) < length {
            var anchors:[Int]=[],privateAnchor=false
            for x in 0..<columns {
                let cell=y*columns+x
                guard sourceMask?[cell] ?? true,let c=rgb(y,x),zip(c,primary).map({abs($0-$1)}).max()! <= tolerance else { continue }
                anchors.append(x)
                if seeds[cell] { privateAnchor=true }
            }
            guard privateAnchor,let first=anchors.first,let last=anchors.last,first+1 < last else { continue }
            let rim=max(2,columns/8)
            let probes=(1...rim).flatMap { step in
                [-step,columns+step-1,step-1,columns-step].compactMap { rgb(y,$0) }
            }
            let localPaper=probes.count >= 2 ? (0..<3).map { k in
                Double(probes.map { $0[k] }.sorted()[probes.count/2])
            } : nil
            for x in (first+1)..<last {
                let cell=y*columns+x
                guard sourceMask?[cell] ?? true,let c=rgb(y,x),zip(c,primary).map({abs($0-$1)}).max()! > 96 else { continue }
                if let sourceContrast,sourceContrast.count==3 {
                    // The source already supplies an ink-minus-paper vector.
                    // A glyph can cover this row's border probes, so retain that
                    // independent reference when rejecting antialias mixtures.
                    let observed=(0..<3).map { Double(c[$0]-primary[$0])+sourceContrast[$0] }
                    let energy=sourceContrast.reduce(0) { $0+$1*$1 }
                    if energy > 0 {
                        let alpha=zip(sourceContrast,observed).reduce(0) { $0+$1.0*$1.1 }/energy
                        let residual=zip(sourceContrast,observed).map { abs($1-alpha*$0) }.max()!
                        if alpha >= -0.1,alpha <= 1.1,residual <= 16 { continue }
                    }
                }
                // Letter counters reveal paper too. A colour along this row's
                // ink-to-paper mixture is paper or antialiasing, not independent
                // companion ink; global histogram enrichment cannot prove it.
                if let localPaper {
                    let ink=zip(primary,localPaper).map { Double($0)-$1 }
                    let observed=zip(c,localPaper).map { Double($0)-$1 }
                    let energy=ink.reduce(0) { $0+$1*$1 }
                    if energy > 0 {
                        let alpha=zip(ink,observed).reduce(0) { $0+$1.0*$1.1 }/energy
                        let residual=zip(ink,observed).map { abs($1-alpha*$0) }.max()!
                        if alpha >= -0.1,alpha <= 1.1,residual <= 16 { continue }
                    }
                }
                let k=key(c);counts[k]+=1;bands[k].insert(Int(floor((start+CGFloat(y))/CGFloat(columns))))
                samples.append((c,y,k))
            }
        }
        guard samples.count >= 8 else { return nil }
        var ranked:[(key:Int,weight:Double)]=[]
        for k in 0..<512 where counts[k] >= 8 && bands[k].count >= 2 {
            let f=Double(counts[k])/Double(samples.count),g=Double(paper[k])/Double(paperCount)
            let enrichment=(f+0.001)/(g+0.001)
            if f >= 0.015,enrichment >= 2 { ranked.append((k,f*log(enrichment))) }
        }
        ranked.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.key < $1.key }
        guard let best=ranked.first else { return nil }
        let group=samples.filter { $0.key == best.key }
        let colour=(0..<3).map { k in group.map { $0.colour[k] }.sorted()[group.count/2] }
        let rim=max(2,columns/8)
        var background:[[Int]]=[]
        for y in Set(group.map(\.row)) {
            for step in 1...rim {
                for x in [-step,columns+step-1,step-1,columns-step] {
                    guard let sample=rgb(y,x),key(sample) != best.key else { continue }
                    let difference=zip(sample,primary).map { abs($0-$1) }.max()!
                    if difference > tolerance { background.append(sample) }
                }
            }
        }
        let contrast:[Double]?
        if background.count >= 2 {
            var values:[Double]=[]
            for channel in 0..<3 {
                let sorted=background.map { $0[channel] }.sorted()
                values.append(Double(colour[channel])-Double(sorted[sorted.count/2]))
            }
            contrast=values
        } else { contrast=nil }
        let residuals=group.map { sample in zip(sample.colour,colour).map { abs($0-$1) }.max()! }.sorted()
        let tolerance=max(16,residuals[min(residuals.count-1,residuals.count*9/10)])
        return (colour,contrast,bands[best.key].count,group.count,tolerance)
    }

    /// A flat printed fill can change colour under a common veil, but its
    /// interior remains a coherent colour. Nearby artwork can match the same
    /// contrast vector while having a textured interior. Measure dispersion
    /// around each component's OWN median, using the original private ink as
    /// the noise reference; absolute colour changes are not a rejection.
    static func certifyingSourceInkTexture(mask:[UInt8],family:[UInt8],seeds:[Bool],
        columns:Int,rows:Int,start:CGFloat,length:CGFloat,rgb:(Int,Int)->[Int]?,
        audit:(([String:Any])->Void)? = nil) -> [UInt8] {
        let count=columns*rows
        guard columns > 2,rows > 2,mask.count == count,family.count == count,seeds.count == count else { return mask }
        func interior(_ p:Int)->Bool {
            let y=p/columns,x=p%columns
            return x > 0 && x+1 < columns && y > 0 && y+1 < rows &&
                [p,p-1,p+1,p-columns,p+columns].allSatisfy { mask[$0] != 0 && family[$0] != 0 }
        }
        func scatter(_ colours:[[Int]])->Int {
            let median=(0..<3).map { k in colours.map { $0[k] }.sorted()[colours.count/2] }
            let residuals=colours.map { c in zip(c,median).map { abs($0-$1) }.max()! }.sorted()
            return residuals[min(residuals.count-1,residuals.count*9/10)]
        }
        let original=mask.indices.filter {
            seeds[$0] && interior($0) && start+CGFloat($0/columns) >= 0 && start+CGFloat($0/columns) < length
        }.compactMap { rgb($0/columns,$0%columns) }
        guard original.count >= 32 else { return mask }
        let sourceScatter=scatter(original)
        var referenceScatter=sourceScatter
        var candidates:[(cells:[Int],scatter:Int,top:Int,bottom:Int)] = []
        var seen=[Bool](repeating:false,count:count),result=mask,cells:[Int]=[]
        for seed in mask.indices where mask[seed] != 0 && !seen[seed] {
            cells.removeAll(keepingCapacity:true);cells.append(seed);seen[seed]=true
            var cursor=0,owned=false,left=columns,right=0,top=rows,bottom=0,colours:[[Int]]=[]
            while cursor < cells.count {
                let p=cells[cursor];cursor+=1;let y=p/columns,x=p%columns
                left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                if seeds[p] && family[p] != 0 { owned=true }
                if interior(p),let colour=rgb(y,x) { colours.append(colour) }
                for dy in -1...1 { for dx in -1...1 {
                    let yy=y+dy,xx=x+dx
                    guard yy >= 0,yy < rows,xx >= 0,xx < columns else { continue }
                    let next=yy*columns+xx
                    if !seen[next],mask[next] != 0 { seen[next]=true;cells.append(next) }
                } }
            }
            if let audit,colours.count >= 8 {
                audit(["componentInteriorColourScatter":scatter(colours),"componentInteriorColourOwned":owned,
                       "componentInteriorColourSamples":colours.count,"componentInteriorColourTop":start+CGFloat(top),
                       "componentInteriorColourBottom":start+CGFloat(bottom+1)])
            }
            if owned,colours.count >= 8 { referenceScatter=max(referenceScatter,scatter(colours)) }
            guard !owned,colours.count >= 8 else { continue }
            // A continuous terminal can cross different photographed surfaces;
            // its independently measured long thin geometry remains available.
            if CGFloat(right-left+1) <= CGFloat(columns)*0.3,CGFloat(bottom-top+1) > CGFloat(columns)*1.6 { continue }
            candidates.append((cells,scatter(colours),top,bottom))
        }
        // A new glyph may be as variable as any observed original glyph.
        // The 16-level residual floor is the same colour-fit resolution used
        // by the source palette; no unrelated stroke-width multiplier applies.
        let limit=max(16,referenceScatter)
        audit?(["sourceInteriorColourScatter":sourceScatter,"sourceInteriorColourLimit":limit,
                "sourceInteriorColourReferenceScatter":referenceScatter,"sourceInteriorColourSamples":original.count])
        for candidate in candidates where candidate.scatter > limit {
            for p in candidate.cells { result[p]=0 }
            audit?(["rejectedInteriorColourScatter":candidate.scatter,"rejectedInteriorColourTop":start+CGFloat(candidate.top),
                    "rejectedInteriorColourBottom":start+CGFloat(candidate.bottom+1),"rejectedInteriorColourPixels":candidate.cells.count])
        }
        return result
    }

    /// Learn paired fill/outline ink from the original private glyphs. A
    /// detached source-coloured drawing line lacks that observed font style.
    /// All distances are source-pixel distances in the intrinsic reading frame.
    static func certifyingSourceInkPair(mask:[UInt8],primary:[UInt8],family:[UInt8],
        secondary:[UInt8],seeds:[Bool],columns:Int,rows:Int,start:CGFloat,length:CGFloat,
        audit:(([String:Any])->Void)? = nil,refineEnds:Bool = false,pairObserver:(()->Void)? = nil) -> [UInt8] {
        let count=columns*rows
        guard columns > 0,rows > 0,[mask.count,primary.count,family.count,secondary.count,seeds.count].allSatisfy({$0==count}) else { return mask }
        var depth=[Int](repeating:0,count:count),near=[Int](repeating:columns+rows+1,count:count)
        for y in 0..<rows { for x in 0..<columns {
            let p=y*columns+x
            if primary[p] != 0 { depth[p]=1+min(x > 0 ? depth[p-1]:0,y > 0 ? depth[p-columns]:0) }
            if secondary[p] != 0 { near[p]=0 }
            else { near[p]=min(near[p],1+min(x > 0 ? near[p-1]:count,y > 0 ? near[p-columns]:count)) }
        } }
        for y in stride(from:rows-1,through:0,by:-1) { for x in stride(from:columns-1,through:0,by:-1) {
            let p=y*columns+x
            if primary[p] != 0 { depth[p]=min(depth[p],1+min(x+1 < columns ? depth[p+1]:0,y+1 < rows ? depth[p+columns]:0)) }
            near[p]=min(near[p],1+min(x+1 < columns ? near[p+1]:count,y+1 < rows ? near[p+columns]:count))
        } }
        let original=primary.indices.filter { primary[$0] != 0 && seeds[$0] && start+CGFloat($0/columns) >= 0 && start+CGFloat($0/columns) < length }
        guard original.count >= 32 else { return mask }
        let weights=original.map { depth[$0] }.sorted()
        var radius=max(2,weights[weights.count*9/10]*2)
        let measuredDistances=original.map { near[$0] }.sorted()
        let observedRadius=measuredDistances[measuredDistances.count*9/10]
        // Private detector samples can lie on an outline's outer edge. Its
        // measured companion distance is more informative than fill depth,
        // but a remote colour cannot establish a font-wide pairing radius.
        if refineEnds, observedRadius <= max(2,columns/3) { radius=max(radius,observedRadius) }
        let paired=original.filter { near[$0] <= radius }.count
        let fraction=Double(paired)/Double(original.count)
        audit?(["sourceInkPairFraction":fraction,"sourceInkPairRadius":radius])
        guard fraction >= 0.7 else { return mask }
        if refineEnds { pairObserver?() }
        var nearPrimary=[Int](repeating:columns+rows+1,count:count)
        for y in 0..<rows { for x in 0..<columns {
            let p=y*columns+x
            if family[p] != 0 { nearPrimary[p]=0 }
            else { nearPrimary[p]=1+min(x > 0 ? nearPrimary[p-1]:count,y > 0 ? nearPrimary[p-columns]:count) }
        } }
        for y in stride(from:rows-1,through:0,by:-1) { for x in stride(from:columns-1,through:0,by:-1) {
            let p=y*columns+x
            nearPrimary[p]=min(nearPrimary[p],1+min(x+1 < columns ? nearPrimary[p+1]:count,y+1 < rows ? nearPrimary[p+columns]:count))
        } }
        let pairedRows=original.filter { near[$0] <= radius }.map { $0/columns }
        let head=pairedRows.min()!,tail=pairedRows.max()!
        // A genuine terminal can continue in just one source colour. Measure
        // its uninterrupted narrow corridor before pair pruning destroys it.
        // It must attach to the paired core and span a character-scale length;
        // detached islands and short decorative bridges have no such proof.
        var terminalRows=Set<Int>()
        if refineEnds {
            for direction in [-1,1] {
                var y=direction < 0 ? head-1:tail+1
                var run:[Int]=[],previousX:Int?,junctionRows=0
                while y >= 0 && y < rows {
                    let xs=(0..<columns).filter { family[y*columns+$0] != 0 }
                    guard let left=xs.first,let right=xs.last,
                          CGFloat(right-left+1) <= CGFloat(columns)*0.3 else {
                        // The paired private core can end inside the final
                        // glyph. Cross only its short junction before looking
                        // for the narrow source terminal, never a remote island.
                        if run.isEmpty,junctionRows < max(2,columns/2) {
                            junctionRows+=1;y+=direction;continue
                        }
                        break
                    }
                    let centre=(left+right)/2
                    if let previousX,abs(centre-previousX) > max(2,radius) { break }
                    run.append(y);previousX=centre;y+=direction
                }
                if CGFloat(run.count+junctionRows) > CGFloat(columns)*1.6,
                   CGFloat(run.count) >= CGFloat(columns)*0.8 {
                    terminalRows.formUnion(run)
                }
            }
        }
        audit?(["pairedSourceTerminalRows":terminalRows.count])
        var pairedMask=mask,removed=0
        for p in mask.indices where refineEnds && mask[p] != 0 && (p/columns < head || p/columns > tail) {
            // Only the end bands are corrected. Internal original glyphs keep
            // their complete contours; genuine paired continuations also stay.
            if !terminalRows.contains(p/columns),
               family[p] != 0 && near[p] > radius || secondary[p] != 0 && nearPrimary[p] > radius {
                pairedMask[p]=0;removed+=1
            }
        }
        audit?(["sourcePairedEndHead":start+CGFloat(head),"sourcePairedEndTail":start+CGFloat(tail+1),
                "removedUnpairedEndPixels":removed])
        var result=pairedMask,seen=[Bool](repeating:false,count:count),cells:[Int]=[]
        for seed in pairedMask.indices where pairedMask[seed] != 0 && !seen[seed] {
            cells.removeAll(keepingCapacity:true);cells.append(seed);seen[seed]=true
            var cursor=0,own=false,primaryCount=0,pairCount=0
            while cursor < cells.count {
                let p=cells[cursor];cursor+=1;let y=p/columns,x=p%columns
                if start+CGFloat(y) >= 0 && start+CGFloat(y) < length { own=true }
                if family[p] != 0 {
                    primaryCount+=1
                    if near[p] <= radius { pairCount+=1 }
                }
                for dy in -1...1 { for dx in -1...1 {
                    let yy=y+dy,xx=x+dx
                    guard yy >= 0,yy < rows,xx >= 0,xx < columns else { continue }
                    let next=yy*columns+xx
                    if !seen[next],pairedMask[next] != 0 { seen[next]=true;cells.append(next) }
                } }
            }
            if !own,primaryCount >= 8,Double(pairCount) < Double(primaryCount)*fraction*0.5 {
                for p in cells { result[p]=0 }
                audit?(["rejectedUnpairedInkPixels":cells.count,"unpairedInkTop":start+CGFloat(cells.map {$0/columns}.min()!),
                        "unpairedInkBottom":start+CGFloat(cells.map {$0/columns}.max()!+1)])
            }
        }
        return result
    }

    struct EndpointInkStyle {
        let colors: [[Int]]
        init(colors: [[Int]]) { self.colors=colors }
        init(_ primary: [Int]) { self.colors=[primary] }
    }

    /// A separately decoded point train can become redundant after a real word's
    /// measured endpoint recovery. Transfer its detector ownership, never its crop
    /// or inferred text. Composite reads retain their existing fragment layout.
    static func containedPointOwners(reads: [NativeCoreMLRecognizedRegion],
                                     evidence: [Int: [NativeOCRDetectorSeedEvidence]],
                                     proofs: [Int: [CGPoint]], ink: [EndpointInkStyle?], recognitionThreshold: Double) -> [Int: Int] {
        func dots(_ text: String) -> String {
            text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
        }
        var result: [Int: Int] = [:]
        for child in reads {
            let text = dots(child.text)
            guard text.count >= 2, text.allSatisfy({ $0 == "." }), child.confidence >= recognitionThreshold,
                  let source = evidence[child.sourceIndex], source.count == 1, source[0].isValid,
                  !source[0].components.isEmpty, let childFrame = EndpointFrame(child.polygon),
                  ink.indices.contains(child.sourceIndex), let childInk = ink[child.sourceIndex] else { continue }
            let area = NativeOCRDirectionGeometry.area(child.polygon)
            guard area > 0 else { continue }
            let parents = reads.filter { parent in
                guard parent.sourceIndex != child.sourceIndex, parent.confidence >= 0.8,
                      parent.text.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 2,
                      dots(parent.text).contains("."), let owners = evidence[parent.sourceIndex], owners.count == 1,
                      owners[0].ownerID != source[0].ownerID,
                      NativeOCRDetectorSeedEvidence.preservingUnion([owners,source]) != nil,
                      let proof = proofs[parent.sourceIndex], let frame = EndpointFrame(parent.polygon),
                      ink.indices.contains(parent.sourceIndex), let parentInk = ink[parent.sourceIndex],
                      parentInk.colors.contains(where: { a in childInk.colors.contains { b in
                          a.count == 3 && b.count == 3 && zip(a,b).map { abs($0-$1) }.max()! <= 48
                      } }),
                      abs(frame.along.x*childFrame.along.x + frame.along.y*childFrame.along.y) >= 0.98,
                      NativeOCRDirectionGeometry.intersectionArea(child.polygon, parent.polygon) >= area*0.98,
                      NativeOCRDirectionGeometry.intersectionArea(child.polygon, proof) >= area*0.98 else { return false }
                let local = frame.bounds(child.polygon), width = frame.rect.width
                guard abs(local.midX-frame.rect.midX) <= width*0.4, local.height <= width*2,
                      max(local.midY-frame.rect.minY,frame.rect.maxY-local.midY) >= frame.rect.height*0.65 else { return false }
                // Check the private measured cells as well as the padded detector
                // rectangle. Missing or contradictory evidence cannot erase a read.
                let e = source[0], sx = CGFloat(e.sourceWidth)/CGFloat(e.mapFullWidth)
                let sy = CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight)
                let total = e.components.reduce(0) { $0+$1.pixelCount }
                var inside = 0
                for component in e.components { for run in component.runs { for x in run.x..<(run.x+run.count) {
                    let p = CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                    let cell = NativeOCRDirectionGeometry.corners(CGRect(x:p.x-sx*0.05,y:p.y-sy*0.05,
                        width:sx*0.1,height:sy*0.1))
                    if NativeOCRDirectionGeometry.intersectionArea(cell,parent.polygon) >= sx*sy*0.0098 &&
                        NativeOCRDirectionGeometry.intersectionArea(cell,proof) >= sx*sy*0.0098 { inside += 1 }
                } } }
                return total > 0 && Double(inside) >= Double(total)*0.98
            }
            if parents.count == 1 { result[child.sourceIndex] = parents[0].sourceIndex }
        }
        return result
    }

    /// Restore provenance of an unread detector alias whose entire candidate
    /// component is already represented by one actual word. No read, text or
    /// geometry is created or removed. Private or multiply contested ink cannot
    /// be assigned this way, even when its padded rectangle happens to fit.
    static func containedSharedSourceOwners(reads: [NativeCoreMLRecognizedRegion],
        evidence: [Int: [NativeOCRDetectorSeedEvidence]], boxes: [NativeCoreMLDetectionBox],
        recognitionThreshold: Double) -> [Int: Int] {
        let retained=Set(reads.map(\.sourceIndex))
        let represented=Set(evidence.values.flatMap { $0.map(\.ownerID) })
        var result:[Int:Int]=[:]
        for child in boxes.indices where !retained.contains(child) {
            guard let source=boxes[child].detectorSeedEvidence,source.isValid,source.components.isEmpty,
                  !represented.contains(source.ownerID),
                  (source.ambiguousComponents ?? []).isEmpty,let parts=source.candidateComponents,!parts.isEmpty else { continue }
            let area=NativeOCRDirectionGeometry.area(boxes[child].polygon)
            guard area > 0 else { continue }
            let parents=reads.filter { parent in
                guard parent.confidence >= recognitionThreshold,
                      parent.text.filter({$0.isLetter || $0.isNumber}).count >= 2,
                      let owners=evidence[parent.sourceIndex],!owners.contains(where:{$0.ownerID==source.ownerID}),
                      NativeOCRDetectorSeedEvidence.preservingUnion([owners,[source]]) != nil,
                      NativeOCRDirectionGeometry.intersectionArea(boxes[child].polygon,parent.polygon) >= area*0.98 else { return false }
                let matching=owners.filter { owner in
                    guard boxes.indices.contains(owner.parentBoxIndex),parts.allSatisfy({
                        $0.competingOwnerIDs == [owner.ownerID]
                    }) else { return false }
                    let seeds=NativeOCRContextualColumnRecovery.sharedContinuationSeeds(evidence:owner,
                        source:boxes[owner.parentBoxIndex].polygon,reference:parent.polygon)
                    let known=owner.components+(owner.ambiguousComponents ?? [])+(owner.candidateComponents ?? []).map(\.component)
                    return parts.allSatisfy { candidate in
                        seeds.contains(candidate.component.seed) && known.contains(candidate.component)
                    }
                }
                guard matching.count==1 else { return false }
                let sx=CGFloat(source.sourceWidth)/CGFloat(source.mapFullWidth)
                let sy=CGFloat(source.sourceHeight)/CGFloat(source.mapFullHeight)
                var total=0,inside=0
                for part in parts { for run in part.component.runs { for x in run.x..<(run.x+run.count) {
                    total+=1
                    if NativeOCRDirectionGeometry.contains(parent.polygon,
                        CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)) { inside+=1 }
                } } }
                return total >= 8 && inside*100 >= total*98
            }
            if parents.count==1 { result[child]=parents[0].sourceIndex }
        }
        var claims:[String:Set<Int>]=[:]
        for (child,parent) in result {
            if let owner=boxes[child].detectorSeedEvidence?.ownerID { claims[owner,default:[]].insert(parent) }
        }
        return result.filter { child,_ in
            boxes[child].detectorSeedEvidence.map { claims[$0.ownerID]?.count==1 } ?? false
        }
    }

    static func distinctEndpointInk(_ lhs: EndpointInkStyle?, _ rhs: EndpointInkStyle?) -> Bool {
        guard let lhs,let rhs,let a=lhs.colors.first,let b=rhs.colors.first,
              a.count == 3,b.count == 3 else { return false }
        // An outlined word can switch its most common colour between fill
        // and outline in adjacent crops. Shared learned ink makes these the
        // same layer even when their single dominant RGBs are far apart.
        if lhs.colors.contains(where: { l in rhs.colors.contains { r in
            l.count == 3 && r.count == 3 && zip(l,r).map { abs($0-$1) }.max()! <= 48
        } }) { return false }
        return zip(a,b).map { abs($0-$1) }.max()! > 96 &&
            max(a.max()!-a.min()!,b.max()!-b.min()!) >= 32
    }

    /// Infer source ink from private detector cells against their own paper.
    /// This is a pixel observation, never a label or recognized-string rule.
    static func endpointFontPeerPolygons(_ boxes:[NativeCoreMLDetectionBox])->[String:[[CGPoint]]] {
        var peers:[String:[[CGPoint]]]=[:]
        for box in boxes {
            guard let evidence=box.detectorSeedEvidence,evidence.isValid,box.polygon.count==4,
                  box.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { continue }
            peers[evidence.ownerID,default:[]].append(box.polygon)
        }
        return peers
    }

    /// Minor crop-padding overlap is not overlapping ink. Reciprocal, mostly
    /// exclusive detector components and a common RF text scope can establish
    /// two consecutive pieces of one column without relaxing independent reads.
    static func confirmedEndpointContinuation(_ first:NativeCoreMLDetectionBox,peer second:NativeCoreMLDetectionBox,
                                              scope:NativeRFDETRLayoutPrimitive,
                                              observer:((NativeOCRDetectorSeedEvidence,NativeOCRDetectorSeedEvidence.Component,Bool)->Void)? = nil)->Bool {
        guard first.score >= 0.8,second.score >= 0.8,scope.semanticClass == .text,scope.confidence >= 0.5,
              let a=first.detectorSeedEvidence,let b=second.detectorSeedEvidence,a.isValid,b.isValid,
              a.ownerID != b.ownerID,a.sourceWidth==b.sourceWidth,a.sourceHeight==b.sourceHeight,
              a.mapFullWidth==b.mapFullWidth,a.mapFullHeight==b.mapFullHeight,
              let frame=EndpointFrame(first.polygon),let other=EndpointFrame(second.polygon),
              abs(frame.along.x*other.along.x+frame.along.y*other.along.y) >= 0.95 else { return false }
        let x=frame.bounds(first.polygon),y=frame.bounds(second.polygon),font=min(x.width,y.width)
        guard font > 0,min(x.height,y.height) >= font*2,max(x.width,y.width) <= font*1.7,
              abs(x.midX-y.midX) <= font*0.3 else { return false }
        let area=min(NativeOCRDirectionGeometry.area(first.polygon),NativeOCRDirectionGeometry.area(second.polygon))
        let overlap=NativeOCRDirectionGeometry.intersectionArea(first.polygon,second.polygon)
        guard overlap > 0,overlap <= area*0.1 else { return false }
        let support=NativeOCRDirectionAdapters.support(scope)
        for polygon in [first.polygon,second.polygon] {
            guard NativeOCRDirectionGeometry.intersectionArea(polygon,support) >=
                    NativeOCRDirectionGeometry.area(polygon)*0.6 else { return false }
        }
        func candidates(_ evidence:NativeOCRDetectorSeedEvidence,polygon:[CGPoint],peerID:String)
            -> [(NativeOCRDetectorSeedEvidence.Component,CGRect,Bool)] {
            let sx=CGFloat(evidence.sourceWidth)/CGFloat(evidence.mapFullWidth)
            let sy=CGFloat(evidence.sourceHeight)/CGFloat(evidence.mapFullHeight)
            let radiusX=(abs(frame.across.x)*sx+abs(frame.across.y)*sy)/2
            let radiusY=(abs(frame.along.x)*sx+abs(frame.along.y)*sy)/2
            var output:[(NativeOCRDetectorSeedEvidence.Component,CGRect,Bool)]=[]
            let exclusive=(evidence.candidateComponents ?? []).filter { candidate in
                candidate.competingOwnerIDs.contains(peerID) &&
                    candidate.outsideCompetingCells.allSatisfy({$0*5 >= candidate.component.pixelCount*4})
            }.map { ($0.component,false) }
            let privateParts=evidence.components.filter { $0.meanProbability >= evidence.threshold }.map { ($0,true) }
            for (component,isPrivate) in exclusive+privateParts {
                var owned=0,bounds=CGRect.null
                for run in component.runs { for cell in run.x..<(run.x+run.count) {
                    let point=CGPoint(x:(CGFloat(cell)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                    if NativeOCRDirectionGeometry.contains(polygon,point) { owned+=1 }
                    bounds=bounds.union(CGRect(origin:frame.project(point),size:.zero))
                } }
                bounds=bounds.insetBy(dx:-radiusX,dy:-radiusY)
                guard owned*5 >= component.pixelCount*4,bounds.height >= font*2 else { continue }
                output.append((component,bounds,isPrivate))
            }
            return output
        }
        let left=candidates(a,polygon:first.polygon,peerID:b.ownerID)
        let right=candidates(b,polygon:second.polygon,peerID:a.ownerID)
        for (component,part,isPrivate) in left { for (otherComponent,otherPart,otherPrivate) in right {
            let gap=max(part.minY,otherPart.minY)-min(part.maxY,otherPart.maxY)
            // A private winner need not also be an ambiguous candidate.
            // At least one reciprocal exclusive candidate is still required;
            // independent complete columns do not acquire merge permission.
            if !(isPrivate && otherPrivate),component.seed != otherComponent.seed,gap >= 0,
               gap <= max(x.width,y.width)*(isPrivate || otherPrivate ? 0.6:1.2) {
                observer?(b,otherComponent,otherPart.minY >= part.maxY)
                return true
            }
        } }
        return false
    }

    static func endpointInkStyle(box: NativeCoreMLDetectionBox, frame: NativeOCRRGBAFrame,
                                 candidatePeerPolygons:[String:[[CGPoint]]] = [:]) -> EndpointInkStyle? {
        guard let evidence = box.detectorSeedEvidence, evidence.isValid,
              evidence.sourceWidth == frame.width, evidence.sourceHeight == frame.height,
              let basis = EndpointFrame(box.polygon) else { return nil }
        let r = basis.rect, columns = Int(ceil(r.width)), rows = Int(ceil(r.height))
        guard columns > 2, rows > 0, columns <= 524_288/rows else { return nil }
        return endpointPalette(evidence:evidence,columns:columns,rows:rows,start:0,length:r.height,
            project: { point in
                let p = basis.project(point)
                return CGPoint(x:p.x-r.minX,y:p.y-r.minY)
            },rgb: { row,column in
                let p = basis.restore(CGPoint(x:r.minX+CGFloat(column)+0.5,y:r.minY+CGFloat(row)+0.5))
                let x = Int(floor(p.x)), y = Int(floor(p.y))
                guard x >= 0, y >= 0, x < frame.width, y < frame.height else { return nil }
                let offset = y*frame.bytesPerRow+x*4
                return [Int(frame.bytes[offset]),Int(frame.bytes[offset+1]),Int(frame.bytes[offset+2])]
            },styleOnly:true,candidatePeerPolygons:candidatePeerPolygons)?.inkStyle
    }

    /// The editor/detector first edge defines the immutable width direction.
    /// Opposite-edge averaging during a length resize can rotate a skew quad.
    /// This frame keeps that first edge exactly parallel at every scene angle.
    struct EndpointFrame {
        let origin: CGPoint
        let along: CGPoint
        let across: CGPoint
        let rect: CGRect
        let trustedAlong: CGPoint
        init?(_ q: [CGPoint]) { self.init(q,trustedAlong:nil) }
        init?(_ q: [CGPoint], trustedAlong:CGPoint?) {
            guard AxisFrame(q) != nil else { return nil }
            let edge = CGPoint(x:q[1].x-q[0].x,y:q[1].y-q[0].y)
            let size = hypot(edge.x,edge.y)
            let u = CGPoint(x:edge.x/size,y:edge.y/size), v = CGPoint(x:-edge.y/size,y:edge.x/size)
            let width = size+hypot(q[2].x-q[3].x,q[2].y-q[3].y)
            let height = hypot(q[3].x-q[0].x,q[3].y-q[0].y)+hypot(q[2].x-q[1].x,q[2].y-q[1].y)
            let y = height >= width ? v : u, x = CGPoint(x:y.y,y:-y.x)
            origin=q[0];along=y;across=x;self.trustedAlong=trustedAlong ?? y
            rect=q.reduce(CGRect.null) { r,p in
                r.union(CGRect(origin:CGPoint(x:(p.x-q[0].x)*x.x+(p.y-q[0].y)*x.y,
                    y:(p.x-q[0].x)*y.x+(p.y-q[0].y)*y.y),size:.zero))
            }
        }
        func project(_ p:CGPoint)->CGPoint {
            .init(x:(p.x-origin.x)*across.x+(p.y-origin.y)*across.y,
                  y:(p.x-origin.x)*along.x+(p.y-origin.y)*along.y)
        }
        func restore(_ p:CGPoint)->CGPoint {
            .init(x:origin.x+p.x*across.x+p.y*along.x,y:origin.y+p.x*across.y+p.y*along.y)
        }
        func bounds(_ q:[CGPoint])->CGRect {
            q.reduce(CGRect.null) { $0.union(CGRect(origin:project($1),size:.zero)) }
        }
    }

    static func combiningEndpointGrowth(base: [CGPoint], supplement: [CGPoint]?, minimumChange: CGFloat? = nil) -> [CGPoint] {
        guard let supplement, let frame = EndpointFrame(base), supplement.count == 4 else { return base }
        let extra = frame.bounds(supplement)
        // Sampling proposals keep their grid tolerance. Already observed
        // physical caps use zero tolerance when combining proof intervals.
        let change = minimumChange ?? max(2, frame.rect.width * 0.5)
        let first = frame.rect.minY-extra.minY >= change ? extra.minY : frame.rect.minY
        let last = extra.maxY-frame.rect.maxY >= change ? extra.maxY : frame.rect.maxY
        guard first < frame.rect.minY - 1 || last > frame.rect.maxY + 1 else { return base }
        return base.map { point in
            var p = frame.project(point)
            let weight = (p.y - frame.rect.minY) / frame.rect.height
            p.y += (1 - weight) * (first - frame.rect.minY) + weight * (last - frame.rect.maxY)
            return frame.restore(p)
        }
    }

    /// A changed crop must retain accepted words, numbers and meaningful
    /// symbols. Punctuation may retokenize when its original reading span is
    /// still present; confidence alone never authorizes losing a word token.
    /// Typography-level ambiguity may change when empty crop padding is removed.
    /// This comparison is used only with measured private/source-ink retention
    /// AND an independently padded confirming recognition, never on its own.
    /// Two overlapping detector factories may share the same ambiguous glyph.
    /// Correct its weak isolated read only when the new real crop retains that
    /// exact shared component, not merely an enclosing rectangle.
    static func retainsSharedGlyph(child:NativeOCRDetectorSeedEvidence,parent:NativeOCRDetectorSeedEvidence,
                                   childPolygon:[CGPoint],container:[CGPoint])->Bool {
        guard child.isValid,parent.isValid,child.mapFullWidth==parent.mapFullWidth,
              child.mapFullHeight==parent.mapFullHeight,child.sourceWidth==parent.sourceWidth,
              child.sourceHeight==parent.sourceHeight else { return false }
        func parts(_ e:NativeOCRDetectorSeedEvidence)->[NativeOCRDetectorSeedEvidence.Component] {
            e.components+(e.ambiguousComponents ?? [])+(e.candidateComponents ?? []).map(\.component)
        }
        let seeds=Set(parts(parent).map(\.seed)),sx=CGFloat(child.sourceWidth)/CGFloat(child.mapFullWidth),
            sy=CGFloat(child.sourceHeight)/CGFloat(child.mapFullHeight)
        var total=0,covered=0
        for c in parts(child) where seeds.contains(c.seed) { for run in c.runs { for x in run.x..<(run.x+run.count) {
            let p=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
            if NativeOCRDirectionGeometry.contains(childPolygon,p) {
                total+=1
                if NativeOCRDirectionGeometry.contains(container,p) { covered+=1 }
            }
        } } }
        return total >= 8 && Double(covered) >= Double(total)*0.95
    }

    /// An independently detected endpoint glyph can already be present in a
    /// retained whole-word crop without sharing its detector component ID.
    /// A paired reread may alias it only when BOTH the old and new word crops
    /// retain its complete private cells, at the same literal word endpoint.
    /// Padding that first acquires a neighbour is never this certificate.
    static func retainsObservedBoundaryGlyph(child:NativeOCRDetectorSeedEvidence,fragment:String,
        baselineText:String,candidateText:String,baseline:[CGPoint],container:[CGPoint])->Bool {
        guard child.isValid,child.completeCCScan == true,!child.components.isEmpty,
              (child.ambiguousComponents ?? []).isEmpty,(child.candidateComponents ?? []).isEmpty,
              fragment.count==1,fragment.allSatisfy({$0.isLetter || $0.isNumber}),
              baselineText.filter({$0.isLetter || $0.isNumber}).count >= 2,
              let frame=EndpointFrame(baseline) else { return false }
        let before=measuredTrimContent(baselineText),after=measuredTrimContent(candidateText)
        let head=before.hasPrefix(fragment) && after.hasPrefix(fragment)
        let tail=before.hasSuffix(fragment) && after.hasSuffix(fragment)
        guard head || tail else { return false }
        let sx=CGFloat(child.sourceWidth)/CGFloat(child.mapFullWidth)
        let sy=CGFloat(child.sourceHeight)/CGFloat(child.mapFullHeight)
        var total=0,oldCovered=0,newCovered=0,ink=CGRect.null
        for component in child.components { for run in component.runs { for x in run.x..<(run.x+run.count) {
            let point=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
            total+=1
            if NativeOCRDirectionGeometry.contains(baseline,point) { oldCovered+=1 }
            if NativeOCRDirectionGeometry.contains(container,point) { newCovered+=1 }
            ink=ink.union(CGRect(origin:frame.project(point),size:.zero))
        } } }
        let glyph=frame.rect.width
        guard total >= 8,Double(oldCovered) >= Double(total)*0.95,
              Double(newCovered) >= Double(total)*0.95,
              ink.width <= glyph*1.35,ink.height <= glyph*1.5 else { return false }
        return (head && ink.maxY <= frame.rect.minY+glyph*1.5) ||
            (tail && ink.minY >= frame.rect.maxY-glyph*1.5)
    }

    static func preservesAlignedFragment(candidate:String,fragment:String,confidence:Double,threshold:Double)->Bool {
        let letters=fragment.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        if letters.isEmpty { return true }
        guard letters.count==1 else { return false }
        return preservesRecognizedCore(candidate:candidate,confidence:confidence,baseline:fragment,
            threshold:threshold,retainsOriginalSpan:true)
    }

    static func foldEndpointKana(_ text:String)->String {
        let small=Array("ぁぃぅぇぉゃゅょゎァィゥェォャュョヮヵヶ")
        let full=Array("あいうえおやゆよわアイウエオヤユヨワカケ")
        let folds=Dictionary(uniqueKeysWithValues:zip(small,full))
        return String(text.map { folds[$0] ?? $0 })
    }

    /// CTC can spell the same measured terminal stroke as a prolonged-sound
    /// mark, horizontal bar or em dash when point context changes. Preserve
    /// every stroke and its position; internal word strokes stay literal.
    static func canonicalTerminalStroke(_ text:String)->String {
        var characters=Array(text.precomposedStringWithCanonicalMapping)
        let bars:Set<Character>=["ー","―","—"]
        func terminalMark(_ c:Character)->Bool {
            c.isWhitespace || c.unicodeScalars.allSatisfy { scalar in
                switch scalar.properties.generalCategory {
                case .connectorPunctuation,.dashPunctuation,.openPunctuation,.closePunctuation,
                     .initialPunctuation,.finalPunctuation,.otherPunctuation,
                     .mathSymbol,.currencySymbol,.modifierSymbol,.otherSymbol:return true
                default:return false
                }
            }
        }
        var end=characters.count-1
        while end >= 0,!bars.contains(characters[end]),terminalMark(characters[end]) { end-=1 }
        while end >= 0,bars.contains(characters[end]) { characters[end]="ー";end-=1 }
        return String(characters)
    }

    static func measuredTrimContent(_ text:String)->String {
        foldEndpointKana(String(canonicalTerminalStroke(text.precomposedStringWithCompatibilityMapping).filter { character in
            !character.isWhitespace && !character.unicodeScalars.allSatisfy { scalar in
                switch scalar.properties.generalCategory {
                case .connectorPunctuation,.dashPunctuation,.openPunctuation,.closePunctuation,
                     .initialPunctuation,.finalPunctuation,.otherPunctuation:return true
                default:return false
                }
            }
        }))
    }

    /// Trim confirmation may retokenize a dot run, but cannot silently lose
    /// a visible bracket, exclamation, heart or original word character.
    static func measuredTrimSignature(_ text:String)->String {
        foldEndpointKana(String(text.precomposedStringWithCompatibilityMapping.filter {
            !$0.isWhitespace && $0 != "."
        }))
    }

    /// A source-proven terminal may append only prolonged-sound strokes to
    /// an otherwise unchanged word. Existing strokes can never be dropped.
    static func preservesTerminalWord(candidate:String,baseline:String,allowSingleGlyph:Bool = false)->Bool {
        let old=foldEndpointKana(canonicalTerminalStroke(baseline).filter { $0.isLetter || $0.isNumber })
        let new=foldEndpointKana(canonicalTerminalStroke(candidate).filter { $0.isLetter || $0.isNumber })
        return old.count >= (allowSingleGlyph ? 1:2) && new.hasPrefix(old) && new.dropFirst(old.count).allSatisfy { $0 == "ー" }
    }

    static func preservesRecognizedCore(candidate: String, confidence: Double,
                                        baseline: String, threshold: Double,
                                        retainsOriginalSpan:Bool = false,
                                        retainsDetectorSpan:Bool = false,
                                        confirmedMeasuredTrim:Bool = false,
                                        confirmedTerminalCompletion:Bool = false,
                                        unprovenLongGrowth:Bool = false,
                                        overlappingPeerTexts:[String] = [],newlyAcquiredPeerTexts:[String] = []) -> Bool {
        guard confidence >= threshold, !candidate.isEmpty else { return false }
        func normalized(_ text:String,wordsOnly:Bool)->String {
            var output=""
            for character in text.precomposedStringWithCanonicalMapping {
                let punctuation=character.unicodeScalars.allSatisfy { scalar in
                    switch scalar.properties.generalCategory {
                    case .connectorPunctuation,.dashPunctuation,.openPunctuation,.closePunctuation,
                         .initialPunctuation,.finalPunctuation,.otherPunctuation: return true
                    default:return false
                    }
                }
                if wordsOnly && (punctuation || character.isWhitespace) { continue }
                // Compatibility punctuation such as an ellipsis and its dots
                // is one observation; letters, numbers and symbols stay exact.
                output += punctuation ? String(character).precomposedStringWithCompatibilityMapping : String(character)
            }
            return output
        }
        func contains(_ candidate:String,_ baseline:String)->Bool {
            var remaining=candidate.makeIterator()
            for character in baseline {
                var found=false
                while let next=remaining.next() { if next==character { found=true;break } }
                if !found { return false }
            }
            return true
        }
        func literalContent(_ text:String)->String {
            String(text.precomposedStringWithCanonicalMapping.filter { $0.isLetter || $0.isNumber })
        }
        let candidateCore=normalized(candidate,wordsOnly:true),baselineCore=normalized(baseline,wordsOnly:true)
        // Finishing a glyph needs modest crop room. A much longer extension
        // that reveals no additional content needs measured terminal support;
        // an unchanged decode alone cannot certify foreground in nearby art.
        if unprovenLongGrowth,candidateCore == baselineCore { return false }
        if !newlyAcquiredPeerTexts.isEmpty,contains(candidateCore,baselineCore) {
            let original=Array(baselineCore)
            var position=0,added=""
            for character in candidateCore {
                if position < original.count,character == original[position] { position+=1 }
                else { added.append(character) }
            }
            if !added.isEmpty,newlyAcquiredPeerTexts.contains(where:{ peer in
                let other=normalized(peer,wordsOnly:true)
                if contains(other,added) { return true }
                // Cropping part of an independent word can alter a kana or
                // repeat a letter. A long unproved expansion cannot use those
                // partly shared new tokens as its own foreground certificate.
                return unprovenLongGrowth && !Set(other).isDisjoint(with:Set(added))
            }) { return false }
        }
        if literalContent(baseline).isEmpty {
            let introduced=literalContent(candidate)
            // A symbol read has no accepted word core to certify new letters.
            // If all of them already occur in a comparable overlapping read,
            // resizing has not supplied independent evidence for a new word.
            // Novel content remains eligible; no peer text is copied or edited.
            if !introduced.isEmpty,overlappingPeerTexts.contains(where:{ contains(literalContent($0),introduced) }) {
                return false
            }
            // A crop newly crossing an independent peer is stronger evidence
            // than pre-existing padding overlap. Even a partial borrowed word
            // cannot certify new letters for a formerly symbol-only source.
            if !introduced.isEmpty,newlyAcquiredPeerTexts.contains(where: { peer in
                !Set(literalContent(peer)).isDisjoint(with:Set(introduced))
            }) { return false }
        }
        if contains(normalized(candidate,wordsOnly:false),normalized(baseline,wordsOnly:false)) { return true }
        func withoutDots(_ text:String)->String {
            foldEndpointKana(String(normalized(text,wordsOnly:false).filter { $0 != "." && !$0.isWhitespace }))
        }
        if confirmedMeasuredTrim,!literalContent(baseline).isEmpty,
           measuredTrimContent(candidate)==measuredTrimContent(baseline) { return true }
        // A trim may discard speculative padding while retaining every detector
        // cell. Only dot-run retokenization is tolerated on that evidence;
        // letters, long-vowel marks, hearts and all other punctuation stay exact.
        if retainsDetectorSpan, !literalContent(baseline).isEmpty {
            if withoutDots(candidate) == withoutDots(baseline) { return true }
        }
        if confirmedTerminalCompletion,preservesTerminalWord(candidate:candidate,baseline:baseline) {
            func symbols(_ text:String)->String {
                String(text.filter { c in c.unicodeScalars.allSatisfy { scalar in
                    switch scalar.properties.generalCategory {
                    case .mathSymbol,.currencySymbol,.modifierSymbol,.otherSymbol:return true
                    default:return false
                    }
                } })
            }
            if contains(symbols(candidate),symbols(baseline)) { return true }
        }
        guard retainsOriginalSpan else { return false }
        let words=normalized(baseline,wordsOnly:true)
        return !words.isEmpty && contains(normalized(candidate,wordsOnly:true),words)
    }

    static func overlapsComparableEndpointRead(_ original:[CGPoint],peer:[CGPoint],
                                               ink:EndpointInkStyle?,peerInk:EndpointInkStyle?) -> Bool {
        let area=min(NativeOCRDirectionGeometry.area(original),NativeOCRDirectionGeometry.area(peer))
        guard area > 0,!distinctEndpointInk(ink,peerInk) else { return false }
        return NativeOCRDirectionGeometry.intersectionArea(original,peer) >= area*0.1
    }

    /// Different print colours can share a crop, but do not grant permission
    /// to acquire the other word during growth. Recognition samples all RGB
    /// layers, even when the pixel expansion was fitted to only one palette.
    static func overlapsEndpointReadAfterGrowth(_ candidate:[CGPoint],baseline:[CGPoint],peer:[CGPoint],
        ink:EndpointInkStyle?,peerInk:EndpointInkStyle?)->Bool {
        if overlapsComparableEndpointRead(candidate,peer:peer,ink:ink,peerInk:peerInk) { return true }
        guard overlapsComparableEndpointRead(candidate,peer:peer,ink:nil,peerInk:nil) else { return false }
        return NativeOCRDirectionGeometry.intersectionArea(candidate,peer) >
            NativeOCRDirectionGeometry.intersectionArea(baseline,peer)+1e-6
    }

    /// Distinguish one glyph with normal crop padding from a speculative long
    /// extension. A measured source terminal can justify its actual cap, with
    /// the same small glyph-relative padding at every rotation and scale.
    static func hasUnprovenLongEndpointGrowth(candidate:[CGPoint],baseline:[CGPoint],terminalProof:[CGPoint]?) -> Bool {
        guard candidate.count==4,let frame=EndpointFrame(baseline),
              candidate.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { return true }
        let old=frame.rect,new=frame.bounds(candidate),glyph=old.width
        guard glyph > 0 else { return true }
        let proof=terminalProof.flatMap { p -> CGRect? in
            guard p.count==4,p.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { return nil }
            return frame.bounds(p)
        }
        let head=old.minY-new.minY,tail=new.maxY-old.maxY
        let slack=glyph*0.25
        let finishingRoom=glyph*1.5
        if head > finishingRoom+1e-6,proof.map({$0.minY <= new.minY+slack}) != true { return true }
        if tail > finishingRoom+1e-6,proof.map({$0.maxY >= new.maxY-slack}) != true { return true }
        return false
    }

    /// A rejected speculative end must not erase a measured cap at the other
    /// end. This is a new recognition input, never a relabelled old decode.
    static func measuredEndpointAlternative(candidate:[CGPoint],baseline:[CGPoint],terminalProof:[CGPoint]?) -> [CGPoint]? {
        guard hasUnprovenLongEndpointGrowth(candidate:candidate,baseline:baseline,terminalProof:terminalProof) ||
                !retainsOriginalReadingSpan(candidate:candidate,baseline:baseline),
              let frame=EndpointFrame(baseline),let proof=terminalProof,proof.count==4,
              proof.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { return nil }
        let observed=frame.bounds(candidate),ink=frame.bounds(proof),old=frame.rect
        let start=min(old.minY,max(observed.minY,ink.minY))
        let end=max(old.maxY,min(observed.maxY,ink.maxY))
        guard old.minY-start > 1 || end-old.maxY > 1 else { return nil }
        let target=[CGPoint(x:old.minX,y:start),CGPoint(x:old.maxX,y:start),
                    CGPoint(x:old.maxX,y:end),CGPoint(x:old.minX,y:end)].map(frame.restore)
        let result=replacingEndpointExtent(base:baseline,proposal:target,minimumChange:0)
        guard zip(result,candidate).contains(where:{ hypot($0.x-$1.x,$0.y-$1.y) > 1 }) else { return nil }
        return result
    }

    /// Retokenizing punctuation is permitted only when the original reading
    /// span and normal extent remain available in the intrinsic source frame.
    static func retainsOriginalReadingSpan(candidate:[CGPoint],baseline:[CGPoint]) -> Bool {
        guard candidate.count==4,let frame=EndpointFrame(baseline),
              candidate.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { return false }
        let observed=frame.bounds(candidate),old=frame.rect
        let epsilon:CGFloat=1e-6
        return observed.minX <= old.minX+epsilon && observed.maxX >= old.maxX-epsilon &&
            observed.minY <= old.minY+epsilon && observed.maxY >= old.maxY-epsilon
    }

    /// Replace only the long-axis interval, retaining the reference's width
    /// and exact first-edge angle even for nonrectangular detector quads.
    static func replacingEndpointExtent(base: [CGPoint], proposal: [CGPoint], minimumChange: CGFloat = 1) -> [CGPoint] {
        guard let frame = EndpointFrame(base), proposal.count == 4 else { return base }
        let target = frame.bounds(proposal)
        guard target.height > 0 else { return base }
        let start = abs(target.minY-frame.rect.minY) > minimumChange ? target.minY : frame.rect.minY
        let end = abs(target.maxY-frame.rect.maxY) > minimumChange ? target.maxY : frame.rect.maxY
        guard end > start else { return base }
        return base.map { point in
            var p = frame.project(point)
            let weight = (p.y-frame.rect.minY)/frame.rect.height
            p.y += (1-weight)*(start-frame.rect.minY)+weight*(end-frame.rect.maxY)
            return frame.restore(p)
        }
    }

    /// A later direct-colour trim cannot erase a terminal already measured as
    /// a connected/fragment-chained continuation of original source ink. Keep
    /// that observed cap only, without protecting speculative crop padding.
    static func preservingRecoveredTerminal(trimmed:[CGPoint],candidate:[CGPoint],original:[CGPoint],
        proof:[CGPoint]?,audit:(([String:Any])->Void)? = nil) -> [CGPoint] {
        guard refinesEndpointInk,let proof,proof.count==4,let frame=EndpointFrame(trimmed) else { return trimmed }
        let old=frame.bounds(original),read=frame.bounds(candidate),ink=frame.bounds(proof)
        var start=frame.rect.minY,end=frame.rect.maxY
        if ink.minY < old.minY-1 { start=min(start,max(read.minY,ink.minY)) }
        if ink.maxY > old.maxY+1 { end=max(end,min(read.maxY,ink.maxY)) }
        guard start < frame.rect.minY || end > frame.rect.maxY else { return trimmed }
        let target=[CGPoint(x:frame.rect.minX,y:start),CGPoint(x:frame.rect.maxX,y:start),
                    CGPoint(x:frame.rect.maxX,y:end),CGPoint(x:frame.rect.minX,y:end)].map(frame.restore)
        audit?(["protectedTerminalStart":start,"protectedTerminalEnd":end,
                "trimmedStart":frame.rect.minY,"trimmedEnd":frame.rect.maxY])
        return replacingEndpointExtent(base:trimmed,proposal:target,minimumChange:0)
    }

    /// Independent reads cannot both acquire the same previously unowned gap.
    /// Resolve their competing endpoint proposals together, before recognition;
    /// preserve the already established crops and all noncompeting endpoints.
    static func reconcilingEndpointGrowth(_ proposals: [[CGPoint]], bases: [[CGPoint]],
                                          pixelProofs: [[CGPoint]?] = [], inkStyles: [EndpointInkStyle?] = [],
                                          pixelInkProofs: [[CGPoint]?] = [],pointTerminalProofs:[[CGPoint]?] = []) -> [[CGPoint]] {
        guard refinesEndpointInk, proposals.count == bases.count else { return proposals }
        let frames = bases.map(EndpointFrame.init)
        var head = [Bool](repeating: false, count: bases.count)
        var tail = head
        for i in bases.indices {
            guard let a = frames[i] else { continue }
            for j in bases.indices where j > i {
                guard let b = frames[j] else { continue }
                let alignment = a.along.x*b.along.x + a.along.y*b.along.y
                guard abs(alignment) >= 0.95 else { continue }
                let oldA = a.rect, oldB = a.bounds(bases[j])
                let cross = min(oldA.maxX,oldB.maxX)-max(oldA.minX,oldB.minX)
                guard cross >= min(oldA.width,oldB.width)*0.6 else { continue }
                let newA = a.bounds(proposals[i]), newB = a.bounds(proposals[j])
                if alignment > 0.95,pointTerminalProofs.indices.contains(i),pointTerminalProofs.indices.contains(j),
                   let firstProof=pointTerminalProofs[i],let secondProof=pointTerminalProofs[j] {
                    let p=a.bounds(firstProof),q=a.bounds(secondProof)
                    // Both words can observe the same missed ellipsis. Its
                    // forward continuation belongs to the preceding word;
                    // the following word retains its original head. The first
                    // crop may already contain the initial points.
                    // A following head proof rewinding into those points must
                    // not cancel the forward tail. Both proofs have already
                    // excluded other private glyphs; the retained forward cap
                    // still cannot cross the following established body.
                    if oldA.maxY < oldB.minY,newA.maxY > oldA.maxY+1,newB.minY < oldB.minY-1,
                       newA.maxY > newB.minY,p.maxY >= newA.maxY-1,q.minY <= newB.minY+1,
                       p.maxY <= oldB.minY+1 {
                        head[j]=true
                        continue
                    }
                    if oldB.maxY < oldA.minY,newB.maxY > oldB.maxY+1,newA.minY < oldA.minY-1,
                       newB.maxY > newA.minY,q.maxY >= newB.maxY-1,p.minY <= newA.minY+1,
                       q.maxY <= oldA.minY+1 {
                        head[i]=true
                        continue
                    }
                }
                // Sampling padding can overlap although the measured strokes
                // do not. It cannot cancel both real endpoint recoveries.
                if pixelInkProofs.indices.contains(i),pixelInkProofs.indices.contains(j),
                   pixelProofs.indices.contains(i),pixelProofs.indices.contains(j),
                   let inkA=pixelInkProofs[i],let inkB=pixelInkProofs[j],
                   let paddedA=pixelProofs[i],let paddedB=pixelProofs[j] {
                    let paintA=a.bounds(inkA),paintB=a.bounds(inkB)
                    let readA=a.bounds(paddedA),readB=a.bounds(paddedB)
                    let coveredA=(newA.minY >= oldA.minY || newA.minY >= readA.minY-1) &&
                        (newA.maxY <= oldA.maxY || newA.maxY <= readA.maxY+1)
                    let coveredB=(newB.minY >= oldB.minY || newB.minY >= readB.minY-1) &&
                        (newB.maxY <= oldB.maxY || newB.maxY <= readB.maxY+1)
                    if coveredA,coveredB,
                       paintA.maxY <= paintB.minY || paintB.maxY <= paintA.minY { continue }
                }
                // Pixel proposals already exclude the measured peer ink. A
                // peer's rectangular padding must not overrule that stronger
                // evidence. Unmeasured proposals and competing growth into the
                // same gap still use the original conflict rules below.
                let distinct = inkStyles.indices.contains(i) && inkStyles.indices.contains(j) &&
                    distinctEndpointInk(inkStyles[i],inkStyles[j])
                func measured(_ index: Int, endpoint: CGFloat, head: Bool) -> Bool {
                    // Repeated point proof already inspected the source RGB
                    // and vetoed every other detector's actual private ink.
                    // A peer's empty rectangle cannot revoke that observation.
                    // Two competing proofs over the same novel ink remain a
                    // conflict; this does not give both reads the same gap.
                    if pointTerminalProofs.indices.contains(index),let proof=pointTerminalProofs[index] {
                        let r=a.bounds(proof),old=a.bounds(bases[index]),peer=index==i ? j:i
                        let covers=head ? r.minY <= endpoint+1:r.maxY >= endpoint-1
                        var competing=false
                        if pointTerminalProofs.indices.contains(peer),let other=pointTerminalProofs[peer] {
                            let p=a.bounds(other),start=head ? r.minY:old.maxY,end=head ? old.minY:r.maxY
                            competing=min(end,p.maxY)-max(start,p.minY) > 1
                        }
                        if covers,!competing { return true }
                    }
                    guard distinct, pixelProofs.indices.contains(index), let proof = pixelProofs[index] else { return false }
                    let r = a.bounds(proof)
                    return head ? r.minY <= endpoint+1 : r.maxY >= endpoint-1
                }
                if oldA.maxY < oldB.minY {
                    if newA.maxY > oldB.minY, newA.maxY > oldA.maxY+1,
                       !measured(i, endpoint:newA.maxY, head:false) { tail[i] = true }
                    if newB.minY < oldA.maxY, newB.minY < oldB.minY-1,
                       !measured(j, endpoint:newB.minY, head:true) {
                        if alignment > 0 { head[j] = true } else { tail[j] = true }
                    }
                }
                if oldB.maxY < oldA.minY {
                    if newA.minY < oldB.maxY, newA.minY < oldA.minY-1,
                       !measured(i, endpoint:newA.minY, head:true) { head[i] = true }
                    if newB.maxY > oldA.minY, newB.maxY > oldB.maxY+1,
                       !measured(j, endpoint:newB.maxY, head:false) {
                        if alignment > 0 { tail[j] = true } else { head[j] = true }
                    }
                }
                if oldA.maxY < oldB.minY, newA.maxY > oldA.maxY+1,
                   newB.minY < oldB.minY-1, newA.maxY > newB.minY,
                   !(measured(i,endpoint:newA.maxY,head:false) && measured(j,endpoint:newB.minY,head:true)) {
                    // A proven forward point continuation takes precedence
                    // over an unproven backward proposal. This exception is
                    // specific to observed points, not general pixel padding;
                    // it cannot grant a following word an earlier word's tail.
                    if !(alignment > 0.95 && pointTerminalProofs.indices.contains(i) && pointTerminalProofs[i] != nil &&
                         measured(i,endpoint:newA.maxY,head:false)) { tail[i] = true }
                    if alignment > 0 { head[j] = true } else { tail[j] = true }
                }
                if oldB.maxY < oldA.minY, newB.maxY > oldB.maxY+1,
                   newA.minY < oldA.minY-1, newB.maxY > newA.minY,
                   !(measured(i,endpoint:newA.minY,head:true) && measured(j,endpoint:newB.maxY,head:false)) {
                    head[i] = true
                    if !(alignment > 0.95 && pointTerminalProofs.indices.contains(j) && pointTerminalProofs[j] != nil &&
                         measured(j,endpoint:newB.maxY,head:false)) {
                        if alignment > 0 { tail[j] = true } else { head[j] = true }
                    }
                }
            }
        }
        let reconciled=proposals.indices.map { i in
            guard head[i] || tail[i], let frame = frames[i] else { return proposals[i] }
            let proposed = frame.bounds(proposals[i])
            let start = head[i] ? max(proposed.minY,frame.rect.minY) : proposed.minY
            let end = tail[i] ? min(proposed.maxY,frame.rect.maxY) : proposed.maxY
            guard end > start else { return bases[i] }
            return proposals[i].map { point in
                var p = frame.project(point)
                let weight = (p.y-proposed.minY)/proposed.height
                p.y += (1-weight)*(start-proposed.minY)+weight*(end-proposed.maxY)
                return frame.restore(p)
            }
        }
        // A newer, longer cap may cross a peer's padding although an earlier
        // independently measured point cap did not. Retry that bounded proof
        // through the SAME conflict checks instead of discarding all growth.
        // Each endpoint only moves inward to its fixed proof, so this retry
        // terminates and never exempts a competing point/source observation.
        var bounded=proposals,retry=false
        for i in proposals.indices {
            guard let frame=frames[i],pointTerminalProofs.indices.contains(i),
                  let proof=pointTerminalProofs[i] else { continue }
            let old=frame.rect,p=frame.bounds(proposals[i]),r=frame.bounds(reconciled[i]),q=frame.bounds(proof)
            var first=p.minY,last=p.maxY
            if head[i],p.minY < q.minY-1,q.minY < old.minY-1,r.minY > q.minY+1 { first=q.minY }
            if tail[i],p.maxY > q.maxY+1,q.maxY > old.maxY+1,r.maxY < q.maxY-1 { last=q.maxY }
            if first > p.minY || last < p.maxY {
                bounded[i]=proposals[i].map { point in
                    var local=frame.project(point)
                    let weight=(local.y-p.minY)/p.height
                    local.y += (1-weight)*(first-p.minY)+weight*(last-p.maxY)
                    return frame.restore(local)
                }
                retry=true
            }
        }
        return retry ? reconcilingEndpointGrowth(bounded,bases:bases,pixelProofs:pixelProofs,inkStyles:inkStyles,
            pixelInkProofs:pixelInkProofs,pointTerminalProofs:pointTerminalProofs):reconciled
    }

    /// Change only the measured along-axis span. Keep each corner's original
    /// normal coordinate instead of replacing a skew quad by its enclosure.
    static func resizingReadSpan(_ polygon:[CGPoint],head:CGFloat,tail:CGFloat)->[CGPoint] {
        guard let f=EndpointFrame(polygon),tail > head,f.rect.height > 0 else { return polygon }
        return polygon.map { point in
            var p=f.project(point)
            let weight=(p.y-f.rect.minY)/f.rect.height
            p.y=head+weight*(tail-head)
            return f.restore(p)
        }
    }

    /// A new measured cap does not independently validate a trim at the other
    /// end. If that trim crosses source print, retain its old full margin too:
    /// an outline joined to white paper may not form a separate RGB component.
    static func preservingMixedEndpointSource(baseline:[CGPoint],candidate:[CGPoint],frame:NativeOCRRGBAFrame,
        inkStyle:EndpointInkStyle?)->[CGPoint] {
        guard let f=EndpointFrame(baseline) else { return candidate }
        let old=f.rect,p=f.bounds(candidate)
        let mixed=(p.minY > old.minY+2 && p.maxY > old.maxY+2) ||
            (p.minY < old.minY-2 && p.maxY < old.maxY-2)
        guard mixed else { return candidate }
        let protected=preservingTrimCrossingInk(original:baseline,candidate:candidate,frame:frame,inkStyle:inkStyle)
        let r=f.bounds(protected)
        let head=p.minY > old.minY+2 && r.minY < p.minY-1 ? old.minY:p.minY
        let tail=p.maxY < old.maxY-2 && r.maxY > p.maxY+1 ? old.maxY:p.maxY
        guard head < p.minY || tail > p.maxY else { return candidate }
        return resizingReadSpan(baseline,head:head,tail:tail)
    }

    /// A nominal trim cannot cut through a source-coloured connected stroke
    /// merely because its detector seeds ended earlier. Observe only the old
    /// retained read; paper spanning the lane and outside pixels supply no cap.
    static func preservingTrimCrossingInk(original:[CGPoint],candidate:[CGPoint],frame:NativeOCRRGBAFrame,
        inkStyle:EndpointInkStyle?,preserveDetached:Bool = false,
        competingInkStyles:[EndpointInkStyle] = [],sourceRoots:[CGPoint]? = nil)->[CGPoint] {
        guard let f=EndpointFrame(original),let inkStyle,!inkStyle.colors.isEmpty else { return original }
        let old=f.rect,cut=f.bounds(candidate),columns=Int(ceil(old.width)),rows=Int(ceil(old.height))
        guard columns > 2,rows > 2,columns <= 524_288/rows else { return original }
        var head=cut.minY,tail=cut.maxY
        let rootMask:[Bool]?=sourceRoots.map { points in
            var mask=[Bool](repeating:false,count:columns*rows)
            for point in points {
                let p=f.project(point),x=Int(floor(p.x-old.minX)),y=Int(floor(p.y-old.minY))
                // The source and intrinsic RGB grids may differ by one cell.
                for dy in -1...1 { for dx in -1...1 {
                    let xx=x+dx,yy=y+dy
                    if xx >= 0,xx < columns,yy >= 0,yy < rows { mask[yy*columns+xx]=true }
                } }
            }
            return mask
        }
        func pixel(_ x:Int,_ y:Int)->[Int]? {
            let p=f.restore(.init(x:old.minX+CGFloat(x)+0.5,y:old.minY+CGFloat(y)+0.5))
            let xx=Int(floor(p.x)),yy=Int(floor(p.y))
            guard xx >= 0,xx < frame.width,yy >= 0,yy < frame.height else { return nil }
            let i=yy*frame.bytesPerRow+xx*4
            return (0..<3).map { Int(frame.bytes[i+$0]) }
        }
        func close(_ a:[Int],_ b:[Int],_ tolerance:Int)->Bool {
            a.count==3 && b.count==3 && zip(a,b).allSatisfy { abs($0-$1) <= tolerance }
        }
        // A shared outline can connect two differently printed words. Its
        // connectivity alone cannot transfer the peer's halo into this read.
        // Partition only that observed layer by distance to distinct measured
        // ink on either side. Ties remain ours; missing witnesses change nothing.
        func ownedLayer(_ cells:[Int],colour:[Int])->[Int] {
            let peerColours=competingInkStyles.flatMap(\.colors)
            let ownCore=inkStyle.colors.filter { c in
                !close(c,colour,48) && !peerColours.contains { close(c,$0,48) }
            }
            let peerCore=peerColours.filter { c in !inkStyle.colors.contains { close(c,$0,48) } }
            guard !ownCore.isEmpty,!peerCore.isEmpty else { return cells }
            let membership=Set(cells)
            var ownSeeds:[Int]=[],peerSeeds:[Int]=[]
            for cell in cells {
                let x=cell%columns,y=cell/columns
                var own=false,peer=false
                for dy in -1...1 { for dx in -1...1 {
                    guard let c=pixel(x+dx,y+dy) else { continue }
                    own = own || ownCore.contains { close(c,$0,32) }
                    peer = peer || peerCore.contains { close(c,$0,32) }
                } }
                if own { ownSeeds.append(cell) };if peer { peerSeeds.append(cell) }
            }
            guard ownSeeds.count >= 2,peerSeeds.count >= 2 else { return cells }
            func distances(_ seeds:[Int])->[Int:Int] {
                var distances=Dictionary(uniqueKeysWithValues:seeds.map { ($0,0) }),queue=seeds,cursor=0
                while cursor < queue.count {
                    let cell=queue[cursor];cursor+=1
                    let x=cell%columns,y=cell/columns,d=distances[cell]!+1
                    for dy in -1...1 { for dx in -1...1 {
                        let xx=x+dx,yy=y+dy,n=yy*columns+xx
                        guard xx >= 0,xx < columns,yy >= 0,yy < rows,
                              membership.contains(n),distances[n]==nil else { continue }
                        distances[n]=d;queue.append(n)
                    } }
                }
                return distances
            }
            let own=distances(ownSeeds),peer=distances(peerSeeds)
            return cells.filter { (own[$0] ?? Int.max) <= (peer[$0] ?? Int.max) }
        }
        for colour in inkStyle.colors where colour.count==3 {
            var mask=[UInt8](repeating:0,count:columns*rows)
            for y in 0..<rows { for x in 0..<columns {
                let p=f.restore(.init(x:old.minX+CGFloat(x)+0.5,y:old.minY+CGFloat(y)+0.5))
                let xx=Int(floor(p.x)),yy=Int(floor(p.y))
                guard xx >= 0,xx < frame.width,yy >= 0,yy < frame.height else { continue }
                let i=yy*frame.bytesPerRow+xx*4
                if (0..<3).allSatisfy({abs(Int(frame.bytes[i+$0])-colour[$0]) <= 32}) { mask[y*columns+x]=1 }
            } }
            var queue:[Int]=[]
            for seed in mask.indices where mask[seed] != 0 {
                queue.removeAll(keepingCapacity:true);queue.append(seed);mask[seed]=0
                var cursor=0,x0=columns,x1 = -1,y0=rows,y1 = -1
                while cursor < queue.count {
                    let p=queue[cursor];cursor+=1;let x=p%columns,y=p/columns
                    x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                    for dy in -1...1 { for dx in -1...1 {
                        let xx=x+dx,yy=y+dy
                        guard xx >= 0,xx < columns,yy >= 0,yy < rows else { continue }
                        let n=yy*columns+xx
                        if mask[n] != 0 { mask[n]=0;queue.append(n) }
                    } }
                }
                let thinRootedStroke=preserveDetached && rootMask != nil && max(x1-x0+1,y1-y0+1) >= 4
                guard queue.count >= 4,(x1-x0 >= 1 && y1-y0 >= 1) || thinRootedStroke else { continue }
                // A new pure-white family trim must not resurrect a graphic
                // merely because it crosses the old detector's edge. Only a
                // connected component rooted in actual private word pixels
                // supplies this crossing-stroke veto. Other trim paths retain
                // their established default without this optional constraint.
                if let rootMask,!queue.contains(where:{rootMask[$0]}) { continue }
                let interior=x0 > 0 && x1 < columns-1
                // A real outline may touch both normal edges of the old
                // reading strip. Sparse stroke occupancy distinguishes that
                // border from a dense paper component spanning the crop.
                let area=(x1-x0+1)*(y1-y0+1)
                guard interior || queue.count*5 < area*3 else { continue }
                let owned=ownedLayer(queue,colour:colour)
                guard let firstRow=owned.map({$0/columns}).min(),let lastRow=owned.map({$0/columns}).max() else { continue }
                let first=old.minY+CGFloat(firstRow),last=old.minY+CGFloat(lastRow+1)
                if cut.minY > old.minY+1,first < cut.minY,last > cut.minY {
                    head=min(head,max(old.minY,first-2))
                }
                if cut.maxY < old.maxY-1,first < cut.maxY,last > cut.maxY {
                    tail=max(tail,min(old.maxY,last+2))
                }
                // A new fallback cannot certify that an entire retained
                // source-colour stroke is empty merely because CTC omits it.
                // This applies only to the new retries, not verified legacy
                // weak-word trims. Dense paper was excluded above.
                if preserveDetached {
                    if cut.minY > old.minY+1,last <= cut.minY {
                        head=min(head,max(old.minY,first-2))
                    }
                    if cut.maxY < old.maxY-1,first >= cut.maxY {
                        tail=max(tail,min(old.maxY,last+2))
                    }
                }
            }
        }
        return resizingReadSpan(original,head:head,tail:tail)
    }

    /// A shared component can still have an unambiguous printed core inside
    /// an actual read. Use only its cells outside every known competitor;
    /// this supplies a trim keep-constraint, never private ownership metadata.
    static func exclusiveObservedTrimInk(index:Int,boxes:[NativeCoreMLDetectionBox])->[CGPoint]? {
        guard boxes.indices.contains(index),let evidence=boxes[index].detectorSeedEvidence,
              evidence.isValid,evidence.components.isEmpty,evidence.ownershipVersion == 2,
              evidence.completeCCScan == true,let basis=EndpointFrame(boxes[index].polygon) else { return nil }
        let peers=endpointFontPeerPolygons(boxes)
        let sx=CGFloat(evidence.sourceWidth)/CGFloat(evidence.mapFullWidth)
        let sy=CGFloat(evidence.sourceHeight)/CGFloat(evidence.mapFullHeight)
        var points:[CGPoint]=[]
        for candidate in evidence.candidateComponents ?? [] {
            let component=candidate.component,owners=candidate.competingOwnerIDs
            guard !owners.isEmpty,candidate.outsideCompetingCells.count==owners.count,
                  candidate.outsideCompetingCells.allSatisfy({$0*5 >= component.pixelCount*4}),
                  component.meanProbability >= evidence.threshold,
                  owners.allSatisfy({!(peers[$0]?.isEmpty ?? true)}) else { continue }
            let competitors=owners.flatMap { peers[$0] ?? [] }
            var cells:[CGPoint]=[]
            for run in component.runs { for x in run.x..<(run.x+run.count) {
                let p=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                if NativeOCRDirectionGeometry.contains(boxes[index].polygon,p),
                   !competitors.contains(where:{NativeOCRDirectionGeometry.contains($0,p)}) {
                    cells.append(p)
                }
            } }
            guard cells.count >= 8,cells.count*5 >= component.pixelCount*4 else { continue }
            for p in cells {
                points += corners(CGRect(x:p.x-sx/2,y:p.y-sy/2,width:sx,height:sy))
            }
        }
        guard points.count >= 32,basis.bounds(points).height >= basis.rect.width*2 else { return nil }
        return points
    }

    /// Shared detector cells alone cannot certify which same-print glyphs an
    /// established crop may discard. Require every recorded competing print
    /// to have an independently measured, distinct style before this new trim.
    static func observedTrimCompetitorStyles(index:Int,boxes:[NativeCoreMLDetectionBox],
        inkStyles:[EndpointInkStyle?]?)->[EndpointInkStyle]? {
        guard boxes.indices.contains(index),let inkStyles,inkStyles.indices.contains(index),
              let own=inkStyles[index],exclusiveObservedTrimInk(index:index,boxes:boxes) != nil else { return nil }
        // A lone colour fitted from a shared CC may be the paper between
        // letters. This outline-specific path needs both observed layers;
        // without a distinct core it cannot partition a shared halo at all.
        guard own.colors.contains(where: { a in own.colors.contains { b in
            a.count==3 && b.count==3 && zip(a,b).map { abs($0-$1) }.max()! > 96
        } }) else { return nil }
        let owners=Set((boxes[index].detectorSeedEvidence?.candidateComponents ?? []).flatMap(\.competingOwnerIDs))
        var styles:[EndpointInkStyle]=[]
        for owner in owners {
            let matches=boxes.indices.filter { boxes[$0].detectorSeedEvidence?.ownerID==owner }
            guard !matches.isEmpty else { return nil }
            for j in matches {
                guard inkStyles.indices.contains(j),let peer=inkStyles[j],distinctEndpointInk(own,peer) else { return nil }
                styles.append(peer)
            }
        }
        return styles.isEmpty ? nil:styles
    }

    /// Remove demonstrably empty crop tails without changing detector owners.
    /// The immutable high-probability core is a keep constraint, not a target.
    static func trimmingEndpointPadding(index: Int, boxes: [NativeCoreMLDetectionBox], polygon: [CGPoint],
                                        layout: NativeRFDETRLayoutResult?, frame: NativeOCRRGBAFrame,
                                        inkStyles: [EndpointInkStyle?]? = nil, audit: (([String: Any]) -> Void)? = nil,
                                        observedWord:Bool = false,immutableObservation:Bool = false) -> [CGPoint] {
        guard refinesEndpointInk, boxes.indices.contains(index), boxes[index].score >= 0.8 || observedWord,
              let evidence = boxes[index].detectorSeedEvidence, evidence.isValid,
              evidence.sourceWidth == frame.width, evidence.sourceHeight == frame.height,
              let basis = EndpointFrame(polygon) else { return polygon }
        let sx = CGFloat(frame.width)/CGFloat(evidence.mapFullWidth)
        let sy = CGFloat(frame.height)/CGFloat(evidence.mapFullHeight)
        var privateInk: [CGPoint] = []
        for component in evidence.components { for run in component.runs {
            // A shared CC can continue into another deliberately independent
            // read. Only cells in this detector crop are its keep constraint.
            var first: Int?, last: Int?
            for x in run.x..<(run.x + run.count) {
                let center = CGPoint(x: (CGFloat(x) + 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy)
                if NativeOCRDirectionGeometry.contains(boxes[index].polygon, center) {
                    if first == nil { first = x }; last = x
                }
            }
            if let first, let last {
                privateInk.append(contentsOf: corners(CGRect(x: CGFloat(first)*sx, y: CGFloat(run.y)*sy,
                    width: CGFloat(last-first+1)*sx, height: sy)))
            }
        } }
        if privateInk.isEmpty,observedWord,
           observedTrimCompetitorStyles(index:index,boxes:boxes,inkStyles:inkStyles) != nil {
            privateInk=exclusiveObservedTrimInk(index:index,boxes:boxes) ?? []
        }
        guard !privateInk.isEmpty else { return polygon }
        var candidates=boxes
        if !immutableObservation {
            candidates[index] = .init(polygon:polygon,score:boxes[index].score,detectorSeedEvidence:evidence)
        }
        // A larger read is an observation window, not a new original owner.
        // A post-read paired trim can measure from the immutable source while
        // retaining the current read as its complete-word recognition control.
        guard let measured = pixelEndpointCompletion(index:index,boxes:candidates,layout:layout,frame:frame,
                                                       protectedInk:privateInk,protectedEvidence:evidence,audit:audit,inkStyles:inkStyles,
                                                       sourcePolygon:boxes[index].polygon) else { return polygon }
        var measuredBounds = basis.bounds(measured)
        let uncertainty = max(2,ceil(max(sx,sy))+1)
        let sourceBounds=basis.bounds(boxes[index].polygon)
        // Rebuilding a trim graph from direct colour matches can retain a
        // detached background tail rejected by the growth paint model. Retry
        // only a resolved, added half-cell beyond the immutable detector read.
        // Sub-cell padding changes cannot retune established crop boundaries,
        // and the retry cannot remove any part of the original source window.
        let resolved=max(uncertainty,basis.rect.width*0.5)
        if sourceBounds.minY-measuredBounds.minY > resolved || measuredBounds.maxY-sourceBounds.maxY > resolved,
           let admitted=pixelEndpointCompletion(index:index,boxes:candidates,layout:layout,frame:frame,
                protectedInk:privateInk,protectedEvidence:evidence,admittedTrimInk:true,audit:audit,
                inkStyles:inkStyles,sourcePolygon:boxes[index].polygon) {
            let alternative=basis.bounds(admitted)
            var head=measuredBounds.minY,tail=measuredBounds.maxY
            let admittedHead=min(alternative.minY,sourceBounds.minY)
            let admittedTail=max(alternative.maxY,sourceBounds.maxY)
            if admittedHead-head > resolved {head=admittedHead}
            if tail-admittedTail > resolved {tail=admittedTail}
            if head != measuredBounds.minY || tail != measuredBounds.maxY {
                audit?(["resolvedTrimHead":head,"resolvedTrimTail":tail,
                    "resolvedTrimMinimum":resolved,"resolvedTrimSourceHead":sourceBounds.minY,
                    "resolvedTrimSourceTail":sourceBounds.maxY])
                measuredBounds=CGRect(x:measuredBounds.minX,y:head,width:measuredBounds.width,height:tail-head)
            }
        }
        var start = max(basis.rect.minY, measuredBounds.minY), end = min(basis.rect.maxY, measuredBounds.maxY)
        // Once source pixels certify empty padding and the private foreground
        // is retained, the detector edge has no separate glyph-sized exemption.
        // Paired recognition still rejects any loss of previously accepted text.
        // One detector cell plus source raster rounding is not a resolved
        // new endpoint. Suppress that uncertainty without a glyph-sized floor.
        if start-basis.rect.minY <= uncertainty { start = basis.rect.minY }
        if basis.rect.maxY-end <= uncertainty { end = basis.rect.maxY }
        guard start > basis.rect.minY+1 || end < basis.rect.maxY-1 else { return polygon }
        return polygon.map { point in
            var p = basis.project(point)
            let weight = (p.y-basis.rect.minY)/basis.rect.height
            p.y += (1-weight)*(start-basis.rect.minY)+weight*(end-basis.rect.maxY)
            return basis.restore(p)
        }
    }

    static var privateInkWidthEnabled:Bool {
        if let value=ProcessInfo.processInfo.environment["AIDOKU_OCR_PRIVATE_INK_WIDTH"] {return value == "1"}
        return mainMangaEndpointPolicy
    }

    /// Fit empty lateral padding in the same intrinsic frame as endpoint
    /// measurement. RF binds the text region; private cells and actual source
    /// paint protect its width. Neither ownership nor the along span changes.
    static func fittingPrivateInkWidth(index:Int,boxes:[NativeCoreMLDetectionBox],polygon:[CGPoint],
        layout:NativeRFDETRLayoutResult?,frame:NativeOCRRGBAFrame,audit:(([String:Any])->Void)? = nil)->[CGPoint] {
        guard refinesEndpointInk,privateInkWidthEnabled,boxes.indices.contains(index),
              let evidence=boxes[index].detectorSeedEvidence,evidence.isValid,!evidence.components.isEmpty,
              evidence.sourceWidth == frame.width,evidence.sourceHeight == frame.height,
              let basis=EndpointFrame(polygon),let layout,
              layout.sourceWidth == frame.width,layout.sourceHeight == frame.height else {return polygon}
        let r=basis.rect,sx=CGFloat(frame.width)/CGFloat(evidence.mapFullWidth),
            sy=CGFloat(frame.height)/CGFloat(evidence.mapFullHeight)
        let radiusX=(abs(basis.across.x)*sx+abs(basis.across.y)*sy)/2
        let radiusY=(abs(basis.along.x)*sx+abs(basis.along.y)*sy)/2
        var roots=CGRect.null,cellCount=0
        for component in evidence.components {for run in component.runs {for x in run.x..<(run.x+run.count) {
            let world=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
            guard NativeOCRDirectionGeometry.contains(boxes[index].polygon,world) else {continue}
            let p=basis.project(world)
            roots=roots.union(CGRect(x:p.x-radiusX,y:p.y-radiusY,width:radiusX*2,height:radiusY*2));cellCount+=1
        }}}
        guard cellCount >= 12,!roots.isNull,roots.width >= 6,r.width >= roots.width*1.5,
              r.height >= roots.width*2,roots.height >= r.height*0.55 else {return polygon}
        audit?(["privateWidthCandidate":r.width,"privateWidthRootSpan":roots.width,
            "privateWidthRootHeight":roots.height,"privateWidthReadHeight":r.height])
        let textScopes=layout.primitives.compactMap { primitive -> (confidence:Float,width:CGFloat,cell:CGFloat)? in
            guard primitive.semanticClass == .text,primitive.confidence >= 0.25 else {return nil}
            let support=NativeOCRDirectionAdapters.support(primitive),rf=basis.bounds(support),overlap=rf.intersection(roots)
            // A wide paragraph covering a thin glyph rail does not corroborate
            // a thin reading cell. RF must independently resolve a much
            // narrower single lane, using the same excess-padding criterion
            // as the private cells above.
            guard !overlap.isNull,overlap.width*overlap.height >= roots.width*roots.height*0.7,
                  r.width >= rf.width*1.5 else {return nil}
            return (primitive.confidence,rf.width,NativeOCRDirectionGeometry.area(support)/max(1,rf.height))
        }.sorted{$0.confidence > $1.confidence}
        guard let textScope=textScopes.first else {audit?(["privateWidthSkip":"no-narrow-RF-consensus"]);return polygon}
        audit?(["privateWidthRFSpan":textScope.width,"privateWidthRFCell":textScope.cell])
        let columns=Int(ceil(r.width)),rows=Int(ceil(r.height))
        guard columns >= 3,rows > 0,columns <= 524_288/rows else {return polygon}
        func world(_ row:Int,_ column:Int)->CGPoint {
            basis.restore(CGPoint(x:r.minX+CGFloat(column)+0.5,y:r.minY+CGFloat(row)+0.5))
        }
        func rgb(_ row:Int,_ column:Int)->[Int]? {
            let p=world(row,column),x=Int(floor(p.x)),y=Int(floor(p.y))
            guard x >= 0,y >= 0,x < frame.width,y < frame.height else {return nil}
            let k=y*frame.bytesPerRow+x*4
            return [Int(frame.bytes[k]),Int(frame.bytes[k+1]),Int(frame.bytes[k+2])]
        }
        var sourceMask=[Bool](repeating:false,count:columns*rows)
        for row in 0..<rows {for column in 0..<columns {
            sourceMask[row*columns+column]=NativeOCRDirectionGeometry.contains(boxes[index].polygon,world(row,column))
        }}
        guard let paint=endpointPalette(evidence:evidence,columns:columns,rows:rows,start:0,length:r.height,
            project:{p in let q=basis.project(p);return CGPoint(x:q.x-r.minX,y:q.y-r.minY)},
            rgb:rgb,sourceMask:sourceMask,candidatePeerPolygons:endpointFontPeerPolygons(boxes)) else {return polygon}
        let ownSeeds=Set(evidence.components.map(\.seed))
        var foreign=[Bool](repeating:false,count:columns*rows)
        for peer in boxes.indices where peer != index {
            guard let other=boxes[peer].detectorSeedEvidence,other.isValid,
                  other.sourceWidth == frame.width,other.sourceHeight == frame.height else {continue}
            let ox=CGFloat(frame.width)/CGFloat(other.mapFullWidth),oy=CGFloat(frame.height)/CGFloat(other.mapFullHeight)
            for component in other.components where !ownSeeds.contains(component.seed) {
                for run in component.runs {for x in run.x..<(run.x+run.count) {
                    let p=basis.project(CGPoint(x:(CGFloat(x)+0.5)*ox,y:(CGFloat(run.y)+0.5)*oy))
                    let column=Int(floor(p.x-r.minX)),row=Int(floor(p.y-r.minY))
                    if column >= 0,column < columns,row >= 0,row < rows {foreign[row*columns+column]=true}
                }}
            }
        }
        // A detector may root the coloured fill but miss its white collar.
        // Keep source contrast connected to that fill too. Unstable lateral
        // paper is unknown, so it cannot certify a narrower reading crop.
        var mask=paint.mask
        let rim=max(1,columns/10)
        let reserve=max(3,roots.width*0.12)
        let leftRim=Int(floor(roots.minX-r.minX-reserve))-rim
        let rightRim=Int(ceil(roots.maxX-r.minX+reserve))
        for row in 0..<rows {
            // Broad detector padding can reach beyond the actual paper. Use
            // independently stable gutters beside the private paint instead
            // of treating two different surfaces as one noisy background.
            let papers=[leftRim,rightRim].compactMap { first -> ([Int],Int)? in
                let border=(0..<rim).compactMap{rgb(row,first+$0)}
                guard border.count >= 2 else {return nil}
                let paper=(0..<3).map{channel in border.map{$0[channel]}.sorted()[border.count/2]}
                let deviations=border.map{c in zip(c,paper).map{abs($0-$1)}.max()!}.sorted()
                let noise=deviations[deviations.count/2]
                return noise <= 16 ? (paper,max(24,noise*4)):nil
            }
            if papers.isEmpty {
                if (0..<columns).contains(where:{paint.seeds[row*columns+$0] && paint.mask[row*columns+$0] != 0}) {
                    audit?(["privateWidthSkip":"unstable-private-gutters","row":row]);return polygon
                }
                continue
            }
            for column in 0..<columns {
                if let c=rgb(row,column),papers.allSatisfy({paper,cutoff in
                    zip(c,paper).map({abs($0-$1)}).max()! > cutoff
                }) {
                    mask[row*columns+column]=1
                }
            }
        }
        var queue:[Int]=[],extent=CGRect.null,owned=CGRect.null,ownedPixels=0
        for seed in mask.indices where mask[seed] != 0 {
            queue.removeAll(keepingCapacity:true);queue.append(seed);mask[seed]=0
            var cursor=0,left=columns,right=0,top=rows,bottom=0,privatePixels=0,foreignPixels=0,palettePixels=0
            while cursor < queue.count {
                let cell=queue[cursor];cursor+=1;let x=cell%columns,y=cell/columns
                left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                if paint.seeds[cell],paint.mask[cell] != 0 {privatePixels+=1}
                if paint.mask[cell] != 0 {palettePixels+=1}
                if foreign[cell] {foreignPixels+=1}
                for dy in -1...1 {for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx=x+dx,yy=y+dy
                    guard xx >= 0,xx < columns,yy >= 0,yy < rows else {continue}
                    let next=yy*columns+xx
                    if mask[next] != 0 {mask[next]=0;queue.append(next)}
                }}
            }
            let box=CGRect(x:r.minX+CGFloat(left),y:r.minY+CGFloat(top),
                width:CGFloat(right-left+1),height:CGFloat(bottom-top+1))
            let rooted=privatePixels >= 2 && queue.count >= 8
            let context=foreignPixels == 0 && queue.count >= 4 && palettePixels*5 >= queue.count*4 && box.width <= roots.width*1.5 &&
                box.height <= roots.width*2 && box.midX >= roots.minX-roots.width*0.25 &&
                box.midX <= roots.maxX+roots.width*0.25
            guard rooted || context else {continue}
            if rooted,foreignPixels > 0 {audit?(["privateWidthSkip":"foreign-connected-print"]);return polygon}
            // A cut normal contour is unknown, not evidence of empty padding.
            guard left > 0,right < columns-1 else {audit?(["privateWidthSkip":"open-normal-contour"]);return polygon}
            extent=extent.union(box)
            if rooted {owned=owned.union(box);ownedPixels+=privatePixels}
        }
        guard ownedPixels >= 12,!owned.isNull,!extent.isNull,
              owned.height >= r.height*0.55,owned.height >= roots.width*2 else {return polygon}
        // Preserve every original private cell, even if an antialiased edge
        // did not exactly match the observed paint. Source paint can widen
        // this keep interval, but cannot create a new detector owner.
        let keep=extent.union(roots),padding=max(2,keep.width*0.08)
        // A dot or narrow letter can occupy only part of RF's measured text
        // cell. Preserve that normal cell as well as the actual source paint.
        let halfCell=max(keep.width,textScope.cell)/2
        var left=max(r.minX,min(keep.minX,keep.midX-halfCell)-padding)
        var right=min(r.maxX,max(keep.maxX,keep.midX+halfCell)+padding)
        let uncertainty=max(2,ceil(max(sx,sy))+1)
        if left-r.minX <= uncertainty {left=r.minX}
        if r.maxX-right <= uncertainty {right=r.maxX}
        guard right > left,right-left <= r.width*0.85,
              left > r.minX+uncertainty || right < r.maxX-uncertainty else {return polygon}
        audit?(["privateWidthBefore":r.width,"privateWidthAfter":right-left,"privateWidthCells":cellCount,
            "privateWidthOwnedPaint":ownedPixels,"privateWidthKeep": [keep.minX,keep.maxX]])
        return polygon.map { point in
            var p=basis.project(point)
            let weight=(p.x-r.minX)/r.width
            p.x += (1-weight)*(left-r.minX)+weight*(right-r.maxX)
            return basis.restore(p)
        }
    }

    /// Finish only closed normal contours physically connected to private
    /// source paint. RF nominates text, but cannot supply blank lateral pad.
    static func completingPrivateNormalInk(index:Int,boxes:[NativeCoreMLDetectionBox],polygon:[CGPoint],
        layout:NativeRFDETRLayoutResult?,frame:NativeOCRRGBAFrame,inkStyle:EndpointInkStyle? = nil,
        audit:(([String:Any])->Void)? = nil)->[CGPoint] {
        guard refinesEndpointInk,privateInkWidthEnabled,boxes.indices.contains(index),
              let evidence=boxes[index].detectorSeedEvidence,evidence.isValid,!evidence.components.isEmpty,
              evidence.sourceWidth==frame.width,evidence.sourceHeight==frame.height,
              let basis=EndpointFrame(polygon),let layout,
              layout.sourceWidth==frame.width,layout.sourceHeight==frame.height else {return polygon}
        let r=basis.rect,area=NativeOCRDirectionGeometry.area(polygon)
        guard r.width>=6,r.height>=r.width*2,layout.primitives.contains(where:{ primitive in
            guard primitive.semanticClass == .text,primitive.confidence>=0.25 else {return false}
            let support=NativeOCRDirectionAdapters.support(primitive),rf=basis.bounds(support)
            // A paragraph cannot certify which neighbouring normal lane is
            // cropped. Require an independently resolved single reading cell.
            return rf.width>=r.width*1.15 && rf.width<=r.width*1.8 &&
                rf.height>=r.height*0.8 && rf.height<=r.height*1.4 &&
                NativeOCRDirectionGeometry.intersectionArea(polygon,support)>=area*0.7
        }) else {return polygon}
        let margin=max(4,r.width*0.6),start=r.minX-margin
        let columns=Int(ceil(r.width+margin*2)),rows=Int(ceil(r.height))
        guard rows>0,columns<=524_288/rows else {return polygon}
        func world(_ y:Int,_ x:Int)->CGPoint {
            basis.restore(CGPoint(x:start+CGFloat(x)+0.5,y:r.minY+CGFloat(y)+0.5))
        }
        func rgb(_ y:Int,_ x:Int)->[Int]? {
            let p=world(y,x),xx=Int(floor(p.x)),yy=Int(floor(p.y))
            guard xx>=0,yy>=0,xx<frame.width,yy<frame.height else {return nil}
            let k=yy*frame.bytesPerRow+xx*4
            return [Int(frame.bytes[k]),Int(frame.bytes[k+1]),Int(frame.bytes[k+2])]
        }
        var source=[Bool](repeating:false,count:columns*rows)
        for y in 0..<rows {for x in 0..<columns {
            source[y*columns+x]=NativeOCRDirectionGeometry.contains(boxes[index].polygon,world(y,x))
        }}
        guard let paint=endpointPalette(evidence:evidence,columns:columns,rows:rows,start:0,length:r.height,
            project:{let p=basis.project($0);return CGPoint(x:p.x-start,y:p.y-r.minY)},rgb:rgb,
            audit:audit,sourceMask:source,candidatePeerPolygons:endpointFontPeerPolygons(boxes)) else {return polygon}
        // Wider context must not relearn coloured paper as primary ink.
        // Keep the original private-source palette as the independent witness.
        guard let measuredInk=paint.inkStyle.colors.first else {return polygon}
        let sourceInk=inkStyle?.colors.first
        if let sourceInk,zip(sourceInk,measuredInk).map({abs($0-$1)}).max()!>24 {
            // Context cannot overrule a previously established print family.
            audit?(["normalContourSkip":"known-source-primary-conflict"]);return polygon
        }
        if sourceInk == nil {
            // A severely cut original can itself have a poor palette. A new
            // primary must independently contrast with BOTH stable gutters
            // on several privately rooted rows; near-paper shades never pass.
            let rim=max(2,Int(ceil(r.width*0.08)))
            var contrastedRows=0
            for y in 0..<rows where (0..<columns).contains(where:{paint.seeds[y*columns+$0] && paint.primaryMask[y*columns+$0] != 0}) {
                let valid=[0,columns-rim].allSatisfy { first in
                    let colours=(first..<(first+rim)).compactMap{rgb(y,$0)}
                    guard colours.count==rim else {return false}
                    let paper=(0..<3).map{k in colours.map{$0[k]}.sorted()[colours.count/2]}
                    let noise=colours.map{zip($0,paper).map{abs($0-$1)}.max()!}.sorted()[colours.count/2]
                    return noise<=12 && zip(measuredInk,paper).map{abs($0-$1)}.max()!>=max(32,noise*4)
                }
                if valid {contrastedRows+=1}
            }
            guard contrastedRows>=4 else {
                audit?(["normalContourSkip":"new-primary-is-local-paper"]);return polygon
            }
        }
        var primary=paint.primaryMask,cutPrint=[Bool](repeating:false,count:primary.count),work:[Int]=[]
        for seed in primary.indices where primary[seed] != 0 {
            work.removeAll(keepingCapacity:true);work.append(seed);primary[seed]=0
            var cursor=0,left=columns,right=0,top=rows,bottom=0,roots=0
            while cursor<work.count {
                let cell=work[cursor];cursor+=1;let x=cell%columns,y=cell/columns
                left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                if paint.seeds[cell] {roots+=1}
                for dy in -1...1 {for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx=x+dx,yy=y+dy
                    if xx>=0,xx<columns,yy>=0,yy<rows,primary[yy*columns+xx] != 0 {
                        primary[yy*columns+xx]=0;work.append(yy*columns+xx)
                    }
                }}
            }
            // Source-sized print must itself be substantially clipped.
            // A continuous backing panel or a tiny antialias protrusion does
            // not prove that a whole reading cell needs normal expansion.
            let cut=max(r.minX-(start+CGFloat(left)),start+CGFloat(right+1)-r.maxX)
            if roots>=2,work.count>=8,left>0,right<columns-1,CGFloat(bottom-top+1)<=r.width*2,
               CGFloat(right-left+1)<=r.width*1.8,cut>max(2,r.width*0.12) {
                for cell in work {cutPrint[cell]=true}
            }
        }
        guard cutPrint.contains(true) else {return polygon}
        let cutRows=(0..<rows).map { y in (0..<columns).contains(where:{cutPrint[y*columns+$0]}) }
        let cutRootRows=(0..<rows).map { y in (0..<columns).contains(where:{cutPrint[y*columns+$0] && paint.seeds[y*columns+$0]}) }
        audit?(["normalCutRows":cutRows.enumerated().filter{$0.element}.map{$0.offset},
            "normalCutRootRows":cutRootRows.enumerated().filter{$0.element}.map{$0.offset},
            "normalCutTotalRows":rows,"normalCutGlyphFraction":Double(cutRows.filter{$0}.count)/Double(rows),
            "normalCutWidth":r.width,"normalCutColour":paint.inkStyle.colors.first ?? []])
        // Disconnected end flares cannot certify a new width for a whole
        // word through the bounding height of a larger connected backing.
        guard cutRows.filter({$0}).count*10>=rows*3 else {return polygon}
        var mask=paint.mask,foreign=[Bool](repeating:false,count:mask.count)
        let ownSeeds=Set(evidence.components.map(\.seed))
        for peer in boxes.indices where peer != index {
            guard let other=boxes[peer].detectorSeedEvidence,other.isValid,
                  other.sourceWidth==frame.width,other.sourceHeight==frame.height else {continue}
            let sx=CGFloat(frame.width)/CGFloat(other.mapFullWidth),sy=CGFloat(frame.height)/CGFloat(other.mapFullHeight)
            for component in other.components where !ownSeeds.contains(component.seed) {
                for run in component.runs {for xx in run.x..<(run.x+run.count) {
                    let p=basis.project(CGPoint(x:(CGFloat(xx)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy))
                    let x=Int(floor(p.x-start)),y=Int(floor(p.y-r.minY))
                    if x>=0,x<columns,y>=0,y<rows {foreign[y*columns+x]=true}
                }}
            }
        }
        // A collar may be absent from the map and the root colour palette.
        // Independent stable side gutters certify contrast around the print.
        let rim=max(2,Int(ceil(r.width*0.08)))
        for y in 0..<rows {
            let papers=[0,columns-rim].compactMap { first -> ([Int],Int)? in
                let c=(first..<(first+rim)).compactMap{rgb(y,$0)}
                guard c.count==rim else {return nil}
                let median=(0..<3).map{k in c.map{$0[k]}.sorted()[c.count/2]}
                let d=c.map{zip($0,median).map{abs($0-$1)}.max()!}.sorted()
                let noise=d[d.count/2]
                return noise<=12 ? (median,max(24,noise*4)):nil
            }
            guard !papers.isEmpty else {continue}
            for x in 0..<columns {
                if let c=rgb(y,x),papers.allSatisfy({p,t in zip(c,p).map{abs($0-$1)}.max()!>t}) {
                    mask[y*columns+x]=1
                }
            }
        }
        var queue:[Int]=[],extent=CGRect.null,rooted=CGRect.null,totalRoots=0,openRoots=0,foreignRoots=0
        for seed in mask.indices where mask[seed] != 0 {
            queue.removeAll(keepingCapacity:true);queue.append(seed);mask[seed]=0
            var cursor=0,left=columns,right=0,top=rows,bottom=0,roots=0,others=0,primaryRoots=0,cutWitness=0
            var primaryExtent=CGRect.null
            while cursor<queue.count {
                let cell=queue[cursor];cursor+=1;let x=cell%columns,y=cell/columns
                left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                if paint.seeds[cell],paint.mask[cell] != 0 {roots+=1}
                if paint.primaryMask[cell] != 0 {
                    primaryExtent=primaryExtent.union(CGRect(x:start+CGFloat(x),y:r.minY+CGFloat(y),width:1,height:1))
                    if paint.seeds[cell] {primaryRoots+=1}
                }
                if foreign[cell] {others+=1}
                if cutPrint[cell] {cutWitness+=1}
                for dy in -1...1 {for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx=x+dx,yy=y+dy
                    if xx>=0,xx<columns,yy>=0,yy<rows,mask[yy*columns+xx] != 0 {
                        mask[yy*columns+xx]=0;queue.append(yy*columns+xx)
                    }
                }}
            }
            guard roots>=2,queue.count>=8 else {continue}
            if left==0 || right==columns-1 {openRoots+=roots;continue}
            if others>0 {foreignRoots+=roots;continue}
            let box=CGRect(x:start+CGFloat(left),y:r.minY+CGFloat(top),width:CGFloat(right-left+1),height:CGFloat(bottom-top+1))
            // A closed backing tile is not a cut glyph. The independently
            // rooted primary print itself must cross the retained boundary;
            // a white companion or unrelated contrast alone cannot nominate it.
            let cut=max(r.minX-primaryExtent.minX,primaryExtent.maxX-r.maxX)
            audit?(["normalContourComponentRoots":roots,"normalContourPrimaryRoots":primaryRoots,
                "normalContourPrimaryCut":cut,"normalContourComponentWidth":box.width])
            guard box.width<=r.width*1.8,primaryRoots>=2,cutWitness>=8,!primaryExtent.isNull,
                  cut>max(2,r.width*0.12) else {continue}
            totalRoots+=roots;extent=extent.union(box);rooted=rooted.union(box.intersection(r))
        }
        guard totalRoots>=12,!extent.isNull,!rooted.isNull,rooted.height>=r.height*0.55,
              extent.width<=r.width*1.8 else {return polygon}
        let padding=max(1,min(3,r.width*0.04))
        let left=min(r.minX,extent.minX-padding),right=max(r.maxX,extent.maxX+padding)
        let uncertainty=max(2,r.width*0.06)
        guard r.minX-left>uncertainty || right-r.maxX>uncertainty else {return polygon}
        audit?(["normalContourBefore":r.width,"normalContourAfter":right-left,"normalContourRoots":totalRoots,
            "normalContourOpenRoots":openRoots,"normalContourForeignRoots":foreignRoots])
        let result=polygon.map { point -> CGPoint in
            var p=basis.project(point);let weight=(p.x-r.minX)/r.width
            p.x+=(1-weight)*(left-r.minX)+weight*(right-r.maxX);return basis.restore(p)
        }
        return result.allSatisfy({$0.x>=0 && $0.y>=0 && $0.x<=CGFloat(frame.width) && $0.y<=CGFloat(frame.height)}) ? result:polygon
    }

    struct Group: Sendable {
        let index: Int
        let members: [Int]
        let evidence: [NativeOCRDetectorSeedEvidence]
        var pointFragments: Set<Int> = []
        var sourcePixelLane = false
    }

    /// Sampling-only alternatives for a strong tiny DB core whose primary read
    /// failed. Detector geometry/ownership stays unchanged. The caller requires
    /// two agreeing above-threshold reads, never a confidence-floor exception.
    static func smallCoreContextPolygons(index: Int,boxes: [NativeCoreMLDetectionBox],
                                         width: Int,height: Int) -> [[CGPoint]] {
        guard boxes.indices.contains(index),boxes[index].score >= 0.75,
              !(boxes[index].detectorSeedEvidence?.components.isEmpty ?? true),
              let q=NativeOCRDirectionGeometry.readingQuad(boxes[index].polygon,vertical:true),
              let basis=NativeOCRDirectionGeometry.Frame(q),basis.rect.width >= 6,basis.rect.width <= 24,
              basis.rect.height >= basis.rect.width,basis.rect.height <= basis.rect.width*6 else { return [] }
        let canvas=CGRect(x:0,y:0,width:width,height:height)
        let own=boxes[index].detectorSeedEvidence!
        let ownCells=Set((own.components+(own.ambiguousComponents ?? [])+(own.candidateComponents ?? []).map(\.component)).map {
            SIMD3(own.mapFullWidth,own.mapFullHeight,$0.seed)
        })
        let margins:[(CGFloat,CGFloat)]=[(0.2,0.2),(0.4,0.4),(0.15,0.45),(0.45,0.15)]
        return margins.compactMap { head,tail in
            // A failed isolated near-square glyph needs blank sampling context
            // on BOTH axes; elongating it alone changes the recognition layout.
            let side:CGFloat = basis.rect.height < basis.rect.width*1.5 ? (head+tail)/2 : 0.05
            let r=CGRect(x:basis.rect.minX-basis.rect.width*side,y:basis.rect.minY-basis.rect.width*head,
                width:basis.rect.width*(1+side*2),height:basis.rect.height+basis.rect.width*(head+tail))
            let polygon=NativeOCRDirectionGeometry.corners(r).map(basis.restore)
            guard polygon.allSatisfy({ canvas.contains($0) }), !boxes.indices.contains(where:{ peer in
                guard peer != index else { return false }
                let b=basis.bounds(boxes[peer].polygon),overlap=r.intersection(b)
                let old=basis.rect.intersection(b)
                let area=overlap.isNull ? 0 : overlap.width*overlap.height
                let prior=old.isNull ? 0 : old.width*old.height
                guard area > prior+1 else { return false }
                // A peer's recognition margin is not peer glyph ink. Permit
                // blank context inside that margin, never newly sampled peer
                // components; shared original CCs are the SAME physical glyph.
                guard let evidence=boxes[peer].detectorSeedEvidence,evidence.isValid,
                      evidence.sourceWidth == width,evidence.sourceHeight == height else { return true }
                let components=evidence.components + (evidence.ambiguousComponents ?? []) +
                    (evidence.candidateComponents ?? []).map(\.component)
                for component in components where !ownCells.contains(SIMD3(evidence.mapFullWidth,evidence.mapFullHeight,component.seed)) {
                    for run in component.runs { for x in run.x..<(run.x+run.count) {
                        let point=basis.project(CGPoint(x:(CGFloat(x)+0.5)*CGFloat(width)/CGFloat(evidence.mapFullWidth),
                            y:(CGFloat(run.y)+0.5)*CGFloat(height)/CGFloat(evidence.mapFullHeight)))
                        if r.contains(point) && !basis.rect.contains(point) { return true }
                    } }
                }
                return false
            }) else { return nil }
            return polygon
        }
    }

    struct RefinedCrop: Sendable {
        let index: Int
        let parent: Int
    }

    struct Plan: Sendable {
        let boxes: [NativeCoreMLDetectionBox]
        let supported: Set<Int>
        let stronglySupported: Set<Int>
        let groups: [Group]
        let refinedCrops: [RefinedCrop]
    }

    /// A narrow RF column can independently bind spaced DB fragments even
    /// when each fragment is already a private detector owner. Keep those
    /// owners and add one ordinary grouped read; existing recognition checks
    /// still decide whether that complete-column read may replace its parts.
    static func includingSourceAlignedColumns(_ plan:Plan,layout:NativeRFDETRLayoutResult?,
        frame:NativeOCRRGBAFrame,independentColumns:(()->[[CGPoint]])? = nil)->Plan {
        guard refinesEndpointInk,sourceAlignedColumnsEnabled,
              let layout,layout.sourceWidth == frame.width,layout.sourceHeight == frame.height else { return plan }
        var boxes=plan.boxes,groups=plan.groups,supported=plan.supported,strong=plan.stronglySupported
        var used=Set(groups.flatMap { $0.members+[$0.index] })
        let peers=endpointFontPeerPolygons(plan.boxes)
        var styles:[Int:EndpointInkStyle]=[:],measured=Set<Int>()
        func style(_ index:Int)->EndpointInkStyle? {
            if measured.insert(index).inserted {
                styles[index]=endpointInkStyle(box:plan.boxes[index],frame:frame,candidatePeerPolygons:peers)
            }
            return styles[index]
        }
        var sourceSupport:[Int:Bool]=[:]
        var sourceColumns:[[CGPoint]]?
        func hasCompleteSourceColumn(_ polygon:[CGPoint])->Bool {
            guard let independentColumns else {return false}
            if sourceColumns==nil {sourceColumns=independentColumns()}
            return sourceColumns!.contains { sourceColumnDominatesGroup(polygon,column:$0) }
        }
        func observedSource(_ index:Int)->Bool {
            if let result=sourceSupport[index] {return result}
            guard let e=plan.boxes[index].detectorSeedEvidence,e.isValid,
                  e.ownershipVersion==2,e.completeCCScan==true,
                  e.sourceWidth==frame.width,e.sourceHeight==frame.height else {
                sourceSupport[index]=false;return false
            }
            // A connected printed column may be shared by two disjoint DB
            // crops. Count its actual cells inside this source window without
            // reassigning that component to either detector owner.
            let components=e.components+(e.ambiguousComponents ?? [])+(e.candidateComponents ?? []).map(\.component)
            let sx=CGFloat(frame.width)/CGFloat(e.mapFullWidth),sy=CGFloat(frame.height)/CGFloat(e.mapFullHeight)
            var cells=Set<Int>()
            for component in components {for run in component.runs {for x in run.x..<(run.x+run.count) {
                let point=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                if NativeOCRDirectionGeometry.contains(plan.boxes[index].polygon,point) {
                    cells.insert(run.y*e.mapFullWidth+x)
                    if cells.count>=12 {sourceSupport[index]=true;return true}
                }
            }}}
            sourceSupport[index]=false;return false
        }
        let scopes=layout.primitives.filter { $0.semanticClass == .text && $0.confidence >= 0.25 }
            .sorted { a,b in a.confidence == b.confidence ? a.queryID < b.queryID:a.confidence > b.confidence }
        for scope in scopes {
            let support=NativeOCRDirectionAdapters.support(scope)
            for anchor in plan.boxes.indices where !used.contains(anchor) {
                guard boxes.count < 256,plan.boxes[anchor].score >= 0.8,
                      let f=EndpointFrame(plan.boxes[anchor].polygon),f.rect.width >= 6,
                      f.rect.height >= f.rect.width*1.2 else { continue }
                let rf=f.bounds(support),a=f.rect,overlap=rf.intersection(a)
                guard !overlap.isNull,overlap.width >= a.width*0.85,overlap.height >= a.height*0.85 else { continue }
                let narrowRF=rf.width >= a.width*0.8 && rf.width <= a.width*1.8 &&
                    abs(rf.midX-a.midX) <= a.width*0.25
                // A paragraph RF enclosure need not itself be one glyph wide.
                // Its actual source fragments must resolve one coherent lane;
                // broader scopes retain a shorter inter-fragment gap budget.
                let sourceLane=scope.confidence>=0.5 && observedSource(anchor)
                guard narrowRF || sourceLane else {continue}
                let lane=plan.boxes.indices.filter { i in
                    guard !used.contains(i),plan.boxes[i].score >= 0.8,
                          let e=plan.boxes[i].detectorSeedEvidence,e.isValid,
                          !e.components.isEmpty || (sourceLane && observedSource(i)),
                          e.sourceWidth == frame.width,e.sourceHeight == frame.height,
                          let own=EndpointFrame(plan.boxes[i].polygon),
                          abs(own.along.x*f.along.x+own.along.y*f.along.y) >= 0.98 else { return false }
                    let r=f.bounds(plan.boxes[i].polygon),covered=r.intersection(rf)
                    return r.height >= r.width*1.2 && max(r.width,a.width) <= min(r.width,a.width)*1.5 &&
                        abs(r.midX-a.midX) <= min(r.width,a.width)*0.25 && !covered.isNull &&
                        covered.width*covered.height >= r.width*r.height*0.85
                }.sorted { f.bounds(plan.boxes[$0].polygon).minY < f.bounds(plan.boxes[$1].polygon).minY }
                guard (2...8).contains(lane.count),lane.contains(anchor),
                      let ink=style(anchor),lane.allSatisfy({ i in
                          guard let other=style(i) else { return false }
                          return ink.colors.contains { a in other.colors.contains { b in
                              a.count == 3 && b.count == 3 && zip(a,b).map { abs($0-$1) }.max()! <= 40
                          } }
                      }) else { continue }
                let rects=lane.map { f.bounds(plan.boxes[$0].polygon) }
                var contactProofs:[Int:Bool]=[:],usesContact=false
                func contact(_ pair:Int)->Bool {
                    if let proof=contactProofs[pair] {return proof}
                    let proof=confirmedEndpointContinuation(plan.boxes[lane[pair]],
                        peer:plan.boxes[lane[pair+1]],scope:scope)
                    contactProofs[pair]=proof;return proof
                }
                guard zip(rects,rects.dropFirst()).enumerated().allSatisfy({ pair,entry in
                    let (a,b)=entry
                    let gap=b.minY-a.maxY,width=max(a.width,b.width)
                    if gap >= -min(a.width,b.width)*0.1 && gap <= width*(narrowRF ? 3:1.2) {return true}
                    // Quad padding can overlap while reciprocal, mostly
                    // exclusive original components remain consecutive ink.
                    guard gap<0,contact(pair) else {return false}
                    usesContact=true;return true
                }) else { continue }
                let bounds=rects.reduce(CGRect.null) { $0.union($1) }
                let completeContact = !narrowRF && bounds.height < rf.height*0.8 &&
                    (0..<(lane.count-1)).allSatisfy(contact)
                // A closed source continuation defines this column's own
                // span; neighboring columns may make the RF paragraph taller.
                guard (bounds.height >= rf.height*0.8 || completeContact),bounds.height <= rf.height*1.15,
                      layout.primitives.filter({$0.semanticClass == .soundEffect && $0.confidence >= 0.5}).allSatisfy({ effect in
                          NativeOCRDirectionGeometry.intersectionArea(corners(bounds).map(f.restore),
                              NativeOCRDirectionAdapters.support(effect)) < bounds.width*bounds.height*0.1
                      }) else { continue }
                let evidence=lane.compactMap { plan.boxes[$0].detectorSeedEvidence }
                guard evidence.count == lane.count else { continue }
                let polygon=corners(bounds).map(f.restore)
                // A source-proven prefix must not become a competing whole
                // column when an independent longer ink read already covers
                // it. Keep that established read and its detector fragments.
                if (usesContact || completeContact),hasCompleteSourceColumn(polygon) {continue}
                let index=boxes.count
                boxes.append(.init(polygon:polygon,score:lane.map { plan.boxes[$0].score }.min()!))
                groups.append(.init(index:index,members:lane,evidence:evidence,
                    sourcePixelLane:usesContact || completeContact || !narrowRF ||
                        lane.contains { plan.boxes[$0].detectorSeedEvidence?.components.isEmpty == true }))
                supported.insert(index);strong.insert(index);used.formUnion(lane);used.insert(index)
            }
        }
        return .init(boxes:boxes,supported:supported,stronglySupported:strong,groups:groups,refinedCrops:plan.refinedCrops)
    }

    static func sourceColumnDominatesGroup(_ polygon:[CGPoint],column:[CGPoint])->Bool {
        guard let group=EndpointFrame(polygon),let source=EndpointFrame(column),
              abs(group.along.x*source.along.x+group.along.y*source.along.y)>=0.98 else {return false}
        let r=group.rect,c=source.rect
        guard c.width>=r.width*0.5,c.width<=r.width*1.5,
              c.height>=r.height*1.25,c.height>=r.height+r.width else {return false}
        return NativeOCRDirectionGeometry.intersectionArea(polygon,column) >=
            NativeOCRDirectionGeometry.area(polygon)*0.85
    }

    /// A first member's short width edge can carry raster skew into a much
    /// longer synthetic read. An independently measured pixel column may
    /// resolve that axis only if the original member centers corroborate it.
    static func sourceConsistentGroupAxis(_ polygon:[CGPoint],members:[[CGPoint]],
        columns:[[CGPoint]],uncertainty:CGFloat)->[CGPoint]? {
        guard members.count>=2,let original=EndpointFrame(polygon) else {return nil}
        let centers=members.compactMap { q -> CGPoint? in
            guard q.count==4 else {return nil}
            return CGPoint(x:q.reduce(0){$0+$1.x}/4,y:q.reduce(0){$0+$1.y}/4)
        }
        guard centers.count==members.count else {return nil}
        func spread(_ f:EndpointFrame)->CGFloat {
            let values=centers.map {f.project($0).x}
            return values.max()!-values.min()!
        }
        let oldSpread=spread(original),r=original.rect
        guard oldSpread>uncertainty else {return nil}
        var best:[CGPoint]?,bestSpread=oldSpread
        for column in columns {
            guard let measured=EndpointFrame(column),
                  measured.rect.width>=r.width*0.5,measured.rect.width<=r.width*1.5,
                  measured.rect.height>=r.height*0.85,measured.rect.height<=r.height*1.2 else {continue}
            let delta=atan2(uncertainty,min(r.height,measured.rect.height))
            let dot=original.along.x*measured.along.x+original.along.y*measured.along.y
            guard abs(dot)<cos(delta),abs(dot)>=0.98,
                  NativeOCRDirectionGeometry.intersectionArea(polygon,column) >=
                    min(NativeOCRDirectionGeometry.area(polygon),NativeOCRDirectionGeometry.area(column))*0.85 else {continue}
            let proposedSpread=spread(measured)
            guard proposedSpread+uncertainty<oldSpread,proposedSpread<bestSpread else {continue}
            best=dot<0 ? [column[2],column[3],column[0],column[1]]:column
            bestSpread=proposedSpread
        }
        return best
    }

    static func reconcilingSourceGroupAxes(_ polygons:[[CGPoint]],indices:[Int],groups:[Group],
        boxes:[NativeCoreMLDetectionBox],layout:NativeRFDETRLayoutResult?,frame:NativeOCRRGBAFrame,
        probability:NativeMainEnsembleOCRProbability.Sample?,cancellationCheck:() throws -> Void = {}) throws -> [[CGPoint]] {
        guard polygons.count==indices.count,let map=probability else {return polygons}
        let selected=groups.filter(\.sourcePixelLane),groupIndices=Set(selected.map(\.index))
        guard !groupIndices.isEmpty else {return polygons}
        // A tentative union is not an owner of a more precise pixel column.
        // Measure the independent candidates without those synthetic reads.
        let existing=zip(indices,polygons).filter{!groupIndices.contains($0.0)}.map(\.1)
        let columns=try sourceInkColumns(boxes:boxes,existing:existing,layout:layout,frame:frame,
            probability:map,cancellationCheck:cancellationCheck).map(\.polygon)
        let uncertainty=max(2,ceil(max(CGFloat(frame.width)/CGFloat(map.width),
            CGFloat(frame.height)/CGFloat(map.height)))+1)
        var result=polygons
        for group in selected {
            guard let position=indices.firstIndex(of:group.index),
                  group.members.allSatisfy({indices.contains($0)}) else {continue}
            let members=group.members.compactMap { index in indices.firstIndex(of:index).map{polygons[$0]} }
            if let measured=sourceConsistentGroupAxis(polygons[position],members:members,
                columns:columns,uncertainty:uncertainty) {result[position]=measured}
        }
        return result
    }

    /// A small parallel side column next to a separately detected full-size
    /// word is annotation-sized. This uses only local geometry, at every angle.
    static func sourceInkSideAnnotation(_ polygon:[CGPoint],boxes:[NativeCoreMLDetectionBox],useOwnFontWidth:Bool=false,
        rfWitness:Bool=false)->Bool {
        guard let f=EndpointFrame(polygon) else {return false}
        let r=f.rect
        let owner=boxes.first { box in
            guard box.score>=0.6,let own=EndpointFrame(box.polygon),
                  own.rect.height>=own.rect.width*(rfWitness ? 1.2:3),
                  abs(own.along.x*f.along.x+own.along.y*f.along.y)>=0.98 else {return false}
            let peer=f.bounds(box.polygon),overlap=max(0,min(peer.maxY,r.maxY)-max(peer.minY,r.minY))
            let gap=max(0,peer.minX-r.maxX,r.minX-peer.maxX)
            // Projecting a long, tilted word into the candidate axis adds its
            // length to the apparent width. That is not a larger glyph size.
            let fontWidth=useOwnFontWidth ? min(peer.width,own.rect.width):peer.width
            if rfWitness {
                return fontWidth>=r.width*1.8 && overlap>=r.height*0.75 && r.height<=peer.height*0.85 &&
                    abs(r.midX-peer.midX)>=fontWidth*0.2 && gap<=fontWidth*0.55
            }
            return fontWidth>=r.width*1.8 && fontWidth<=r.width*4 &&
                overlap>=r.height*0.75 && r.height<=peer.height*1.25 &&
                abs(r.midX-peer.midX)>=peer.width*0.35 && gap<=peer.width*0.55
        }
        if let owner,ProcessInfo.processInfo.environment["AIDOKU_OCR_INK_WIDTH_AUDIT"] == "1" {
            let fields:[String:Any] = ["candidate":polygon.map{[Double($0.x),Double($0.y)]},
                "body":owner.polygon.map{[Double($0.x),Double($0.y)]}]
            if let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]) {
                FileHandle.standardError.write(Data("ocr_ink_annotation ".utf8)+data+Data([10]))
            }
        }
        return owner != nil
    }

    /// The map locates a column, but a weak final dot is still real source ink.
    /// Only closed, nearby source-colour runs can extend its measured crop;
    /// open rules/backgrounds and remote marks cannot supply an endpoint.
    static func sourceInkColumnCaps(_ polygon:[CGPoint],colour:SIMD3<Int>,frame:NativeOCRRGBAFrame,
        normalLimits:[CGPoint] = [],probability:NativeMainEnsembleOCRProbability.Sample? = nil)->[CGPoint] {
        guard let f=EndpointFrame(polygon),f.rect.width>=6 else {return polygon}
        let r=f.rect,width=r.width,margin=width*0.45
        let limits=normalLimits.isEmpty ? r.insetBy(dx:-margin,dy:0):f.bounds(normalLimits)
        let left=max(r.minX-margin,min(r.minX,limits.minX)),right=min(r.maxX+margin,max(r.maxX,limits.maxX))
        let start=floor(r.minY-width*2.5),end=ceil(r.maxY+width*2.5)
        let columns=Int(ceil(right-left)),rows=Int(end-start)
        guard columns>0,rows>0,columns<=262_144/rows else {return polygon}
        var ink=[UInt8](repeating:0,count:columns*rows)
        for y in 0..<rows {for x in 0..<columns {
            let p=f.restore(.init(x:left+CGFloat(x)+0.5,y:start+CGFloat(y)+0.5))
            guard p.x>=0,p.y>=0,p.x<CGFloat(frame.width),p.y<CGFloat(frame.height) else {continue}
            let i=Int(p.y)*frame.bytesPerRow+Int(p.x)*4
            if max(abs(Int(frame.bytes[i])-colour.x),abs(Int(frame.bytes[i+1])-colour.y),
                   abs(Int(frame.bytes[i+2])-colour.z))<=20 {ink[y*columns+x]=1}
        }}
        var marks:[(rect:CGRect,roots:Int,strongRoots:Int,pixels:Int)]=[],queue:[Int]=[]
        for seed in ink.indices where ink[seed] != 0 {
            queue.removeAll(keepingCapacity:true);queue.append(seed);ink[seed]=0
            var cursor=0,x0=columns,y0=rows,x1=0,y1=0,open=false,roots=0,strongRoots=0
            while cursor<queue.count {
                let p=queue[cursor];cursor+=1;let x=p%columns,y=p/columns
                x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                let local=CGPoint(x:left+CGFloat(x)+0.5,y:start+CGFloat(y)+0.5)
                if r.contains(local),let map=probability,map.sourceWidth==frame.width,map.sourceHeight==frame.height,
                   map.width>0,map.height>0,map.values.count==map.width*map.height {
                    let world=f.restore(local)
                    let mx=min(map.width-1,max(0,Int(world.x*CGFloat(map.width)/CGFloat(frame.width))))
                    let my=min(map.height-1,max(0,Int(world.y*CGFloat(map.height)/CGFloat(frame.height))))
                    if map.values[my*map.width+mx]>=0.15 {roots+=1}
                    if map.values[my*map.width+mx]>=0.5 {strongRoots+=1}
                }
                if x==0 || x==columns-1 || y==0 || y==rows-1 {open=true}
                for dy in -1...1 {for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx=x+dx,yy=y+dy
                    if xx>=0,xx<columns,yy>=0,yy<rows,ink[yy*columns+xx] != 0 {
                        ink[yy*columns+xx]=0;queue.append(yy*columns+xx)
                    }
                }}
            }
            let m=CGRect(x:left+CGFloat(x0),y:start+CGFloat(y0),width:CGFloat(x1-x0+1),height:CGFloat(y1-y0+1))
            guard !open,queue.count>=2,m.width<=width*1.4,m.height<=width*1.7,
                  CGFloat(queue.count)>=m.width*m.height*0.12 else {continue}
            marks.append((m,roots,strongRoots,queue.count))
        }
        // A detector-missed end can be a narrow closed stroke followed by
        // a final point. Three regular source-colour points, rooted in the
        // retained column, establish its print scale without decoding text.
        // A lone stroke, remote texture or open rule cannot supply this proof.
        func roundPoint(_ i:Int)->Bool {
            let m=marks[i].rect
            return m.width>=2 && m.height>=2 && m.width<=width*0.4 && m.height<=width*0.4 &&
                m.height>=m.width*0.5 && m.height<=m.width*2 &&
                abs(m.midX-r.midX)<=width*0.3 && CGFloat(marks[i].pixels)>=m.width*m.height*0.5
        }
        let points=marks.indices.filter(roundPoint)
        var periodicCaps=Set<Int>()
        for i in marks.indices where !roundPoint(i) {
            let stem=marks[i].rect
            guard stem.width<=width*0.35,stem.height>=width*0.4,stem.height<=width*1.4,
                  stem.height>=stem.width*2.5,abs(stem.midX-r.midX)<=width*0.3,
                  CGFloat(marks[i].pixels)>=stem.width*stem.height*0.35 else {continue}
            for direction in [CGFloat(-1),CGFloat(1)] {
                let inner=points.filter { direction*(marks[$0].rect.midY-stem.midY)<0 &&
                    abs(marks[$0].rect.midX-stem.midX)<=width*0.15 }
                    .sorted { direction*marks[$0].rect.midY>direction*marks[$1].rect.midY }
                guard inner.count>=3 else {continue}
                var train=Array(inner.prefix(3))
                let a=marks[train[0]].rect,b=marks[train[1]].rect,c=marks[train[2]].rect
                let pitch=abs(a.midY-b.midY),otherPitch=abs(b.midY-c.midY)
                let diameter=max(a.width,a.height,b.width,b.height,c.width,c.height)
                let gap=direction>0 ? stem.minY-a.maxY:a.minY-stem.maxY
                guard pitch>=diameter*1.2,pitch<=width*0.8,abs(otherPitch-pitch)<=pitch*0.25,
                      diameter<=min(a.width,a.height,b.width,b.height,c.width,c.height)*2,
                      gap>=0,gap<=pitch*1.2,stem.width<=diameter*2 else {continue}
                // The last few points can all lie beyond the map endpoint.
                // Follow the same uninterrupted measured pitch back to the
                // retained source; never skip a missing/irregular interval.
                for j in inner.dropFirst(3) {
                    let m=marks[j].rect,previous=marks[train.last!].rect
                    guard abs(abs(m.midY-previous.midY)-pitch)<=pitch*0.25,
                          max(m.width,m.height)<=diameter*2,min(m.width,m.height)>=diameter*0.5 else {break}
                    train.append(j)
                }
                guard train.contains(where:{r.contains(CGPoint(x:marks[$0].rect.midX,y:marks[$0].rect.midY))}) else {continue}
                if let cap=points.first(where:{ j in
                    let m=marks[j].rect,d=direction>0 ? m.minY-stem.maxY:stem.minY-m.maxY
                    return d>=0 && d<=pitch*1.2 && abs(m.midX-stem.midX)<=diameter &&
                        max(m.width,m.height)<=diameter*2 && min(m.width,m.height)>=diameter*0.5
                }) {periodicCaps.insert(i);periodicCaps.insert(cap)}
            }
        }
        if ProcessInfo.processInfo.environment["AIDOKU_OCR_INK_WIDTH_AUDIT"] == "1" {
            let fields:[String:Any] = ["source":polygon.map{[Double($0.x),Double($0.y)]},
                "colour":[colour.x,colour.y,colour.z],"width":Double(width),
                "bounds":[Double(r.minX),Double(r.minY),Double(r.maxX),Double(r.maxY)],
                "marks":marks.enumerated().map { i,m in ["index":i,"bounds":[Double(m.rect.minX),Double(m.rect.minY),Double(m.rect.maxX),Double(m.rect.maxY)],
                    "pixels":m.pixels,"round":roundPoint(i),"periodicCap":periodicCaps.contains(i)] as [String:Any] }]
            if let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]) {
                FileHandle.standardError.write(Data("ocr_ink_caps ".utf8)+data+Data([10]))
            }
        }
        var extent=r,observed=CGRect.null,used=Set<Int>(),changed=true
        while changed {
            changed=false
            for i in marks.indices where !used.contains(i) {
                let m=marks[i].rect,dy=max(0,extent.minY-m.maxY,m.minY-extent.maxY)
                let dx=max(0,extent.minX-m.maxX,m.minX-extent.maxX)
                // Closed detached accents/dots share the source column's
                // actual print scale. Neighbor columns stay beyond their
                // measured midpoint, never borrowed as blank crop padding.
                guard dx<=width*0.45,dy<=width*0.65 else {continue}
                if m.minY<r.minY || m.maxY>r.maxY {
                    // Off-centre filled dots can finish a skewed word. Hollow
                    // accents and neighbouring glyph contours need the stricter
                    // central alignment used by ordinary terminal marks.
                    let filledDot=m.midX>=r.minX && m.midX<=r.maxX &&
                        min(m.width,m.height)>=max(3,width*0.12) &&
                        m.width<=width*0.35 && m.height<=width*0.35 &&
                        m.height>=m.width*0.7 && m.height<=m.width*1.4 &&
                        CGFloat(marks[i].pixels)>=m.width*m.height*0.6
                    let dot=m.width<=width*0.5 && m.height<=width*0.5 &&
                        m.height>=m.width*0.5 && m.height<=m.width*2 &&
                        CGFloat(marks[i].pixels)>=m.width*m.height*0.3 &&
                        (abs(m.midX-r.midX)<=width*0.3 || filledDot)
                    // A strongly rooted partial glyph can leave most of its
                    // closed contour outside the initial crop. Include the
                    // complete glyph, bounded to one measured print width.
                    let terminalReach:CGFloat=marks[i].strongRoots>=8 ? 1:0.65
                    let rooted=marks[i].roots>=2 && m.minY>=r.minY-width*terminalReach && m.maxY<=r.maxY+width*terminalReach
                    guard rooted || dot || periodicCaps.contains(i) else {continue}
                }
                extent=extent.union(m);observed=observed.union(m);used.insert(i);changed=true
            }
        }
        guard !used.isEmpty else {return polygon}
        let padding=max(2,width*0.08)
        let bounded=CGRect(x:max(left,min(r.minX,observed.minX-padding)),
            y:min(r.minY,observed.minY-padding),
            width:0,height:0)
        let final=CGRect(x:bounded.minX,y:bounded.minY,
            width:min(right,max(r.maxX,observed.maxX+padding))-bounded.minX,
            height:max(r.maxY,observed.maxY+padding)-bounded.minY)
        let result=corners(final).map(f.restore)
        return result.allSatisfy({$0.x>=0 && $0.y>=0 && $0.x<=CGFloat(frame.width) && $0.y<=CGFloat(frame.height)}) ? result:polygon
    }

    /// Source-pixel lane proposals. Both RF and detector frames
    /// are evidence; neither labels nor decoded text participate in this path.
    static var sourceInkAnnotationBandsEnabled: Bool {
        if let override=ProcessInfo.processInfo.environment["AIDOKU_OCR_INK_ANNOTATION_BANDS"] {
            return override == "1"
        }
        return mainMangaEndpointPolicy
    }

    static var sourceInkPartitionsEnabled: Bool {
        if let override=ProcessInfo.processInfo.environment["AIDOKU_OCR_SOURCE_INK_PARTITIONS"] {
            return override == "1"
        }
        return mainMangaEndpointPolicy
    }

    static var sourceInkColumnsEnabled: Bool {
        if let override=ProcessInfo.processInfo.environment["AIDOKU_OCR_SOURCE_INK_COLUMNS"] {
            return override == "1"
        }
        return mainMangaEndpointPolicy
    }

    static func sourceInkColumns(boxes: [NativeCoreMLDetectionBox], existing originalExisting: [[CGPoint]],
        layout: NativeRFDETRLayoutResult?, frame: NativeOCRRGBAFrame,
        probability: NativeMainEnsembleOCRProbability.Sample?,
        partitionsEnabled:Bool? = nil,cancellationCheck: () throws -> Void = {}) throws -> [NativeCoreMLDetectionBox] {
        guard sourceInkColumnsEnabled,let layout,let map=probability,
              layout.sourceWidth==frame.width,layout.sourceHeight==frame.height,
              map.sourceWidth==frame.width,map.sourceHeight==frame.height,
              map.width>0,map.height>0,map.width==map.resizedWidth,map.height==map.resizedHeight,
              map.region==CGRect(x:0,y:0,width:map.width,height:map.height),
              map.values.count==map.width*map.height,frame.bytesPerRow>=frame.width*4,
              frame.bytes.count>=frame.bytesPerRow*frame.height else { return [] }
        let texts=layout.primitives.filter { $0.semanticClass == .text && $0.confidence>=0.55 }
        let fragmentScopes=layout.primitives.filter { $0.semanticClass == .text && $0.confidence>=0.25 }
        let effects=layout.primitives.filter { $0.semanticClass == .soundEffect && $0.confidence>=0.5 }
        guard !texts.isEmpty || !fragmentScopes.isEmpty else { return [] }
        let flexible=partitionsEnabled ?? sourceInkPartitionsEnabled
        let traceInk=ProcessInfo.processInfo.environment["AIDOKU_OCR_INK_WIDTH_AUDIT"] == "1"
        func trace(_ stage:String,_ fields:[String:Any]) {
            guard traceInk,let data=try? JSONSerialization.data(withJSONObject:["stage":stage,"value":fields],options:[.sortedKeys]) else {return}
            FileHandle.standardError.write(Data("ocr_ink_trace ".utf8)+data+Data([10]))
        }
        typealias ExclusiveRoots = (points:[CGPoint],seeds:Set<Int>)
        var exclusiveCache:[String:ExclusiveRoots]=[:],candidatePeers:[String:[[CGPoint]]]?=nil
        // Only observed cells outside every recorded competitor may support
        // the new crop. Detector component ownership is never reassigned.
        func exclusiveRoots(_ box:NativeCoreMLDetectionBox)->ExclusiveRoots {
            let empty:ExclusiveRoots=([],[])
            guard let e=box.detectorSeedEvidence,let candidates=e.candidateComponents,!candidates.isEmpty,
                  e.isValid,e.sourceWidth==frame.width,e.sourceHeight==frame.height,
                  e.mapFullWidth==map.width,e.mapFullHeight==map.height else {return empty}
            if let cached=exclusiveCache[e.ownerID] {return cached}
            if candidatePeers==nil {candidatePeers=endpointFontPeerPolygons(boxes)}
            let peers=candidatePeers!,sx=CGFloat(frame.width)/CGFloat(map.width),sy=CGFloat(frame.height)/CGFloat(map.height)
            var points:[CGPoint]=[],seeds=Set<Int>()
            for candidate in candidates {
                guard candidate.component.pixelCount>=8,
                      candidate.competingOwnerIDs.allSatisfy({!(peers[$0]?.isEmpty ?? true)}) else {continue}
                let excluded=candidate.competingOwnerIDs.flatMap{peers[$0] ?? []}
                var measured:[CGPoint]=[]
                for run in candidate.component.runs {for x in run.x..<(run.x+run.count) {
                    let p=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                    if NativeOCRDirectionGeometry.contains(box.polygon,p),
                       !excluded.contains(where:{NativeOCRDirectionGeometry.contains($0,p)}) {measured.append(p)}
                }}
                guard measured.count>=8 else {continue}
                points+=measured;seeds.insert(candidate.component.seed)
            }
            let result:ExclusiveRoots=(points,seeds);exclusiveCache[e.ownerID]=result;return result
        }
        // DB's measured high-probability cells certify the text; the RGB stroke
        // is a geometric support mask, not the detector's confidence target.
        func columnSupportScore(_ polygon:[CGPoint],allowExclusive:Bool,minimumScore:Double=0.6)->Double? {
            guard let f=EndpointFrame(polygon) else {return nil}
            let bound=f.rect
            var owners=Set<String>(),seeds=Set<Int>(),scores:[Double]=[],rootPixels=0,exclusiveOwners:[String]=[]
            for box in boxes where box.score>=minimumScore {
                guard let evidence=box.detectorSeedEvidence,evidence.isValid,
                      evidence.sourceWidth==frame.width,evidence.sourceHeight==frame.height,
                      evidence.mapFullWidth==map.width,evidence.mapFullHeight==map.height,
                      !owners.contains(evidence.ownerID),let own=EndpointFrame(box.polygon) else {continue}
                let extra=allowExclusive ? exclusiveRoots(box):(points:[],seeds:Set<Int>())
                guard !evidence.components.isEmpty || !extra.points.isEmpty,seeds.isDisjoint(with:extra.seeds) else {continue}
                let r=f.bounds(box.polygon)
                guard (own.rect.height<own.rect.width*1.8 || abs(own.along.x*f.along.x+own.along.y*f.along.y)>=0.98),
                      bound.width<=r.width*2.5+0.000001,bound.width+0.000001>=r.width*0.5,
                      abs(bound.midX-r.midX)<=min(bound.width,r.width)*0.35+0.000001,
                      evidence.components.allSatisfy({!seeds.contains($0.seed)}) else {continue}
                let sx=CGFloat(frame.width)/CGFloat(map.width),sy=CGFloat(frame.height)/CGFloat(map.height)
                var covered=0,total=0
                for component in evidence.components {
                    total+=component.pixelCount
                    for run in component.runs {for x in run.x..<(run.x+run.count) {
                        let p=f.project(.init(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy))
                        if bound.contains(p) {covered+=1}
                    }}
                }
                total+=extra.points.count
                covered+=extra.points.filter{bound.contains(f.project($0))}.count
                guard covered>=3,covered*2>=total else {continue}
                owners.insert(evidence.ownerID);seeds.formUnion(evidence.components.map(\.seed))
                seeds.formUnion(extra.seeds)
                if !extra.points.isEmpty {exclusiveOwners.append(evidence.ownerID)}
                scores.append(box.score);rootPixels+=covered
            }
            guard owners.count>=2,rootPixels>=12,let score=scores.min() else {return nil}
            if minimumScore<0.5 {
                guard scores.max()!>=0.8,scores.reduce(0,+)/Double(scores.count)>=0.65 else {return nil}
            }
            if traceInk {trace(allowExclusive ? "exclusive-score":"private-score",["candidate":polygon.map{[Double($0.x),Double($0.y)]},
                "owners":owners.sorted(),"exclusiveOwners":exclusiveOwners,"rootPixels":rootPixels,"score":score])}
            return score
        }
        // Keep already validated source columns as independent model evidence.
        // The broader partition search can only contribute genuinely new ink.
        let preserved=flexible ? try sourceInkColumns(boxes:boxes,existing:originalExisting,
            layout:layout,frame:frame,probability:map,partitionsEnabled:false,
            cancellationCheck:cancellationCheck):[]
        let existing=originalExisting+preserved.map(\.polygon)
        typealias Source = (basis:EndpointFrame,rect:CGRect,nominal:CGFloat?,minimum:Int,maximum:Int,single:Bool,
                           scope:[CGPoint]?,witness:CGRect?,closedNormal:Bool,exclusive:Bool,bridge:Bool,measured:Bool,rootLane:Bool,lightStroke:Bool,rfWitness:Bool)
        // Several independently measured centres can correct the skew of a
        // short anchor. Its own detector axis still bounds the allowed change.
        func compactFrame(_ initial:EndpointFrame,scope:NativeRFDETRLayoutPrimitive,allowExclusive:Bool=false,
                          minimumScore:Double=0.6)->EndpointFrame {
            let a=initial.rect
            var nearbyRects:[CGRect]=[],nearbyWidths:[CGFloat]=[]
            var nearby=boxes.compactMap { box -> CGPoint? in
                guard box.score>=minimumScore,let evidence=box.detectorSeedEvidence,evidence.isValid,
                      (!evidence.components.isEmpty || (allowExclusive && exclusiveRoots(box).points.count>=8)),
                      NativeOCRDirectionAdapters.coverage(box.polygon,by:scope)>=0.8,
                      let own=EndpointFrame(box.polygon),abs(own.along.x*initial.along.x+own.along.y*initial.along.y)>=0.98 else {return nil}
                let r=initial.bounds(box.polygon)
                let tolerance=min(r.width,a.width)*(allowExclusive ? 0.5:0.35)+(allowExclusive ? 0:abs(r.midY-a.midY)*0.2)
                guard max(r.width,a.width)<=min(r.width,a.width)*2.5,
                      abs(r.midX-a.midX)<=tolerance else {return nil}
                nearbyRects.append(r)
                nearbyWidths.append(own.rect.width)
                return box.polygon.reduce(CGPoint.zero){CGPoint(x:$0.x+$1.x/CGFloat(box.polygon.count),y:$0.y+$1.y/CGFloat(box.polygon.count))}
            }
            guard nearby.count>=(allowExclusive ? 2:3) else {return initial}
            if nearby.count==2 {
                let pair=nearbyRects.sorted{$0.minY<$1.minY},gap=pair[1].minY-pair[0].maxY
                guard gap>=min(pair[0].width,pair[1].width)*(-0.75),
                      gap<=max(pair[0].width,pair[1].width)*0.6,
                      max(pair[0].width,pair[1].width)<=min(pair[0].width,pair[1].width)*1.8 else {return initial}
            }
            if nearby.count>=3 {
                // Along-distance tolerance gathers possible skew corrections,
                // but can also reach another column. Fit only a consensus
                // through this anchor, prioritizing its measured normal lane.
                let origin=initial.restore(CGPoint(x:a.midX,y:a.midY))
                let core=nearby.indices.filter { i in
                    abs(initial.project(nearby[i]).x-a.midX)<=min(a.width,nearbyWidths[i])*0.35
                }
                var directions=[initial.along]
                for i in nearby.indices {
                    let dx=nearby[i].x-origin.x,dy=nearby[i].y-origin.y,length=hypot(dx,dy)
                    if length>=max(a.width,nearbyWidths[i])*1.5 {
                        let v=CGPoint(x:dx/length,y:dy/length)
                        if abs(v.x*initial.along.x+v.y*initial.along.y)>=0.98 {directions.append(v)}
                    }
                }
                var selected:[Int]=[],bestCore = -1,bestCost=Double.infinity
                for v in directions {
                    let n=CGPoint(x:v.y,y:-v.x)
                    let residuals=nearby.indices.map { i in
                        abs((nearby[i].x-origin.x)*n.x+(nearby[i].y-origin.y)*n.y)/max(1,min(a.width,nearbyWidths[i]))
                    }
                    let members=nearby.indices.filter{residuals[$0]<=0.35}
                    guard members.count>=3 else {continue}
                    let coreCount=core.filter{members.contains($0)}.count
                    let cost=members.reduce(0.0){$0+Double(residuals[$1]*residuals[$1])}/Double(members.count)
                    if coreCount>bestCore || (coreCount==bestCore &&
                        (members.count>selected.count || (members.count==selected.count && cost<bestCost))) {
                        selected=members;bestCore=coreCount;bestCost=cost
                    }
                }
                guard selected.count>=3 else {return initial}
                if selected.count<nearby.count,traceInk {trace("frameConsensus",[
                    "anchor":corners(a).map(initial.restore).map{[Double($0.x),Double($0.y)]},
                    "points":nearby.map{[Double($0.x),Double($0.y)]},"selected":selected,"core":core])}
                nearby=selected.map{nearby[$0]}
            }
            let center=nearby.reduce(CGPoint.zero){CGPoint(x:$0.x+$1.x/CGFloat(nearby.count),y:$0.y+$1.y/CGFloat(nearby.count))}
            var xx:CGFloat=0,yy:CGFloat=0,xy:CGFloat=0
            for p in nearby {let x=p.x-center.x,y=p.y-center.y;xx+=x*x;yy+=y*y;xy+=x*y}
            let delta=hypot(xx-yy,2*xy),major=(xx+yy+delta)/2,minor=(xx+yy-delta)/2
            guard major>=max(1,minor)*9 else {return initial}
            let angle=atan2(2*xy,xx-yy)/2,v=CGPoint(x:cos(angle),y:sin(angle)),n=CGPoint(x:v.y,y:-v.x)
            guard abs(v.x*initial.along.x+v.y*initial.along.y)>=0.98 else {return initial}
            let projected=corners(initial.rect).map(initial.restore).map {CGPoint(x:$0.x*n.x+$0.y*n.y,y:$0.x*v.x+$0.y*v.y)}
            let r=NativeOCRDirectionGeometry.bounds(projected)
            return EndpointFrame(corners(r).map{CGPoint(x:$0.x*n.x+$0.y*v.x,y:$0.x*n.y+$0.y*v.y)},
                trustedAlong:initial.trustedAlong) ?? initial
        }
        var sources:[Source]=[],rawSources:[Source]=[]
        for box in boxes where box.score>=0.5 {
            if let f=EndpointFrame(box.polygon),f.rect.width>=20,
               f.rect.height>=f.rect.width*(flexible ? 1.3:1.6),f.rect.height<=f.rect.width*2.8 {
                rawSources.append((f,f.rect,nil,2,4,false,nil,nil,false,false,false,false,false,false,false))
            }
        }
        for text in texts where text.confidence>=0.8 {
            var axes:[CGPoint]=[]
            for anchor in boxes where anchor.score>=0.6 {
                guard let f=EndpointFrame(anchor.polygon),f.rect.height>=f.rect.width*3,
                      NativeOCRDirectionAdapters.coverage(anchor.polygon,by:text)>=0.8,
                      !axes.contains(where:{abs($0.x*f.along.x+$0.y*f.along.y)>0.98}) else { continue }
                let r=f.bounds(NativeOCRDirectionAdapters.support(text)),w=f.rect.width
                guard r.width>=w*(flexible ? 0.8:2),r.width<=w*9,r.height>=w*3 else { continue }
                let single=flexible && r.width<w*1.8
                sources.append((f,r,w,single ? 1:2,8,single,nil,nil,false,false,false,false,false,false,false));axes.append(f.along)
            }
        }
        sources=flexible ? sources+rawSources:rawSources+sources
        if flexible {
            // A weak RF score alone cannot propose text. Independently owned,
            // aligned detector fragments must certify a complete local lane.
            // Process already supported tight scopes before broader searches,
            // so a loose alternative cannot replace a proven pixel envelope.
            for pass in [0,1,2,3,4,6,5,7,8,9] {
                let expanded=pass>0,compactAllowed=pass>=2,variableScale=pass==4,exclusiveStage=(5...7).contains(pass)
                let privateBridge=pass==9,measuredStage=pass==8 || pass==9,minimumScore=(pass==8 || pass==9) ? 0.5:0.6
                for scope in fragmentScopes where expanded || scope.confidence<0.8 {
                    let support=NativeOCRDirectionAdapters.support(scope)
                    var certified:[[CGPoint]]=[]
                    let anchors=boxes.filter{$0.score>=minimumScore}
                    let ordered=expanded ? anchors.sorted {
                        (EndpointFrame($0.polygon)?.rect.height ?? 0) > (EndpointFrame($1.polygon)?.rect.height ?? 0)
                    }:anchors
                    for anchor in ordered {
                        guard let initial=EndpointFrame(anchor.polygon),initial.rect.width>=6,
                              initial.rect.height>=initial.rect.width*1.8,
                              NativeOCRDirectionAdapters.coverage(anchor.polygon,by:scope)>=0.8 else {continue}
                        if compactAllowed,anchor.detectorSeedEvidence?.components.isEmpty != false,
                           !((exclusiveStage || privateBridge) && exclusiveRoots(anchor).points.count>=8) {continue}
                        let f:EndpointFrame
                        if pass==6 || measuredStage {
                            f=compactFrame(initial,scope:scope,allowExclusive:true,minimumScore:minimumScore)
                        }
                        else {f=(pass==3 && scope.confidence>=0.8) || variableScale ? compactFrame(initial,scope:scope):initial}
                        let a=f.rect,rf=f.bounds(support)
                        var peers=boxes.filter { box in
                            // Shared terminal ink is supporting evidence only;
                            // compact searches still require a private anchor.
                            guard box.score>=minimumScore,let evidence=box.detectorSeedEvidence,evidence.isValid,
                                  (!evidence.components.isEmpty || ((exclusiveStage || privateBridge) && exclusiveRoots(box).points.count>=8) ||
                                      (compactAllowed && scope.confidence>=0.8 &&
                                      (!(evidence.ambiguousComponents ?? []).isEmpty || !(evidence.candidateComponents ?? []).isEmpty))),
                                  let own=EndpointFrame(box.polygon) else {return false}
                            let compactPeer=compactAllowed && (scope.confidence>=0.8 || variableScale) && own.rect.height<=own.rect.width*1.8
                            guard compactPeer || abs(own.along.x*f.along.x+own.along.y*f.along.y)>=0.98 else {return false}
                            let r=f.bounds(box.polygon)
                            return r.height>=r.width*(compactPeer ? 0.7:1.2) &&
                                max(r.width,a.width)<=min(r.width,a.width)*(variableScale ? 2.5:(compactPeer ? 2:1.8)) &&
                                abs(r.midX-a.midX)<=min(r.width,a.width)*0.35 &&
                                NativeOCRDirectionAdapters.coverage(box.polygon,by:scope)>=0.8
                        }
                        if traceInk,variableScale || privateBridge {trace(privateBridge ? "privateBridgePeers":"scalePeers",["scope":scope.queryID,
                            "anchor":anchor.polygon.map{[Double($0.x),Double($0.y)]},
                            "basis":corners(f.rect).map(f.restore).map{[Double($0.x),Double($0.y)]},
                            "peers":peers.map{["score":$0.score,"polygon":$0.polygon.map{[Double($0.x),Double($0.y)]},
                                "privateComponents":$0.detectorSeedEvidence?.components.count ?? 0] as [String:Any]}])}
                        guard (2...8).contains(peers.count) else {continue}
                        var rects=peers.map{f.bounds($0.polygon)}.sorted{$0.minY<$1.minY}
                        guard zip(rects,rects.dropFirst()).allSatisfy({a,b in
                            b.minY-a.maxY >= -min(a.width,b.width)*0.75 &&
                                b.minY-a.maxY <= max(a.width,b.width)*((variableScale || privateBridge) ? 3.5:(expanded ? 1.5:3.5))
                        }) else {continue}
                        var bounds=rects.reduce(CGRect.null){$0.union($1)}
                        let initialBounds=bounds
                        if pass==7 {
                            // Follow model-supported tails beyond a partial RF
                            // text scope, without changing any seed ownership.
                            // Every containing balloon/frame remains a hard limit.
                            let containers=layout.primitives.filter { item in
                                guard item.confidence>=0.5,
                                      item.semanticClass == .balloon || item.semanticClass == .frame else {return false}
                                let polygon=corners(initialBounds).map(f.restore)
                                return NativeOCRDirectionAdapters.coverage(polygon,by:item)>=0.9
                            }
                            for _ in 0..<8 {
                                let next=boxes.filter { box in
                                    guard box.score>=0.8,box.detectorSeedEvidence?.isValid == true,
                                          !peers.contains(where:{$0.polygon==box.polygon}),let own=EndpointFrame(box.polygon),
                                          abs(own.along.x*f.along.x+own.along.y*f.along.y)>=0.98 else {return false}
                                    let r=f.bounds(box.polygon),font=min(r.width,a.width)
                                    let gap=max(0,r.minY-bounds.maxY,bounds.minY-r.maxY)
                                    return r.height>=r.width*1.2 && max(r.width,a.width)<=font*1.8 &&
                                        abs(r.midX-a.midX)<=font*0.35 && gap<=max(r.width,a.width)*0.8 &&
                                        (r.maxY>bounds.maxY+font*0.5 || r.minY<bounds.minY-font*0.5) &&
                                        containers.allSatisfy {NativeOCRDirectionAdapters.coverage(box.polygon,by:$0)>=0.9}
                                }.min { left,right in
                                    let l=f.bounds(left.polygon),r=f.bounds(right.polygon)
                                    return max(0,l.minY-bounds.maxY,bounds.minY-l.maxY)<max(0,r.minY-bounds.maxY,bounds.minY-r.maxY)
                                }
                                guard let next else {break}
                                peers.append(next);bounds=bounds.union(f.bounds(next.polygon))
                            }
                            guard bounds.height>initialBounds.height+a.width*0.5 else {continue}
                            rects=peers.map{f.bounds($0.polygon)}.sorted{$0.minY<$1.minY}
                        }
                        if exclusiveStage || privateBridge {
                            // A paragraph can extend below this particular
                            // column. New private bridges use their complete
                            // measured fragment span as the witness, rather
                            // than requiring most of the paragraph's height.
                            guard (privateBridge || bounds.height>=rf.height*0.75),
                                  privateBridge || peers.contains(where:{exclusiveRoots($0).points.count>=8}) else {continue}
                            // A truncated RF scope cannot certify a complete
                            // column while a strong adjacent detection continues it.
                            let continuation=boxes.contains { box in
                                guard box.score>=0.8,box.detectorSeedEvidence?.isValid == true,
                                      !peers.contains(where:{$0.polygon==box.polygon}),let own=EndpointFrame(box.polygon),
                                      abs(own.along.x*f.along.x+own.along.y*f.along.y)>=0.98 else {return false}
                                let r=f.bounds(box.polygon),font=min(r.width,a.width)
                                let gap=max(0,r.minY-bounds.maxY,bounds.minY-r.maxY)
                                return r.height>=r.width*1.2 && max(r.width,a.width)<=font*1.8 &&
                                    abs(r.midX-a.midX)<=font*0.35 && gap<=max(r.width,a.width)*0.8 &&
                                    (r.maxY>bounds.maxY+font*0.5 || r.minY<bounds.minY-font*0.5)
                            }
                            guard !continuation else {continue}
                        }
                        let longest=rects.map(\.height).max()!
                        guard compactAllowed ? bounds.height>=longest+rects.map(\.width).min()!*0.5:
                            bounds.height>=longest*1.35 else {continue}
                        // A narrow subset must not masquerade as a whole lane
                        // when a larger neighbouring fragment continues it.
                        let omittedContinuation=boxes.contains { box in
                            guard box.score>=0.6,!peers.contains(where:{$0.polygon==box.polygon}),
                                  let own=EndpointFrame(box.polygon),
                                  abs(own.along.x*f.along.x+own.along.y*f.along.y)>=0.98,
                                  NativeOCRDirectionAdapters.coverage(box.polygon,by:scope)>=0.8 else {return false}
                            let r=f.bounds(box.polygon)
                            let gap=max(0,r.minY-bounds.maxY,bounds.minY-r.maxY)
                            return r.width>a.width*1.8 && r.height>=r.width*1.2 &&
                                abs(r.midX-a.midX)<=min(r.width,a.width)*0.35 && gap<=r.width*3.5
                        }
                        guard !omittedContinuation else {continue}
                        let width=rects.map(\.width).sorted()[rects.count/2]
                        // A lower scalar score is not sufficient by itself.
                        // New measured chains need private model components,
                        // a strong peer, and a complete pixel/root proof below.
                        let measuredChain=measuredStage && peers.allSatisfy({
                                $0.detectorSeedEvidence?.components.isEmpty == false ||
                                    (privateBridge && exclusiveRoots($0).points.count>=8)
                            }) && peers.contains(where:{$0.detectorSeedEvidence?.components.isEmpty == false}) &&
                            peers.map(\.score).max()!>=0.75 && peers.map(\.score).reduce(0,+)/Double(peers.count)>=0.65 &&
                            bounds.height>=width*4 && rects.allSatisfy({$0.height>=width*0.7}) &&
                            (privateBridge || peers.contains(where:{$0.score<0.6}) || rf.width>bounds.width*6)
                        // New broad searches need repeated full-size text in
                        // every fragment, rather than an isolated ornament.
                        let repeated=rects.allSatisfy({$0.height>=width*1.8}) && peers.allSatisfy({ box in
                                guard let own=EndpointFrame(box.polygon) else {return false}
                                return own.rect.height>=own.rect.width*2
                            })
                        let compactChain=compactAllowed && scope.confidence>=0.8 && (
                            (peers.count>=3 && bounds.height>=width*4 && rects.allSatisfy({$0.height>=width*0.7})) ||
                            (peers.count==2 && rects.allSatisfy({$0.height>=width*0.5}) &&
                                rects.map(\.height).max()!>=width*2 &&
                                zip(rects,rects.dropFirst()).allSatisfy({$1.minY-$0.maxY<=max($0.width,$1.width)*0.4})))
                        let scaleChain=variableScale && peers.count>=3 && bounds.height>=width*4 &&
                            rects.map(\.width).max()!>=rects.map(\.width).min()!*1.8 &&
                            peers.allSatisfy({$0.detectorSeedEvidence?.components.isEmpty == false})
                        // Three strong private owners can certify a narrow
                        // varying-size lane inside a wider RF paragraph.
                        let broadScaleChain=scaleChain && peers.allSatisfy({$0.score>=0.75}) &&
                            peers.map(\.score).reduce(0,+)/Double(peers.count)>=0.8
                        let maximumScopeColumns:CGFloat=measuredChain ? 9:
                            (broadScaleChain ? 6:(scaleChain ? 3:(compactChain ? 9:(expanded ? 6:3))))
                        guard (!measuredStage || measuredChain),(!variableScale || scaleChain),
                              (!expanded || repeated || compactChain || scaleChain || pass==7 || measuredChain),
                              rf.width<=bounds.width*maximumScopeColumns else {continue}
                        let top=pass==7 ? bounds.minY-width*0.45:max(rf.minY,bounds.minY-width*1.5)
                        let bottom=pass==7 ? bounds.maxY+width*0.45:min(rf.maxY,bounds.maxY+width*1.5)
                        let r=CGRect(x:bounds.minX-width*0.15,y:top,width:bounds.width+width*0.3,height:bottom-top)
                        let polygon=corners(r).map(f.restore)
                        if !expanded {
                            let area=NativeOCRDirectionGeometry.area(polygon)
                            guard NativeOCRDirectionGeometry.intersectionArea(polygon,support)>=area*0.8 ||
                                texts.contains(where:{NativeOCRDirectionGeometry.intersectionArea(polygon,
                                    NativeOCRDirectionAdapters.support($0))>=area*0.8}) ||
                                texts.contains(where:{ text in
                                    let shape=NativeOCRDirectionAdapters.support(text)
                                    let overlap=NativeOCRDirectionGeometry.intersectionArea(polygon,shape)
                                    return text.confidence>=0.8 && overlap>=area*0.25 &&
                                        overlap>=NativeOCRDirectionGeometry.area(shape)*0.9
                                }) else {continue}
                        }
                        guard !certified.contains(where:{NativeOCRDirectionGeometry.intersectionArea(polygon,$0) >=
                            NativeOCRDirectionGeometry.area(polygon)*0.8}) else {continue}
                        certified.append(polygon)
                        if traceInk,privateBridge {trace("privateBridgeWindow",[
                            "source":polygon.map{[Double($0.x),Double($0.y)]},
                            "members":peers.map{["score":$0.score,"polygon":$0.polygon.map{[Double($0.x),Double($0.y)]}] as [String:Any]}])}
                        sources.append((f,r,width,1,2,true,support,expanded ? bounds:nil,compactAllowed,
                            exclusiveStage || privateBridge,pass==7 || privateBridge,measuredStage,false,false,false))
                    }
                }
            }
        }
        // Prefer a complete measured chain over a prefix from a different
        // anchor. Previously accepted paths keep their original precedence.
        let measuredSources=sources.filter(\.measured).sorted {
            ($0.witness?.height ?? 0)>($1.witness?.height ?? 0)
        }
        sources.removeAll(where:{$0.measured});sources+=measuredSources
        // If an adjacent same-colour column touches the search edge, retain
        // the original path and separately test only a closed, owned body lane.
        let rootLaneSources=sources.filter{$0.exclusive && $0.closedNormal && $0.witness != nil}.map { source -> Source in
            var copy=source;copy.rootLane=true;return copy
        }
        sources+=rootLaneSources
        // A pale outline may remain stable while a word's inner print colour
        // changes. Try that measured stroke separately, with a root certificate.
        let lightStrokeSources=sources.filter{$0.closedNormal && $0.witness != nil}.map { source -> Source in
            var copy=source;copy.lightStroke=true;return copy
        }
        sources+=lightStrokeSources
        // Finish every previously validated path, including its rooted/pale
        // variants, before trying the new private column witnesses. A new
        // complete hypothesis may supplement an old read, never suppress it
        // merely by being considered first.
        let privateBridgeSources=sources.filter{$0.bridge && $0.measured}
        sources.removeAll(where:{$0.bridge && $0.measured})
        sources+=privateBridgeSources
        func quantile(_ values:[Double],_ p:Double)->Double {
            let a=values.sorted();guard !a.isEmpty else {return 0}
            let index=Double(a.count-1)*p,lo=Int(floor(index)),hi=Int(ceil(index))
            return a[lo]+(a[hi]-a[lo])*(index-Double(lo))
        }
        func runs(_ values:[Bool])->[Range<Int>] {
            var result:[Range<Int>]=[],start:Int?
            for i in 0...values.count {
                if i<values.count,values[i] {if start==nil {start=i}}
                else if let a=start {result.append(a..<i);start=nil}
            }
            return result
        }
        func distance(_ a:SIMD3<Int>,_ b:SIMD3<Int>)->Int {
            max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z))
        }
        func key(_ c:SIMD3<Int>)->Int {(c.x/32)*64+(c.y/32)*8+c.z/32}
        func median(_ colours:[SIMD3<Int>])->SIMD3<Int> {
            var c=SIMD3<Int>(repeating:0)
            for k in 0..<3 {c[k]=Int(quantile(colours.map{Double($0[k])},0.5))}
            return c
        }
        if flexible {
            // A strong RF text scope can contain columns fused into one broad
            // DB parent. Its measured map cells provide the search interval;
            // no detector component is reassigned to the new columns.
            let sx=CGFloat(frame.width)/CGFloat(map.width),sy=CGFloat(frame.height)/CGFloat(map.height)
            let canvas=CGRect(x:0,y:0,width:frame.width,height:frame.height)
            for scope in texts where scope.confidence>=0.85 {
                let support=NativeOCRDirectionAdapters.support(scope)
                let roi=NativeOCRDirectionGeometry.bounds(support).intersection(canvas)
                guard !roi.isNull,roi.width>=8,roi.height>=8 else {continue}
                let x0=max(0,Int(floor(roi.minX/sx))),x1=min(map.width,Int(ceil(roi.maxX/sx)))
                let y0=max(0,Int(floor(roi.minY/sy))),y1=min(map.height,Int(ceil(roi.maxY/sy)))
                var roots:[CGPoint]=[]
                for y in y0..<y1 {
                    if y & 63 == 0 {try cancellationCheck()}
                    for x in x0..<x1 where map.values[y*map.width+x]>=0.5 {
                        let point=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(y)+0.5)*sy)
                        if NativeOCRDirectionGeometry.contains(support,point) {roots.append(point)}
                    }
                }
                guard roots.count>=12 else {continue}
                var bases:[EndpointFrame]=[]
                for box in boxes.sorted(by:{$0.score>$1.score}) where box.score>=0.6 {
                    guard let basis=EndpointFrame(box.polygon),basis.rect.width>=6,
                          basis.rect.height>=basis.rect.width*1.2,
                          NativeOCRDirectionGeometry.intersectionArea(box.polygon,support) >=
                            min(NativeOCRDirectionGeometry.area(box.polygon),NativeOCRDirectionGeometry.area(support))*0.5,
                          !bases.contains(where:{abs($0.along.x*basis.along.x+$0.along.y*basis.along.y)>=0.98}) else {continue}
                    bases.append(basis)
                    if bases.count==4 {break}
                }
                if bases.isEmpty {
                    let center=roots.reduce(CGPoint.zero){CGPoint(x:$0.x+$1.x/CGFloat(roots.count),y:$0.y+$1.y/CGFloat(roots.count))}
                    var xx:CGFloat=0,yy:CGFloat=0,xy:CGFloat=0
                    for point in roots {let x=point.x-center.x,y=point.y-center.y;xx+=x*x;yy+=y*y;xy+=x*y}
                    let delta=hypot(xx-yy,2*xy),major=(xx+yy+delta)/2,minor=(xx+yy-delta)/2
                    if major>=max(1,minor)*3 {
                        let angle=atan2(2*xy,xx-yy)/2
                        var along=CGPoint(x:cos(angle),y:sin(angle))
                        if let reference=EndpointFrame(support),along.x*reference.along.x+along.y*reference.along.y<0 {
                            along=CGPoint(x:-along.x,y:-along.y)
                        }
                        let normal=CGPoint(x:along.y,y:-along.x)
                        let rect=NativeOCRDirectionGeometry.bounds(roots.map{CGPoint(x:$0.x*normal.x+$0.y*normal.y,y:$0.x*along.x+$0.y*along.y)})
                        let quad=corners(rect).map{CGPoint(x:$0.x*normal.x+$0.y*along.x,y:$0.x*normal.y+$0.y*along.y)}
                        if let basis=EndpointFrame(quad) {bases.append(basis)}
                    }
                }
                for basis in bases {
                    let observed=NativeOCRDirectionGeometry.bounds(roots.map(basis.project))
                    guard observed.width>=6,observed.height>=observed.width*1.2 else {continue}
                    let normalMargin=max(max(sx,sy)*3,observed.width*0.2)
                    let alongMargin=max(max(sx,sy)*2,observed.width*0.12)
                    let context=basis.bounds(support)
                    let search=CGRect(x:observed.minX-normalMargin,y:context.minY-alongMargin,
                        width:observed.width+normalMargin*2,height:context.height+alongMargin*2)
                    var candidate:Source=(basis,search,nil,1,8,false,support,nil,true,false,false,false,false,false,true)
                    sources.append(candidate);candidate.lightStroke=true;sources.append(candidate)
                }
            }
        }
        var result=preserved
        for source in sources {
            try cancellationCheck()
            let f=source.basis,r=source.rect,q=corners(r).map(f.restore)
            let area=NativeOCRDirectionGeometry.area(q)
            // Certified fragments already have individual RF coverage. Their
            // source-pixel search margin need not itself lie inside that RF.
            let strictScope=source.witness != nil || texts.contains {NativeOCRDirectionGeometry.intersectionArea(q,
                NativeOCRDirectionAdapters.support($0))>=area*0.8} || source.scope.map {
                    NativeOCRDirectionGeometry.intersectionArea(q,$0)>=area*0.8
                } == true
            let containedScope=flexible && texts.contains { text in
                let support=NativeOCRDirectionAdapters.support(text)
                let overlap=NativeOCRDirectionGeometry.intersectionArea(q,support)
                return text.confidence>=0.8 && overlap>=area*0.25 &&
                    overlap>=NativeOCRDirectionGeometry.area(support)*0.9
            }
            let effectConflict=effects.contains { effect in
                guard NativeOCRDirectionGeometry.intersectionArea(q,
                    NativeOCRDirectionAdapters.support(effect))>=area*0.1 else {return false}
                if source.bridge,source.measured,let witness=source.witness {
                    let column=corners(witness).map(f.restore),size=NativeOCRDirectionGeometry.area(column)
                    // A weaker overlapping effect must not erase a complete
                    // privately rooted column supported by stronger RF text.
                    if texts.contains(where:{$0.confidence>=max(0.5,effect.confidence) &&
                        NativeOCRDirectionGeometry.intersectionArea(column,
                            NativeOCRDirectionAdapters.support($0))>=size*0.8}) {return false}
                }
                return true
            }
            guard area>0,(strictScope || containedScope),!effectConflict else {continue}
            let step=max(1,min(3,r.height/700)),columns=Int(ceil(r.width/step)),rows=Int(ceil(r.height/step))
            guard columns>0,rows>0,columns<=300_000/rows else {continue}
            var rgb=[SIMD3<Int>](repeating:.init(repeating:0),count:columns*rows)
            var values=[Float](repeating:0,count:rgb.count),border:[SIMD3<Int>]=[]
            for y in 0..<rows {
                if y & 63 == 0 {try cancellationCheck()}
                for x in 0..<columns {
                    let point=f.restore(.init(x:r.minX+(CGFloat(x)+0.5)*r.width/CGFloat(columns),
                        y:r.minY+(CGFloat(y)+0.5)*r.height/CGFloat(rows)))
                    guard point.x>=0,point.y>=0,point.x<CGFloat(frame.width),point.y<CGFloat(frame.height) else {continue}
                    let offset=Int(point.y)*frame.bytesPerRow+Int(point.x)*4,p=y*columns+x
                    let colour=SIMD3(Int(frame.bytes[offset]),Int(frame.bytes[offset+1]),Int(frame.bytes[offset+2]))
                    rgb[p]=colour
                    let mx=min(map.width-1,Int(point.x*CGFloat(map.width)/CGFloat(frame.width)))
                    let my=min(map.height-1,Int(point.y*CGFloat(map.height)/CGFloat(frame.height)))
                    values[p]=map.values[my*map.width+mx]
                    if y==0 || y==rows-1 {border.append(colour)}
                    if x==0 || x==columns-1 {border.append(colour)}
                }
            }
            guard !border.isEmpty else {continue}
            var borderBins=[Int:Int]()
            for c in border {borderBins[key(c),default:0]+=1}
            let bgKey=borderBins.keys.sorted().max { a,b in
                borderBins[a]==borderBins[b] ? a>b:borderBins[a]!<borderBins[b]!
            }!
            var background=median(border.filter{key($0)==bgKey})
            if source.rfWitness,let scope=source.scope {
                // Expanded search margins can cross out of coloured paper.
                // Estimate that paper inside the RF scope, away from text roots.
                var paper=[Int:[SIMD3<Int>]]()
                for y in 0..<rows {for x in 0..<columns where values[y*columns+x]<0.15 {
                    let local=CGPoint(x:r.minX+(CGFloat(x)+0.5)*r.width/CGFloat(columns),
                        y:r.minY+(CGFloat(y)+0.5)*r.height/CGFloat(rows))
                    if NativeOCRDirectionGeometry.contains(scope,f.restore(local)) {
                        let c=rgb[y*columns+x];paper[key(c),default:[]].append(c)
                    }
                }}
                if let best=paper.keys.sorted().max(by:{paper[$0]!.count<paper[$1]!.count}),paper[best]!.count>=12 {
                    background=median(paper[best]!)
                }
            }
            var bins=[Int:[SIMD3<Int>]](),seedCount=0
            for p in rgb.indices where values[p]>=0.5 && distance(rgb[p],background)>=48 {
                bins[key(rgb[p]),default:[]].append(rgb[p]);seedCount+=1
            }
            guard seedCount>=12 else {continue}
            let ordered=bins.keys.sorted { a,b in bins[a]!.count==bins[b]!.count ? a<b:bins[a]!.count>bins[b]!.count }
            let alternatives=ordered.filter { k in
                guard Double(bins[k]!.count)>=max(12,Double(seedCount)*0.08) else {return false}
                let c=median(bins[k]!);return min(c.x,c.y,c.z)<190 || max(c.x,c.y,c.z)-min(c.x,c.y,c.z)>40
            }
            let ordinaryKey=alternatives.first ?? ordered[0]
            let colour:SIMD3<Int>
            if source.lightStroke {
                guard let pale=ordered.first(where:{ k in
                    k != ordinaryKey && !alternatives.contains(k) &&
                        Double(bins[k]!.count)>=max(12,Double(seedCount)*0.08)
                }) else {continue}
                colour=median(bins[pale]!)
            } else {colour=median(bins[ordinaryKey]!)}
            var ink=[UInt8](repeating:0,count:rgb.count),profile=[Double](repeating:0,count:columns)
            for p in rgb.indices where values[p]>=0.005 && distance(rgb[p],colour)<=20 {
                ink[p]=1;profile[p%columns]+=1
            }
            let positive=profile.filter{$0>0}
            guard !positive.isEmpty else {continue}
            let radius=max(1,Int((Double(columns)*0.008).rounded(.toNearestOrEven)))
            let smoothed=profile.indices.map { x -> Double in
                var sum=0.0
                for k in max(0,x-radius)...min(columns-1,x+radius) {sum+=profile[k]}
                return sum/Double(2*radius+1)
            }
            let gate=max(2,quantile(positive,0.75)*0.12)
            var bands=runs(smoothed.map{$0>=gate})
            let annotationGuard=sourceInkAnnotationBandsEnabled
            let substantial=bands.map{Double($0.count)}.filter{$0>=max(3,Double(columns)*0.08)}
            let normalNominal=source.nominal.map{Double($0/step)} ?? quantile(substantial,0.5)
            let expected=normalNominal
            // Detector padding can overstate glyph width; require a size
            // contrast with neighbouring source-colour bands as well.
            let annotationScale=min(normalNominal,quantile(substantial,0.75)*1.5)
            func annotationSized(_ band:Range<Int>)->Bool {
                guard annotationGuard,Double(band.count)<=annotationScale*0.5 else {return false}
                let active=(0..<rows).map { y -> Bool in
                    var count=0;for x in band {count+=Int(ink[y*columns+x])}
                    return Double(count)>=max(1,Double(band.count)*0.05)
                }
                let spans=runs(active)
                guard let first=spans.first,let last=spans.last else {return false}
                let extent=last.upperBound-first.lowerBound,occupied=spans.reduce(0){$0+$1.count}
                guard Double(extent)>=annotationScale*1.5,Double(occupied)>=Double(extent)*0.35,
                      quantile(spans.map{Double($0.count)},0.5)<annotationScale*0.5 else {return false}
                return true
            }
            let annotations=bands.filter{annotationSized($0)}
            if ProcessInfo.processInfo.environment["AIDOKU_OCR_INK_WIDTH_AUDIT"] == "1" {
                let fields:[String:Any] = ["source":q.map{[Double($0.x),Double($0.y)]},
                    "flexible":flexible,"nominal":normalNominal,"annotationScale":annotationScale,"lightStroke":source.lightStroke,"rfWitness":source.rfWitness,
                    "step":Double(step),"bands":bands.map{[$0.lowerBound,$0.upperBound]},
                    "annotations":annotations.map{[$0.lowerBound,$0.upperBound]},
                    "witness":source.witness.map{[Double($0.minX),Double($0.minY),Double($0.maxX),Double($0.maxY)]} ?? []]
                if let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]) {
                    FileHandle.standardError.write(Data("ocr_ink_width ".utf8)+data+Data([10]))
                }
            }
            let unjoinedBands=bands
            if flexible && !source.rootLane {
                var joined:[Range<Int>]=[]
                for band in bands {
                    if let last=joined.last,!annotationSized(band),!annotationSized(last),
                       Double(band.lowerBound-last.upperBound)<=expected*0.25,
                       Double(min(band.count,last.count))<expected*0.5,
                       Double(band.upperBound-last.lowerBound)<=expected*1.6 {
                        joined[joined.count-1]=last.lowerBound..<band.upperBound
                    } else {joined.append(band)}
                }
                bands=joined
            }
            var lanes=bands.filter{Double($0.count)>=max(3,Double(columns)*0.08) && !annotationSized($0)}
            if source.rfWitness {lanes=lanes.filter{$0.lowerBound>radius && $0.upperBound<columns-radius}}
            if source.rootLane {
                lanes=lanes.filter { lane in
                    lane.lowerBound>radius && lane.upperBound<columns-radius
                }
                guard lanes.count==1 else {continue}
            }
            guard (source.minimum...source.maximum).contains(lanes.count) else {continue}
            // A tilted frame crossing neighbouring columns leaves ink open
            // on its normal edges. Compact chains need measured side valleys.
            if source.closedNormal,lanes.contains(where:{$0.lowerBound<=radius || $0.upperBound>=columns-radius}) {continue}
            let widths=lanes.map{Double($0.count)},pitch=quantile(widths,0.5)
            let nominal=source.nominal ?? (source.rfWitness ? CGFloat(pitch)*step:r.width/CGFloat(lanes.count))
            // A measured valley is quantized to sample columns. Do not reject
            // a full one-sample valley for missing a fraction of a sample.
            let minimumValley=source.rfWitness ? max(1,floor(pitch*0.08)):pitch*0.08
            guard widths.max()!<=widths.min()!*2.2,CGFloat(widths.min()!)>=nominal/step*0.4,
                  zip(lanes,lanes.dropFirst()).allSatisfy({Double($1.lowerBound-$0.upperBound)>=minimumValley}) else {continue}
            var proposals:[(polygon:[CGPoint],limits:[CGPoint],normalClosed:Bool)]=[]
            var longWitness=source.nominal != nil
            for (position,lane) in lanes.enumerated() {
                let rowCounts=(0..<rows).map { y -> Int in
                    var count=0;for x in lane {count+=Int(ink[y*columns+x])}
                    return count
                }
                let active=rowCounts.map{Double($0)>=max(1,Double(lane.count)*0.05)}
                let observed=runs(active);var segments:[Range<Int>]=[]
                for run in observed {
                    if let last=segments.last,Double(run.lowerBound-last.upperBound)<=pitch*(source.measured ? 1.5:(source.single ? 3:1.3)) {
                        segments[segments.count-1]=last.lowerBound..<run.upperBound
                    } else {segments.append(run)}
                }
                if traceInk {trace("span",["source":q.map{[Double($0.x),Double($0.y)]},"lane":[lane.lowerBound,lane.upperBound],
                    "observed":observed.map{[$0.lowerBound,$0.upperBound]},"segments":segments.map{[$0.lowerBound,$0.upperBound]},
                    "colour":[colour.x,colour.y,colour.z]])}
                var shapedRuns=observed.count
                if source.rfWitness,observed.count<3 {
                    // Connected pale contours need not leave a completely
                    // blank row between glyphs. Repeated wide bodies separated
                    // by narrow strokes still differ from a uniform rule.
                    let radius=max(1,Int(Double(lane.count)*0.08))
                    let body=rowCounts.indices.map { y -> Double in
                        let lo=max(0,y-radius),hi=min(rows-1,y+radius)
                        return Double(rowCounts[lo...hi].reduce(0,+))/Double(hi-lo+1)
                    }
                    let gate=max(2,(body.max() ?? 0)*0.6)
                    let bodies=runs(body.map{$0>=gate}).filter{Double($0.count)>=max(2,Double(lane.count)*0.1)}
                    if bodies.count>=3 {
                        shapedRuns=bodies.count
                        if traceInk {trace("connectedBodies",["source":q.map{[Double($0.x),Double($0.y)]},
                            "lane":[lane.lowerBound,lane.upperBound],"bodies":bodies.map{[$0.lowerBound,$0.upperBound]},"gate":gate])}
                    }
                }
                guard segments.count==1,let span=segments.first,
                      Double(span.count)>=Double(lane.count)*(source.rfWitness ? 3:(flexible ? 1.8:3)),
                      shapedRuns>=(source.rfWitness ? 3:(flexible ? 2:3)) else {
                    if flexible,source.nominal != nil || source.rfWitness {continue}
                    break
                }
                if span.count>=lane.count*3,shapedRuns>=3 {longWitness=true}
                let padding=max(1.5,CGFloat(lane.count)*r.width/CGFloat(columns)*0.14)
                var left=max(r.minX,r.minX+CGFloat(lane.lowerBound)*r.width/CGFloat(columns)-padding)
                var right=min(r.maxX,r.minX+CGFloat(lane.upperBound)*r.width/CGFloat(columns)+padding)
                let top=max(r.minY,r.minY+CGFloat(span.lowerBound)*r.height/CGFloat(rows)-padding)
                let bottom=min(r.maxY,r.minY+CGFloat(span.upperBound)*r.height/CGFloat(rows)+padding)
                var normalLeft=position>0 ? r.minX+CGFloat(lanes[position-1].upperBound+lane.lowerBound)*r.width/CGFloat(columns*2):left-r.width/CGFloat(columns)*CGFloat(lane.count)*0.45
                var normalRight=position+1<lanes.count ? r.minX+CGFloat(lane.upperBound+lanes[position+1].lowerBound)*r.width/CGFloat(columns*2):right+r.width/CGFloat(columns)*CGFloat(lane.count)*0.45
                if source.scope != nil {
                    normalLeft=max(normalLeft,r.minX)
                    normalRight=min(normalRight,r.maxX)
                }
                if source.rootLane || source.rfWitness {
                    // Unselected bands still constrain the caps: they are
                    // neighbouring ink, not permission to widen into it.
                    if let previous=unjoinedBands.last(where:{$0.upperBound<=lane.lowerBound}) {
                        normalLeft=max(normalLeft,r.minX+CGFloat(previous.upperBound+lane.lowerBound)*r.width/CGFloat(columns*2))
                        left=max(left,normalLeft)
                    }
                    if let next=unjoinedBands.first(where:{$0.lowerBound>=lane.upperBound}) {
                        normalRight=min(normalRight,r.minX+CGFloat(lane.upperBound+next.lowerBound)*r.width/CGFloat(columns*2))
                        right=min(right,normalRight)
                    }
                }
                if annotationGuard {
                    if let band=annotations.last(where:{$0.upperBound<=lane.lowerBound &&
                        Double(lane.lowerBound-$0.upperBound)<=Double(lane.count)*0.5}) {
                        normalLeft=max(normalLeft,r.minX+CGFloat(band.upperBound+lane.lowerBound)*r.width/CGFloat(columns*2))
                        left=max(left,normalLeft)
                    }
                    if let band=annotations.first(where:{$0.lowerBound>=lane.upperBound &&
                        Double($0.lowerBound-lane.upperBound)<=Double(lane.count)*0.5}) {
                        normalRight=min(normalRight,r.minX+CGFloat(lane.upperBound+band.lowerBound)*r.width/CGFloat(columns*2))
                        right=min(right,normalRight)
                    }
                }
                let limits=corners(CGRect(x:normalLeft,y:r.minY,width:normalRight-normalLeft,height:r.height)).map(f.restore)
                proposals.append((corners(CGRect(x:left,y:top,width:right-left,height:bottom-top)).map(f.restore),limits,
                    lane.lowerBound>radius && lane.upperBound<columns-radius))
            }
            guard !proposals.isEmpty,(!flexible || longWitness),
                  (flexible && (source.nominal != nil || source.rfWitness)) || proposals.count==lanes.count else {continue}
            func omitsContinuation(_ candidate:CGRect,inside container:CGRect?=nil,nearbyOnly:Bool=false)->Bool {
                for box in boxes where box.score>=0.6 {
                    guard let evidence=box.detectorSeedEvidence,evidence.isValid,
                          evidence.sourceWidth==frame.width,evidence.sourceHeight==frame.height,
                          evidence.mapFullWidth==map.width,evidence.mapFullHeight==map.height,
                          let own=EndpointFrame(box.polygon),
                          abs(own.along.x*f.along.x+own.along.y*f.along.y)>=0.98 else {continue}
                    let b=f.bounds(box.polygon),font=min(b.width,candidate.width)
                    guard max(b.width,candidate.width)<=font*2.5,
                          abs(b.midX-candidate.midX)<=font*0.35 else {continue}
                    let gap=max(0,b.minY-candidate.maxY,candidate.minY-b.maxY)
                    if nearbyOnly,gap>font*1.5 {continue}
                    var omitted=Set<Int>()
                    let sx=CGFloat(frame.width)/CGFloat(map.width),sy=CGFloat(frame.height)/CGFloat(map.height)
                    // Unknown ownership cannot admit new ink. It can still veto
                    // discarding observed cells inside that detector's polygon.
                    let possible = evidence.components + (evidence.ambiguousComponents ?? []) +
                        (evidence.candidateComponents ?? []).map(\.component)
                    for component in possible {for run in component.runs {for x in run.x..<(run.x+run.count) {
                        let world=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                        let p=f.project(world)
                        if NativeOCRDirectionGeometry.contains(box.polygon,world),container?.contains(p) != false,
                           p.x>=candidate.minX-font*0.25,p.x<=candidate.maxX+font*0.25,
                           (p.y<candidate.minY-font*0.5 || p.y>candidate.maxY+font*0.5) {
                            omitted.insert(run.y*map.width+x)
                        }
                    }}}
                    if omitted.count>=8 {return true}
                }
                return false
            }
            func certifiedExtension(_ polygon:[CGPoint],of other:[CGPoint])->Bool {
                guard source.bridge || source.measured else {return false}
                let candidate=f.bounds(polygon),old=f.bounds(other)
                let normal=max(0,min(candidate.maxX,old.maxX)-max(candidate.minX,old.minX))
                let along=max(0,min(candidate.maxY,old.maxY)-max(candidate.minY,old.minY))
                return candidate.height>=old.height+min(candidate.width,old.width)*0.5 &&
                    max(candidate.width,old.width)<=min(candidate.width,old.width)*1.8 &&
                    normal>=min(candidate.width,old.width)*0.8 && along>=old.height*0.8
            }
            var refinementScore:Double?
            func certifiedRefinement(_ polygon:[CGPoint],of other:[CGPoint])->Bool {
                let candidate=f.bounds(polygon),old=f.bounds(other)
                let size=NativeOCRDirectionGeometry.area(polygon),oldSize=NativeOCRDirectionGeometry.area(other)
                guard size>0,oldSize>=size*1.8,old.width>=candidate.width*1.25,old.height>=candidate.height*1.15,
                      candidate.minX>r.minX+step*CGFloat(radius),candidate.maxX<r.maxX-step*CGFloat(radius),
                      candidate.height>=candidate.width*3,
                      NativeOCRDirectionGeometry.intersectionArea(polygon,other)>=size*0.9 else {return false}
                let witness=source.witness ?? texts.filter {
                    $0.confidence>=0.8 && NativeOCRDirectionAdapters.coverage(polygon,by:$0)>=0.8
                }.map{f.bounds(NativeOCRDirectionAdapters.support($0))}.min(by:{$0.height<$1.height})
                guard let witness,candidate.height>=witness.height*0.85 else {return false}
                if omitsContinuation(candidate,inside:old) {return false}
                let strongRF=texts.contains {$0.confidence>=0.9 && NativeOCRDirectionAdapters.coverage(polygon,by:$0)>=0.8}
                guard let proof=columnSupportScore(polygon,allowExclusive:source.exclusive || strongRF,
                    minimumScore:strongRF ? 0.4:(source.measured ? 0.5:0.6)) else {return false}
                refinementScore=proof;return true
            }
            func alreadyOwned(_ polygon:[CGPoint])->Bool {
                let bound=f.bounds(polygon),size=NativeOCRDirectionGeometry.area(polygon)
                guard size>0 else {return true}
                let owner=existing.first { other in
                    if certifiedExtension(polygon,of:other) || certifiedRefinement(polygon,of:other) {return false}
                    let otherArea=NativeOCRDirectionGeometry.area(other),overlap=NativeOCRDirectionGeometry.intersectionArea(polygon,other)
                    let width=f.bounds(other).width
                    if source.lightStroke,f.bounds(other).height>=bound.height*1.35,
                       width>=bound.width*0.5,width<=bound.width*2.5,overlap>=size*0.9 {return true}
                    return (width>=bound.width*0.5 && width<=bound.width*1.8 && overlap>=size*0.8) ||
                        overlap/max(1,size+otherArea-overlap)>=0.65 || (overlap>=size*0.85 && otherArea<=size*1.8)
                }
                if let owner,ProcessInfo.processInfo.environment["AIDOKU_OCR_INK_WIDTH_AUDIT"] == "1" {
                    let fields:[String:Any] = ["candidate":polygon.map{[Double($0.x),Double($0.y)]},
                        "owner":owner.map{[Double($0.x),Double($0.y)]},
                        "closedSource":source.closedNormal,"rootLane":source.rootLane,
                        "witness":source.witness.map{[Double($0.minY),Double($0.maxY)]} ?? [],
                        "widthRatio":Double(f.bounds(owner).width/bound.width),
                        "heightRatio":Double(f.bounds(owner).height/bound.height)]
                    if let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]) {
                        FileHandle.standardError.write(Data("ocr_ink_owned ".utf8)+data+Data([10]))
                    }
                }
                return owner != nil
            }
            for proposal in proposals {
                // Endpoint details refine a genuinely missing/split column;
                // they must not invent a duplicate of an already owned word.
                refinementScore=nil
                guard !alreadyOwned(proposal.polygon) else {continue}
                var polygon=sourceInkColumnCaps(proposal.polygon,colour:colour,frame:frame,normalLimits:proposal.limits,probability:map)
                if source.lightStroke || source.rfWitness,omitsContinuation(f.bounds(polygon),nearbyOnly:true) {continue}
                if source.rfWitness {
                    let narrow=r.width<=f.bounds(polygon).width*2
                    guard !sourceInkSideAnnotation(polygon,boxes:boxes,useOwnFontWidth:true,rfWitness:narrow) else {continue}
                    // Restore differently coloured glyph edges only when the
                    // map and original contrast support them near this lane.
                    let body=f.bounds(polygon),limits=f.bounds(proposal.limits)
                    var left=body.minX,right=body.maxX,outer=0
                    for y in 0..<rows {for x in 0..<columns where values[y*columns+x]>=0.5 {
                        let point=CGPoint(x:r.minX+(CGFloat(x)+0.5)*r.width/CGFloat(columns),
                            y:r.minY+(CGFloat(y)+0.5)*r.height/CGFloat(rows))
                        if point.y>=body.minY,point.y<=body.maxY,point.x>=body.minX-body.width*0.35,
                           point.x<=body.maxX+body.width*0.35,distance(rgb[y*columns+x],background)>=24,
                           point.x<body.minX || point.x>body.maxX {
                            left=min(left,point.x);right=max(right,point.x);outer+=1
                        }
                    }}
                    if outer>=8 {
                        left=max(limits.minX,left-step*2);right=min(limits.maxX,right+step*2)
                        polygon=corners(CGRect(x:left,y:body.minY,width:right-left,height:body.height)).map(f.restore)
                    }
                }
                if let witness=source.witness {
                    let crop=f.bounds(polygon)
                    let overlap=max(0,min(crop.maxY,witness.maxY)-max(crop.minY,witness.minY))
                    if overlap<witness.height*0.85 {
                        if traceInk {trace("witness",["candidate":polygon.map{[Double($0.x),Double($0.y)]},"coverage":Double(overlap/witness.height)])}
                        continue
                    }
                }
                if sourceInkSideAnnotation(polygon,boxes:boxes,useOwnFontWidth:source.rootLane || source.rfWitness,
                    rfWitness:source.rfWitness && r.width<=f.bounds(polygon).width*2) {continue}
                if source.rfWitness,!layout.primitives.contains(where:{
                    $0.semanticClass == .balloon && $0.confidence>=0.6 &&
                        NativeOCRDirectionAdapters.coverage(polygon,by:$0)>=0.8
                }) {continue}
                if flexible,!strictScope,!texts.contains(where:{NativeOCRDirectionAdapters.coverage(polygon,by:$0)>=0.7}) {continue}
                let bound=f.bounds(polygon),size=NativeOCRDirectionGeometry.area(polygon)
                guard size>0,source.nominal.map({bound.width >= $0*(source.rootLane ? 0.4:0.65)}) != false,
                      polygon.allSatisfy({$0.x>=0 && $0.y>=0 && $0.x<=CGFloat(frame.width) && $0.y<=CGFloat(frame.height)}) else {continue}
                refinementScore=nil
                guard !alreadyOwned(polygon),!result.contains(where:{!certifiedExtension(polygon,of:$0.polygon) &&
                    !certifiedRefinement(polygon,of:$0.polygon) && NativeOCRDirectionGeometry.intersectionArea(polygon,$0.polygon) >
                    min(size,NativeOCRDirectionGeometry.area($0.polygon))*0.8}) else {continue}
                var sum=0.0,count=0,highMap=0,totalMap=0
                for y in 0..<rows {for x in 0..<columns {
                    let local=CGPoint(x:r.minX+(CGFloat(x)+0.5)*r.width/CGFloat(columns),
                        y:r.minY+(CGFloat(y)+0.5)*r.height/CGFloat(rows))
                    if bound.contains(local) {
                        totalMap+=1;if values[y*columns+x]>=0.5 {highMap+=1}
                        if ink[y*columns+x] != 0 {sum+=Double(values[y*columns+x]);count+=1}
                    }
                }}
                if traceInk {trace("score",["candidate":polygon.map{[Double($0.x),Double($0.y)]},"pixels":count,"meanProbability":count>0 ? sum/Double(count):0])}
                guard count>=12 else {continue}
                var confidence=sum/Double(count)
                if source.rfWitness {
                    let strong=texts.contains {$0.confidence>=0.9 && NativeOCRDirectionAdapters.coverage(polygon,by:$0)>=0.8}
                    let soft=strong && confidence>=0.25 && highMap>=12 && Double(highMap)>=Double(totalMap)*0.15
                    guard (confidence>=0.6 || soft),proposal.normalClosed else {continue}
                }
                if let proof=refinementScore {
                    guard confidence>=0.25,proposal.normalClosed else {continue}
                    confidence=proof
                }
                if !source.rfWitness && (source.measured || source.rootLane || source.lightStroke) {
                    guard confidence>=0.25,proposal.normalClosed,
                          let proof=columnSupportScore(polygon,allowExclusive:source.rootLane ||
                            ((source.lightStroke || (source.bridge && source.measured)) && source.exclusive),
                            minimumScore:source.measured ? 0.5:0.6) else {continue}
                    confidence=proof
                }
                if confidence<0.5 && refinementScore==nil && !source.rfWitness {
                    let scoped=source.witness != nil || texts.contains {
                        $0.confidence>=0.8 && NativeOCRDirectionAdapters.coverage(polygon,by:$0)>=0.7
                    }
                    guard confidence>=0.25,proposal.normalClosed,scoped,
                          let proof=columnSupportScore(polygon,allowExclusive:source.exclusive) else {continue}
                    confidence=proof
                }
                // Keep the pixel measurement grid independent of PCA sign.
                // Apply trusted reading order only after the envelope is final.
                if polygon.count==4,let ordered=EndpointFrame(polygon),
                   ordered.along.x*f.trustedAlong.x+ordered.along.y*f.trustedAlong.y<0 {
                    polygon=[polygon[2],polygon[3],polygon[0],polygon[1]]
                }
                result.append(.init(polygon:polygon,score:confidence))
            }
        }
        return result
    }

    final class MapCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: NativeMainEnsembleOCRProbability.Sample?

        func store(_ sample: NativeMainEnsembleOCRProbability.Sample) {
            lock.lock(); value = sample; lock.unlock()
        }

        func take() -> NativeMainEnsembleOCRProbability.Sample? {
            lock.lock(); defer { lock.unlock() }
            let sample = value; value = nil
            return sample
        }

        func observer(forwarding downstream: NativeMainEnsembleOCRProbability.Observer?) -> NativeMainEnsembleOCRProbability.Observer {
            { [self] sample in
                store(sample)
                return downstream?(sample) ?? .init(status: .registered, width: sample.width, height: sample.height)
            }
        }
    }

    static func plan(boxes: [NativeCoreMLDetectionBox], layout: NativeRFDETRLayoutResult?,
                     width: Int, height: Int,
                     probability: NativeMainEnsembleOCRProbability.Sample? = nil,
                     pixelThreshold: Double = 0.15) -> Plan {
        guard let layout, NativeOCRDirectionGeometry.enabled("missing") || NativeOCRDirectionGeometry.enabled("narrow") || NativeOCRDirectionGeometry.enabled("groups") else {
            return axisPlan(boxes:boxes,layout:layout,width:width,height:height,probability:probability,pixelThreshold:pixelThreshold)
        }
        let scoped = layout.primitives.flatMap { p -> [(NativeRFDETRLayoutPrimitive,NativeOCRDirectionGeometry.Window)] in
            guard p.semanticClass == .text else { return [] }
            return NativeOCRDirectionAdapters.scopeFrames(p.sourceBounds,boxes:boxes,probability:probability).compactMap { f in
                guard let w=NativeOCRDirectionAdapters.window(f,scope:p.sourceBounds,boxes:boxes) else { return nil }
                return (p,w)
            }
        }
        let ids = Set(scoped.map { $0.0.queryID })
        let base = axisPlan(boxes:boxes,layout:layout,width:width,height:height,probability:probability,pixelThreshold:pixelThreshold,
            skipMissing:NativeOCRDirectionGeometry.enabled("missing") ? ids : [],
            skipNarrow:NativeOCRDirectionGeometry.enabled("narrow") ? ids : [],
            skipGroups:NativeOCRDirectionGeometry.enabled("groups") ? ids : [],
            includeGroups:!NativeOCRDirectionGeometry.enabled("groups"),
            includeMissing:!NativeOCRDirectionGeometry.enabled("missing"),
            includeNarrow:!NativeOCRDirectionGeometry.enabled("narrow"))
        var augmented = base.boxes, supported = base.supported, strong = base.stronglySupported
        var refined = base.refinedCrops, groups = base.groups
        for (p,w) in scoped {
            let map = probability.flatMap { NativeOCRDirectionAdapters.probability($0,window:w,
                support:NativeOCRDirectionGeometry.enabled("rfShape") ? NativeOCRDirectionAdapters.support(p) : nil,
                preserving:boxes.map(\.polygon)) }
            let local = axisPlan(boxes:boxes.map { NativeOCRDirectionAdapters.box($0,map:w.project) },
                layout:NativeOCRDirectionAdapters.layout(layout,
                    primitives:[p]+layout.primitives.filter { $0.semanticClass == .soundEffect },window:w),width:w.width,height:w.height,
                probability:map,pixelThreshold:pixelThreshold,includeGroups:NativeOCRDirectionGeometry.enabled("groups"),
                includeMissing:NativeOCRDirectionGeometry.enabled("missing"),includeNarrow:NativeOCRDirectionGeometry.enabled("narrow"),
                allowProjectedContact:true,
                eligible:NativeOCRDirectionGeometry.enabled("mixedDirections") ? Set(boxes.indices.filter {
                    NativeOCRDirectionGeometry.compatible(boxes[$0].polygon,with:w.frame) }) : nil)
            for i in boxes.count..<local.boxes.count {
                let proposed = NativeOCRDirectionAdapters.box(local.boxes[i],map:w.restore)
                let r = w.frame.bounds(proposed.polygon)
                let refinement = local.refinedCrops.first { $0.index == i }
                let group = local.groups.first { $0.index == i }
                if NativeOCRDirectionGeometry.enabled("rfShape"), NativeOCRDirectionAdapters.coverage(proposed.polygon,by:p) < 0.9 { continue }
                if let group, groups.contains(where: { !Set($0.members).isDisjoint(with:group.members) }) { continue }
                if refinement == nil && group == nil && augmented.contains(where: { b in
                    let other = w.frame.bounds(b.polygon), overlap = r.intersection(other)
                    return !overlap.isNull && overlap.width*overlap.height >= min(r.width*r.height,other.width*other.height)*0.8
                }) { continue }
                if let refinement, refined.contains(where: { $0.parent == refinement.parent }) { continue }
                let index = augmented.count
                augmented.append(proposed)
                if local.supported.contains(i) { supported.insert(index) }
                if local.stronglySupported.contains(i) { strong.insert(index) }
                if let refinement { refined.append(.init(index:index,parent:refinement.parent)) }
                if let group { groups.append(.init(index:index,members:group.members,evidence:group.evidence)) }
            }
        }
        return includingAlignedPointFragments(.init(boxes:augmented,supported:supported,stronglySupported:strong,
            groups:groups,refinedCrops:refined),layout:layout,width:width,height:height)
    }

    /// A thin end fragment in the same RF text scope is a supplemental read
    /// of the original owners. Recognition still has to preserve the word;
    /// it never creates a detector owner or suppresses an independent word.
    static func includingAlignedPointFragments(_ plan:Plan,layout:NativeRFDETRLayoutResult?,
                                               width:Int,height:Int)->Plan {
        guard refinesEndpointInk,let layout,layout.sourceWidth==width,layout.sourceHeight==height else { return plan }
        var augmented=plan.boxes,groups=plan.groups,supported=plan.supported,strong=plan.stronglySupported
        let texts=layout.primitives.filter { $0.semanticClass == .text && $0.confidence >= 0.55 }
        for i in plan.boxes.indices where !groups.contains(where:{ $0.index == i || $0.members.contains(i) }) {
            let word=plan.boxes[i]
            guard word.score >= 0.6,let evidence=word.detectorSeedEvidence,evidence.isValid,
                  let frame=EndpointFrame(word.polygon),frame.rect.width >= 6,
                  frame.rect.height >= frame.rect.width*1.2 else { continue }
            let glyph=frame.rect.width
            let fragments=plan.boxes.indices.filter { j in
                guard j != i,!groups.contains(where:{ $0.index == j || $0.members.contains(j) }),
                      plan.boxes[j].score >= 0.5,let peer=plan.boxes[j].detectorSeedEvidence,peer.isValid,
                      peer.ownerID != evidence.ownerID else { return false }
                let r=frame.bounds(plan.boxes[j].polygon)
                let crossOverlap=max(0,min(r.maxX,frame.rect.maxX)-max(r.minX,frame.rect.minX))
                guard r.width <= glyph*0.9,r.height >= r.width*0.7,r.height <= glyph*3,
                      abs(r.midX-frame.rect.midX) <= glyph*0.25 || crossOverlap >= r.width*0.8 else { return false }
                let head=r.minY < frame.rect.minY-glyph*0.2 && r.maxY <= frame.rect.minY+glyph*0.6 && frame.rect.minY-r.maxY <= glyph
                let tail=r.maxY > frame.rect.maxY+glyph*0.2 && r.minY >= frame.rect.maxY-glyph*0.6 && r.minY-frame.rect.maxY <= glyph
                guard head || tail else { return false }
                return texts.contains { p in
                    NativeOCRDirectionAdapters.coverage(word.polygon,by:p) >= 0.6 &&
                    NativeOCRDirectionAdapters.coverage(plan.boxes[j].polygon,by:p) >= 0.7
                }
            }
            guard !fragments.isEmpty,fragments.count <= 2 else { continue }
            let ids=[i]+fragments,extent=ids.reduce(CGRect.null) { $0.union(frame.bounds(plan.boxes[$1].polygon)) }
            let proposal=[CGPoint(x:frame.rect.minX,y:extent.minY),CGPoint(x:frame.rect.maxX,y:extent.minY),
                CGPoint(x:frame.rect.maxX,y:extent.maxY),CGPoint(x:frame.rect.minX,y:extent.maxY)].map(frame.restore)
            let score=ids.map { plan.boxes[$0].score }.min()!,index=augmented.count
            augmented.append(.init(polygon:proposal,score:score))
            groups.append(.init(index:index,members:ids,evidence:ids.compactMap { plan.boxes[$0].detectorSeedEvidence },pointFragments:Set(fragments)))
            supported.insert(index)
            if ids.allSatisfy({ strong.contains($0) }) { strong.insert(index) }
        }
        return .init(boxes:augmented,supported:supported,stronglySupported:strong,groups:groups,refinedCrops:plan.refinedCrops)
    }

    static func axisPlan(boxes: [NativeCoreMLDetectionBox], layout: NativeRFDETRLayoutResult?,
                         width: Int, height: Int,
                         probability: NativeMainEnsembleOCRProbability.Sample? = nil,
                         pixelThreshold: Double = 0.15,
                         skipMissing: Set<Int> = [], skipNarrow: Set<Int> = [],
                         skipGroups: Set<Int> = [],
                         includeGroups: Bool = true, includeMissing: Bool = true, includeNarrow: Bool = true,
                         allowProjectedContact: Bool = false,
                         eligible: Set<Int>? = nil) -> Plan {
        guard let layout, layout.sourceWidth == width, layout.sourceHeight == height,
              width > 0, height > 0, boxes.count <= 256 else {
            return .init(boxes: boxes, supported: [], stronglySupported: [], groups: [], refinedCrops: [])
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let effects = layout.primitives.filter { $0.semanticClass == .soundEffect && $0.confidence >= 0.35 }
        let texts = layout.primitives.filter { $0.semanticClass == .text && $0.confidence >= 0.8 &&
            canvas.contains($0.sourceBounds) }
        var supported = Set<Int>(), stronglySupported = Set<Int>(), groups: [Group] = [], augmented = boxes
        var refinedCrops: [RefinedCrop] = []
        var grouped = Set<Int>()
        func bounds(_ box: NativeCoreMLDetectionBox) -> CGRect? {
            guard box.polygon.count == 4 else { return nil }
            let value = box.polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            return value.isNull || value.isEmpty || !canvas.contains(value) ? nil : value
        }
        // The probability scan visits up to 262,144 cells per RF query. Resolve
        // polygon bounds once, not once per cell and original DB box.
        let originalBounds = boxes.map(bounds)
        func coverage(_ part: CGRect, _ whole: CGRect) -> CGFloat {
            let intersection = part.intersection(whole)
            return intersection.isNull ? 0 : intersection.width * intersection.height / (part.width * part.height)
        }
        func detectorCoverage(_ index: Int, _ scope: CGRect) -> CGFloat {
            if let primitive=layout.primitives.first(where: { $0.sourceBounds == scope && $0.supportPolygon != nil }) {
                return NativeOCRDirectionAdapters.coverage(boxes[index].polygon,by:primitive)
            }
            if NativeOCRDirectionGeometry.enabled("rfOverlap") {
                return NativeOCRDirectionGeometry.coverage(boxes[index].polygon, by: scope)
            }
            return originalBounds[index].map { coverage($0, scope) } ?? 0
        }
        func overlapsEffect(_ index: Int) -> Bool {
            effects.contains { effect in
                if effect.supportPolygon != nil {
                    return NativeOCRDirectionGeometry.intersectionArea(boxes[index].polygon,NativeOCRDirectionAdapters.support(effect)) > 0
                }
                if NativeOCRDirectionGeometry.enabled("rfOverlap") {
                    return NativeOCRDirectionGeometry.intersectionArea(boxes[index].polygon, effect.sourceBounds) > 0
                }
                return originalBounds[index]?.intersects(effect.sourceBounds) == true
            }
        }
        for text in texts.sorted(by: { $0.queryID < $1.queryID }) {
            let members = boxes.indices.filter { index in
                guard eligible?.contains(index) != false, boxes[index].score >= 0.25, originalBounds[index] != nil,
                      detectorCoverage(index, text.sourceBounds) >= 0.6 else { return false }
                return !overlapsEffect(index)
            }
            supported.formUnion(members)
            stronglySupported.formUnion(members.filter { index in
                return boxes[index].score >= 0.5 && detectorCoverage(index, text.sourceBounds) >= 0.9
            })
            let vertical = members.filter { index in
                guard includeGroups, !skipGroups.contains(text.queryID), let box = bounds(boxes[index]) else { return false }
                return box.height >= box.width * 1.2 && !grouped.contains(index)
            }.sorted { bounds(boxes[$0])!.midX < bounds(boxes[$1])!.midX }
            for head in vertical {
                guard !grouped.contains(head), let anchor = bounds(boxes[head]) else { continue }
                let lane = vertical.filter { index in
                    guard !grouped.contains(index), let box = bounds(boxes[index]) else { return false }
                    return abs(box.midX - anchor.midX) <= min(box.width, anchor.width) * 0.3 &&
                        max(box.width, anchor.width) <= min(box.width, anchor.width) * 1.7
                }.sorted { bounds(boxes[$0])!.minY < bounds(boxes[$1])!.minY }
                guard (2...5).contains(lane.count) else { continue }
                let rectangles = lane.map { bounds(boxes[$0])! }
                guard zip(lane, lane.dropFirst()).allSatisfy({ firstIndex, secondIndex in
                    let first = bounds(boxes[firstIndex])!, second = bounds(boxes[secondIndex])!
                    let gap = second.minY-first.maxY
                    // Projected envelopes can overlap at a slanted touching
                    // edge even when the physical DB quads do not overlap.
                    let contact = allowProjectedContact && gap >= -min(first.width,second.width)*0.15 &&
                        NativeOCRDirectionGeometry.intersectionArea(boxes[firstIndex].polygon,boxes[secondIndex].polygon)
                            <= min(NativeOCRDirectionGeometry.area(boxes[firstIndex].polygon),
                                   NativeOCRDirectionGeometry.area(boxes[secondIndex].polygon))*0.05
                    return (gap >= 0 || contact) && gap <= max(first.width, second.width) * 1.2
                }) else { continue }
                let union = rectangles.reduce(CGRect.null) { $0.union($1) }
                guard NativeOCRDirectionAdapters.coverage(corners(union),by:text) >= 0.9,
                      union.height >= union.width * 2,
                      !effects.contains(where: { NativeOCRDirectionGeometry.intersectionArea(corners(union),NativeOCRDirectionAdapters.support($0)) > 0 }) else { continue }
                let polygon = [CGPoint(x: union.minX, y: union.minY), CGPoint(x: union.maxX, y: union.minY),
                               CGPoint(x: union.maxX, y: union.maxY), CGPoint(x: union.minX, y: union.maxY)]
                let index = augmented.count
                augmented.append(.init(polygon: polygon, score: lane.map { boxes[$0].score }.min() ?? 0,
                    erasurePolygons: lane.flatMap { boxes[$0].erasurePolygons }))
                groups.append(.init(index: index, members: lane,
                    evidence: lane.compactMap { boxes[$0].detectorSeedEvidence }))
                supported.insert(index)
                grouped.formUnion(lane)
            }
        }
        // A weaker RF text query is useful only with an independently strong DB
        // box and near-complete geometric agreement. It never creates a box.
        for text in layout.primitives where text.semanticClass == .text &&
            text.confidence >= 0.25 && text.confidence < 0.8 && canvas.contains(text.sourceBounds) {
            for index in boxes.indices where boxes[index].score >= 0.6 {
                guard originalBounds[index] != nil, detectorCoverage(index, text.sourceBounds) >= 0.75,
                      !overlapsEffect(index) else { continue }
                supported.insert(index)
            }
        }
        if let probability, probability.sourceWidth == width, probability.sourceHeight == height,
           probability.width == probability.resizedWidth, probability.height == probability.resizedHeight,
           probability.region == CGRect(x: 0, y: 0, width: probability.width, height: probability.height),
           probability.values.count == probability.width * probability.height,
           pixelThreshold.isFinite, (0...1).contains(pixelThreshold) {
            for text in layout.primitives where text.semanticClass == .text && text.confidence >= 0.55 &&
                includeMissing && !skipMissing.contains(text.queryID) &&
                canvas.contains(text.sourceBounds) && text.sourceBounds.height >= text.sourceBounds.width * 2 {
                let peers = boxes.indices.compactMap { index -> CGRect? in
                    guard let box = originalBounds[index], box.height >= box.width * 2,
                          text.sourceBounds.intersects(box) else { return nil }
                    return box
                }
                guard !peers.isEmpty, augmented.count < 256 else { continue }
                let safeBottom = effects.filter { effect in
                    effect.sourceBounds.maxX > text.sourceBounds.minX &&
                        effect.sourceBounds.minX < text.sourceBounds.maxX &&
                        effect.sourceBounds.minY > text.sourceBounds.minY &&
                        effect.sourceBounds.minY < text.sourceBounds.maxY
                }.map { $0.sourceBounds.minY }.min() ?? text.sourceBounds.maxY
                guard safeBottom - text.sourceBounds.minY >= text.sourceBounds.width * 2 else { continue }
                let scaleX = CGFloat(probability.width) / CGFloat(width)
                let scaleY = CGFloat(probability.height) / CGFloat(height)
                let x0 = max(0, Int(floor(text.sourceBounds.minX * scaleX)))
                let x1 = min(probability.width, Int(ceil(text.sourceBounds.maxX * scaleX)))
                let y0 = max(0, Int(floor(text.sourceBounds.minY * scaleY)))
                let y1 = min(probability.height, Int(floor(safeBottom * scaleY)))
                guard x1 > x0, y1 > y0, (x1 - x0) * (y1 - y0) <= 262_144 else { continue }
                var columns = [Int](repeating: 0, count: x1 - x0)
                for y in y0..<y1 {
                    let sourceY = (CGFloat(y) + 0.5) / scaleY
                    let rowKeepouts = originalBounds.compactMap { box -> CGRect? in
                        guard let box, box.minY <= sourceY, sourceY < box.maxY else { return nil }
                        return box
                    }
                    for x in x0..<x1 {
                        let sourceX = (CGFloat(x) + 0.5) / scaleX
                        guard !rowKeepouts.contains(where: { $0.minX <= sourceX && sourceX < $0.maxX }) else { continue }
                        if Double(probability.values[y * probability.width + x]) >= pixelThreshold {
                            columns[x - x0] += 1
                        }
                    }
                }
                guard let peak = columns.max(), peak >= (y1 - y0) / 2 else { continue }
                let strong = columns.indices.filter { columns[$0] >= peak / 2 }
                guard let first = strong.first, let last = strong.last,
                      last - first + 1 <= (x1 - x0) / 2 else { continue }
                let medianWidth = peers.map(\.width).sorted()[peers.count / 2]
                let centerX = (CGFloat(x0 + first + x0 + last + 1) / 2) / scaleX
                let candidate = CGRect(x: centerX - medianWidth / 2,
                    y: CGFloat(y0) / scaleY, width: medianWidth,
                    height: CGFloat(y1 - y0) / scaleY).intersection(canvas)
                guard !candidate.isNull, candidate.width >= medianWidth * 0.9,
                      !originalBounds.contains(where: { $0?.intersects(candidate) == true }),
                      !augmented.contains(where: { bounds($0)?.intersects(candidate) == true }) else { continue }
                let polygon = [CGPoint(x: candidate.minX, y: candidate.minY),
                    CGPoint(x: candidate.maxX, y: candidate.minY),
                    CGPoint(x: candidate.maxX, y: candidate.maxY),
                    CGPoint(x: candidate.minX, y: candidate.maxY)]
                let index = augmented.count
                augmented.append(.init(polygon: polygon, score: Double(text.confidence)))
                supported.insert(index)
            }
        }
        // If DB's wide box would be read horizontally but a high-confidence RF
        // text scope inside it is a vertical column, add that narrower ORIGINAL
        // pixel crop to the same first recognizer call. RF never supplies ink or
        // an erasure mask; DB remains the only detector evidence.
        for text in texts.sorted(by: { $0.queryID < $1.queryID }) where text.confidence >= 0.85 &&
            includeNarrow && !skipNarrow.contains(text.queryID) {
            let scope = text.sourceBounds.integral
            guard scope.height >= scope.width * 1.6,
                  !effects.contains(where: { $0.sourceBounds.intersects(scope) }) else { continue }
            let parents = boxes.indices.filter { index in
                guard boxes[index].score >= 0.4, let box = bounds(boxes[index]),
                      box.height < box.width * 1.5,
                      coverage(scope, box) >= 0.9,
                      coverage(box, scope) >= 0.3,
                      coverage(box, scope) <= 0.6 else { return false }
                return !refinedCrops.contains(where: { $0.parent == index })
            }
            guard parents.count == 1, refinedCrops.count < 8 else { continue }
            let parent = parents[0], index = augmented.count
            let polygon = [CGPoint(x: scope.minX, y: scope.minY), CGPoint(x: scope.maxX, y: scope.minY),
                           CGPoint(x: scope.maxX, y: scope.maxY), CGPoint(x: scope.minX, y: scope.maxY)]
            augmented.append(.init(polygon: polygon, score: boxes[parent].score,
                detectorSeedEvidence: boxes[parent].detectorSeedEvidence))
            refinedCrops.append(.init(index: index, parent: parent))
            supported.insert(index)
            stronglySupported.insert(index)
        }
        return .init(boxes: augmented, supported: supported,
            stronglySupported: stronglySupported, groups: groups, refinedCrops: refinedCrops)
    }

    /// First-batch sampling only. A narrow RF box must include
    /// every contrasting original pixel in the DB support, plus context. A
    /// nonuniform border or ink touching DB's boundary vetoes the refinement.
    /// Detection, erasure, confidence and decoded text are not modified here.
    static func completeSupportSampling(box: NativeCoreMLDetectionBox,
                                        boxes: [NativeCoreMLDetectionBox],
                                        layout: NativeRFDETRLayoutResult?,
                                        frame: NativeOCRRGBAFrame) -> [CGPoint]? {
        guard box.recognitionPolygon == nil, box.polygon.count == 4,
              let layout, layout.sourceWidth == frame.width, layout.sourceHeight == frame.height else { return nil }
        if oriented("WIDTH") {
            return orientedCompleteSupportSampling(box:box,boxes:boxes,layout:layout,frame:frame)
        }
        return axisCompleteSupportSampling(box:box,boxes:boxes,layout:layout,frame:frame)
    }

    /// Rectified kernel; world-coordinate use is an explicit legacy control.
    static func axisCompleteSupportSampling(box: NativeCoreMLDetectionBox,
                                            boxes: [NativeCoreMLDetectionBox],
                                            layout: NativeRFDETRLayoutResult,
                                            frame: NativeOCRRGBAFrame) -> [CGPoint]? {
        func bounds(_ polygon: [CGPoint]) -> CGRect {
            polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let db = bounds(box.polygon)
        let upright = db.height >= db.width * 2 && box.polygon.allSatisfy { point in
            (abs(point.x - db.minX) < 0.001 || abs(point.x - db.maxX) < 0.001) &&
                (abs(point.y - db.minY) < 0.001 || abs(point.y - db.maxY) < 0.001)
        }
        guard upright else { return nil }
        // This estimator measures support in source axes. It cannot replace a
        // slanted quadrilateral without changing the recognizer's reading axis.
        // Keep such original quads intact rather than flattening their glyphs.
        guard box.polygon.allSatisfy({ point in
            (abs(point.x - db.minX) < 0.001 || abs(point.x - db.maxX) < 0.001) &&
                (abs(point.y - db.minY) < 0.001 || abs(point.y - db.maxY) < 0.001)
        }) else { return nil }
        guard db.width >= 8, db.height >= db.width * 2,
              db.width * db.height <= 500_000,
              db.minX >= 0, db.minY >= 0,
              db.maxX <= CGFloat(frame.width), db.maxY <= CGFloat(frame.height) else { return nil }
        let matches = layout.primitives.filter { primitive in
            let rf = primitive.sourceBounds, overlap = db.intersection(rf)
            guard primitive.semanticClass == .text, primitive.confidence >= 0.25,
                  !overlap.isNull, rf.width >= db.width * 0.5,
                  rf.width < db.width * 0.95,
                  overlap.height >= db.height * 0.9,
                  NativeOCRDirectionGeometry.intersectionArea(box.polygon,NativeOCRDirectionAdapters.support(primitive)) /
                    max(0.000001, NativeOCRDirectionGeometry.area(box.polygon) +
                        NativeOCRDirectionGeometry.area(NativeOCRDirectionAdapters.support(primitive)) -
                        NativeOCRDirectionGeometry.intersectionArea(box.polygon,NativeOCRDirectionAdapters.support(primitive))) >= 0.5
            else { return false }
            return boxes.filter { other in
                NativeOCRDirectionGeometry.intersectionArea(other.polygon,NativeOCRDirectionAdapters.support(primitive)) >=
                    NativeOCRDirectionGeometry.area(other.polygon)*0.3
            }.count == 1
        }
        guard matches.count == 1 else { return nil }
        let x0 = Int(ceil(db.minX)), x1 = Int(floor(db.maxX))
        let y0 = Int(ceil(db.minY)), y1 = Int(floor(db.maxY))
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let offset = y * frame.bytesPerRow + x * 4
            return (0..<3).map { Int(frame.bytes[offset + $0]) }
        }
        var border: [[Int]] = []
        for x in x0..<x1 { border.append(rgb(x, y0)); border.append(rgb(x, y1 - 1)) }
        for y in y0..<y1 { border.append(rgb(x0, y)); border.append(rgb(x1 - 1, y)) }
        let background = (0..<3).map { channel in border.map { $0[channel] }.sorted()[border.count / 2] }
        func distance(_ pixel: [Int]) -> Int {
            zip(pixel, background).map { abs($0 - $1) }.max() ?? 0
        }
        guard border.allSatisfy({ distance($0) <= 12 }) else { return nil }
        var left = x1, right = x0, inkCount = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let offset = y * frame.bytesPerRow + x * 4
                let contrast = max(abs(Int(frame.bytes[offset]) - background[0]),
                    abs(Int(frame.bytes[offset + 1]) - background[1]),
                    abs(Int(frame.bytes[offset + 2]) - background[2]))
                guard contrast > 40 else { continue }
                left = min(left, x); right = max(right, x + 1); inkCount += 1
            }
        }
        guard inkCount >= 16, left > x0, right < x1 else { return nil }
        let rf = matches[0].sourceBounds
        let padding: CGFloat = 2
        let minX = max(db.minX, min(CGFloat(left), rf.minX) - padding)
        let maxX = min(db.maxX, max(CGFloat(right), rf.maxX) + padding)
        guard maxX - minX < db.width - 1 else { return nil }
        return [CGPoint(x: minX, y: db.minY), CGPoint(x: maxX, y: db.minY),
                CGPoint(x: maxX, y: db.maxY), CGPoint(x: minX, y: db.maxY)]
    }

    /// Measure the same border/ink evidence in a one-pixel local-axis raster.
    /// Only the DB crop is sampled, never an extra model image or a page ID.
    static func orientedCompleteSupportSampling(box: NativeCoreMLDetectionBox,
                                                boxes: [NativeCoreMLDetectionBox],
                                                layout: NativeRFDETRLayoutResult,
                                                frame: NativeOCRRGBAFrame) -> [CGPoint]? {
        guard let local = AxisFrame(box.polygon), local.rect.width >= 8,
              local.rect.height >= local.rect.width * 2,
              local.rect.width * local.rect.height <= 500_000,
              frame.bytesPerRow >= frame.width * 4,
              frame.bytes.count >= frame.bytesPerRow * frame.height else { return nil }
        let width = Int(ceil(local.rect.width)) + 2, height = Int(ceil(local.rect.height)) + 2
        let shift = CGPoint(x: 1 - local.rect.minX, y: 1 - local.rect.minY)
        func project(_ p: CGPoint) -> CGPoint {
            let q = local.project(p)
            return CGPoint(x: q.x + shift.x, y: q.y + shift.y)
        }
        func restore(_ p: CGPoint) -> CGPoint {
            local.restore(CGPoint(x: p.x - shift.x, y: p.y - shift.y))
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let point = restore(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
            let xx = Int(floor(point.x)), yy = Int(floor(point.y))
            guard xx >= 0, yy >= 0, xx < frame.width, yy < frame.height else { return nil }
            let src = yy * frame.bytesPerRow + xx * 4, dst = (y * width + x) * 4
            for channel in 0..<4 { bytes[dst + channel] = frame.bytes[src + channel] }
        } }
        let db = CGRect(x: 1, y: 1, width: local.rect.width, height: local.rect.height)
        let transformed = NativeCoreMLDetectionBox(polygon: corners(db), score: box.score)
        let peers = boxes.map { NativeCoreMLDetectionBox(polygon: $0.polygon.map(project), score: $0.score) }
        let primitives = layout.primitives.map { primitive -> NativeRFDETRLayoutPrimitive in
            let bounds = corners(primitive.sourceBounds).map(project).reduce(CGRect.null) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
            var transformed = NativeRFDETRLayoutPrimitive(queryID: primitive.queryID, semanticClass: primitive.semanticClass,
                confidence: primitive.confidence, normalizedBounds: CGRect(x: bounds.minX / CGFloat(width),
                    y: bounds.minY / CGFloat(height), width: bounds.width / CGFloat(width), height: bounds.height / CGFloat(height)),
                sourceBounds: bounds, mask: nil)
            transformed.supportPolygon = NativeOCRDirectionAdapters.support(primitive).map(project)
            return transformed
        }
        let transformedLayout = NativeRFDETRLayoutResult(imageIdentity: layout.imageIdentity,
            sourceWidth: width, sourceHeight: height, primitives: primitives,
            maskQueriesOmittedByBudget: layout.maskQueriesOmittedByBudget,
            preprocessingMilliseconds: 0, modelMilliseconds: 0, decodeMilliseconds: 0,
            computeUnits: layout.computeUnits, fromCache: layout.fromCache)
        guard let sampled = NativeOCRRGBAFrame(width: width, height: height, bytesPerRow: width * 4, bytes: bytes) else { return nil }
        guard let crop = axisCompleteSupportSampling(box: transformed, boxes: peers,
                layout: transformedLayout, frame: sampled) else { return nil }
        let cropped = crop.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        // Shift the original vertices across their own local axis; retain their
        // along coordinates, vertex order, and any original perspective.
        return box.polygon.map { point in
            var q = project(point)
            q.x = cropped.minX + (q.x - db.minX) / db.width * cropped.width
            return restore(q)
        }
    }

    static func admits(_ read: NativeCoreMLRecognizedRegion, threshold: Double,
                       supported: Set<Int>, stronglySupported: Set<Int>, merged: Set<Int>,
                       dbScore: Double? = nil) -> Bool {
        if read.confidence >= threshold { return true }
        guard read.confidence.isFinite else { return false }
        let letters = read.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        // Punctuation-only lettering has no letters to satisfy the ordinary
        // language gate. Admit the original DB read only when RF independently
        // nominated the same box; this does not grant erasure or translation.
        if letters.isEmpty, !read.text.isEmpty,
           read.text.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) ||
               CharacterSet.symbols.contains($0) }) {
            let singleMark = read.text.unicodeScalars.count == 1
            return supported.contains(read.sourceIndex) &&
                (dbScore ?? 0) >= 0.25 && read.confidence >=
                (singleMark ? supportedRecognitionThreshold : firstPassDecodeFloor)
        }
        guard !letters.isEmpty else { return false }
        if supported.contains(read.sourceIndex) {
            return read.confidence >= (stronglySupported.contains(read.sourceIndex) ?
                stronglySupportedRecognitionThreshold : supportedRecognitionThreshold)
        }
        // DB already nominated this original-pixel column. In the measured
        // first-pass cases, short and wide low-confidence boxes mostly belonged
        // to protected lettering. Preserve only a tall original-pixel column;
        // the downstream source-role filter still decides whether it is painted.
        let bounds = read.polygon.reduce(CGRect.null) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        guard !bounds.isNull, bounds.width > 0,
              bounds.height >= bounds.width * 2 else { return false }
        return dbScore.map { $0 >= 0.25 && read.confidence >= dbRecognitionThreshold } ?? false
    }
}

/// RF + ORIGINAL pixels nominate missing lines, never a new detector pass.
/// Like ClosedColumnNomination and OriginalContextRecovery, sampling is not
/// ownership: original detections are immutable keepouts and RF grants no
/// source/merge/erasure authority. No model, cache, label or provider access.
@available(iOS 18.0, *)
enum NativeOCRRFGapRecovery {
    static let cacheVersion = "rf-original-gap-paired-v3-db-fallback"
    static var runtimeEnabled: Bool { ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_GAP_RECOVERY"] == "1" }

    struct Proposal: Sendable {
        let sourceIdentity: String
        let textQueryID: Int
        let maskQueryID: Int?
        let nominationEvidence: String
        let componentDBMeans: [Double]
        let original: NativeCoreMLRecognitionRegion
        let crops: [NativeCoreMLRecognitionRegion]
        let measuredComponentBounds: [CGRect]
        let measuredInkPixels: Int
        let admissionThreshold: Double
        var grantsErasureAuthority: Bool { false }
    }

    /// The caller binds each independent recognizer invocation to its actual
    /// immutable source and RF query; strings alone cannot certify a proposal.
    struct BoundRead: Sendable {
        let sourceIdentity: String
        let textQueryID: Int
        let read: NativeCoreMLRecognizedRegion
    }

    /// Unmodified, full-source DB cells from the original-CGImage evidence
    /// store. An absent/partial/stale map never becomes a synthetic RF mask.
    struct SourceProbability: Sendable {
        let sourceIdentity: String
        let sourceWidth: Int
        let sourceHeight: Int
        let width: Int
        let height: Int
        let values: [Float]

        fileprivate func valid(for frame: NativeRFDETRSourceImage, identity: String) -> Bool {
            sourceIdentity == identity && sourceWidth == frame.width && sourceHeight == frame.height &&
                width > 0 && height > 0 && width <= min(2000, sourceWidth) && height <= min(2000, sourceHeight) &&
                values.count == width * height && values.allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
        fileprivate func value(x: Int, y: Int) -> Double {
            Double(values[(y * height / sourceHeight) * width + x * width / sourceWidth])
        }
    }

    /// Keep this receipt beside the packet at the supplemental accepted-source
    /// ingress. The parent must put original + supplemental packets in ONE
    /// accepted-primary table before grouping, preserving old packet ordinals.
    /// Do not call bindingPrimary on supplemental lines alone (different table).
    struct Admission: Sendable {
        let sourceIdentity: String
        let textQueryID: Int
        let maskQueryID: Int?
        let sourceIndex: Int
        let packet: NativeOCRAcceptedSource.Packet
    }

    struct SourceIngress: Sendable {
        let lines: [NativeCoreMLOCRLine]
        let previousOperationID: UUID?
        let table: NativeOCRAcceptedSource.PacketTable
        let originalPacketCount: Int
        let admissions: [Admission]
    }

    /// Direct seam for the original RGBA frame. Composite premultiplied RGBA
    /// on white exactly as RF source decode does; row padding is excluded.
    /// A colour-space/canvas disagreement fails the RGB identity check below.
    /// Prefer the already-decoded RF RGB frame when available to avoid a copy.
    static func proposals(auxiliaryLayout layout: NativeRFDETRLayoutResult,
                          frame: NativeOCRRGBAFrame, detected: [CGRect], accepted: [CGRect],
                          firstSourceIndex: Int, admissionThreshold: Double,
                          sourceProbability: SourceProbability? = nil,
                          audit: (([String: Int]) -> Void)? = nil) -> [Proposal] {
        guard frame.width == layout.sourceWidth, frame.height == layout.sourceHeight,
              frame.width <= 16_384, frame.height <= 16_384,
              frame.width <= 16_777_216 / frame.height else { audit?(["invalidRGBAFrame": 1, "proposedCount": 0]); return [] }
        var rgb = Data(count: frame.width * frame.height * 3)
        rgb.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            for y in 0..<frame.height { for x in 0..<frame.width {
                let source = y * frame.bytesPerRow + x * 4, target = (y * frame.width + x) * 3
                let white = 255 - Int(frame.bytes[source + 3])
                for c in 0..<3 { output[target + c] = UInt8(min(255, Int(frame.bytes[source + c]) + white)) }
            } }
        }
        guard let source = try? NativeRFDETRSourceImage(width: frame.width, height: frame.height, rgb: rgb) else {
            audit?(["invalidRGBConversion": 1, "proposedCount": 0]); return []
        }
        return proposals(auxiliaryLayout: layout, frame: source, detected: detected, accepted: accepted,
                          firstSourceIndex: firstSourceIndex, admissionThreshold: admissionThreshold,
                          sourceProbability: sourceProbability, audit: audit)
    }

    static func proposals(auxiliaryLayout layout: NativeRFDETRLayoutResult,
                          frame: NativeRFDETRSourceImage, detected: [CGRect], accepted: [CGRect],
                          firstSourceIndex: Int, admissionThreshold: Double,
                          sourceProbability: SourceProbability? = nil,
                          audit: (([String: Int]) -> Void)? = nil) -> [Proposal] {
        // Synchronous, exactly once, even on early return. Counts are gate
        // events across mask/DB passes, not unique sources or accuracy metrics.
        var counts = ["proposedCount": 0, "detectorKeepoutRects": detected.count, "acceptedKeepoutRects": accepted.count]
        defer { audit?(counts) }
        func note(_ key: String, _ amount: Int = 1) { counts[key, default: 0] += amount }
        let canvas = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let keepouts = detected + accepted
        guard layout.sourceWidth == frame.width, layout.sourceHeight == frame.height,
              layout.primitives.count <= 512, keepouts.count <= 1024,
              keepouts.allSatisfy({ valid($0) && canvas.contains($0) }),
              firstSourceIndex >= 0, firstSourceIndex <= Int.max - 16,
              admissionThreshold.isFinite, (0.5...1).contains(admissionThreshold),
              layout.imageIdentity == frame.identity else { note("invalidInputOrIdentity"); return [] }
        let primitives = layout.primitives
        guard primitives.allSatisfy({ $0.queryID >= 0 && valid($0.sourceBounds) &&
            $0.confidence.isFinite && (0...1).contains($0.confidence) }) else { note("invalidRFPrimitive"); return [] }
        let texts = primitives.filter { $0.semanticClass == .text && $0.confidence >= 0.55 }
            .sorted { $0.confidence == $1.confidence ? $0.queryID < $1.queryID : $0.confidence > $1.confidence }
        note("rfTextPrimitives", primitives.filter { $0.semanticClass == .text }.count)
        note("eligibleText", texts.count)
        note("textBelowConfidence", primitives.filter { $0.semanticClass == .text && $0.confidence < 0.55 }.count)
        if texts.isEmpty { note("noText") }
        note("textLimitSkipped", max(0, texts.count - 32))
        let maskSources = primitives.filter { ($0.semanticClass == .balloon || $0.semanticClass == .text) &&
            $0.confidence >= 0.55 && $0.mask != nil }
        note("maskLimitSkipped", max(0, maskSources.count - 32))
        let maskOwners = maskSources.prefix(32).filter {
            let valid = validMask($0, frame: frame)
            if !valid { note("invalidMask") }
            return valid
        }
        let probability = sourceProbability.flatMap { $0.valid(for: frame, identity: layout.imageIdentity) ? $0 : nil }
        if probability == nil { note(sourceProbability == nil ? "noDB" : "invalidDB") }
        var output: [Proposal] = [], scanned = 0, sampled = 0
        // Existing mask-supported nominations consume the shared budget first.
        for requireMask in [true, false] {
            if !requireMask && probability == nil { note("fallbackTextsWithoutDB", min(32, texts.count)); continue }
            for text in texts.prefix(32) {
                guard output.count < 8 else { note("proposalBudget"); break }
                let roi = text.sourceBounds.integral.intersection(canvas)
                guard valid(roi) else { note("invalidROIGeometry"); continue }
                guard roi.width >= 6, roi.height >= 6 else { note("roiTooSmall"); continue }
                guard roi.width * roi.height <= 262_144 else { note("roiPixelBudget"); continue }
                guard scanned + Int(roi.width * roi.height) <= 1_048_576 else { note("pageScanBudget"); continue }
                // Text masks are normally absent. Reuse the existing containing
                // balloon mask, never fabricate mask support from a text bbox.
                let maskOwner = maskOwners.filter {
                    ($0.semanticClass == .balloon || ($0.semanticClass == .text && $0.queryID == text.queryID)) &&
                    $0.sourceBounds.contains(roi)
                }.sorted { $0.confidence == $1.confidence ? $0.queryID < $1.queryID : $0.confidence > $1.confidence }.first
                if requireMask && maskOwner == nil { note("noMask"); continue }
                if !requireMask && output.contains(where: { $0.textQueryID == text.queryID }) { note("alreadyNominatedQuery"); continue }
                scanned += Int(roi.width * roi.height)
                note(requireMask ? "maskROIScans" : "dbROIScans")
                let components = inkComponents(frame: frame, roi: roi, mask: requireMask ? maskOwner?.mask : nil,
                    probability: requireMask ? nil : probability, keepouts: keepouts, detectedCount: detected.count, diagnostics: &counts)
                guard (2...128).contains(components.count) else { note("insufficientIndependentComponents"); continue }
                // Same repeated-line geometry principle as closed column recovery;
                // every component remains tied to measured original source pixels.
                for vertical in [true, false] {
                    for lane in lanes(components, vertical: vertical) where output.count < 8 {
                        note("lanesExamined")
                        guard (2...32).contains(lane.count) else { note("laneComponentCount"); continue }
                        let ordered = lane.sorted { vertical ? $0.bounds.midY < $1.bounds.midY : $0.bounds.midX < $1.bounds.midX }
                        let widths = ordered.map { vertical ? $0.bounds.width : $0.bounds.height }
                        let lengths = ordered.map { vertical ? $0.bounds.height : $0.bounds.width }
                        let thickness = widths.sorted()[widths.count / 2]
                        guard widths.max()! <= widths.min()! * 2.5,
                              lengths.max()! <= lengths.min()! * 3 else { note("laneSizeConsistency"); continue }
                        guard ordered.indices.dropFirst().allSatisfy({ i in
                                  let a = ordered[i - 1].bounds, b = ordered[i].bounds
                                  let gap = vertical ? b.minY - a.maxY : b.minX - a.maxX
                                  return gap >= 0 && gap <= thickness * 1.5
                              }) else { note("laneGap"); continue }
                        let bounds = lane.reduce(CGRect.null) { $0.union($1.bounds) }
                        guard (vertical ? bounds.height : bounds.width) >= thickness * 2 else { note("laneLength"); continue }
                        guard !keepouts.contains(where: { $0.intersects(bounds) }) else {
                            note(detected.contains(where: { $0.intersects(bounds) }) ? "laneDetectorKeepout" : "laneAcceptedKeepout"); continue
                        }
                        guard !output.contains(where: { $0.original.polygonBounds.intersects(bounds) }) else { note("duplicateProposal"); continue }
                        // Conflicting RF-SFX plus actual source ink is ambiguous,
                        // even when RF text confidence is higher. Abstain.
                        guard !primitives.contains(where: { $0.semanticClass == .soundEffect &&
                            $0.confidence >= 0.35 && $0.sourceBounds.intersects(bounds) }) else { note("laneSFXConflict"); continue }
                        var crops: [NativeCoreMLRecognitionRegion] = []
                        let index = firstSourceIndex + output.count
                        for fraction: CGFloat in [0.12, 0.24] {
                            let crop = bounds.insetBy(dx: -max(1, thickness * fraction),
                                                      dy: -max(1, thickness * fraction)).integral.intersection(canvas)
                            guard valid(crop) else { note("invalidCropGeometry"); break }
                            guard roi.contains(crop) else { note("cropOutsideRFBounds"); break }
                            guard !keepouts.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).intersects(crop) }) else {
                                note(detected.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).intersects(crop) })
                                    ? "cropDetectorKeepout" : "cropAcceptedKeepout"); break
                            }
                            guard !primitives.contains(where: { $0.semanticClass == .soundEffect &&
                                $0.confidence >= 0.35 && $0.sourceBounds.intersects(crop) }) else { note("cropSFXConflict"); break }
                            crops.append(.init(sourceIndex: index, polygon: quad(crop)))
                        }
                        guard crops.count == 2 else { note("incompleteCropPair"); continue }
                        guard crops[0].polygon != crops[1].polygon else { note("identicalCropPair"); continue }
                        let pixels = crops.reduce(0) { $0 + Int($1.polygonBounds.width * $1.polygonBounds.height) }
                        guard sampled + pixels <= 524_288 else { note("recognitionPixelBudget"); continue }
                        sampled += pixels
                        output.append(.init(sourceIdentity: layout.imageIdentity, textQueryID: text.queryID,
                            maskQueryID: requireMask ? maskOwner?.queryID : nil,
                            nominationEvidence: requireMask ? "rf-text-mask-original-components" : "rf-text-db-original-components",
                            componentDBMeans: ordered.compactMap(\.probabilityMean),
                            original: .init(sourceIndex: index, polygon: quad(bounds.insetBy(dx: -1, dy: -1))),
                            crops: crops, measuredComponentBounds: ordered.map(\.bounds),
                            measuredInkPixels: ordered.reduce(0) { $0 + $1.pixels }, admissionThreshold: admissionThreshold))
                    }
                }
            }
        }
        counts["proposedCount"] = output.count
        counts["scannedPixels"] = scanned
        counts["recognitionCropPixels"] = sampled
        return output
    }

    /// Independent full-span reads must agree exactly and pass the unchanged
    /// caller threshold. Returns measured source geometry, never padded crops.
    static func accepted(proposal: Proposal, reads: [BoundRead], expectedSourceIdentity: String) -> NativeCoreMLRecognizedRegion? {
        guard proposal.sourceIdentity == expectedSourceIdentity, reads.count == 2, proposal.crops.count == 2 else { return nil }
        for i in reads.indices {
            let bound = reads[i], read = bound.read
            guard bound.sourceIdentity == expectedSourceIdentity, bound.textQueryID == proposal.textQueryID,
                  read.sourceIndex == proposal.crops[i].sourceIndex, read.polygon == proposal.crops[i].polygon,
                  read.confidence.isFinite, (proposal.admissionThreshold...1).contains(read.confidence),
                  !read.text.isEmpty, read.text.count <= 256, read.text == read.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  read.text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }),
                  !read.tokenObservations.isEmpty,
                  read.tokenObservations.map(\.text).joined() == read.text,
                  read.tokenObservations.allSatisfy({ $0.confidence.isFinite && (0.9...1).contains($0.confidence) }) else { return nil }
        }
        guard reads[0].read.text == reads[1].read.text else { return nil }
        return .init(sourceIndex: proposal.original.sourceIndex, polygon: proposal.original.polygon,
                     text: reads[0].read.text, confidence: min(reads[0].read.confidence, reads[1].read.confidence),
                     tokenObservations: reads[0].read.tokenObservations)
    }

    /// Independently resample the ORIGINAL pixels after successful recognition.
    /// Only uniform-surface, complete measured components qualify. Row-span
    /// rectangles cover observed contrasting pixels exactly (including >=8/255
    /// antialias fringes); neither RF masks nor component bounding boxes erase.
    /// The normal merger retains at most64 erasure polygons, so larger masks
    /// abstain instead of silently losing part of the accepted glyph coverage.
    static func sourceSupportedErasurePolygons(proposal: Proposal, frame: NativeRFDETRSourceImage) -> [[CGPoint]]? {
        let roi = proposal.original.polygonBounds
        let canvas = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        guard proposal.sourceIdentity == frame.identity, valid(roi), roi == roi.integral, canvas.contains(roi),
              roi.width * roi.height <= 262_144, !proposal.measuredComponentBounds.isEmpty,
              proposal.measuredComponentBounds.count <= 32 else { return nil }
        let x0 = Int(roi.minX), y0 = Int(roi.minY), w = Int(roi.width), h = Int(roi.height)
        func value(_ x: Int, _ y: Int) -> Int {
            let i = (y * frame.width + x) * 3
            return (Int(frame.rgb[i]) * 77 + Int(frame.rgb[i + 1]) * 150 + Int(frame.rgb[i + 2]) * 29) / 256
        }
        var ring: [Int] = []
        for x in x0..<(x0 + w) { ring.append(value(x, y0)); ring.append(value(x, y0 + h - 1)) }
        for y in y0..<(y0 + h) { ring.append(value(x0, y)); ring.append(value(x0 + w - 1, y)) }
        ring.sort()
        let background = ring[ring.count / 2]
        // Any visible edge ink means unknown continuation outside this domain.
        guard ring.allSatisfy({ abs($0 - background) < 8 }) else { return nil }
        var rectangles: [CGRect] = [], active: [String: Int] = [:], strong = 0
        var pixels = [UInt8](repeating: 0, count: w * h)
        var strongBounds = [CGRect](repeating: .null, count: proposal.measuredComponentBounds.count)
        for y in y0..<(y0 + h) {
            var spans: [(Int, Int)] = [], start: Int?
            for x in x0..<(x0 + w) {
                let contrast = abs(value(x, y) - background)
                if contrast >= 8 {
                    pixels[(y - y0) * w + x - x0] = 1
                    let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    guard proposal.measuredComponentBounds.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) })
                    else { return nil }
                    if contrast >= 48 {
                        guard let i = proposal.measuredComponentBounds.firstIndex(where: { $0.contains(point) }) else { return nil }
                        strong += 1
                        strongBounds[i] = strongBounds[i].union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                    if start == nil { start = x }
                } else if let first = start { spans.append((first, x)); start = nil }
            }
            if let first = start { spans.append((first, x0 + w)) }
            var next: [String: Int] = [:]
            for (left, right) in spans {
                let key = "\(left):\(right)"
                if let i = active[key] {
                    rectangles[i].size.height += 1; next[key] = i
                } else {
                    guard rectangles.count < 8192 else { return nil }
                    next[key] = rectangles.count
                    rectangles.append(CGRect(x: left, y: y, width: right - left, height: 1))
                }
            }
            active = next
        }
        guard strong == proposal.measuredInkPixels, strongBounds == proposal.measuredComponentBounds, !rectangles.isEmpty else { return nil }
        if rectangles.count <= 64 { return rectangles.map(quad) }
        return exactContours(pixels: pixels, width: w, height: h, origin: CGPoint(x: x0, y: y0), rectangles: rectangles)
    }

    /// Trace original pixel-cell edges, with foreground on the right. No
    /// simplification/convex hull: every retained corner is an exact pixel edge.
    /// Counters remain holes by retaining exact spans for that component only;
    /// a simple polygon cannot express subtraction in the downstream union.
    private static func exactContours(pixels: [UInt8], width: Int, height: Int,
                                      origin: CGPoint, rectangles: [CGRect]) -> [[CGPoint]]? {
        let stride = width + 1
        var edges = [UInt8](repeating: 0, count: stride * (height + 1)), remaining = 0
        func ink(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && pixels[y * width + x] != 0
        }
        func add(_ x: Int, _ y: Int, _ direction: Int) {
            edges[y * stride + x] |= UInt8(1 << direction); remaining += 1
        }
        for y in 0..<height { for x in 0..<width where ink(x, y) {
            if !ink(x, y - 1) { add(x, y, 0) }
            if !ink(x + 1, y) { add(x + 1, y, 1) }
            if !ink(x, y + 1) { add(x + 1, y + 1, 2) }
            if !ink(x - 1, y) { add(x, y + 1, 3) }
        } }
        guard remaining <= 1_048_576 else { return nil }
        let dx = [1, 0, -1, 0], dy = [0, 1, 0, -1]
        var rings: [([CGPoint], CGFloat)] = []
        for start in edges.indices {
            while edges[start] != 0 {
                guard rings.count < 128 else { return nil }
                var current = start, vertices: [CGPoint] = []
                var direction = (0..<4).first { edges[start] & UInt8(1 << $0) != 0 }!
                repeat {
                    guard remaining > 0, vertices.count <= 131_072,
                          edges[current] & UInt8(1 << direction) != 0 else { return nil }
                    let x = current % stride, y = current / stride
                    vertices.append(CGPoint(x: origin.x + CGFloat(x), y: origin.y + CGFloat(y)))
                    edges[current] &= ~UInt8(1 << direction); remaining -= 1
                    let nx = x + dx[direction], ny = y + dy[direction]
                    guard nx >= 0, ny >= 0, nx <= width, ny <= height else { return nil }
                    current = ny * stride + nx
                    if current == start { break }
                    let turns = [(direction + 1) % 4, direction, (direction + 3) % 4, (direction + 2) % 4]
                    guard let next = turns.first(where: { edges[current] & UInt8(1 << $0) != 0 }) else { return nil }
                    direction = next
                } while current != start
                guard vertices.count >= 4 else { return nil }
                let corners = vertices.indices.compactMap { i -> CGPoint? in
                    let a = vertices[(i + vertices.count - 1) % vertices.count], b = vertices[i]
                    let c = vertices[(i + 1) % vertices.count]
                    return (a.x == b.x && b.x == c.x) || (a.y == b.y && b.y == c.y) ? nil : b
                }
                guard corners.count >= 4, corners.count <= 4096 else { return nil }
                let area = corners.indices.reduce(CGFloat.zero) { sum, i in
                    let a = corners[i], b = corners[(i + 1) % corners.count]
                    return sum + a.x * b.y - b.x * a.y
                }
                guard area != 0 else { return nil }
                rings.append((corners, area))
            }
        }
        guard remaining == 0 else { return nil }
        func contains(_ point: CGPoint, _ polygon: [CGPoint]) -> Bool {
            var inside = false
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            return inside
        }
        let holes = rings.filter { $0.1 < 0 }
        var output: [[CGPoint]] = []
        for (polygon, area) in rings where area > 0 {
            // Skip counter rings: they are represented by exact foreground
            // spans of their exterior, never filled as positive polygons.
            if polygon.count <= 32 && !holes.contains(where: { contains($0.0[0], polygon) }) {
                output.append(polygon)
            } else {
                output += rectangles.filter { contains(CGPoint(x: $0.minX + 0.5, y: $0.minY + 0.5), polygon) }.map(quad)
            }
            guard output.count <= 64 else { return nil }
        }
        return output.isEmpty ? nil : output
    }

    static func recordAudit(_ stage: String, fields: [String: Any] = [:]) {
        guard runtimeEnabled, let data = try? JSONSerialization.data(withJSONObject:
            ["stage": stage, "value": fields], options: [.sortedKeys]), data.count <= 16_384 else { return }
        var line = Data("ocr_rf_gap ".utf8)
        line.append(data); line.append(10)
        FileHandle.standardError.write(line)
    }

    /// Explicit mask ingress: pass only polygons independently measured and
    /// verified on THIS original source after paired recognition. Empty/missing
    /// masks abstain; RF masks, crop rectangles and component boxes are never
    /// substituted. No DB record is invented for an initially undetected line.
    static func acceptedPacket(proposal: Proposal, reads: [BoundRead], expectedSourceIdentity: String,
                               verifiedErasurePolygons: [[CGPoint]], orientation: BrowserOCRSourceOrientation) -> Admission? {
        guard let read = accepted(proposal: proposal, reads: reads, expectedSourceIdentity: expectedSourceIdentity),
              !verifiedErasurePolygons.isEmpty, verifiedErasurePolygons.count <= 256,
              verifiedErasurePolygons.reduce(0, { $0 + $1.count }) <= 8192 else { return nil }
        let bounds = proposal.original.polygonBounds
        for polygon in verifiedErasurePolygons {
            guard polygon.count >= 3, polygon.count <= 4096,
                  polygon.allSatisfy({ p in p.x.isFinite && p.y.isFinite && p.x >= bounds.minX &&
                      p.x <= bounds.maxX && p.y >= bounds.minY && p.y <= bounds.maxY }) else { return nil }
            let area = polygon.indices.reduce(CGFloat.zero) { total, i in
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                return total + a.x * b.y - b.x * a.y
            }
            guard abs(area) > 0 else { return nil }
        }
        return .init(sourceIdentity: expectedSourceIdentity, textQueryID: proposal.textQueryID,
            maskQueryID: proposal.maskQueryID, sourceIndex: read.sourceIndex,
            packet: .init(polygon: read.polygon, text: read.text, score: read.confidence,
                orientation: orientation, orientationIsEstimated: false, sourceTileBounds: nil,
                erasurePolygons: verifiedErasurePolygons, detectorSeedEvidence: nil))
    }

    /// Supplemental accepted-source ingress AFTER recognition + independent
    /// glyph-mask verification, BEFORE downstream grouping/translation. Copy
    /// the immutable ORIGINAL packet table verbatim; remap all old memberships
    /// to one new operation, preserving body/readings/unknown sets and ordinals.
    /// Rebinding only the new lines would silently break subsequent unions.
    static func appendingAdmissions(_ admissions: [Admission], to existing: [NativeCoreMLOCRLine],
                                    expectedSourceIdentity: String, width: Int, height: Int) -> SourceIngress? {
        guard (1...8).contains(admissions.count), existing.count <= 1024,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              Set(admissions.map(\.sourceIndex)).count == admissions.count,
              admissions.allSatisfy({ $0.sourceIdentity == expectedSourceIdentity &&
                  !$0.packet.erasurePolygons.isEmpty && $0.packet.detectorSeedEvidence == nil }) else { return nil }
        let previous = existing.first?.acceptedSource.membership?.table
        guard existing.isEmpty || previous != nil else { return nil }
        if let previous {
            guard previous.width == width, previous.height == height, previous.packets.count <= 4096,
                  existing.allSatisfy({ line in
                      guard let m = line.acceptedSource.membership else { return false }
                      return m.table === previous && !m.body.isEmpty &&
                          m.body.union(m.readings).union(m.unknownDedup).allSatisfy({ previous.packets.indices.contains($0) })
                  }) else { return nil }
        }
        let originalPackets = previous?.packets ?? []
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        func bounds(_ polygon: [CGPoint]) -> CGRect {
            polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        for (i, admission) in admissions.enumerated() {
            let b = bounds(admission.packet.polygon)
            guard valid(b), canvas.contains(b),
                  !originalPackets.contains(where: { bounds($0.polygon).intersects(b) }),
                  !admissions.prefix(i).contains(where: { bounds($0.packet.polygon).intersects(b) }) else { return nil }
        }
        let table = NativeOCRAcceptedSource.PacketTable(packets: originalPackets + admissions.map(\.packet), width: width, height: height)
        var lines = existing.map { line in
            var output = line
            if let m = line.acceptedSource.membership {
                output.acceptedSource = .init(.init(table: table, body: m.body, readings: m.readings,
                    unknownDedup: m.unknownDedup, hasUntrackedInputs: m.hasUntrackedInputs))
            }
            return output
        }
        for (i, admission) in admissions.enumerated() {
            let packet = admission.packet
            lines.append(.init(polygon: packet.polygon, text: packet.text, score: packet.score,
                orientation: packet.orientation, orientationIsEstimated: packet.orientationIsEstimated,
                sourceTileBounds: packet.sourceTileBounds, erasurePolygons: packet.erasurePolygons,
                detectorSeedEvidence: nil,
                acceptedSource: .init(.init(table: table, body: [originalPackets.count + i], readings: [],
                    unknownDedup: [], hasUntrackedInputs: false))))
        }
        return .init(lines: lines, previousOperationID: previous?.operationID, table: table,
                     originalPacketCount: originalPackets.count, admissions: admissions)
    }

    private struct Component { let bounds: CGRect; let pixels: Int; let probabilityMean: Double? }

    private static func inkComponents(frame: NativeRFDETRSourceImage, roi: CGRect,
                                      mask: NativeRFDETRLayoutMask?, probability: SourceProbability? = nil,
                                      keepouts: [CGRect], detectedCount: Int, diagnostics: inout [String: Int]) -> [Component] {
        func note(_ key: String, _ amount: Int = 1) { diagnostics[key, default: 0] += amount }
        let x0 = Int(roi.minX), y0 = Int(roi.minY), w = Int(roi.width), h = Int(roi.height)
        func luminance(_ x: Int, _ y: Int) -> Int {
            let i = (y * frame.width + x) * 3
            return (Int(frame.rgb[i]) * 77 + Int(frame.rgb[i + 1]) * 150 + Int(frame.rgb[i + 2]) * 29) / 256
        }
        var ring: [Int] = []
        for x in 0..<w { ring.append(luminance(x0 + x, y0)); ring.append(luminance(x0 + x, y0 + h - 1)) }
        for y in 0..<h { ring.append(luminance(x0, y0 + y)); ring.append(luminance(x0 + w - 1, y0 + y)) }
        ring.sort()
        let background = ring[ring.count / 2]
        guard ring[ring.count * 9 / 10] - ring[ring.count / 10] <= 40 else { note("unstableOriginalSurface"); return [] }
        var ink = [UInt8](repeating: 0, count: w * h)
        var excluded = [UInt8](repeating: 0, count: w * h)
        for (index, keepout) in keepouts.enumerated() {
            let local = keepout.insetBy(dx: -1, dy: -1).integral.intersection(roi)
            guard valid(local) else { continue }
            for y in Int(local.minY)..<Int(local.maxY) { for x in Int(local.minX)..<Int(local.maxX) {
                excluded[(y - y0) * w + x - x0] |= index < detectedCount ? 1 : 2
            } }
        }
        var inkPixels = 0
        for y in 0..<h {
            var rowHasInk = false
            for x in 0..<w {
                let sx = x0 + x, sy = y0 + y
                // Extract WHOLE original components first. Mask/keepout clipping
                // must not manufacture shorter glyphs from an intersecting stroke.
                guard abs(luminance(sx, sy) - background) >= 48 else { continue }
                ink[y * w + x] = 1
                inkPixels += 1; rowHasInk = true
            }
            if rowHasInk { note("inkRows") }
        }
        note("inkPixels", inkPixels)
        if inkPixels == 0 { note("noOriginalInk") }
        var result: [Component] = [], visited = 0
        for seed in ink.indices where ink[seed] == 1 {
            var queue = [seed], cursor = 0, left = seed % w, right = left, top = seed / w, bottom = top
            var supported = true
            var detectorBlocked = false, acceptedBlocked = false, maskBlocked = false
            var dbSum: Double = 0, dbSupported = 0
            ink[seed] = 0
            while cursor < queue.count {
                let i = queue[cursor], x = i % w, y = i / w
                cursor += 1; visited += 1
                guard visited <= 131_072 else { note("componentPixelBudget"); return [] }
                if excluded[i] & 1 != 0 { detectorBlocked = true; note("inkPixelsInDetectorKeepout") }
                if excluded[i] & 2 != 0 { acceptedBlocked = true; note("inkPixelsInAcceptedKeepout") }
                if mask.map({ !$0.contains(sourceX: x0 + x, sourceY: y0 + y) }) ?? false { maskBlocked = true }
                if excluded[i] != 0 || maskBlocked { supported = false }
                if let probability {
                    let p = probability.value(x: x0 + x, y: y0 + y)
                    dbSum += p
                    if p >= 0.35 { dbSupported += 1 }
                }
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < w && ny >= 0 && ny < h {
                    let next = ny * w + nx
                    if ink[next] == 1 { ink[next] = 0; queue.append(next) }
                }
            }
            let cw = right - left + 1, ch = bottom - top + 1
            let fill = Double(queue.count) / Double(cw * ch)
            note("originalComponents")
            guard supported else {
                if detectorBlocked { note("componentDetectorKeepout") }
                if acceptedBlocked { note("componentAcceptedKeepout") }
                if maskBlocked { note("componentMaskSupport") }
                continue
            }
            guard cw >= 3, ch >= 3, cw <= 96, ch <= 96 else { note("componentSize"); continue }
            guard max(cw, ch) <= min(cw, ch) * 3 else { note("componentAspect"); continue }
            guard (0.08...0.8).contains(fill) else { note("componentInkDensity"); continue }
            guard left > 0, top > 0, right < w - 1, bottom < h - 1 else { note("componentClippedAtROI"); continue }
            // Below detector admission is allowed only as recognition support:
            // >=half the actual ink must have measured DB>=.35, mean>=.25.
            if probability != nil && (dbSupported * 2 < queue.count || dbSum / Double(queue.count) < 0.25) {
                if dbSupported * 2 < queue.count { note("componentDBCoverage") }
                if dbSum / Double(queue.count) < 0.25 { note("componentDBMean") }
                note("componentNoDBSupport"); continue
            }
            result.append(.init(bounds: CGRect(x: x0 + left, y: y0 + top, width: cw, height: ch), pixels: queue.count,
                probabilityMean: probability == nil ? nil : dbSum / Double(queue.count)))
            note("independentComponents")
            guard result.count <= 128 else { note("componentCountBudget"); return [] }
        }
        return result
    }

    private static func lanes(_ components: [Component], vertical: Bool) -> [[Component]] {
        let sorted = components.sorted { vertical ? $0.bounds.midX < $1.bounds.midX : $0.bounds.midY < $1.bounds.midY }
        var output: [[Component]] = []
        for c in sorted {
            if let i = output.indices.first(where: { i in output[i].allSatisfy {
                let a = $0.bounds, b = c.bounds
                return vertical ? abs(a.midX - b.midX) <= min(a.width, b.width) * 0.4
                    : abs(a.midY - b.midY) <= min(a.height, b.height) * 0.4
            } }) { output[i].append(c) } else { output.append([c]) }
        }
        return output
    }

    private static func validMask(_ p: NativeRFDETRLayoutPrimitive, frame: NativeRFDETRSourceImage) -> Bool {
        guard let m = p.mask else { return false }
        return m.queryID == p.queryID && m.sourceWidth == frame.width && m.sourceHeight == frame.height &&
            m.logits.count == NativeRFDETRLayoutResource.maskSide * NativeRFDETRLayoutResource.maskSide && m.logits.allSatisfy(\.isFinite)
    }
    private static func valid(_ b: CGRect) -> Bool {
        !b.isNull && !b.isInfinite && b.width > 0 && b.height > 0 && [b.minX, b.minY, b.maxX, b.maxY].allSatisfy(\.isFinite)
    }
    private static func quad(_ b: CGRect) -> [CGPoint] {
        [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY), .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
    }
}

@available(iOS 18.0, *)
private extension NativeCoreMLRecognitionRegion {
    var polygonBounds: CGRect { polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) } }
}


/// Shared offline calibration; runtime keys are source measurements, never GT
/// distances, image identities or detector indices. No ownership changes.
@available(iOS 18.0, *)
enum NativeOCRCommonBoundaryCalibration {
    struct Input {
        let index: Int
        let polygon: [CGPoint]
        var baseline: [CGPoint]? = nil
        var terminal: [CGPoint]? = nil
        var pointTerminal: [CGPoint]? = nil
        var hasInk = false
        var independent = false
    }
    static let rules: [String: [Double]] = [
        "detector:compact:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:ink:sparse:short|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:ink:sparse:short|2": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:ink:sparse:short|4": [1.0, 1.0, 0.0, 0.0, -0.35, 0.0, 0.0],
        "detector:compact:ink:sparse:short|5": [1.0, 0.75, -0.03, -0.05, 0.0, 0.0, 0.0],
        "detector:compact:ink:sparse:short|7": [1.0, 0.75, -0.03, -0.05, 0.0, 0.0, 0.0],
        "detector:compact:ink:sparse:short|8": [1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:sparse:short|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:sparse:short|1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:sparse:short|4": [0.0, 0.0, -0.03, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:sparse:short|7": [1.0, 0.0, -0.03, 0.0, 0.0, 0.0, 1.0],
        "detector:compact:unproved:unknown|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:unknown|1": [1.0, 0.5, 0.0, 0.5, 0.0, 0.0, 0.0],
        "detector:compact:unproved:unknown|4": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|-1": [1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|1": [1.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|2": [3.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|4": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|5": [3.0, 1.0, 0.0, 0.0, 0.05, 0.0, 0.0],
        "detector:long:ink:sparse:normal|7": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|8": [2.0, 1.0, 0.0, -0.05, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:short|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:short|5": [2.0, 1.0, 0.0, 0.0, -0.15, 0.0, 1.0],
        "detector:long:ink:sparse:short|8": [1.0, 0.5, 0.0, -0.35, 0.0, 0.0, 0.0],
        "detector:long:unproved:fallback|-1": [0.0, 0.5, 0.03, 0.15, 0.35, 0.0, 0.5],
        "detector:long:unproved:sparse:normal|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|1": [1.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|2": [1.0, 0.75, 0.0, 0.0, 0.0, 0.0, 0.5],
        "detector:medium:ink:sparse:normal|3": [3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|4": [4.0, 1.0, 0.0, 0.0, -0.05, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|5": [4.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|6": [0.0, 0.5, 0.0, 0.15, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|7": [4.0, 1.0, 0.0, -0.05, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|8": [3.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|-1": [0.0, 0.0, 0.0, -0.05, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|2": [1.0, 1.0, 0.0, -0.35, 0.15, 0.0, 0.0],
        "detector:medium:ink:sparse:short|4": [2.0, 1.0, 0.0, -0.15, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|5": [0.0, 0.0, 0.0, -0.05, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|7": [3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|8": [3.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:unknown|-1": [0.0, 0.5, 0.0, 0.0, 0.15, 0.0, 1.0],
        "detector:medium:unproved:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:normal|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:normal|1": [1.0, 0.75, 0.0, -0.05, -0.35, 0.0, 0.0],
        "detector:medium:unproved:sparse:normal|4": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:normal|7": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:short|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:short|1": [1.0, 1.0, -0.06, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:short|4": [0.0, 0.0, 0.0, 0.05, -0.5, 0.0, 0.0],
        "detector:medium:unproved:sparse:short|7": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:unknown|-1": [0.0, 0.5, 0.0, -0.15, 0.35, 0.0, 0.0],
        "group:compact:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "group:long:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "group:long:ink:sparse:normal|-1": [3.0, 1.0, 0.0, -0.05, 0.05, 0.0, 0.0],
        "group:long:ink:sparse:normal|5": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "group:medium:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "group:medium:ink:sparse:normal|-1": [1.0, 0.25, 0.0, 0.0, 0.0, 0.0, 0.5],
        "independent:compact:unproved:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "independent:long:unproved:unknown|7": [0.0, 0.25, 0.06, 0.15, 0.15, 0.08, 1.0],
        "independent:medium:unproved:unknown|7": [0.0, 0.0, 0.0, 0.15, 0.0, 0.0, 0.0],
    ]
    // One fixed shared proposal supplies a source-ownership witness. It
    // contains no per-image coordinates or GT; future tunings may change the
    // candidate without silently discarding previously observed glyph cells.
    private static let sourceSupportReferenceRules: [String: [Double]] = [
        "detector:compact:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:ink:sparse:short|-1": [3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:ink:sparse:short|2": [4.0, 0.75, 0.06, 0.0, 0.0, -0.08, 0.5],
        "detector:compact:ink:sparse:short|4": [1.0, 1.0, 0.0, 0.0, -0.35, 0.0, 0.0],
        "detector:compact:ink:sparse:short|5": [1.0, 0.75, -0.03, -0.05, 0.0, 0.0, 0.0],
        "detector:compact:ink:sparse:short|7": [1.0, 0.75, -0.03, -0.05, 0.0, 0.0, 0.0],
        "detector:compact:ink:sparse:short|8": [1.0, 0.75, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:sparse:short|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:sparse:short|1": [0.0, 0.0, 0.0, 0.15, 0.15, 0.0, 0.0],
        "detector:compact:unproved:sparse:short|4": [0.0, 0.0, -0.03, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:sparse:short|7": [1.0, 0.0, -0.03, 0.0, 0.0, 0.0, 1.0],
        "detector:compact:unproved:unknown|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:compact:unproved:unknown|1": [1.0, 0.5, 0.0, 0.5, 0.0, 0.0, 0.0],
        "detector:compact:unproved:unknown|4": [0.0, 0.0, 0.06, 0.15, 0.6, -0.08, 1.0],
        "detector:long:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|-1": [1.0, 1.0, 0.0, 0.15, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|1": [3.0, 1.0, 0.0, -0.15, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|2": [2.0, 1.0, -0.03, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|4": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|5": [3.0, 1.0, 0.0, 0.0, 0.05, 0.0, 0.0],
        "detector:long:ink:sparse:normal|7": [2.0, 1.0, 0.03, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:normal|8": [2.0, 1.0, 0.0, -0.05, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:short|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:long:ink:sparse:short|5": [2.0, 0.5, 0.0, 0.0, -0.05, 0.0, 1.0],
        "detector:long:ink:sparse:short|8": [1.0, 0.5, 0.0, -0.35, 0.0, 0.0, 0.0],
        "detector:long:unproved:fallback|-1": [0.0, 0.75, 0.06, 0.0, 0.35, 0.04, 1.0],
        "detector:long:unproved:sparse:normal|-1": [1.0, 0.75, 0.0, 0.05, 0.15, 0.0, 0.25],
        "detector:medium:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|1": [3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|2": [3.0, 1.0, 0.0, 0.15, 0.15, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|3": [3.0, 1.0, 0.0, 0.0, 0.35, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|4": [4.0, 1.0, 0.0, 0.0, -0.05, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|5": [4.0, 0.75, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|6": [0.0, 0.5, 0.0, 0.15, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|7": [1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:normal|8": [3.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|-1": [3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|2": [1.0, 1.0, 0.0, -0.35, 0.15, 0.0, 0.0],
        "detector:medium:ink:sparse:short|4": [3.0, 1.0, 0.0, -0.15, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|5": [0.0, 0.0, 0.0, -0.05, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|7": [1.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:sparse:short|8": [3.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:ink:unknown|-1": [0.0, 1.0, 0.0, 0.0, 0.15, 0.0, 1.0],
        "detector:medium:unproved:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:normal|-1": [0.0, 0.5, 0.0, 0.35, -0.35, 0.0, 0.0],
        "detector:medium:unproved:sparse:normal|1": [0.0, 1.0, 0.0, -0.15, -0.15, 0.0, 0.0],
        "detector:medium:unproved:sparse:normal|4": [0.0, 0.0, 0.0, 0.0, 0.15, 0.0, 0.0],
        "detector:medium:unproved:sparse:normal|7": [1.0, 0.5, -0.06, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:short|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:short|1": [1.0, 1.0, -0.06, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:short|4": [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "detector:medium:unproved:sparse:short|7": [0.0, 0.0, 0.0, 0.05, 0.05, 0.0, 0.0],
        "detector:medium:unproved:unknown|-1": [0.0, 0.75, 0.0, 0.3, 0.15, 0.0, 0.0],
        "group:compact:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "group:long:ink:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "group:long:ink:sparse:normal|-1": [3.0, 1.0, 0.0, -0.05, 0.05, 0.0, 0.0],
        "group:long:ink:sparse:normal|5": [0.0, 0.0, 0.0, -0.15, -0.15, 0.0, 0.0],
        "group:medium:ink:fallback|-1": [3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "group:medium:ink:sparse:normal|-1": [0.0, 0.5, 0.0, -0.05, 0.0, 0.0, 0.5],
        "independent:compact:unproved:fallback|-1": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        "independent:long:unproved:unknown|7": [0.0, 0.25, 0.06, 0.15, 0.15, 0.08, 1.0],
        "independent:medium:unproved:unknown|7": [0.0, 0.0, 0.0, 0.15, 0.0, 0.0, 0.0],
    ]
    private static let families = Set(rules.keys.compactMap { $0.split(separator: "|").first.map(String.init) })
    static func calibrate(_ inputs: [Input], originals: [NativeCoreMLDetectionBox],
                          prepared: [NativeCoreMLDetectionBox], groups: [Int: [Int]]) -> [[CGPoint]] {
        inputs.map { input in
            let q=input.polygon
            guard q.count==4 else {return q}
            let e1=CGPoint(x:q[1].x-q[0].x,y:q[1].y-q[0].y),e3=CGPoint(x:q[3].x-q[0].x,y:q[3].y-q[0].y)
            let edge=hypot(e1.x,e1.y)>=hypot(e3.x,e3.y) ? e1:e3
            let length=hypot(edge.x,edge.y)
            guard length>0 else {return q}
            let along=CGPoint(x:edge.x/length,y:edge.y/length),normal=CGPoint(x:edge.y/length,y:-edge.x/length)
            func project(_ p:CGPoint)->CGPoint {CGPoint(x:p.x*normal.x+p.y*normal.y,y:p.x*along.x+p.y*along.y)}
            func bounds(_ p:[CGPoint])->CGRect {
                let v=p.map(project),xs=v.map(\.x),ys=v.map(\.y)
                return CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
            }
            let rect=bounds(q),width=max(1,rect.width)
            guard rect.width>0,rect.height>0 else {return q}
            var protected:[CGPoint]=[],owned:[CGPoint]=[]
            for i in groups[input.index] ?? [input.index] where originals.indices.contains(i) {
                guard let evidence=originals[i].detectorSeedEvidence,evidence.isValid else {continue}
                let sx=CGFloat(evidence.sourceWidth)/CGFloat(evidence.mapFullWidth),sy=CGFloat(evidence.sourceHeight)/CGFloat(evidence.mapFullHeight)
                for component in evidence.components {for run in component.runs {for x in run.x..<(run.x+run.count) {
                    let p=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                    owned.append(p)
                    if contains(q,p) {protected.append(p)}
                }}}
            }
            let observed=protected.count>=12
            let kind=input.independent ? "independent":groups[input.index] != nil ? "group":"detector"
            let ratio=max(hypot(e1.x,e1.y),hypot(e3.x,e3.y))/max(1,min(hypot(e1.x,e1.y),hypot(e3.x,e3.y)))
            let aspect=ratio<3 ? "compact":ratio<8 ? "medium":"long"
            let parent=kind+":"+aspect+":"+(input.hasInk ? "ink":"unproved")
            var family=parent+":unknown"
            if observed {
                let ink=bounds(protected),nf=ink.width/max(1,rect.width),af=ink.height/max(1,rect.height)
                family=parent+":"+(nf<0.7 ? "sparse":nf<0.9 ? "normal":"full")+":"+(af<0.85 ? "short":af<0.97 ? "normal":"full")
            }
            if !families.contains(family) {family=parent+":fallback"}
            let seed=prepared.indices.contains(input.index) ? prepared[input.index].polygon:q,seedRect=bounds(seed)
            let score=prepared.indices.contains(input.index) ? prepared[input.index].score:1
            let confidence=score<0.8 ? 0:score<0.9 ? 1:2
            let head=(rect.minY-seedRect.minY)/width,tail=(rect.maxY-seedRect.maxY)/width
            let growth=head < -0.15 || tail>0.15 ? 2:head>0.15 || tail < -0.15 ? 0:1
            guard let p=rules[family+"|"+String(confidence*3+growth)] ?? rules[family+"|-1"] else {return q}
            let alternative=input.baseline.flatMap {
                NativeOCRRFPrimaryEnsemble.measuredEndpointAlternative(candidate:q,baseline:$0,terminalProof:input.terminal)
            }
            let anchors=[input.baseline ?? q,seed,alternative ?? q,input.terminal ?? q,input.pointTerminal ?? q]
            func transformed(_ p:[Double])->[CGPoint] {
                let anchor=anchors[Int(p[0])],target=bounds(anchor),blend=CGFloat(p[1])
                let lo=CGPoint(x:rect.minX*(1-blend)+target.minX*blend+CGFloat(p[5]-p[2])*width,
                               y:rect.minY*(1-blend)+target.minY*blend-CGFloat(p[3])*width)
                let hi=CGPoint(x:rect.maxX*(1-blend)+target.maxX*blend+CGFloat(p[5]+p[2])*width,
                               y:rect.maxY*(1-blend)+target.maxY*blend+CGFloat(p[4])*width)
                guard hi.x>lo.x,hi.y>lo.y else {return q}
                var candidate=q.map { point->CGPoint in
                    let v=project(point),x=(v.x-rect.minX)*(hi.x-lo.x)/rect.width+lo.x,y=(v.y-rect.minY)*(hi.y-lo.y)/rect.height+lo.y
                    return CGPoint(x:x*normal.x+y*along.x,y:x*normal.y+y*along.y)
                }
                let a1=CGPoint(x:anchor[1].x-anchor[0].x,y:anchor[1].y-anchor[0].y),a3=CGPoint(x:anchor[3].x-anchor[0].x,y:anchor[3].y-anchor[0].y)
                var ae=hypot(a1.x,a1.y)>=hypot(a3.x,a3.y) ? a1:a3
                let al=hypot(ae.x,ae.y)
                if al>0 {
                    ae=CGPoint(x:ae.x/al,y:ae.y/al)
                    if ae.x*along.x+ae.y*along.y<0 {ae=CGPoint(x:-ae.x,y:-ae.y)}
                    var angle=atan2(along.x*ae.y-along.y*ae.x,along.x*ae.x+along.y*ae.y)
                    if abs(angle)>CGFloat.pi/12 {angle=0}
                    angle *= CGFloat(p[6])
                    let center=CGPoint(x:candidate.map(\.x).reduce(0,+)/4,y:candidate.map(\.y).reduce(0,+)/4)
                    candidate=candidate.map { point in
                        let x=point.x-center.x,y=point.y-center.y
                        return CGPoint(x:center.x+x*cos(angle)-y*sin(angle),y:center.y+x*sin(angle)+y*cos(angle))
                    }
                }
                return candidate
            }
            if !observed {protected=q}
            func supported(_ polygon:[CGPoint])->Bool {
                polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.x>=0 && $0.y>=0}) &&
                    protected.allSatisfy({contains(polygon,$0,tolerance:0.75)})
            }
            let categoryKey=family+"|"+String(confidence*3+growth)
            let referenceParameters=sourceSupportReferenceRules[categoryKey] ?? sourceSupportReferenceRules[family+"|-1"]
            let proposedReference=referenceParameters.map(transformed) ?? q
            let reference=supported(proposedReference) ? proposedReference:q
            let candidate=transformed(p)
            let previouslyIncluded=owned.filter {contains(reference,$0)}
            guard supported(candidate),previouslyIncluded.allSatisfy({contains(candidate,$0,tolerance:0.75)}) else {return reference}
            return candidate
        }
    }
    private static func contains(_ quad:[CGPoint],_ point:CGPoint,tolerance:CGFloat=0)->Bool {
        var positive=false,negative=false
        for i in quad.indices {
            let a=quad[i],b=quad[(i+1)%quad.count],cross=(b.x-a.x)*(point.y-a.y)-(b.y-a.y)*(point.x-a.x)
            if cross>1e-7 {positive=true};if cross < -1e-7 {negative=true}
        }
        if !positive || !negative {return true}
        guard tolerance>0 else {return false}
        return quad.indices.contains {i in
            let a=quad[i],b=quad[(i+1)%quad.count],dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
            guard length>0 else {return hypot(point.x-a.x,point.y-a.y)<=tolerance}
            let t=max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/length))
            return hypot(point.x-a.x-t*dx,point.y-a.y-t*dy)<=tolerance
        }
    }
}
