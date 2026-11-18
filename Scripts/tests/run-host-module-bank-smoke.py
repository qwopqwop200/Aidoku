#!/usr/bin/env python3
"""Actual typed observers and host persistence with a model-free fake producer."""
from pathlib import Path
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR"
ENSEMBLE = ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble"


def structure(text, marker):
    start = text.index(marker)
    opened = text.index("{", start)
    depth, end = 1, opened + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


detector = (OCR / "NativeCoreMLDetector.swift").read_text()
recognizer = (OCR / "NativeCoreMLRecognizer.swift").read_text()
pipeline = (OCR / "NativeCoreMLOCRPipeline.swift").read_text()
models = (ROOT / "Aidoku/Core/Translation/NativeEngine/Layout/NativeRFDETRLayoutModels.swift").read_text()
models = models[:models.index("/// Compact raw mask logits")]
sources = ["import Foundation\nimport CoreGraphics\nimport ImageIO\nimport CryptoKit\n", models,
    detector[detector.index("@available(iOS 18.0, *)"):detector.index("@available(iOS 18.0, *)\nstruct NativeCoreMLDetectionCanvas")],
    recognizer[recognizer.index("@available(iOS 18.0, *)"):recognizer.index("/// Explicit in-memory diagnostic")],
    pipeline[pipeline.index("@available(iOS 18.0, *)\nstruct NativeCoreMLOCRLine:"):
             pipeline.index("@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics:")]]
columns = (OCR / "NativeOCRDBChildColumnEvidence.swift").read_text()
clearance = (OCR / "NativeOCRDBRecognitionClearance.swift").read_text()
sources += [structure(columns, "struct NativeOCRDBComponentRun:"), structure(columns, "struct NativeOCRDetectorColumnEvidence:"),
            "enum NativeOCRDBRecognitionClearance {\n" + structure(clearance, "    struct Evidence:") + "\n}"]
bbox = (OCR / "NativeOCRBBoxConfidenceAdmission.swift").read_text()
sources.append("enum NativeOCRBBoxConfidenceAdmission {\n typealias G = NativeOCRIndividualGeometryHypotheses\n" +
    "\n".join(structure(bbox, marker) for marker in ["    struct Row:", "    struct Report:", "    struct Production:"]) + "\n}")
for name in ["BrowserOCRSourceOrientation.swift", "NativeOCRSourceROIProbabilityEvidence.swift", "NativeOCRDetectorSeedEvidence.swift",
             "NativeOCRAcceptedSource.swift", "NativeOCRIndividualGeometryHypotheses.swift", "NativeOCRGeometryDeduplication.swift",
             "NativeOCRPreRecognitionFilter.swift", "NativeOCRPostRecognitionDeduplication.swift", "NativeOCRRawModuleObservation.swift"]:
    sources.append((OCR / name).read_text())
evidence = (ENSEMBLE / "NativeMainEnsembleOCREvidence.swift").read_text()
sources.append("""
enum NativeMainEnsembleOCREvidence {
    enum Failure: Error {case digest,binding}
    struct Binding {init(_ source:NativeRFDETRSourceImage,fileSHA:String?) {}}
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
""" + structure(evidence, "    static func cachedBinding(") + "\n}")
sources += [(ROOT / "Scripts/image-translation/HostRenderProvenance.swift").read_text(),
            (ROOT / "Scripts/image-translation/HostModuleBank.swift").read_text()]
