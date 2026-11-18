import Foundation
import CoreGraphics

@available(macOS 15.0, *)
enum HostNativeAdmission425Controls {

// Real-type controls only. Worker never compiles/runs these while full830 runs.
typealias A=NonDestructiveAuthority425
typealias F=NativeOCRSourceLocalJoint369
typealias B=NativeOCRSourceAuthenticatedBodyEvidence
typealias M=NativeOCRSourceComponentMeasurements.Measurement

// Keep every condition intact, but report the exact failed source line even in -O.
private static func check(_ condition: @autoclosure () -> Bool,
    file: StaticString = #fileID, line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("425 CONTROL FAILED \(file):\(line)\n".utf8))
        preconditionFailure("425 typed control contract failed")
    }
}
private static func required<T>(_ value: T?, _ label: String,
    file: StaticString = #fileID, line: UInt = #line) -> T {
    guard let value else {
        FileHandle.standardError.write(Data("425 CONTROL REQUIRED \(label) \(file):\(line)\n".utf8))
        preconditionFailure("425 genuine native evidence unavailable")
    }
    return value
}
private static func phase(_ label: String) {
    FileHandle.standardError.write(Data("425 CONTROL \(label)\n".utf8))
}

private static func policyControls(angle:CGFloat) {
    let n=CGPoint(x:cos(angle),y:sin(angle)),a=CGPoint(x:-sin(angle),y:cos(angle))
    func q(_ width:CGFloat,_ length:CGFloat)->[CGPoint] {
        [CGPoint(x:-width,y:-length),CGPoint(x:width,y:-length),CGPoint(x:width,y:length),CGPoint(x:-width,y:length)].map{
            CGPoint(x:100+$0.x*n.x+$0.y*a.x,y:100+$0.x*n.y+$0.y*a.y)
        }
    }
    let old=q(10,20),expanded=q(12,24)
    func facts(proposed:[CGPoint]?=nil,fixed:Bool=true,bound:Bool=true,loss:Int?=0,
               foreign:Int?=0,uncertain:Int?=0,peerBound:Bool=true,peerCount:Int?=0,
               whole:String="no-entire-closed-component-loss-observed",
               dense:String="no-substantial-source-relative-loss-observed",
               terminal:String?="no-qualified-terminal-loss-observed",emptyWitness:Bool=true,
               hard:[String]=[],soft:[String]=[A.coherentOnlyReason],checks:Bool=true)->A.Facts {
        .init(actualOld:old,proposed:proposed ?? expanded,graphAndMergeRelationsFixed:fixed,
            actualFrameAndSourceScopeBound:bound,lostProtectedPoints:loss,
            actualForeignAcquisitions:foreign,actualUncertainAcquisitions:uncertain,
            expandedPeers:[.init(coherentRegionContrast:true,authenticBodyBound:peerBound,observedAcquiredBodyPixels:peerCount)],
            expectedMembers:1,memberLossChecks:checks ? [.init(sourceOrdinal:0,whole:whole,dense:dense,
                terminal:terminal,terminalWitnessesEmpty:emptyWitness)]:[],hardRejections:hard,softRejections:soft)
    }
    check(A.mayDefer(facts()))
    check(!A.mayDefer(facts(proposed:q(9,24)))) // actual old pixels can be lost
    check(!A.mayDefer(facts(fixed:false)))
    check(!A.mayDefer(facts(bound:false)))
    check(!A.mayDefer(facts(loss:1)))
    check(!A.mayDefer(facts(foreign:1)))
    check(!A.mayDefer(facts(uncertain:1)))
    check(!A.mayDefer(facts(peerCount:1))) // even ONE actual peer body pixel blocks
    check(!A.mayDefer(facts(peerBound:false)))
    check(!A.mayDefer(facts(peerCount:nil))) // missing is not zero/background
    check(!A.mayDefer(facts(foreign:nil)))
    check(!A.mayDefer(facts(loss:nil)))
    check(!A.mayDefer(facts(whole:"reject")))
    check(!A.mayDefer(facts(dense:"reject")))
    check(!A.mayDefer(facts(dense:"uncertain")))
    check(!A.mayDefer(facts(terminal:nil)))
    check(!A.mayDefer(facts(terminal:"reject")))
    check(!A.mayDefer(facts(emptyWitness:false)))
    check(!A.mayDefer(facts(hard:["existing-root-member-semantic-reject"])))
    check(!A.mayDefer(facts(soft:[A.coherentOnlyReason,"relevant-peer-local-physical-evidence-unavailable"])))
    check(!A.mayDefer(facts(checks:false)))
    check(A.mayDefer(facts(checks:false),requireExecutedLossChecks:false)) // RUN checks only
}

