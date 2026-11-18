"""Compile the live stage bridge and exact Reader registration block; synthetic values only."""
from pathlib import Path
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Aidoku/Core/Translation/NativeEngine"
ocr = ENGINE / "OCR"
ensemble = ENGINE / "Ensemble"
detector = (ocr / "NativeCoreMLDetector.swift").read_text()
box = detector[detector.index("@available(iOS 18.0, *)"):detector.index("@available(iOS 18.0, *)\nstruct NativeCoreMLDetectionCanvas")]
recognizer = (ocr / "NativeCoreMLRecognizer.swift").read_text()
carriers = recognizer[recognizer.index("@available(iOS 18.0, *)"):recognizer.index("/// Explicit in-memory diagnostic")]
pipeline = (ocr / "NativeCoreMLOCRPipeline.swift").read_text()
line = pipeline[pipeline.index("@available(iOS 18.0, *)\nstruct NativeCoreMLOCRLine:"):
                pipeline.index("@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics:")]
result_type = pipeline[pipeline.index("@available(iOS 18.0, *)\nstruct NativeCoreMLOCRResult:"):
                       pipeline.index("@available(iOS 18.0, *)\nenum NativeOCRScopeGeometry")]
capture = pipeline[pipeline.index("            let ensembleStageSnapshot = try? NativeOCREnsembleStageSnapshot.capture("):]
capture = capture[:capture.index("            return NativeCoreMLOCRResult(")]
models = (ENGINE / "Layout/NativeRFDETRLayoutModels.swift").read_text()
models = models[:models.index("/// Compact raw mask logits")]
reader = (ENGINE.parent / "ReaderTranslationService.swift").read_text()
registration = reader.split('if NativeMainEnsembleRenderer.enabled {', 1)[1]
registration = registration[registration.index('let evidenceSource = try NativeMainEnsemblePreparedDB.SourceBinding(ocrEvidenceOriginal: image)'):]
registration = registration[:registration.index('} catch is CancellationError')]
support = r'''
struct NativeOCRDetectorColumnEvidence: Equatable, Sendable {}
struct ReaderTranslationSourceOCRAlternative {
    let originalText: String; let exactReading: String; let paddedReading: String
    let rect: CGRect; let primaryConfidence: Double; let exactConfidence: Float; let paddedConfidence: Float
}
struct ReaderTranslationRegion {
    let id: String; let source: String; let confidence: Double; let rect: CGRect; let polygon: [CGPoint]
    var unitMemberRects: [CGRect] = []
    var sourceMemberPolygons: [[CGPoint]] = []
    var translation: String? = nil
    var sourceSingleVerticalColumn: Bool? = nil
    var sourceOrientation: BrowserOCRSourceOrientation = .vertical
    var detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]? = nil
    var sourceOCRAlternatives: [ReaderTranslationSourceOCRAlternative] = []
}
struct FixtureResult { let ensembleStageSnapshot: NativeOCREnsembleStageSnapshot? }
struct NativeCoreMLOCRPipelineDiagnostics: Equatable, Sendable {}
struct NativeCausalOCRLiveContext: Equatable, Sendable {}
struct NativeCoreMLOCRGapLine: Equatable, Sendable {}
// Unrelated optional reports on the actual pipeline result.
struct FixtureReport: Equatable, Sendable {}
enum NativeOCRIndividualGeometryHypotheses { typealias Individual = FixtureReport }
enum NativeOCRLearnedBoundaryAdmission { typealias Proof = FixtureReport }
enum NativeOCRGeometryRepresentativeSelection { typealias Report = FixtureReport }
enum NativeOCRGeometrySignalAdmission { typealias Report = FixtureReport }
enum NativeOCRGeometryWitnessAdmission { typealias Report = FixtureReport }
enum NativeOCRGeometryPortfolioAdmission { typealias Report = FixtureReport }
enum NativeOCRRFSemanticAdmission { typealias Report = FixtureReport }
enum NativeOCRPhysicalPaintAdmission { typealias Report = FixtureReport }
enum NativeOCRRawCanonicalRuntime { typealias Receipt = FixtureReport }
struct FixtureDetection { let width: Int; let height: Int; let boxes: [NativeCoreMLDetectionBox] }
struct FixtureRecognition: Equatable { let regions: [NativeCoreMLRecognizedRegion] }
func actualPipelineCapture(detection: FixtureDetection, recognition: FixtureRecognition?,
    rejectedReads: [NativeCoreMLRecognizedRegion], cancellationCheck: () throws -> Void = {}) throws -> NativeOCREnsembleStageSnapshot? {
''' + capture + '''
    return ensembleStageSnapshot
}
final class NativeMainEnsembleEvidenceStore {
    static let shared = NativeMainEnsembleEvidenceStore()
    let store = NativeMainEnsembleOCREvidence.Store()
    func register(ocr: NativeMainEnsembleOCREvidence.Packet, original: CGImage, source: NativeMainEnsemblePreparedDB.SourceBinding) throws {
        try store.register(ocr, original: original, source: source)
    }
}
func registration(image: CGImage, result: FixtureResult, lines: [NativeCoreMLOCRLine], joined: [ReaderTranslationRegion])
    throws -> (NativeMainEnsembleOCREvidence.Packet,[String:Double]) {
    var lastPhaseMilliseconds: [String:Double] = [:]
''' + registration + '\nreturn (packet,lastPhaseMilliseconds)\n}\n'
checks = r'''
typealias S = NativeOCREnsembleStageSnapshot
typealias E = NativeMainEnsembleOCREvidence
var count = 0
func check(_ value: @autoclosure () -> Bool, _ reason: String) { precondition(value(),reason); count += 1 }
func fails(_ reason: String, _ body: () throws -> Void) {
    do { try body(); preconditionFailure(reason) } catch { count += 1 }
}
func quad(_ x: CGFloat = 10, _ y: CGFloat = 10, _ w: CGFloat = 20, _ h: CGFloat = 60) -> [CGPoint] {
    [.init(x:x,y:y),.init(x:x+w,y:y),.init(x:x+w,y:y+h),.init(x:x,y:y+h)]
}
let image: CGImage = {
    let provider = CGDataProvider(data:Data(repeating:255,count:256*256*3) as CFData)!
    return CGImage(width:256,height:256,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:256*3,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,
        decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}()
let binding = try E.liveBinding(original:image)
let box = NativeCoreMLDetectionBox(polygon:quad(),score:0.88)
let accepted = NativeCoreMLRecognizedRegion(sourceIndex:7,polygon:quad(),text:"『Ａ…あ』",confidence:0.92)
let rejected = NativeCoreMLRecognizedRegion(sourceIndex:8,polygon:quad(60),text:"",confidence:0)
let snapshot = try S.capture(width:256,height:256,detectionBoxes:[box],recognizedRegions:[accepted],rejectedReads:[rejected])
let actualCapture = try actualPipelineCapture(detection:.init(width:256,height:256,boxes:[box]),
    recognition:.init(regions:[accepted]),rejectedReads:[rejected])
check(actualCapture == snapshot,"actual pipeline return capture matches exact measured arrays")
let notRun = try actualPipelineCapture(detection:.init(width:256,height:256,boxes:[]),recognition:nil,rejectedReads:[])
check(notRun?.detector?.isEmpty == true && notRun?.recognized == nil && notRun?.rejected == nil,
      "pipeline does not mark unrun recognition/rejection observed empty")
let rejectedBudget = try actualPipelineCapture(detection:.init(width:256,height:256,boxes:Array(repeating:box,count:4097)),
    recognition:.init(regions:[accepted]),rejectedReads:[])
check(rejectedBudget == nil,"pipeline snapshot budget failure remains optional, not an OCR error or empty observed stages")
fails("pipeline cancellation still propagates outside optional capture") {
    _ = try actualPipelineCapture(detection:.init(width:256,height:256,boxes:[box]),recognition:nil,rejectedReads:[],
        cancellationCheck:{ throw CancellationError() })
}
var actualResult = NativeCoreMLOCRResult(requestID:"actual",width:256,height:256,lines:[],frameConversionMilliseconds:0,
    detectionMilliseconds:0,recognitionMilliseconds:0,totalMilliseconds:0,detectedBoxes:1,selectedBoxes:1,
    diagnostics:.init(),ensembleStageSnapshot:actualCapture)
check(actualResult.ensembleStageSnapshot == snapshot,"actual result type retains optional Equatable/Sendable snapshot")
actualResult.ensembleStageSnapshot = nil
check(actualResult.ensembleStageSnapshot == nil,"legacy callers may leave result snapshot unavailable")
check(snapshot.detector?[0].sourceIndex == 0 && snapshot.detector?[0].text == nil,"actual detector index; no invented detector text")
check(snapshot.recognized?[0].sourceIndex == 7 && snapshot.recognized?[0].text == accepted.text,"exact recognized index and Unicode retained")
check(snapshot.rejected?[0].text == "" && snapshot.rejected?[0].confidence == 0,"observed empty decode preserved within actual rejected stage")
check(snapshot.decoded == nil,"recognized plus rejected never fabricate decoded stage")
let projected = try snapshot.project(binding:binding)
let packet = try E.Packet(binding:binding,stages:projected)
check(packet.stages[.detector]?.count == 1 && packet.stages[.recognized]?.count == 1 && packet.stages[.rejected]?.count == 1,
      "real three stages projected and retained")
check(packet.stages[.decoded] == nil,"decoded remains unavailable in packet")
check(packet.stages[.recognized]?[0].bounds.minX == 10/256.0,"original pixel coordinates projected exactly once")
let empty = try S.capture(width:256,height:256,detectionBoxes:[],recognizedRegions:[],rejectedReads:[])
let emptyPacket = try E.Packet(binding:binding,stages:empty.project(binding:binding))
check(emptyPacket.stages[.detector]?.isEmpty == true && emptyPacket.stages[.recognized]?.isEmpty == true,"observed empty stages remain available")
check(emptyPacket.stages[.decoded] == nil,"empty observed stages do not imply raw decoded observation")
let unavailable = try S(width:256,height:256)
let unavailableStages = try unavailable.project(binding:binding)
check(unavailableStages.isEmpty,"all-unavailable snapshot emits no observed empty stage")
let raw = try S.capture(width:256,height:256,detectionBoxes:nil,recognizedRegions:nil,rejectedReads:nil,decodedRegions:[rejected])
check(raw.decoded?.count == 1 && raw.recognized == nil,"decoded exists only on explicit actual observation")
let row = S.Observation(sourceIndex:1,polygon:quad(),text:"text",confidence:0.9)
fails("dimensions") { _ = try S(width:0,height:256) }
fails("record budget") { _ = try S(width:256,height:256,detector:Array(repeating:row,count:4097)) }
let duplicateSnapshot = try S(width:256,height:256,recognized:[row,row])
var duplicateAudit: [String] = []
let duplicateStages = try duplicateSnapshot.project(binding:binding,audit:{ duplicateAudit.append($0) })
check(duplicateStages[0].records.count == 2 && duplicateAudit == ["recognized.duplicateSourceIndex"],
    "actual duplicate source indices preserved and diagnosed, never renumbered")
fails("negative source index") { _ = try S(width:256,height:256,recognized:[.init(sourceIndex:-1,polygon:quad(),text:"x",confidence:0.9)]) }
fails("nonfinite confidence") { _ = try S(width:256,height:256,recognized:[.init(sourceIndex:0,polygon:quad(),text:"x",confidence:.nan)]) }
fails("out-of-range confidence") { _ = try S(width:256,height:256,recognized:[.init(sourceIndex:0,polygon:quad(),text:"x",confidence:1.1)]) }
fails("nonfinite geometry") { _ = try S(width:256,height:256,recognized:[.init(sourceIndex:0,polygon:quad(.nan),text:"x",confidence:0.9)]) }
fails("text budget") { _ = try S(width:256,height:256,recognized:[.init(sourceIndex:0,polygon:quad(),text:String(repeating:"x",count:16385),confidence:0.9)]) }
fails("aggregate byte budget") {
    _ = try S(width:256,height:256,recognized:(0..<100).map { .init(sourceIndex:$0,polygon:quad(),text:String(repeating:"x",count:16384),confidence:0.9) })
}
fails("binding dimensions") { _ = try S(width:255,height:256,recognized:[row]).project(binding:binding) }
let clipped = try S(width:256,height:256,recognized:[.init(sourceIndex:9,polygon:quad(-2),text:"source",confidence:0.9)])
let clippedStage = try clipped.project(binding:binding)
check(clipped.recognized?[0].polygon[0].x == -2 && clippedStage[0].records[0].geometryClipped,"raw geometry retained and actual clipping observable")
let roi = NativeOCRSourceROIProbabilityEvidence(version:1,sourceWidth:256,sourceHeight:256,sourceDigest:String(repeating:"a",count:64),
    roi:.init(x:0,y:0,width:256,height:256),detector:.init(originX:0,originY:0,width:256,height:256,fullWidth:256,fullHeight:256),
    upperBounds:Data(repeating:255,count:256*256))
var seed = NativeOCRDetectorSeedEvidence(ownerID:"actual-owned",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
    mapOriginX:0,mapOriginY:0,mapFullWidth:256,mapFullHeight:256,sourceWidth:256,sourceHeight:256,
    components:[.init(seed:2570,pixelCount:30,meanProbability:0.99,runs:(10..<16).map { .init(y:$0,x:10,count:5) })])
seed.ownershipVersion = 2; seed.completeCCScan = true; seed.ambiguousComponents = []; seed.candidateComponents = []; seed.sourceProbabilityROI = roi
var budget = S.SeedBudget()
let sparse = try S.compactSeedRows([seed],budget:&budget)!
check(sparse[0]["sourceProbabilityROI"] == nil,"ROI removed before JSON encoding")
check(seed.sourceProbabilityROI?.upperBounds.count == 65536,"original detector evidence not mutated")
let withPayload = NativeCoreMLDetectionBox(polygon:quad(),score:0.88,detectorSeedEvidence:seed)
let lean = try S.capture(width:256,height:256,detectionBoxes:[withPayload],recognizedRegions:[accepted],rejectedReads:[rejected])
check(lean == snapshot && lean.retainedBytes < 1024,"snapshot strips seed payload and pixels by construction")
var exhausted = S.SeedBudget(); exhausted.remainingRuns = 0
fails("sparse run budget") { _ = try S.compactSeedRows([seed],budget:&exhausted) }
var noBytes = S.SeedBudget(); noBytes.remainingBytes = 1
fails("sparse byte budget") { _ = try S.compactSeedRows([seed],budget:&noBytes) }
var optionalAudit: [String] = []
let optionalRows = S.optionalSeedRows([seed],budget:&noBytes,audit:{ optionalAudit.append($0) })
check(optionalRows == nil && noBytes.remainingBytes == 1 && optionalAudit.contains("missingGeometry") &&
    optionalAudit.contains("seedBudgetFailure"),"optional geometry budget failure explicit and transactional")
let native = NativeCoreMLOCRLine(polygon:quad(),text:accepted.text,score:0.92,orientation:.vertical,detectorSeedEvidence:[seed])
let nativeStage = try S.projectNativeLines([native],binding:binding)
let nativePacket = try E.Packet(binding:binding,stages:[nativeStage])
let nativeSaved = try nativePacket.savedEvidence(currentOriginalItems:[],removalMaskAvailable:false)
let nativeRows = (nativeSaved["originalOCR"] as! [String:Any])["regions"] as! [[String:Any]]
check(nativeRows[0]["sourceOwnedDetectorComponents"] != nil,"native lines carry actual compact owned source geometry")
check(nativeRows[0]["sourceIndex"] == nil,"native row ordinal never fabricated as detector index")
var final = ReaderTranslationRegion(id:"actual-region",source:accepted.text,confidence:0.92,
    rect:CGRect(x:10/256.0,y:10/256.0,width:20/256.0,height:60/256.0),
    polygon:quad().map { CGPoint(x:$0.x/256,y:$0.y/256) })
final.detectorSeedEvidence = [seed]
final.sourceOCRAlternatives = [.init(originalText:"字",exactReading:"じ",paddedReading:"じ",rect:final.rect,
    primaryConfidence:0.8,exactConfidence:0.9,paddedConfidence:0.9)]
let (registered,metrics) = try registration(image:image,result:.init(ensembleStageSnapshot:snapshot),lines:[native],joined:[final])
check(registered.stages.count == 5 && registered.stages[.nativeLines]?.count == 1 && registered.stages[.finalRegions]?.count == 1,
      "actual Reader registration publishes live stages plus native lines and final regions")
let saved = try registered.savedEvidence(currentOriginalItems:[],removalMaskAvailable:false)
let availability = saved["ocrStageAvailability"] as! [String:String]
check(availability["decoded"] == "unavailable" && availability["detector"] == "observed:1","availability remains truthful at saved consumer boundary")
check(saved["originalDetector"] != nil && saved["originalRecognizer"] != nil && saved["originalRejectedReads"] != nil && saved["originalDecodedReads"] == nil,
      "detector recognized rejected reach consumers without invented decoded stage")
let finalRows = (saved["originalOCR"] as! [String:Any])["regions"] as! [[String:Any]]
check(finalRows[0]["sourceOwnedDetectorComponents"] != nil && finalRows[0]["detectorSeedEvidence"] == nil,
      "final stage retains compact owned geometry, not full seeds")
check(finalRows[0]["sourceReadingHints"] == nil &&
    (finalRows[0]["sourceOCRAlternatives"] as? [[String:Any]])?.count == 1,"Reader excludes retired reading hints and retains OCR alternatives")
check(metrics["mainOCREvidenceStages"] == 5,"actual stage count logged")
let invalidSeed = NativeOCRDetectorSeedEvidence(ownerID:"invalid",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",
    threshold:.nan,mapOriginX:0,mapOriginY:0,mapFullWidth:256,mapFullHeight:256,sourceWidth:256,sourceHeight:256,
    components:seed.components)
var invalidFinal = final
invalidFinal.detectorSeedEvidence = [invalidSeed]
let invalidNative = NativeCoreMLOCRLine(polygon:quad(),text:accepted.text,score:0.92,
    orientation:.vertical,detectorSeedEvidence:[invalidSeed])
let (softPacket,softMetrics) = try registration(image:image,result:.init(ensembleStageSnapshot:snapshot),
    lines:[invalidNative],joined:[invalidFinal])
check(softPacket.stages.count == 5 && softPacket.stages[.nativeLines]?.count == 1 && softPacket.stages[.finalRegions]?.count == 1,
    "invalid optional seed does not discard actual base stages or packet")
check(softMetrics["mainOCREvidence.nativeLines.missingGeometry"] == 1 &&
    softMetrics["mainOCREvidence.finalRegions.seedEncodingFailure"] == 1,"invalid optional geometry explicitly diagnosed")
var oversizedFinal = final
oversizedFinal.detectorSeedEvidence = Array(repeating:seed,count:65)
let oversizedNative = NativeCoreMLOCRLine(polygon:quad(),text:accepted.text,score:0.92,
    orientation:.vertical,detectorSeedEvidence:Array(repeating:seed,count:65))
let (oversizedPacket,oversizedMetrics) = try registration(image:image,result:.init(ensembleStageSnapshot:snapshot),
    lines:[oversizedNative],joined:[oversizedFinal])
check(oversizedPacket.stages.count == 5 && oversizedPacket.stages[.finalRegions]?.count == 1,
    "oversized optional seeds preserve valid measured stages")
check(oversizedMetrics["mainOCREvidence.nativeLines.seedBudgetFailure"] == 1 &&
    oversizedMetrics["mainOCREvidence.finalRegions.missingGeometry"] == 1,"oversized seed budget omission explicit")
let badFinal = ReaderTranslationRegion(id:final.id,source:final.source,confidence:final.confidence,rect:final.rect,
    polygon:[CGPoint(x:Double.nan,y:0),CGPoint(x:1,y:0),CGPoint(x:1,y:1)])
let (partialPacket,partialMetrics) = try registration(image:image,result:.init(ensembleStageSnapshot:snapshot),
    lines:[native],joined:[badFinal])
check(partialPacket.stages[.detector]?.count == 1 && partialPacket.stages[.nativeLines]?.count == 1 &&
    partialPacket.stages[.finalRegions] == nil && partialMetrics["mainOCREvidence.finalRegions.projectionFailure"] == 1,
    "invalid final projection preserves measured prior stages without fabricated empty final stage")
let (missing,missingMetrics) = try registration(image:image,result:.init(ensembleStageSnapshot:nil),lines:[],joined:[])
check(missing.stages[.detector] == nil && missing.stages[.recognized] == nil && missing.stages[.rejected] == nil,
      "missing pipeline snapshot never becomes three empty observed stages")
check(missing.stages[.nativeLines]?.isEmpty == true && missing.stages[.finalRegions]?.isEmpty == true &&
    missingMetrics["mainOCRSnapshotUnavailable"] == 1,"actual empty native/final stages remain explicit while snapshot absence is diagnosed")
print("Live ensemble snapshot/Reader checks: \(count) passed")
'''
prepared = (ensemble / "NativeMainEnsemblePreparedDB.swift").read_text()
source_binding = prepared[prepared.index("    struct SourceBinding:"):prepared.index("    convenience init(")]
sources = [models, box, carriers, line, result_type, support, "enum NativeMainEnsemblePreparedDB {\n" + source_binding + "}"]
for name in ["BrowserOCRSourceOrientation.swift", "NativeOCRSourceROIProbabilityEvidence.swift",
             "NativeOCRDetectorSeedEvidence.swift", "NativeOCRAcceptedSource.swift", "NativeOCREnsembleStageSnapshot.swift"]:
    sources.append((ocr / name).read_text())
for name in ["NativeMainEnsembleEvidenceLease.swift", "NativeMainEnsembleOCREvidence.swift", "NativeSourceOwnedComponentProjection.swift",
             "NativeCausalParagraphAxisGrouping.swift", "NativeCausalPartialSourceProjector.swift"]:
    sources.append((ensemble / name).read_text())
with tempfile.TemporaryDirectory(prefix="ocr-stage-snapshot-") as folder:
    folder = Path(folder)
    path = folder / "main.swift"
    path.write_text("import Foundation\n" + '\n'.join(sources) + checks)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(folder / "clang-cache"), SWIFT_MODULECACHE_PATH=str(folder / "swift-cache"))
    started = time.monotonic()
    subprocess.run(["swiftc", "-module-cache-path", str(folder / "swift-cache"), str(path), "-o", str(folder / "checks")],check=True,env=env)
    compiled = time.monotonic()
    subprocess.run([str(folder / "checks")],check=True,env=env)
    print(f"Synthetic bridge compile: {compiled-started:.3f}s; execution: {time.monotonic()-compiled:.3f}s")
