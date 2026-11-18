import Foundation
import CoreGraphics
import CryptoKit

/// Actual typed live bridge. Reuses 400's authentication/evidence construction,
/// NOT its generated offers, scalars, descriptors or native-admission outcomes.
/// No reads, model calls, frame capture, graph mutation or production integration.
@available(iOS 18.0, *)
enum NativeOCRSourceLiveStroke404 {
    typealias F = NativeOCRSourceLocalJoint369
    typealias K = NativeOCRSharedBoundary396
    typealias G = NativeOCRSourceAssociatedStroke404
    static let maximumFootprintCells=4_000_000
    static let maximumOriginalRunCells=4_000_000
    struct Output {
        let polygon:[CGPoint]?
        let receipt:[String:Any]
        let sourceBinding:[String:Any]
        let exactMissing:[String]
    }
    struct Preparation {
        let session:Session?
        let receipt:[String:Any]
        let sourceBinding:[String:Any]
        let exactMissing:[String]
    }
    /// Footprints here must be real Body.Evidence.actualFullFootprint values.
    /// Missing-peer polygons are uncertainty ONLY, never positive ink/ownership.
    struct MaskViews {
        let actualPeerFootprints:[F.Footprint]
        let missingRetainedPeerPolygons:[[CGPoint]]
        func foreignAt(_ p:CGPoint)->Bool {actualPeerFootprints.contains{$0.contains(p)}}
        func uncertainAt(_ p:CGPoint)->Bool {missingRetainedPeerPolygons.contains{F.contains($0,p)}}
    }
    static func maskViews(actualPeerFootprints:[F.Footprint],missingRetainedPeerPolygons:[[CGPoint]])->MaskViews? {
        guard actualPeerFootprints.count<=256,missingRetainedPeerPolygons.count<=256,
              actualPeerFootprints.allSatisfy(validFootprint),
              missingRetainedPeerPolygons.allSatisfy(liveQuad),
              actualPeerFootprints.reduce(0,{$0+$1.cells.count})<=maximumFootprintCells else{return nil}
        return .init(actualPeerFootprints:actualPeerFootprints,missingRetainedPeerPolygons:missingRetainedPeerPolygons)
    }
    final class Session {
        private let core:G.Session
        let sourceBinding:[String:Any]
        let exactMissing:[String]
        fileprivate init(core:G.Session,sourceBinding:[String:Any],exactMissing:[String]) {
            self.core=core;self.sourceBinding=sourceBinding;self.exactMissing=exactMissing
        }
        /// Exact typed delegation; no synthetic seed or geometry conversion.
        func unresolvedLostPositions(proposed q:[CGPoint])->[CGPoint]? {
            core.unresolvedLostPositions(proposed:q)
        }
        /// Read-only404 association observations, not ownership assignment.
        func protectedAssociatedCellCenters()->[CGPoint]? {
            core.protectedAssociatedCellCenters()
        }
        func repair(proposed q:[CGPoint])->Output {
            // Pass the EXACT typed polygon. Never regenerate a 400 candidate or
            // align/sort/round/rotate the supplied candidate before repair.
            let fixed=core.repair(proposed:q)
            var binding=sourceBinding
            binding["exactInputProposedPolygon"]=q.map{[Double($0.x),Double($0.y)]}
            if q.count==4 && q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) {binding["exactInputProposedPolygonSHA256"]=NativeOCRSourceLiveStroke404.polygonDigest(q)}
            if let p=fixed.polygon {binding["repairedPolygonSHA256"]=NativeOCRSourceLiveStroke404.polygonDigest(p)}
            var receipt=fixed.receipt
            receipt["adapterFamily"]="source-live-stroke404"
            receipt["source400ScalarOrDescriptorAccepted"]=false
            receipt["parentRecomputeRequired"]=NativeOCRSourceLiveStroke404.parentRecomputeRequired
            receipt["nativeAdmissionSuiteRun"]=false;receipt["nativeReadmissionRequired"]=true
            receipt["admissionGranted"]=false;receipt["automaticSelection"]=false
            receipt["geometryIsNotSource400RawOffer"]=true
            receipt["missingIndependentBindings"]=exactMissing
            return .init(polygon:fixed.polygon,receipt:receipt,sourceBinding:binding,exactMissing:exactMissing)
        }
    }
    static func repairFromLive(proposed:[CGPoint],prior:NativeOCRCurrentPrior351.Resolution,
        graph:NativeOCRSourceLocalJoint369Capture.FinalGraph,measurement:F.M,live:F.LiveObservation,
        actualOriginalSeedEvidence originals:[NativeCoreMLDetectionBox],sourceRF layout:NativeRFDETRLayoutResult?)->Output {
        let prepared=prepareFromLive(prior:prior,graph:graph,measurement:measurement,live:live,
            actualOriginalSeedEvidence:originals,sourceRF:layout)
        guard let session=prepared.session else {
            return .init(polygon:nil,receipt:prepared.receipt,sourceBinding:prepared.sourceBinding,exactMissing:prepared.exactMissing)
        }
        return session.repair(proposed:proposed)
    }
    static func prepareFromLive(prior:NativeOCRCurrentPrior351.Resolution,
        graph:NativeOCRSourceLocalJoint369Capture.FinalGraph,measurement:F.M,live:F.LiveObservation,
        actualOriginalSeedEvidence originals:[NativeCoreMLDetectionBox],sourceRF layout:NativeRFDETRLayoutResult?)->Preparation {
        func failure(_ reason:String)->Preparation {
            .init(session:nil,receipt:["family":"source-live-stroke404","status":reason,
                "sourceOnly":true,"GTRead":false,"admissionGranted":false,"automaticSelection":false,
                "ownershipChanged":false,"nativeAdmissionSuiteRun":false,"frameCalls":0,"sourceAcquisitionCalls":0,
                "freshReadRequired":reason.contains("fresh-read-required"),"parentRecomputeRequired":parentRecomputeRequired],
                sourceBinding:[:],exactMissing:[reason])
        }
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
            // actual external borrowed-original packets are handled by core404.
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
        guard let views=maskViews(actualPeerFootprints:peerFootprints,missingRetainedPeerPolygons:missingPeerPolygons) else {
            return failure("unavailable-bounded-actual-peer-mask-views")
        }
        let evidence=K.Evidence(rgba:.init(bytes:r.bytes,width:r.width,height:r.height,
            bytesPerRow:r.bytesPerRow,origin:r.origin),body:rootBody,privateAt:{rootFP.contains($0)},
            nativeCellCenters:nativePoints,detectors:detectors,rf:rf)
        guard let core=G.prepare(actualOld:prior.polygon,
            basis:.init(origin:measurement.origin,normal:measurement.normal,along:measurement.along),
            nativeW:nativeW,evidence:evidence,foreignAt:views.foreignAt,uncertainAt:views.uncertainAt) else {
            return failure("unavailable-404-rooted-actual-RGB-session")
        }
        // Explicit limitations of the REAL input types, not invented fields.
        var missing=[
            "F.LiveObservation has no full-frame source SHA/imageIdentity; actualRGBA_SHA256 binds the supplied local bytes only",
            "Body.Prepared has no sourceIndex; peer dictionary-key identity relies on actual F.captureLive construction",
            "F.LiveObservation does not retain peer Measurements; peer retained-privateObservation equality cannot be independently compared here",
            "404 component IDs/receipts are not 400 sourceSupportComponents; complete 400-compatible support descriptors must be freshly recomputed"
        ]
        if layout != nil {
            missing.append("RF imageIdentity cannot be matched to a frame identity absent from F.LiveObservation; caller must bind RF and original RGB to the same actual source")
        } else {
            missing.append("sourceRF is nil: no same-word RF corroboration is available; no RF geometry is synthesized")
        }
        if nearbyMissingPackets>0 {
            missing.append("nearby original detector packets unavailable: "+String(nearbyMissingPackets)+"; no replacement quad-ink or scalar evidence supplied")
        }
        let binding:[String:Any]=["family":"source-live-stroke404","status":"actual-input-packets-bound-404-session-prepared",
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
            "rootedBorrowedForeignPolicy":"unchanged-core404-real-native-GG-root-wins-no-ownership-mutation",
            "window":[window.left,window.top,window.width,window.height],
            "frameSize":[window.frameSize.width,window.frameSize.height],
            "detectors":detectorReceipts,"rfText":rfReceipts,
            "sourceRFPresent":layout != nil,"sourceRFImageIdentity":layout?.imageIdentity as Any? ?? NSNull(),
            "capturedRawSHA256":NSNull(),"fullFrameSHA256":NSNull(),
            "fullCurrentProbeVerified":true,"nativeFullFootprintMatchesRetainedMeasurement":true,
            "metadataDifferences392":differences,"graphAndPriorMutated":false,"ownershipChanged":false,
            "frameCalls":0,"sourceAcquisitionCalls":0,"source400ScalarOrDescriptorAccepted":false,
            "nativeAdmissionSuiteRun":false,"admissionGranted":false]
        var receipt=core.receipt
        receipt["adapterFamily"]="source-live-stroke404";receipt["parentRecomputeRequired"]=parentRecomputeRequired
        receipt["missingIndependentBindings"]=missing;receipt["source400ScalarOrDescriptorAccepted"]=false
        receipt["nativeAdmissionSuiteRun"]=false;receipt["admissionGranted"]=false
        let session=Session(core:core,sourceBinding:binding,exactMissing:missing)
        return .init(session:session,receipt:receipt,sourceBinding:binding,exactMissing:missing)
    }

    /// All policy fields must be re-described from repaired geometry AND fresh
    /// actual support. These names match the inspected SourceBoundary400Policy.
    /// Merely replacing rawOffer.polygon while retaining old sourceReceipt is invalid.
    static let parentRecomputeRequired:[String]=[
        "rawOffer.polygon and proposed native candidate geometry",
        "sourceReceipt.signedEdgePlaneChanges and edgeBits from actualOld to repaired",
        "sourceReceipt.newlyExcludedActualNativeCellCenters against original complete native membership",
        "sourceReceipt.newlyExcludedOriginalGGBodyPixels against same actual root GG mask",
        "sourceReceipt.sourceSupportComponentIDs and edgeActualSupport from fresh actual support; no 400/404 ID equivalence",
        "sourceObservation.sourceSupportComponents including actualPixelCount, actualRootPrivateBodyAnchors, originalGGBodyPixels, projectedActualCellBounds, RFTextQueryIDs, originalRGBCCClippedAtCapture",
        "sourceReceipt.rootRFTextQueries, rootDetectorActualCellAgreement, otherDetectorEvidenceOrdinals, actualContourContactAdded",
        "SourceBoundary400Policy.describe: areaRatio,widthRatio,alongRatio,priorAspect,selectedComponents,selectedActualPixels,privateAnchorFraction,ggBodyFraction,nativeAnchoredPixelFraction,rootRFSupportedPixelFraction,selectedClippedFraction",
        "SourceBoundary400Policy.describe: nativeCellLoss,nativeCellLossFraction,sourceGGBodyLoss,planeExpansionSumSourceW,planeContractionSumSourceW,planeChangeMaxSourceW,changedEdges",
        "SourceBoundary400Policy.describe: rootDetectorCellAgreement,rootRFMatches,otherDetectorEvidenceCount,contourContactAdded,sourceScore,sourceAxisResidual,componentAlongMaxSourceW,componentWidthMaxSourceW,centerShift",
        "source00...source21: parent must recompute or independently rebind the exact actual precoord prefix; no old descriptor promotion",
        "reapply any policy bounds and ranking on a fresh repaired descriptor; old selection/native-order result is not acceptance",
        "all actual native admission/semantic/caps/foreign/uncertain/ownership/whole/dense/GG tests on repaired polygon; robust IoU and parent final selection"
    ]
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
