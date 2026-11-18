import Foundation
import CryptoKit

/// Staged source-only port. Parameters match frozen Python v1. No GT/page/text,
/// recognizer, proposal-bank lookup, raw payload rewrite or G.Refinement emission.
enum NativeOCRSourceOwnedRailPartition {
    static let abi="source-owned-along-conditioned-normal-rail-partition-v1"
    static let receiptABI="native-sorted-json-fullseed-subset-byte-receipt-v1"
    static let canonicalRGBABI="native-cgimage-opaque-srgb-white-rgba8-v2"
    struct Frame:Sendable {
        let width:Int,height:Int,bytesPerRow:Int,rgba:[UInt8]
    }
    struct Original:Codable,Sendable {
        let polygon:[[Double]]
        let detectorSeedEvidence:NativeOCRDetectorSeedEvidence?
    }
    struct Cell:Hashable,Sendable {let x:Int,y:Int}
    struct Subset:Codable,Equatable,Sendable {
        let originalComponentSeed:Int
        let observedCellSubsetRuns:[NativeOCRDetectorSeedEvidence.Run]
    }
    struct Lane:Sendable {
        let polygon:[[Double]]
        let sourceObservationID:String
        let parentOwnerID:String
        let fullOriginalSeedSHA256:String
        let sourceCellSubsetSHA256:String
        let componentCellSubsets:[Subset]
        let sourceOwnedCells:Int
        let fullOriginalSeedEncodedBytes:Data
        let sourceCellSubsetEncodedBytes:Data
        /// Original evidence remains immutable/full. Subset never masquerades as it.
        let fullOriginalEvidence:NativeOCRDetectorSeedEvidence
    }
    struct Result:Sendable {
        let lanes:[Lane]
        let reason:String?
        let diagnostics:[String:Double]
    }
    private static func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private static func encoded(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    /// Exact source capture JSON codec (Data upperBounds uses an explicit wrapper).
    static func sourceSeedCanonicalData(_ s:NativeOCRDetectorSeedEvidence)throws->Data {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        var obj=try JSONSerialization.jsonObject(with:e.encode(s)) as! [String:Any]
        if s.sourceProbabilityROI==nil{obj["sourceProbabilityROI"]=NSNull()}
        if var roi=obj["sourceProbabilityROI"] as? [String:Any],let b=roi["upperBounds"] as? String {roi["upperBounds"]=["base64":b,"byteCount":s.sourceProbabilityROI!.upperBounds.count];obj["sourceProbabilityROI"]=roi}
        return try encoded(obj)
    }
    static func sourceSeedHash(_ s:NativeOCRDetectorSeedEvidence)throws->String {hash(try sourceSeedCanonicalData(s))}
    private static func median(_ values:[Double])->Double {
        guard !values.isEmpty else{return .nan};let s=values.sorted(),m=s.count/2
        return s.count%2==1 ? s[m]:(s[m-1]+s[m])/2
    }
    private static func mean1D(_ x:[Double])->Double {
        guard !x.isEmpty else{return .nan}
        // NumPy's contiguous pairwise summation for short reduction vectors.
        if x.count<8 {return x.reduce(-0.0,+)/Double(x.count)}
        var sums=Array(x.prefix(8)),i=8
        while i+8<=x.count {for j in 0..<8{sums[j]+=x[i+j]};i+=8}
        var total=((sums[0]+sums[1])+(sums[2]+sums[3]))+((sums[4]+sums[5])+(sums[6]+sums[7]))
        while i<x.count{total+=x[i];i+=1}
        return total/Double(x.count)
    }
    private static func reflect101(_ x:Int,_ n:Int)->Int {
        if n<=1{return 0};var p=x
        while p<0 || p>=n {p = p<0 ? -p:2*n-p-2}
        return p
    }
    private static func gaussian(_ x:[Double],sigma:Double)->[Double] {
        let size=max(1,Int((sigma*8+1).rounded(.toNearestOrEven))|1),r=size/2
        var k=(0..<size).map{exp(-0.5*pow(Double($0-r)/sigma,2))};let sum=k.reduce(0,+);k=k.map{$0/sum}
        var out=Array(repeating:0.0,count:x.count)
        for i in x.indices {var v=0.0;for j in k.indices{v+=x[reflect101(i+j-r,x.count)]*k[j]};out[i]=v}
        return out
    }
    private static func morphology(_ mask:[UInt8],rows:Int,cols:Int,radius:Int,dilate:Bool)->[UInt8] {
        var integral=Array(repeating:0,count:(rows+1)*(cols+1))
        for y in 0..<rows {var total=0;for x in 0..<cols{total+=Int(mask[y*cols+x]);integral[(y+1)*(cols+1)+x+1]=integral[y*(cols+1)+x+1]+total}}
        var out=Array(repeating:UInt8(0),count:mask.count)
        for y in 0..<rows{let y0=max(0,y-radius),y1=min(rows,y+radius+1)
            for x in 0..<cols{let x0=max(0,x-radius),x1=min(cols,x+radius+1),stride=cols+1
                let count=integral[y1*stride+x1]-integral[y0*stride+x1]-integral[y1*stride+x0]+integral[y0*stride+x0]
                out[y*cols+x]=(dilate ? count>0:count==(y1-y0)*(x1-x0)) ? 1:0
            }
        };return out
    }
    private static func otsu(_ values:[UInt8])->Int {
        var h=Array(repeating:0,count:256);for v in values{h[Int(v)]+=1}
        let scale=1/Double(values.count);var mu=0.0
        for i in 0..<256{mu+=Double(i)*Double(h[i])};mu*=scale
        var q1=0.0,mu1=0.0,best=0.0,threshold=0
        for i in 0..<256 {
            let p=Double(h[i])*scale
            mu1*=q1;q1+=p;let q2=1-q1
            if min(q1,q2)<Double(Float.ulpOfOne) || max(q1,q2)>1-Double(Float.ulpOfOne){continue}
            mu1=(mu1+Double(i)*p)/q1;let mu2=(mu-q1*mu1)/q2;let v=q1*q2*(mu1-mu2)*(mu1-mu2)
            if v>best{best=v;threshold=i}
        };return threshold
    }
    private static func packed(_ set:Set<Cell>)->[NativeOCRDetectorSeedEvidence.Run] {
        let sorted=set.sorted{a,b in a.y==b.y ? a.x<b.x:a.y<b.y}
        guard let first=sorted.first else{return []};var y=first.y,lo=first.x,prev=lo,out:[NativeOCRDetectorSeedEvidence.Run]=[]
        for c in sorted.dropFirst(){if c.y != y || c.x != prev+1{out.append(.init(y:y,x:lo,count:prev-lo+1));y=c.y;lo=c.x};prev=c.x}
        out.append(.init(y:y,x:lo,count:prev-lo+1));return out
    }
    private static func bestIndex(_ a:[Double],_ range:Range<Int>,maximum:Bool)->Int {
        var chosen=range.lowerBound
        for i in range.dropFirst(){if maximum ? a[i]>a[chosen]:a[i]<a[chosen]{chosen=i}}
        return chosen
    }
    private struct Offer {
        let fraction:Double,negativeRatio:Double,peak:Double,cut:Int,left:Int,right:Int,count:Int
        var key:[Double]{[fraction,negativeRatio,peak,Double(cut),Double(left),Double(right),Double(count)]}
    }
    private static func lexBefore(_ a:[Double],_ b:[Double])->Bool{for (x,y) in zip(a,b){if x != y{return x<y}};return false}

    static func partition(frame:Frame,original:Original)throws->Result {
        func fail(_ reason:String)->Result{.init(lanes:[],reason:reason,diagnostics:[:])}
        let W=frame.width,H=frame.height
        guard frame.bytesPerRow>=W*4,frame.rgba.count>=frame.bytesPerRow*H else{return fail("source-frame-mismatch")}
        guard let s=original.detectorSeedEvidence,!s.ownerID.isEmpty,s.completeCCScan==true else{return fail("missing-complete-owned-source-evidence")}
        guard s.sourceWidth==W,s.sourceHeight==H else{return fail("source-frame-mismatch")}
        let comps=s.components;guard !comps.isEmpty else{return fail("no-private-cells")}
        let q=original.polygon;guard q.count==4,q.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else{return fail("degenerate-geometry")}
        var bestLength = -1.0,ax=0.0,ay=0.0
        for i in 0..<4{let dx=q[(i+1)%4][0]-q[i][0],dy=q[(i+1)%4][1]-q[i][1],length=dx*dx+dy*dy;if length>bestLength{bestLength=length;ax=dx;ay=dy}}
        guard bestLength>0 else{return fail("degenerate-geometry")};let norm=sqrt(bestLength);ax/=norm;ay/=norm
        if ay<0 || (ay==0 && ax<0){ax = -ax;ay = -ay};let nx=ay,ny = -ax,cx=q.map{$0[0]}.reduce(0,+)/4,cy=q.map{$0[1]}.reduce(0,+)/4
        let pn=q.map{($0[0]-cx)*nx+($0[1]-cy)*ny},pa=q.map{($0[0]-cx)*ax+($0[1]-cy)*ay}
        let nl=pn.min()!,nh=pn.max()!,al=pa.min()!,ah=pa.max()!,width=nh-nl,length=ah-al
        guard min(width,length)>0,s.mapFullWidth>0,s.mapFullHeight>0 else{return fail("degenerate-geometry")}
        let sx=Double(W)/Double(s.mapFullWidth),sy=Double(H)/Double(s.mapFullHeight),dn=abs(nx)*sx+abs(ny)*sy,da=abs(ax)*sx+abs(ay)*sy
        let n0=nl-0.10*width,n1=nh+0.10*width,a0=al-0.10*length,a1=ah+0.10*length,N=max(16,min(384,Int(ceil(n1-n0)))),M=max(32,min(768,Int(ceil(a1-a0)))),du=(n1-n0)/Double(N),dv=(a1-a0)/Double(M)
        let u=(0..<N).map{n0+(Double($0)+0.5)*du},v=(0..<M).map{a0+(Double($0)+0.5)*dv};let pixels=M*N
        var componentCells:[Set<Cell>]=[],all=Set<Cell>()
        for c in comps{var subset=Set<Cell>();for r in c.runs where r.count>0{for x in r.x..<(r.x+r.count){subset.insert(.init(x:x,y:r.y))}};componentCells.append(subset);all.formUnion(subset)}
        guard !all.isEmpty else{return fail("no-observed-private-runs")};let cells=all.sorted{a,b in a.x==b.x ? a.y<b.y:a.x<b.x}
        var cn:[Double]=[],ca:[Double]=[]
        for c in cells{let x=(Double(c.x)+0.5)*sx-cx,y=(Double(c.y)+0.5)*sy-cy;cn.append(x*nx+y*ny);ca.append(x*ax+y*ay)}
        var owned=Array(repeating:UInt8(0),count:pixels),gray=owned
        func color(_ x:Int,_ y:Int,_ ch:Int)->Int {if x<0 || y<0 || x>=W || y>=H{return 255};return Int(frame.rgba[y*frame.bytesPerRow+x*4+ch])}
        for y in 0..<M{for x in 0..<N{
            let mx=cx+v[y]*ax+u[x]*nx,my=cy+v[y]*ay+u[x]*ny,index=y*N+x
            let gx=Int(floor(mx/sx)),gy=Int(floor(my/sy));owned[index]=all.contains(.init(x:gx,y:gy)) ? 1:0
            // OpenCV INTER_LINEAR: Float32 coordinate, five fractional bits,
            // constant-white four-neighbor interpolation, integer half-up cast.
            let X=Int((Double(Float(mx))*32).rounded(.toNearestOrEven)),Y=Int((Double(Float(my))*32).rounded(.toNearestOrEven)),ix=X>>5,iy=Y>>5,fx=X&31,fy=Y&31
            var channels=[0,0,0]
            for ch in 0..<3 {channels[ch]=(color(ix,iy,ch)*(32-fx)*(32-fy)+color(ix+1,iy,ch)*fx*(32-fy)+color(ix,iy+1,ch)*(32-fx)*fy+color(ix+1,iy+1,ch)*fx*fy+512)>>10}
            gray[index]=UInt8((channels[0]*9798+channels[1]*19235+channels[2]*3735+16384)>>15)
        }}
        let radius=min(31,max(1,Int(ceil(2*max(dn/du,da/dv))))),near=morphology(owned,rows:M,cols:N,radius:radius,dilate:true)
        guard Int(gray.max()!)-Int(gray.min()!)>=10 else{return fail("no-source-rgb-boundary-contrast")}
        var inside:[Double]=[],outside:[Double]=[]
        for i in 0..<pixels{if owned[i]>0{inside.append(Double(gray[i]))};if near[i]==0{outside.append(Double(gray[i]))}}
        if outside.isEmpty{for x in 0..<N{outside.append(Double(gray[x]));outside.append(Double(gray[(M-1)*N+x]))};for y in 0..<M{outside.append(Double(gray[y*N]));outside.append(Double(gray[y*N+N-1]))}}
        let dark=median(inside)<=median(outside),threshold=otsu(gray);var ink=Array(repeating:UInt8(0),count:pixels)
        for i in 0..<pixels{ink[i]=(dark ? Int(gray[i])<=threshold:Int(gray[i])>threshold) ? 1:0}
        let bands=32;var profiles=Array(repeating:Array(repeating:0.0,count:N),count:bands),db=profiles
        for j in 0..<bands{let low=j*M/bands,high=(j+1)*M/bands,count=Double(high-low)
            for x in 0..<N{var rgbCount=0,dbCount=0;for y in low..<high{let i=y*N+x;rgbCount+=Int(ink[i]*near[i]);dbCount+=Int(owned[i])};profiles[j][x]=Double(rgbCount)/count;db[j][x]=Double(dbCount)/count}
            profiles[j]=gaussian(profiles[j],sigma:max(0.6,0.5*dn/du));db[j]=gaussian(db[j],sigma:max(0.6,0.5*dn/du))
        }
        let dbmax=db.map{$0.max()!},rgbmax=profiles.map{$0.max()!},active=dbmax.map{$0>0.01}
        guard active.filter({$0}).count>=6 else{return fail("insufficient-along-private-support")}
        var score=profiles,mean=Array(repeating:0.0,count:N);let activeCount=active.filter{$0}.count
        for j in 0..<bands{for x in 0..<N{score[j][x]=0.7*(profiles[j][x]/max(rgbmax[j],1e-9))+0.3*(db[j][x]/max(dbmax[j],1e-9));if active[j]{mean[x]+=score[j][x]}}}
        mean=mean.map{$0/Double(activeCount)}
        let guardN=max(1,Int(ceil(0.5*dn/du))),separation=max(2*dn,0.15*width),track=max(guardN,Int(ceil(0.15*width/du)))
        func paths(cut:Int,left:Int,right:Int)->[Int]? {
            let lo=max(left+guardN,cut-track),hi=min(right-guardN,cut+track+1)
            if hi<=lo{return nil};var result:[Int]=[]
            for j in 0..<bands{var ix=lo,best=Double.infinity;for x in lo..<hi{let value=score[j][x]+0.05*Double(abs(x-cut))/Double(N);if value<best{best=value;ix=x}};result.append(ix)}
            return result
        }
        var selected:Offer?
        if guardN+2<N-guardN-2{for cut in (guardN+2)..<(N-guardN-2){
            if u[cut]<nl+0.1*width || u[cut]>nh-0.1*width{continue}
            let left=bestIndex(mean,0..<(cut-guardN),maximum:true),right=bestIndex(mean,(cut+guardN)..<N,maximum:true)
            if Double(right-left)*du<separation{continue}
            var co:[Int]=[]
            for j in 0..<bands{if active[j] && rgbmax[j]>0.01 && db[j][..<cut].max()!>0.01 && db[j][cut...].max()!>0.01 && profiles[j][left]>0.01 && profiles[j][right]>0.01{co.append(j)}}
            if co.count<6{continue};guard let path=paths(cut:cut,left:left,right:right) else{continue}
            var ratios:[Double]=[],quiet=0
            for j in co{let valley=score[j][path[j]],peak=min(score[j][left],score[j][right]);ratios.append(valley/max(peak,1e-9));if valley<=0.55*peak{quiet+=1}}
            let fraction=Double(quiet)/Double(co.count);if fraction<0.70{continue}
            let offer=Offer(fraction:fraction,negativeRatio: -mean1D(ratios),peak:min(mean[left],mean[right]),cut:cut,left:left,right:right,count:co.count)
            if selected==nil || lexBefore(selected!.key,offer.key){selected=offer}
        }}
        guard let selected else{return fail("no-persistent-rgb-db-supported-valley")}
        let path=paths(cut:selected.cut,left:selected.left,right:selected.right)!
        var pathX:[Double]=[],pathY:[Double]=[]
        for j in 0..<bands{if active[j] && rgbmax[j]>0.01 && score[j][path[j]]<=0.55*min(score[j][selected.left],score[j][selected.right]){pathX.append(u[path[j]]);pathY.append(a0+(Double(j)+0.5)*(a1-a0)/Double(bands))}}
        var slopes:[Double]=[]
        for i in pathX.indices{if i+1<pathX.count{for j in (i+1)..<pathX.count where pathY[j] != pathY[i]{slopes.append((pathX[j]-pathX[i])/(pathY[j]-pathY[i]))}}}
        let slope=slopes.isEmpty ? 0:median(slopes),intercept=median(zip(pathX,pathY).map{$0-slope*$1}),residual=median(zip(pathX,pathY).map{abs($0-intercept-slope*$1)})
        if residual>1.5*dn{return fail("unstable-source-valley-rail-fit")}
        let denom=sqrt(1+slope*slope),n2x=(nx-slope*ax)/denom,n2y=(ny-slope*ay)/denom,a2x=(ax+slope*nx)/denom,a2y=(ay+slope*ny)/denom,dn2=abs(n2x)*sx+abs(n2y)*sy,da2=abs(a2x)*sx+abs(a2y)*sy
        let closed=morphology(morphology(ink,rows:M,cols:N,radius:1,dilate:true),rows:M,cols:N,radius:1,dilate:false),seedHash=try sourceSeedHash(s)
        var output:[Lane]=[]
        for side in 0..<2{
            var subset=Set<Cell>()
            for i in cells.indices{let left=cn[i]<intercept+slope*ca[i];if left==(side==0){subset.insert(cells[i])}}
            if subset.isEmpty{return fail("empty-observed-cell-subset")}
            var mask=closed,subowned=owned
            for y in 0..<M{for x in 0..<N{let isLeft=u[x]<intercept+slope*v[y];if isLeft != (side==0){mask[y*N+x]=0;subowned[y*N+x]=0}}}
            let anchor=morphology(subowned,rows:M,cols:N,radius:1,dilate:true);var seen=Array(repeating:false,count:pixels),points:[Int]=[]
            for start in 0..<pixels where mask[start]>0 && !seen[start] {
                var queue=[start],head=0,border=false,touches=false;seen[start]=true
                while head<queue.count{let i=queue[head];head+=1;let y=i/N,x=i%N;if x==0 || y==0 || x==N-1 || y==M-1{border=true};if anchor[i]>0{touches=true}
                    for dy in -1...1{for dx in -1...1{if dx==0 && dy==0{continue};let xx=x+dx,yy=y+dy;if xx>=0 && yy>=0 && xx<N && yy<M{let z=yy*N+xx;if mask[z]>0 && !seen[z]{seen[z]=true;queue.append(z)}}}}
                };if !border && touches{points+=queue}
            }
            if points.count<2{return fail("no-closed-rgb-support-for-each-lane")}
            var snLow=Double.infinity,snHigh = -Double.infinity,saLow=Double.infinity,saHigh = -Double.infinity
            for c in subset{let x=(Double(c.x)+0.5)*sx-cx,y=(Double(c.y)+0.5)*sy-cy,nn=x*n2x+y*n2y,aa=x*a2x+y*a2y;snLow=min(snLow,nn);snHigh=max(snHigh,nn);saLow=min(saLow,aa);saHigh=max(saHigh,aa)}
            var rgbLow=Double.infinity,rgbHigh = -Double.infinity,aLow=Double.infinity,aHigh = -Double.infinity
            for i in points{let x=u[i%N]*nx+v[i/N]*ax,y=u[i%N]*ny+v[i/N]*ay,nn=x*n2x+y*n2y,aa=x*a2x+y*a2y;rgbLow=min(rgbLow,nn);rgbHigh=max(rgbHigh,nn);aLow=min(aLow,aa);aHigh=max(aHigh,aa)}
            let lowN=min(rgbLow-du/2,snLow-dn2/2),highN=max(rgbHigh+du/2,snHigh+dn2/2),lowA=min(aLow-dv/2,saLow-da2/2),highA=max(aHigh+dv/2,saHigh+da2/2)
            if min(highN-lowN,highA-lowA)<=0{return fail("degenerate-lane")}
            let polygon=[[lowN,lowA],[highN,lowA],[highN,highA],[lowN,highA]].map{[cx+$0[0]*n2x+$0[1]*a2x,cy+$0[0]*n2y+$0[1]*a2y]}
            if polygon.contains(where:{$0[0]<0 || $0[1]<0 || $0[0]>Double(W) || $0[1]>Double(H)}){return fail("out-of-frame-lane")}
            var subsets:[Subset]=[]
            for i in comps.indices{let part=componentCells[i].intersection(subset);if !part.isEmpty{subsets.append(.init(originalComponentSeed:comps[i].seed,observedCellSubsetRuns:packed(part)))}}
            let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];let obj=try JSONSerialization.jsonObject(with:e.encode(subsets)),proofBytes=try encoded(["parentOwnerID":s.ownerID,"fullOriginalSeedSHA256":seedHash,"componentCellSubsets":obj]),proof=hash(proofBytes)
            output.append(.init(polygon:polygon,sourceObservationID:"source-owned-rail/"+proof,parentOwnerID:s.ownerID,fullOriginalSeedSHA256:seedHash,sourceCellSubsetSHA256:proof,componentCellSubsets:subsets,sourceOwnedCells:subset.count,fullOriginalSeedEncodedBytes:try sourceSeedCanonicalData(s),sourceCellSubsetEncodedBytes:proofBytes,fullOriginalEvidence:s))
        }
        return .init(lanes:output,reason:nil,diagnostics:["privateCells":Double(cells.count),"activeBands":Double(activeCount),"coactiveBands":Double(selected.count),"persistentValleyFraction":selected.fraction,"valleyPeakRatio": -selected.negativeRatio,"sourceNormalCut":u[selected.cut],"observedValleySlope":slope,"observedValleyIntercept":intercept,"valleyFitResidualPixels":residual,"warpRows":Double(M),"warpCols":Double(N),"sourceForegroundOtsu":Double(threshold),"sourceForegroundDark":dark ? 1:0])
    }
}
