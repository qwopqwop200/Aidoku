import CoreGraphics
import Foundation

/// Final whole-word repair uses the composited owning surface after all earlier
/// source restoration and geometry choices. Plates never grow in this pass.
enum NativeKoreanStackRepair {
    struct Row {let first:Int;let last:Int;let chars:String;let rect:CGRect}
    struct Entry {
        let id:String;let text:String;let rows:[Row];let font:Double;let ratio:Double;let spacing:Double
        let angle:Double;let condense:Double;let center:CGPoint;let nodeRect:CGRect;let outerHeight:Double
        let frame:CGRect;let sourcePixelWidth:Double;let unit:Bool
        let obstacles:[[[Double]]];let kept:[CGRect];let ownColors:[[Double]]
    }
    struct Raster {let data:[UInt8];let page:[UInt8]?}
    struct Crop {let rect:CGRect;let scale:Double;let width:Int;let height:Int}
    struct Candidate {
        let kind:String;let font:Double;let condense:Double;let lines:[String];let pitch:Double
        let offset:CGPoint;let width:Double;let height:Double;let rects:[CGRect]
    }
    struct Outcome {let candidate:Candidate?;let declined:Bool;let rejected:[String:Int];let best:Double?;let reference:[Double]?}
    final class Session {var samples:Int;var tries:Int;init(samples:Int=393_216,tries:Int=6_000){self.samples=samples;self.tries=tries}}
    static func kind(text:String,rows:[Row],unit:Bool,reduplication:(Int)->Bool)->String? {
        guard rows.count>=2 else {return nil}
        let units=Array(text.utf16)
        func hangul(_ i:Int)->Bool {units.indices.contains(i) && (0xAC00...0xD7A3).contains(units[i])}
        func visible(_ text:String)->String {
            text.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
                !CharacterSet.punctuationCharacters.contains($0)  &&  !CharacterSet.symbols.contains($0)  && 
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }.map(String.init).joined()
        }
        func joined(_ i:Int)->Bool {
            let a=rows[i-1].last+1,b=rows[i].first
            guard a<=b,a>=0,b<=units.count else {return false}
            let between=String(decoding:units[a..<b],as:UTF16.self)
            return !between.unicodeScalars.contains(where:CharacterSet.whitespacesAndNewlines.contains) && hangul(rows[i-1].last) && hangul(rows[i].first)
        }
        func lone(_ row:Row)->Bool {let v=visible(row.chars);return v.utf16.count==1  &&  v.unicodeScalars.first.map {(0xAC00...0xD7A3).contains($0.value)} == true}
        for i in 1..<rows.count where lone(rows[i-1]) && lone(rows[i]) && joined(i) {return "stack"}
        if rows.count>=3,rows.allSatisfy({visible($0.chars).unicodeScalars.count<=2}),rows.indices.contains(where:{$0>0 && joined($0) &&  !reduplication(rows[$0].first)}) {return "column"}
        if rows.indices.contains(where:{lone(rows[$0]) && ($0>0 && joined($0) || $0+1<rows.count && joined($0+1))}) {return "fragment"}
        if unit,rows.indices.contains(where:{$0>0 && joined($0) &&  !reduplication(rows[$0].first)}) {return "split"}
        return nil
    }
    static func search(_ e:Entry,session:Session,measure:@escaping (String,Double)->Double,
                       lineLayout:(String,Double,Int,(String)->Double)->[String]?,
                       reduplication:(Int)->Bool,read:(Crop)->Raster?,clips:(CGPoint)->Bool,
                       verify:(Candidate)->Bool)->Outcome {
        let empty=Outcome(candidate:nil,declined:false,rejected:[:],best:nil,reference:nil)
        guard e.font>0,!e.rows.isEmpty,let kind=kind(text:e.text,rows:e.rows,unit:e.unit,reduplication:reduplication) else {return empty}
        let floorSize=kind=="stack" ? min(e.font,8.5):max(ceil(e.font*(kind=="fragment" ? 0.75:0.85)*4)/4,min(e.font,8.5))
        var sizes=[e.font],size=floor(e.font*0.95*4)/4
        while size>floorSize+0.01  &&  sizes.count<24 {sizes.append(size);size=floor(size*0.95*4)/4}
        if floorSize<e.font {sizes.append(floorSize)}
        let cosine=cos(e.angle),sine=sin(e.angle)
        func toPage(_ p:CGPoint)->CGPoint {CGPoint(x:e.center.x+p.x*cosine-p.y*sine,y:e.center.y+p.x*sine+p.y*cosine)}
        func local(_ x:Int,_ y:Int,_ crop:Crop)->CGPoint {
            let dx=crop.rect.minX+(Double(x)+0.5)/crop.scale-e.center.x,dy=crop.rect.minY+(Double(y)+0.5)/crop.scale-e.center.y
            return CGPoint(x:dx*cosine+dy*sine,y:-dx*sine+dy*cosine)
        }
        let normalized=e.text.split(whereSeparator:\.isWhitespace).joined(separator:" ")
        let full=measure(normalized,e.font)*(1+e.spacing),maxWidth=min(Double(e.frame.width),full+e.font*2),maxHeight=max(Double(e.nodeRect.height),e.outerHeight)+e.font
        let corners=[CGPoint(x:-maxWidth,y:-maxHeight/2),CGPoint(x:maxWidth,y:-maxHeight/2),CGPoint(x:maxWidth,y:maxHeight/2),CGPoint(x:-maxWidth,y:maxHeight/2)].map(toPage)
        let l=max(e.frame.minX,corners.map(\.x).min()!-4),t=max(e.frame.minY,corners.map(\.y).min()!-4),r=min(e.frame.maxX,corners.map(\.x).max()!+4),b=min(e.frame.maxY,corners.map(\.y).max()!+4)
        guard r-l>=2,b-t>=2 else {return empty}
        let scale=min(2,e.sourcePixelWidth/Double(e.frame.width),sqrt(98_304/Double((r-l)*(b-t))))
        let crop=Crop(rect:CGRect(x:l,y:t,width:r-l,height:b-t),scale:scale,width:max(1,Int(floor(Double(r-l)*scale+0.5))),height:max(1,Int(floor(Double(b-t)*scale+0.5))))
        guard crop.width*crop.height<=session.samples else {return empty}
        session.samples-=crop.width*crop.height
        guard let raster=read(crop),raster.data.count==crop.width*crop.height*4,raster.page==nil || raster.page!.count==raster.data.count else {return empty}
        let ink=e.rows.map(\.rect),inkBox=ink.reduce(CGRect.null) {$0.union($1)}
        func inside(_ rects:[CGRect],_ point:CGPoint,_ margin:Double)->Bool {
            rects.contains {point.x >= $0.minX-margin  &&  point.x <= $0.maxX+margin  &&  point.y >= $0.minY-margin  &&  point.y <= $0.maxY+margin}
        }
        func bounds(_ rects:[CGRect])->(Int,Int,Int,Int) {
            let pts=rects.flatMap {q in [CGPoint(x:q.minX,y:q.minY),CGPoint(x:q.maxX,y:q.minY),CGPoint(x:q.maxX,y:q.maxY),CGPoint(x:q.minX,y:q.maxY)]}.map(toPage)
            return (max(0,Int(floor(Double(pts.map(\.x).min()!-crop.rect.minX)*scale))),max(0,Int(floor(Double(pts.map(\.y).min()!-crop.rect.minY)*scale))),
                min(crop.width,Int(ceil(Double(pts.map(\.x).max()!-crop.rect.minX)*scale))),min(crop.height,Int(ceil(Double(pts.map(\.y).max()!-crop.rect.minY)*scale))))
        }
        var reference=e.ownColors.last,tolerance=reference==nil ? 28.0:14.0
        if reference==nil {
            var samples=[[Double](),[Double](),[Double]()];let (x0,y0,x1,y1)=bounds(ink)
            if x1>x0  &&  y1>y0 {for y in y0..<y1 {for x in x0..<x1 where inside(ink,local(x,y,crop),0) {let i=(y*crop.width+x)*4;for ch in 0..<3 {samples[ch].append(Double(raster.data[i+ch]))}}}}
            guard samples[0].count>=4 else {return empty}
            reference=samples.map {$0.sorted()[$0.count>>1]};tolerance=28
        }
        guard let reference,reference.count==3 else {return empty}
        var rejected=["split":0,"frame":0,"obstacle":0,"surface":0],best:Double?
        func surfaceFits(_ rects:[CGRect],_ margin:Double)->Bool {
            let (x0,y0,x1,y1)=bounds(rects.map {$0.insetBy(dx:-margin,dy:-margin)})
            var checked=0,off=0;let limit=max(2,Double((x1-x0)*(y1-y0))*0.01)
            if x1>x0  &&  y1>y0 {scan:for y in y0..<y1 {for x in x0..<x1 {
                let p=local(x,y,crop)
                if !inside(rects,p,margin) || inside(ink,p,1) {continue}
                checked+=1;let i=(y*crop.width+x)*4,px=crop.rect.minX+(Double(x)+0.5)/scale,py=crop.rect.minY+(Double(y)+0.5)/scale
                let pageOutside = !e.kept.contains {px >= $0.minX-0.5  &&  px <= $0.maxX+0.5  &&  py >= $0.minY-0.5  &&  py <= $0.maxY+0.5}
                let data=pageOutside ? raster.page ?? raster.data:raster.data
                if (0..<3).map({abs(Double(data[i+$0])-reference[$0])}).max()!>tolerance {off+=1;if Double(off)>limit {break scan}}
            }}}
            if checked>0 {best=min(best ?? 1,Double(off)/Double(checked))}
            return Double(off)<=max(2,Double(checked)*0.01)
        }
        let ratios=e.rows.filter {$0.chars.unicodeScalars.count>=2}.map {row in
            Double(row.rect.width)/e.condense/(measure(row.chars,e.font)+Double(row.chars.unicodeScalars.count-1)*e.font*e.spacing)
        }.filter(\.isFinite).sorted()
        let calibration=ratios.isEmpty ? 1:min(1.15,max(1,ratios[ratios.count>>1]))
        let words=e.text.split(whereSeparator:\.isWhitespace).map(String.init),units=Array(e.text.utf16)
        func hangul(_ i:Int)->Bool {units.indices.contains(i) && (0xAC00...0xD7A3).contains(units[i])}
        func visible(_ s:String)->String {s.precomposedStringWithCanonicalMapping.unicodeScalars.filter {!CharacterSet.punctuationCharacters.contains($0)  &&  !CharacterSet.symbols.contains($0)  &&  !CharacterSet.whitespacesAndNewlines.contains($0)}.map(String.init).joined()}
        var localTries=1500,chosen:Candidate?
        search:for font in sizes {for condense in [1.0,0.9] {
            func width(_ part:String)->Double {(measure(part,font)+Double(max(0,part.unicodeScalars.count-1))*font*e.spacing)*calibration}
            let longest=(words.map(width).max() ?? 0)+1,line=width(normalized)+1
            let measures=Set([longest,longest*1.2,longest*1.45,longest*1.8,longest*2.3,line].filter {$0<=line+0.01}.map {ceil($0*4)/4}).sorted()
            for measureWidth in measures {
                let priorGlobal=session.tries;session.tries-=1
                if priorGlobal<=0 {break search}
                let priorLocal=localTries;localTries-=1
                if priorLocal<=0 {break search}
                guard let lines=lineLayout(e.text,measureWidth,e.rows.count,width),!lines.isEmpty,lines.count<=e.rows.count else {continue}
                var at=0,whole=true
                for i in lines.indices {at+=lines[i].utf16.count;if i<lines.count-1,hangul(at-1),hangul(at),!(reduplication(at) && lines.allSatisfy({visible($0).unicodeScalars.count>=2})) {whole=false}}
                if !whole || lines.contains(where:{visible($0).isEmpty}) {rejected["split",default:0]+=1;continue}
                let pitch=font*e.ratio,total=Double(lines.count)*pitch,block=(lines.map {width($0.trimmingCharacters(in:.whitespacesAndNewlines))}.max() ?? 0)*condense
                let xs=[0,Double(inkBox.midX),Double(inkBox.minX)+block/2,Double(inkBox.maxX)-block/2],ys=[0,Double(inkBox.midY),Double(inkBox.minY)+total/2,Double(inkBox.maxY)-total/2]
                var shifts:[CGPoint]=[]
                func add(_ x:Double,_ y:Double) {if !shifts.contains(where:{abs(Double($0.x)-x)<0.5 && abs(Double($0.y)-y)<0.5}) {shifts.append(CGPoint(x:x,y:y))}}
                for y in ys {for x in xs {add(x,y)}}
                if kind=="split" {for p in shifts {for d in [CGPoint(x:1,y:0),CGPoint(x:-1,y:0),CGPoint(x:0,y:1),CGPoint(x:0,y:-1)] {add(Double(p.x+d.x),Double(p.y+d.y))}}}
                let margin=max(2,font*0.25)
                for shift in shifts {
                    let rects=lines.enumerated().map {index,text -> CGRect in let w=width(text.trimmingCharacters(in:.whitespacesAndNewlines))*condense
                        return CGRect(x:Double(shift.x)-w/2,y:Double(shift.y)-total/2+Double(index)*pitch+(pitch-font)/2,width:w,height:font)}
                    let polygons=rects.map {q in let p=q.insetBy(dx:-margin,dy:-margin);return [CGPoint(x:p.minX,y:p.minY),CGPoint(x:p.maxX,y:p.minY),CGPoint(x:p.maxX,y:p.maxY),CGPoint(x:p.minX,y:p.maxY)].map {v->[Double] in let p=toPage(v);return [Double(p.x),Double(p.y)]}}
                    if polygons.contains(where:{$0.contains {p in p[0]<max(Double(e.frame.minX),Double(crop.rect.minX))-0.5 || p[1]<max(Double(e.frame.minY),Double(crop.rect.minY))-0.5 || p[0]>min(Double(e.frame.maxX),Double(crop.rect.maxX))+0.5 || p[1]>min(Double(e.frame.maxY),Double(crop.rect.maxY))+0.5}}) {rejected["frame",default:0]+=1;continue}
                    if polygons.contains(where:{p in e.obstacles.contains {NativeSlantedGeometry.convexOverlap(p,$0)}}) {rejected["obstacle",default:0]+=1;continue}
                    if rects.contains(where:{q in [0.0,0.5,1].contains {u in [0.0,0.5,1].contains {v in !clips(toPage(CGPoint(x:q.minX+q.width*u,y:q.minY+q.height*v)))}}}) {rejected["clip",default:0]+=1;continue}
                    if !surfaceFits(rects,margin) {rejected["surface",default:0]+=1;continue}
                    chosen = .init(kind:kind,font:font,condense:condense,lines:lines,pitch:pitch,offset:shift,width:block/condense+max(2,font*0.15),height:total,rects:rects)
                    break search
                }
            }
        }}
        guard let chosen else {return .init(candidate:nil,declined:true,rejected:rejected,best:best,reference:reference)}
        guard verify(chosen) else {return .init(candidate:nil,declined:false,rejected:rejected,best:best,reference:reference)}
        return .init(candidate:chosen,declined:false,rejected:rejected,best:best,reference:reference)
    }
}
