"""Focused native checks of learned ranking and complete pre-rec crop identity."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
NATIVE=ROOT/'Aidoku/Aidoku/Core/Translation/NativeEngine/OCR'
OUT=ROOT/'Aidoku/build/stage-dedup-quality-check'
OUT.mkdir(parents=True,exist_ok=True)
region_source=(NATIVE/'NativeCoreMLRecognizer.swift').read_text()
region=region_source[region_source.index('@available(iOS 18.0, *)'):region_source.index('@available(iOS 18.0, *)\nstruct NativeCoreMLRecognizedRegion:')]
host=(ROOT/'Aidoku/Scripts/image-translation/HostModelRefresh.swift').read_text()
neutral=host[host.index('    private static func neutralCrop('):host.index('    private struct RoleReplayPolicy:')]
fields=set(re.findall(r'^    let (\w+):',region,re.M))
assert all('r.'+name in neutral for name in fields-{'sourceIndex'}),fields
harness='''import Foundation
import CoreGraphics
// Only storage is stubbed; actual Region and neutralCrop declarations follow.
struct NativeOCRDetectorColumnEvidence: Codable, Equatable, Sendable { let marker: Int }
'''+region+'\nenum CropCheck {\n'+neutral+'''
static func same(_ a: NativeCoreMLRecognitionRegion, _ b: NativeCoreMLRecognitionRegion) -> Bool {
    neutralCrop(a) == neutralCrop(b)
}
}
'''+r'''
var checks=0
func check(_ value: Bool, _ message: String) {
    precondition(value,message);checks+=1
}
let quad=[CGPoint(x:0,y:0),CGPoint(x:10,y:0),CGPoint(x:10,y:10),CGPoint(x:0,y:10)]
let a=NativeCoreMLRecognitionRegion(sourceIndex:1,polygon:quad)
check(CropCheck.same(a,.init(sourceIndex:2,polygon:quad)),"IDs are metadata")
check(!CropCheck.same(a,.init(sourceIndex:2,polygon:quad,photometricMode:.luminanceContrast)),"photometric mode must survive")
check(!CropCheck.same(a,.init(sourceIndex:2,polygon:quad,useProvidedOrder:true)),"crop order must survive")
check(!CropCheck.same(a,.init(sourceIndex:2,polygon:quad,minimumSequenceWidth:32)),"sequence width must survive")
check(!CropCheck.same(a,.init(sourceIndex:2,polygon:quad,isThinFinePrintRecovery:true)),"fine-print mode must survive")
check(!CropCheck.same(a,.init(sourceIndex:2,polygon:quad,finePrintRetryPolygons:[quad])),"retry plan must survive")
check(!CropCheck.same(a,.init(sourceIndex:2,polygon:quad,samplingPolygon:quad)),"sampling provenance must survive")
check(!CropCheck.same(a,.init(sourceIndex:2,polygon:quad,recognitionColumnEvidence:.init(marker:1))),"column evidence must survive")
typealias S=NativeOCRPremergeCandidateSelection
typealias F=NativeOCRPremergeCandidateFeatures
let names=NativeOCRPremergeCandidateModel.featureNames
func quality(_ coef:[Double],bias:Double=0.1) -> Data {
    try! JSONSerialization.data(withJSONObject:["kind":"ridge","mean":Array(repeating:0.0,count:55),
        "scale":Array(repeating:1.0,count:55),"coef":coef,"bias":bias,"featureNames":names])
}
func policy(minimum:Double?=0.45,enabled:Bool?=nil)->Data {
    var config:[String:Any]=["iou":0.99,"containment":0.0,"axis":0.0,"across":2.0,"along":2.0,"minContrastSamples":0.0]
    if let minimum {config["minimumRecognitionConfidence"]=minimum}
    var value:[String:Any]=["schema":"source-confidence-iou-only-v1","qualityWeight":1.0,"contentWeight":0.0,
        "featureNames":names,"config":config]
    if let enabled {value["enabled"]=enabled}
    return try! JSONSerialization.data(withJSONObject:value)
}
var coefficient=Array(repeating:0.0,count:55);coefficient[11]=1
let learned=S(qualityData:quality(coefficient),policyData:policy())
check(learned.isAvailable && learned.usesOnlyLearnedSignalQuality && !learned.usesOnlyFixedConfidenceAndIoU,"fresh learned ranker allowed only for explicit replay")
var pixel=coefficient;pixel[0]=1
check(!S(qualityData:quality(pixel),policyData:policy()).usesOnlyLearnedSignalQuality,"shape/pixel predictor rejected")
var rec=coefficient;rec[30]=1
let recModel=S(qualityData:quality(rec),policyData:policy())
check(recModel.usesOnlyLearnedSignalQuality && !recModel.usesOnlyPreRecognitionSignalQuality,"pre-rec forbids rec scores")
let polys:[[F.Point]]=[[(0.0,0.0),(10,0),(10,10),(0,10)],[(0,0),(10.05,0),(10.05,10),(0,10)]].map { $0.map { .init(x:$0.0,y:$0.1) } }
var fa=Array(repeating:0.0,count:55);fa[8]=1;fa[9]=0.99;fa[11]=0.1;fa[29]=1;fa[30]=0.99
var fb=fa;fb[9]=0.7;fb[11]=0.9;fb[30]=0.6
let keep=NativeOCRPremergeCandidateModel.Decision(keep:true,score:0,failure:nil,punctuationPreserved:false)
let first=learned.select(polygons:polys,features:[fa,fb],content:[keep,keep])
check(first.keep == [false,true],"learned bbox quality outranks raw rec confidence")
check(first.aliases.count==1 && first.aliases[0].anchor==1,"alias refers to quality winner")
fb[30]=0.2
check(learned.select(polygons:polys,features:[fa,fb],content:[keep,keep]).keep == [true,true],"low-rec hypothesis cannot suppress verified peer")
fb[30]=0.6
check(S(qualityData:quality(coefficient),policyData:policy(enabled:false)).select(polygons:polys,features:[fa,fb],content:[keep,keep]).keep == [true,true],"disabled calibrated policy is a real no-op")
var fixed=Array(repeating:0.0,count:55);fixed[9]=0.5;fixed[30]=0.5
let legacy=S(qualityData:quality(fixed,bias:0),policyData:policy(minimum:nil))
check(legacy.usesOnlyFixedConfidenceAndIoU,"legacy asset remains compatible")
check(legacy.select(polygons:polys,features:[fa,fb],content:[keep,keep]).keep == [true,false],"legacy default behavior unchanged")
print("Native stage-dedup checks passed: \(checks)")
'''
main=OUT/'main.swift'
if not main.exists() or main.read_text()!=harness:main.write_text(harness)
sources=[NATIVE/n for n in ['NativeOCRPremergeCandidateFeatures.swift','NativeOCRPremergeCandidateModel.swift','NativeOCRPremergeCandidateSelection.swift']]+[main]
fingerprint=hashlib.sha256(b''.join(p.read_bytes() for p in sources)).hexdigest()
binary=OUT/'check';stamp=OUT/'fingerprint';build_seconds=0.
if not binary.exists() or not stamp.exists() or stamp.read_text()!=fingerprint:
    mapping={str(p):{'object':str(OUT/(p.stem+'.o')),'swift-dependencies':str(OUT/(p.stem+'.swiftdeps'))} for p in sources}
    mapping['']={'swift-dependencies':str(OUT/'master.swiftdeps')}
    output_map=OUT/'output-map.json';output_map.write_text(json.dumps(mapping))
    start=time.monotonic()
    subprocess.run(['xcrun','swiftc','-O','-incremental','-enable-batch-mode','-j','1','-module-name','StageDedupQualityCheck',
        '-module-cache-path',str(OUT/'module-cache'),'-output-file-map',str(output_map),*map(str,sources),'-o',str(binary)],check=True)
    build_seconds=time.monotonic()-start;stamp.write_text(fingerprint)
start=time.monotonic();result=subprocess.run([str(binary)],text=True,stdout=subprocess.PIPE,check=True)
report=dict(sourceFingerprint=fingerprint,buildSeconds=build_seconds,testSeconds=time.monotonic()-start,
    output=result.stdout,sourceImagesRead=0,MLInferences=0,scope='native ranking/provenance behavior, not full GT recall')
(OUT/'REPORT.json').write_text(json.dumps(report,indent=2));print(result.stdout,flush=True)
