import Foundation
import CoreGraphics
import CryptoKit

/// DEFAULT OFF actual-live source-binding bridge. No geometry/native admission,
/// synthetic private seeds, mandatory replacement, model call or frame acquisition.
@available(iOS 18.0, *)
enum NativeOCRSourceLiveClosedContrast418 {
    typealias F = NativeOCRSourceLocalJoint369
    typealias K = NativeOCRSharedBoundary396
    typealias C = SourceClosedContrast418
    static let enabled = false
    static let maximumFootprintCells=4_000_000
    static let maximumOriginalRunCells=4_000_000
    struct Preparation {
        let session:Session?
        let receipt:[String:Any]
        let sourceBinding:[String:Any]
        let exactMissing:[String]
    }
    struct Query {
        let state:String
        let positive:Bool
        let actualLocalPixelIndex:Int?
        let closedContrast:C.Result?
        let receipt:[String:Any]
    }
    final class Session {
        let actualOld:[CGPoint]
        let rgba:K.RGBA
        let basis:K.Basis
        let nativeW:CGFloat
        let evidence:K.Evidence
        let roles408:SourceContrastRole408.Output
        let sourceBinding:[String:Any]
        let exactMissing:[String]
        private let peerViews:NativeOCRSourceLiveStroke404.MaskViews
        private var cache:[Int:Query]=[:]
        fileprivate init(old:[CGPoint],basis:K.Basis,nativeW:CGFloat,evidence:K.Evidence,
                         roles408:SourceContrastRole408.Output,
                         peerViews:NativeOCRSourceLiveStroke404.MaskViews,
                         binding:[String:Any],missing:[String]) {
            self.actualOld=old;self.rgba=evidence.rgba;self.basis=basis;self.nativeW=nativeW
            self.evidence=evidence;self.roles408=roles408;self.peerViews=peerViews
            self.sourceBinding=binding;self.exactMissing=missing
        }
        func foreignAt(_ p:CGPoint)->Bool {peerViews.foreignAt(p)}
        func uncertainAt(_ p:CGPoint)->Bool {peerViews.uncertainAt(p)}
        private func unresolved(_ why:String,_ i:Int?=nil)->Query {
            .init(state:"unresolved",positive:false,actualLocalPixelIndex:i,closedContrast:nil,
                receipt:["family":"source-live-closed-contrast418","status":why,
                    "NNOrGGQuerySeedUsed":false,"ambiguityDischarged":false,
                    "unknownPolicy":"receipt-deferred-parent-policy-owned-no-fallback-or-allow-decision",
                    "literalExteriorCompanionRun":false,"mandatoryReplaced":false,"admissionGranted":false])
        }
        // Root-local serial use. Cache is keyed by the actual stride-free local
        // index, never a detector/root/GT ID. A repeated query has no extra role pass.
        func assess(actualLocalPixelIndex i:Int)->Query {
            guard i>=0,i<rgba.width*rgba.height else{return unresolved("invalid-actual-local-index")}
            if let previous=cache[i] {return previous}
            guard cache.count<2048 else{return unresolved("distinct-actual-query-budget-exhausted",i)}
            let p=CGPoint(x:rgba.origin.x+CGFloat(i%rgba.width)+0.5,
                y:rgba.origin.y+CGFloat(i/rgba.width)+0.5)
            let o=(i/rgba.width)*rgba.bytesPerRow+(i%rgba.width)*4
            guard rgba.bytes[o+3]==255,K.contains(actualOld,p) else {
                return unresolved("query-not-opaque-actual-old-pixel",i)
            }
            // Exact Galileo API. Query nominates only this observed coordinate;
            // it is NOT inserted into native cells, GG, detectors, or 408 roots.
            let closed=C.assess(rgba:rgba,queryPoint:p,normal:basis.normal,along:basis.along,nativeW:nativeW)
            let literalRole=roles408.role(atActualLocalPixelIndex:i)
            var receipt=closed.receipt
            receipt["adapterFamily"]="source-live-closed-contrast418"
            receipt["actualLocalPixelIndex"]=i;receipt["actualCenter"]=[Double(p.x),Double(p.y)]
            receipt["actualRGB"]=(0..<3).map{Int(rgba.bytes[o+$0])}
            receipt["actualQueryPixelCell"]=[[Double(p.x-0.5),Double(p.y-0.5)],
                [Double(p.x+0.5),Double(p.y-0.5)],[Double(p.x+0.5),Double(p.y+0.5)],
                [Double(p.x-0.5),Double(p.y+0.5)]]
            receipt["queryCellRequiresClippingToActualOld"]=true
            receipt["literal408RoleRawValue"]=Int(literalRole.rawValue)
            receipt["literal408PositiveFill"]=roles408.isPositiveFill(atActualLocalPixelIndex:i)
            receipt["literal408StableRimCore"]=literalRole == .stableRimCore
            receipt["literal408Status"]=roles408.receipt["status"] as Any? ?? NSNull()
            receipt["actualNativeMembershipContextOnly"]=evidence.privateAt(p)
            receipt["actualGGMembershipContextOnly"]=evidence.body[i] != 0
            receipt["actualForeignMembership"]=foreignAt(p);receipt["actualPeerUncertainty"]=uncertainAt(p)
            receipt["queryRegisteredAsNativeOrGGSeed"]=false;receipt["role408ComputedOncePerRoot"]=true
            receipt["actualLocalRGBA_SHA256"]=sourceBinding["actualRGBA_SHA256"]
            receipt["literalExteriorCompanionRun"]=false;receipt["ambiguityDischarged"]=false
            receipt["positiveSupplementalLossVetoOnly"]=closed.positive
            receipt["unknownPolicy"]="receipt-deferred-parent-policy-owned-no-fallback-or-allow-decision"
            receipt["closedContrastIsSourceOwnership"]=false;receipt["mandatoryReplaced"]=false
            receipt["nativeAdmissionSuiteRun"]=false;receipt["admissionGranted"]=false
            let output=Query(state:closed.state.rawValue,positive:closed.positive,
                actualLocalPixelIndex:i,closedContrast:closed,receipt:receipt)
            cache[i]=output;return output
        }
        func assess(actualQueryPoint p:CGPoint)->Query {
            guard p.x.isFinite,p.y.isFinite else{return unresolved("nonfinite-actual-query")}
            let x=floor(p.x-rgba.origin.x),y=floor(p.y-rgba.origin.y)
            guard x>=0,x<CGFloat(rgba.width),y>=0,y<CGFloat(rgba.height),
                  abs(p.x-(rgba.origin.x+x+0.5))<=1e-7,
                  abs(p.y-(rgba.origin.y+y+0.5))<=1e-7 else {
                return unresolved("query-not-an-exact-exported-actual-pixel-center")
            }
            return assess(actualLocalPixelIndex:Int(y)*rgba.width+Int(x))
        }
        /// Optional strict join for Herschel exports that also carry their actual
        /// center/RGB/local-byte binding. These are caller arguments, not claimed
        /// existing fields on an uninspected export type.
        func assess(actualLocalPixelIndex i:Int,expectedCenter:CGPoint,expectedRGB:[Int],
                    expectedRGBA_SHA256:String)->Query {
            guard i>=0,i<rgba.width*rgba.height,
                  sourceBinding["actualRGBA_SHA256"] as? String==expectedRGBA_SHA256 else {
                return unresolved("lost-pixel-export-local-RGBA-binding-mismatch")
            }
            let p=CGPoint(x:rgba.origin.x+CGFloat(i%rgba.width)+0.5,
                y:rgba.origin.y+CGFloat(i/rgba.width)+0.5)
            let o=(i/rgba.width)*rgba.bytesPerRow+(i%rgba.width)*4
            guard expectedCenter==p,expectedRGB==(0..<3).map({Int(rgba.bytes[o+$0])}) else {
                return unresolved("lost-pixel-export-index-center-RGB-mismatch",i)
            }
            return assess(actualLocalPixelIndex:i)
        }
    }
    static func prepareFromLive(prior:NativeOCRCurrentPrior351.Resolution,
        graph:NativeOCRSourceLocalJoint369Capture.FinalGraph,measurement:F.M,live:F.LiveObservation,
        actualOriginalSeedEvidence originals:[NativeCoreMLDetectionBox],sourceRF layout:NativeRFDETRLayoutResult?,
        experimentEnabled:Bool=false)->Preparation {
        func failure(_ reason:String)->Preparation {
            .init(session:nil,receipt:["family":"source-live-closed-contrast418","status":reason,
                "sourceOnly":true,"GTRead":false,"admissionGranted":false,"mandatoryReplaced":false,
                "NNOrGGQuerySeedUsed":false,"role408Passes":0,"frameCalls":0,"sourceAcquisitionCalls":0],
                sourceBinding:[:],exactMissing:reason=="disabled" ? []:[reason])
        }
        guard experimentEnabled else{return failure("disabled")}
        let indices=[measurement.index]+prior.consumedIndices
        guard let actual=graph.prior(measurement.index),actual.polygon==prior.polygon,
              actual.consumedIndices==prior.consumedIndices,
              actual.inheritedAssociationKey==prior.inheritedAssociationKey,
              Set(indices).count==indices.count,!indices.isEmpty,indices.count<=64,
              live.sources.map(\.index)==indices,live.bodies.count==indices.count,
              liveQuad(prior.polygon) else {return failure("unavailable-actual-graph-prior-member-order")}
        let r=live.rgba,window=live.window
        guard r.width>0,r.height>0,r.width<=600_000/r.height,
              r.width<=Int.max/4,r.bytesPerRow>=r.width*4,r.height<=Int.max/r.bytesPerRow,
              r.bytes.count==r.bytesPerRow*r.height,
              r.origin==CGPoint(x:window.left,y:window.top),r.width==window.width,r.height==window.height,
              window.frameSize.width>0,window.frameSize.height>0,
              prior.polygon.allSatisfy({$0.x>=r.origin.x && $0.y>=r.origin.y &&
                  $0.x<=r.origin.x+CGFloat(r.width) && $0.y<=r.origin.y+CGFloat(r.height)}) else {
            return failure("unavailable-actual-shared-RGBA-window")
        }
        guard let root=live.sources.first,root.index==measurement.index,
              root.status==measurement.status,root.origin==measurement.origin,
              root.normal==measurement.normal,root.along==measurement.along,
              root.rect==measurement.rect,root.polygon==measurement.polygon else {
            return failure("unavailable-root-measurement-binding")
        }
        let differences=NativeOCRSourceLocalJoint369Capture.metadataDifferences392(root,measurement)
        guard differences.isEmpty else {return failure("unavailable-root-measurement-metadata:"+differences.joined(separator:","))}
        let rgbaSHA=SHA256.hash(data:Data(r.bytes)).map{String(format:"%02x",$0)}.joined()
        let pixelCount=r.width*r.height
        var memberBindings:[[String:Any]]=[],memberCellWork=0
        for ordinal in indices.indices {
            let m=live.sources[ordinal],e=live.bodies[ordinal],p=e.prepared,b=e.sourceLocalRGBA
            // m.rect.width is the actual native Measurement width (exported as m.width).
            // No prior polygon width, private hull width, or inferred width substitutes it.
            let nativeWidth=Double(m.rect.width),fp=e.actualFullFootprint
            guard m.status=="measured",nativeWidth.isFinite,nativeWidth>0,
                  [m.origin,m.normal,m.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
                  abs(hypot(m.normal.x,m.normal.y)-1)<1e-6,
                  abs(hypot(m.along.x,m.along.y)-1)<1e-6,
                  abs(m.normal.x*m.along.x+m.normal.y*m.along.y)<1e-6,
                  p.inherited==prior.polygon,p.sourceOrigin==m.origin,p.normal==m.normal,p.along==m.along,
                  p.sourceWidth==nativeWidth,
                  p.window.frameSize==window.frameSize,p.window.left==window.left,p.window.top==window.top,
                  p.window.width==window.width,p.window.height==window.height,
                  sameWindow(e.source.window,window),
                  b.origin==r.origin,b.width==r.width,b.height==r.height,
                  b.bytesPerRow==r.bytesPerRow,b.bytes==r.bytes,
                  e.sourceAuthenticatedContrastBodyMask.count==pixelCount,
                  e.uniqueMaskPixels==e.sourceAuthenticatedContrastBodyMask.filter({$0 != 0}).count,
                  let retained=m.privateObservation,retained.missingPrivateRGBPixels==0,
                  let original=retained.footprint,fp.width>0,fp.height>0,
                  fp.width<=Int.max/fp.height,fp.scaleX.isFinite,fp.scaleY.isFinite,fp.scaleX>0,fp.scaleY>0,
                  !fp.cells.isEmpty,fp.cells.allSatisfy({$0>=0 && $0<fp.width*fp.height}),
                  fp.width==original.width,fp.height==original.height,
                  fp.scaleX==original.scaleX,fp.scaleY==original.scaleY,fp.cells==original.cells,
                  abs(CGFloat(fp.width)*fp.scaleX-CGFloat(window.frameSize.width))<=1e-6,
                  abs(CGFloat(fp.height)*fp.scaleY-CGFloat(window.frameSize.height))<=1e-6,
                  !e.actualPalettes.isEmpty,e.actualPalettes.count<=16,
                  e.actualPalettes.count==retained.palettes.count else {
                return failure("unavailable-actual-body-native-width-original-footprint-binding")
            }
            guard fp.cells.count<=maximumFootprintCells-memberCellWork else{return failure("member-full-footprint-cell-budget-exceeded")}
            memberCellWork += fp.cells.count
            for (a,b) in zip(e.actualPalettes,retained.palettes) {
                guard a.rgb==b.rgb,a.bin==b.bin,a.sourceSeedBinCount==b.sourceSeedBinCount,
                      a.rgb.count==3,a.rgb.allSatisfy({(0...255).contains($0)}) else {
                    return failure("unavailable-actual-native-palette-binding")
                }
            }
            memberBindings.append(["sourceIndex":m.index,"nativeW":nativeWidth,
                "actualFullFootprintSHA256":footprintDigest(fp),"actualFullFootprintCells":fp.cells.count,
                "actualGGBodySHA256":digest(e.sourceAuthenticatedContrastBodyMask),
                "actualRGBA_SHA256":rgbaSHA,"preparedInheritedEqualsActualPrior":true])
        }
        let rootBody = live.bodies[0].sourceAuthenticatedContrastBodyMask
        let rootFP = live.bodies[0].actualFullFootprint
        let nativeW = CGFloat(measurement.rect.width)
        // Match396 observer's source-basis actual386 +/- one native width observation probe.
        // The existing live window may have been built in the prior's basis instead.
        func project(_ p: CGPoint) -> CGPoint {
            let x=p.x-measurement.origin.x,y=p.y-measurement.origin.y
            return .init(x:x*measurement.normal.x+y*measurement.normal.y,
                         y:x*measurement.along.x+y*measurement.along.y)
        }
        let pp=prior.polygon.map(project)
        let n0=pp.map(\.x).min()!-nativeW,n1=pp.map(\.x).max()!+nativeW
        let a0=pp.map(\.y).min()!-nativeW,a1=pp.map(\.y).max()!+nativeW
        let fullProbe=[CGPoint(x:n0,y:a0),CGPoint(x:n1,y:a0),CGPoint(x:n1,y:a1),CGPoint(x:n0,y:a1)].map { p -> CGPoint in
            let x=measurement.origin.x+p.x*measurement.normal.x+p.y*measurement.along.x
            let y=measurement.origin.y+p.x*measurement.normal.y+p.y*measurement.along.y
            return .init(x:max(0,min(CGFloat(window.frameSize.width),x)),
                         y:max(0,min(CGFloat(window.frameSize.height),y)))
        }
        guard fullProbe.allSatisfy({$0.x>=r.origin.x-1e-7 && $0.y>=r.origin.y-1e-7 &&
            $0.x<=r.origin.x+CGFloat(r.width)+1e-7 && $0.y<=r.origin.y+CGFloat(r.height)+1e-7}) else {
            return failure("unavailable-full-current-source-basis-probe-fresh-read-required")
        }
        let roi=CGRect(x:r.origin.x,y:r.origin.y,width:CGFloat(r.width),height:CGFloat(r.height))
        guard originals.count<=4096 else { return failure("original-detector-inventory-budget-exceeded") }
        var detectors:[K.Detector]=[],detectorReceipts:[[String:Any]]=[]
        var nearbyMissingPackets=0,originalCellWork=0
        // Same roles and full-grid cell semantics as396 prepare-consensus.py.
        for (ordinal,box) in originals.enumerated() {
            guard liveQuad(box.polygon),F.bounds(box.polygon).intersects(roi) else { continue }
            guard let e=box.detectorSeedEvidence else { nearbyMissingPackets += 1;continue }
            guard e.isValid,e.parentBoxIndex==ordinal,
                  e.sourceWidth==window.frameSize.width,e.sourceHeight==window.frameSize.height else {
                return failure("unavailable-nearby-original-detector-packet-binding")
            }
            guard detectors.count<64 else { return failure("nearby-detector-budget-exceeded") }
            let sx=CGFloat(e.sourceWidth)/CGFloat(e.mapFullWidth)
            let sy=CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight)
            let sameGrid=e.mapFullWidth==rootFP.width && e.mapFullHeight==rootFP.height &&
                abs(sx-rootFP.scaleX)<1e-7 && abs(sy-rootFP.scaleY)<1e-7
            var localRuns:[[Int]]=[],originalCells=Set<Int>(),overlap=0,subset=sameGrid
            // Runs are already full-grid coordinates; mapOrigin is NOT an offset to add.
            // Only owned components corroborate396. Ambiguous/candidate cells stay
            // unresolved and remain in the existing392 peer/new-owner checks.
            for component in e.components { for run in component.runs {
                guard run.count>0,run.count<=maximumOriginalRunCells-originalCellWork else{return failure("original-owned-run-cell-budget-exceeded")}
                originalCellWork += run.count
                for x in run.x..<(run.x+run.count) {
                    let cell=run.y*e.mapFullWidth+x
                    if originalCells.insert(cell).inserted && sameGrid {
                        if rootFP.cells.contains(cell) { overlap += 1 }
                        else { subset=false }
                    }
                }
                if CGFloat(run.y)*sy>=roi.maxY || CGFloat(run.y+1)*sy<=roi.minY { continue }
                let lo=max(run.x,Int(floor(roi.minX/sx)))
                let hi=min(run.x+run.count,Int(ceil(roi.maxX/sx)))
                if hi>lo { localRuns.append([run.y,lo,hi-lo]) }
            }}
            let originalCellCount=originalCells.count
            subset = subset && originalCellCount>0
            guard let cells=K.PrivateRLE(width:e.mapFullWidth,height:e.mapFullHeight,
                scaleX:sx,scaleY:sy,runs:localRuns) else {
                return failure("unavailable-overlapping-or-invalid-original-detector-local-RLE")
            }
            detectors.append(.init(ordinal:ordinal,owner:e.ownerID,nativeRoot:subset,cells:cells))
            detectorReceipts.append(["detectorOrdinal":ordinal,"ownerID":e.ownerID,
                "parentBoxIndex":e.parentBoxIndex,"provenance":e.provenance,
                "mapOrigin":[e.mapOriginX,e.mapOriginY],"fullGridRunCoordinates":true,
                "width":e.mapFullWidth,"height":e.mapFullHeight,"scaleX":Double(sx),"scaleY":Double(sy),
                "originalOwnedCellCount":originalCellCount,"nativeRootOverlapCells":overlap,
                "subsetOfNativeRoot":subset,"runs":localRuns,
                "completeCCScan":e.completeCCScan ?? false,
                "ambiguousComponentCount":e.ambiguousComponents?.count ?? 0,
                "candidateComponentCount":e.candidateComponents?.count ?? 0,
                "detectorPolygonIsInk":false,"ownershipResolved":false])
        }
        var rf:[K.RF]=[],rfReceipts:[[String:Any]]=[]
        if let layout {
            guard layout.sourceWidth==window.frameSize.width,layout.sourceHeight==window.frameSize.height else {
                return failure("unavailable-actual-source-RF-frame-binding")
            }
            for primitive in layout.primitives where primitive.semanticClass.rawValue==0 && primitive.confidence>=0.4 {
                let b=primitive.sourceBounds
                guard [b.minX,b.minY,b.maxX,b.maxY].allSatisfy({$0.isFinite}),
                      b.width>0,b.height>0,primitive.confidence.isFinite else {
                    return failure("unavailable-invalid-original-RF-text-primitive")
                }
                guard b.intersects(roi) else { continue }
                guard rf.count<160 else { return failure("local-RF-text-primitive-budget-exceeded") }
                rf.append(.init(query:primitive.queryID,confidence:Double(primitive.confidence),
                    bounds:[b.minX,b.minY,b.maxX,b.maxY]))
                rfReceipts.append(["queryID":primitive.queryID,"semanticClass":primitive.semanticClass.rawValue,
                    "confidence":Double(primitive.confidence),"bounds":[Double(b.minX),Double(b.minY),Double(b.maxX),Double(b.maxY)],
                    "RFGeometryIsInk":false])
            }
        }
        // Exact ORIGINAL full native cells, never a rasterized prior, quad or hull.
        let nativePoints=rootFP.cells.sorted().map { cell in
            CGPoint(x:(CGFloat(cell%rootFP.width)+0.5)*rootFP.scaleX,
                    y:(CGFloat(cell/rootFP.width)+0.5)*rootFP.scaleY)
        }
        guard live.peerBodies.count<=256,graph.live.count<=4096 else{return failure("local-peer-inventory-budget-exceeded")}
        var peerFootprints:[F.Footprint]=[],peerBindings:[[String:Any]]=[],peerCellWork=0
        let members=Set(indices)
        var ignoredMemberPeerKeys:[Int]=[]
        for key in live.peerBodies.keys.sorted() {
            // Member packets never become foreign masks. Root CCs that overlap
            // actual external borrowed-original packets stay contextual evidence;
            // they do not become native/GG query seeds or wrapper vetoes.
            if members.contains(key) {ignoredMemberPeerKeys.append(key);continue}
            guard let body=live.peerBodies[key] else{return failure("missing-peer-body-dictionary-value")}
            let p=body.prepared,b=body.sourceLocalRGBA,fp=body.actualFullFootprint
            guard sameWindow(p.window,window),sameWindow(body.source.window,window),
                  b.origin==r.origin,b.width==r.width,b.height==r.height,
                  b.bytesPerRow==r.bytesPerRow,b.bytes==r.bytes,
                  liveQuad(p.inherited),p.sourceWidth.isFinite,p.sourceWidth>0,
                  [p.sourceOrigin,p.normal,p.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
                  abs(hypot(p.normal.x,p.normal.y)-1)<1e-6,
                  abs(hypot(p.along.x,p.along.y)-1)<1e-6,
                  abs(p.normal.x*p.along.x+p.normal.y*p.along.y)<1e-6,
                  body.sourceAuthenticatedContrastBodyMask.count==pixelCount,
                  body.uniqueMaskPixels==body.sourceAuthenticatedContrastBodyMask.filter({$0 != 0}).count,
                  validFootprint(fp),
                  abs(CGFloat(fp.width)*fp.scaleX-CGFloat(window.frameSize.width))<=1e-6,
                  abs(CGFloat(fp.height)*fp.scaleY-CGFloat(window.frameSize.height))<=1e-6,
                  body.actualPalettes.count<=16,
                  body.actualPalettes.allSatisfy({$0.rgb.count==3 && $0.rgb.allSatisfy({(0...255).contains($0)})}) else {
                return failure("unavailable-peer-body-same-source-window-full-native-binding")
            }
            peerCellWork+=fp.cells.count
            guard peerCellWork<=maximumFootprintCells else{return failure("peer-full-footprint-cell-budget-exceeded")}
            peerFootprints.append(fp)
            peerBindings.append(["sourceIndexDictionaryKey":key,
                "actualFullFootprintSHA256":footprintDigest(fp),"actualFullFootprintCells":fp.cells.count,
                "actualGGBodySHA256":digest(body.sourceAuthenticatedContrastBodyMask),"actualRGBA_SHA256":rgbaSHA,
                "preparedQuery":p.inherited.map{[Double($0.x),Double($0.y)]},
                "preparedQueryIsNotForeground":true,"currentlyRetainedGraphSource":graph.live.contains(key),
                "keyProvenance":"actual-F.captureLive-peerBodies-dictionary-contract",
                "nativeMembershipIsNotReassigned":true])
        }
        var missingPeerPolygons:[[CGPoint]]=[],missingPeerBindings:[[String:Any]]=[]
        for peer in graph.live.sorted() where !members.contains(peer) {
            guard let polygon=graph.polygons[peer],liveQuad(polygon) else {
                return failure("unavailable-current-retained-peer-quad")
            }
            guard F.bounds(polygon).intersects(roi) else{continue}
            guard let actualPeer=graph.prior(peer),actualPeer.polygon==polygon else {
                return failure("unavailable-current-retained-peer-graph-binding")
            }
            // All supplied external body packets were validated above. Geometry
            // is used ONLY when the current retained peer has no actual body.
            if live.peerBodies[peer]==nil {
                guard missingPeerPolygons.count<256 else{return failure("local-missing-peer-quad-budget-exceeded")}
                missingPeerPolygons.append(polygon)
                missingPeerBindings.append(["sourceIndex":peer,"currentPolygon":polygon.map{[Double($0.x),Double($0.y)]},
                    "actualBodyAvailable":false,"role":"uncertainty-only-not-foreground-not-owner"])
            }
        }
        guard let views=NativeOCRSourceLiveStroke404.maskViews(actualPeerFootprints:peerFootprints,missingRetainedPeerPolygons:missingPeerPolygons) else {
            return failure("unavailable-bounded-actual-peer-mask-views")
        }
        let evidence=K.Evidence(rgba:.init(bytes:r.bytes,width:r.width,height:r.height,
            bytesPerRow:r.bytesPerRow,origin:r.origin),body:rootBody,privateAt:{rootFP.contains($0)},
            nativeCellCenters:nativePoints,detectors:detectors,rf:rf)
        let basis=K.Basis(origin:measurement.origin,normal:measurement.normal,along:measurement.along)
        // Exactly once for this root/session. Original model support nominates
        // literal408 rows; GG/native membership is never a foreground assignment.
        let roles408=SourceContrastRole408.assess(evidence:evidence,basis:basis,nativeW:nativeW,
            seedMode:.originalNativeSupport)
        var missing=[
            "F.LiveObservation has no full-frame SHA/imageIdentity; local byte SHA binds actual supplied RGBA only",
            "Body.Prepared has no sourceIndex; peer key identity relies on actual F.captureLive construction",
            "F.LiveObservation omits peer Measurements, so their retained-private equality is not independently available here",
            "literalExterior companion is not invoked by this closed-contrast-only bridge"
        ]
        if layout != nil {missing.append("RF imageIdentity has no matching LiveObservation frame token; caller retains actual same-source RF/RGB binding")}
        if nearbyMissingPackets>0 {missing.append("nearby original detector packets missing: "+String(nearbyMissingPackets))}
        let binding:[String:Any]=["family":"source-live-closed-contrast418","status":"actual-input-packets-bound-query418-prepared",
            "actualCurrentPrior":prior.polygon.map{[Double($0.x),Double($0.y)]},
            "actualCurrentPriorSHA256":polygonDigest(prior.polygon),"actualSourceIndices":indices,
            "actualAssociationKey":prior.inheritedAssociationKey.map{$0 as Any} ?? NSNull(),
            "nativeW":Double(nativeW),"measurementKind":measurement.kind,
            "actualBasis":["origin":[Double(measurement.origin.x),Double(measurement.origin.y)],
                "normal":[Double(measurement.normal.x),Double(measurement.normal.y)],
                "along":[Double(measurement.along.x),Double(measurement.along.y)]],
            "actualRGBA_SHA256":rgbaSHA,"actualRootGGBodySHA256":digest(rootBody),
            "actualRootFullFootprintSHA256":footprintDigest(rootFP),"actualNativeCellCenterCount":nativePoints.count,
            "memberBindings":memberBindings,"peerBindings":peerBindings,
            "ignoredCurrentMemberPeerDictionaryKeys":ignoredMemberPeerKeys,
            "missingCurrentRetainedPeerBodies":missingPeerBindings,
            "foreignMaskRole":"union-of-actual-live-peerBodies-full-native-footprints-only",
            "uncertainMaskRole":"current-retained-graph-peer-quads-without-actual-body-only",
            "rootedBorrowedForeignPolicy":"context-memberships-only-query-is-never-registered-as-a-native-GG-seed",
            "window":[window.left,window.top,window.width,window.height],
            "frameSize":[window.frameSize.width,window.frameSize.height],
            "detectors":detectorReceipts,"rfText":rfReceipts,
            "sourceRFPresent":layout != nil,"sourceRFImageIdentity":layout?.imageIdentity as Any? ?? NSNull(),
            "capturedRawSHA256":NSNull(),"fullFrameSHA256":NSNull(),
            "fullCurrentProbeVerified":true,"nativeFullFootprintMatchesRetainedMeasurement":true,
            "metadataDifferences392":differences,"graphAndPriorMutated":false,"ownershipChanged":false,
            "frameCalls":0,"sourceAcquisitionCalls":0,"source400ScalarOrDescriptorAccepted":false,
            "nativeAdmissionSuiteRun":false,"admissionGranted":false]
        var receipt:[String:Any]=["family":"source-live-closed-contrast418","status":"prepared",
            "experimentEnabled":true,"role408Passes":1,"literal408Receipt":roles408.receipt,
            "querySeedMode":"actual-source-pixel-location-not-native-GG-seed",
            "literalExteriorCompanionRun":false,"geometryProduced":false,"mandatoryReplaced":false,
            "unknownPolicy":"receipt-deferred-parent-policy-owned-no-fallback-or-allow-decision",
            "positiveMeaning":"supplemental-positive-contrast-cell-protection-cue-only",
            "source400ScalarOrDescriptorAccepted":false,"nativeAdmissionSuiteRun":false,
            "ownershipChanged":false,"admissionGranted":false,"frameCalls":0,"sourceAcquisitionCalls":0]
        receipt["exactMissing"]=missing
        let session=Session(old:prior.polygon,basis:basis,nativeW:nativeW,evidence:evidence,
            roles408:roles408,peerViews:views,binding:binding,missing:missing)
        return .init(session:session,receipt:receipt,sourceBinding:binding,exactMissing:missing)
    }
    private static func sameWindow(_ a:F.Body.Window,_ b:F.Body.Window)->Bool {
        a.frameSize==b.frameSize && a.left==b.left && a.top==b.top && a.width==b.width && a.height==b.height
    }
    private static func validFootprint(_ f:F.Footprint)->Bool {
        f.width>0 && f.height>0 && f.width<=Int.max/f.height && f.scaleX.isFinite && f.scaleY.isFinite
            && f.scaleX>0 && f.scaleY>0 && !f.cells.isEmpty && f.cells.count<=maximumFootprintCells
            && f.cells.allSatisfy{$0>=0 && $0<f.width*f.height}
    }
    private static func digest(_ bytes:[UInt8])->String {
        SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
    }
    private static func footprintDigest(_ f:F.Footprint)->String {
        var bytes=Data()
        func append(_ n:UInt64) {var v=n.littleEndian;withUnsafeBytes(of:&v){bytes.append(contentsOf:$0)}}
        append(UInt64(f.width));append(UInt64(f.height));append(Double(f.scaleX).bitPattern);append(Double(f.scaleY).bitPattern)
        for cell in f.cells.sorted() {append(UInt64(cell))}
        return SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
    private static func polygonDigest(_ p:[CGPoint])->String {
        var bytes=Data()
        for point in p {for n in [Double(point.x),Double(point.y)] {
            var bits=n.bitPattern.littleEndian;withUnsafeBytes(of:&bits){bytes.append(contentsOf:$0)}
        }}
        return SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
    private static func liveQuad(_ q:[CGPoint])->Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        let cross=(0..<4).map{i -> CGFloat in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return cross.allSatisfy{$0>1e-9} || cross.allSatisfy{$0 < -1e-9}
    }
}
