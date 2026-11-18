"""Compile production RF gap helper against real value carriers; synthetic pixels only."""
from pathlib import Path
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Aidoku/Core/Translation/NativeEngine"
models = (ENGINE / "Layout/NativeRFDETRLayoutModels.swift").read_text()
models = models[:models.index("struct NativeRFDETRBalloonOwner")]
recognizer = (ENGINE / "OCR/NativeCoreMLRecognizer.swift").read_text()
carriers = recognizer[recognizer.index("@available(iOS 18.0, *)"):recognizer.index("/// Explicit in-memory diagnostic")]
pipeline = (ENGINE / "OCR/NativeCoreMLOCRPipeline.swift").read_text()
line = pipeline[pipeline.index("@available(iOS 18.0, *)\nstruct NativeCoreMLOCRLine:"):
                pipeline.index("@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics:")]
source_types = "\n".join((ENGINE / "OCR" / name).read_text() for name in [
    "BrowserOCRSourceOrientation.swift", "NativeOCRSourceROIProbabilityEvidence.swift",
    "NativeOCRDetectorSeedEvidence.swift", "NativeOCRAcceptedSource.swift", "NativeOCRFrameTypes.swift"])
detector = (ENGINE / "OCR/NativeCoreMLDetector.swift").read_text()
detector_box = detector[detector.index("@available(iOS 18.0, *)\nstruct NativeCoreMLDetectionBox:"):
                        detector.index("@available(iOS 18.0, *)\nstruct NativeCoreMLDetectionCanvas:")]
