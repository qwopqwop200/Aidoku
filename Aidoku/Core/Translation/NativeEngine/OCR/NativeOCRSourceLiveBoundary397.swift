import Foundation
import CoreGraphics
import CryptoKit

/// Post391/pre392 source-only observation. No capture, acquisition, selection or graph mutation.
@available(iOS 18.0, *)
enum NativeOCRSourceLiveBoundary397 {
    typealias Result = NativeOCRSourceOrientation391.Result
    typealias K = NativeOCROutlineBoundary397Kernel
    static let maximumCores = 128
    typealias F = NativeOCRSourceLocalJoint369

    static func generateFromLive(prior: NativeOCRCurrentPrior351.Resolution,
        graph: NativeOCRSourceLocalJoint369Capture.FinalGraph,
        measurement: F.M, live: F.LiveObservation,
        cores inputCores: NativeOCRSourceOrientation391.Result, actualPriorOnly: Bool = false, nativeAnchoredSeeds: Bool = false) -> Result {
        let cores: Result = actualPriorOnly ? .init(offers:[],receipt:[
            "status":"orientation391-not-run-actual-prior-only","sourceOnly":true,"GTRead":false]) : inputCores
        let family = nativeAnchoredSeeds ? "source-boundary-prior399" : (actualPriorOnly ? "source-boundary-prior397" : "source-boundary-orientation397")
        let started = Date()
        func failure(_ reason:String)->Result {
            .init(offers:[],receipt:["family":family,"status":reason,
                "sourceOnly":true,"GTRead":false,"actualPriorOnly":actualPriorOnly,"nativeAnchoredSeeds":nativeAnchoredSeeds,"admissionGranted":false,
                "automaticSelection":false,"ownershipChanged":false,"nativeAdmissionSuiteRun":false,
                "allSourceSupportObserved":false,"capturedRawSHA256":NSNull(),
                "unresolvedOpenRays":NSNull(),"frameCalls":0,"sourceAcquisitionCalls":0,
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
        var body=[UInt8](repeating:0,count:r.width*r.height)
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
                  e.sourceAuthenticatedContrastBodyMask.count==body.count,
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
            for i in body.indices where e.sourceAuthenticatedContrastBodyMask[i] != 0 {body[i]=1}
        }
        let sharedBodySHA=digest(body)
        // Do not rerun391 or treat its union body/geometric cores as root ink.
        guard cores.offers.count < maximumCores else {
            return failure("unavailable-core-budget-including-one-actual-retained-prior")
        }
        if !cores.offers.isEmpty {
            guard cores.receipt["sourceOnly"] as? Bool == true,
                  cores.receipt["GTRead"] as? Bool == false,
                  cores.receipt["sharedActualBodySHA256"] as? String == sharedBodySHA,
                  let binding = cores.receipt["liveBinding"] as? [String: Any],
                  binding["actualSourceIndices"] as? [Int] == indices,
                  binding["actualRGBA_SHA256"] as? String == rgbaSHA,
                  points(binding["actualCurrentPrior"]) == prior.polygon else {
                return failure("unavailable-orientation391-live-core-batch-binding-or-budget")
            }
        }
        let rootBody = live.bodies[0].sourceAuthenticatedContrastBodyMask
        let rootFP = live.bodies[0].actualFullFootprint
        let nativeW = CGFloat(measurement.rect.width)
        // Match397's source-basis actual386 +/- one native width observation probe.
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
        var seen=Set<String>()
        // Validate the entire menu before spending a shared ray budget.
        for raw in cores.offers {
            guard let key=raw["key"] as? String,!key.isEmpty,seen.insert(key).inserted,
                  let q=points(raw["polygon"]),liveQuad(q),
                  let cr=raw["sourceReceipt"] as? [String:Any],
                  points(cr["actualCurrentPrior"]) == prior.polygon,
                  cr["actualRGBA_SHA256"] as? String == rgbaSHA,
                  cr["actualRootRawSHA256"] is NSNull,
                  cr["sharedActualBodySHA256"] as? String == sharedBodySHA,
                  let w=cr["nativeW"] as? Double,w == Double(nativeW) else {
                return failure("unavailable-live-core-provenance-or-duplicate-key")
            }
        }
        let session: K.Session
        do {
            session=try K.Session(rgba:.init(bytes:r.bytes,width:r.width,height:r.height,
                bytesPerRow:r.bytesPerRow,origin:r.origin),body:rootBody,
                privateAt:{rootFP.contains($0)},actualOld:prior.polygon,
                basis:.init(origin:measurement.origin,normal:measurement.normal,along:measurement.along),nativeW:nativeW,nativeAnchoredSeeds:nativeAnchoredSeeds)
        } catch let invalid as K.Invalid { return failure(invalid.reason)
        } catch { return failure("unavailable-root-GG-boundary-session") }
        let bodySHA=digest(rootBody)
        // Independent geometric input, read directly from actual final386 graph.
        // No391 fit, shrink, padding, body-union receipt or capture artifact is attributed to it.
        let actualPriorKey="actual-retained386-prior-core397"
        guard !seen.contains(actualPriorKey) else { return failure("duplicate-actual-retained-prior-core-key") }
        var menu=cores.offers
        menu.append(["key":actualPriorKey,"polygon":prior.polygon.map{[Double($0.x),Double($0.y)]},
            "sourceReceipt":["coreOrigin":"actual-retained386-prior","actualGraphPriorDirect":true,
                "actualCurrentPrior":prior.polygon.map{[Double($0.x),Double($0.y)]},
                "actualSourceIndices":indices,"actualRGBA_SHA256":rgbaSHA,
                "actualRootRawSHA256":NSNull(),"capturedRawSHA256":NSNull(),
                "coreArtifactSHA256":NSNull(),"actualRootGGBodySHA256":bodySHA,
                "nativeW":Double(nativeW),"orientation391Derived":false,
                "coreIsForegroundOrOwnership":false,"admissionGranted":false] as [String:Any]])
        var offers:[[String:Any]]=[],observations:[[String:Any]]=[]
        for raw in menu {
            // Proven above; do not skip a measured core because of another core's result.
            let key=raw["key"] as! String,core=points(raw["polygon"])!
            let repaired=session.repair(core:core)
            var receipt=repaired.receipt
            receipt["kernelFamily"]=receipt["family"]
            receipt["family"]=family
            let edges=receipt["edgeObservations"] as? [[String:Any]] ?? []
            let openCount=edges.reduce(0) { total, edge in
                total + (edge["openFillOrRimAtProbeOrBound"] as? Int ?? 0) +
                    (edge["unqualifiedOrAmbiguousRayCount"] as? Int ?? 0)
            }
            // Kernel397's flag counts fresh-read rays. Also disclose every relevant
            // unqualified/ambiguous ray; none can certify complete boundary support.
            receipt["kernelUnresolvedOpenRays"]=receipt["unresolvedOpenRays"] ?? NSNull()
            receipt["unresolvedOpenRays"] = session.budgetExhausted || edges.count != 4 ? NSNull() : (openCount>0) as Any
            receipt["openRayObservationIncomplete"]=session.budgetExhausted || edges.count != 4
            receipt["unresolvedOpenRayCount"]=openCount
            let actualOldCore=key==actualPriorKey
            receipt["coreKey"]=key
            receipt["coreOrigin"]=actualOldCore ? "actual-retained386-prior":"orientation391-live"
            receipt["orientation391Derived"] = !actualOldCore
            receipt["coreArtifactSHA256"]=NSNull()
            receipt["actualCurrentPrior"]=prior.polygon.map{[Double($0.x),Double($0.y)]}
            receipt["actualRGBA_SHA256"]=rgbaSHA
            receipt["actualRootRawSHA256"]=NSNull()
            receipt["capturedRawSHA256"]=NSNull()
            receipt["actualRootGGBodySHA256"]=bodySHA
            receipt["coreDeclaredSharedBodySHA256"]=actualOldCore ? NSNull() : (cores.receipt["sharedActualBodySHA256"] ?? NSNull())
            receipt["coreDeclaredBodyUsedAsSourceAnchor"]=false
            receipt["originalCoreSourceReceipt"]=raw["sourceReceipt"]
            receipt["nativeFullFootprintMatchesRetainedMeasurement"]=true
            receipt["allSourceSupportObserved"]=false
            receipt["admissionGranted"]=false
            receipt["nativeAdmissionSuiteRun"]=false
            receipt["automaticSelection"]=false
            observations.append(receipt)
            if let polygon=repaired.polygon {
                let obligations=["actual-native-whole-dense-GG-semantics-required",
                    "foreign-peer-new-acquisition-ownership-unresolved","no-erasure-authority"] +
                    (openCount>0 ? ["unresolved-open-or-ambiguous-source-rays"]:[])
                offers.append(["family":family,
                    "key":"outline-boundary-hypotheses397-"+key,"originalCoreKey":key,
                    "polygon":polygon.map{[Double($0.x),Double($0.y)]},"sourceReceipt":receipt,
                    "hardRejections":[String](),"softRejections":obligations,"obligations":obligations,
                    "admissionGranted":false,"automaticSelection":false,"nativeAdmissionSuiteRun":false])
            }
            if session.budgetExhausted { break }
        }
        let exhausted=session.budgetExhausted
        // Same397 rule: retain diagnostics but discard ALL offers on root budget exhaustion.
        if exhausted { offers=[] }
        return .init(offers:offers,receipt:["family":family,
            "status":exhausted ? "source-session-budget-exhausted-no-partial-root-delivery":"measured-hypotheses-only",
            "sourceOnly":true,"GTRead":false,"inputCoreCount":menu.count,
            "orientation391CoreCount":cores.offers.count,"actualRetainedPriorCoreCount":1,
            "actualPriorOnly":actualPriorOnly,"nativeAnchoredSeeds":nativeAnchoredSeeds,"orientation391InvokedByAdapter":false,
            "attemptedCoreCount":observations.count,"proposalCount":offers.count,"maximumCores":maximumCores,
            "coreObservations":observations,"sharedSourceSession":session.summary(),
            "orientation391Receipt":cores.receipt,"actualSourceIndices":indices,
            "actualCurrentPrior":prior.polygon.map{[Double($0.x),Double($0.y)]},
            "actualAssociationKey":prior.inheritedAssociationKey.map{$0 as Any} ?? NSNull(),
            "actualRGBA_SHA256":rgbaSHA,"actualRootGGBodySHA256":bodySHA,"capturedRawSHA256":NSNull(),
            "rootOnlyBodyAnchors":true,"peerMasksConferOwnership":false,"fullCurrentProbeVerified":true,
            "sourceNativeOldRemainsActual386":true,"sourceNativeGraphRemainsActual386":true,
            "unresolvedOpenRays":exhausted ? NSNull() : observations.contains{$0["unresolvedOpenRays"] as? Bool == true} as Any,
            "allSourceSupportObserved":false,"frameCalls":0,"sourceAcquisitionCalls":0,
            "seconds":Date().timeIntervalSince(started),"nativeAdmissionSuiteRun":false,
            "admissionGranted":false,"automaticSelection":false,"ownershipChanged":false])
    }
    private static func digest(_ bytes:[UInt8])->String {
        SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
    }
    private static func points(_ value:Any?)->[CGPoint]? {
        guard let v=value as? [[Double]],v.count==4,
              v.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else{return nil}
        return v.map{CGPoint(x:$0[0],y:$0[1])}
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
