import Foundation
import CoreGraphics

/// Source-only SHADOW calibration. No IDs, hashes, folds, GT or native admission API.
enum SourceBoundary435UtilityHerschel {
    struct Node { let feature:Int; let threshold:Double; let left:Int; let right:Int; let value:Double }
    struct Model {
        let trees:[[Node]]; let rate:Double; let margin:Double; let depth:Int
        init(data:Data) throws {
            enum Bad:Error { case model }
            guard let o=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  o["format"] as? String == "source-boundary435-utility-Herschel-v1",
                  (o["featureNames"] as? [String])?.count == 63,
                  let raw=o["trees"] as? [[[Double]]], !raw.isEmpty, raw.count<=128,
                  let rate=o["learningRate"] as? Double, rate==0.1,
                  let margin=o["margin"] as? Double,margin.isFinite,margin>=0,
                  let depth=o["maximumDepth"] as? Int,depth>=1,depth<=8 else {throw Bad.model}
            var trees:[[Node]]=[]
            for rows in raw {
                var nodes:[Node]=[]
                for n in rows {
                    guard n.count==7,n.allSatisfy({$0.isFinite}),n[0].rounded()==n[0],n[2].rounded()==n[2],n[3].rounded()==n[3],n[0]>=(-1),n[0]<63,n[5]>=32,n[6]>=4 else {throw Bad.model}
                    nodes.append(Node(feature:Int(n[0]),threshold:n[1],left:Int(n[2]),right:Int(n[3]),value:n[4]))
                }
                var seen=Set<Int>()
                func visit(_ i:Int,_ level:Int)throws {
                    guard nodes.indices.contains(i),level<=depth,seen.insert(i).inserted else {throw Bad.model}
                    let n=nodes[i]
                    if n.feature>=0 {try visit(n.left,level+1);try visit(n.right,level+1)}
                    else if n.left != -1 || n.right != -1 {throw Bad.model}
                }
                try visit(0,0);guard seen.count==nodes.count else {throw Bad.model};trees.append(nodes)
            }
            self.trees=trees;self.rate=rate;self.margin=margin;self.depth=depth
        }
        func score(_ features:[Double])->Double? {
            guard features.count==63,features.allSatisfy({$0.isFinite}) else {return nil}
            var sum=0.0
            for tree in trees {
                var i=0
                while tree[i].feature>=0 {let n=tree[i];i=features[n.feature]<=n.threshold ? n.left:n.right}
                sum += rate*tree[i].value
            }
            return sum.isFinite ? sum:nil
        }
    }
    private static func sum(_ values:[Double])->Double {
        var hi=0.0,lo=0.0
        for x in values {let t=hi+x;if abs(hi)>=abs(x) {lo += (hi-t)+x} else {lo += (x-t)+hi};hi=t}
        return lo != 0 && lo.isFinite ? hi+lo:hi
    }
    private static func point(_ p:CGPoint)->(Double,Double) {(Double(p.x),Double(p.y))}
    private static func valid(_ q:[CGPoint],_ frame:CGSize)->Bool {
        guard q.count==4,frame.width.isFinite,frame.height.isFinite,frame.width>0,frame.height>0,
              q.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.x>=0 && $0.y>=0 && $0.x<=frame.width && $0.y<=frame.height}) else{return false}
        let z=(0..<4).map{i -> Double in let a=point(q[i]),b=point(q[(i+1)%4]),c=point(q[(i+2)%4]);return(b.0-a.0)*(c.1-b.1)-(b.1-a.1)*(c.0-b.0)}
        return z.allSatisfy({$0>1e-9}) || z.allSatisfy({$0<(-1e-9)})
    }
    private static func area(_ q:[CGPoint])->Double {
        let terms=(0..<4).map{i -> Double in let a=point(q[i]),b=point(q[(i+1)%4]);return a.0*b.1-b.0*a.1}
        return abs(sum(terms))/2
    }
    private static func basis(_ q:[CGPoint])->(c:(Double,Double),n:(Double,Double),a:(Double,Double),w:Double,l:Double) {
        var best=(0.0,0.0),length=0.0
        for i in 0..<4 {let p=point(q[i]),b=point(q[(i+1)%4]),e=(b.0-p.0,b.1-p.1),len=hypot(e.0,e.1);if len>length {best=e;length=len}}
        var a=(best.0/length,best.1/length)
        if a.1<0 || (a.1==0 && a.0<0) {a=(-a.0,-a.1)}
        let n=(a.1,-a.0),c=(sum(q.map{Double($0.x)})/4,sum(q.map{Double($0.y)})/4)
        let ns=q.map{(Double($0.x)-c.0)*n.0+(Double($0.y)-c.1)*n.1},ls=q.map{(Double($0.x)-c.0)*a.0+(Double($0.y)-c.1)*a.1}
        return(c,n,a,ns.max()!-ns.min()!,ls.max()!-ls.min()!)
    }
    static func features(sourceFeatures50:[Double],predictedRelative5:[Double],candidate:[CGPoint],baseline:[CGPoint],rootW:CGFloat,frame:CGSize)->[Double]? {
        guard sourceFeatures50.count==50,predictedRelative5.count==5,rootW.isFinite,rootW>0,valid(candidate,frame),valid(baseline,frame) else{return nil}
        let c=basis(candidate),b=basis(baseline),w=Double(rootW),ang=atan2(b.a.0*c.a.1-b.a.1*c.a.0,b.a.0*c.a.0+b.a.1*c.a.1)
        let shift=(c.c.0-b.c.0,c.c.1-b.c.1)
        var terms:[Double]=[]
        for i in 0..<4 {let p=point(candidate[i]),q=point(baseline[i]);terms += [pow(p.0-q.0,2),pow(p.1-q.1,2)]}
        let squared=sum(terms)
        let ratios=[area(candidate)/area(baseline),c.w/b.w,c.l/b.l,(shift.0*b.n.0+shift.1*b.n.1)/w,(shift.0*b.a.0+shift.1*b.a.1)/w,sin(2*ang),cos(2*ang),sqrt(squared/4)/w]
        let x=sourceFeatures50+predictedRelative5+ratios
        return x.allSatisfy({$0.isFinite}) ? x:nil
    }
    static func preferred(model:Model,sourceFeatures50:[Double],predictedRelative5:[Double],candidate:[CGPoint],baseline:[CGPoint],rootW:CGFloat,frame:CGSize)->(score:Double,nominate:Bool,receipt:[String:Any])? {
        guard let x=features(sourceFeatures50:sourceFeatures50,predictedRelative5:predictedRelative5,candidate:candidate,baseline:baseline,rootW:rootW,frame:frame),let score=model.score(x) else{return nil}
        return(score,score>model.margin,["sourceOnly":true,"featureCount":63,"utilityThreshold":model.margin,"basicGeometryAndFrameValid":true,"shadowOnly":true,"legacy425PolicyApplied":false,"nativeAdmissionGranted":false,"physicalCoreReviewRequired":true])
    }
}
