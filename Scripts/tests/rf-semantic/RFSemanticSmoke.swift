import Foundation
import CryptoKit
@main enum RFSemanticSmoke {
 typealias A = NativeOCRRFSemanticAdmission
 typealias G = NativeOCRIndividualGeometryHypotheses
 static func q(_ x:Double)->[G.Point] { [.init(x:x,y:10),.init(x:x+20,y:10),.init(x:x+20,y:80),.init(x:x,y:80)] }
 static func input(_ name:String)->G.Output {
  let p=q(10);let r=G.Record(requestID:"unit",sourceIndex:0,sourceParent:0,sourceMembers:[],alternativeID:name,origin:.corrected,originalDetectorIndex:nil,polygon:p)
  return G.emit(requestID:"unit",corrected:[r],originals:[])
 }
 static func policy() throws -> A.Policy {
  try JSONDecoder().decode(A.Policy.self,from:Data(#"{"schema":"rf-semantic-source-observation-rules-v1","rules":[{"otherClass":3,"minOtherMean":0.55,"maxTextMean":0.05,"maxObservedRecognitionAgreement":0.96}],"preserveSourceStageAnchors":true,"gridSide":162,"quadratureSide":16,"semanticClassOrder":["text","soundEffect","balloon","frame"],"requiresObservedRecognitionContext":true,"modelWeightsSHA256":"verified"}"#.utf8))
 }
 static func main() throws {
  if CommandLine.arguments.count>1 { try replay();return }
  var cp=[Float](repeating:0,count:1500);cp[3]=0.9;cp[5]=0.01
  var grid=try NativeRFDETRSemanticGrid.aggregate(width:100,height:100,classProbabilities:cp){q,_,_ in q<2 ? 80 : -80};grid.modelWeightsSHA256="verified"
  precondition(grid.isValid && abs(grid.probabilities[3*162*162]-0.9)<1e-6)
  let p=try policy();let observed=[A.Observation(polygon:q(70),confidence:0.99)];let raw=input("learned-boundary/model/original/0")
  let removed=try A.apply(raw,grid:grid,recognition:observed,policy:p)
  precondition(removed.output.individuals.isEmpty && removed.report.allQueryCount==300)
  let anchor=try A.apply(input("original/0"),grid:grid,recognition:observed,policy:p)
  precondition(anchor.output.individuals.count==1)
  let supported=try A.apply(raw,grid:grid,recognition:[.init(polygon:q(10),confidence:0.99)],policy:p)
  precondition(supported.output.individuals==raw.individuals)
  let missing=try A.apply(raw,grid:nil,recognition:observed,policy:p)
  precondition(missing.output.individuals==raw.individuals && missing.report.missingEvidenceKeptIndices==[0])
  let noRec=try A.apply(raw,grid:grid,recognition:[],policy:p);precondition(noRec.output.individuals==raw.individuals)
  var wrong=grid;wrong.modelWeightsSHA256="different";let unbound=try A.apply(raw,grid:wrong,recognition:observed,policy:p);precondition(!unbound.report.gridAvailable)
  let means=A.means(q(10),grid:grid);let reversed=A.means(Array(q(10).reversed()),grid:grid)
  precondition(zip(means,reversed).allSatisfy{abs($0-$1)<1e-12})
  let bytes=try JSONEncoder().encode(removed.report);_ = try JSONDecoder().decode(A.Report.self,from:bytes)
  let near = G.Record(requestID:"unit",sourceIndex:1,sourceParent:0,sourceMembers:[0],alternativeID:"corrected/near",origin:.corrected,originalDetectorIndex:nil,polygon:q(10.2))
  let exact = G.Record(requestID:"unit",sourceIndex:0,sourceParent:0,sourceMembers:[0],alternativeID:"corrected/exact",origin:.corrected,originalDetectorIndex:nil,polygon:q(10))
  let portfolio = G.admitting(G.emit(requestID:"unit",corrected:[exact,near],originals:[]),bboxScores:[0.8,0.7],threshold:0.07)
  let terminalPolicy = try JSONDecoder().decode(A.Policy.self,from:Data(#"{"schema":"rf-semantic-source-observation-rules-v1","rules":[],"preserveSourceStageAnchors":true,"gridSide":162,"quadratureSide":16,"semanticClassOrder":["text","soundEffect","balloon","frame"],"requiresObservedRecognitionContext":true,"modelWeightsSHA256":"verified","finalCoverThreshold":0.95,"finalCoverRanking":"representative-quality"}"#.utf8))
  let terminal = try A.apply(portfolio,grid:grid,recognition:observed,qualityScores:[0.9,0.7],policy:terminalPolicy)
  precondition(terminal.report.keptIndices == [0] && terminal.output.individuals == [portfolio.individuals[0]])
  precondition(terminal.report.finalCover?.replacements.first?.representativeIndex == 0)
  let missingQuality = try A.apply(portfolio,grid:grid,recognition:observed,qualityScores:[0.9],policy:terminalPolicy)
  precondition(missingQuality.output.individuals == portfolio.individuals)
  let partialQuality = try A.apply(portfolio,grid:grid,recognition:observed,qualityScores:[0.9,nil],policy:terminalPolicy)
  precondition(partialQuality.output.individuals == portfolio.individuals)
  let terminalMissingGrid = try A.apply(portfolio,grid:nil,recognition:observed,qualityScores:[0.9,0.7],policy:terminalPolicy)
  precondition(terminalMissingGrid.output.individuals == portfolio.individuals)
  try JointEvidenceFocusedTests.run()
  print("PASS: all300 aggregation/class order, anchors, positive OCR veto, missing evidence, model binding, quad winding, immutable selection and report")
 }
 struct RepresentativeScores:Decodable {let scores:[Double?];let keptIndices:[Int]}
 struct Saved:Decodable {let page:String;let sourceSHA256:String;let output:G.Output;let representatives:RepresentativeScores?}
 struct Context:Decodable {let recognition:[A.Observation]}
 struct Request:Decodable {let page:String;let geometry:String;let geometrySHA256:String;let context:String;let contextSHA256:String;let field:String;let fieldSHA256:String;let sourceSHA256:String;let width:Int;let height:Int;let modelWeightsSHA256:String;let output:String;let referenceInventory:String?;let referenceInventorySHA256:String?}
 static func digest(_ d:Data)->String {SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()}
 static func replay() throws {
  let p=try JSONDecoder().decode(A.Policy.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])));let enc=JSONEncoder();enc.outputFormatting=[.sortedKeys]
  while let line=readLine() {
   let r=try JSONDecoder().decode(Request.self,from:Data(line.utf8));let bytes=try Data(contentsOf:URL(fileURLWithPath:r.geometry));let cb=try Data(contentsOf:URL(fileURLWithPath:r.context));let fb=try Data(contentsOf:URL(fileURLWithPath:r.field))
   guard digest(bytes)==r.geometrySHA256,digest(cb)==r.contextSHA256,digest(fb)==r.fieldSHA256,fb.count==4*162*162*4 else{throw A.Failure.invalidPolicy}
   let s=try JSONDecoder().decode(Saved.self,from:bytes);guard s.page==r.page,s.sourceSHA256==r.sourceSHA256 else{throw A.Failure.invalidPolicy}
   let c=try JSONDecoder().decode(Context.self,from:cb);let v=fb.withUnsafeBytes{Array($0.bindMemory(to:Float.self))};let grid=NativeRFDETRSemanticGrid(width:r.width,height:r.height,side:162,probabilities:v,modelWeightsSHA256:r.modelWeightsSHA256)
   let quality=s.representatives.map { report in report.keptIndices.map { report.scores.indices.contains($0) ? report.scores[$0] : nil } }
   var reference:G.Output?
   if let path=r.referenceInventory {
    let data=try Data(contentsOf:URL(fileURLWithPath:path))
    guard digest(data)==r.referenceInventorySHA256 else {throw A.Failure.invalidPolicy}
    let saved=try JSONDecoder().decode(Saved.self,from:data)
    guard saved.page==s.page,saved.sourceSHA256==s.sourceSHA256 else {throw A.Failure.invalidPolicy}
    reference=saved.output
   }
   let result=try A.apply(s.output,grid:grid,recognition:c.recognition,qualityScores:quality,referenceInventory:reference,policy:p)
   let d:[String:Any]=["page":s.page,"sourceSHA256":s.sourceSHA256,"inputSHA256":r.geometrySHA256,"RFFieldSHA256":r.fieldSHA256,"modelWeightsSHA256":r.modelWeightsSHA256,"GTAtInference":false,"output":try JSONSerialization.jsonObject(with:enc.encode(result.output)),"rfSemanticAdmission":try JSONSerialization.jsonObject(with:enc.encode(result.report))]
   try JSONSerialization.data(withJSONObject:d,options:[.sortedKeys]).write(to:URL(fileURLWithPath:r.output),options:.atomic);print(r.page);fflush(stdout)
  }
 }
}
