import CoreGraphics
import Foundation

/// Frozen late pixel-aware source-side/fringe plate trim14350–14596. Earlier
/// compact-panel policies retain their own independent source requirements.
enum NativeLatePlateTrim {
    struct Source {
        var id:String
        var bounds:[Double]
        var auxiliary:[[Double]] = []
        var font:Double?
        var vertical = false
        var rotation = 0.0
    }
    struct Caption {
        var ink:CGRect
        var font:Double
        var visible = true
        var transformed = false
        var displayCardGrowth = false
        var sampledForeground:[Double]?
        var sampledStroke:[Double]?
        var outlined:[String:Any]?
        var sample:[String:Any] = [:]
    }
    struct Plate {
        var rect:CGRect
        var coverage:[CGRect]?
        var background:[Double]?
        var rootParent = true
        var sourceErasure = false
        var sourcePreservedCaption = false
        var transformed = false
        var displayed = true
        var visible = true
        var hasBackgroundImage = false
        var hasBacking = false
        var otherChildren = false
        var clipped = false
    }
    struct Scene {
        var opacity = 1.0
        var preserveSourceBackground = true
        var itemCount:Int
        var frame:CGRect
        var imageSize:CGSize
        var imageComplete = true
    }
    final class Budget { var samples = 1_048_576 }
    struct Proposal {
        var rect:CGRect
        var coverage:[CGRect]?
        var clipped:Bool
        var oldArea:Int
        var newArea:Int
    }
    struct Validation { var ink:CGRect; var fits:Bool; var clipSupported = true }
    private struct Pads {
        var left:Double; var top:Double; var right:Double; var bottom:Double
        init(_ even:Double) { left = even;top = even;right = even;bottom = even }
        init(left:Double,top:Double,right:Double,bottom:Double) { self.left=left;self.top=top;self.right=right;self.bottom=bottom }
        subscript(_ key:Int) -> Double {
            get { [left,top,right,bottom][key] }
            set { switch key { case 0:left=newValue;case 1:top=newValue;case 2:right=newValue;default:bottom=newValue } }
        }
    }
    private struct Box {
        var left:Double;var top:Double;var right:Double;var bottom:Double
        init(_ r:CGRect) { left=Double(r.minX);top=Double(r.minY);right=Double(r.maxX);bottom=Double(r.maxY) }
        init(_ l:Double,_ t:Double,_ r:Double,_ b:Double) { left=l;top=t;right=r;bottom=b }
        var rect:CGRect { .init(x:left,y:top,width:right-left,height:bottom-top) }
        var empty:Bool { right-left <= 0.25 || bottom-top <= 0.25 }
        var area:Double { max(0,right-left)*max(0,bottom-top) }
        func grow(_ p:Pads) -> Self { .init(left-p.left,top-p.top,right+p.right,bottom+p.bottom) }
        func meet(_ r:Self) -> Self { .init(max(left,r.left),max(top,r.top),min(right,r.right),min(bottom,r.bottom)) }
    }
    private static func valid(_ values:[Double]) -> Bool { values.count == 4 && values.allSatisfy(\.isFinite) && values[2] > 0 && values[3] > 0 }
    private static func colours(_ value:Any?) -> [Double]? {
        guard let values = value as? [NSNumber],values.count >= 3 else { return nil }
        let rgb=values.prefix(3).map(\.doubleValue);return rgb.allSatisfy(\.isFinite) ? rgb:nil
    }
    private static func gap(_ a:[Double],_ b:[Double]) -> Double { max(abs(a[0]-b[0]),abs(a[1]-b[1]),abs(a[2]-b[2])) }
    private static func number(_ value:Double,fallback:Double=10) -> Double { value == 0 || value.isNaN ? fallback:value }
    static func trim(source:Source,caption:Caption,plate:Plate,scene:Scene,budget:Budget,
                     otherSources:[Source],otherCaptionInks:[CGRect],restoration:CGRect?,
                     readSource:(_ crop:CGRect,_ width:Int,_ height:Int)throws->[UInt8],
                     validate:(Proposal)->Validation) -> Proposal? {
        guard scene.opacity == 1,scene.preserveSourceBackground,scene.itemCount <= 256,
              [scene.frame.minX,scene.frame.minY,scene.frame.width,scene.frame.height].allSatisfy(\.isFinite),scene.frame.width > 0,scene.frame.height > 0,
              source.rotation == 0,plate.rootParent,!plate.sourceErasure,!plate.sourcePreservedCaption,!plate.transformed,
              plate.displayed,plate.visible,!plate.hasBackgroundImage,!plate.hasBacking,!plate.otherChildren,
              caption.visible,!caption.transformed,!caption.displayCardGrowth else { return nil }
        if plate.coverage == nil && plate.clipped { return nil }
        let coverage = plate.coverage?.filter { valid([Double($0.minX),Double($0.minY),Double($0.width),Double($0.height)]) }
        if let coverage,coverage.isEmpty { return nil }
        let old=Box(plate.rect),ink=Box(caption.ink),frame=Box(scene.frame)
        guard !old.empty,!ink.empty else { return nil }
        let size=number(caption.font),pad=max(3,min(6,size*0.3)),glyph=source.font.flatMap { $0.isFinite && $0 > 0 ? $0:nil } ?? pad
        let fringe=max(0,min(16,glyph)-pad)
        func sourceBox(_ b:[Double]) -> Box { .init(frame.left+b[0]*Double(scene.frame.width),frame.top+b[1]*Double(scene.frame.height),frame.left+(b[0]+b[2])*Double(scene.frame.width),frame.top+(b[1]+b[3])*Double(scene.frame.height)) }
        let ownBoxes=([source.bounds]+source.auxiliary).filter(valid).map(sourceBox)
        var required=[ink.grow(Pads(pad))],others:[Box]=[]
        for other in otherSources where other.id != source.id {
            let cross=max(3,min(16,other.font.flatMap { $0.isFinite ? $0:nil } ?? 3))
            for b in ([other.bounds]+other.auxiliary).filter(valid) {
                let r=sourceBox(b)
                if r.left>old.right || r.right<old.left || r.top>old.bottom || r.bottom<old.top { continue }
                others.append(r.grow(other.vertical ? .init(left:cross,top:3,right:cross,bottom:3):.init(left:3,top:cross,right:3,bottom:cross)))
            }
        }
        others += otherCaptionInks.map(Box.init).filter { !$0.empty }.map { $0.grow(Pads(2)) }
        func bounding(_ rects:[Box]) -> Box? {
            let kept=rects.map { $0.meet(old) }.filter { !$0.empty };guard !kept.isEmpty else { return nil }
            return .init(kept.map(\.left).min()!,kept.map(\.top).min()!,kept.map(\.right).max()!,kept.map(\.bottom).max()!)
        }
        guard let optimistic=bounding(required+others+ownBoxes.map { $0.grow(Pads(1)) }),optimistic.area <= old.area*0.95 else { return nil }
        let plateRGB=plate.background.flatMap { $0.count == 3 ? $0:nil }
        for (index,box) in ownBoxes.enumerated() {
            let pads=Pads(left:pad+(source.vertical ? fringe:0),top:pad+(source.vertical ? 0:fringe),right:pad+(source.vertical ? fringe:0),bottom:pad+(source.vertical ? 0:fringe))
            let rest=index == 0 ? bounding(required+others+ownBoxes.dropFirst().map { $0.grow(Pads(pad)) }):nil
            let wanted=rest.map { [box.left-pads.left<$0.left-0.5,box.top-pads.top<$0.top-0.5,box.right+pads.right>$0.right+0.5,box.bottom+pads.bottom>$0.bottom+0.5] } ?? [true,true,true,true]
            var sides=pads
            if index == 0,let plateRGB,wanted.contains(true) {
                do { sides=try sourceSides(box:box,pads:pads,plate:plateRGB,wanted:wanted,caption:caption,scene:scene,budget:budget,readSource:readSource) } catch { sides=pads }
            }
            required.append(box.grow(sides))
        }
        required += others
        if let restoration { required.append(Box(restoration)) }
        guard var next=bounding(required) else { return nil }
        next = Box(floor(next.left*4)/4,floor(next.top*4)/4,ceil(next.right*4)/4,ceil(next.bottom*4)/4).meet(old)
        if next.left-old.left < 1 { next.left=old.left };if next.top-old.top < 1 { next.top=old.top }
        if old.right-next.right < 1 { next.right=old.right };if old.bottom-next.bottom < 1 { next.bottom=old.bottom }
        if scene.imageComplete,scene.imageSize.width > 0,let plateRGB {
            do {
                func line(_ horizontal:Bool,_ at:Double,_ from:Double,_ to:Double) throws -> Double {
                    let sx=Double(scene.imageSize.width)/Double(scene.frame.width),sy=Double(scene.imageSize.height)/Double(scene.frame.height)
                    let a=floor((horizontal ? (at-frame.top)*sy:(at-frame.left)*sx)+0.5)
                    let b0=max(0,floor((horizontal ? from-frame.left:from-frame.top)*(horizontal ? sx:sy)))
                    let b1=min(Double(horizontal ? scene.imageSize.width:scene.imageSize.height),ceil((horizontal ? to-frame.left:to-frame.top)*(horizontal ? sx:sy)))
                    if a < 0 || a >= Double(horizontal ? scene.imageSize.height:scene.imageSize.width) { return 1 }
                    if b1-b0 < 2 { return 0 }
                    let crop=horizontal ? CGRect(x:b0,y:a,width:b1-b0,height:1):CGRect(x:a,y:b0,width:1,height:b1-b0)
                    let data=try readSource(crop,Int(crop.width),Int(crop.height));guard data.count == Int(crop.width*crop.height)*4 else { return 0 }
                    var art=0
                    for p in stride(from:0,to:data.count,by:4) { if gap([Double(data[p]),Double(data[p+1]),Double(data[p+2])],plateRGB)>40 { art += 1 } }
                    return Double(art)/Double(data.count/4)
                }
                func column(_ box:Box,_ x:Double) throws -> Double { try line(false,x,box.top,box.bottom) }
                func row(_ box:Box,_ y:Double) throws -> Double { try line(true,y,box.left,box.right) }
                func cuts(_ now:Double,_ before:Double) -> Bool { before < 0.3 && now > before+0.35 }
                if next.left>old.left { if try cuts(column(next,next.left-1.5),column(old,old.left-1.5)) { next.left=old.left } }
                if next.right<old.right { if try cuts(column(next,next.right+1.5),column(old,old.right+1.5)) { next.right=old.right } }
                if next.top>old.top { if try cuts(row(next,next.top-1.5),row(old,old.top-1.5)) { next.top=old.top } }
                if next.bottom<old.bottom { if try cuts(row(next,next.bottom+1.5),row(old,old.bottom+1.5)) { next.bottom=old.bottom } }
            } catch {}
        }
        if next.area > old.area*0.95 { return nil }
        var pieces:[CGRect]?,clipped=false
        if let coverage {
            let kept=coverage.map { Box($0).meet(next) }.filter { !$0.empty }
            let whole=kept.count == 1 && abs(kept[0].left-next.left)<0.01 && abs(kept[0].top-next.top)<0.01 && abs(kept[0].right-next.right)<0.01 && abs(kept[0].bottom-next.bottom)<0.01
            clipped = !kept.isEmpty && !whole
            pieces=(kept.isEmpty ? [next]:kept).map(\.rect)
        }
        let proposal=Proposal(rect:next.rect,coverage:pieces,clipped:clipped,oldArea:Int(floor(old.area+0.5)),newArea:Int(floor(next.area+0.5)))
        let proof=validate(proposal),after=Box(proof.ink)
        guard proof.clipSupported,proof.fits,abs(after.left-ink.left)<=0.5,abs(after.top-ink.top)<=0.5,abs(after.right-ink.right)<=0.5,abs(after.bottom-ink.bottom)<=0.5 else { return nil }
        return proposal
    }
    private static func sourceSides(box:Box,pads:Pads,plate:[Double],wanted:[Bool],caption:Caption,scene:Scene,budget:Budget,
                                    readSource:(CGRect,Int,Int)throws->[UInt8]) throws -> Pads {
        guard scene.imageComplete,scene.imageSize.width > 0 else { return pads }
        var candidates:[Any?]=[caption.sampledForeground,caption.sampledStroke]
        if let record=caption.outlined { candidates += [record["core"],record["outline"],record["ink"]] }
        candidates += [caption.sample["foreground"],caption.sample["displayForeground"],caption.sample["stroke"]]
        let lettering=candidates.compactMap(colours);if lettering.isEmpty { return pads }
        let frame=Box(scene.frame),E=box.grow(pads).meet(frame);if E.empty { return pads }
        let nw=Double(scene.imageSize.width),nh=Double(scene.imageSize.height),sx=nw/Double(scene.frame.width),sy=nh/Double(scene.frame.height)
        let x0=max(0,floor((E.left-frame.left)*sx)),y0=max(0,floor((E.top-frame.top)*sy)),x1=min(nw,ceil((E.right-frame.left)*sx)),y1=min(nh,ceil((E.bottom-frame.top)*sy))
        let w=Int(x1-x0),h=Int(y1-y0);if w<1 || h<1 || w*h>budget.samples { return pads };budget.samples -= w*h
        let data=try readSource(CGRect(x:x0,y:y0,width:Double(w),height:Double(h)),w,h);guard data.count == w*h*4 else { return pads }
        let stepX=max(1,Int(floor(sx/1.5+0.5))),stepY=max(1,Int(floor(sy/1.5+0.5)))
        func like(_ rgb:[Double]) -> Bool { lettering.contains { c in
            if gap(rgb,c)<=72 { return true }
            let d=(0..<3).map { c[$0]-plate[$0] },n=d[0]*d[0]+d[1]*d[1]+d[2]*d[2];if n<48*48 { return false }
            let v=(0..<3).map { rgb[$0]-plate[$0] },t=(v[0]*d[0]+v[1]*d[1]+v[2]*d[2])/n;if t<0.25 { return false }
            return hypot(hypot(v[0]-t*d[0],v[1]-t*d[1]),v[2]-t*d[2])<=56
        } }
        var side=[[Double]](repeating:[0,0,0],count:4)
        let bx0=Int(floor((box.left-frame.left)*sx)-x0),bx1=Int(ceil((box.right-frame.left)*sx)-x0),by0=Int(floor((box.top-frame.top)*sy)-y0),by1=Int(ceil((box.bottom-frame.top)*sy)-y0)
        func visit(_ xa:Int,_ xb:Int,_ ya:Int,_ yb:Int) {
            for yy in stride(from:max(0,ya),to:min(h,yb),by:stepY) {
                let py=frame.top+(y0+Double(yy)+0.5)/sy
                for xx in stride(from:max(0,xa),to:min(w,xb),by:stepX) {
                    let px=frame.left+(x0+Double(xx)+0.5)/sx
                    if px>=box.left && px<=box.right && py>=box.top && py<=box.bottom { continue }
                    let p=(yy*w+xx)*4,rgb=[Double(data[p]),Double(data[p+1]),Double(data[p+2])];if gap(rgb,plate)<=40 { continue }
                    let letter=like(rgb),reach=[box.left-px,box.top-py,px-box.right,py-box.bottom]
                    for key in 0..<4 where reach[key]>0 && wanted[key] { side[key][0]+=1;if letter { side[key][1]+=1;side[key][2]=max(side[key][2],reach[key]+1/min(sx,sy)) } }
                }
            }
        }
        if wanted[0] { visit(0,bx0,0,h) };if wanted[2] { visit(bx1,w,0,h) };if wanted[1] { visit(0,w,0,by0) };if wanted[3] { visit(0,w,by1,h) }
        var result=pads
        for key in 0..<4 where wanted[key] && side[key][0]>=2 { result[key]=min(pads[key],side[key][1]>0 ? side[key][2]+1.5:1) }
        return result
    }
}
