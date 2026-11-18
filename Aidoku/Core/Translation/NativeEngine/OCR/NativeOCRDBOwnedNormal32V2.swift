import Foundation

/// Source-only DB normal-boundary block, F64. Ownership is a separately verified
/// strict producer/exact-quad complete-cell witness, NEVER inferred by this kernel.
enum NativeOCRDBOwnedNormal32V2 {
    static let abi = "db-owned-normal32-v2-nested-candidates-f64"
    struct Run: Codable, Hashable, Sendable {let x:Int,y:Int,count:Int}
    struct Component: Decodable, Sendable {
        let runs:[Run]
        enum CodingKeys:String,CodingKey{case runs,component}
        init(runs:[Run]){self.runs=runs}
        init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);if c.contains(.component){runs=try c.decode(Component.self,forKey:.component).runs}else{runs=try c.decodeIfPresent([Run].self,forKey:.runs) ?? []}}
    }
    struct Seed: Decodable, Sendable {
        let ownerID:String?
        let sourceWidth:Int?,sourceHeight:Int?,mapFullWidth:Int?,mapFullHeight:Int?
        let mapOriginX:Int?,mapOriginY:Int? // receipt only; NEVER added to full-grid runs
        let completeCCScan:Bool?
        let components:[Component]?
        let ambiguousComponents:[Component]?
        let candidateComponents:[Component]?
    }
    struct Box: Decodable, Sendable {let detectorSeedEvidence:Seed?}
    struct RawPage: Decodable, Sendable {let width:Int,height:Int;let boxes:[Box]}
    struct Output: Sendable {let features:[Double];let reason:String?}
    struct Cell: Hashable, Sendable {let x:Int,y:Int}
    struct Owner: Sendable {
        let seed:Seed?;let privateCells:Set<Cell>;let contestedCells:Set<Cell>;let componentCount:Int
    }
    struct PreparedPage: Sendable {
        let width:Int,height:Int;let owners:[Owner];let ownerIDCounts:[String:Int]
    }
    private struct P {let n:Double,a:Double}
    private struct Basis {let cx:Double,cy:Double,nx:Double,ny:Double,ax:Double,ay:Double,loN:Double,hiN:Double,loA:Double,hiA:Double}
    private static func cells(_ c:[Component])->Set<Cell>{
        var out=Set<Cell>()
        for component in c {for run in component.runs where run.count>0 {
            guard run.x<=Int.max-run.count else{continue}
            for x in run.x..<(run.x+run.count){out.insert(.init(x:x,y:run.y))}
        }}
        return out
    }
    static func prepare(_ raw:RawPage)->PreparedPage {
        var owners:[Owner]=[],counts:[String:Int]=[:]
        for box in raw.boxes {
            let s=box.detectorSeedEvidence,pc=cells(s?.components ?? []),cc=cells((s?.ambiguousComponents ?? [])+(s?.candidateComponents ?? [])).subtracting(pc)
            let fingerprints=Set((s?.components ?? []).map { c in
                c.runs.sorted{a,b in a.x != b.x ? a.x<b.x:(a.y != b.y ? a.y<b.y:a.count<b.count)}
            })
            owners.append(.init(seed:s,privateCells:pc,contestedCells:cc,componentCount:fingerprints.count))
            if let id=s?.ownerID{counts[id,default:0]+=1}
        }
        return .init(width:raw.width,height:raw.height,owners:owners,ownerIDCounts:counts)
    }
    private static func basis(_ q:[[Double]])->(Basis?,String?) {
        guard q.count==4,q.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else{return(nil,"invalid-quad")}
        var best = -1.0,dx=0.0,dy=0.0
        for i in 0..<4{let x=q[(i+1)%4][0]-q[i][0],y=q[(i+1)%4][1]-q[i][1],l=x*x+y*y;if l>best{best=l;dx=x;dy=y}}
        guard best>0 else{return(nil,"degenerate-quad")}
        var ax=dx/sqrt(best),ay=dy/sqrt(best)
        if ay<0 || (ay==0 && ax<0){ax = -ax;ay = -ay}
        let nx=ay,ny = -ax,cx=q.map{$0[0]}.reduce(0,+)/4,cy=q.map{$0[1]}.reduce(0,+)/4
        let ns=q.map{($0[0]-cx)*nx+($0[1]-cy)*ny},als=q.map{($0[0]-cx)*ax+($0[1]-cy)*ay},ln=ns.min()!,hn=ns.max()!,la=als.min()!,ha=als.max()!
        guard min(hn-ln,ha-la)>1e-9 else{return(nil,"degenerate-spans")}
        return(.init(cx:cx,cy:cy,nx:nx,ny:ny,ax:ax,ay:ay,loN:ln,hiN:hn,loA:la,hiA:ha),nil)
    }
    /// authenticatedOwnerIndices must be certified by strict source producer or
    /// complete immutable packet witness. Passing [] explicitly means unknown.
    static func extract(quad:[[Double]],page:PreparedPage,authenticatedOwnerIndices:[Int])->Output {
        var f=[Double](repeating:0,count:32)
        func fail(_ reason:String)->Output{.init(features:[Double](repeating:0,count:32),reason:reason)}
        let ids=Array(Set(authenticatedOwnerIndices)).sorted(),owners=page.owners
        guard !ids.isEmpty,ids.allSatisfy({$0>=0 && $0<owners.count}) else{return fail("no-authenticated-owner")}
        let (candidate,error)=basis(quad);guard let b=candidate else{return fail(error!)}
        guard let first=owners[ids[0]].seed else{return fail("owner-frame-grid-identity-or-completeness-invalid")}
        let gw=first.mapFullWidth ?? 0,gh=first.mapFullHeight ?? 0
        func valid(_ s:Seed?)->Bool {
            guard let s,let id=s.ownerID,!id.isEmpty else{return false}
            return s.completeCCScan==true && s.sourceWidth==page.width && s.sourceHeight==page.height && s.mapFullWidth==gw && s.mapFullHeight==gh && min(gw,gh)>0 && page.ownerIDCounts[id]==1
        }
        guard ids.allSatisfy({valid(owners[$0].seed)}) else{return fail("owner-frame-grid-identity-or-completeness-invalid")}
        let sx=Double(page.width)/Double(gw),sy=Double(page.height)/Double(gh),W=b.hiN-b.loN,L=b.hiA-b.loA
        let dn=abs(b.nx)*sx+abs(b.ny)*sy,da=abs(b.ax)*sx+abs(b.ay)*sy
        var ownP=Set<Cell>(),ownC=Set<Cell>()
        for i in ids{ownP.formUnion(owners[i].privateCells);ownC.formUnion(owners[i].contestedCells)}
        ownC.subtract(ownP)
        func insideGrid(_ c:Cell)->Bool{c.x>=0 && c.y>=0 && c.x<gw && c.y<gh}
        guard ownP.union(ownC).allSatisfy(insideGrid) else{return fail("owned-run-outside-full-grid")}
        var neighbor=owners.allSatisfy{valid($0.seed)}
        let idSet=Set(ids);var foreignOwners=neighbor ? owners.indices.filter{!idSet.contains($0)}:[],foreign=Set<Cell>()
        for i in foreignOwners{foreign.formUnion(owners[i].privateCells)}
        if !foreign.allSatisfy(insideGrid){neighbor=false;foreign=[];foreignOwners=[]}
        f[0]=1;f[1]=ownP.isEmpty ? 0:1;f[2]=ownC.isEmpty ? 0:1;f[4]=log1p(Double(ids.count));f[5]=dn/W;f[6]=da/W;f[27]=log1p(Double(ids.map{owners[$0].componentCount}.reduce(0,+)));f[31]=neighbor ? 1:0
        let ctx=[b.loN-0.8*W,b.hiN+0.8*W,b.loA-4*W,b.hiA+4*W],cellarea=sx*sy
        func projected(_ cells:Set<Cell>)->[P] {
            cells.sorted{$0.x != $1.x ? $0.x<$1.x:$0.y<$1.y}.map{c in
                let x=(Double(c.x)+0.5)*sx-b.cx,y=(Double(c.y)+0.5)*sy-b.cy
                return .init(n:x*b.nx+y*b.ny,a:x*b.ax+y*b.ay)
            }
        }
        func incontext(_ z:[P])->[P]{z.filter{$0.n+dn/2>=ctx[0] && $0.n-dn/2<=ctx[1] && $0.a+da/2>=ctx[2] && $0.a-da/2<=ctx[3]}}
        let p=incontext(projected(ownP)),c=incontext(projected(ownC)),ff=incontext(projected(foreign))
        let corners=[(-sx/2,-sy/2),(sx/2,-sy/2),(sx/2,sy/2),(-sx/2,sy/2)].map{P(n:$0.0*b.nx+$0.1*b.ny,a:$0.0*b.ax+$0.1*b.ay)}
        func clippedArea(_ input:[P],_ r:[Double])->Double {
            var poly=input
            for (axis,bound,sign) in [(0,r[0],1.0),(0,r[1],-1.0),(1,r[2],1.0),(1,r[3],-1.0)] {
                if poly.isEmpty{return 0};var out:[P]=[];var prev=poly.last!
                func v(_ x:P)->Double{axis==0 ? x.n:x.a}
                var pin=sign*(v(prev)-bound)>=0
                for cur in poly {
                    let cin=sign*(v(cur)-bound)>=0
                    if cin != pin {let t=(bound-v(prev))/(v(cur)-v(prev));out.append(.init(n:prev.n+t*(cur.n-prev.n),a:prev.a+t*(cur.a-prev.a)))}
                    if cin{out.append(cur)};prev=cur;pin=cin
                }
                poly=out
            }
            guard poly.count>=3 else{return 0};var x=0.0,y=0.0
            for i in poly.indices{let j=(i+1)%poly.count;x += poly[i].n*poly[j].a;y += poly[i].a*poly[j].n}
            return abs(x-y)*0.5
        }
        func area(_ z:[P],_ r:[Double])->Double {
            var inside=0,total=0.0
            for v in z where v.n+dn/2>r[0] && v.n-dn/2<r[1] && v.a+da/2>r[2] && v.a-da/2<r[3] {
                if v.n-dn/2>=r[0] && v.n+dn/2<=r[1] && v.a-da/2>=r[2] && v.a+da/2<=r[3]{inside+=1}
                else{total += clippedArea(corners.map{.init(n:$0.n+v.n,a:$0.a+v.a)},r)}
            }
            return Double(inside)*cellarea+total
        }
        let contextarea=(ctx[1]-ctx[0])*(ctx[3]-ctx[2]);f[7]=area(p,ctx)/contextarea;f[28]=area(c,ctx)/contextarea
        if !p.isEmpty {
            let ns=p.map(\.n).sorted();f[8]=(ns[0]-dn/2-b.loN)/W;f[9]=(ns.last!+dn/2-b.hiN)/W
            f[10]=(ns[max(0,Int(ceil(0.05*Double(ns.count)))-1)]-b.loN)/W;f[11]=(ns[max(0,Int(ceil(0.95*Double(ns.count)))-1)]-b.hiN)/W
        }
        func bands(_ z:[P])->(Double,Double,Double,Double,Double) {
            var lows:[Double]=[],highs:[Double]=[],contacts=[0,0]
            for i in 0..<32 {
                let l=b.loA+L*Double(i)/32,h=b.loA+L*Double(i+1)/32,v=z.filter{$0.a+da/2>l && $0.a-da/2<h}
                if v.isEmpty{continue};lows.append(v.map(\.n).min()!-dn/2);highs.append(v.map(\.n).max()!+dn/2)
                for (j,e) in [b.loN,b.hiN].enumerated(){if v.contains(where:{$0.n+dn/2>=e-dn/2 && $0.n-dn/2<=e+dn/2}){contacts[j]+=1}}
            }
            func std(_ values:[Double])->Double{guard values.count>1 else{return 0};let mean=values.reduce(0,+)/Double(values.count);return sqrt(values.map{($0-mean)*($0-mean)}.reduce(0,+)/Double(values.count))/W}
            return(Double(contacts[0])/32,Double(contacts[1])/32,Double(lows.count)/32,std(lows),std(highs))
        }
        let pb=bands(p),cb=bands(c);f[12]=pb.0;f[13]=pb.1;f[24]=pb.3;f[25]=pb.4;f[26]=pb.2;f[14]=cb.0;f[15]=cb.1;f[30]=cb.2
        if neighbor {
            f[29]=area(ff,ctx)/contextarea
            for j in 0..<2 {
                var r=j==0 ? [b.loN-W,b.loN,b.loA,b.hiA]:[b.hiN,b.hiN+W,b.loA,b.hiA]
                r[0]=max(r[0],ctx[0]);r[1]=min(r[1],ctx[1]);f[20+j]=area(ff,r)/(W*L)
            }
            var offers=[[[Double]]] (repeating:[],count:2)
            for i in foreignOwners {
                let z=incontext(projected(owners[i].privateCells)).filter{$0.a+da/2>b.loA && $0.a-da/2<b.hiA}
                if z.isEmpty{continue}
                let lowN=z.map(\.n).min()!-dn/2,lowA=z.map(\.a).min()!-da/2,highN=z.map(\.n).max()!+dn/2,highA=z.map(\.a).max()!+da/2,mid=(lowN+highN)/2,cmid=(b.loN+b.hiN)/2
                if mid==cmid{continue};let j=mid<cmid ? 0:1,gap=j==0 ? b.loN-highN:lowN-b.hiN,overlap=max(0,min(highA,b.hiA)-max(lowA,b.loA))/L
                offers[j].append([abs(gap),gap,lowN,lowA,highN,highA,overlap])
            }
            for j in 0..<2 {
                if let v=offers[j].min(by:{$0.lexicographicallyPrecedes($1)}){f[3]=1;f[16+j]=v[1]/W;f[18+j]=v[6]}
            }
            let union=incontext(projected(ownP.union(ownC).union(foreign))).filter{$0.a+da/2>b.loA && $0.a-da/2<b.hiA}
            for (j,e) in [b.loN,b.hiN].enumerated() {
                let hits=union.filter{j==0 ? ($0.n+dn/2>=e-0.8*W && $0.n-dn/2<=e):($0.n-dn/2<=e+0.8*W && $0.n+dn/2>=e)}
                if hits.isEmpty{f[22+j]=0.8}
                else if hits.contains(where:{$0.n-dn/2<=e && $0.n+dn/2>=e}){f[22+j]=0}
                else{f[22+j]=max(0,j==0 ? (e-(hits.map(\.n).max()!+dn/2))/W:((hits.map(\.n).min()!-dn/2)-e)/W)}
            }
        }
        guard f.allSatisfy(\.isFinite) else{return fail("nonfinite-feature")}
        return .init(features:f,reason:nil)
    }
}
