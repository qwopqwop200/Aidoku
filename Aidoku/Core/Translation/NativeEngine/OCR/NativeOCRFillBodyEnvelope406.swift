import Foundation
import CoreGraphics

/// Geometry from 405's actually sampled positive fill, NEVER a second classifier.
/// A point envelope is a candidate, not completeness, ownership or admission.
enum NativeOCRFillBodyEnvelope406 {
    typealias K = NativeOCRSharedBoundary396
    typealias R = SourceFillRimRole405
    private struct Point {
        let index:Int
        let witness:R.PixelWitness
        let component:Int
        let row:Int
        let role:R.Role
        let n:CGFloat
        let a:CGFloat
    }
    private struct Variant {
        let name:String
        let bounds:[CGFloat] // normal low/high, along low/high
        let measured:[CGFloat]
        let indices:[Int] // exact observed pixel extrema, never interpolated ink
        let provenance:[String]
        let includesObservedRim:Bool
        let padding:CGFloat
    }
    static func generate(actualOld:[CGPoint], basis:K.Basis, nativeW:CGFloat,
                         evidence:K.Evidence) -> K.Output {
        let observed=R.assess(evidence:evidence,basis:basis,nativeW:nativeW)
        return generate(actualOld:actualOld,basis:basis,nativeW:nativeW,
                        evidence:evidence,roleObservation:observed)
    }
    /// Allows the parent to reuse its actual405 observation without rerunning it.
    /// The parent must pass the output of assess on this SAME captured evidence.
    /// Actual point witnesses, pixel roles, RGB and positive DB/RF hits are rebound
    /// below; no external observation is trusted as a completeness declaration.
    static func generate(actualOld old:[CGPoint], basis f:K.Basis, nativeW mw:CGFloat,
                         evidence e:K.Evidence, roleObservation observed:R.Output) -> K.Output {
        func none(_ status:String) -> K.Output {
            .init(proposals:[],receipt:["family":"fill-body-envelope406","status":status,
                "sourceOnly":true,"GTRead":false,"sourceCompletenessClaimed":false,"admissionGranted":false])
        }
        let r=e.rgba,w=r.width,h=r.height
        guard w>2,h>2,w<=600_000/h,w<=Int.max/4,r.bytesPerRow>=w*4,
              h<=Int.max/r.bytesPerRow,r.bytes.count==h*r.bytesPerRow,e.body.count==w*h,
              old.count==4,old.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              mw.isFinite,mw>0,mw<100_000,
              [r.origin,f.origin,f.normal,f.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              abs(hypot(f.normal.x,f.normal.y)-1)<1e-6,
              abs(hypot(f.along.x,f.along.y)-1)<1e-6,
              abs(f.normal.x*f.along.x+f.normal.y*f.along.y)<1e-6,
              e.detectors.count<=64,e.rf.count<=160,e.nativeCellCenters.count<=600_000,
              e.nativeCellCenters.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              e.rf.allSatisfy({$0.bounds.count==4 && $0.bounds.allSatisfy(\.isFinite) && $0.confidence.isFinite}),
              observed.roles.count==w*h,observed.rows.count<=4096,observed.components.count<=20_000,
              observed.receipt["RGBAWidth"] as? Int == w,observed.receipt["RGBAHeight"] as? Int == h,
              observed.receipt["family"] as? String == "source-fill-rim-role405",
              observed.receipt["status"] as? String == "source-role-observations-only",
              observed.receipt["wholeComponentRolePropagation"] as? Bool == false else {return none("invalid-or-missing-same-capture-role-observation")}
        func turns(_ q:[CGPoint]) -> [CGFloat] {(0..<4).map {i in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }}
        let oldTurns=turns(old)
        guard oldTurns.allSatisfy({$0>1e-8}) || oldTurns.allSatisfy({$0 < -1e-8}) else{return none("invalid-actual-prior-convexity")}
        func world(_ i:Int) -> CGPoint {CGPoint(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5)}
        func project(_ p:CGPoint) -> CGPoint {
            let x=p.x-f.origin.x,y=p.y-f.origin.y
            return CGPoint(x:x*f.normal.x+y*f.normal.y,y:x*f.along.x+y*f.along.y)
        }
        let nr=(abs(f.normal.x)+abs(f.normal.y))*0.5,ar=(abs(f.along.x)+abs(f.along.y))*0.5
        var components:[Int:R.ComponentRole]=[:]
        for c in observed.components {
            guard components[c.componentID]==nil,c.sampledPixelRolesOnly else {return none("ambiguous-or-propagated-component-role")}
            components[c.componentID]=c
        }
        var fill:[Int:Point]=[:],rim:[Int:Point]=[:],associationQueries=0,totalWitnesses=0
        for (rowIndex,row) in observed.rows.enumerated() {
            guard row.seed>=0,row.seed<w*h,row.along.isFinite,
                  abs(project(world(row.seed)).y-row.along)<=1e-6,
                  row.low.fill.contains(row.seed),row.high.fill.contains(row.seed),
                  (row.low.path+row.high.path).allSatisfy({$0>=0 && $0<w*h && abs(project(world($0)).y-row.along)<=ar+1e-6}) else {
                return none("role-observation-not-bound-to-actual-source-basis-rows")
            }
            guard let component=components[row.componentID],component.closedAtCapture,
                  component.directlyRooted || component.connectedRootComponentID != nil else {continue}
            let positiveComponent=component.role == .fill || component.role == .unoutlinedPositive
            guard positiveComponent else {continue}
            let rowFill=Set(row.low.fill+row.high.fill)
            let rowRim=Set(row.low.rimOrAA+row.high.rimOrAA)
            for v in row.witnesses {
                totalWitnesses += 1
                guard totalWitnesses<=2_000_000 else{return none("observation-witness-budget-exceeded")}
                let i=v.localIndex
                guard i>=0,i<w*h else{return none("role-witness-index-outside-actual-capture")}
                let role=observed.role(atActualLocalPixelIndex:i)
                let isFill=(role == .fill || role == .unoutlinedPositive) && rowFill.contains(i)
                let isRim=role == .rimOrAA && rowRim.contains(i)
                guard isFill || isRim else {continue}
                let p=world(i),offset=(i/w)*r.bytesPerRow+(i%w)*4
                let actualRGB=[Int(r.bytes[offset]),Int(r.bytes[offset+1]),Int(r.bytes[offset+2])]
                guard v.center==p,v.rgb==actualRGB,r.bytes[offset+3]==255,
                      v.rootGG==(e.body[i] != 0),v.actualNativeRootCell==e.privateAt(p) else{return none("role-point-not-bound-to-original-RGBA-GG-native-membership")}
                for j in v.detectorArrayPositions {
                    associationQueries += 1
                    guard associationQueries<=2_000_000,j>=0,j<e.detectors.count,e.detectors[j].cells.contains(p) else{return none("unbound-positive-original-detector-RLE-cue")}
                }
                for j in v.nativeRootDetectorArrayPositions {
                    guard v.detectorArrayPositions.contains(j),e.detectors[j].nativeRoot else{return none("unbound-native-root-detector-subset")}
                }
                for j in v.rfArrayPositions {
                    associationQueries += 1
                    guard associationQueries<=2_000_000,j>=0,j<e.rf.count,e.rf[j].confidence>=0.4,e.rf[j].contains(p) else{return none("unbound-positive-RF-cue")}
                }
                let q=project(p),point=Point(index:i,witness:v,component:row.componentID,row:rowIndex,role:role,n:q.x,a:q.y)
                if isFill {if fill[i]==nil {fill[i]=point}}
                else {if rim[i]==nil {rim[i]=point}}
            }
        }
        // The only indices considered foreground here were individually observed
        // as positive by405 AND exported with a real matching original pixel.
        let positiveIndices=Set(observed.roles.indices.filter{observed.isPositiveFill(atActualLocalPixelIndex:$0)})
        guard positiveIndices==Set(fill.keys) else{return none("positive-role-pixels-lack-exported-actual-point-provenance")}
        let points=fill.keys.sorted().map{fill[$0]!}
        guard points.count>=4,Set(points.map(\.row)).count>=3 else{return none("insufficient-measured-positive-fill-pixels-and-rows")}
        func envelope(_ pts:[Point]) -> ([CGFloat],[Int]) {
            let n0=pts.indices.min{pts[$0].n<pts[$1].n}!,n1=pts.indices.max{pts[$0].n<pts[$1].n}!
            let a0=pts.indices.min{pts[$0].a<pts[$1].a}!,a1=pts.indices.max{pts[$0].a<pts[$1].a}!
            return ([pts[n0].n-nr,pts[n1].n+nr,pts[a0].a-ar,pts[a1].a+ar],
                    [pts[n0].index,pts[n1].index,pts[a0].index,pts[a1].index])
        }
        let (bounds,extrema)=envelope(points),oldProjected=old.map(project)
        let oldBounds=[oldProjected.map(\.x).min()!,oldProjected.map(\.x).max()!,oldProjected.map(\.y).min()!,oldProjected.map(\.y).max()!]
        let union=[min(bounds[0],oldBounds[0]),max(bounds[1],oldBounds[1]),min(bounds[2],oldBounds[2]),max(bounds[3],oldBounds[3])]
        func variant(_ name:String,_ b:[CGFloat],_ provenance:[String],_ padding:CGFloat=0) -> Variant {
            .init(name:name,bounds:b,measured:bounds,indices:extrema,provenance:provenance,includesObservedRim:false,padding:padding)
        }
        let exact=[String](repeating:"measured-positive-fill-pixel-square",count:4)
        var variants=[variant("measured-fill",bounds,exact),
            variant("prior-preserving-fill-expansion",union,(0..<4).map{union[$0]==bounds[$0] ? exact[$0]:"actual-old-source-plane-envelope"}),
            variant("normal-fill-old-along-union",[bounds[0],bounds[1],union[2],union[3]],[exact[0],exact[1],"actual-old-or-measured-along-envelope","actual-old-or-measured-along-envelope"]),
            variant("along-fill-old-normal-union",[union[0],union[1],bounds[2],bounds[3]],["actual-old-or-measured-normal-envelope","actual-old-or-measured-normal-envelope",exact[2],exact[3]])]
        for fraction in [CGFloat(0.025),0.05,0.10] {
            let pad=mw*fraction
            variants.append(variant("fill-margin-\(Int(fraction*1000))",[bounds[0]-pad,bounds[1]+pad,bounds[2]-pad,bounds[3]+pad],
                [String](repeating:"explicit-nativeW-relative-margin-not-measured-foreground",count:4),pad))
        }
        if !rim.isEmpty {
            let all=points+rim.keys.sorted().map{rim[$0]!},(b,indices)=envelope(all)
            variants.append(.init(name:"fill-and-observed-rim",bounds:b,measured:b,indices:indices,
                provenance:[String](repeating:"measured-positive-fill-or-observed-rim-square",count:4),includesObservedRim:true,padding:0))
        }
        func pointReceipt(_ i:Int) -> [String:Any] {
            let p=fill[i] ?? rim[i]!,v=p.witness
            return ["actualLocalPixelIndex":i,"center":[Double(v.center.x),Double(v.center.y)],"RGB":v.rgb,
                "role405":Int(p.role.rawValue),"role405Name":p.role == .fill ? "fill":p.role == .unoutlinedPositive ? "unoutlinedPositive":"rimOrAA",
                "actual405RowIndex":p.row,"actual405ComponentID":p.component,"rootGGBody":v.rootGG,
                "actualNativeRootCell":v.actualNativeRootCell,"originalDetectorArrayPositions":v.detectorArrayPositions,
                "originalNativeRootDetectorArrayPositions":v.nativeRootDetectorArrayPositions,"actualRFArrayPositions":v.rfArrayPositions,
                "sourceProjection":[Double(p.n),Double(p.a)],"ownershipClaimed":false]
        }
        func runs(_ indices:[Int]) -> [[Int]] {
            var result:[[Int]]=[]
            for i in indices.sorted() {if let last=result.last,last[0]==i/w,last[1]+last[2]==i%w {result[result.count-1][2] += 1}
                else {result.append([i/w,i%w,1])}}
            return result
        }
        var proposals:[K.Proposal]=[],seen=Set<String>(),outsideCapture=0
        let gg=e.body.indices.filter{e.body[$0] != 0}
        for v in variants {
            let b=v.bounds
            guard b.allSatisfy(\.isFinite),b[1]>b[0],b[3]>b[2] else {continue}
            func restore(_ n:CGFloat,_ a:CGFloat) -> CGPoint {CGPoint(x:f.origin.x+n*f.normal.x+a*f.along.x,y:f.origin.y+n*f.normal.y+a*f.along.y)}
            let rectangle=[restore(b[0],b[2]),restore(b[1],b[2]),restore(b[1],b[3]),restore(b[0],b[3])]
            guard rectangle.allSatisfy({$0.x>=r.origin.x && $0.x<=r.origin.x+CGFloat(w) && $0.y>=r.origin.y && $0.y<=r.origin.y+CGFloat(h)}) else {outsideCapture += 1;continue}
            var q=rectangle,cost=CGFloat.infinity
            for reversed in [false,true] {
                let z=reversed ? Array(rectangle.reversed()):rectangle
                for offset in 0..<4 {
                    let candidate=(0..<4).map{z[($0+offset)%4]}
                    let c=(0..<4).reduce(CGFloat(0)) { sum,i in
                        let dx=candidate[i].x-old[i].x,dy=candidate[i].y-old[i].y
                        return sum+dx*dx+dy*dy
                    }
                    if c<cost {cost=c;q=candidate}
                }
            }
            let key=q.map{String(format:"%.8f,%.8f",Double($0.x),Double($0.y))}.joined(separator:";")
            guard seen.insert(key).inserted,proposals.count<8 else {continue}
            let bodyLoss=gg.filter{K.contains(old,world($0)) && !K.contains(q,world($0))}
            let unknownLoss=bodyLoss.filter{observed.role(atActualLocalPixelIndex:$0) == .unknown}
            let nativeLoss=e.nativeCellCenters.filter{K.contains(old,$0) && !K.contains(q,$0)}
            let rimLoss=rim.keys.filter{K.contains(old,world($0)) && !K.contains(q,world($0))}
            let conflictLoss=bodyLoss.filter{observed.role(atActualLocalPixelIndex:$0) == .conflicting}
            let newFill=points.filter{!K.contains(old,$0.witness.center) && K.contains(q,$0.witness.center)}
            let rec:[String:Any]=["family":"fill-body-envelope406","variant":v.name,"actualOld":old.map{[Double($0.x),Double($0.y)]},
                "actualOldEnclosed":old.allSatisfy{K.contains(q,$0)},"sourceBasisUnchanged":true,
                "sourceBasis":["origin":[Double(f.origin.x),Double(f.origin.y)],"normal":[Double(f.normal.x),Double(f.normal.y)],"along":[Double(f.along.x),Double(f.along.y)]],
                "sourcePlaneOrder":["normalLow","normalHigh","alongLow","alongHigh"],
                "proposedSourcePlanes":b.map(Double.init),"measuredSupportSourcePlanes":v.measured.map(Double.init),
                "planeProvenance":v.provenance,"edgeActualPixelSquareSupport":v.indices.map(pointReceipt),
                "nativeWRelativeMargin":Double(v.padding/mw),"marginIsObservedForeground":false,
                "includesOnlyObservedRimInOptionalEnvelope":v.includesObservedRim,
                "observedPositiveFillPixels":points.count,"observedPositiveFillPixelSquaresEnclosed":true,
                "newOutsideOldObservedFillPixels":newFill.count,"newObservedFillWitnesses":newFill.prefix(4).map{pointReceipt($0.index)},
                "newlyExcludedOriginalGGBodyPixels":bodyLoss.count,"newlyExcludedUnknownRoleGGBodyPixels":unknownLoss.count,
                "unknownGGLossWitnessIndices":Array(unknownLoss.prefix(8)),"newlyExcludedConflictingRoleGGBodyPixels":conflictLoss.count,
                "newlyExcludedObservedRimPixelCenters":rimLoss.count,"newlyExcludedActualNativeCellCenters":nativeLoss.count,
                "nativeCellsAreForeground":false,"GGBodyLossIsAutomaticallyFillLoss":false,
                "knownRimLossAuthorizesErasure":false,"nativeCellLossWitnesses":nativeLoss.prefix(4).map{[Double($0.x),Double($0.y)]},
                "GGBodyLossWitnessIndices":Array(bodyLoss.prefix(8)),"unsampledPixelsAssignedFill":false,
                "wholeCCFilled":false,"hullOrQuadRasterizedAsInk":false,"geometryIsOwnership":false,
                "allSourceFillOrTerminalExtentObserved":false,"sourceCompletenessClaimed":false,
                "foreignRubyAssociationResolved":false,"nativeAdmissionSuiteRun":false,"admissionGranted":false]
            var obligations=["actual-native-whole-dense-terminal-GG-typed401-404-and-semantic-gates-required",
                "observed-fill-envelope-is-not-all-glyph-completeness","unsampled-along-head-tail-and-detached-support-unresolved",
                "fill-rim-role-observation-does-not-prove-target-ownership","new-peer-foreign-ruby-acquisition-check-required","no-erasure-authority"]
            if !unknownLoss.isEmpty || !conflictLoss.isEmpty {obligations.append("unknown-or-conflicting-original-GG-loss-must-be-resolved")}
            if !bodyLoss.isEmpty || !nativeLoss.isEmpty {obligations.append("original-source-and-native-support-loss-remains-a-real-observation")}
            if v.padding>0 {obligations.append("nativeW-margin-is-unmeasured-geometry-only")}
            proposals.append(.init(suffix:"fill-envelope406-"+v.name,polygon:q,receipt:rec,obligations:obligations))
        }
        return .init(proposals:proposals,receipt:["family":"fill-body-envelope406","status":proposals.isEmpty ? "no-in-capture-observed-fill-envelope":"observed-fill-geometry-only",
            "proposalCount":proposals.count,"maximumProposals":8,"role405Observation":observed.receipt,
            "observedPositiveFillActualRuns":runs(Array(fill.keys)),"observedRimActualRuns":runs(Array(rim.keys)),
            "positivePointWitnessCount":fill.count,"observedRimPointWitnessCount":rim.count,
            "positiveFillSourceRows":Set(points.map(\.row)).count,"positiveFillSourceComponents":Set(points.map(\.component)).count,
            "sourceAssociationRebindingQueries":associationQueries,"rejectedOutOfCaptureGeometry":outsideCapture,
            "unsampledPixelsAssignedFill":false,"foregroundReclassifiedBy406":false,
            "sourceCompletenessClaimed":false,"ownershipClaimed":false,"GTRead":false,"admissionGranted":false])
    }
}
