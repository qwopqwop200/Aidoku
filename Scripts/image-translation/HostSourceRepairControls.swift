import Foundation
import CoreGraphics

/// Parent-run in an ACTUAL native-type compilation context. No surrogate M,
/// LiveObservation, Body, FinalGraph or detector/RF definitions are supplied.
/// run() makes synthetic in-memory RGB and native Body packets; author did not run it.
@available(iOS 18.0, *)
enum NativeOCRSourceLiveStroke404Controls {
    typealias A = NativeOCRSourceLiveStroke404
    typealias F = NativeOCRSourceLocalJoint369
    typealias Body = NativeOCRSourceAuthenticatedBodyEvidence
    struct Failure:Error {let message:String}
    static func run() throws -> [String:Any] {
        var checks:[[String:Any]]=[]
        func check(_ ok:Bool,_ name:String) throws {
            if !ok {throw Failure(message:name)}
            checks.append(["check":name,"pass":true])
        }
        func quad(_ x0:CGFloat,_ y0:CGFloat,_ x1:CGFloat,_ y1:CGFloat)->[CGPoint] {
            [.init(x:x0,y:y0),.init(x:x1,y:y0),.init(x:x1,y:y1),.init(x:x0,y:y1)]
        }
        let width=240,height=260,old=quad(104,55,136,220),q=quad(110,60,130,145)
        let origin=CGPoint(x:120,y:130),normal=CGPoint(x:1,y:0),along=CGPoint(x:0,y:1)
        var bytes=[UInt8](repeating:255,count:width*height*4)
        for i in 0..<width*height {
            let ink=(117...123).contains(i%width) && (85...190).contains(i/width)
            let colour=ink ? [35,60,110]:[215,220,230]
            for c in 0..<3 {bytes[i*4+c]=UInt8(colour[c])}
        }
        guard let frame=NativeOCRRGBAFrame(width:width,height:height,bytesPerRow:width*4,bytes:bytes) else {
            throw Failure(message:"actual native Frame initializer")
        }
        // True sparse original native cells: upper stroke + observed background
        // provide actual palette contrast; no old/RF polygon is rasterized as ink.
        var state=NativeOCRPrivateObservation.State(),cells=Set<Int>()
        for y in 100...128 {for x in 118...128 where x<=122 || x>=125 {
            cells.insert(y*width+x)
            let p=CGPoint(x:CGFloat(x)+0.5-origin.x,y:CGFloat(y)+0.5-origin.y)
            state.append(floatRoundedLocal:p,origin:origin,normal:normal,along:along,pixelRGBA:{x,y in
                guard x>=0,x<width,y>=0,y<height else{return nil}
                let k=(y*width+x)*4
                return SIMD4<UInt8>(bytes[k],bytes[k+1],bytes[k+2],bytes[k+3])
            })
        }}
        var retained=state.retained
        retained.footprint = .init(width:width,height:height,scaleX:1,scaleY:1,cells:cells)
        var m=F.M(index:0,polygon:old,origin:origin,normal:normal,along:along,
            rect:.init(x:-33.5,y:-75,width:67,height:165))
        m.status="measured";m.kind="independent";m.hasInk=true
        m.privateSamples=retained.moments.count;m.privateObservation=retained
        guard let probe=F.probe(prior:old,sourceWidth:m.rect.width,frameSize:.init(width:width,height:height)),
              let body=Body.make(m,inherited:old,frameSize:.init(width:width,height:height),enabled:true,
                sharedWindow:probe.window,frameProvider:{frame}).evidence else {
            throw Failure(message:"actual native Body.make synthetic preparation")
        }
        var peer=F.M(index:1,polygon:quad(117,85,124,191),origin:origin,normal:normal,along:along,rect:m.rect)
        peer.status=m.status;peer.privateSamples=m.privateSamples;peer.privateObservation=retained
        guard let borrowed=Body.make(peer,inherited:probe.quad,frameSize:.init(width:width,height:height),enabled:true,
            sharedWindow:probe.window,frameProvider:{frame}).evidence else {
            throw Failure(message:"actual borrowed peer Body.make")
        }
        let polygons=[0:old,1:peer.polygon,2:quad(130,195,135,210)]
        let graph=NativeOCRSourceLocalJoint369Capture.FinalGraph(live:[0,1,2],suppressed:[],applied:[:],
            polygons:polygons,consumed:[],associations:[],groups:[:])
        guard let prior=graph.prior(0) else {throw Failure(message:"synthetic actual graph prior")}
        let live=F.LiveObservation(window:probe.window,rgba:body.sourceLocalRGBA,sources:[m],bodies:[body],
            mandatory:[],peerBodies:[1:borrowed],scopes:[])
        let prepared=A.prepareFromLive(prior:prior,graph:graph,measurement:m,live:live,
            actualOriginalSeedEvidence:[],sourceRF:nil)
        try check(prepared.session != nil,"prepare from real native live/body/full-RLE types")
        guard let session=prepared.session else {throw Failure(message:String(describing:prepared.receipt))}
        let result=session.repair(proposed:q)
        guard let repaired=result.polygon else {throw Failure(message:"actual synthetic live repair: "+String(describing:result.receipt))}
        try check(repaired.allSatisfy{F.contains(old,$0)},"live repair contained in actual prior")
        try check(q.allSatisfy{F.contains(repaired,$0)},"live repair only undoes raw contraction")
        try check(F.contains(repaired,.init(x:120.5,y:190.5)),"whole rooted bar tail restored")
        try check(result.sourceBinding["exactInputProposedPolygon"] as? [[Double]] == q.map{[Double($0.x),Double($0.y)]},"exact proposed polygon binding preserved")
        try check(result.receipt["source400ScalarOrDescriptorAccepted"] as? Bool==false,"old 400 scalars/descriptors not carried")
        try check(result.receipt["nativeAdmissionSuiteRun"] as? Bool==false && result.receipt["admissionGranted"] as? Bool==false,"native readmission remains parent owned")
        try check(!result.exactMissing.isEmpty,"nonexistent identity/index fields explicitly disclosed")
        let records=result.receipt["components"] as? [[String:Any]] ?? []
        try check(records.contains{($0["borrowedForeignPixelsRetainedOnlyForRootedCC"] as? Int ?? 0)>0},"borrowed real GG/native roots survive actual peer footprint union")
        let missing=result.sourceBinding["missingCurrentRetainedPeerBodies"] as? [[String:Any]] ?? []
        try check(missing.count==1 && missing[0]["sourceIndex"] as? Int==2,"only current retained missing-body peer quad becomes uncertainty")
        guard let views=A.maskViews(actualPeerFootprints:[borrowed.actualFullFootprint],missingRetainedPeerPolygons:[polygons[2]!]) else {
            throw Failure(message:"typed actual mask views")
        }
        try check(views.foreignAt(.init(x:120.5,y:110.5)),"foreign uses actual native cell membership without subtracting root")
        try check(!views.foreignAt(.init(x:132,y:200)) && views.uncertainAt(.init(x:132,y:200)),"quad uncertainty never becomes foreign foreground")
        try check(!views.foreignAt(.init(x:131,y:100)),"peer quad interior does not imply foreign ink")
        var stale=m;stale.score += 0.01
        try check(A.prepareFromLive(prior:prior,graph:graph,measurement:stale,live:live,
            actualOriginalSeedEvidence:[],sourceRF:nil).session==nil,"stale supplied measurement scalar cannot replace bound live measurement")
        let badGraph=NativeOCRSourceLocalJoint369Capture.FinalGraph(live:graph.live,suppressed:[],applied:[:],
            polygons:[0:q,1:peer.polygon,2:polygons[2]!],consumed:[],associations:[],groups:[:])
        try check(A.prepareFromLive(prior:prior,graph:badGraph,measurement:m,live:live,
            actualOriginalSeedEvidence:[],sourceRF:nil).session==nil,"stale graph prior rejected")
        var badBytes=live.rgba.bytes;badBytes[0] ^= 1
        let badLive=F.LiveObservation(window:live.window,rgba:.init(bytes:badBytes,width:live.rgba.width,height:live.rgba.height,
            bytesPerRow:live.rgba.bytesPerRow,origin:live.rgba.origin),sources:live.sources,bodies:live.bodies,
            mandatory:[],peerBodies:live.peerBodies,scopes:[])
        try check(A.prepareFromLive(prior:prior,graph:graph,measurement:m,live:badLive,
            actualOriginalSeedEvidence:[],sourceRF:nil).session==nil,"local RGBA byte mismatch rejected")
        let corruptPeer=Body.Evidence(prepared:borrowed.prepared,source:borrowed.source,
            sourceAuthenticatedContrastBodyMask:[],nativeBodyCountAcrossPairs:0,nativeExaminedPalettePairs:0,uniqueMaskPixels:0)
        let badPeerLive=F.LiveObservation(window:live.window,rgba:live.rgba,sources:live.sources,bodies:live.bodies,
            mandatory:[],peerBodies:[1:corruptPeer],scopes:[])
        try check(A.prepareFromLive(prior:prior,graph:graph,measurement:m,live:badPeerLive,
            actualOriginalSeedEvidence:[],sourceRF:nil).session==nil,"malformed actual peer packet cannot become trusted foreign or silent quad fallback")
        var wrongNative=m
        wrongNative.privateObservation?.footprint = .init(width:width,height:height,scaleX:1,scaleY:1,cells:[0])
        let wrongNativeLive=F.LiveObservation(window:live.window,rgba:live.rgba,sources:[wrongNative],bodies:live.bodies,
            mandatory:[],peerBodies:live.peerBodies,scopes:[])
        try check(A.prepareFromLive(prior:prior,graph:graph,measurement:wrongNative,live:wrongNativeLive,
            actualOriginalSeedEvidence:[],sourceRF:nil).session==nil,"complete original footprint equality required, not local subset")
        let badRF=NativeRFDETRLayoutResult(imageIdentity:"synthetic",sourceWidth:width+1,sourceHeight:height,
            primitives:[],maskQueriesOmittedByBudget:0,preprocessingMilliseconds:0,modelMilliseconds:0,
            decodeMilliseconds:0,computeUnits:"synthetic",fromCache:false)
        try check(A.prepareFromLive(prior:prior,graph:graph,measurement:m,live:live,
            actualOriginalSeedEvidence:[],sourceRF:badRF).session==nil,"RF actual frame dimensions required")
        let sourceRF=NativeRFDETRLayoutResult(imageIdentity:"synthetic",sourceWidth:width,sourceHeight:height,
            primitives:[],maskQueriesOmittedByBudget:0,preprocessingMilliseconds:0,modelMilliseconds:0,
            decodeMilliseconds:0,computeUnits:"synthetic",fromCache:false)
        let rfPrepared=A.prepareFromLive(prior:prior,graph:graph,measurement:m,live:live,
            actualOriginalSeedEvidence:[],sourceRF:sourceRF)
        try check(rfPrepared.session != nil && rfPrepared.exactMissing.contains{$0.contains("RF imageIdentity")},"RF identity limitation disclosed without fabricated frame token")
        let absentPacket=NativeCoreMLDetectionBox(polygon:old,score:0.9)
        let withoutPacket=A.prepareFromLive(prior:prior,graph:graph,measurement:m,live:live,
            actualOriginalSeedEvidence:[absentPacket],sourceRF:nil)
        try check(withoutPacket.exactMissing.contains{$0.contains("nearby original detector packets unavailable")},"missing original DB evidence reported exactly, never replaced by quad ink")
        return ["status":"PASS","checks":checks,"syntheticOnly":true,"actualNativeTypes":true,
            "productionIntegrationChanged":false,"nativeFullAdmissionSuiteRun":false,"admissionGranted":false]
    }
}