// Build genuine Measurement/private footprint/GG evidence through the REAL
// native Context and Body APIs from literal synthetic original RGB+DB cells.
// No private Observation/Measurement/body object is fabricated by this fixture.
private static func nativeControl(angle:CGFloat) throws {
    phase("native angle=\(angle) begin")
    let w=160,h=160,origin=CGPoint(x:70,y:80)
    let n=CGPoint(x:cos(angle),y:sin(angle)),a=CGPoint(x:-sin(angle),y:cos(angle))
    func world(_ x:CGFloat,_ y:CGFloat)->CGPoint {
        CGPoint(x:origin.x+x*n.x+y*a.x,y:origin.y+x*n.y+y*a.y)
    }
    func box(_ x0:CGFloat,_ x1:CGFloat,_ y0:CGFloat,_ y1:CGFloat)->[CGPoint] {
        [world(x0,y0),world(x1,y0),world(x1,y1),world(x0,y1)]
    }
    let old=box(-10,10,-22,22),q=box(-10,20,-22,22),peerQuad=box(14,45,-22,22)
    var bytes=[UInt8](repeating:255,count:w*h*4),owned=[Set<Int>(),Set<Int>()]
    for i in 0..<w*h {
        let dx=CGFloat(i%w)+0.5-origin.x,dy=CGFloat(i/w)+0.5-origin.y
        let x=dx*n.x+dy*n.y,y=dx*a.x+dy*a.y
        var rgb:[UInt8]=[235,235,235]
        // Two literal source endpoints in the original DB cells: contrast >64.
        // The previous20/28 pair shared a32-bin and could not seed native GG.
        if abs(x)<3 && abs(y)<15 {rgb=(i%2 == 0) ? [20,20,20]:[220,220,220];owned[0].insert(i)}
        if x>25 && x<31 && abs(y)<15 {rgb=(i%2 == 0) ? [20,20,20]:[220,220,220];owned[1].insert(i)}
        // Original coherent colour in a newly overlapped peer QUAD, with no
        // acquired original peer DB cell or actual authenticated peer body.
        if x>16 && x<19 && abs(y)<5 {rgb=[110,140,170]}
        for c in 0..<3 {bytes[i*4+c]=rgb[c]}
    }
    let frame=required(NativeOCRRGBAFrame(width:w,height:h,bytes:bytes), "frame")
    func packet(_ index:Int)->NativeOCRDetectorSeedEvidence {
        var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
        for i in owned[index].sorted() {
            if let last=runs.last,last.y==i/w,last.x+last.count==i%w {
                runs[runs.count-1] = .init(y:last.y,x:last.x,count:last.count+1)
            } else {runs.append(.init(y:i/w,x:i%w,count:1))}
        }
        let cc=NativeOCRDetectorSeedEvidence.Component(seed:owned[index].min()!,pixelCount:owned[index].count,
            meanProbability:0.99,runs:runs)
        return .init(ownerID:"control-original-\(index)",parentBoxIndex:index,
            provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
            mapFullWidth:w,mapFullHeight:h,sourceWidth:w,sourceHeight:h,components:[cc],
            sourceProbabilityROI:nil,ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    let originalBoxes=[NativeCoreMLDetectionBox(polygon:old,score:0.95,detectorSeedEvidence:packet(0)),
                       NativeCoreMLDetectionBox(polygon:peerQuad,score:0.95,detectorSeedEvidence:packet(1))]
    let context=NativeOCRSourceComponentMeasurements.Context(originals:originalBoxes,prepared:originalBoxes,
        groups:[:],scopes:[],frameProvider:{frame})
    let root=required(context.measure(index:0,polygon:old,capturePrivateObservation:true,captureDensePrivateFootprint:true), "root measurement")
    let peer=required(context.measure(index:1,polygon:peerQuad,capturePrivateObservation:true,captureDensePrivateFootprint:true), "peer measurement")
    check(root.status=="measured" && peer.status=="measured")
    let size=B.FrameSize(width:w,height:h),window=required(B.Window.make(sourceQuads:[old,q,peerQuad],frameSize:.init(width:w,height:h)), "shared window")
    let rootPrepared=required(B.prepare(root,inherited:old,frameSize:size,enabled:true,sharedWindow:window).prepared, "root prepared")
    let peerPrepared=required(B.prepare(peer,inherited:peerQuad,frameSize:size,enabled:true,sharedWindow:window).prepared, "peer prepared")
    let pixels=required(B.read(rootPrepared,frameProvider:{frame}), "actual pixels")
    let rootBody=required(B.observe(rootPrepared,source:pixels).evidence, "root body")
    let peerBody=required(B.observe(peerPrepared,source:pixels).evidence, "peer body")
    phase("actual palettes root=\(rootPrepared.actualPalettes) peer=\(peerPrepared.actualPalettes)")
    phase("actual body pixels root=\(rootBody.uniqueMaskPixels) peer=\(peerBody.uniqueMaskPixels) pairs root=\(rootBody.nativeExaminedPalettePairs) peer=\(peerBody.nativeExaminedPalettePairs)")
    check(rootBody.uniqueMaskPixels>0 && peerBody.uniqueMaskPixels>0)
    let graph=NativeOCRSourceLocalJoint369Capture.FinalGraph(live:[0,1],suppressed:[],applied:[:],
        polygons:[0:old,1:peerQuad],consumed:[],associations:[],groups:[:])
    let prior=required(graph.prior(0), "prior")
    let peerEvidence=F.PeerEvidence(probeROI:CGRect(x:CGFloat(window.left),y:CGFloat(window.top),
        width:CGFloat(window.width),height:CGFloat(window.height)),frameSize:size,
        peers:[.init(sourceIndex:1,polygon:peerQuad,measurement:peer,missingLocalEvidence:false)],
        knownForeignCells:[required(peer.privateObservation?.footprint, "actual peer footprint")],uncertainCells:[],diagnostics:[:])
    let live=F.LiveObservation(window:window,rgba:pixels.rgba,sources:[root],bodies:[rootBody],
        mandatory:root.guardPoints+root.privateHull.map(root.restore),peerBodies:[1:peerBody],scopes:[])
    let proposal=NativeOCRResidualCandidate(key:"literal-coherent-only-control",polygon:q,
        consumedIndices:[],supportPoints:[],associationKey:nil)
    let actualSemantic:(Int,[CGPoint])->Bool = {_,polygon in
        NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:nil,width:w,height:h)==nil &&
            NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(polygon,evidence:nil,
                layout:nil,width:w,height:h,hasSourceInkProof:false)==nil
    }
    let baseline=NativeOCRSourceLiveAdmission392.assess(prior:prior,graph:graph,measurement:root,
        frame:frame,peerEvidence:peerEvidence,live:live,proposals:[proposal],accepts:actualSemantic)
    phase("baseline records=\(baseline.records)")
    check(baseline.candidates.isEmpty)
    check(baseline.records[0]["softRejections"] as? [String] == [A.coherentOnlyReason])
    let result=NativeAdmission425.assess(prior:prior,graph:graph,measurement:root,frame:frame,
        peerEvidence:peerEvidence,live:live,proposals:[proposal],accepts:actualSemantic)
    phase("result records=\(result.records)")
    check(result.candidates.count==1)
    check(result.records[0]["sourceLossChecksExecutedDespiteEnclosure425"] as? Bool == true)
    check((result.records[0]["pixelChecks"] as? [[String:Any]])?.count==1)
    let withRealForeign=NativeOCRResidualCandidate(key:"actual-peer-ink-control",polygon:box(-10,32,-22,22),
        consumedIndices:[],supportPoints:[],associationKey:nil)
    let blocked=NativeAdmission425.assess(prior:prior,graph:graph,measurement:root,frame:frame,
        peerEvidence:peerEvidence,live:live,proposals:[withRealForeign],accepts:actualSemantic)
    phase("blocked records=\(blocked.records)")
    check(blocked.candidates.isEmpty)
    check((blocked.records[0]["hardRejections"] as? [String])?.contains("acquired-actual-external-owner-cells") == true)
    check((blocked.records[0]["softRejections"] as? [String])?.contains("acquired-peer-authenticated-contrast-body") == true)
    let baselineQualified = NativeOCRSourceQualifiedGeometryAdmission409.assess(prior:prior,graph:graph,
        measurement:root,frame:frame,peerEvidence:peerEvidence,live:live,proposals:[proposal],
        derivedEndpointGeometryForSource:{ _ in [] },originalOwnedSupport:{ _ in [] },accepts:actualSemantic)
    phase("baselineQualified records=\(baselineQualified.records)")
    check(baselineQualified.candidates.isEmpty)
    let qualified = NativeOCRSourceQualifiedAdmission425.assess(prior:prior,graph:graph,
        measurement:root,frame:frame,peerEvidence:peerEvidence,live:live,proposals:[proposal],
        derivedEndpointGeometryForSource:{ _ in [] },originalOwnedSupport:{ _ in [] },accepts:actualSemantic)
    phase("qualified records=\(qualified.records)")
    check(qualified.candidates.count == 1)
    let semanticBlocked = NativeOCRSourceQualifiedAdmission425.assess(prior:prior,graph:graph,
        measurement:root,frame:frame,peerEvidence:peerEvidence,live:live,proposals:[proposal],
        derivedEndpointGeometryForSource:{ _ in [] },originalOwnedSupport:{ _ in [] },accepts:{ _,_ in false })
    phase("semanticBlocked records=\(semanticBlocked.records)")
    check(semanticBlocked.candidates.isEmpty)
    print("425 genuine native control angle=\(angle): coherent-only enclosure deferred; real peer body/foreign acquisition rejected")
}

    static func run() throws -> [String: Any] {
        var config = NativeOCRSourceLocalJoint369Capture.ExportConfiguration()
        check(!config.requestsNativeAdmission425)
        config.families = ["qualified-admission425"]
        check(!config.requestsNativeAdmission425)
        config.enabled = true
        check(config.requestsNativeAdmission425 && config.requestsQualifiedGeometry409)
        check(!config.requestsSourceCost416Select && !config.requestsSourceCostFast422)
        config.families = ["source-cost425-fast-select"]
        check(config.requestsNativeAdmission425 && config.requestsSourceCostFast422 && config.requestsSourceCost418)
        config.families = ["source-repair402-qualified409"]
        check(config.requestsQualifiedGeometry409 && !config.requestsNativeAdmission425)
        let policyAngles: [CGFloat] = [0, 0.3, -0.6, .pi/2, .pi]
        let nativeAngles: [CGFloat] = [0, 0.3, .pi/2]
        for angle in policyAngles { phase("policy angle=\(angle)"); policyControls(angle: angle) }
        for angle in nativeAngles { try nativeControl(angle: angle) }
        return ["status": "pass", "policyAngles": policyAngles.map(Double.init),
            "genuineNativeAngles": nativeAngles.map(Double.init),
            "actual409And425TypedBridgeCompared": true, "semanticRejectionPreserved": true,
            "realPeerBodyAndForeignAcquisitionRejected": true,
            "detectorCalls": 0, "recognizerCalls": 0, "datasetImprovementClaimed": false]
    }
}