reader = (ENGINE.parent / "ReaderTranslationService.swift").read_text()
reader_method = reader.split("// rf-gap-reader-ingress-begin", 1)[1].split("// rf-gap-reader-ingress-end", 1)[0]
reader_method = reader_method.replace("private func recoveringRFGapLines", "func recoveringRFGapLines", 1)
# Compile the actual Reader method with an in-memory recognition transport.
# No Core ML framework, provider, live frame, image file or shared cache is used.
transport = r'''
enum ReaderTranslationDiagnostics {
    static var stages: [String] = []
    static func record(_ stage: String) { stages.append(stage) }
}
final class NativeMainEnsembleEvidenceStore {
    struct Probability {
        let original: CGImage
        let width: Int
        let height: Int
        let values: [Float]
    }
    static let shared = NativeMainEnsembleEvidenceStore()
    var probability: Probability?
    func evidence(original: CGImage) throws -> (regions: [Int], probability: Probability?) { ([],probability) }
}
enum NativeOCRScopeGeometry {
    static func bounds(for polygon: [CGPoint]) -> CGRect? {
        guard polygon.count >= 3, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return polygon.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
    }
}
struct NativeCausalOCRLiveContext {
    struct Detection { let sourceIndex: Int; let polygon: [CGPoint] }
    struct Source { let read: NativeCoreMLRecognizedRegion }
    let frame: NativeOCRRGBAFrame
    var detections: [Detection] = []
    var sources: [Source] = []
}
struct NativeCoreMLOCRResult {
    struct GapLine { let line: NativeCoreMLOCRLine }
    let width: Int
    let height: Int
    var causalLineageContext: NativeCausalOCRLiveContext?
    var recoveryCandidates: [NativeCoreMLOCRLine] = []
    var isolatedLines: [NativeCoreMLOCRLine] = []
    var splitLines: [NativeCoreMLOCRLine] = []
    var gapLines: [GapLine] = []
}
final class NativeCoreMLOCRPipeline {
    enum Mode { case good, weak, missing, mismatch, cancelled, failure, disagreement }
    struct ReadResult { let requestID: String; let regions: [NativeCoreMLRecognizedRegion] }
    struct Failure: Error {}
    var mode: Mode = .good
    var calls = 0
    var cropIDs: [[Int]] = []
    func recognizeSupplementalRegions(context: NativeCausalOCRLiveContext, regions: [NativeCoreMLRecognitionRegion],
        requestID: String, confidenceThreshold: Double = 0) async throws -> ReadResult {
        calls += 1; cropIDs.append(regions.map(\.sourceIndex))
        if mode == .cancelled { throw CancellationError() }
        if mode == .failure { throw Failure() }
        let text = mode == .disagreement && calls % 2 == 0 ? "違う" : "読める"
        return .init(requestID:mode == .mismatch ? "wrong" : requestID,regions:mode == .missing ? [] : regions.map {
            .init(sourceIndex:$0.sourceIndex,polygon:$0.polygon,text:text,confidence:mode == .weak ? 0.7 : 0.95,
                  tokenObservations:text.map { .init(text:String($0),confidence:0.95) })
        })
    }
}
struct ReaderRFGapHarness {
''' + reader_method + '\n}\n'
tests = r'''
typealias H = NativeOCRRFGapRecovery
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label); checks += 1
}
check(NativeOCRRFPrimaryEnsemble.supportedRecognitionThreshold == 0.65,
      "first-pass recognizer threshold matches RF-supported admission floor")
let size = 160
let box = CGRect(x:20,y:10,width:80,height:130)
func frame(blank: Bool = false, inverted: Bool = false, horizontal: Bool = false, solid: Bool = false) throws -> NativeRFDETRSourceImage {
    var bytes = Data(repeating: inverted ? 0 : 255, count: size*size*3)
    if !blank {
        for n in 0..<4 {
            let x0 = horizontal ? 30+n*14 : 45, y0 = horizontal ? 50 : 25+n*18
            for y in 0..<10 { for x in 0..<10 where solid || x < 2 || y < 2 || x >= 8 || y >= 8 {
                for c in 0..<3 { bytes[((y0+y)*size+x0+x)*3+c] = inverted ? 255 : 0 }
            } }
        }
    }
    return try .init(width:size,height:size,rgb:bytes)
}
func primitive(_ id: Int, _ kind: NativeRFDETRLayoutClass, bounds: CGRect = box,
               masked: Bool = false, sourceSize: Int = size, maskID: Int? = nil,
               logits: [Float]? = nil) -> NativeRFDETRLayoutPrimitive {
    .init(queryID:id,semanticClass:kind,confidence:0.9,normalizedBounds:.zero,sourceBounds:bounds,
          mask:masked ? .init(queryID:maskID ?? id,sourceWidth:sourceSize,sourceHeight:sourceSize,
                              logits:logits ?? Array(repeating:1,count:162*162)) : nil)
}
func layout(_ f: NativeRFDETRSourceImage, primitives: [NativeRFDETRLayoutPrimitive]? = nil,
            identity: String? = nil) -> NativeRFDETRLayoutResult {
    .init(imageIdentity:identity ?? f.identity,sourceWidth:size,sourceHeight:size,
          primitives:primitives ?? [primitive(1,.text),primitive(2,.balloon,masked:true)],
          maskQueriesOmittedByBudget:0,preprocessingMilliseconds:0,modelMilliseconds:0,
          decodeMilliseconds:0,computeUnits:"synthetic",fromCache:false)
}
func plans(_ f: NativeRFDETRSourceImage, primitives: [NativeRFDETRLayoutPrimitive]? = nil,
           detected: [CGRect] = [], accepted: [CGRect] = [], probability: H.SourceProbability? = nil) -> [H.Proposal] {
    H.proposals(auxiliaryLayout:layout(f,primitives:primitives),frame:f,detected:detected,accepted:accepted,
                firstSourceIndex:100,admissionThreshold:0.75,sourceProbability:probability)
}
let f = try frame()
let primaryPolygon = [CGPoint(x:20,y:10),CGPoint(x:100,y:10),CGPoint(x:100,y:140),CGPoint(x:20,y:140)]
let primaryBox = NativeCoreMLDetectionBox(polygon:primaryPolygon,score:0.7)
func primaryText(_ confidence:Float, bounds: CGRect = box) -> NativeRFDETRLayoutPrimitive {
    .init(queryID:90,semanticClass:.text,confidence:confidence,normalizedBounds:.zero,
          sourceBounds:bounds,mask:nil)
}
let weakPrimary = NativeOCRRFPrimaryEnsemble.plan(boxes:[primaryBox],
    layout:layout(f,primitives:[primaryText(0.35)]),width:size,height:size)
check(weakPrimary.supported.contains(0) && weakPrimary.stronglySupported.isEmpty,
      "DB and weaker RF agree before first recognition")
let strongPrimary = NativeOCRRFPrimaryEnsemble.plan(boxes:[primaryBox],
    layout:layout(f,primitives:[primaryText(0.85)]),width:size,height:size)
check(strongPrimary.stronglySupported.contains(0),"strong RF and DB agreement")
func primaryRead(_ score:Double) -> NativeCoreMLRecognizedRegion {
    .init(sourceIndex:0,polygon:primaryPolygon,text:"読む",confidence:score,tokenObservations:[])
}
check(NativeOCRRFPrimaryEnsemble.admits(primaryRead(0.68),threshold:0.75,
    supported:weakPrimary.supported,stronglySupported:weakPrimary.stronglySupported,merged:[]),
    "weak RF-backed read survives final admission")
check(!NativeOCRRFPrimaryEnsemble.admits(primaryRead(0.62),threshold:0.75,
    supported:weakPrimary.supported,stronglySupported:weakPrimary.stronglySupported,merged:[]),
    "weak RF cannot admit below 0.65")
check(NativeOCRRFPrimaryEnsemble.admits(primaryRead(0.61),threshold:0.75,
    supported:strongPrimary.supported,stronglySupported:strongPrimary.stronglySupported,merged:[]),
    "strong RF-backed read survives final admission")
let unsupportedPrimary = NativeOCRRFPrimaryEnsemble.plan(boxes:[primaryBox],
    layout:layout(f,primitives:[primaryText(0.2)]),width:size,height:size)
check(unsupportedPrimary.supported.isEmpty,"RF below evidence floor does not relax admission")
let widePolygon = [CGPoint(x:10,y:10),CGPoint(x:110,y:10),CGPoint(x:110,y:130),CGPoint(x:10,y:130)]
let narrowScope = CGRect(x:35,y:18,width:48,height:95)
let wideBox = NativeCoreMLDetectionBox(polygon:widePolygon,score:0.48)
let refinedPrimary = NativeOCRRFPrimaryEnsemble.plan(boxes:[wideBox],
    layout:layout(f,primitives:[primaryText(0.91,bounds:narrowScope)]),width:size,height:size)
check(refinedPrimary.refinedCrops.count == 1 && refinedPrimary.refinedCrops[0].parent == 0 &&
      refinedPrimary.boxes.count == 2 && refinedPrimary.stronglySupported.contains(1),
      "oversized DB box gets an RF-guided crop in the first recognition call")
check(refinedPrimary.boxes[1].erasurePolygons.isEmpty,
      "RF crop does not inherit a broad DB erasure polygon")
let weakRefinement = NativeOCRRFPrimaryEnsemble.plan(boxes:[wideBox],
    layout:layout(f,primitives:[primaryText(0.7,bounds:narrowScope)]),width:size,height:size)
check(weakRefinement.refinedCrops.isEmpty,"weak RF cannot manufacture a new primary crop")
let p = plans(f)
check(p.count == 1,"missing vertical line nominated")
let proposal = p[0]
var padded = [UInt8](repeating:123,count:(size*4+8)*size)
for y in 0..<size { for x in 0..<size {
    for c in 0..<3 { padded[y*(size*4+8)+x*4+c] = f.rgb[(y*size+x)*3+c] }
    padded[y*(size*4+8)+x*4+3] = 255
} }
let rgba = NativeOCRRGBAFrame(width:size,height:size,bytesPerRow:size*4+8,bytes:padded)!
check(H.proposals(auxiliaryLayout:layout(f),frame:rgba,detected:[],accepted:[],firstSourceIndex:100,
                  admissionThreshold:0.75).count == 1,"live RGBA frame seam ignores row padding")
let transparent = [UInt8](repeating:0,count:size*size*4)
let transparentFrame = NativeOCRRGBAFrame(width:size,height:size,bytes:transparent)!
check(H.proposals(auxiliaryLayout:layout(f),frame:transparentFrame,detected:[],accepted:[],firstSourceIndex:100,
                  admissionThreshold:0.75).isEmpty,"different RGBA source cannot borrow RF identity")
check(proposal.sourceIdentity == f.identity && proposal.textQueryID == 1 && proposal.maskQueryID == 2,"source/query binding")
check(proposal.measuredComponentBounds.count == 4 && proposal.measuredInkPixels == 256,"original pixel measurements")
let pixelMask = H.sourceSupportedErasurePolygons(proposal:proposal,frame:f)!
check(pixelMask.count <= 64 && !pixelMask.isEmpty,"pixel mask fits downstream polygon budget")
var maskCoverage = 0
var maskOnlyInk = true
for y in 0..<size { for x in 0..<size {
    let covered = pixelMask.contains { polygon in
        NativeOCRScopeGeometry.bounds(for:polygon)!.contains(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
    }
    if covered { maskCoverage += 1; maskOnlyInk = maskOnlyInk && f.rgb[(y*size+x)*3] == 0 }
} }
check(maskCoverage == 256,"all measured original ink covered exactly")
check(maskOnlyInk,"mask polygon contains observed ink only")
let unrelatedMaskFrame = try frame(blank:true)
check(H.sourceSupportedErasurePolygons(proposal:proposal,frame:unrelatedMaskFrame) == nil,"different source cannot reuse pixel mask")
check(proposal.crops.count == 2 && proposal.crops[0].polygon != proposal.crops[1].polygon,"distinct independent contexts")
check(!proposal.grantsErasureAuthority,"no RF erasure authority")
let blank = try frame(blank:true), inverted = try frame(inverted:true)
let horizontal = try frame(horizontal:true), solid = try frame(solid:true)
check(plans(blank).isEmpty,"RF alone cannot nominate blank source")
check(plans(inverted).count == 1,"light ink on dark source")
check(plans(horizontal).count == 1,"missing horizontal line")
check(plans(solid).isEmpty,"solid artifacts suppressed")
check(plans(f,detected:[box]).isEmpty,"detected but rejected text not duplicated")
check(plans(f,accepted:[box]).isEmpty,"accepted text not duplicated")
check(plans(f,detected:[CGRect(x:49,y:10,width:1,height:120)]).isEmpty,"keepout cannot split original components")
check(plans(f,primitives:[primitive(1,.text)]).isEmpty,"missing mask abstains")
func db(_ source: NativeRFDETRSourceImage, value: Float = 0.6, identity: String? = nil,
        width: Int = 80, count: Int? = nil) -> H.SourceProbability {
    .init(sourceIdentity:identity ?? source.identity,sourceWidth:source.width,sourceHeight:source.height,
          width:width,height:80,values:Array(repeating:value,count:count ?? width*80))
}
let open = plans(f,primitives:[primitive(1,.text)],probability:db(f))
check(open.count == 1 && open[0].maskQueryID == nil,"open text nominates from real DB plus original components without balloon mask")
check(open[0].nominationEvidence == "rf-text-db-original-components" && open[0].componentDBMeans.count == 4,
      "fallback retains measured DB provenance per component")
check(open[0].componentDBMeans.allSatisfy { abs($0-0.6) < 0.0001 },"actual sub-detector-threshold DB values retained")
check(H.sourceSupportedErasurePolygons(proposal:open[0],frame:f) == pixelMask,"fallback independently measures same actual glyph mask")
check(plans(f,probability:db(f))[0].nominationEvidence == "rf-text-mask-original-components","existing mask path retains priority")
check(plans(f,primitives:[primitive(1,.text)],probability:db(f,value:0)).isEmpty,"RF text without DB ink support abstains")
check(plans(f,primitives:[primitive(1,.text)],probability:db(f,identity:"stale")).isEmpty,"wrong source DB cannot nominate")
check(plans(f,primitives:[primitive(1,.text)],probability:db(f,value:Float.nan)).isEmpty,"invalid DB cells rejected")
check(plans(f,primitives:[primitive(1,.text)],probability:db(f,count:1)).isEmpty,"partial DB map rejected")
check(plans(unrelatedMaskFrame,primitives:[primitive(1,.text)],probability:db(unrelatedMaskFrame)).isEmpty,"DB plus RF cannot invent original glyphs")
check(plans(f,primitives:[primitive(1,.text),primitive(3,.soundEffect)],probability:db(f)).isEmpty,"open text SFX conflict stays protected")
check(plans(f,primitives:[primitive(1,.text)],detected:[box],probability:db(f)).isEmpty,"open fallback respects original detector keepouts")
func audited(_ source: NativeRFDETRSourceImage, primitives: [NativeRFDETRLayoutPrimitive],
             detected: [CGRect] = [], probability: H.SourceProbability? = nil,
             identity: String? = nil) -> (plans:[H.Proposal],counts:[String:Int],calls:Int) {
    var counts: [String:Int] = [:], calls = 0
    let plans = H.proposals(auxiliaryLayout:layout(source,primitives:primitives,identity:identity),frame:source,
        detected:detected,accepted:[],firstSourceIndex:100,admissionThreshold:0.75,sourceProbability:probability,
        audit: { calls += 1; counts = $0 })
    return (plans,counts,calls)
}
let noTextAudit = audited(f,primitives:[])
check(noTextAudit.calls == 1 && noTextAudit.counts["noText"] == 1 && noTextAudit.counts["proposedCount"] == 0,
      "single summary callback distinguishes no eligible RF text")
let noSupportAudit = audited(f,primitives:[primitive(1,.text)])
check(noSupportAudit.calls == 1 && noSupportAudit.counts["noMask"] == 1 && noSupportAudit.counts["noDB"] == 1,
      "single summary distinguishes absent mask and DB")
let blockedAudit = audited(f,primitives:[primitive(1,.text),primitive(2,.balloon,masked:true)],detected:[box])
check(blockedAudit.counts["componentDetectorKeepout"] == 4 && (blockedAudit.counts["inkPixelsInDetectorKeepout"] ?? 0) > 0,
      "detector keepout blocking independently measured original glyphs is explicit")
let noInkAudit = audited(unrelatedMaskFrame,primitives:[primitive(1,.text),primitive(2,.balloon,masked:true)])
check(noInkAudit.counts["noOriginalInk"] == 1 && noInkAudit.counts["inkPixels"] == 0 && noInkAudit.counts["inkRows",default:0] == 0,
      "no original ink differs from keepout rejection")
let noDBAudit = audited(f,primitives:[primitive(1,.text)],probability:db(f,value:0))
check(noDBAudit.counts["componentNoDBSupport"] == 4 && noDBAudit.counts["componentDBCoverage"] == 4,
      "independent ink without actual DB support differs from detector blocking")
let positiveAudit = audited(f,primitives:[primitive(1,.text)],probability:db(f))
check(positiveAudit.calls == 1 && positiveAudit.plans.count == open.count && positiveAudit.counts["proposedCount"] == 1,
      "instrumented nomination preserves candidate behavior")
check(positiveAudit.counts["inkRows"] == 40 && positiveAudit.counts["independentComponents"] == 4 &&
      positiveAudit.counts["scannedPixels"] == Int(box.width*box.height),"ink rows and work measured in the existing single scan")
let invalidAudit = audited(f,primitives:[primitive(1,.text)],identity:"stale")
check(invalidAudit.calls == 1 && invalidAudit.counts["invalidInputOrIdentity"] == 1,"early failure still reports exactly once")
check(plans(f,primitives:[primitive(1,.text),primitive(2,.balloon,masked:true,sourceSize:159)]).isEmpty,"stale mask dimensions")
check(plans(f,primitives:[primitive(1,.text),primitive(2,.balloon,masked:true,maskID:3)]).isEmpty,"mask query mismatch")
check(plans(f,primitives:[primitive(1,.text),primitive(2,.balloon,masked:true,logits:[Float.nan])]).isEmpty,"invalid masks")
check(plans(f,primitives:[primitive(1,.text),primitive(2,.balloon,masked:true,logits:Array(repeating:-1,count:162*162))]).isEmpty,"negative mask")
let halfMask: [Float] = (0..<(162*162)).map { $0 % 162 < 50 ? 1 : -1 }
check(plans(f,primitives:[primitive(1,.text),primitive(2,.balloon,masked:true,logits:halfMask)]).isEmpty,"mask cannot manufacture partial glyphs")
check(plans(f,primitives:[primitive(1,.text),primitive(2,.balloon,masked:true),primitive(3,.soundEffect)]).isEmpty,"SFX conflict preserved")
check(H.proposals(auxiliaryLayout:layout(f,identity:"stale"),frame:f,detected:[],accepted:[],firstSourceIndex:100,
                  admissionThreshold:0.75).isEmpty,"wrong source identity")
check(plans(f,primitives:[primitive(1,.text),primitive(1,.text),primitive(2,.balloon,masked:true)]).count == 1,"RF duplicate suppression")
check(H.proposals(auxiliaryLayout:layout(f),frame:f,detected:[],accepted:[],firstSourceIndex:Int.max,
                  admissionThreshold:0.75).isEmpty,"source ID overflow")
check(H.proposals(auxiliaryLayout:layout(f),frame:f,detected:[],accepted:[],firstSourceIndex:100,
                  admissionThreshold:Double.nan).isEmpty,"invalid threshold")
var crowdedBytes = Data(repeating:255,count:size*size*3)
for column in 0..<10 { for row in 0..<4 {
    for y in 0..<10 { for x in 0..<10 where x < 2 || y < 2 || x >= 8 || y >= 8 {
        for c in 0..<3 { crowdedBytes[((25+row*18+y)*size+10+column*14+x)*3+c] = 0 }
    } }
} }
let crowded = try NativeRFDETRSourceImage(width:size,height:size,rgb:crowdedBytes)
let wide = CGRect(x:5,y:10,width:150,height:130)
let crowdedPlans = plans(crowded,primitives:[primitive(1,.text,bounds:wide),primitive(2,.balloon,bounds:wide,masked:true)])
check(crowdedPlans.count == 8,"bounded page proposal budget")
check(Set(crowdedPlans.map { $0.original.sourceIndex }).count == 8,"one unique source ID per proposal")
check(crowdedPlans.flatMap(\.crops).count == 16,"at most sixteen recognition crops in two passes")
var staircaseBytes = Data(repeating:255,count:size*size*3)
for column in 0..<12 { for y in 0..<12 {
    let shift = (y/2)%2 == 0 ? 0 : 3
    for x in shift..<(shift+7) { for c in 0..<3 { staircaseBytes[((40+y)*size+10+column*12+x)*3+c] = 0 } }
} }
let staircase = try NativeRFDETRSourceImage(width:size,height:size,rgb:staircaseBytes)
let staircasePlans = plans(staircase,primitives:[primitive(1,.text,bounds:wide),primitive(2,.balloon,bounds:wide,masked:true)])
check(staircasePlans.count == 1,"long repeated glyph line fixture")
let contours = H.sourceSupportedErasurePolygons(proposal:staircasePlans[0],frame:staircase)!
check(contours.count == 12 && contours.allSatisfy { $0.count <= 32 },"exact contours replace 72 row spans within actual merger limits")
func pointInside(_ p: CGPoint, polygon: [CGPoint]) -> Bool {
    var inside = false
    for i in polygon.indices {
        let a = polygon[i], b = polygon[(i+1)%polygon.count]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
    }
    return inside
}
var exactContourCoverage = true
for y in 0..<size { for x in 0..<size {
    let covered = contours.contains { pointInside(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5),polygon:$0) }
    exactContourCoverage = exactContourCoverage && (covered == (staircase.rgb[(y*size+x)*3] == 0))
} }
check(exactContourCoverage,"traced contours preserve every original foreground and background pixel exactly")
func reads(_ text: String = "読める", score: Double = 0.9, tokenScore: Double = 0.95,
           source: String? = nil, query: Int = 1) -> [H.BoundRead] {
    proposal.crops.map { crop in
        .init(sourceIdentity:source ?? proposal.sourceIdentity,textQueryID:query,
              read:.init(sourceIndex:crop.sourceIndex,polygon:crop.polygon,text:text,confidence:score,
                         tokenObservations:text.map { .init(text:String($0),confidence:tokenScore) }))
    }
}
let good = H.accepted(proposal:proposal,reads:reads(),expectedSourceIdentity:f.identity)
check(good?.polygon == proposal.original.polygon && good?.text == "読める" && good?.sourceIndex == 100,"normal threshold paired ingress")
check(H.accepted(proposal:proposal,reads:[],expectedSourceIdentity:f.identity) == nil,"RF-only automatic admission prohibited")
check(H.accepted(proposal:proposal,reads:reads(score:0.749),expectedSourceIdentity:f.identity) == nil,"normal confidence floor")
check(H.accepted(proposal:proposal,reads:reads(tokenScore:0.89),expectedSourceIdentity:f.identity) == nil,"weak tokens")
check(H.accepted(proposal:proposal,reads:reads(source:"stale"),expectedSourceIdentity:f.identity) == nil,"read source mismatch")
check(H.accepted(proposal:proposal,reads:reads(query:7),expectedSourceIdentity:f.identity) == nil,"read query mismatch")
check(H.accepted(proposal:proposal,reads:reads(),expectedSourceIdentity:"stale") == nil,"caller source mismatch")
check(H.accepted(proposal:proposal,reads:reads("…！"),expectedSourceIdentity:f.identity) == nil,"punctuation artifact")
var disagreement = reads(); disagreement[1] = reads("違う")[1]
check(H.accepted(proposal:proposal,reads:disagreement,expectedSourceIdentity:f.identity) == nil,"independent disagreement")
check(H.accepted(proposal:proposal,reads:reads().reversed(),expectedSourceIdentity:f.identity) == nil,"crop binding")
check(H.accepted(proposal:proposal,reads:reads(score:Double.nan),expectedSourceIdentity:f.identity) == nil,"nonfinite recognizer score")
check(H.accepted(proposal:proposal,reads:reads(tokenScore:Double.infinity),expectedSourceIdentity:f.identity) == nil,"nonfinite lexical score")
var wrongID = reads()
wrongID[0] = .init(sourceIdentity:f.identity,textQueryID:1,
                   read:.init(sourceIndex:99,polygon:proposal.crops[0].polygon,text:"読める",confidence:0.9,
                              tokenObservations:reads()[0].read.tokenObservations))
check(H.accepted(proposal:proposal,reads:wrongID,expectedSourceIdentity:f.identity) == nil,"recognizer source ID binding")
let verified = [proposal.original.polygon]
let admission = H.acceptedPacket(proposal:proposal,reads:reads(),expectedSourceIdentity:f.identity,
                                 verifiedErasurePolygons:verified,orientation:.vertical)
check(admission?.packet.text == "読める" && admission?.sourceIndex == 100,"source packet ingress")
check(admission?.packet.erasurePolygons == verified && admission?.packet.detectorSeedEvidence == nil,"verified mask retained; no invented DB evidence")
check(admission?.sourceIdentity == f.identity && admission?.textQueryID == 1 && admission?.maskQueryID == 2,"ingress receipt binding")
check(H.acceptedPacket(proposal:proposal,reads:reads(),expectedSourceIdentity:f.identity,
                       verifiedErasurePolygons:[],orientation:.vertical) == nil,"mask missing: no ingress")
check(H.acceptedPacket(proposal:proposal,reads:reads(),expectedSourceIdentity:f.identity,
                       verifiedErasurePolygons:[proposal.crops[0].polygon],orientation:.vertical) == nil,"context crop cannot become erasure mask")
check(H.acceptedPacket(proposal:proposal,reads:reads(),expectedSourceIdentity:f.identity,
                       verifiedErasurePolygons:[[.zero,.zero,.zero]],orientation:.vertical) == nil,"invalid glyph polygon")
if let packet = admission?.packet {
    let old = NativeCoreMLOCRLine(polygon:[.zero,CGPoint(x:1,y:0),CGPoint(x:1,y:1)],text:"old",score:0.9,orientation:.vertical)
    let extra = NativeCoreMLOCRLine(polygon:packet.polygon,text:packet.text,score:packet.score,orientation:packet.orientation,
                                  erasurePolygons:packet.erasurePolygons,detectorSeedEvidence:packet.detectorSeedEvidence)
    let bound = NativeOCRAcceptedSource.bindingPrimary([old,extra],width:size,height:size)
    check(bound[0].acceptedSource.membership?.table === bound[1].acceptedSource.membership?.table,"single shared page ingress table")
    check(bound[0].acceptedSource.membership?.body == [0] && bound[1].acceptedSource.membership?.body == [1],"old ordinal preserved; new ordinal appended")
    check(bound[1].acceptedSource.membership?.table.packets[1].erasurePolygons == verified,"mask reaches accepted-source lineage")
}
if let admission {
    let old = NativeCoreMLOCRLine(polygon:[.zero,CGPoint(x:1,y:0),CGPoint(x:1,y:1)],text:"old",score:0.9,orientation:.vertical)
    let sibling = NativeCoreMLOCRLine(polygon:[CGPoint(x:120,y:1),CGPoint(x:121,y:1),CGPoint(x:121,y:2)],
                                     text:"sibling",score:0.9,orientation:.vertical)
    let originals = NativeOCRAcceptedSource.bindingPrimary([old,sibling],width:size,height:size)
    let originalTable = originals[0].acceptedSource.membership!.table
    var carried = originals[0]
    carried.acceptedSource = .init(.init(table:originalTable,body:[0],readings:[1],unknownDedup:[1],hasUntrackedInputs:true))
    let ingress = H.appendingAdmissions([admission],to:[carried],expectedSourceIdentity:f.identity,width:size,height:size)!
    check(ingress.previousOperationID == originalTable.operationID && ingress.table.operationID != originalTable.operationID,
          "explicit supplemental operation ancestry")
    check(ingress.originalPacketCount == 2 && Array(ingress.table.packets.prefix(2)) == originalTable.packets,
          "original immutable packets copied verbatim, including reading-only packets")
    let membership = ingress.lines[0].acceptedSource.membership!
    check(membership.body == [0] && membership.readings == [1] && membership.unknownDedup == [1] && membership.hasUntrackedInputs,
          "all original membership fields retained")
    check(ingress.lines[1].acceptedSource.membership?.body == [2] && ingress.lines[1].acceptedSource.membership?.table === membership.table,
          "supplemental source appends ordinal in same table")
    check(ingress.lines[1].erasurePolygons == verified && ingress.lines[1].detectorSeedEvidence == nil,"mask and honest detector absence reach line ingress")
    check(originalTable.packets.count == 2,"old operation remains immutable")
    check(H.appendingAdmissions([admission],to:[old],expectedSourceIdentity:f.identity,width:size,height:size) == nil,
          "untracked existing table cannot be silently rebound")
    check(H.appendingAdmissions([admission,admission],to:originals,expectedSourceIdentity:f.identity,width:size,height:size) == nil,
          "duplicate admission source IDs rejected")
    check(H.appendingAdmissions([admission],to:originals,expectedSourceIdentity:"stale",width:size,height:size) == nil,
          "source mismatch at final ingress")
    check(H.appendingAdmissions([admission],to:originals,expectedSourceIdentity:f.identity,width:159,height:size) == nil,
          "source dimensions mismatch at final ingress")
    check(H.appendingAdmissions([admission],to:[],expectedSourceIdentity:f.identity,width:size,height:size)?.lines.count == 1,
          "entirely undetected page may start its accepted table")
}
let image = CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:size*3,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:0),
                    provider:CGDataProvider(data:f.rgb as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
let originalFrame = NativeOCRCGImageAdapter.makeRGBAFrame(from:image)!
let context = NativeCausalOCRLiveContext(frame:originalFrame)
let result = NativeCoreMLOCRResult(width:size,height:size,causalLineageContext:context)
let old = NativeCoreMLOCRLine(polygon:[CGPoint(x:1,y:1),CGPoint(x:3,y:1),CGPoint(x:3,y:3),CGPoint(x:1,y:3)],
                             text:"old",score:0.95,orientation:.vertical)
let primary = NativeOCRAcceptedSource.bindingPrimary([old],width:size,height:size)
let service = ReaderRFGapHarness()
let transport = NativeCoreMLOCRPipeline()
let gapFlag = "AIDOKU_OCR_RF_GAP_RECOVERY"
let savedFlag = ProcessInfo.processInfo.environment[gapFlag]
unsetenv(gapFlag)
var received = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:layout(f),result:result,
    primary:primary,pipeline:transport,confidenceThreshold:0.75)
check(received.count == 1 && transport.calls == 0,"Reader disabled path performs no supplemental reads")
setenv(gapFlag,"1",1)
received = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:layout(f),result:result,
    primary:primary,pipeline:transport,confidenceThreshold:0.75)
check(received.count == 2 && transport.calls == 2,"actual Reader ingress executes two distinct reads")
check(received[0].text == "old" && received[1].text == "読める","Reader preserves old source and admits paired source")
check(received[1].erasurePolygons == pixelMask && received[1].detectorSeedEvidence == nil,"Reader carries exact source pixel mask")
check(received[0].acceptedSource.membership?.table === received[1].acceptedSource.membership?.table,"Reader uses one source table")
check(ReaderTranslationDiagnostics.stages.contains("rf_gap_accepted_ingress"),"Reader emits explicit source ancestry audit")
NativeMainEnsembleEvidenceStore.shared.probability = .init(original:image,width:80,height:80,values:Array(repeating:0.6,count:80*80))
let openPipeline = NativeCoreMLOCRPipeline()
let openLayout = layout(f,primitives:[primitive(1,.text)])
received = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:openLayout,result:result,
    primary:primary,pipeline:openPipeline,confidenceThreshold:0.75)
check(received.count == 2 && openPipeline.calls == 2 && received[1].erasurePolygons == pixelMask,
      "actual Reader method consumes source-bound store DB for open text and exact pixel mask ingress")
NativeMainEnsembleEvidenceStore.shared.probability = .init(original:image,width:80,height:80,values:Array(repeating:0,count:80*80))
let noDBPipeline = NativeCoreMLOCRPipeline()
received = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:openLayout,result:result,
    primary:primary,pipeline:noDBPipeline,confidenceThreshold:0.75)
check(received.count == 1 && noDBPipeline.calls == 0,"Reader RF-only open text remains unaccepted without actual DB support")
NativeMainEnsembleEvidenceStore.shared.probability = nil
var preexistingGap = result
preexistingGap.gapLines = [.init(line:.init(polygon:proposal.original.polygon,text:"existing",score:0.9,orientation:.vertical))]
let duplicatePipeline = NativeCoreMLOCRPipeline()
received = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:layout(f),result:preexistingGap,
    primary:primary,pipeline:duplicatePipeline,confidenceThreshold:0.75)
check(received.count == 1 && duplicatePipeline.calls == 0,"Reader suppresses an existing detector-free gap recovery")
for mode: NativeCoreMLOCRPipeline.Mode in [.weak,.missing,.disagreement,.failure,.mismatch] {
    let pipeline = NativeCoreMLOCRPipeline(); pipeline.mode = mode
    received = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:layout(f),result:result,
        primary:primary,pipeline:pipeline,confidenceThreshold:0.75)
    check(received.count == 1 && received[0].acceptedSource.membership?.table === primary[0].acceptedSource.membership?.table,
          "Reader optional failure leaves original source and ancestry intact")
}
let cancelled = NativeCoreMLOCRPipeline(); cancelled.mode = .cancelled
var cancellationPropagated = false
do {
    _ = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:layout(f),result:result,
        primary:primary,pipeline:cancelled,confidenceThreshold:0.75)
} catch is CancellationError { cancellationPropagated = true }
check(cancellationPropagated,"Reader propagates cancellation")
let unavailable = NativeCoreMLOCRPipeline()
received = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:nil,result:result,
    primary:primary,pipeline:unavailable,confidenceThreshold:0.75)
check(received.count == 1 && unavailable.calls == 0 && ReaderTranslationDiagnostics.stages.last == "rf_gap_unaccepted_missing_layout_or_context",
      "missing RF remains unaccepted with explicit audit")
received = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:layout(f,identity:"stale"),result:result,
    primary:primary,pipeline:unavailable,confidenceThreshold:0.75)
check(received.count == 1 && unavailable.calls == 0 && ReaderTranslationDiagnostics.stages.last == "rf_gap_unaccepted_source_identity",
      "Reader validates actual decoded source identity before read")
var wrongContext = result
wrongContext.causalLineageContext = .init(frame:transparentFrame)
received = try await service.recoveringRFGapLines(image:image,auxiliaryLayout:layout(f),result:wrongContext,
    primary:primary,pipeline:unavailable,confidenceThreshold:0.75)
check(received.count == 1 && unavailable.calls == 0 && ReaderTranslationDiagnostics.stages.last == "rf_gap_unaccepted_retained_frame_identity",
      "Reader verifies actual retained recognition pixels")
var fringeBytes = f.rgb
for y in 25..<35 { for c in 0..<3 { fringeBytes[(y*size+44)*3+c] = 239 } }
let fringe = try NativeRFDETRSourceImage(width:size,height:size,rgb:fringeBytes)
let fringeImage = CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:size*3,
    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:0),
    provider:CGDataProvider(data:fringe.rgb as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
let fringeContext = NativeCausalOCRLiveContext(frame:NativeOCRCGImageAdapter.makeRGBAFrame(from:fringeImage)!)
let fringeResult = NativeCoreMLOCRResult(width:size,height:size,causalLineageContext:fringeContext)
let fringePipeline = NativeCoreMLOCRPipeline()
received = try await service.recoveringRFGapLines(image:fringeImage,auxiliaryLayout:layout(fringe),result:fringeResult,
    primary:primary,pipeline:fringePipeline,confidenceThreshold:0.75)
check(received.count == 1 && fringePipeline.calls == 2 && ReaderTranslationDiagnostics.stages.last == "rf_gap_unaccepted_original_pixel_mask",
      "agreed reads cannot admit an incomplete original pixel mask; explicit unaccepted audit")
if let savedFlag { setenv(gapFlag,savedFlag,1) } else { unsetenv(gapFlag) }
print("RF gap synthetic checks: \(checks) passed")
'''
with tempfile.TemporaryDirectory(prefix="ocr-rf-gap-") as folder:
    folder = Path(folder)
    source = folder / "main.swift"
    source.write_text("import Foundation\nimport Darwin\nstruct NativeOCRDetectorColumnEvidence: Equatable, Sendable {}\n"
                      + models + carriers + line + source_types + detector_box + (ENGINE / "OCR/NativeOCRCGImageAdapter.swift").read_text()
                      + (ENGINE / "OCR/NativeOCRRFGapRecovery.swift").read_text() + transport + tests)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(folder / "clang-cache"), SWIFT_MODULECACHE_PATH=str(folder / "swift-cache"))
    started = time.monotonic()
    subprocess.run(["swiftc", "-module-cache-path", str(folder / "swift-cache"), str(source), "-o", str(folder / "checks")],
                   check=True, env=env)
    compiled = time.monotonic()
    subprocess.run([str(folder / "checks")], check=True, env=env)
    print(f"Focused synthetic compile: {compiled - started:.3f}s; execution: {time.monotonic() - compiled:.3f}s")
