import Foundation
import CoreGraphics
import CryptoKit

/// Diagnostic alternative to ONLY the untyped mandatory-point containment gate.
/// Does not replace semantic, foreign, ownership, whole, dense or GG terminal checks.
enum NativeOCRPointObligation401 {
    enum Role:String,Codable {
        case explicitEndpointCap, explicitProtectedMark
        case derivedEndpointGeometry
        case measurementDBGuard, ownedDBCell, nativeRLECell, privateHullVertex, sourceQuadVertex
        case originalOwnedUntypedSupport, inheritedUntypedSupport
    }
    struct Point {
        let ordinal:Int;let sourceOrdinal:Int;let position:CGPoint;let role:Role
        let provenance:String // actual callback/measurement field, never inferred from position
    }
    struct RGBA {let bytes:[UInt8];let width:Int;let height:Int;let stride:Int;let origin:CGPoint}
    struct Binding {
        let actualOld:[CGPoint];let sourceOrdinal:Int;let sourceSHA256:String
        let rgbaSHA256:String;let rootGGBodySHA256:String;let nativeFullFootprintSHA256:String
        let actualNativeFullFootprintVerified:Bool
    }
    struct Evidence {
        let rgba:RGBA;let rootGGBody:[UInt8];let nativeContains:(CGPoint)->Bool
        let nativeW:CGFloat;let normal:CGPoint;let along:CGPoint
    }
    enum Qualification:String {
        case explicitProtection, measuredClosedForeground, detectionGeometryUnqualified
        case unresolvedSourceEvidence, unresolvedInheritedProvenance
    }
    enum Verdict:String {case pass,reject,uncertain,notRun}
    struct NativeChecks {
        let semantic:()->Verdict;let foreign:()->Verdict;let ownership:()->Verdict
        let whole:()->Verdict;let dense:()->Verdict;let terminal:()->Verdict
    }
    struct PixelProof {
        let positive:Bool;let reason:String;let receipt:[String:Any]
    }
    struct Classified {
        let point:Point;let qualification:Qualification;let mustPreserve:Bool;let pixel:PixelProof
        func receipt()->[String:Any] {
            ["ordinal":point.ordinal,"sourceOrdinal":point.sourceOrdinal,"role":point.role.rawValue,
             "provenance":point.provenance,"point":[Double(point.position.x),Double(point.position.y)],
             "qualification":qualification.rawValue,"mustPreservePoint":mustPreserve,
             "actualPixelEvidence":pixel.receipt,"reason":pixel.reason,
             "ownershipClaimed":false,"unqualifiedDoesNotMeanBackgroundOrErasureRights":true]
        }
    }
    struct Observation {
        let actualOld:[CGPoint];let points:[Classified];let explicitCapsComplete:Bool
        /// Call ALL original checks for EVERY geometrically valid candidate, even
        /// if a qualified point veto is already known. Unknown geometry is deferred.
        func preflight(proposed q:[CGPoint],checks:NativeChecks)->[String:Any] {
            guard NativeOCRPointObligation401.valid(q) else{return ["status":"invalid-proposal","admissionGranted":false,"nativeChecksInvoked":false]}
            let lost=points.filter{!NativeOCRPointObligation401.contains(q,$0.point.position)}
            let mandatoryLost=lost.filter{$0.mustPreserve},deferred=lost.filter{!$0.mustPreserve}
            // Deliberate sequential, unconditional evaluation: no short-circuit AND.
            let semantic=checks.semantic(),foreign=checks.foreign(),ownership=checks.ownership()
            let whole=checks.whole(),dense=checks.dense(),terminal=checks.terminal()
            let gates:[String:Verdict]=["semantic":semantic,"foreign":foreign,"ownership":ownership,"whole":whole,"dense":dense,"terminal":terminal]
            let reject=gates.filter{$0.value == .reject}.keys.sorted()
            let uncertain=gates.filter{$0.value == .uncertain || $0.value == .notRun}.keys.sorted()
            var hard=mandatoryLost.map{"lost-"+$0.qualification.rawValue+"-point-"+String($0.point.ordinal)}
            hard += reject.map{"original-native-"+$0+"-reject"}
            return ["status":"typed-point-obligation-preflight401","actualOld":actualOld.map{[Double($0.x),Double($0.y)]},
                "actualOldEnclosed":actualOld.allSatisfy{NativeOCRPointObligation401.contains(q,$0)},"nativeChecksInvoked":true,
                "nativeGateResults":gates.mapValues{$0.rawValue},"hardRejections":hard,
                "unresolvedNativeChecks":uncertain,"explicitCapListsComplete":explicitCapsComplete,
                "lostProtectedPoints":mandatoryLost.map{$0.receipt()},"deferredGeometricPoints":deferred.map{$0.receipt()},
                "legacyUntypedPointGateWouldReject":!lost.isEmpty,
                "eligibleForParentDecision":hard.isEmpty && uncertain.isEmpty && explicitCapsComplete,
                "unknownGeometrySilentlyUsedAsForegroundVeto":false,"allPointRecords":points.map{$0.receipt()},
                "ownershipChanged":false,"erasureAuthority":"none","admissionGranted":false,
                "parentStillOwnsFinalAdmissionAndAssociation":true]
        }
    }
    struct Invalid:Error {let reason:String}
    static func contains(_ q:[CGPoint],_ p:CGPoint)->Bool {
        guard q.count==4,p.x.isFinite,p.y.isFinite else{return false}
        var pos=false,neg=false
        for i in 0..<4 {let a=q[i],b=q[(i+1)%4],v=(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
            pos = pos || v>1e-7;neg = neg || v < -1e-7};return !pos || !neg
    }
    static func valid(_ q:[CGPoint])->Bool {
        guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return false}
        let c=(0..<4).map{i -> CGFloat in let a=q[i],b=q[(i+1)%4],d=q[(i+2)%4];return (b.x-a.x)*(d.y-b.y)-(b.y-a.y)*(d.x-b.x)}
        return c.allSatisfy{$0>1e-8} || c.allSatisfy{$0 < -1e-8}
    }
    static func observe(actualOld:[CGPoint],points:[Point],sessions:[Int:SourceSession],explicitCapsComplete:Bool)throws->Observation {
        guard valid(actualOld),points.count<=262_144,sessions.count<=64,Set(points.map{$0.ordinal}).count==points.count,
            points.allSatisfy({$0.position.x.isFinite && $0.position.y.isFinite}),
            sessions.allSatisfy({$0.key==$0.value.binding.sourceOrdinal && $0.value.binding.actualOld==actualOld}) else{throw Invalid(reason:"invalid-typed-source-bundle")}
        let classified=points.map { p -> Classified in
            let proofs:[PixelProof]
            if let source=sessions[p.sourceOrdinal] {proofs=[source.classify(p.position)]}
            else if p.sourceOrdinal<0 {proofs=sessions.keys.sorted().map{sessions[$0]!.classify(p.position)}}
            else{proofs=[]}
            let pixel=proofs.first(where:{$0.positive}) ?? proofs.first(where:{$0.receipt["sourcePixelObserved"] as? Bool==true}) ?? PixelProof(positive:false,reason:"source-session-unavailable",receipt:["sourcePixelObserved":false])
            if p.role == .explicitEndpointCap || p.role == .explicitProtectedMark {
                return .init(point:p,qualification:.explicitProtection,mustPreserve:true,pixel:pixel)
            }
            if pixel.positive{return .init(point:p,qualification:.measuredClosedForeground,mustPreserve:true,pixel:pixel)}
            let q:Qualification
            if p.role == .inheritedUntypedSupport || p.role == .originalOwnedUntypedSupport {q = .unresolvedInheritedProvenance}
            else if pixel.receipt["sourcePixelObserved"] as? Bool==true {q = .detectionGeometryUnqualified}
            else{q = .unresolvedSourceEvidence}
            return .init(point:p,qualification:q,mustPreserve:false,pixel:pixel)
        }
        return .init(actualOld:actualOld,points:classified,explicitCapsComplete:explicitCapsComplete)
    }
    final class SourceSession {
        let binding:Binding;let evidence:Evidence
        private var cache:[Int:PixelProof]=[:],colours:[SIMD3<Int>]=[]
        private var probes=0;private(set) var budgetExhausted=false
        init(binding:Binding,evidence e:Evidence)throws {
            let r=e.rgba
            guard NativeOCRPointObligation401.valid(binding.actualOld),binding.actualNativeFullFootprintVerified,
                r.width>2,r.height>2,r.width<=600_000/r.height,r.stride>=r.width*4,r.height<=Int.max/r.stride,
                r.bytes.count==r.height*r.stride,e.rootGGBody.count==r.width*r.height,e.rootGGBody.contains(where:{$0 != 0}),
                e.nativeW.isFinite,e.nativeW>0,e.nativeW<100_000,
                abs(hypot(e.normal.x,e.normal.y)-1)<1e-6,abs(hypot(e.along.x,e.along.y)-1)<1e-6,
                abs(e.normal.x*e.along.x+e.normal.y*e.along.y)<1e-6,
                Self.digest(r.bytes)==binding.rgbaSHA256,Self.digest(e.rootGGBody)==binding.rootGGBodySHA256,
                binding.nativeFullFootprintSHA256.count==64 else{throw Invalid(reason:"unbound-actual-source-GG-native-evidence")}
            self.binding=binding;self.evidence=e
            var counts:[Int]=[]
            for i in e.rootGGBody.indices where e.rootGGBody[i] != 0 && e.nativeContains(world(i)) && opaque(i) {
                let c=rgb(i)
                if let k=colours.firstIndex(where:{distance($0,c)<=24}){counts[k] += 1}
                else if colours.count<16{colours.append(c);counts.append(1)}
            }
            colours=colours.indices.filter{counts[$0]>=2}.map{colours[$0]}
        }
        private static func digest(_ bytes:[UInt8])->String {SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()}
        private func world(_ i:Int)->CGPoint {let r=evidence.rgba;return CGPoint(x:r.origin.x+CGFloat(i%r.width)+0.5,y:r.origin.y+CGFloat(i/r.width)+0.5)}
        private func opaque(_ i:Int)->Bool {let r=evidence.rgba;return r.bytes[(i/r.width)*r.stride+(i%r.width)*4+3]==255}
        private func rgb(_ i:Int)->SIMD3<Int> {let r=evidence.rgba,k=(i/r.width)*r.stride+(i%r.width)*4;return .init(Int(r.bytes[k]),Int(r.bytes[k+1]),Int(r.bytes[k+2]))}
        private func distance(_ a:SIMD3<Int>,_ b:SIMD3<Int>)->Int {max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z))}
        private func sample(_ p:CGPoint)->Int? {
            probes += 1;if probes>8_000_000{budgetExhausted=true;return nil}
            let r=evidence.rgba,x=floor(p.x-r.origin.x),y=floor(p.y-r.origin.y)
            guard x>=0,x<CGFloat(r.width),y>=0,y<CGFloat(r.height) else{return nil}
            let i=Int(y)*r.width+Int(x);return opaque(i) ? i:nil
        }
        private func witness(_ i:Int)->[String:Any] {let p=world(i),c=rgb(i);return ["pixelIndex":i,"center":[Double(p.x),Double(p.y)],"RGB":[c.x,c.y,c.z],"rootGG":evidence.rootGGBody[i] != 0,"nativeCellAtCenter":evidence.nativeContains(p)]}
        /// A literal same-fill/AA run ending in positively stable contrasting
        /// exterior. Never labels a stable white field as an invented outline.
        private func closedFill(_ i:Int,_ n:CGPoint)->[Int]? {
            let start=world(i),initial=rgb(i),steps=min(1024,Int(ceil(evidence.nativeW*1.5))+4)
            var seen=[i],last=i
            for step in 1...steps {
                guard let j=sample(CGPoint(x:start.x+n.x*CGFloat(step),y:start.y+n.y*CGFloat(step))) else{return nil}
                if j==last{continue};last=j;seen.append(j)
                let c=rgb(j)
                if distance(initial,c)<=28{continue}
                guard distance(initial,c)>=40 else{continue}
                var outside=[j]
                for k in 1...3 {
                    guard let z=sample(CGPoint(x:world(j).x+n.x*CGFloat(k),y:world(j).y+n.y*CGFloat(k))),distance(rgb(z),c)<=12 else{return nil}
                    outside.append(z)
                }
                // Every intermediate AA value is between actual fill/exterior.
                for z in seen.dropFirst().dropLast() {let value=rgb(z)
                    for channel in 0..<3 where value[channel]<min(initial[channel],c[channel])-16 || value[channel]>max(initial[channel],c[channel])+16{return nil}}
                return seen+Array(outside.dropFirst())
            };return nil
        }
        private func rim(_ i:Int,_ n:CGPoint)->[String:Any]? {
            let p=world(i),c=rgb(i),limit=min(128,max(3,Int(ceil(evidence.nativeW*0.65))))
            var path=[i],last=i,transition=0,anchor:Int?=nil
            for step in 1...limit {
                guard let j=sample(CGPoint(x:p.x-n.x*CGFloat(step),y:p.y-n.y*CGFloat(step))) else{return nil}
                if j==last{continue};last=j;path.append(j)
                if distance(c,rgb(j))<=24 && transition==0{continue}
                transition += 1
                if evidence.rootGGBody[j] != 0,distance(c,rgb(j))>=40,
                    (evidence.nativeContains(world(j)) || colours.contains(where:{distance($0,rgb(j))<=24})){anchor=j;break}
                if transition>max(2,Int(ceil(evidence.nativeW*0.1))){return nil}
            }
            guard let fill=anchor else{return nil}
            let fc=rgb(fill)
            for z in path {let v=rgb(z);for k in 0..<3 where v[k]<min(c[k],fc[k])-16 || v[k]>max(c[k],fc[k])+16{return nil}}
            guard let outside=closedFill(i,n) else{return nil}
            return ["actualRootFillAnchor":witness(fill),"actualFillToRimPixelPath":path.reversed().map(witness),
                "actualRimToStableExterior":outside.map(witness),"ownershipClaimed":false]
        }
        func classify(_ point:CGPoint)->PixelProof {
            let r=evidence.rgba,x=floor(point.x-r.origin.x),y=floor(point.y-r.origin.y)
            if x.isFinite,y.isFinite,x>=0,x<CGFloat(r.width),y>=0,y<CGFloat(r.height),let proof=cache[Int(y)*r.width+Int(x)]{return proof}
            guard let i=sample(point) else{return .init(positive:false,reason:budgetExhausted ? "source-probe-budget-unresolved":"point-outside-observed-opaque-RGBA",receipt:["sourcePixelObserved":false])}
            if let p=cache[i]{return p}
            let e=evidence,p=world(i),c=rgb(i)
            var local:[[String:Any]]=[]
            for dy in -1...1 {for dx in -1...1 {if let j=sample(CGPoint(x:p.x+CGFloat(dx),y:p.y+CGFloat(dy))){local.append(witness(j))}}}
            var record:[String:Any]=["sourcePixelObserved":true,"actualPixel":witness(i),"neighborhood3x3":local,
                "observedSourceOrdinal":binding.sourceOrdinal,"sourceSHA256":binding.sourceSHA256,"RGBA_SHA256":binding.rgbaSHA256,"rootGGBodySHA256":binding.rootGGBodySHA256,
                "nativeFullFootprintSHA256":binding.nativeFullFootprintSHA256,"paletteAloneUsed":false,
                "geometryUsedAsForeground":false,"certifiedBackground":false]
            let sourceSeed=e.rootGGBody[i] != 0 || (e.nativeContains(p) && colours.contains(where:{distance($0,c)<=24}))
            if sourceSeed {
                for axis in [e.normal,e.along] {
                    if let low=closedFill(i,CGPoint(x:-axis.x,y:-axis.y)),let high=closedFill(i,axis) {
                        record["positiveClosedFillLow"]=low.map(witness);record["positiveClosedFillHigh"]=high.map(witness)
                        let proof=PixelProof(positive:true,reason:"actual-root-GG-or-native-contrast-seed-with-two-sided-closed-fill",receipt:record)
                        cache[i]=proof;return proof
                    }
                }
            }
            let n=e.normal,a=e.along
            let raw=[n,CGPoint(x:-n.x,y:-n.y),a,CGPoint(x:-a.x,y:-a.y),
                     CGPoint(x:n.x+a.x,y:n.y+a.y),CGPoint(x:n.x-a.x,y:n.y-a.y),
                     CGPoint(x:-n.x+a.x,y:-n.y+a.y),CGPoint(x:-n.x-a.x,y:-n.y-a.y)]
            var rims:[[String:Any]]=[]
            for v in raw {let len=hypot(v.x,v.y);if let proof=rim(i,CGPoint(x:v.x/len,y:v.y/len)){rims.append(proof)};if rims.count==2{break}}
            record["positiveLiteralRimRelations"]=rims;record["sourceProbeBudgetExhausted"]=budgetExhausted
            let positive=rims.count>=2
            let proof=PixelProof(positive:positive,reason:positive ? "actual-root-fill-to-rim-to-stable-exterior-repeated":"no-positive-closed-source-foreground-proof-geometry-deferred",receipt:record)
            cache[i]=proof;return proof
        }
        func summary()->[String:Any] {["cachedActualPixelClassifications":cache.count,"sourceProbeQueries":probes,"budgetExhausted":budgetExhausted,"RGBAArea":evidence.rgba.width*evidence.rgba.height,"ownershipChanged":false]}
    }
}
