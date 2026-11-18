import Foundation
import CoreGraphics
import CoreFoundation

// Default-OFF typed source menu selector. Global bounds MUST come from frozen
// all830 actual-native menu floor evaluation; no per-case/ID/key lookup is accepted.
enum SourceBoundary400Policy {
    enum Field: String { case areaRatio, widthRatio, alongRatio, priorAspect
        case selectedComponents, selectedActualPixels, privateAnchorFraction, ggBodyFraction
        case nativeAnchoredPixelFraction, rootRFSupportedPixelFraction, selectedClippedFraction
        case nativeCellLoss, nativeCellLossFraction, sourceGGBodyLoss
        case planeExpansionSumSourceW, planeContractionSumSourceW, planeChangeMaxSourceW
        case changedEdges, rootDetectorCellAgreement, rootRFMatches, otherDetectorEvidenceCount
        case contourContactAdded, sourceScore, sourceAxisResidual
        case componentAlongMaxSourceW, componentWidthMaxSourceW, centerShift
        case source00, source01, source02, source03, source04, source05, source06, source07, source08, source09, source10, source11, source12, source13, source14, source15, source16, source17, source18, source19, source20, source21
    }
    struct Features { let values: [Field:Double] }
    struct Bound { let field:Field; let minimum:Double?; let maximum:Double? }
    enum Rank { case minimumArea, maximumSourceCorroboration }
    struct Policy {
        let enabled:Bool
        let bounds:[Bound]
        let rank:Rank
        static let disabled = Policy(enabled:false,bounds:[],rank:.minimumArea)
        // Frozen full830 HYPOTHETICAL +5 candidate; caller must opt in only after
        // parent descriptor/selection parity and selected43 physical validation.
        static let frozenCandidateV1 = Policy(enabled:true,bounds:[
            Bound(field:.centerShift,minimum:nil,maximum:0.85),
            Bound(field:.source07,minimum:nil,maximum:0.2),
            Bound(field:.componentAlongMaxSourceW,minimum:nil,maximum:3),
            Bound(field:.sourceGGBodyLoss,minimum:nil,maximum:8),
            Bound(field:.planeContractionSumSourceW,minimum:0.5,maximum:nil),
            Bound(field:.changedEdges,minimum:nil,maximum:2)
        ],rank:.minimumArea)
    }
    struct NativeOffer {
        let rawOffer:[String:Any]
        let nativeAdmissionPassed:Bool
        let sourceHardRejections:[String]
        let originalRecord:[String:Any]
    }
    struct Choice { let nativeIndex:Int; let features:Features; let offer:NativeOffer
        let finalAdmissionGranted=false }
    static func number(_ v:Any?)->Double? {
        guard let n=v as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{return nil};return n.doubleValue
    }
    static func integer(_ v:Any?)->Int? {
        guard let d=number(v),d>=0,d<Double(Int.max),d.rounded(.towardZero)==d else{return nil};return Int(d)
    }
    static func points(_ v:Any?)->[CGPoint]? {
        guard let a=v as? [Any],a.count==4 else{return nil};var q:[CGPoint]=[]
        for v in a {
            if let p=v as? [Any],p.count==2,let x=number(p[0]),let y=number(p[1]) {q.append(.init(x:x,y:y))}
            else if let p=v as? [String:Any],let x=number(p["x"]),let y=number(p["y"]) {q.append(.init(x:x,y:y))}
            else{return nil}
        };return q
    }
    static func area(_ q:[CGPoint])->Double? {
        guard q.count==4 else{return nil};let o=q[0];var twice=0.0
        for i in 0..<4 {let j=(i+1)%4;twice+=Double(q[i].x-o.x)*Double(q[j].y-o.y)-Double(q[j].x-o.x)*Double(q[i].y-o.y)}
        let a=abs(twice)/2;return a.isFinite && a>0 ? a:nil
    }
    // Necessary structural source preflight only, no arbitrary quality threshold.
    // Observation/native footprint authenticity and captured-window validity remain
    // the existing live factory's job. This function performs no reads/acquisition.
    static func mayGenerate(actualPrior:[CGPoint],nativeW:Double)->Bool {
        nativeW.isFinite && nativeW>0 && actualPrior.count==4 &&
        actualPrior.allSatisfy{$0.x.isFinite && $0.y.isFinite} && area(actualPrior) != nil
    }
    // Cheap NECESSARY bound before400 observation work. Remaining5bounds require
    // actual generated source receipts; this gate grants no native admission.
    static func mayGenerateFrozenCandidateV1(actualPrior:[CGPoint],nativeW:Double,
                                               actualPrecoordSourcePrefix:[Double])->Bool {
        guard mayGenerate(actualPrior:actualPrior,nativeW:nativeW),
              actualPrecoordSourcePrefix.count>7,
              actualPrecoordSourcePrefix[7].isFinite else{return false}
        return actualPrecoordSourcePrefix[7]<=0.2
    }
    static func describe(rawOffer:[String:Any],actualPrior:[CGPoint],nativeW:Double,
                         factoryReceipt:[String:Any],sourcePrefix:[Double],sourceScore:Double)->Features? {
        guard mayGenerate(actualPrior:actualPrior,nativeW:nativeW),sourceScore.isFinite,
              let r=rawOffer["sourceReceipt"] as? [String:Any],
              points(r["actualCurrentPrior"])==actualPrior,let q=points(rawOffer["polygon"]),
              let pa=area(actualPrior),let qa=area(q),
              let obs=factoryReceipt["sourceObservation"] as? [String:Any],
              let components=obs["sourceSupportComponents"] as? [[String:Any]],
              let ids=r["sourceSupportComponentIDs"] as? [Int],
              let shifts=r["signedEdgePlaneChanges"] as? [Double],shifts.count==4,
              shifts.allSatisfy({$0.isFinite}) else{return nil}
        // Component IDs are an existing source-association JOIN, never a policy key.
        var index:[Int:[String:Any]]=[:]
        for c in components {guard let id=integer(c["componentID"]),index[id]==nil else{return nil};index[id]=c}
        var pixels=0.0,anchors=0.0,body=0.0,anchoredPixels=0.0,rfPixels=0.0,clipped=0.0
        var componentAlong=0.0,componentWidth=0.0
        let rootRF=Set(r["rootRFTextQueries"] as? [Int] ?? [])
        for id in ids {
            guard let c=index[id],let px=integer(c["actualPixelCount"]),
                  let ap=integer(c["actualRootPrivateBodyAnchors"]),let bp=integer(c["originalGGBodyPixels"]) else{return nil}
            pixels+=Double(px);anchors+=Double(ap);body+=Double(bp)
            if let bounds=c["projectedActualCellBounds"] as? [Double],bounds.count==4,bounds.allSatisfy({$0.isFinite}) {
                componentWidth=max(componentWidth,(bounds[2]-bounds[0])/nativeW)
                componentAlong=max(componentAlong,(bounds[3]-bounds[1])/nativeW)
            }
            if ap>0 {anchoredPixels+=Double(px)}
            if !rootRF.intersection(c["RFTextQueryIDs"] as? [Int] ?? []).isEmpty {rfPixels+=Double(px)}
            if c["originalRGBCCClippedAtCapture"] as? Bool == true {clipped+=1}
        }
        let dx=Double(actualPrior[1].x-actualPrior[0].x),dy=Double(actualPrior[1].y-actualPrior[0].y),length=(dx*dx+dy*dy).squareRoot()
        guard length>0 else{return nil};let nx=dx/length,ny=dy/length,ax = -ny,ay=nx
        func span(_ p:[CGPoint],_ x:Double,_ y:Double)->Double {let v=p.map{Double($0.x)*x+Double($0.y)*y};return v.max()!-v.min()!}
        let pw=span(actualPrior,nx,ny),pl=span(actualPrior,ax,ay);guard pw>0,pl>0 else{return nil}
        let oldX=actualPrior.map{Double($0.x)}.reduce(0,+)/4,oldY=actualPrior.map{Double($0.y)}.reduce(0,+)/4
        let newX=q.map{Double($0.x)}.reduce(0,+)/4,newY=q.map{Double($0.y)}.reduce(0,+)/4
        let shift=((newX-oldX)*(newX-oldX)+(newY-oldY)*(newY-oldY)).squareRoot()/nativeW
        guard let cellLoss=number(r["newlyExcludedActualNativeCellCenters"]),let bodyLoss=number(r["newlyExcludedOriginalGGBodyPixels"]),let cells=number(r["actualNativeCellCenterCount"]),let bits=integer(r["edgeBits"]) else{return nil}
        var v:[Field:Double]=[.areaRatio:qa/pa,.widthRatio:span(q,nx,ny)/pw,.alongRatio:span(q,ax,ay)/pl,.priorAspect:pl/pw,
          .selectedComponents:Double(ids.count),.selectedActualPixels:pixels,.privateAnchorFraction:anchors/max(1,pixels),.ggBodyFraction:body/max(1,pixels),
          .nativeAnchoredPixelFraction:anchoredPixels/max(1,pixels),.rootRFSupportedPixelFraction:rfPixels/max(1,pixels),.selectedClippedFraction:clipped/max(1,Double(ids.count)),
          .nativeCellLoss:cellLoss,.nativeCellLossFraction:cellLoss/max(1,cells),.sourceGGBodyLoss:bodyLoss,
          .planeExpansionSumSourceW:shifts.map{max(0,$0)}.reduce(0,+)/nativeW,.planeContractionSumSourceW:shifts.map{max(0,-$0)}.reduce(0,+)/nativeW,.planeChangeMaxSourceW:shifts.map{abs($0)}.max()!/nativeW,
          .changedEdges:Double(bits.nonzeroBitCount),.rootDetectorCellAgreement:(r["rootDetectorActualCellAgreement"] as? Bool)==true ? 1:0,
          .rootRFMatches:Double(rootRF.count),.otherDetectorEvidenceCount:Double((r["otherDetectorEvidenceOrdinals"] as? [Int] ?? []).count),
          .contourContactAdded:(r["actualContourContactAdded"] as? Bool)==true ? 1:0,.sourceScore:sourceScore,
          .componentAlongMaxSourceW:componentAlong,.componentWidthMaxSourceW:componentWidth,.centerShift:shift]
        for i in 0..<min(22,sourcePrefix.count) where sourcePrefix[i].isFinite {if let field=Field(rawValue:String(format:"source%02d",i)) {v[field]=sourcePrefix[i]}}
        if sourcePrefix.count>7,sourcePrefix[7].isFinite {v[.sourceAxisResidual]=sourcePrefix[7]}
        guard v.values.allSatisfy({$0.isFinite}) else{return nil};return .init(values:v)
    }
    static func passes(_ features: Features, policy: Policy) -> Bool {
        guard policy.enabled else { return false }
        return policy.bounds.allSatisfy { bound in
            guard let value = features.values[bound.field], value.isFinite else { return false }
            if let low = bound.minimum, (!low.isFinite || value < low) { return false }
            if let high = bound.maximum, (!high.isFinite || value > high) { return false }
            return true
        }
    }
    static func choose(nativeOrdered:[NativeOffer],actualPrior:[CGPoint],nativeW:Double,
                       factoryReceipt:[String:Any],sourcePrefix:[Double],sourceScore:Double,
                       policy:Policy = .disabled)->Choice? {
        guard policy.enabled else{return nil};var best:Choice?=nil,bestRank=Double.infinity
        for (i,c) in nativeOrdered.enumerated() {
            guard c.nativeAdmissionPassed,c.sourceHardRejections.isEmpty,
                  let f=describe(rawOffer:c.rawOffer,actualPrior:actualPrior,nativeW:nativeW,factoryReceipt:factoryReceipt,sourcePrefix:sourcePrefix,sourceScore:sourceScore) else{continue}
            guard passes(f, policy: policy) else { continue }
            let rank:Double
            switch policy.rank {
            case .minimumArea:rank=f.values[.areaRatio]!
            case .maximumSourceCorroboration:rank = -(f.values[.nativeAnchoredPixelFraction]!+f.values[.rootRFSupportedPixelFraction]!)/2
            }
            if rank<bestRank {best = .init(nativeIndex:i,features:f,offer:c);bestRank=rank}
        }
        return best // source masks/geometry do NOT establish ownership or completeness
    }
}
