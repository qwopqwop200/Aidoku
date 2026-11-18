import Foundation
import CoreGraphics

/// Exact 28 geometry/cost +24 actual-source features from the parent416 Python
/// extractors. No predictor, nativeW, IDs, fold/hash, GT or external state.
enum SourceCost416FeatureAdapter {
    static let geometryNames = (0..<8).map{"candidateSourceCost\($0)"}
        + (0..<8).map{"deltaSourceCost\($0)"}
        + ["logAreaRatio", "centerNormalShiftFallbackWidths", "centerAlongShiftFallbackWidths",
           "normalLowMovementFallbackWidths", "normalHighMovementFallbackWidths",
           "alongLowMovementFallbackWidths", "alongHighMovementFallbackWidths",
           "axisDifferenceCosSquared", "logFallbackAspect", "supportRGB", "supportGG", "supportModel"]
    static let actualSourceNames = [
        "sourceScore", "aspect", "normalInkRatio", "alongInkRatio", "privateNormalRatio",
        "ownedComponents", "axisCorrection", "axisResidual", "sourceKind", "hasInkProof",
        "normalInkOffset", "alongInkOffset", "supportKind", "observedHeadExtension",
        "observedTailExtension", "observedJoin", "supportLeftClearanceWidths",
        "supportRightClearanceWidths", "supportHeadClearanceWidths", "supportTailClearanceWidths",
        "supportMinimumRectangleAreaRatio", "actualSupportConfidence",
        "supportSamplesThousandsClamped20", "originalNativeCellsThousandsClamped20"]
    static let names = geometryNames + actualSourceNames

    private static func polygonArea(_ q:[CGPoint]) -> Double {
        // Deliberately the ORIGINAL unshifted shoelace and Python summation order;
        // translating coordinates or using a geometry library changes parity.
        var sum=0.0
        for i in 0..<4 {
            let j=(i+1)%4
            sum += Double(q[i].x)*Double(q[j].y)-Double(q[j].x)*Double(q[i].y)
        }
        return abs(sum)/2
    }
    private static func center(_ q:[CGPoint]) -> [Double] {
        var x=0.0,y=0.0
        for p in q {x += Double(p.x);y += Double(p.y)}
        return [x/4,y/4]
    }
    private static func pythonHypot(_ dx:Double,_ dy:Double) -> Double {
        // CPython math.hypot rounds more accurately than Darwin hypot. A1ULP
        // discrepancy can reverse which nearly tied opposite edge is maximal.
        // Scale by exact powers of2 and recover both square-product errors with
        // FMA; one compensated sqrt correction gives the rounded2D norm.
        let x=abs(dx),y=abs(dy),maximum=max(x,y)
        if maximum==0 || !maximum.isFinite {return maximum}
        let exponent=maximum.exponent
        let a=Double(sign:.plus,exponent:-exponent,significand:max(x,y))
        let b=Double(sign:.plus,exponent:-exponent,significand:min(x,y))
        let aa=a*a,bb=b*b,sum=aa+bb
        let error=((aa-sum)+bb)+(-aa).addingProduct(a,a)+(-bb).addingProduct(b,b)
        let root=sqrt(sum)
        let residual=sum.addingProduct(-root,root)+error
        let corrected=root+residual/(2*root)
        return Double(sign:.plus,exponent:exponent,significand:corrected)
    }
    private static func axis(_ q:[CGPoint]) -> [Double]? {
        var selected=[0.0,0.0],longest = -Double.infinity
        for i in 0..<4 {
            let j=(i+1)%4,dx=Double(q[j].x)-Double(q[i].x),dy=Double(q[j].y)-Double(q[i].y)
            let length=pythonHypot(dx,dy)
            // Python max(edges,key=hypot) keeps the FIRST exact tie. No epsilon,
            // winding normalization, edge averaging, or >= tie replacement.
            if length>longest {longest=length;selected=[dx,dy]}
        }
        guard longest.isFinite,longest>0 else{return nil}
        return [selected[0]/longest,selected[1]/longest]
    }
    static func features(candidatePolygon q:[CGPoint], fallbackPolygon q0:[CGPoint],
                         candidate8features406:[Double], fallback8features406:[Double],
                         sourceFeaturePrefix22:[Double], sourceMode406:String,
                         sourceSupportConfidence406:Double, sourceSupportPointCount406:Int,
                         actualNativeCellCenterCount:Int) -> [Double]? {
        guard q.count==4,q0.count==4,(q+q0).allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              candidate8features406.count==8,fallback8features406.count==8,sourceFeaturePrefix22.count==22,
              (candidate8features406+fallback8features406+sourceFeaturePrefix22).allSatisfy(\.isFinite),
              sourceSupportConfidence406.isFinite,sourceSupportPointCount406>=0,actualNativeCellCenterCount>=0,
              let a=axis(q0),let v=axis(q) else{return nil}
        let n=[-a[1],a[0]],cc=center(q0)
        func project(_ polygon:[CGPoint]) -> [[Double]] {
            polygon.map { p in
                let x=Double(p.x)-cc[0],y=Double(p.y)-cc[1]
                return [x*n[0]+y*n[1],x*a[0]+y*a[1]]
            }
        }
        func bounds(_ p:[[Double]]) -> [Double] {
            // Python order: nLow,aLow,nHigh,aHigh (NOT nLow,nHigh,aLow,aHigh).
            [p.map{$0[0]}.min()!,p.map{$0[1]}.min()!,p.map{$0[0]}.max()!,p.map{$0[1]}.max()!]
        }
        let bounds0=bounds(project(q0)),b=bounds(project(q)),z=center(q)
        // This width is FALLBACK geometry projected on its longest-edge frame.
        // It is not an actual native measurement width and must never be replaced.
        let width=max(1e-9,bounds0[2]-bounds0[0])
        let length=max(width,bounds0[3]-bounds0[1])
        let fallbackArea=polygonArea(q0),candidateArea=polygonArea(q)
        guard fallbackArea.isFinite,fallbackArea>0,candidateArea.isFinite else{return nil}
        let dot=v[0]*a[0]+v[1]*a[1]
        var result=candidate8features406
        for i in 0..<8 {result.append(candidate8features406[i]-fallback8features406[i])}
        result.append(contentsOf:[
            log(max(1e-9,candidateArea/fallbackArea)),
            ((z[0]-cc[0])*n[0]+(z[1]-cc[1])*n[1])/width,
            ((z[0]-cc[0])*a[0]+(z[1]-cc[1])*a[1])/width,
            (b[0]-bounds0[0])/width,(b[2]-bounds0[2])/width,
            (b[1]-bounds0[1])/width,(b[3]-bounds0[3])/width,
            1-dot*dot,log(length/width),
            sourceMode406.contains("RGB") ? 1:0,
            sourceMode406.contains("GG") ? 1:0,
            sourceMode406.contains("model") ? 1:0])
        // append_actual_source.py excludes ONLY original source index20 (angle).
        // Index21 (minimum rectangle area ratio) stays as feature48.
        for i in 0..<22 where i != 20 {result.append(sourceFeaturePrefix22[i])}
        result.append(sourceSupportConfidence406)
        result.append(min(20,Double(sourceSupportPointCount406)/1000))
        result.append(min(20,Double(actualNativeCellCenterCount)/1000))
        guard result.count==52,result.allSatisfy(\.isFinite) else{return nil}
        return result
    }
}
