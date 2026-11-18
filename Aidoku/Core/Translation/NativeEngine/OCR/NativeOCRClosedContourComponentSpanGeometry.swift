import Foundation

/// Private experimental source-pixel geometry. No GT, text, model, file/page
/// lookup or recognition score. Not registered with Pipeline or a runtime head.
/// Canny Sobel/NMS/hysteresis -> closed 8-connected edge regions -> exact DB
/// ownership association. No native removal-mask erosion or rectangle padding.
enum NativeOCRClosedContourComponentSpanGeometry {
    struct Point: Codable, Equatable, Sendable {let x:Double;let y:Double}
    struct Rect: Codable, Equatable, Sendable {let x:Int;let y:Int;let width:Int;let height:Int}
    struct Source: Codable, Equatable, Sendable {
        let polygon:[Point]
        let detectorSeedEvidence:NativeOCRDetectorSeedEvidence?
    }
    struct RGBROI: Sendable {
        let sourceWidth:Int;let sourceHeight:Int
        let rect:Rect
        /// Tightly packed RGB8 or BGR8: all channels participate symmetrically.
        let bytes:[UInt8]
    }
    struct ComponentSpan: Codable, Equatable, Sendable {
        let seed:Int
        let representedClosedRegions:Int
        let representedClosedRegionIDs:[Int]
        let detectorCellCenterBounds:[Double]
        let observedClosedBoundaryBounds:[Double]?
        let projectedHalfCellUncertainty:[Double]
        let normalSpanContained:Bool
        let alongSpanContained:Bool
    }
    struct Candidate: Codable, Equatable, Sendable {
        let anchorSourceIndex:Int;let sourceParent:Int;let seedParentBoxIndex:Int
        let sourceMembers:[Int];let ownerID:String;let definiteSeeds:[Int]
        let sourceDigest:String?;let sourceGrid:[Int];let polygon:[Point]
        let originalPolygon:[Point];let normalSpanBefore:Double;let normalSpanAfter:Double
        let alongSpanBefore:Double;let alongSpanAfter:Double
        let sourceOwnedCoverage:Double;let sourceOwnedPixels:Int;let acceptedEdgeRegions:Int
        let nativeSeedPacketUnchanged:Bool;let recognitionIndependent:Bool
        let componentSpans:[ComponentSpan];let admissionPolicy:String
    }
    struct Assessment: Codable, Equatable, Sendable {
        let sourceIndex:Int;let reason:String;let cropBounds:Rect?
        let sourceOwnedPixels:Int;let acceptedEdgeRegions:Int;let sourceOwnedCoverage:Double?
        let borderVetoes:Int;let foreignVetoes:Int;let componentSpans:[ComponentSpan];let candidate:Candidate?
    }
    private struct Basis {
        let o:Point;let ax:Double;let ay:Double
        init?(_ q:[Point]) {
            guard q.count==4,q.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return nil}
            var best=0,maxLength = -Double.infinity
            for i in 0..<4 {let dx=q[(i+1)%4].x-q[i].x,dy=q[(i+1)%4].y-q[i].y;let ll=dx*dx+dy*dy
                if ll>maxLength{best=i;maxLength=ll}}
            guard maxLength>0 else{return nil}
            let e=Point(x:q[(best+1)%4].x-q[best].x,y:q[(best+1)%4].y-q[best].y),len=sqrt(maxLength)
            let sign=e.y>1e-9 || (abs(e.y)<=1e-9 && e.x>=0) ? 1.0 : -1.0
            o=q[0];ax=sign*e.x/len;ay=sign*e.y/len
        }
        func project(_ p:Point)->Point{.init(x:(p.x-o.x)*ay-(p.y-o.y)*ax,y:(p.x-o.x)*ax+(p.y-o.y)*ay)}
        func restore(_ n:Double,_ a:Double)->Point{.init(x:o.x+n*ay+a*ax,y:o.y-n*ax+a*ay)}
        func bounds(_ q:[Point])->(Double,Double,Double,Double){let p=q.map(project);return(p.map(\.x).min()!,p.map(\.y).min()!,p.map(\.x).max()!,p.map(\.y).max()!)}
    }
    static func requiredROI(original:Source,width:Int,height:Int)->Rect? {
        guard width>0,height>0,width<=131072,height<=131072,let basis=Basis(original.polygon) else{return nil}
        let (l,t,r,b)=basis.bounds(original.polygon),nw=r-l,ah=b-t
        guard nw>0,ah>0 else{return nil}
        let q=[basis.restore(l-0.5*nw,t-0.15*ah),basis.restore(r+0.5*nw,t-0.15*ah),basis.restore(r+0.5*nw,b+0.15*ah),basis.restore(l-0.5*nw,b+0.15*ah)]
        let x0=Int(max(0,min(Double(width),floor(q.map(\.x).min()!)))),y0=Int(max(0,min(Double(height),floor(q.map(\.y).min()!))))
        let x1=Int(max(0,min(Double(width),ceil(q.map(\.x).max()!)))),y1=Int(max(0,min(Double(height),ceil(q.map(\.y).max()!))))
        let w=x1-x0,h=y1-y0
        guard w>0,h>0,w<=1_000_000/h else{return nil}
        return .init(x:x0,y:y0,width:w,height:h)
    }

    /// Parent crops live RGB using requiredROI, then passes every immutable raw
    /// box/packet as barriers. Supplying an ROI from another operation is invalid.
    static func measure(anchor:Int,originals:[Source],roi:RGBROI)->Assessment {
        var ownPixels=0,accepted=0,borderVeto=0,foreignVeto=0,coverage:Double?
        var spanProofs:[ComponentSpan]=[]
        func stop(_ reason:String,_ c:Candidate?=nil)->Assessment {
            .init(sourceIndex:anchor,reason:reason,cropBounds:roi.rect,sourceOwnedPixels:ownPixels,
                acceptedEdgeRegions:accepted,sourceOwnedCoverage:coverage,borderVetoes:borderVeto,
                foreignVetoes:foreignVeto,componentSpans:spanProofs,candidate:c)
        }
        guard originals.indices.contains(anchor),originals.count<=4096,
              let expected=requiredROI(original:originals[anchor],width:roi.sourceWidth,height:roi.sourceHeight),expected==roi.rect,
              roi.bytes.count==expected.width*expected.height*3 else{return stop("invalid-source-ROI")}
        let original=originals[anchor]
        guard let seed=original.detectorSeedEvidence,seed.isValid,seed.ownershipVersion==2,seed.completeCCScan==true,
              seed.sourceWidth==roi.sourceWidth,seed.sourceHeight==roi.sourceHeight,!seed.components.isEmpty,
              let basis=Basis(original.polygon) else{return stop("missing-valid-definite-source-cells")}
        let w=expected.width,h=expected.height,count=w*h
        var label=[Int32](repeating:0,count:count),uncertain=[UInt8](repeating:0,count:count)
        func compatible(_ s:NativeOCRDetectorSeedEvidence)->Bool {
            s.isValid && s.ownershipVersion==2 && s.completeCCScan==true && s.sourceWidth==roi.sourceWidth && s.sourceHeight==roi.sourceHeight && s.mapFullWidth==seed.mapFullWidth && s.mapFullHeight==seed.mapFullHeight
        }
        func paint(_ c:NativeOCRDetectorSeedEvidence.Component,_ s:NativeOCRDetectorSeedEvidence,_ owner:Int32,_ ambiguous:Bool) {
            let sx=Double(roi.sourceWidth)/Double(s.mapFullWidth),sy=Double(roi.sourceHeight)/Double(s.mapFullHeight)
            for run in c.runs {
                let xa=max(0,min(w,Int(ceil(Double(run.x)*sx-0.5))-expected.x)),xb=max(0,min(w,Int(ceil(Double(run.x+run.count)*sx-0.5))-expected.x))
                let ya=max(0,min(h,Int(ceil(Double(run.y)*sy-0.5))-expected.y)),yb=max(0,min(h,Int(ceil(Double(run.y+1)*sy-0.5))-expected.y))
                guard xb>xa,yb>ya else{continue}
                for y in ya..<yb {for x in xa..<xb {let i=y*w+x
                    if ambiguous{uncertain[i]=1}
                    else if label[i]==0 || label[i]==owner{label[i]=owner}else{label[i] = -1}
                }}
            }
        }
        var invalidForeign:[Source]=[]
        for (i,other) in originals.enumerated() {
            guard let s=other.detectorSeedEvidence,compatible(s) else{if i != anchor{invalidForeign.append(other)};continue}
            for c in s.components{paint(c,s,Int32(i+1),false)}
            for c in (s.ambiguousComponents ?? [])+(s.candidateComponents ?? []).map(\.component){paint(c,s,0,true)}
        }
        var own=[UInt8](repeating:0,count:count),foreign=[UInt8](repeating:0,count:count)
        for i in 0..<count {
            own[i]=label[i]==Int32(anchor+1) && uncertain[i]==0 ? 1:0
            foreign[i]=(label[i] != 0 && label[i] != Int32(anchor+1)) || uncertain[i] != 0 ? 1:0
        }
        for other in invalidForeign {
            guard other.polygon.count==4,other.polygon.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return stop("invalid-foreign-source-polygon")}
            // Integer point coverage mirrors rasterized source raw barriers.
            let q=other.polygon.map{Point(x:($0.x-Double(expected.x)).rounded(.toNearestOrEven),y:($0.y-Double(expected.y)).rounded(.toNearestOrEven))}
            let xa=max(0,min(w,Int(floor(q.map(\.x).min()!)))),xb=max(0,min(w-1,Int(ceil(q.map(\.x).max()!))))
            let ya=max(0,min(h,Int(floor(q.map(\.y).min()!)))),yb=max(0,min(h-1,Int(ceil(q.map(\.y).max()!))))
            if xb>=xa,yb>=ya {for y in ya...yb {for x in xa...xb where contains(q,Double(x),Double(y)){foreign[y*w+x]=1}}}
        }
        // Authenticate association to each actual definite native RLE CC.
        // Pixel labels are only association carriers, never claimed ink masks.
        var componentAtPixel=[Int16](repeating:-1,count:count)
        let sx=Double(roi.sourceWidth)/Double(seed.mapFullWidth),sy=Double(roi.sourceHeight)/Double(seed.mapFullHeight)
        for (ci,c) in seed.components.enumerated() {for run in c.runs {
            let xa=max(0,min(w,Int(ceil(Double(run.x)*sx-0.5))-expected.x)),xb=max(0,min(w,Int(ceil(Double(run.x+run.count)*sx-0.5))-expected.x))
            let ya=max(0,min(h,Int(ceil(Double(run.y)*sy-0.5))-expected.y)),yb=max(0,min(h,Int(ceil(Double(run.y+1)*sy-0.5))-expected.y))
            if xb>xa,yb>ya {for y in ya..<yb {for x in xa..<xb where own[y*w+x] != 0 {
                let i=y*w+x
                if componentAtPixel[i] == -1 || componentAtPixel[i] == Int16(ci){componentAtPixel[i]=Int16(ci)}
                else{componentAtPixel[i] = -2}
            }}}
        }}
        var observed=Array(repeating:[Double.infinity,Double.infinity,-Double.infinity,-Double.infinity],count:seed.components.count)
        var represented=Array(repeating:0,count:seed.components.count)
        var representedIDs=Array(repeating:[Int](),count:seed.components.count)
        func registerRegion(_ boundary:[Int],_ touched:Set<Int>) {
            guard !boundary.isEmpty else{return}
            let points=boundary.map{Point(x:Double(expected.x+$0%w)+0.5,y:Double(expected.y+$0/w)+0.5)}
            let (nl,al,nh,ah)=basis.bounds(points)
            for ci in touched {
                represented[ci]+=1;representedIDs[ci].append(accepted-1);observed[ci][0]=min(observed[ci][0],nl);observed[ci][1]=min(observed[ci][1],al)
                observed[ci][2]=max(observed[ci][2],nh);observed[ci][3]=max(observed[ci][3],ah)
            }
        }
        ownPixels=own.reduce(0){$0+Int($1)}
        guard ownPixels>0 else{return stop("no-certain-source-core-in-ROI")}
        let edges=cannyRGB(roi.bytes,width:w,height:h)
        var visited=[UInt8](repeating:0,count:count),selected=[UInt8](repeating:0,count:count),selectedPoints:[Point]=[]
        let adjacent=[(-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)]
        var queue:[Int]=[]
        for start in 0..<count where edges[start] != 0 && visited[start]==0 {
            queue.removeAll(keepingCapacity:true);queue.append(start);visited[start]=1;var front=0,minx=w,miny=h,maxx=0,maxy=0
            while front<queue.count {let i=queue[front];front+=1;let x=i%w,y=i/w;minx=min(minx,x);maxx=max(maxx,x);miny=min(miny,y);maxy=max(maxy,y)
                for (dx,dy) in adjacent {let xx=x+dx,yy=y+dy;if xx>=0,xx<w,yy>=0,yy<h {let j=yy*w+xx;if edges[j] != 0 && visited[j]==0{visited[j]=1;queue.append(j)}}}
            }
            if minx<=1 || miny<=1 || maxx>=w-2 || maxy>=h-2{borderVeto+=1;continue}
            let bw=maxx-minx+3,bh=maxy-miny+3
            var filled=[UInt8](repeating:0,count:bw*bh)
            for i in queue{filled[(i/w-miny+1)*bw+(i%w-minx+1)]=1}
            // Four-connected complement flood fills only interiors enclosed by
            // the measured eight-connected edge region, never its convex hull.
            var flood=[Int]();flood.reserveCapacity(bw*bh);flood.append(0);filled[0]=2;front=0
            while front<flood.count {let k=flood[front];front+=1;let x=k%bw,y=k/bw
                for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {let xx=x+dx,yy=y+dy;if xx>=0,xx<bw,yy>=0,yy<bh{let j=yy*bw+xx;if filled[j]==0{filled[j]=2;flood.append(j)}}}
            }
            var touchesOwn=false,touchesForeign=false,touched=Set<Int>()
            for y in miny...maxy {for x in minx...maxx where filled[(y-miny+1)*bw+x-minx+1] != 2 {
                let i=y*w+x;if own[i] != 0{touchesOwn=true;if componentAtPixel[i]>=0{touched.insert(Int(componentAtPixel[i]))}};if foreign[i] != 0{touchesForeign=true}
            }}
            if !touchesOwn{continue};if touchesForeign{foreignVeto+=1;continue}
            accepted+=1
            for y in miny...maxy {for x in minx...maxx where filled[(y-miny+1)*bw+x-minx+1] != 2{selected[y*w+x]=1}}
            registerRegion(queue,touched)
            selectedPoints+=queue.map{.init(x:Double(expected.x+$0%w)+0.5,y:Double(expected.y+$0/w)+0.5)}
        }
        // RETR_TREE also has closed hole borders INSIDE an edge component
        // whose external border touches the ROI. A foreground-CC-only flood
        // loses these legitimate inner cycles. Enumerate bounded four-connected
        // complement components and include their adjacent measured edge border.
        var backgroundVisited=[UInt8](repeating:0,count:count)
        for start in 0..<count where edges[start]==0 && backgroundVisited[start]==0 {
            queue.removeAll(keepingCapacity:true);queue.append(start);backgroundVisited[start]=1
            var front=0,touchesFrame=false
            while front<queue.count {
                let i=queue[front];front+=1;let x=i%w,y=i/w
                if x==0 || y==0 || x==w-1 || y==h-1{touchesFrame=true}
                for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let xx=x+dx,yy=y+dy
                    if xx>=0,xx<w,yy>=0,yy<h {let j=yy*w+xx
                        if edges[j]==0 && backgroundVisited[j]==0{backgroundVisited[j]=1;queue.append(j)}
                    }
                }
            }
            if touchesFrame{continue}
            var border=Set<Int>(),touchesOwn=false,touchesForeign=false,touched=Set<Int>()
            for i in queue {
                if own[i] != 0{touchesOwn=true;if componentAtPixel[i]>=0{touched.insert(Int(componentAtPixel[i]))}};if foreign[i] != 0{touchesForeign=true}
                let x=i%w,y=i/w
                for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let xx=x+dx,yy=y+dy
                    if xx>=0,xx<w,yy>=0,yy<h {let j=yy*w+xx;if edges[j] != 0{border.insert(j)}}
                }
            }
            guard !border.isEmpty else{continue}
            var clipped=false
            for i in border {
                let x=i%w,y=i/w
                if x<=1 || y<=1 || x>=w-2 || y>=h-2{clipped=true}
                if own[i] != 0{touchesOwn=true;if componentAtPixel[i]>=0{touched.insert(Int(componentAtPixel[i]))}};if foreign[i] != 0{touchesForeign=true}
            }
            if clipped{borderVeto+=1;continue}
            if !touchesOwn{continue};if touchesForeign{foreignVeto+=1;continue}
            accepted+=1
            for i in queue{selected[i]=1};for i in border{selected[i]=1}
            registerRegion(Array(border),touched)
            selectedPoints+=border.map{.init(x:Double(expected.x+$0%w)+0.5,y:Double(expected.y+$0/w)+0.5)}
        }
        guard accepted>0,!selectedPoints.isEmpty else{return stop("no-source-owned-closed-contour")}
        let covered=own.indices.reduce(0){$0+(own[$1] != 0 && selected[$1] != 0 ? 1:0)}
        let fraction=Double(covered)/Double(ownPixels);coverage=fraction // diagnostic ONLY
        let hn=0.5*(abs(basis.ay)*sx+abs(basis.ax)*sy)
        let ha=0.5*(abs(basis.ax)*sx+abs(basis.ay)*sy)
        for (ci,c) in seed.components.enumerated() {
            var centers:[Point]=[]
            for run in c.runs {
                centers.append(.init(x:(Double(run.x)+0.5)*sx,y:(Double(run.y)+0.5)*sy))
                centers.append(.init(x:(Double(run.x+run.count)-0.5)*sx,y:(Double(run.y)+0.5)*sy))
            }
            let (nl,al,nh,ah)=basis.bounds(centers),span=observed[ci],present=represented[ci]>0
            // One-way required-span containment: an outer real glyph may
            // legitimately exceed its shrunken DB prior. No filled-area ratio.
            let normalOK=present && span[0]<=nl+hn+1e-9 && span[2]>=nh-hn-1e-9
            let alongOK=present && span[1]<=al+ha+1e-9 && span[3]>=ah-ha-1e-9
            spanProofs.append(.init(seed:c.seed,representedClosedRegions:represented[ci],representedClosedRegionIDs:representedIDs[ci],
                detectorCellCenterBounds:[nl,al,nh,ah],observedClosedBoundaryBounds:present ? span:nil,
                projectedHalfCellUncertainty:[hn,ha],normalSpanContained:normalOK,alongSpanContained:alongOK))
        }
        guard spanProofs.allSatisfy({$0.representedClosedRegions>0}) else{return stop("unrepresented-authenticated-CC")}
        guard spanProofs.allSatisfy({$0.normalSpanContained}) else{return stop("incomplete-authenticated-CC-normal-span")}
        guard spanProofs.allSatisfy({$0.alongSpanContained}) else{return stop("incomplete-authenticated-CC-along-span")}
        let (l,t,r,b)=basis.bounds(selectedPoints),(ol,ot,orr,ob)=basis.bounds(original.polygon)
        guard r-l<=2*(orr-ol) else{return stop("normal-envelope-budget")}
        let polygon=[basis.restore(l,t),basis.restore(r,t),basis.restore(r,b),basis.restore(l,b)]
        guard polygon.allSatisfy({$0.x>=0 && $0.y>=0 && $0.x<=Double(roi.sourceWidth) && $0.y<=Double(roi.sourceHeight)}) else{return stop("source-envelope-outside-frame")}
        let c=Candidate(anchorSourceIndex:anchor,sourceParent:anchor,seedParentBoxIndex:seed.parentBoxIndex,sourceMembers:[anchor],ownerID:seed.ownerID,definiteSeeds:seed.components.map(\.seed),sourceDigest:seed.sourceProbabilityROI?.sourceDigest,sourceGrid:[seed.mapFullWidth,seed.mapFullHeight],polygon:polygon,originalPolygon:original.polygon,normalSpanBefore:orr-ol,normalSpanAfter:r-l,alongSpanBefore:ob-ot,alongSpanAfter:b-t,sourceOwnedCoverage:fraction,sourceOwnedPixels:ownPixels,acceptedEdgeRegions:accepted,nativeSeedPacketUnchanged:true,recognitionIndependent:true,componentSpans:spanProofs,admissionPolicy:"per-authenticated-CC-representation-and-required-span-containment-v1")
        return stop("closed-source-contour-envelope",c)
    }
    private static func contains(_ q:[Point],_ x:Double,_ y:Double)->Bool {
        var pos=false,neg=false
        for i in q.indices {let a=q[i],b=q[(i+1)%q.count];let d=(b.x-a.x)*(y-a.y)-(b.y-a.y)*(x-a.x);if d>1e-6{pos=true};if d < -1e-6{neg=true}}
        return !(pos && neg)
    }

    /// OpenCV-compatible aperture3 Sobel, L2 NMS and8-neighbour hysteresis.
    /// No blur, training parameters or colour/text statistics are used.
    static func cannyRGB(_ bytes:[UInt8],width w:Int,height h:Int)->[UInt8] {
        guard w>0,h>0,bytes.count==w*h*3 else{return []}
        let count=w*h;var output=[UInt8](repeating:0,count:count)
        for channel in 0..<3 {
            var dx=[Int32](repeating:0,count:count),dy=dx,mag=[Int32](repeating:0,count:count)
            func v(_ x:Int,_ y:Int)->Int32{Int32(bytes[(min(h-1,max(0,y))*w+min(w-1,max(0,x)))*3+channel])}
            for y in 0..<h {for x in 0..<w {let i=y*w+x
                let gx = -v(x-1,y-1)+v(x+1,y-1)-2*v(x-1,y)+2*v(x+1,y)-v(x-1,y+1)+v(x+1,y+1)
                let gy = -v(x-1,y-1)-2*v(x,y-1)-v(x+1,y-1)+v(x-1,y+1)+2*v(x,y+1)+v(x+1,y+1)
                dx[i]=gx;dy[i]=gy;mag[i]=gx*gx+gy*gy
            }}
            func m(_ x:Int,_ y:Int)->Int32{x>=0 && x<w && y>=0 && y<h ? mag[y*w+x]:0}
            var state=[UInt8](repeating:0,count:count),queue:[Int]=[]
            for y in 0..<h {for x in 0..<w {let i=y*w+x,mm=mag[i];guard mm>48*48 else{continue}
                let xx=Int(abs(dx[i])),yy=Int(abs(dy[i]))<<15,tg22=xx*13573
                let peak:Bool
                if yy<tg22 {peak=mm>m(x-1,y) && mm>=m(x+1,y)}
                else if yy>tg22+(xx<<16){peak=mm>m(x,y-1) && mm>=m(x,y+1)}
                else {let s=(dx[i]^dy[i])<0 ? -1:1;peak=mm>m(x-s,y-1) && mm>m(x+s,y+1)}
                if peak {state[i]=1;if mm>96*96{state[i]=2;queue.append(i)}}
            }}
            var front=0
            while front<queue.count {let i=queue[front];front+=1;let x=i%w,y=i/w
                for yy in max(0,y-1)...min(h-1,y+1) {for xx in max(0,x-1)...min(w-1,x+1){let j=yy*w+xx;if state[j]==1{state[j]=2;queue.append(j)}}}
            }
            for i in 0..<count where state[i]==2{output[i]=1}
        }
        return output
    }
}
