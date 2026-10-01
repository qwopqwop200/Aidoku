import CoreGraphics
import Foundation

/// Frozen growPlateWide/widenDisplayCard display search. The caption may widen,
/// while its original plate, erasure, coverage and source restoration stay put.
enum NativeTypographyDisplayWidening {
    typealias Measurement=NativeTypographyPlateGrowth.Measurement
    typealias Proposal=NativeTypographyPlateGrowth.Proposal
    struct Input {
        var text: String
        var font: Double
        var glyph: Double
        var pageGlyph: Double
        var cap: Double = .infinity
        var grown: Double? = nil
        var flatRoom = false
        var rotation = false
        var vertical = false
        var sourceVertical = true
        var allowsRecovery = true
        var wrappingScript = "korean"
        var visible = true
        var ratio = 1.2
        var strict = false
        var plate: CGRect
        var visiblePlate: CGRect
        var color: [Double]
        var frame: CGRect
        var source: CGRect
        var imageWidth: Int
        var imageHeight: Int
        var others: [CGRect] = []
        var foreignCards: [CGRect] = []
        var foreignSourceRects: [CGRect] = []
    }
    final class Budget {var pixels=393_216}
    struct Result {var proposal:Proposal;var ink:CGRect;var widths:[Double];var sampledPixels:Int}
    static func eligible(_ e:Input)->Bool {
        !e.rotation && !e.vertical && e.sourceVertical && !e.flatRoom && e.allowsRecovery &&
        ["korean","word"].contains(e.wrappingScript) && e.visible && !e.text.isEmpty && e.text.utf16.count<=180 &&
        e.font>0 && e.glyph>0 && (e.glyph>=40 || e.glyph>=24 && e.glyph>=1.6*e.pageGlyph)
    }
    static func meets(_ a:CGRect,_ b:CGRect)->Bool {a.minX<b.maxX && a.maxX>b.minX && a.minY<b.maxY && a.maxY>b.minY}
    static func widen(_ e:Input,budget:Budget,advance:(String,Double)->Double,
                      read:(CGRect,Int,Int)->[UInt8]?,measure:(Proposal)->Measurement?)->Result? {
        guard eligible(e),e.frame.width>0,e.frame.height>0,e.imageWidth>0,e.imageHeight>0,
              e.color.count>=3,(e.color.count==3 || e.color[3]==1),
              abs(e.visiblePlate.minX-e.plate.minX)<=1,abs(e.visiblePlate.maxX-e.plate.maxX)<=1 else{return nil}
        let target=floor(min(32,e.glyph*0.95,e.font*3,e.cap)*4)/4
        let display=floor((e.glyph>=40 ? min(128,e.glyph*0.8,e.cap):min(32,e.glyph*0.95,e.font*3,e.cap))*4)/4
        guard !(e.grown.map {$0>=max(target,display)*0.95} ?? false),max(target,display)>=e.font*1.1 else{return nil}
        let earlier=floor(min(e.glyph>=40 ? min(64,e.glyph*0.8):32,e.glyph*0.95,e.font*3,e.cap)*4)/4
        var sizes:[Double]=[]
        if display>target {
            var larger=NativeTypographyPlateGrowth.displaySizes(display,target)
            if earlier>target {for step in 0..<4 {larger.append(floor((earlier-(earlier-target)*Double(step)/4)*4)/4)}}
            sizes += Array(Set(larger)).sorted(by:>)
        }
        if target>=e.font*1.1 {for step in 0..<6 {sizes.append(floor((target-(target-e.font*1.1)*Double(step)/5)*4)/4)}}
        let from=max(e.font,e.grown ?? 0)
        sizes=sizes.filter {$0>e.font && $0>=from*1.05}
        guard let topSize=sizes.first else{return nil}
        let p=e.visiblePlate,reach=min(Double(e.frame.width)*0.5,1.5*max(e.glyph,topSize))
        let left=max(Double(e.frame.minX),Double(p.minX)-reach),right=min(Double(e.frame.maxX),Double(p.maxX)+reach)
        let top=max(e.frame.minY,p.minY),bottom=min(e.frame.maxY,p.maxY)
        guard right-left>=Double(p.width)+4,bottom-top>=4 else{return nil}
        let band=CGRect(x:left,y:top,width:right-left,height:bottom-top)
        let sx=Double(e.imageWidth)/Double(e.frame.width),sy=Double(e.imageHeight)/Double(e.frame.height)
        let rw=Double(band.width)*sx,rh=Double(band.height)*sy,k=min(1,sqrt(98_304/max(1,rw*rh)))
        let w=max(1,Int(floor(rw*k+0.5))),h=max(1,Int(floor(rh*k+0.5)))
        guard w*h<=budget.pixels else{return nil};budget.pixels-=w*h
        let crop=CGRect(x:(band.minX-e.frame.minX)*sx,y:(band.minY-e.frame.minY)*sy,width:rw,height:rh)
        guard let rgba=read(crop,w,h),rgba.count>=w*h*4 else{return nil}
        let off=(0..<w*h).map {i -> UInt8 in
            max(abs(Double(rgba[i*4])-e.color[0]),abs(Double(rgba[i*4+1])-e.color[1]),abs(Double(rgba[i*4+2])-e.color[2]))>28 ? 1:0
        }
        func share(_ q:CGRect)->Double {
            let x0=max(0,Int(floor(Double(q.minX-band.minX)/Double(band.width)*Double(w))))
            let x1=min(w,Int(ceil(Double(q.maxX-band.minX)/Double(band.width)*Double(w))))
            let y0=max(0,Int(floor(Double(q.minY-band.minY)/Double(band.height)*Double(h))))
            let y1=min(h,Int(ceil(Double(q.maxY-band.minY)/Double(band.height)*Double(h))))
            guard x1>x0,y1>y0 else{return 1}
            var bad=0;for y in y0..<y1 {for x in x0..<x1 {bad+=Int(off[y*w+x])}}
            return Double(bad)/Double((x1-x0)*(y1-y0))
        }
        let obstacles=e.others.map {$0.insetBy(dx:-3,dy:-3)}+e.foreignCards+e.foreignSourceRects.map {$0.insetBy(dx:-2,dy:-2)}
        let words=e.text.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        for size in sizes {
            let pad=max(3,min(8,size*0.3)),word=words.map {advance($0,size)}.max() ?? -.infinity
            let line=advance(e.text.split(whereSeparator:{$0.isWhitespace}).joined(separator:" "),size)
            let widths=Array(Set([word,(word+line)/2,line].map {ceil($0+pad*2+2)})).sorted().filter {$0>Double(p.width) && $0<=Double(band.width)}
            for width in widths {
                var x=Double(e.source.midX)-width/2
                x=min(max(x,Double(band.minX)),Double(band.maxX)-width)
                guard x<=Double(p.minX)+0.5,x+width>=Double(p.maxX)-0.5 else{continue}
                let proposal=Proposal(box:CGRect(x:x,y:p.minY,width:width,height:p.height),font:size,pitch:size*e.ratio,
                    padding:pad,horizontalScale:1,room:false,lifting:false)
                guard let m=measure(proposal),m.scrollWidth<=m.clientWidth+1,m.scrollHeight<=m.clientHeight+1 else{continue}
                let ink=m.ink
                guard ink.minX>=proposal.box.minX+pad-0.5,ink.maxX<=proposal.box.maxX-pad+0.5,
                      ink.minY>=p.minY+pad-0.5,ink.maxY<=p.maxY-pad+0.5 else{continue}
                let lines=max(1,Int(floor(Double(ink.height)/(size*e.ratio)+0.5)))
                guard NativeTypographyPlateGrowth.keepsLineLength(e.text,before:1,after:lines),
                      !e.others.contains(where:{meets(ink,$0)}),!(e.strict && m.badLineStart) else{continue}
                let margin=max(2,size*0.12),top=Double(ink.minY)-margin,bottom=Double(ink.maxY)+margin
                let edges=[(Double(ink.minX)-margin,Double(p.minX)),(Double(p.maxX),Double(ink.maxX)+margin)]
                let parts=edges.compactMap {left,right -> CGRect? in
                    guard right-left>0.5 else{return nil}
                    return CGRect(x:left,y:top,width:right-left,height:bottom-top)
                }
                guard !parts.isEmpty,!parts.contains(where:{q in q.minX<band.minX-0.5 || q.maxX>band.maxX+0.5 ||
                    obstacles.contains(where:{meets(q,$0)}) || share(q)>0.01}) else{continue}
                return Result(proposal:proposal,ink:ink,widths:widths,sampledPixels:w*h)
            }
        }
        return nil
    }
}
