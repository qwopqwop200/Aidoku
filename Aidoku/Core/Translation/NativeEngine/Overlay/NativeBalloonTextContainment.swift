import CoreGraphics
import Foundation

/// Final speech-balloon containment operates on leaf Range rectangles and the
/// planner's measured paper bands; plate ownership remains a separate policy.
enum NativeBalloonTextContainment {
    struct Entry {
        var geometry: NativeTranslationFinalGeometry.Entry
        let balloonRect: [CGFloat]
        let spans: [Double]
        let center: [CGFloat]?
        var contourVerified = true
        var horizontalTransform = true
        var horizontalWriting = true
        var parentBox: CGRect?
        var hasPlates = false
        var covers: [CGRect] = []
        var fit: [Double]?
        var rejected = false
    }
    typealias Reshape = (NativeTranslationFinalGeometry.Entry, _ font: Double, _ pitch: Double) -> [CGRect]?
    static func contain(_ input: [Entry], itemCount: Int? = nil, reshape: Reshape) -> [Entry] {
        guard (itemCount ?? input.count) <= 256 else {return input}
        var entries=input,checks=131_072
        func leaf(_ boxes:[CGRect])->[CGRect] {
            let boxes=boxes.filter {$0.width>0 && $0.height>0}
            return boxes.enumerated().filter {i,r in !boxes.enumerated().contains {j,o in i != j && r.height>o.height*1.65 && o.minX>=r.minX-0.05 && o.maxX<=r.maxX+0.05 && o.minY>=r.minY-0.05 && o.maxY<=r.maxY+0.05 && o.height<r.height-0.1}}.map(\.element)
        }
        for i in entries.indices {entries[i].geometry.lines=leaf(entries[i].geometry.lines)}
        for i in entries.indices {
            let e=entries[i],g=e.geometry,f=g.frame,b=e.balloonRect,s=e.spans
            guard e.contourVerified,g.originalRotation==0,!g.vertical,!g.keepsSource,g.visible,e.horizontalTransform,e.horizontalWriting,
                  b.count==4,b.allSatisfy(\.isFinite),s.count>=4,s.count<=1024,s.count.isMultiple(of:2),s.allSatisfy(\.isFinite) else {continue}
            let top=f.minY+b[1]*f.height,height=b[3]*f.height,bands=s.count/2
            guard height>0 else {continue}
            let pad=0.5+g.stroke/2
            func allowance(_ rects:[CGRect],_ dy:CGFloat)->[CGFloat]? {
                if rects.count>256 {return nil};var low = -CGFloat.infinity,high=CGFloat.infinity
                for r in rects {
                    let y0=r.minY+dy-pad,y1=r.maxY+dy+pad
                    if y0<top || y1>top+height {return nil}
                    let first=max(0,Int(floor((y0-top)/height*CGFloat(bands)))),last=min(bands-1,Int(ceil((y1-top)/height*CGFloat(bands)))-1)
                    if first<=last {for row in first...last {
                        checks-=1;if checks<0 || s[row*2]<0 || s[row*2+1]<=s[row*2] {return nil}
                        low=max(low,f.minX+s[row*2]*f.width+pad-r.minX)
                        high=min(high,f.minX+s[row*2+1]*f.width-pad-r.maxX)
                    }}
                };return low<=high ? [low,high]:nil
            }
            let initial=g.lines,room=allowance(initial,0)
            if initial.isEmpty {continue}
            let already=room.map {$0[0]<=0 && $0[1]>=0} ?? false
            let center=e.center.flatMap {$0.count==2 && $0.allSatisfy(\.isFinite) ? $0:nil} ?? [b[0]+b[2]/2,b[1]+b[3]/2]
            let target=CGPoint(x:f.minX+center[0]*f.width,y:f.minY+center[1]*f.height)
            func midpoint(_ rects:[CGRect])->CGPoint {CGPoint(x:(rects.map(\.minX).min()!+rects.map(\.maxX).max()!)/2,y:(rects.map(\.minY).min()!+rects.map(\.maxY).max()!)/2)}
            let original=midpoint(initial),distance=hypot(target.x-original.x,target.y-original.y)
            if already && distance<0.75 {continue}
            let size=g.font,pitch=g.pitch/size
            guard size>0,pitch>0 else {continue}
            let foreign=entries.indices.filter {$0 != i && entries[$0].geometry.visible}.flatMap {entries[$0].geometry.lines}
            func hit(_ a:CGRect,_ b:CGRect)->Bool {a.minX<b.maxX && b.minX<a.maxX && a.minY<b.maxY && b.minY<a.maxY}
            let oldHits=foreign.filter {r in initial.contains {hit($0,r)}}.count
            let verticalLimit=already ? min(24,max(8,height*0.22)):min(48,max(12,height*0.5))
            let horizontalLimit=already ? verticalLimit:min(160,max(24,abs(target.x-original.x)+4))
            let preferred=max(-verticalLimit,min(verticalLimit,target.y-original.y))
            var steps=[preferred],d:CGFloat=2
            while d<=verticalLimit {steps += [preferred-d,preferred+d];d+=2};steps.append(0)
            var unique:[CGFloat]=[]
            for dy in steps where abs(dy)<=verticalLimit && !unique.contains(dy) {unique.append(dy)}
            var accepted=false
            for step in 0...(already ? 0:6) {
                if accepted {break};let next=size-Double(step)*0.25
                if next<min(size,max(5,size*0.85)) {break}
                guard let shaped=reshape(g,next,next*pitch) else {continue}
                let rects=leaf(shaped);if rects.isEmpty {continue}
                let desired=target.x-midpoint(rects).x
                for dy in unique {
                    guard let room=allowance(rects,dy) else {continue}
                    let dx=max(room[0],min(room[1],desired));if abs(dx)>horizontalLimit {continue}
                    let moved=rects.map {$0.offsetBy(dx:dx,dy:dy)}
                    if foreign.filter({r in moved.contains {hit($0,r)}}).count>oldHits {continue}
                    if let parent=e.parentBox,moved.contains(where:{$0.minX-pad<parent.minX || $0.maxX+pad>parent.maxX || $0.minY-pad<parent.minY || $0.maxY+pad>parent.maxY}) {continue}
                    if e.hasPlates && (e.covers.isEmpty || moved.contains(where:{r in !e.covers.contains {r.minX-pad >= $0.minX-0.05 && r.minY-pad >= $0.minY-0.05 && r.maxX+pad <= $0.maxX+0.05 && r.maxY+pad <= $0.maxY+0.05}})) {continue}
                    let actual=allowance(moved,0),center=midpoint(moved)
                    let closer = !already || hypot(target.x-center.x,target.y-center.y)<distance-0.1
                    if closer,let actual,actual[0]<=0.05,actual[1]>=(-0.05) {
                        entries[i].geometry.lines=moved;entries[i].geometry.font=next;entries[i].geometry.pitch=next*pitch
                        entries[i].geometry.shift.x+=dx;entries[i].geometry.shift.y+=dy
                        entries[i].fit=[Double(dx),Double(dy),size,next];accepted=true;break
                    }
                }
            }
            if !accepted && !already {entries[i].rejected=true}
        }
        return entries
    }
}
