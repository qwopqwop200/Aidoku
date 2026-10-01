import CoreGraphics
import Foundation

/// Bounded source-paper observation used when the OCR planner did not provide
/// a verified native contour. Its topology and query raster match the final pass.
final class NativeBalloonInteriorEstimator {
    private(set) var remainingPixels: Int
    init(pixelBudget: Int = 3_000_000) { remainingPixels = pixelBudget }
    typealias Reader = (CGRect, _ width: Int, _ height: Int) -> [UInt8]?

    func estimate(sourceRects own: [CGRect], unitMemberCount: Int = 0, sourceUnion: CGRect? = nil,
                  frame: CGRect, sourceFontSize: Double? = nil, reader: Reader) -> NativeBalloonRelayout.Interior? {
        guard let source = own.first, source.width >= 2, source.height >= 2 else { return nil }
        let members = unitMemberCount > 0 ? Array(own.prefix(unitMemberCount)) : nil
        let union = members != nil ? sourceUnion ?? source : source
        let ext = max(3 * max(union.width,union.height),27)
        let left = max(frame.minX,union.minX-ext), top = max(frame.minY,union.minY-ext)
        let right = min(frame.maxX,union.maxX+ext), bottom = min(frame.maxY,union.maxY+ext)
        guard right > left, bottom > top else { return nil }
        let areaRect = CGRect(x:left,y:top,width:right-left,height:bottom-top)
        let k = min(2,sqrt(250_000 / max(1,Double((right-left)*(bottom-top)))))
        let w = Int(ceil(Double(right-left)*k)), h = Int(ceil(Double(bottom-top)*k))
        guard w >= 8, h >= 8, w*h <= remainingPixels else { return nil }
        remainingPixels -= w*h
        guard let rgba = reader(areaRect,w,h), rgba.count == w*h*4 else { return nil }
        let bx0 = max(0,Int(floor(Double(source.minX-left)*k))), by0 = max(0,Int(floor(Double(source.minY-top)*k)))
        let bx1 = min(w,max(bx0+1,Int(ceil(Double(source.maxX-left)*k)))), by1 = min(h,max(by0+1,Int(ceil(Double(source.maxY-top)*k))))
        let boxArea = (bx1-bx0)*(by1-by0)
        guard bx0 < bx1, by0 < by1 else { return nil }
        var bins=[Int](repeating:0,count:32)
        for y in by0..<by1 { for x in bx0..<bx1 {let at=(y*w+x)*4;bins[min(31,(Int(rgba[at])+Int(rgba[at+1])+Int(rgba[at+2]))/24)]+=1} }
        let mode = bins.firstIndex(of:bins.max()!)!
        var counts=[Int](repeating:0,count:768),nearMode=0
        for y in by0..<by1 {for x in bx0..<bx1 {
            let at=(y*w+x)*4,average=Double(Int(rgba[at])+Int(rgba[at+1])+Int(rgba[at+2]))/3
            if abs(average-Double(mode*8+4)) <= 24 {
                for c in 0..<3 {counts[c*256+Int(rgba[at+c])]+=1};nearMode+=1
            }
        }}
        guard Double(nearMode) >= Double(boxArea)*0.3 else {return nil}
        var paper=[Double](repeating:0,count:3)
        for c in 0..<3 {var seen=0;for v in 0..<256 {seen+=counts[c*256+v];if seen > nearMode >> 1 {paper[c]=Double(v);break}}}
        guard paper.min()! >= 170, paper.max()!-paper.min()! <= 48 else {return nil}
        let n=w*h
        var surface=[UInt8](repeating:0,count:n)
        for i in 0..<n {if (0..<3).allSatisfy({abs(Double(rgba[i*4+$0])-paper[$0])<=48}) {surface[i]=1}}
        let glyph=sourceFontSize.flatMap {$0>0 ? $0:nil} ?? Double(min(source.width,source.height))
        let margin=max(2,Int(floor(glyph*0.25*k+0.5)))
        var passable=surface,seen=[UInt8](repeating:0,count:n),queue=[Int](repeating:0,count:n)
        for member in members ?? [source] {
            let mx0=max(0,Int(floor(Double(member.minX-left)*k))-margin),my0=max(0,Int(floor(Double(member.minY-top)*k))-margin)
            let mx1=min(w,Int(ceil(Double(member.maxX-left)*k))+margin),my1=min(h,Int(ceil(Double(member.maxY-top)*k))+margin)
            if mx0>=mx1 || my0>=my1 {continue}
            for y in my0..<my1 {for x in mx0..<mx1 {
                let s=y*w+x;if surface[s] != 0 || seen[s] != 0 {continue}
                var read=0,length=1,inside=true;seen[s]=1;queue[0]=s
                while read<length {
                    let v=queue[read],vx=v%w,vy=v/w;read+=1
                    for dy in -1...1 {for dx in -1...1 {
                        let nx=vx+dx,ny=vy+dy;if nx<0 || ny<0 || nx>=w || ny>=h {continue}
                        let q=ny*w+nx;if surface[q] != 0 {continue}
                        if nx<mx0 || nx>=mx1 || ny<my0 || ny>=my1 {inside=false;continue}
                        if seen[q]==0 {seen[q]=1;queue[length]=q;length+=1}
                    }}
                }
                if inside {for i in 0..<length {passable[queue[i]]=1}}
            }}
        }
        var open=[UInt8](repeating:0,count:n)
        for y in 0..<h {for x in 0..<w {
            let s=y*w+x;if passable[s]==0 {continue}
            if x>=bx0 && x<bx1 && y>=by0 && y<by1 {open[s]=1;continue}
            if (x==0 || passable[s-1] != 0) && (x==w-1 || passable[s+1] != 0) &&
                (y==0 || passable[s-w] != 0) && (y==h-1 || passable[s+w] != 0) {open[s]=1}
        }}
        var labels=[Int](repeating:0,count:n),components=0,best=0,bestCount=0,keep=Set<Int>()
        for y in by0..<by1 {for x in bx0..<bx1 {
            let s=y*w+x;if open[s]==0 || labels[s] != 0 {continue}
            components+=1;var read=0,length=1,inBox=0;labels[s]=components;queue[0]=s
            while read<length {
                let v=queue[read],vx=v%w,vy=v/w;read+=1
                if vx>=bx0 && vx<bx1 && vy>=by0 && vy<by1 {inBox+=1}
                var neighbors:[Int]=[];if vx>0 {neighbors.append(v-1)};if vx<w-1 {neighbors.append(v+1)};if vy>0 {neighbors.append(v-w)};if vy<h-1 {neighbors.append(v+w)}
                for q in neighbors where open[q] != 0 && labels[q]==0 {labels[q]=components;queue[length]=q;length+=1}
            }
            if Double(inBox)>=Double(boxArea)*0.08 {keep.insert(components)}
            if inBox>bestCount {bestCount=inBox;best=components}
        }}
        guard components>0 else {return nil};if keep.isEmpty {keep.insert(best)}
        var fill=labels.map {keep.contains($0) ? UInt8(1):0}
        func innerSide(_ x:Int,_ y:Int)->Bool {x==0 && left>frame.minX+0.5 || x==w-1 && right<frame.maxX-0.5 || y==0 && top>frame.minY+0.5 || y==h-1 && bottom<frame.maxY-0.5}
        for x in 0..<w {if fill[x] != 0 && innerSide(x,0) || fill[(h-1)*w+x] != 0 && innerSide(x,h-1) {return nil}}
        for y in 0..<h {if fill[y*w] != 0 && innerSide(0,y) || fill[y*w+w-1] != 0 && innerSide(w-1,y) {return nil}}
        var outside=[UInt8](repeating:0,count:n),read=0,length=0
        for x in 0..<w {for y in [0,h-1] {let s=y*w+x;if fill[s]==0 && outside[s]==0 {outside[s]=1;queue[length]=s;length+=1}}}
        for y in 0..<h {for x in [0,w-1] {let s=y*w+x;if fill[s]==0 && outside[s]==0 {outside[s]=1;queue[length]=s;length+=1}}}
        while read<length {
            let v=queue[read],vx=v%w,vy=v/w;read+=1
            var neighbors:[Int]=[];if vx>0 {neighbors.append(v-1)};if vx<w-1 {neighbors.append(v+1)};if vy>0 {neighbors.append(v-w)};if vy<h-1 {neighbors.append(v+w)}
            for q in neighbors where fill[q]==0 && outside[q]==0 {outside[q]=1;queue[length]=q;length+=1}
        }
        var area=0,covered=0,pageEdge=0,rowMin=[Int](repeating:-1,count:h),rowMax=[Int](repeating:-1,count:h)
        for y in 0..<h {for x in 0..<w {
            let s=y*w+x;if outside[s] != 0 {continue};fill[s]=1;area+=1
            if x>=bx0 && x<bx1 && y>=by0 && y<by1 {covered+=1}
            if rowMin[y]<0 {rowMin[y]=x};rowMax[y]=x
            if x==0 || x==w-1 || y==0 || y==h-1 {pageEdge+=1}
        }}
        guard Double(pageEdge)<=Double(w+h)*0.12,Double(area)>=Double(boxArea)*1.2,Double(covered)>=Double(boxArea)*0.9 else {return nil}
        let reference=members != nil ? Double(union.width*union.height)*k*k:Double(boxArea)
        let tight=Double(area)<reference*1.8
        var points:[CGPoint]=[]
        for y in 0..<h where rowMin[y]>=0 {points += [CGPoint(x:rowMin[y],y:y),CGPoint(x:rowMin[y],y:y+1),CGPoint(x:rowMax[y]+1,y:y),CGPoint(x:rowMax[y]+1,y:y+1)]}
        points.sort {$0.x==$1.x ? $0.y<$1.y:$0.x<$1.x}
        func cross(_ o:CGPoint,_ a:CGPoint,_ b:CGPoint)->CGFloat {(a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x)}
        func hull(_ points:[CGPoint])->[CGPoint] {var chain:[CGPoint]=[];for q in points {while chain.count>=2 && cross(chain[chain.count-2],chain.last!,q)<=0 {chain.removeLast()};chain.append(q)};return chain}
        let polygon=Array(hull(points).dropLast())+Array(hull(points.reversed()).dropLast())
        var hullArea:CGFloat=0
        for i in polygon.indices {let a=polygon[i],b=polygon[(i+1)%polygon.count];hullArea+=a.x*b.y-b.x*a.y}
        guard Double(area)>=Double(abs(hullArea)/2)*0.8 else {return nil}
        var integral=[Int](repeating:0,count:(w+1)*(h+1))
        for y in 0..<h {var run=0;for x in 0..<w {run+=Int(fill[y*w+x]);integral[(y+1)*(w+1)+x+1]=integral[y*(w+1)+x+1]+run}}
        return .init(rect:areaRect,scale:k,width:w,height:h,fill:fill,surfaceRGB:paper,tight:tight,integral:integral)
    }
}
