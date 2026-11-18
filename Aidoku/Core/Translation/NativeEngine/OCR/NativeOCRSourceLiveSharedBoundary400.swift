import Foundation
import CoreGraphics
import CryptoKit

/// Actual native typed bridge to396. Observation only; no acquisition, ownership or admission.
@available(iOS 18.0, *)
enum NativeOCRSourceLiveSharedBoundary400 {
    typealias Result = NativeOCRSourceOrientation391.Result
    typealias K = NativeOCRSharedBoundary396
    static let maximumOffers = 96
    typealias F = NativeOCRSourceLocalJoint369

    static func generateFromLive(prior: NativeOCRCurrentPrior351.Resolution,
        graph: NativeOCRSourceLocalJoint369Capture.FinalGraph,
        measurement: F.M, live: F.LiveObservation,
        actualOriginalSeedEvidence originals: [NativeCoreMLDetectionBox],
        sourceRF layout: NativeRFDETRLayoutResult?) -> Result {
        let started = Date()
        func failure(_ reason:String)->Result {
            .init(offers:[],receipt:["family":"source-shared-boundary400","status":reason,
                "sourceOnly":true,"GTRead":false,"admissionGranted":false,
                "automaticSelection":false,"ownershipChanged":false,"nativeAdmissionSuiteRun":false,
                "allSourceSupportObserved":false,"capturedRawSHA256":NSNull(),
                "frameCalls":0,"sourceAcquisitionCalls":0,
                "freshReadRequired":reason.contains("fresh-read-required")])
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
        let rgbaSHA=SHA256.hash(data:Data(r.bytes)).map{String(format:"%02x",$0)}.joined()
        let pixelCount=r.width*r.height
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
                  b.origin==r.origin,b.width==r.width,b.height==r.height,
                  b.bytesPerRow==r.bytesPerRow,b.bytes==r.bytes,
                  e.sourceAuthenticatedContrastBodyMask.count==pixelCount,
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
            for (a,b) in zip(e.actualPalettes,retained.palettes) {
                guard a.rgb==b.rgb,a.bin==b.bin,a.sourceSeedBinCount==b.sourceSeedBinCount,
                      a.rgb.count==3,a.rgb.allSatisfy({(0...255).contains($0)}) else {
                    return failure("unavailable-actual-native-palette-binding")
                }
            }
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
        var nearbyMissingPackets=0
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
        let output=K.generate(actualOld:prior.polygon,
            basis:.init(origin:measurement.origin,normal:measurement.normal,along:measurement.along),
            nativeW:nativeW,evidence:.init(rgba:.init(bytes:r.bytes,width:r.width,height:r.height,
                bytesPerRow:r.bytesPerRow,origin:r.origin),body:rootBody,privateAt:{rootFP.contains($0)},
                nativeCellCenters:nativePoints,detectors:detectors,rf:rf))
        let rootBodySHA=digest(rootBody)
        var seen=Set<String>(),offers:[[String:Any]]=[]
        for proposal in output.proposals.prefix(maximumOffers) {
            let key="source-shared-boundary400-"+proposal.suffix
            guard seen.insert(key).inserted,liveQuad(proposal.polygon) else {
                return failure("invalid-or-duplicate-shared396-output-key")
            }
            var receipt=proposal.receipt
            receipt["kernelFamily"]=receipt["family"];receipt["family"]="source-shared-boundary400"
            receipt["actualCurrentPrior"]=prior.polygon.map{[Double($0.x),Double($0.y)]}
            receipt["actualRGBA_SHA256"]=rgbaSHA;receipt["actualRootGGBodySHA256"]=rootBodySHA
            receipt["actualRootRawSHA256"]=NSNull();receipt["capturedRawSHA256"]=NSNull()
            receipt["sourceConsensusSHA256"]=NSNull()
            receipt["nativeFullFootprintMatchesRetainedMeasurement"]=true
            receipt["actualNativeCellCenterCount"]=nativePoints.count
            receipt["allSourceSupportObserved"]=false
            receipt["nativeAdmissionSuiteRun"]=false;receipt["automaticSelection"]=false
            offers.append(["family":"source-shared-boundary400","key":key,
                "polygon":proposal.polygon.map{[Double($0.x),Double($0.y)]},"sourceReceipt":receipt,
                "hardRejections":[String](),"softRejections":proposal.obligations,"obligations":proposal.obligations,
                "admissionGranted":false,"nativeAdmissionSuiteRun":false,"automaticSelection":false])
        }
        return .init(offers:offers,receipt:["family":"source-shared-boundary400",
            "status":"actual-live-shared396-source-hypotheses-only","sourceOnly":true,"GTRead":false,
            "sourceObservation":output.receipt,"actualCurrentPrior":prior.polygon.map{[Double($0.x),Double($0.y)]},
            "actualSourceIndices":indices,"actualAssociationKey":prior.inheritedAssociationKey.map{$0 as Any} ?? NSNull(),
            "actualRGBA_SHA256":rgbaSHA,"actualRootGGBodySHA256":rootBodySHA,"capturedRawSHA256":NSNull(),
            "nativeFullFootprintMatchesRetainedMeasurement":true,"actualNativeCellCenterCount":nativePoints.count,
            "detectors":detectorReceipts,"rfText":rfReceipts,"nearbyMissingOriginalDetectorPackets":nearbyMissingPackets,
            "sourceRFPresent":layout != nil,"sourceRFImageIdentity":layout?.imageIdentity as Any? ?? NSNull(),
            "rootOnlyBodyAnchors":true,"peerMasksConferOwnership":false,"fullCurrentProbeVerified":true,
            "originalOldEdgeDirectionsPreserved":true,"actualOldAndGraphChanged":false,
            "kernelOfferCount":output.proposals.count,"maximumDeliveredOffers":maximumOffers,
            "proposalCount":offers.count,"offersOmittedByAdapterBudget":max(0,output.proposals.count-maximumOffers),
            "sourceNativeOldAndGraphRemainActual386":true,"allSourceSupportObserved":false,
            "frameCalls":0,"sourceAcquisitionCalls":0,"seconds":Date().timeIntervalSince(started),
            "nativeAdmissionSuiteRun":false,"admissionGranted":false,"automaticSelection":false,"ownershipChanged":false])
    }
    private static func digest(_ bytes:[UInt8])->String {
        SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
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