import Foundation
import CoreGraphics

// Host-only controls: compile with authentic production dependencies and the
// existing missing-observation generator. No worker native build was executed.
@available(iOS 18.0, *)
func missingObservationControls() {
    typealias A = NativeOCRMissingObservationFollowup
    typealias C = NativeOCRSourceComponentMeasurements.Context
    let frame = NativeOCRRGBAFrame(width:600,height:600,
        bytes:[UInt8](repeating:255,count:600*600*4))!
    let context=C(originals:[],prepared:[],groups:[:],scopes:[],frameProvider:{frame})
    func quad(_ angle:CGFloat,_ normalWidth:CGFloat,_ length:CGFloat)->[CGPoint] {
        let n=CGPoint(x:cos(angle),y:sin(angle)),a=CGPoint(x:-sin(angle),y:cos(angle))
        return [CGPoint(x:-normalWidth/2,y:-length/2),CGPoint(x:normalWidth/2,y:-length/2),
                CGPoint(x:normalWidth/2,y:length/2),CGPoint(x:-normalWidth/2,y:length/2)].map{
            CGPoint(x:300+$0.x*n.x+$0.y*a.x,y:300+$0.x*n.y+$0.y*a.y)
        }
    }
    for angle in [CGFloat(0),0.3,-0.6,CGFloat.pi/2] {
        let original=quad(angle,24,120)
        let canonical=context.measure(index:0,polygon:original,hasInk:false,
            capturePrivateObservation:true,captureDensePrivateFootprint:true)!
        precondition(canonical.status == "no-private-source")
        let enriched=A.enrich(canonical:[0:canonical],width:600,height:600,genuineRecapture:{i,m in
            context.measure(index:i,polygon:m.polygon,hasInk:m.hasInk,
                capturePrivateObservation:true,captureDensePrivateFootprint:true)
        })
        precondition(enriched.unavailable[0] != nil)
        precondition(enriched.measurements[0]!.status == canonical.status)
        precondition(enriched.measurements[0]!.privateObservation == nil)
        // The canonical original width/basis stays fixed even after a genuinely
        // different current-prior orientation. Only the source query covers both.
        let actual=quad(angle+0.15,30,140)
        let plan=A.plan(actualPrior:actual,sources:[canonical],frameSize:.init(width:600,height:600))!
        let w=plan.window
        precondition(w.width*w.height <= 600_000)
        let roi=CGRect(x:CGFloat(w.left),y:CGFloat(w.top),width:CGFloat(w.width),height:CGFloat(w.height))
        precondition(actual.allSatisfy{roi.contains($0)})
        let widths=plan.receipt["nativeSourceWidths"] as! [Double]
        precondition(widths == [Double(canonical.rect.width)])
        precondition(plan.receipt["sourceWidthReplacedByCurrentPriorWidth"] as? Bool == false)
    }
    // Real no-packet/no-private context remains unavailable, never converted to
    // a synthetic empty private mask or a successful native admission.
    let original=quad(0,24,120)
    let canonical=context.measure(index:0,polygon:original)!
    let nilRecapture=A.enrich(canonical:[0:canonical],width:600,height:600,genuineRecapture:{_,_ in nil})
    precondition(nilRecapture.unavailable[0] == "genuine-context-recapture-returned-nil")
    precondition(nilRecapture.measurements[0]!.polygon == original)
    precondition(A.plan(actualPrior:[],sources:[canonical],frameSize:.init(width:600,height:600)) == nil)
}
@available(macOS 15.0, *)
enum HostSourceRepairControls {
    static func run() throws -> [String: Any] {
        let stroke = try NativeOCRSourceLiveStroke404Controls.run()
        missingObservationControls()
        let qualified409 = try NativeOCRSourceQualified409Controls.run()
        return ["status": "ACTUAL_NATIVE_TYPE_SOURCE_REPAIR_CONTROLS", "stroke404": stroke,
            "qualified409": qualified409,
            "missingObservationFourAngles": true, "detectorModelCalls": 0, "recognizerModelCalls": 0,
            "datasetNativeAdmissionOrImprovementClaimed": false]
    }
}

