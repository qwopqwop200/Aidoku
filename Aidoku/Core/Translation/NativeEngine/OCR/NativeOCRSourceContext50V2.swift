import Foundation

/// NEW geometry-localization agreement ABI, NOT the legacy authenticSource50.
/// Source RF RECTANGLES only: no masks/logits, OCR, GT, identities or ownership inference.
enum NativeOCRSourceContext50V2 {
    static let abi = "current-source-det12-rf32-text6-context50-v2-f32-to-f64"
    static let featureNames = ["bestIoU","secondIoU","gap","bestCandidateCoverage","bestRawCoverage","scoreBestIoU","scoreBestIoUTimesIoU","maxScoreIoU","maxScoreCandidateCoverage","overlapCountDiv8Clip","highIoUCountDiv8Clip","available"].map{"det."+$0}
        + ["frame","text","balloon","sfx"].flatMap { cls in
            ["bestIoU","maxCandidateCoverage","maxPrimitiveCoverage","maxConfIoU","maxConfCandidateCoverage","maxConfIntersecting","intersectionCountDiv8Clip","available"].map{"rf."+cls+"."+$0}
        } + ["text.normalLowOffsetTanh","text.normalHighOffsetTanh","text.alongLowOffsetTanh","text.alongHighOffsetTanh","text.exists","rf.any"]
    struct Detector: Codable, Sendable { let polygon: [[Double]]; let score: Double }
    struct Primitive: Codable, Sendable {
        /// Canonical wire class:0 frame,1 text,2 balloon,3 sfx. NOT internal semantic enum rawValue.
        let canonicalClass: Int
        let confidence: Double
        let polygon: [[Double]] // exact sourceBounds rectangle corners, no clipping
    }
    struct Output: Sendable { let features: [Double]; let available: Double }
    private struct P { let x:Double,y:Double }
    private struct Metric { let iou:Double, candidate:Double, reference:Double }
    private struct Basis { let c:P,n:P,a:P,b:[Double],width:Double }
    /// Pass source-sized detector quads and all4 canonical RF rectangle classes in original order.
    /// Availability reports genuine input availability, never geometric quality or overlap.
    static func extract(candidate:[[Double]], detector:[Detector], primitives:[Primitive],
                        detectorCaptureAvailable:Bool=true, rfCaptureAvailable:Bool=true) -> Output? {
        guard valid(candidate),let s=basis(candidate) else{return nil}
        let det=detector.filter{$0.score.isFinite && (0...1).contains($0.score) && valid($0.polygon)}
        let rf=primitives.filter{(0...3).contains($0.canonicalClass) && $0.confidence.isFinite && (0...1).contains($0.confidence) && valid($0.polygon) && rectangle($0.polygon)}
        var dm:[Metric]=[],rm:[Metric]=[]
        for d in det {guard let m=metric(candidate,d.polygon) else{return nil};dm.append(m)}
        for r in rf {guard let m=metric(candidate,r.polygon) else{return nil};rm.append(m)}
        var v:[Double]=[]
        if !det.isEmpty {
            var best=0
            for i in det.indices where dm[i].iou>dm[best].iou {best=i}
            let ranked=dm.map(\.iou).sorted(by:>)
            let first=ranked[0],second=ranked.count>1 ? ranked[1]:0,score=det[best].score
            var maxSI=0.0,maxSC=0.0,overlap=0,high=0
            for i in det.indices {maxSI=max(maxSI,det[i].score*dm[i].iou);maxSC=max(maxSC,det[i].score*dm[i].candidate);if dm[i].candidate>0{overlap+=1};if dm[i].iou>=0.5{high+=1}}
            v=[first,second,first-second,dm[best].candidate,dm[best].reference,score,score*first,maxSI,maxSC,min(1,Double(overlap)/8),min(1,Double(high)/8),1]
        }else{v=[Double](repeating:0,count:12)}
        for cl in 0..<4 {
            let indices=rf.indices.filter{rf[$0].canonicalClass==cl}
            guard !indices.isEmpty else {v += [Double](repeating:0,count:8);continue}
            var iou=0.0,cc=0.0,pc=0.0,ci=0.0,ccc=0.0,confidence=0.0,count=0
            for i in indices {let m=rm[i],c=rf[i].confidence;iou=max(iou,m.iou);cc=max(cc,m.candidate);pc=max(pc,m.reference);ci=max(ci,c*m.iou);ccc=max(ccc,c*m.candidate);if m.candidate>0{count+=1;confidence=max(confidence,c)}}
            v += [iou,cc,pc,ci,ccc,confidence,min(1,Double(count)/8),1]
        }
        let text=rf.indices.filter{rf[$0].canonicalClass==1}
        if var best=text.first {
            var score=rf[best].confidence*rm[best].candidate
            for i in text.dropFirst() {let next=rf[i].confidence*rm[i].candidate;if next>score{best=i;score=next}}
            let q=rf[best].polygon.map{P(x:$0[0]-s.c.x,y:$0[1]-s.c.y)}
            let ns=q.map{$0.x*s.n.x+$0.y*s.n.y},als=q.map{$0.x*s.a.x+$0.y*s.a.y}
            let b=[ns.min()!,ns.max()!,als.min()!,als.max()!]
            v += (0..<4).map{tanh(((b[$0]-s.b[$0])/s.width)/4)}+[1]
        }else{v += [Double](repeating:0,count:5)}
        v.append(rf.isEmpty ? 0:1)
        guard v.count==50,v.allSatisfy(\.isFinite) else{return nil}
        let rounded=v.map{Double(Float($0))}
        return .init(features:rounded,available:detectorCaptureAvailable && rfCaptureAvailable ? 1:0)
    }
    private static func cross(_ a:P,_ b:P,_ p:P)->Double{(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)}
    private static func area(_ q:[P])->Double {
        guard q.count>=3 else{return 0};let o=q[0];var s=0.0
        for i in q.indices{let a=q[i],b=q[(i+1)%q.count];s += (a.x-o.x)*(b.y-o.y)-(b.x-o.x)*(a.y-o.y)}
        return s/2
    }
    private static func valid(_ q:[[Double]])->Bool {
        guard q.count==4,q.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else{return false}
        let p=q.map{P(x:$0[0],y:$0[1])};var sign:Bool?
        for i in 0..<4{let z=cross(p[i],p[(i+1)%4],p[(i+2)%4]);if z != 0{if let sign,sign != (z>0){return false};sign=z>0}}
        return sign != nil
    }
    private static func rectangle(_ q:[[Double]])->Bool {
        q[0][1]==q[1][1] && q[1][0]==q[2][0] && q[2][1]==q[3][1] && q[3][0]==q[0][0] && q[1][0]>q[0][0] && q[2][1]>q[1][1]
    }
    private static func basis(_ q:[[Double]])->Basis? {
        var best=P(x:0,y:0),length=0.0
        for i in 0..<4{let e=P(x:q[(i+1)%4][0]-q[i][0],y:q[(i+1)%4][1]-q[i][1]),l=hypot(e.x,e.y);if l>length{length=l;best=e}}
        guard length>0 else{return nil};var a=P(x:best.x/length,y:best.y/length)
        if a.y<0 || (a.y==0 && a.x<0){a=P(x:-a.x,y:-a.y)}
        let n=P(x:a.y,y:-a.x),c=P(x:q.map{$0[0]}.reduce(0,+)/4,y:q.map{$0[1]}.reduce(0,+)/4)
        let ns=q.map{($0[0]-c.x)*n.x+($0[1]-c.y)*n.y},als=q.map{($0[0]-c.x)*a.x+($0[1]-c.y)*a.y}
        let b=[ns.min()!,ns.max()!,als.min()!,als.max()!],w=b[1]-b[0]
        guard w>0,w.isFinite else{return nil};return .init(c:c,n:n,a:a,b:b,width:w)
    }
    /// Same unsnapped half-plane algorithm/tolerance/origin translation as quad.cpp.
    private static func metric(_ aq:[[Double]],_ bq:[[Double]])->Metric? {
        let o=aq[0],a=aq.map{P(x:$0[0]-o[0],y:$0[1]-o[1])},b=bq.map{P(x:$0[0]-o[0],y:$0[1]-o[1])}
        var extent=1.0
        for p in a+b{extent=max(extent,abs(p.x),abs(p.y))}
        let eps=64*Double.ulpOfOne*extent*extent,pa=abs(area(a)),pb=abs(area(b))
        guard pa>eps,pb>eps else{return nil}
        var out=b;let orientation=area(a)>=0 ? 1.0:-1.0
        for i in 0..<4 {
            if out.isEmpty{break};let input=out;out=[];let e0=a[i],e1=a[(i+1)%4]
            func dist(_ p:P)->Double{let v=orientation*cross(e0,e1,p);return abs(v)<=eps ? 0:v}
            var prev=input.last!,pd=dist(prev)
            for cur in input{let cd=dist(cur);if (pd>=0) != (cd>=0){let t=max(0,min(1,pd/(pd-cd)));out.append(P(x:prev.x+t*(cur.x-prev.x),y:prev.y+t*(cur.y-prev.y)))};if cd>=0{out.append(cur)};prev=cur;pd=cd}
        }
        let inter=max(0,min(pa,pb,abs(area(out)))),union=pa+pb-inter
        return .init(iou:max(0,min(1,inter/union)),candidate:inter/pa,reference:inter/pb)
    }
}
