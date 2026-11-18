import Foundation

// Pure source-context geometry hypotheses; no files, IDs, GT, ownership or admission.
enum NativeOCRSourceBoundaryRegression435 {
    enum Invalid: Error { case schema, tree, support, input }
    struct Point: Codable, Hashable {
        let x: Double, y: Double
        init(_ x:Double,_ y:Double) {self.x=x;self.y=y}
        init(from decoder:Decoder) throws {
            if var a=try? decoder.unkeyedContainer() {x=try a.decode(Double.self);y=try a.decode(Double.self)}
            else {let a=try decoder.container(keyedBy:Keys.self);x=try a.decode(Double.self,forKey:.x);y=try a.decode(Double.self,forKey:.y)}
        }
        enum Keys:String,CodingKey {case x,y}
        func encode(to encoder:Encoder) throws {var a=encoder.unkeyedContainer();try a.encode(x);try a.encode(y)}
    }
    struct Input: Decodable {
        let sourcePrefix22:[Double],fallbackSource8:[Double],actualV3:[Point],originalDetector:[Point]
        let rfTextRectangles:[[Double]],frame:[Double],supportMode:String,supportSummary3:[Double]
        enum CodingKeys:String,CodingKey {
            case sourcePrefix22="source_prefix22",fallbackSource8="fallback_source8"
            case actualV3="actual_v3_quad",originalDetector="original_detector_quad"
            case rfTextRectangles="source_rf_text_rectangles",frame="actual_frame_width_height"
            case supportMode="source_support_mode",supportSummary3="source_support_confidence_samples_cells"
        }
        init(prefix22:[Double],fallback8:[Double],actualV3:[Point],originalDetector:[Point],rf:[[Double]],frame:[Double],mode:String,summary3:[Double]) {
            sourcePrefix22=prefix22;fallbackSource8=fallback8;self.actualV3=actualV3;self.originalDetector=originalDetector
            rfTextRectangles=rf;self.frame=frame;supportMode=mode;supportSummary3=summary3
        }
        // Authentic FALLBACK52 only; candidate-relative cost/geometry slots must be zero.
        // Root52 contains prefix0..19 at28..47, prefix21 at48; constructor-ID20 omitted.
        static func fromAuthenticatedFallback52(_ v:[Double],actualV3:[Point],originalDetector:[Point],rf:[[Double]],frame:[Double]) -> Input? {
            guard v.count==52,v.allSatisfy({$0.isFinite}),v[8..<24].allSatisfy({abs($0)<=1e-10}),
                  v[25...27].allSatisfy({$0==0 || $0==1}) else {return nil}
            let prefix=Array(v[28..<48])+[0,v[48]]
            var mode="";if v[25]==1 {mode += "RGB "};if v[26]==1 {mode += "GG "};if v[27]==1 {mode += "model"}
            return Input(prefix22:prefix,fallback8:Array(v[0..<8]),actualV3:actualV3,originalDetector:originalDetector,
                         rf:rf,frame:frame,mode:mode,summary3:Array(v[49..<52]))
        }
    }
    struct Extracted {
        let features:[Double],center:Point,normal:Point,along:Point,bounds:[Double],rootW:Double,frame:[Double],rfBound:[Double]
    }
    fileprivate struct Node {let feature:Int,left:Int,right:Int;let threshold:Double,value:Double}
    fileprivate struct Forest {let trees:[[Node]],rate:Double}
    struct Bundle {fileprivate let forests:[Forest],quantiles:[[Double]]}
    private struct WireBundle:Decodable {let schema:String,featureCount:Int,targetNames:[String];let targets:[WireTarget]}
    private struct WireTarget:Decodable {let model:WireModel,trainingResidualQuantiles10_25_50_75_90:[Double]}
    private struct WireModel:Decodable {
        let format:String,featureNames:[String],maximumDepth:Int,enabled:Bool
        let learningRate:Double,initialBias:Double,fallbackPrediction:Double,trees:[[[Double]]]
    }
    static func decode(_ data:Data) throws -> Bundle {
        let w=try JSONDecoder().decode(WireBundle.self,from:data)
        guard w.schema=="source-only-continuous-boundary435-bundle-v1",w.featureCount==50,
              w.targetNames==["normalLow","normalHigh","alongLow","alongHigh","angle"],w.targets.count==5 else {throw Invalid.schema}
        var forests:[Forest]=[],quantiles:[[Double]]=[]
        for target in w.targets {
            let m=target.model,qq=target.trainingResidualQuantiles10_25_50_75_90
            guard m.format=="source-root-boundary435-regression-v1",m.featureNames==(0..<50).map({"f\($0)"}),
                  (1...8).contains(m.maximumDepth),m.enabled,m.initialBias==0,m.fallbackPrediction==0,m.learningRate==0.1,
                  !m.trees.isEmpty,m.trees.count<=128,qq.count==5,qq.allSatisfy({$0.isFinite}) else {throw Invalid.schema}
            var trees:[[Node]]=[]
            for tt in m.trees {
                guard !tt.isEmpty,tt.count<=511 else {throw Invalid.tree}
                var nodes:[Node]=[]
                for v in tt {
                    guard v.count==7,v.allSatisfy({$0.isFinite}),[0,2,3,5,6].allSatisfy({v[$0].rounded(.towardZero)==v[$0]}),
                          v[0]>=(-1),v[0]<50,v[2]>=(-1),v[2]<Double(tt.count),v[3]>=(-1),v[3]<Double(tt.count),
                          v[5]>=32,v[6]>=4,v[6]<=v[5] else {throw Invalid.support}
                    nodes.append(Node(feature:Int(v[0]),left:Int(v[2]),right:Int(v[3]),threshold:v[1],value:v[4]))
                }
                var seen=Set<Int>()
                func visit(_ i:Int,_ depth:Int) throws {
                    guard nodes.indices.contains(i),depth<=m.maximumDepth,seen.insert(i).inserted else {throw Invalid.tree}
                    let n=nodes[i]
                    if n.feature<0 {guard n.left == -1,n.right == -1 else {throw Invalid.tree}}
                    else {try visit(n.left,depth+1);try visit(n.right,depth+1)}
                }
                try visit(0,0);guard seen.count==nodes.count else {throw Invalid.tree};trees.append(nodes)
            }
            forests.append(Forest(trees:trees,rate:0.1));quantiles.append(qq)
        }
        return Bundle(forests:forests,quantiles:quantiles)
    }
    // CPython float sum uses Neumaier compensation; center roundoff can cross tiny tree cuts.
    private static func pythonSum(_ values:[Double])->Double {
        var hi=0.0,lo=0.0
        for x in values {let t=hi+x;if abs(hi)>=abs(x) {lo += (hi-t)+x} else {lo += (x-t)+hi};hi=t}
        return lo != 0 && lo.isFinite ? hi+lo:hi
    }
    private static func valid(_ q:[Point])->Bool {q.count==4 && q.allSatisfy({$0.x.isFinite && $0.y.isFinite})}
    private static func basis(_ q:[Point]) -> (Point,Point,Point,[Double],Double)? {
        guard valid(q) else {return nil};var best=Point(0,0),length=0.0
        for i in 0..<4 {let e=Point(q[(i+1)%4].x-q[i].x,q[(i+1)%4].y-q[i].y),ll=hypot(e.x,e.y);if ll>length {best=e;length=ll}}
        guard length>0 else {return nil};var a=Point(best.x/length,best.y/length)
        if a.y<0 || (a.y==0 && a.x<0) {a=Point(-a.x,-a.y)}
        let n=Point(a.y,-a.x),c=Point(pythonSum(q.map{$0.x})/4,pythonSum(q.map{$0.y})/4),b=bounds(q,c,n,a),w=b[1]-b[0]
        guard w>0,w.isFinite else {return nil};return (c,n,a,b,w)
    }
    private static func bounds(_ q:[Point],_ c:Point,_ n:Point,_ a:Point)->[Double] {
        let ns=q.map{($0.x-c.x)*n.x+($0.y-c.y)*n.y},aa=q.map{($0.x-c.x)*a.x+($0.y-c.y)*a.y}
        return [ns.min()!,ns.max()!,aa.min()!,aa.max()!]
    }
    private static func angle(_ a:Point,_ q:[Point])->Double? {
        guard let (_,_,aa,_,_)=basis(q) else {return nil}
        var t=atan2(a.x*aa.y-a.y*aa.x,a.x*aa.x+a.y*aa.y)
        while t>Double.pi/2 {t -= Double.pi};while t < -Double.pi/2 {t += Double.pi};return t
    }
    static func extract(_ input:Input)->Extracted? {
        guard input.sourcePrefix22.count==22,input.fallbackSource8.count==8,input.supportSummary3.count==3,
              input.frame.count==2,input.frame.allSatisfy({$0.isFinite && $0>0}),
              let (c,n,a,b,w)=basis(input.actualV3),let da=angle(a,input.originalDetector) else {return nil}
        let q=input.actualV3,box=[q.map{$0.x}.min()!,q.map{$0.y}.min()!,q.map{$0.x}.max()!,q.map{$0.y}.max()!]
        func relative(_ qq:[Point])->[Double] {zip(bounds(qq,c,n,a),b).map{($0.0-$0.1)/w}}
        var best:[Double]?=nil,bestOverlap=0.0,bestConfidence=0.0
        for rr in input.rfTextRectangles {
            guard rr.count==5,rr.allSatisfy({$0.isFinite}) else {return nil}
            let x=rr[0],y=rr[1],ww=rr[2],hh=rr[3],cf=rr[4]
            let inter=max(0,min(x+ww,box[2])-max(x,box[0]))*max(0,min(y+hh,box[3])-max(y,box[1]))
            let overlap=inter/max(1,(box[2]-box[0])*(box[3]-box[1]))
            if inter>0 && (best==nil || overlap>bestOverlap || (overlap==bestOverlap && cf>bestConfidence)) {best=rr;bestOverlap=overlap;bestConfidence=cf}
        }
        var rf:[Double],limit:[Double]
        if let v=best {let x=v[0],y=v[1],ww=v[2],hh=v[3];rf=relative([Point(x,y),Point(x+ww,y),Point(x+ww,y+hh),Point(x,y+hh)])+[v[4],1];limit=[min(box[0],x),min(box[1],y),max(box[2],x+ww),max(box[3],y+hh)]}
        else {rf=Array(repeating:0,count:6);limit=[box[0]-2*w,box[1]-2*w,box[2]+2*w,box[3]+2*w]}
        var x=input.sourcePrefix22.enumerated().filter{$0.offset != 20}.map{$0.element}
        x += input.fallbackSource8;x += rf;x += [log(max(1e-9,(b[3]-b[2])/w)),a.x*a.x-a.y*a.y,2*a.x*a.y]
        x += [input.supportMode.contains("RGB") ? 1:0,input.supportMode.contains("GG") ? 1:0,input.supportMode.contains("model") ? 1:0]
        x += input.supportSummary3;x += relative(input.originalDetector);x += [da,1]
        guard x.count==50,x.allSatisfy({$0.isFinite}) else {return nil}
        return Extracted(features:x,center:c,normal:n,along:a,bounds:b,rootW:w,frame:input.frame,rfBound:limit)
    }
    static func predict(_ bundle:Bundle,_ source:Extracted)->[Double]? {
        guard source.features.count==50,source.features.allSatisfy({$0.isFinite}) else {return nil}
        return bundle.forests.map{forest in
            var s=0.0
            for t in forest.trees {var i=0;while t[i].feature>=0 {let n=t[i];i=source.features[n.feature]<=n.threshold ? n.left:n.right};let contribution=forest.rate*t[i].value;s += contribution}
            return s
        }
    }
    struct Offer {
        let kind:String,polygon:[Point],relativeTargets:[Double]
        var nativeAdmissionGranted:Bool {false}
        var receipt:[String:Any] { ["family":"source-boundary-regression435","kind":kind,"sourceOnly":true,
            "nativeAdmissionGranted":false,"requiresActual425AndPixelGuards":true,"RFOrDetectorTreatedAsForeground":false,
            "meanIsHypothesisNotDefaultSelection":true,"predictedRelativeTargets":relativeTargets] }
    }
    private static func make(_ s:Extracted,_ y:[Double])->[Point]? {
        var z=Array(y.prefix(4)).map{max(-4,min(4,$0))};z.append(max(-Double.pi/6,min(Double.pi/6,y[4])))
        let b=zip(s.bounds,z).map{$0.0+s.rootW*$0.1},w=s.rootW
        guard b[1]-b[0]>=0.1*w,b[3]-b[2]>=0.25*w else {return nil}
        func rot(_ v:Point)->Point {Point(cos(z[4])*v.x-sin(z[4])*v.y,sin(z[4])*v.x+cos(z[4])*v.y)}
        let n=rot(s.normal),a=rot(s.along),c=s.center
        let q=[(b[0],b[2]),(b[1],b[2]),(b[1],b[3]),(b[0],b[3])].map{u,v in Point(c.x+u*n.x+v*a.x,c.y+u*n.y+v*a.y)}
        let bb=s.rfBound,l=max(0,bb[0]),t=max(0,bb[1]),h=min(s.frame[0],bb[2]),bot=min(s.frame[1],bb[3])
        guard q.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.x>=l-1e-7 && $0.x<=h+1e-7 && $0.y>=t-1e-7 && $0.y<=bot+1e-7}) else {return nil};return q
    }
    static func proposals(_ bundle:Bundle,_ source:Extracted)->[Offer] {
        guard let mean=predict(bundle,source) else {return []};let qq=bundle.quantiles
        var alternatives:[(String,[Double])]=[("mean",mean)]
        for (name,qi) in [("median",2),("q25",1),("q75",3)] {alternatives.append((name,mean.enumerated().map{$0.element+qq[$0.offset][qi]}))}
        alternatives.append(("outward",mean.enumerated().map{ i,v in v+qq[i][[0,2].contains(i) ? 1:[1,3].contains(i) ? 3:2]}))
        alternatives.append(("inward",mean.enumerated().map{ i,v in v+qq[i][[0,2].contains(i) ? 3:[1,3].contains(i) ? 1:2]}))
        alternatives.append(("angleLow",Array(mean.prefix(4))+[mean[4]+qq[4][1]]));alternatives.append(("angleHigh",Array(mean.prefix(4))+[mean[4]+qq[4][3]]))
        var seen=Set<[Point]>(),out:[Offer]=[]
        for (kind,y) in alternatives {guard let q=make(source,y),seen.insert(q).inserted else {continue};out.append(Offer(kind:kind,polygon:q,relativeTargets:y))}
        return out
    }
    static func offersForNativeAssessment(_ bundle:Bundle,input:Input)->[[String:Any]] {
        guard let source=extract(input) else {return []}
        return proposals(bundle,source).map{ ["key":"source-regression435-"+$0.kind,"polygon":$0.polygon.map{[$0.x,$0.y]},
            "sourceReceipt":$0.receipt,"geometryProposalOnly":true,"actualPriorEnclosureClaimed":false] }
    }
}
