import CoreGraphics
import Foundation

/// Pure frozen6717–7176 source certificate transport. These helpers do not
/// place translated text or infer erasure from a successful typography trial.
enum NativeEarlyMarginPixels {
    struct Geometry {
        var frame:CGRect
        var imageSize:CGSize
        var origin:CGPoint
        var scale:CGSize
    }
    struct Canvas {
        var id:String
        var width:Int
        var height:Int
        var rgba:[UInt8]
        var safe:[UInt8]
        var luminance:[UInt8]
        var geometry:Geometry
        var erasureComplete = false
        var erasureVerified = false
        var connected = true
        var rootOwned = true
        var provisional = false
    }
    struct Exterior {
        var safe:[UInt8]
        var ignored:Int
        var components:Int
    }
    struct Group {
        var safe:[UInt8]
        var luminance:[UInt8]
        var added:Int
    }
    final class Budget {
        var certification = 524_288
        var exterior:Int
        var groupPixels:[String:[UInt8]] = [:]
        init(artworkSurfaceRemaining:Int) { exterior = max(0,min(262_144,artworkSurfaceRemaining)) }
    }
    private static func valid(_ c:Canvas)->Bool {
        c.width>0 && c.height>0 && c.width<=262_144/c.height && c.safe.count==c.width*c.height &&
        c.rgba.count==c.width*c.height*4 && c.luminance.count==c.width*c.height
    }
    /// Frozen6736–6792 labels boundary barriers and certifies only exterior
    /// unsafe islands disconnected from every owned source cell.
    static func exterior(_ c:Canvas,core:[[Double]],glyph:Double,budget:Budget)->Exterior? {
        guard c.erasureVerified,c.erasureComplete,valid(c) else { return nil }
        let w=c.width,h=c.height,n=w*h,limit=max(12,glyph*2)
        struct Part { var label:Int;var left:Int;var top:Int;var right:Int;var bottom:Int;var count:Int;var barrier:Bool;var points:[Int]? }
        var labels=[Int](repeating:0,count:n),queue=[Int](repeating:0,count:n),parts:[Part]=[],residual:[Int]=[]
        for start in 0..<n where c.safe[start]==0 && labels[start]==0 {
            let label=parts.count+1;var head=0,tail=1,l=w,t=h,r=0,b=0,edge=false
            queue[0]=start;labels[start]=label
            while head<tail {
                let i=queue[head],x=i%w,y=i/w;head+=1;l=min(l,x);r=max(r,x);t=min(t,y);b=max(b,y)
                edge = edge || x==0 || y==0 || x==w-1 || y==h-1
                for yy in max(0,y-1)...min(h-1,y+1) { for xx in max(0,x-1)...min(w-1,x+1) {
                    let j=yy*w+xx;if c.safe[j]==0 && labels[j]==0 { labels[j]=label;queue[tail]=j;tail+=1 }
                } }
            }
            let span=max(r-l+1,b-t+1)
            var part=Part(label:label,left:l,top:t,right:r,bottom:b,count:tail,barrier:edge && Double(span)>limit && Double(tail)>=glyph*2)
            if tail>=2 && Double(span)<=limit && core.contains(where: { q in Double(r)>=q[0]-glyph && Double(l)<=q[0]+q[2]+glyph && Double(b)>=q[1]-glyph && Double(t)<=q[1]+q[3]+glyph }) {
                part.points=Array(queue.prefix(tail));residual.append(parts.count)
            }
            parts.append(part)
        }
        guard !residual.isEmpty else { return nil }
        let barriers=Set(parts.filter(\.barrier).map(\.label));guard !barriers.isEmpty else { return nil }
        var reachable=[UInt8](repeating:0,count:n),head=0,tail=0
        for q in core {
            let l=max(0,Int(floor(q[0]))),t=max(0,Int(floor(q[1]))),r=min(w,Int(ceil(q[0]+q[2]))),b=min(h,Int(ceil(q[1]+q[3])))
            if l>=r || t>=b { continue }
            for y in t..<b { for x in l..<r {
                if budget.exterior<1 { return nil };budget.exterior-=1
                let i=y*w+x;if reachable[i]==0 && !barriers.contains(labels[i]) { reachable[i]=1;queue[tail]=i;tail+=1 }
            } }
        }
        guard tail>0 else { return nil }
        while head<tail {
            if budget.exterior<1 { return nil };budget.exterior-=1
            let i=queue[head],x=i%w,y=i/w;head+=1
            for yy in max(0,y-1)...min(h-1,y+1) { for xx in max(0,x-1)...min(w-1,x+1) {
                let j=yy*w+xx;if reachable[j]==0 && !barriers.contains(labels[j]) { reachable[j]=1;queue[tail]=j;tail+=1 }
            } }
        }
        var filtered=c.safe,ignored=0
        for index in residual {
            let part=parts[index],points=part.points!
            if points.contains(where:{ i in
                let x=Double(i%w),y=Double(i/w)
                return reachable[i] != 0 || core.contains { q in x>=floor(q[0]) && x<ceil(q[0]+q[2]) && y>=floor(q[1]) && y<ceil(q[1]+q[3]) }
            }) { return nil }
            for i in points { filtered[i]=1 };ignored+=points.count
        }
        return ignored>0 ? .init(safe:filtered,ignored:ignored,components:residual.count):nil
    }
    /// Frozen6847–6911. A later nonopaque/unowned donor invalidates a prior
    /// inherited proof; original safe cells are never reconsidered.
    static func reconcile(_ c:Canvas,donors:[Canvas],budget:Budget)->Group? {
        guard valid(c) else { return nil }
        struct Donor { let canvas:Canvas;let left:Int;let top:Int;let right:Int;let bottom:Int }
        let g=c.geometry;var work=c.width*c.height,candidates:[Donor]=[]
        for d in donors where !d.provisional && d.connected && d.rootOwned && valid(d) {
            let k=d.geometry
            let left=Double(k.frame.minX)+Double(k.origin.x)/Double(k.imageSize.width)*Double(k.frame.width)
            let top=Double(k.frame.minY)+Double(k.origin.y)/Double(k.imageSize.height)*Double(k.frame.height)
            let right=left+Double(d.width)/Double(k.scale.width)/Double(k.imageSize.width)*Double(k.frame.width)
            let bottom=top+Double(d.height)/Double(k.scale.height)/Double(k.imageSize.height)*Double(k.frame.height)
            let l=max(0,Int(floor(((left-Double(g.frame.minX))*Double(g.imageSize.width)/Double(g.frame.width)-Double(g.origin.x))*Double(g.scale.width))))
            let t=max(0,Int(floor(((top-Double(g.frame.minY))*Double(g.imageSize.height)/Double(g.frame.height)-Double(g.origin.y))*Double(g.scale.height))))
            let r=min(c.width,Int(ceil(((right-Double(g.frame.minX))*Double(g.imageSize.width)/Double(g.frame.width)-Double(g.origin.x))*Double(g.scale.width))))
            let b=min(c.height,Int(ceil(((bottom-Double(g.frame.minY))*Double(g.imageSize.height)/Double(g.frame.height)-Double(g.origin.y))*Double(g.scale.height))))
            if l>=r || t>=b { continue }
            work+=(r-l)*(b-t)+(budget.groupPixels[d.id]==nil ? d.width*d.height:0)
            candidates.append(.init(canvas:d,left:l,top:t,right:r,bottom:b))
        }
        guard candidates.count>=2,work<=budget.certification else { return nil };budget.certification-=work
        for candidate in candidates where budget.groupPixels[candidate.canvas.id]==nil { budget.groupPixels[candidate.canvas.id]=candidate.canvas.rgba }
        var safe=c.safe,luminance=c.luminance
        func linear(_ v:Double)->Double { let v=v/255;return v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4) }
        for part in candidates {
            let d=part.canvas,k=d.geometry,rgba=budget.groupPixels[d.id]!
            for y in part.top..<part.bottom { for x in part.left..<part.right {
                let i=y*c.width+x;if c.safe[i] != 0 { continue }
                let px=Double(g.frame.minX)+(Double(g.origin.x)+(Double(x)+0.5)/Double(g.scale.width))/Double(g.imageSize.width)*Double(g.frame.width)
                let py=Double(g.frame.minY)+(Double(g.origin.y)+(Double(y)+0.5)/Double(g.scale.height))/Double(g.imageSize.height)*Double(g.frame.height)
                let u=((px-Double(k.frame.minX))*Double(k.imageSize.width)/Double(k.frame.width)-Double(k.origin.x))*Double(k.scale.width)-0.5
                let v=((py-Double(k.frame.minY))*Double(k.imageSize.height)/Double(k.frame.height)-Double(k.origin.y))*Double(k.scale.height)-0.5
                let xx=Int(floor(u)),yy=Int(floor(v));if xx<0 || yy<0 || xx+1>=d.width || yy+1>=d.height { continue }
                let cells=[yy*d.width+xx,yy*d.width+xx+1,(yy+1)*d.width+xx,(yy+1)*d.width+xx+1]
                if cells.allSatisfy({ rgba[$0*4+3]==0 }) { continue }
                safe[i]=0
                if d.id==c.id || !d.erasureComplete || !cells.allSatisfy({ rgba[$0*4+3]==255 && d.safe[$0] != 0 }) { continue }
                let fx=u-Double(xx),fy=v-Double(yy),weights=[(1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy]
                let rgb=(0..<3).map { channel in floor(cells.enumerated().reduce(0.0) { $0+Double(rgba[$1.element*4+channel])*weights[$1.offset] }+0.5) }
                safe[i]=1;luminance[i]=UInt8(floor(255*(0.2126*linear(rgb[0])+0.7152*linear(rgb[1])+0.0722*linear(rgb[2]))+0.5))
            } }
        }
        let added=c.safe.indices.reduce(0) { $0+(c.safe[$1]==0 && safe[$1] != 0 ? 1:0) }
        return added>0 ? .init(safe:safe,luminance:luminance,added:added):nil
    }
}