checks = r'''
typealias B=HostModuleBank
typealias O=NativeOCRRawModuleObservation
typealias G=NativeOCRIndividualGeometryHypotheses
var checks=0
@MainActor func check(_ value:@autoclosure ()->Bool,_ reason:String) {precondition(value(),reason);checks+=1}
@MainActor func fails(_ body:()throws->Void) {do {try body();preconditionFailure("invalid bank accepted")} catch {checks+=1}}
let root=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
let bytes=Data(repeating:220,count:16*16*3)
let image=CGImage(width:16,height:16,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:48,
    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:0),provider:CGDataProvider(data:bytes as CFData)!,
    decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
let source=root.appendingPathComponent("input.png")
let encoder=CGImageDestinationCreateWithURL(source as CFURL,"public.png" as CFString,1,nil)!
CGImageDestinationAddImage(encoder,image,nil);precondition(CGImageDestinationFinalize(encoder))
let sourceSHA=try HostRenderProvenance.fileSHA256(source),imageID=try NativeRFDETRSourceImage.decode(image).identity
let h=String(repeating:"a",count:64),c=String(repeating:"b",count:64),p=String(repeating:"c",count:64)
let roles=Dictionary(uniqueKeysWithValues:B.ocrOnlyRequiredModelRoles.map {($0,h)})
let required=O.Stage.allCases.map(\.rawValue)+["recRequested","recDecoded","sourceDB","sourceRF"]
let schemas=Dictionary(uniqueKeysWithValues:required.map {($0,"fake-current-observed-v1")})
let contract=B.Contract(pageID:"metadata-only-page",sourceEncodedSHA256:sourceSHA,sourceImageIdentity:imageID,
    width:16,height:16,modelSHA256:roles,configurationSHA256:c,producerSHA256:p,stageSchemas:schemas,
    requiredStages:required,requiredModelRoles:B.ocrOnlyRequiredModelRoles)
let directory=root.appendingPathComponent("bank")
let session=try B.Session(directory:directory,sourceURL:source,original:image,contract:contract)
let observer=session.rawObserver
let binding=O.Binding(requestID:"actual-request",sourceImageIdentity:imageID,width:16,height:16,
    sourceAnchorMode:"source-anchor-fixed-prerec-v1",runtimePolicyVersion:"fake-current-policy")
func quad(_ x:Double)->[CGPoint] {[.init(x:x,y:1),.init(x:x+3,y:1),.init(x:x+3,y:7),.init(x:x,y:7)]}
func bank()->G.Output {
    G.emit(requestID:"actual-request",corrected:[1,5].enumerated().map {i,x in
        .init(requestID:"actual-request",sourceIndex:40+i,sourceParent:10+i,sourceMembers:[],alternativeID:"actual/\(i)",
            origin:.corrected,originalDetectorIndex:nil,polygon:quad(Double(x)).map {.init(x:Double($0.x),y:Double($0.y))})},
        originals:[],layout:[],refinements:[],mode:.correctedOnly)
}
let input=bank(),scheduled=G.selecting(input,indices:[1])
let roi=NativeOCRSourceROIProbabilityEvidence(version:1,sourceWidth:16,sourceHeight:16,sourceDigest:h,
    roi:.init(x:1,y:1,width:2,height:2),detector:.init(originX:0,originY:0,width:16,height:16,fullWidth:16,fullHeight:16),
    upperBounds:Data([0,17,128,255]))
var seed=NativeOCRDetectorSeedEvidence(ownerID:"db:16x16:0,0:0",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",
    threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:16,mapFullHeight:16,sourceWidth:16,sourceHeight:16,
    components:[.init(seed:17,pixelCount:1,meanProbability:0.99,runs:[.init(y:1,x:1,count:1)])])
seed.sourceProbabilityROI=roi;seed.ownershipVersion=2;seed.completeCCScan=true;seed.ambiguousComponents=[];seed.candidateComponents=[]
observer.originalDetector([.init(polygon:quad(1),score:0.9,detectorSeedEvidence:seed)],binding:binding)
observer.proposals(input,binding:binding)
let bbox=NativeOCRBBoxConfidenceAdmission.Production(output:input,report:.init(schema:"fake-current-bbox",threshold:0.85,
    applied:true,status:"observed",inputCount:2,keptCount:2,rejectedCount:0,scoreDefinition:"actual-fake-values",
    rows:[.init(inputOrdinal:0,bboxConfidence:0.9,kept:true),.init(inputOrdinal:1,bboxConfidence:0.95,kept:true)]))
observer.bboxAdmission(bbox,binding:binding)
let special=Double(bitPattern:0x7ff8000000001234)
var features=[Double](repeating:0.25,count:165);features[0] = -0.0;features[1]=special;features[2] = .infinity
let featureRows=[features,features.map {$0}]
let pre=NativeOCRPreRecognitionFilter.Report(schema:"fake-current-pre165",inputCount:2,keptIndices:[1],
    missingEvidenceKeptIndices:[],scores:[0.1,0.9],threshold:0.5,recognizerCalls:0,geometryModified:false)
observer.preRecognition(input:input,scheduled:scheduled,source165:featureRows,report:pre,binding:binding)
let read=NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:quad(5),text:"e\u{301}日本",confidence:Double(0.5).nextUp)
observer.postRecognition(scheduled:scheduled,input:scheduled,reads:[read],source165Indices:[1],accepted165:[features],
    source166:[features+[read.confidence]],binding:binding)
let dedup=NativeOCRPostRecognitionDeduplication.Result(output:scheduled,report:.init(inputCount:1,keptIndices:[0],
    replacements:[],polygonIoUThreshold:0.85))
observer.deduplication(input:scheduled,result:dedup,binding:binding)
weak var kept:NativeOCRAcceptedSource.PacketTable?
do {
    let packet=NativeOCRAcceptedSource.Packet(polygon:quad(1),text:"original-body",score:0.99,orientation:.vertical,
        orientationIsEstimated:false,sourceTileBounds:nil,erasurePolygons:[],detectorSeedEvidence:[seed])
    let one=NativeOCRAcceptedSource.PacketTable(packets:[packet,packet],width:16,height:16)
    let two=NativeOCRAcceptedSource.PacketTable(packets:[packet,packet],width:16,height:16)
    kept=one
    let lines=[one,one,two].enumerated().map {i,t in
        NativeCoreMLOCRLine(polygon:quad(1),text:"retained",score:0.99,orientation:.vertical,
            acceptedSource:.init(.init(table:t,body:[0],readings:[],unknownDedup:[1],hasUntrackedInputs:false)))
    }
    observer.acceptedMembership(lines,binding:binding)
}
check(kept != nil,"actual table objects strongly retained until finish")
let rec=session.recognitionObserver
let request=NativeCoreMLRecognitionObservations.Request(requestID:"actual-request",generation:1,
    callerConfidenceThreshold:0.3,appliedConfidenceThreshold:0.3)
let region=NativeCoreMLRecognitionRegion(sourceIndex:0,polygon:quad(5),samplingPolygon:quad(4),minimumSequenceWidth:32)
try rec.record(.began(request:request,requestedRegions:2))
try rec.record(.requested(request:request,region:region))
try rec.record(.decoded(.init(request:request,region:region,finalText:read.text,finalConfidence:read.confidence,
    tokenObservations:[],greedyObservation:.init(text:"",confidence:0,tokenObservations:[]),cacheHit:false,admitted:true,reason:.accepted)))
try rec.record(.requested(request:request,region:region))
try rec.record(.decoded(.init(request:request,region:region,finalText:read.text,finalConfidence:read.confidence,
    tokenObservations:[],greedyObservation:nil,cacheHit:true,admitted:true,reason:.accepted)))
try rec.record(.finished(request:request,decodedRegions:2))
let external=root.appendingPathComponent("external.raw")
try Data([1,2,3,4]).write(to:external)
let externalSHA=try HostRenderProvenance.fileSHA256(external)
for stage in ["sourceDB","sourceRF"] {
    try session.referenceExternal(stage:stage,url:external,expectedSHA256:externalSHA,sourceEncodedSHA256:sourceSHA,
        schema:"fake-current-raw",identity:["modelSHA256":h,"configurationSHA256":c,"producerSHA256":p])
}
let manifestURL=try session.finish()
check(kept == nil,"retained object graph released only after final seal")
let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! [String:Any]
check(manifest["complete"] as? Bool == true,"all observed stages and exact caller identity sealed")
check(manifest["uniqueStoredDataBytes"] as? Int == 4,"same ROI bytes stored once across original detector and both tables")
check((manifest["logicalDataBytes"] as! Int)>4,"logical repeated ROI bytes reported separately")
check((manifest["objectDefinitions"] as! [[String:Any]]).count == 2,"content-equal tables remain distinct actual objects")
let artifacts=manifest["artifacts"] as! [[String:Any]]
let matrix=artifacts.first {$0["shape"] as? [Int] == [2,165]}!
let matrixData=try Data(contentsOf:directory.appendingPathComponent(matrix["path"] as! String))
let firstBits=matrixData.withUnsafeBytes {b in (0..<165).map {UInt64(littleEndian:b.loadUnaligned(fromByteOffset:$0*8,as:UInt64.self))}}
check(firstBits == features.map(\.bitPattern),"source165 NaN payload/signedzero/infinity bits exact")
check(artifacts.contains {$0["shape"] as? [Int] == [1,166]},"source166 captured without column loss")
let decodedArtifact=artifacts.first {$0["stage"] as? String == "recDecoded"}!
let decodedLines=try String(contentsOf:directory.appendingPathComponent(decodedArtifact["path"] as! String),encoding:.utf8).split(separator:"\n")
check(decodedLines.count == 2,"all pre-admission callbacks stored without truncation")
let decoded=try decodedLines.map {try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
check(decoded[0]["greedyAvailability"] as? String == "observed" && decoded[1]["greedyAvailability"] as? String == "unavailable","greedy nil vs actually empty preserved")
let resume=try B.canResume(directory:directory,sourceURL:source,contract:contract)
check(resume,"same exact source/config/model/producer/schema and all checksums resumes")
var wrong=contract;wrong.schemaVersion="different-schema"
let wrongResume=try B.canResume(directory:directory,sourceURL:source,contract:wrong)
check(!wrongResume,"schema change cannot resume")
func changedContract(_ key:String,_ value:Any)throws->B.Contract {
    var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(contract)) as! [String:Any]
    object[key]=value
    return try JSONDecoder().decode(B.Contract.self,from:JSONSerialization.data(withJSONObject:object))
}
for (key,value) in [("configurationSHA256",h),("producerSHA256",h),("sourceImageIdentity",h)] {
    let changed=try changedContract(key,value)
    let accepted=try B.canResume(directory:directory,sourceURL:source,contract:changed)
    check(!accepted,"changed identity component rejected: \(key)")
}
let otherModels=try changedContract("modelSHA256",Dictionary(uniqueKeysWithValues:B.ocrOnlyRequiredModelRoles.map {($0,p)}))
let otherModelsResume=try B.canResume(directory:directory,sourceURL:source,contract:otherModels)
check(!otherModelsResume,"changed frozen model identity rejected")
let otherSchemas=try changedContract("stageSchemas",Dictionary(uniqueKeysWithValues:required.map {($0,"different-stage-schema")}))
let otherSchemasResume=try B.canResume(directory:directory,sourceURL:source,contract:otherSchemas)
check(!otherSchemasResume,"changed stage ABI rejected")
fails {_ = try B.Session(directory:directory,sourceURL:source,original:image,contract:contract)}
let wrongSource=root.appendingPathComponent("wrong-source.png")
try Data([0,1,2]).write(to:wrongSource)
fails {_ = try B.canResume(directory:directory,sourceURL:wrongSource,contract:contract)}
let transactionManifest=directory.appendingPathComponent(manifest["contractPath"] as! String).deletingLastPathComponent().appendingPathComponent("manifest.json")
let originalReceipt=try Data(contentsOf:transactionManifest)
try Data("{}".utf8).write(to:transactionManifest)
let alteredReceipt=try B.canResume(directory:directory,sourceURL:source,contract:contract)
check(!alteredReceipt,"current pointer cannot bypass immutable transaction receipt")
try originalReceipt.write(to:transactionManifest)
try Data([0]).write(to:directory.appendingPathComponent(matrix["path"] as! String))
let damagedResume=try B.canResume(directory:directory,sourceURL:source,contract:contract)
check(!damagedResume,"changed matrix cannot resume")
let incompleteDirectory=root.appendingPathComponent("incomplete")
let incomplete=try B.Session(directory:incompleteDirectory,sourceURL:source,original:image,contract:contract)
incomplete.unavailable(stage:"preRecognition",reason:"explicit-byte-budget")
let incompleteURL=try incomplete.finish()
let incompleteJSON=try JSONSerialization.jsonObject(with:Data(contentsOf:incompleteURL)) as! [String:Any]
check(incompleteJSON["complete"] as? Bool == false,"missing stages never fabricate empty observations")
let incompleteResume=try B.canResume(directory:incompleteDirectory,sourceURL:source,contract:contract)
check(!incompleteResume,"incomplete bank never resumes")
let unknown=try changedContract("configurationSHA256",NSNull())
let unknownDirectory=root.appendingPathComponent("unknown-identity")
let unknownSession=try B.Session(directory:unknownDirectory,sourceURL:source,original:image,contract:unknown)
_ = try unknownSession.finish()
let unknownResume=try B.canResume(directory:unknownDirectory,sourceURL:source,contract:unknown)
check(!unknownResume,"unknown configuration is never a resumable identity")
let emptyContract=B.Contract(pageID:"empty-observed",sourceEncodedSHA256:sourceSHA,sourceImageIdentity:imageID,
    width:16,height:16,modelSHA256:roles,configurationSHA256:c,producerSHA256:p,stageSchemas:["empty":"actual-empty-v1"],
    requiredStages:["empty"],requiredModelRoles:B.ocrOnlyRequiredModelRoles)
let emptyDirectory=root.appendingPathComponent("observed-empty")
let emptySession=try B.Session(directory:emptyDirectory,sourceURL:source,original:image,contract:emptyContract)
try emptySession.writeJSON(stage:"empty",value:[String](),records:0)
emptySession.notExecuted(stage:"AOT",reason:"OCR-only source pass")
_ = try emptySession.finish()
let emptyResume=try B.canResume(directory:emptyDirectory,sourceURL:source,contract:emptyContract)
check(emptyResume,"actually observed zero records remain distinct from unavailable or not executed")
let recContract=B.Contract(pageID:"zero-crop-observed",sourceEncodedSHA256:sourceSHA,sourceImageIdentity:imageID,
    width:16,height:16,modelSHA256:roles,configurationSHA256:c,producerSHA256:p,
    stageSchemas:["recRequested":"actual-rec-v1","recDecoded":"actual-rec-v1"],
    requiredStages:["recRequested","recDecoded"],requiredModelRoles:B.ocrOnlyRequiredModelRoles)
let zeroDirectory=root.appendingPathComponent("zero-rec")
let zeroSession=try B.Session(directory:zeroDirectory,sourceURL:source,original:image,contract:recContract)
try zeroSession.recognitionObserver.record(.began(request:request,requestedRegions:0))
try zeroSession.recognitionObserver.record(.finished(request:request,decodedRegions:0))
_ = try zeroSession.finish()
let zeroResume=try B.canResume(directory:zeroDirectory,sourceURL:source,contract:recContract)
check(zeroResume,"actual began0/finished0 seals observed-empty REC streams")
let cancelledDirectory=root.appendingPathComponent("cancelled-rec")
let cancelledSession=try B.Session(directory:cancelledDirectory,sourceURL:source,original:image,contract:recContract)
try cancelledSession.recognitionObserver.record(.began(request:request,requestedRegions:0))
_ = try cancelledSession.finish()
let cancelledResume=try B.canResume(directory:cancelledDirectory,sourceURL:source,contract:recContract)
check(!cancelledResume,"began without successful finished cannot resume even with empty artifacts")
let invalidDirectory=root.appendingPathComponent("invalid-rec")
let invalidSession=try B.Session(directory:invalidDirectory,sourceURL:source,original:image,contract:recContract)
fails {try invalidSession.recognitionObserver.record(.requested(request:request,region:region))}
_ = try invalidSession.finish()
let invalidResume=try B.canResume(directory:invalidDirectory,sourceURL:source,contract:recContract)
check(!invalidResume,"requested callback without lifecycle fails closed")
let streamDirectory=root.appendingPathComponent("stream-budget")
let streamSession=try B.Session(directory:streamDirectory,sourceURL:source,original:image,contract:emptyContract,
    maximumBytes:32768,maximumArtifactBytes:8192)
try streamSession.appendJSON(stage:"empty",value:String(repeating:"x",count:5000))
fails {try streamSession.appendJSON(stage:"empty",value:String(repeating:"y",count:5000))}
streamSession.unavailable(stage:"empty",reason:"stream limit reached")
_ = try streamSession.finish()
let streamResume=try B.canResume(directory:streamDirectory,sourceURL:source,contract:emptyContract)
check(!streamResume,"finish cannot promote explicitly unavailable partial stream to observed")
let limitedDirectory=root.appendingPathComponent("bounded")
let limited=try B.Session(directory:limitedDirectory,sourceURL:source,original:image,contract:contract,maximumBytes:16384,maximumArtifactBytes:8192)
fails {try limited.writeJSON(stage:"proposals",value:["nontruncated":String(repeating:"x",count:20000)],records:1)}
limited.recordFailure("explicit budget failure")
let limitedURL=try limited.finish()
let limitedJSON=try JSONSerialization.jsonObject(with:Data(contentsOf:limitedURL)) as! [String:Any]
check(limitedJSON["complete"] as? Bool == false,"budget overflow seals unavailable not truncated success")
print("Host module bank fake-current observer checks: \(checks) passed; NN/API calls0; shared/main builds0")
'''

with tempfile.TemporaryDirectory(prefix="host-module-bank-") as folder:
    folder = Path(folder)
    source = folder / "main.swift"
    source.write_text("\n".join(sources) + checks)
    started = time.monotonic()
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(folder / "clang-cache"))
    subprocess.run(["swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
                    "-module-cache-path", str(folder / "swift-cache"), str(source), "-o", str(folder / "checks")], check=True, env=env)
    built = time.monotonic()
    subprocess.run([str(folder / "checks"), str(folder / "fixture")], check=True, env=env)
    print(f"Actual observer/exporter compile {built-started:.3f}s; checks {time.monotonic()-built:.3f}s")