import CryptoKit

/// Encapsulated from source-qualified409/fixtures/main.swift. Parent-run only.
/// Original source-session assertions are retained; no top-level execution.
@available(macOS 15.0, *)
enum NativeOCRSourceQualified409Controls {

    // Genuine P.SourceSession controls over literal synthetic original RGBA and
    // matching real cell inventories. They do not claim host/native admission.
    typealias P = NativeOCRPointObligation401
    typealias A = NativeOCRSourceQualifiedGeometryAdmission409
    static func digest(_ bytes:[UInt8])->String {
        SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
    }
    static func fullCellDigest(width:Int,height:Int,cells:Set<Int>)->String {
        var bytes=Data()
        func append(_ value:UInt64) {
            var x=value.littleEndian
            withUnsafeBytes(of:&x){bytes.append(contentsOf:$0)}
        }
        append(UInt64(width));append(UInt64(height))
        append(Double(1).bitPattern);append(Double(1).bitPattern)
        for cell in cells.sorted(){append(UInt64(cell))}
        return SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
    static func control(degrees:Double)throws -> [String:Any] {
        let angle=CGFloat(degrees * .pi/180),w=160,h=160
        let origin=CGPoint(x:80,y:80),n=CGPoint(x:cos(angle),y:sin(angle)),a=CGPoint(x:-sin(angle),y:cos(angle))
        func world(_ normal:CGFloat,_ along:CGFloat)->CGPoint {
            CGPoint(x:origin.x+normal*n.x+along*a.x,y:origin.y+normal*n.y+along*a.y)
        }
        func project(_ p:CGPoint)->CGPoint {
            let x=p.x-origin.x,y=p.y-origin.y
            return CGPoint(x:x*n.x+y*n.y,y:x*a.x+y*a.y)
        }
        func quad(_ low:CGFloat,_ high:CGFloat)->[CGPoint] {
            [world(-20,low),world(20,low),world(20,high),world(-20,high)]
        }
        func actualPixelCenter(_ p:CGPoint)->CGPoint {
            CGPoint(x:floor(p.x)+0.5,y:floor(p.y)+0.5)
        }
        let old=quad(-45,45),flat=actualPixelCenter(world(0,-30)),ink=actualPixelCenter(world(0,9))
        var rgba=[UInt8](repeating:255,count:w*h*4),body=[UInt8](repeating:0,count:w*h),cells=Set<Int>()
        for i in 0..<w*h {
            let p=CGPoint(x:CGFloat(i%w)+0.5,y:CGFloat(i/w)+0.5),v=project(p)
            // A genuine closed foreground rectangle exists away from the synthetic
            // centreline cap. GG/native cells refer ONLY to its actual coloured pixels.
            let foreground=abs(v.x)<8 && v.y>=3 && v.y<15
            let rgb:[UInt8]=foreground ? [30,50,80] : [255,240,222]
            for k in 0..<3 {rgba[i*4+k]=rgb[k]}
            if foreground {body[i]=1;cells.insert(i)}
        }
        precondition(!cells.isEmpty)
        let cellCenters=cells.sorted().map{CGPoint(x:CGFloat($0%w)+0.5,y:CGFloat($0/w)+0.5)}
        let binding=P.Binding(actualOld:old,sourceOrdinal:0,sourceSHA256:digest(rgba),
            rgbaSHA256:digest(rgba),rootGGBodySHA256:digest(body),
            nativeFullFootprintSHA256:fullCellDigest(width:w,height:h,cells:cells),
            actualNativeFullFootprintVerified:true)
        let e=P.Evidence(rgba:.init(bytes:rgba,width:w,height:h,stride:w*4,origin:.zero),rootGGBody:body,
            nativeContains:{p in
                let x=Int(floor(p.x)),y=Int(floor(p.y))
                return x>=0 && x<w && y>=0 && y<h && cells.contains(y*w+x)
            },nativeW:18,normal:n,along:a)
        func session()throws->P.SourceSession {try P.SourceSession(binding:binding,evidence:e)}
        func member(marks:[CGPoint])->P.MemberPoints {
            .init(sourceOrdinal:0,actualExplicitCaps:[flat,ink],originalOwnedSupport:[],
                measurementGuardPoints:[],restoredPrivateHull:[],nativeCellCenters:cellCenters,
                explicitlyProtectedMarks:marks)
        }
        let before=try session(),after=try session()
        let baseline=try P.capture(actualOld:old,members:[member(marks:[])],
            priorConstructorUntypedSupport:[],sessions:[0:before])
        let qualified=try A.captureDerivedEndpoints(actualOld:old,members:[member(marks:[])],
            priorConstructorUntypedSupport:[],sessions:[0:after])
        precondition(baseline.points.count == qualified.points.count)
        for (x,y) in zip(baseline.points,qualified.points) {
            let left=try JSONSerialization.data(withJSONObject:x.pixel.receipt,options:[.sortedKeys])
            let right=try JSONSerialization.data(withJSONObject:y.pixel.receipt,options:[.sortedKeys])
            precondition(left == right && x.pixel.positive == y.pixel.positive && x.pixel.reason == y.pixel.reason,
                         "409 must reuse the unchanged original source-pixel proof")
            if x.point.role != .explicitEndpointCap {
                precondition(x.point.role == y.point.role && x.qualification == y.qualification && x.mustPreserve == y.mustPreserve)
            }
        }
        precondition((before.summary()["sourceProbeQueries"] as? Int) == (after.summary()["sourceProbeQueries"] as? Int))
        precondition(!before.budgetExhausted && !after.budgetExhausted)
        let flatDerived=qualified.points.first{$0.point.position==flat && $0.point.role == .derivedEndpointGeometry}!
        let inkDerived=qualified.points.first{$0.point.position==ink && $0.point.role == .derivedEndpointGeometry}!
        precondition(!flatDerived.pixel.positive && !flatDerived.mustPreserve)
        precondition(flatDerived.qualification == .detectionGeometryUnqualified)
        precondition(inkDerived.pixel.positive && inkDerived.mustPreserve && inkDerived.qualification == .measuredClosedForeground)
        let contraction=quad(-10,40)
        precondition(!P.contains(contraction,flat) && P.contains(contraction,ink))
        precondition(qualified.points.filter(\.mustPreserve).allSatisfy{P.contains(contraction,$0.point.position)},
                     "flat derived cap must not freeze empty head geometry")
        let withExplicitMark=try A.captureDerivedEndpoints(actualOld:old,members:[member(marks:[flat])],
            priorConstructorUntypedSupport:[],sessions:[0:try session()])
        let mark=withExplicitMark.points.first{$0.point.role == .explicitProtectedMark}!
        precondition(!mark.pixel.positive && mark.mustPreserve && mark.qualification == .explicitProtection,
                     "an actual explicit semantic mark remains protected even over a flat pixel")
        precondition(withExplicitMark.points.filter(\.mustPreserve).contains{!P.contains(contraction,$0.point.position)})
        let cutRealInk=quad(-40,-10)
        precondition(!P.contains(cutRealInk,ink) && inkDerived.mustPreserve)
        // Nil cap provenance is still incomplete, never silently a complete empty list.
        let incomplete=P.MemberPoints(sourceOrdinal:0,actualExplicitCaps:nil,originalOwnedSupport:[],
            measurementGuardPoints:[],restoredPrivateHull:[],nativeCellCenters:[],explicitlyProtectedMarks:[])
        let missing=try A.captureDerivedEndpoints(actualOld:old,members:[incomplete],
            priorConstructorUntypedSupport:[],sessions:[0:try session()])
        precondition(!missing.explicitCapsComplete)
        return ["degrees":degrees,"flatDerivedDeferred":!flatDerived.mustPreserve,
            "realDerivedProtected":inkDerived.mustPreserve,"explicitFlatMarkProtected":mark.mustPreserve,
            "pixelProofParity":true,"probeBudgetParity":true,"incompleteCapsRemainIncomplete":!missing.explicitCapsComplete]
    }

    static func run() throws -> [String:Any] {
        var angles:[[String:Any]]=[]
        for degrees in stride(from:0.0,to:360.0,by:22.5) {
            angles.append(try control(degrees:degrees))
        }
        for degrees in [17.0,-23.0,65.0,102.0] {
            angles.append(try control(degrees:degrees))
        }
        return ["status":"ACTUAL_NATIVE_TYPE_QUALIFIED409_CONTROLS","angles":angles,
            "angleCount":angles.count,"originalSourcePixelProofAndBudgetUnchanged":true,
            "datasetNativeAdmissionOrImprovementClaimed":false]
    }
}
