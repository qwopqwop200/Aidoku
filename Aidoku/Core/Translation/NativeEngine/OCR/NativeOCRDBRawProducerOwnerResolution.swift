import Foundation
import CryptoKit

/// CURRENT originals + actual pre-G.emit refinements ONLY. No packets, page paths,
/// witness catalogs, query provenance, sourceParent joins, recognition or overlap.
/// Full native seed objects remain authority; the minimal numeric32 wire is not.
enum NativeOCRDBRawProducerOwnerResolution {
    static let authABI="current-raw-typed-producer-exactquad-owner-v1"
    static let stageABI="pre-learned-current-raw-and-precomputed-refinements-v1"
    static let nativeReceiptCodec="native-jsonencoder-sortedkeys-fullseed-context-v1"
    struct Original: Codable, Sendable {
        let polygon:[[Double]]
        let detectorSeedEvidence:NativeOCRDetectorSeedEvidence?
    }
    struct FrameBinding: Codable, Sendable {
        let operationID:String,sourceFrameIdentity:String,producerRequestID:String
        let width:Int,height:Int
    }
    struct Record: Codable, Sendable {
        let requestID:String
        let origin:String
        let polygon:[[Double]]
        let sourceMembers:[Int]
        let originalDetectorIndex:Int?
    }
    struct Refinement: Codable, Sendable {let head:String;let record:Record}
    struct Resolution: Sendable {
        let ownerIndices:[Int]
        let reason:String?
        let proofKinds:[String]
        let contextID:String
        let authABI:String
        let stageABI:String
        // Exact retained raw objects certify payload identity within this context.
        let fullOwnerSeeds:[NativeOCRDetectorSeedEvidence]
    }
    fileprivate struct QuadKey:Hashable,Sendable {let vertices:[[Double]]}
    private struct Observation {
        let members:[Int],reasons:[String],kind:String
    }
    fileprivate struct Certificate:Sendable {let members:[Int],reasons:[String],kinds:[String]}
    struct Index:Sendable {
        let contextID:String
        let frame:FrameBinding
        let originalCount:Int
        let refinementCount:Int
        let producerContextAvailable:Bool
        let frameOperationBound:Bool
        fileprivate let originalSeeds:[NativeOCRDetectorSeedEvidence?]
        fileprivate let certificates:[QuadKey:Certificate]
    }
    private static func before(_ a:[[Double]],_ b:[[Double]])->Bool {
        for (x,y) in zip(a,b){for j in 0..<2{if x[j] != y[j]{return x[j]<y[j]}}}
        return false
    }
    private static func key(_ q:[[Double]])->QuadKey? {
        guard q.count==4,q.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else{return nil}
        var area=0.0
        for i in 0..<4{area += q[i][0]*q[(i+1)%4][1]-q[i][1]*q[(i+1)%4][0]}
        guard area != 0 else{return nil}
        var variants:[[[Double]]]=[]
        for ring in [q,Array(q.reversed())]{for i in 0..<4{variants.append(Array(ring[i...])+Array(ring[..<i]))}}
        return .init(vertices:variants.min(by:before)!)
    }
    private struct ContextReceipt:Encodable {
        let authABI:String,stageABI:String,codec:String
        let width:Int,height:Int
        let frame:FrameBinding
        let originals:[Original]
        let actualRefinements:[Refinement]?
    }
    /// These arguments MUST be the complete actual source arrays BEFORE G.emit,
    /// not reconstructed query provenance or surviving post-emission hypotheses.
    static func prepare(originals:[Original],width:Int,height:Int,
                        actualPrecomputedRefinements:[Refinement]?,frame:FrameBinding)throws->Index {
        let bound = !frame.operationID.isEmpty && !frame.sourceFrameIdentity.isEmpty && !frame.producerRequestID.isEmpty && frame.width==width && frame.height==height
        let seeds=originals.map(\.detectorSeedEvidence)
        var counts:[String:Int]=[:]
        for s in seeds {if let s{counts[s.ownerID,default:0]+=1}}
        let reasons:[[String]]=seeds.map{s in
            var r:[String]=[]
            if s?.ownerID.isEmpty != false || counts[s?.ownerID ?? ""] != 1{r.append("raw-ownerID-missing-or-not-unique")}
            if s?.sourceWidth != width || s?.sourceHeight != height{r.append("raw-seed-not-current-frame")}
            if s?.completeCCScan != true{r.append("raw-owned-component-scan-not-complete")}
            if (s?.mapFullWidth ?? 0)<=0 || (s?.mapFullHeight ?? 0)<=0{r.append("raw-grid-invalid")}
            if s==nil || s?.ambiguousComponents==nil || s?.candidateComponents==nil{r.append("raw-full-role-payload-missing")}
            return r
        }
        var groups:[QuadKey:[Observation]]=[:]
        func add(_ q:[[Double]],_ members:[Int],_ r:[String],_ kind:String) {
            guard let k=key(q) else{return}
            groups[k,default:[]].append(.init(members:Array(Set(members)).sorted(),reasons:Array(Set(r)).sorted(),kind:kind))
        }
        for i in originals.indices{add(originals[i].polygon,[i],reasons[i],"current-raw-original")}
        let heads:Set<String>=["axis","fragment","normal","closedContour"]
        for ref in actualPrecomputedRefinements ?? [] {
            let rec=ref.record;var r:[String]=[],members=rec.sourceMembers
            if !heads.contains(ref.head) || rec.origin != "sourceRefinement"{r.append("not-actual-typed-refinement-head")}
            if !bound || rec.requestID != frame.producerRequestID{r.append("producer-operation-request-binding-mismatch")}
            if members.isEmpty || !members.allSatisfy({$0>=0 && $0<originals.count}) || Set(members).count != members.count{r.append("producer-members-invalid");members=[]}
            if let anchor=rec.originalDetectorIndex,!members.contains(anchor){r.append("producer-explicit-anchor-not-in-members")}
            for i in members{r += reasons[i]}
            // sourceIndex/sourceParent/seed.parentBoxIndex are deliberately absent.
            add(rec.polygon,members,r,"actual-precomputed-typed-refinement")
        }
        var certificates:[QuadKey:Certificate]=[:]
        for (q,observations) in groups {
            let sets=Set(observations.map(\.members));var rs=Set(observations.flatMap(\.reasons))
            if sets.count != 1{rs.insert("exact-quad-source-observations-disagree-on-complete-owner-set")}
            let members=sets.count==1 && rs.isEmpty ? sets.first!:[]
            certificates[q] = .init(members:members,reasons:rs.sorted(),kinds:Set(observations.map(\.kind)).sorted())
        }
        // Native context token is a binding receipt, NEVER a numerical feature.
        // Python/native JSON transport hashes are NOT asserted byte-identical.
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(ContextReceipt(authABI:authABI,stageABI:stageABI,codec:nativeReceiptCodec,width:width,height:height,frame:frame,originals:originals,actualRefinements:actualPrecomputedRefinements))
        let contextID=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        return .init(contextID:contextID,frame:frame,originalCount:originals.count,refinementCount:actualPrecomputedRefinements?.count ?? 0,producerContextAvailable:actualPrecomputedRefinements != nil,frameOperationBound:bound,originalSeeds:seeds,certificates:certificates)
    }
    /// Geometry ONLY. No overload accepts an Individual/Record/provenance.
    static func resolve(queryQuad:[[Double]],index:Index)->Resolution {
        func fail(_ reason:String)->Resolution{.init(ownerIndices:[],reason:reason,proofKinds:[],contextID:index.contextID,authABI:authABI,stageABI:stageABI,fullOwnerSeeds:[])}
        guard index.frameOperationBound else{return fail("current-frame-operation-binding-missing")}
        guard index.producerContextAvailable else{return fail("actual-precomputed-producer-context-missing")}
        guard let k=key(queryQuad) else{return fail("invalid-query-quad")}
        guard let cert=index.certificates[k] else{return fail("no-exact-raw-or-typed-producer-witness")}
        guard cert.reasons.isEmpty else{return fail(cert.reasons.joined(separator:";"))}
        return .init(ownerIndices:cert.members,reason:nil,proofKinds:cert.kinds,contextID:index.contextID,authABI:authABI,stageABI:stageABI,fullOwnerSeeds:cert.members.compactMap{index.originalSeeds[$0]})
    }
}
