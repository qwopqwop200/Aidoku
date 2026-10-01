// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

/// The frozen browser's aidokuGlossPlacer, with page evidence and candidate ranking retained.
/// Text measurement is supplied by the native typesetter, independently of the placement policy.
final class NativeTranslationGlossPlacement {
    struct Options {
        var start: Double
        var minimum: Double
        var lines: Double = 2
        var texture: Bool = false
    }
    struct TiltedFrame {
        var cx: Double
        var cy: Double
        var angle: Double
        var hw: Double
        var hh: Double
    }
    struct Placement {
        let cost: Double
        let size: Double
        let width: Double
        let lineHeight: Double
        let moves: [CGPoint]
        let edge: Double
        let rank: Int
        let side: String
        let gap: Double
        let texture: Bool
        let ink: CGRect?
        let angle: Double?
        let center: CGPoint?
        let block: CGSize?
    }
    struct Evidence {
        var rule: Double = 0
        var edge: Double = 0
        var edgeMax: Double = 0
        var own: Double = 0
        var paper: Double = 1
        static let rejected = Evidence(rule: 1, edge: 1, edgeMax: 1, own: 1, paper: 0)
    }
    typealias Measure = (_ size: Double, _ width: Double, _ lineHeight: Double) -> [CGRect]
    typealias Sampler = (_ top: Double, _ bottom: Double, _ width: Int, _ height: Int) -> [UInt8]?
    private struct LocalRect {
        var u0: Double
        var u1: Double
        var v0: Double
        var v1: Double
        var width: Double { u1-u0 }
        var height: Double { v1-v0 }
    }
    private struct Grid {
        var k: Double
        var top: Double
        var width: Int
        var height: Int
        var edges: [Int]
        var pairs: [Int]
        var own: [Int]
        var paper: [Int]
        var rows: [Int]
        var columns: [Int]
        var stride: Int { width+1 }
        func area(_ t: [Int], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            t[y1*stride+x1]-t[y0*stride+x1]-t[y1*stride+x0]+t[y0*stride+x0]
        }
        func cell(_ t: [Int], _ x: Int, _ y: Int) -> Int { area(t,x,y,x+1,y+1) }
    }
    private let frame: CGRect
    private var band: CGRect
    private let fill: [Double]
    private let ground: [Double]?
    private let sample: Sampler
    private var grid: Grid?
    private var sampled = false
    private(set) var reasons: [String: Int] = ["frame":0,"source":0,"blocked":0,"edge":0,"inside":0,"reads":0]
    private var figure: Bool { ground.map { (zip(fill,$0).map { abs($0-$1) }.max() ?? 0) > 48 } ?? false }

    init(frame: CGRect, band: CGRect, fill: [Double], ground: [Double]?, sampler: @escaping Sampler) {
        self.frame = frame; self.band = band; self.fill = fill; self.ground = ground; sample = sampler
    }

    convenience init(frame: CGRect, band: CGRect, fill: [Double], ground: [Double]?, image: CGImage?) {
        self.init(frame: frame, band: band, fill: fill, ground: ground) { top,bottom,width,height in
            guard let image, frame.width > 0, frame.height > 0 else { return nil }
            return try? NativeSourcePixelReader.draw(image: image, x: 0,
                y: (top - Double(frame.minY)) / Double(frame.height) * Double(image.height),
                sourceWidth: Double(image.width), sourceHeight: (bottom - top) / Double(frame.height) * Double(image.height),
                width: width, height: height)
        }
    }

    func setBand(_ value: CGRect) { band = value; sampled = false; grid = nil }
    private func increment(_ key: String) { reasons[key,default: 0] += 1 }
    private func sampleGrid() -> Grid? {
        if sampled { return grid }; sampled = true
        guard fill.count == 3, fill.allSatisfy(\.isFinite), ground == nil || ground?.count == 3,
            ground?.allSatisfy(\.isFinite) != false,
            [frame.minX,frame.minY,frame.width,frame.height,band.minX,band.minY,band.width,band.height].allSatisfy(\.isFinite),
            frame.width > 0, frame.height > 0, frame.width <= 1_000_000, frame.height <= 1_000_000 else { return nil }
        let reach = 26.0*1.2*3+40, top = max(Double(frame.minY),Double(band.minY)-reach)
        let bottom = min(Double(frame.maxY),Double(band.maxY)+reach)
        guard bottom>top else { return nil }
        let k = max(2,Double(frame.width)/200,(bottom-top)/400)
        let w = max(2,Int((Double(frame.width)/k).rounded())), h = max(2,Int(((bottom-top)/k).rounded()))
        guard w*h <= 1_000_000, let data = sample(top,bottom,w,h), data.count == w*h*4 else { return nil }
        var g = Grid(k:k,top:top,width:w,height:h,edges:[Int](repeating:0,count:(w+1)*(h+1)),
            pairs:[Int](repeating:0,count:(w+1)*(h+1)),own:[Int](repeating:0,count:(w+1)*(h+1)),
            paper:[Int](repeating:0,count:(w+1)*(h+1)),rows:[Int](repeating:0,count:(w+1)*h),
            columns:[Int](repeating:0,count:(h+1)*w))
        var luminance = [Float](repeating: 0, count: w*h)
        for i in 0..<w*h {
            let red = Double(data[i*4]) * 0.299
            let green = Double(data[i*4+1]) * 0.587
            let blue = Double(data[i*4+2]) * 0.114
            luminance[i] = Float(red + green + blue)
        }
        for y in 0..<h { for x in 0..<w {
            let i=y*w+x,p=i*4,j=(y+1)*(w+1)+x+1
            let step=x+1<w && abs(Double(luminance[i])-Double(luminance[i+1]))>32 ? 1:0
            let drop=y+1<h && abs(Double(luminance[i])-Double(luminance[i+w]))>32 ? 1:0
            let own=(0..<3).map { abs(Double(data[p+$0])-fill[$0]) }.max()! <= 24 ? 1:0
            let paper=ground.map { rgb in (0..<3).map { abs(Double(data[p+$0])-rgb[$0]) }.max()! <= 64 ? 1:0 } ?? 0
            let edgePrevious = g.edges[j-1]+g.edges[j-w-1]-g.edges[j-w-2]
            g.edges[j]=step+drop+edgePrevious
            let pairPrevious = g.pairs[j-1]+g.pairs[j-w-1]-g.pairs[j-w-2]
            g.pairs[j]=(x+1<w ? 1:0)+(y+1<h ? 1:0)+pairPrevious
            g.own[j]=own+g.own[j-1]+g.own[j-w-1]-g.own[j-w-2]
            g.paper[j]=paper+g.paper[j-1]+g.paper[j-w-1]-g.paper[j-w-2]
            g.rows[y*(w+1)+x+1]=g.rows[y*(w+1)+x]+drop
            g.columns[x*(h+1)+y+1]=g.columns[x*(h+1)+y]+step
        } }
        grid=g; return g
    }
    private func gridRect(_ r: CGRect,_ g: Grid) -> (Int,Int,Int,Int) {
        (max(0,Int(floor((Double(r.minX)-Double(frame.minX))/g.k))),max(0,Int(floor((Double(r.minY)-g.top)/g.k))),
         min(g.width,Int(ceil((Double(r.maxX)-Double(frame.minX))/g.k))),min(g.height,Int(ceil((Double(r.maxY)-g.top)/g.k))))
    }
    func underneath(_ rect: CGRect,inset: Double = 0) -> Evidence {
        guard let g=sampleGrid() else { return Evidence() }; increment("reads")
        let (x0,y0,x1,y1)=gridRect(rect,g)
        guard x1-x0>=2,y1-y0>=2 else { return .rejected }
        let cell=max(2,y1-y0); var result=Evidence()
        for x in stride(from:x0,to:x1,by:cell) {
            let end=min(x1,x+cell),n=Double((end-x)*(y1-y0)),pairs=g.area(g.pairs,x,y0,end,y1)
            result.edgeMax=max(result.edgeMax,pairs>0 ? Double(g.area(g.edges,x,y0,end,y1))/Double(pairs):0)
            result.own=max(result.own,Double(g.area(g.own,x,y0,end,y1))/n)
            result.paper=min(result.paper,Double(g.area(g.paper,x,y0,end,y1))/n)
        }
        let padding=Int((inset/g.k).rounded())+1
        if y0+padding<y1-padding-1 { for y in y0+padding..<y1-padding-1 {
            result.rule=max(result.rule,Double(g.rows[y*g.stride+x1]-g.rows[y*g.stride+x0])/Double(x1-x0))
        } }
        if x0+padding<x1-padding-1 { for x in x0+padding..<x1-padding-1 {
            result.rule=max(result.rule,Double(g.columns[x*(g.height+1)+y1]-g.columns[x*(g.height+1)+y0])/Double(y1-y0))
        } }
        let pairs=g.area(g.pairs,x0,y0,x1,y1)
        result.edge=pairs>0 ? Double(g.area(g.edges,x0,y0,x1,y1))/Double(pairs):0
        return result
    }
    func divided(_ rect: CGRect,wide: Bool) -> Bool {
        guard let g=sampleGrid() else { return false }
        let (x0,y0,x1,y1)=gridRect(rect,g)
        guard x1-x0>=2,y1-y0>=2 else { return false }
        if wide { for y in y0..<y1 { if Double(g.rows[y*g.stride+x1]-g.rows[y*g.stride+x0])>Double(x1-x0)*0.8 { return true } } }
        else { for x in x0..<x1 { if Double(g.columns[x*(g.height+1)+y1]-g.columns[x*(g.height+1)+y0])>Double(y1-y0)*0.8 { return true } } }
        return false
    }
    func inkOf(_ source: CGRect) -> CGRect {
        guard figure,let g=sampleGrid() else { return source }
        func x(_ value: CGFloat)->Int { max(0,min(g.width,Int(((Double(value)-Double(frame.minX))/g.k).rounded()))) }
        func y(_ value: CGFloat)->Int { max(0,min(g.height,Int(((Double(value)-g.top)/g.k).rounded()))) }
        let bx0=x(source.minX),bx1=x(source.maxX),by0=y(source.minY),by1=y(source.maxY)
        guard bx1-bx0>=3,by1-by0>=3,Double(g.area(g.own,bx0,by0,bx1,by1))>=Double((bx1-bx0)*(by1-by0))*0.03 else { return source }
        func row(_ y:Int)->Bool { Double(g.area(g.own,bx0,y,bx1,y+1))>=max(2,Double(bx1-bx0)*0.08) }
        var top=by0,bottom=by1-1,left=bx0,right=bx1-1
        while top<bottom && !row(top) { top+=1 }; while bottom>top && !row(bottom) { bottom-=1 }
        func column(_ x:Int)->Bool { Double(g.area(g.own,x,top,x+1,bottom+1))>=max(2,Double(bottom+1-top)*0.08) }
        while left<right && !column(left) { left+=1 }; while right>left && !column(right) { right-=1 }
        var l=max(Double(source.minX),Double(frame.minX)+Double(left)*g.k),r=min(Double(source.maxX),Double(frame.minX)+Double(right+1)*g.k)
        var t=max(Double(source.minY),g.top+Double(top)*g.k),b=min(Double(source.maxY),g.top+Double(bottom+1)*g.k)
        if r-l<Double(source.width)*0.5 { l=Double(source.minX);r=Double(source.maxX) }
        if b-t<Double(source.height)*0.5 { t=Double(source.minY);b=Double(source.maxY) }
        return CGRect(x:l,y:t,width:r-l,height:b-t)
    }
    private func at(_ q:TiltedFrame,_ u:Double,_ v:Double)->CGPoint {
        CGPoint(x:q.cx+u*cos(q.angle)-v*sin(q.angle),y:q.cy+u*sin(q.angle)+v*cos(q.angle))
    }
    private func corners(_ q:TiltedFrame,_ r:LocalRect)->[CGPoint] {
        [at(q,r.u0,r.v0),at(q,r.u1,r.v0),at(q,r.u1,r.v1),at(q,r.u0,r.v1)]
    }
    private func meets(_ points:[CGPoint],_ rect:CGRect,_ q:TiltedFrame)->Bool {
        let b=rect.insetBy(dx:-3,dy:-3)
        guard points.map(\.x).max()!>b.minX,points.map(\.x).min()!<b.maxX,
            points.map(\.y).max()!>b.minY,points.map(\.y).min()!<b.maxY else { return false }
        let box=[CGPoint(x:b.minX,y:b.minY),CGPoint(x:b.maxX,y:b.minY),CGPoint(x:b.maxX,y:b.maxY),CGPoint(x:b.minX,y:b.maxY)]
        for (ax,ay) in [(cos(q.angle),sin(q.angle)),(-sin(q.angle),cos(q.angle))] {
            let a=points.map { Double($0.x)*ax+Double($0.y)*ay },d=box.map { Double($0.x)*ax+Double($0.y)*ay }
            if a.max()!<=d.min()! || d.max()!<=a.min()! { return false }
        }
        return true
    }
    private func samples(_ q:TiltedFrame,_ r:LocalRect,_ g:Grid)->[(x:Int,y:Int,u:Double,v:Double)?] {
        var out:[(x:Int,y:Int,u:Double,v:Double)?]=[],v=r.v0+g.k/2
        while v<r.v1 { var u=r.u0+g.k/2;while u<r.u1 {
            let p=at(q,u,v),x=Int(floor((Double(p.x)-Double(frame.minX))/g.k)),y=Int(floor((Double(p.y)-g.top)/g.k))
            out.append(x<0 || y<0 || x>=g.width || y>=g.height ? nil:(x,y,u,v));u+=g.k
        };v+=g.k }
        return out
    }
    private func underneathTilted(_ q:TiltedFrame,_ r:LocalRect,_ inset:Double)->Evidence {
        guard let g=sampleGrid() else { return Evidence() };increment("reads")
        let list=samples(q,r,g);guard !list.isEmpty,list.allSatisfy({ $0 != nil }) else { return .rejected }
        let cell=max(2*g.k,r.height)
        var cells:[Int:(e:Int,p:Int,o:Int,a:Int,n:Int)]=[:],rows:[Int:(n:Int,d:Int)]=[:],columns:[Int:(n:Int,d:Int)]=[:],e=0,p=0
        for case let s? in list {
            let ce=g.cell(g.edges,s.x,s.y),cp=g.cell(g.pairs,s.x,s.y),key=Int(floor((s.u-r.u0)/cell))
            e+=ce;p+=cp;var c=cells[key] ?? (0,0,0,0,0)
            c.e+=ce;c.p+=cp;c.o+=g.cell(g.own,s.x,s.y);c.a+=g.cell(g.paper,s.x,s.y);c.n+=1;cells[key]=c
            if s.u>r.u0+inset+g.k && s.u<r.u1-inset-g.k && s.v>r.v0+inset+g.k && s.v<r.v1-inset-g.k {
                var row=rows[s.y] ?? (0,0),col=columns[s.x] ?? (0,0)
                row.n+=1;row.d+=g.rows[s.y*g.stride+s.x+1]-g.rows[s.y*g.stride+s.x];rows[s.y]=row
                col.n+=1;col.d+=g.columns[s.x*(g.height+1)+s.y+1]-g.columns[s.x*(g.height+1)+s.y];columns[s.x]=col
            }
        }
        var result=Evidence();result.edge=p>0 ? Double(e)/Double(p):0
        for c in cells.values { result.edgeMax=max(result.edgeMax,c.p>0 ? Double(c.e)/Double(c.p):0);result.own=max(result.own,Double(c.o)/Double(c.n));result.paper=min(result.paper,Double(c.a)/Double(c.n)) }
        for lines in [rows,columns] { let longest=lines.values.map(\.n).max() ?? 0
            for line in lines.values where Double(line.n)>=max(4,Double(longest)*0.6) { result.rule=max(result.rule,Double(line.d)/Double(line.n)) }
        }
        return result
    }
    private func dividedTilted(_ q:TiltedFrame,_ r:LocalRect,_ wide:Bool)->Bool {
        guard let g=sampleGrid() else { return false };var lines:[Int:(n:Int,d:Int)]=[:]
        for case let s? in samples(q,r,g) { let key=wide ? s.y:s.x;var l=lines[key] ?? (0,0);l.n+=1
            l.d += wide ? g.rows[s.y*g.stride+s.x+1]-g.rows[s.y*g.stride+s.x]:g.columns[s.x*(g.height+1)+s.y+1]-g.columns[s.x*(g.height+1)+s.y];lines[key]=l
        }
        let longest=lines.values.map(\.n).max() ?? 0
        return lines.values.contains { Double($0.n)>=max(6,Double(longest)*0.6) && Double($0.d)>Double($0.n)*0.8 }
    }
    private func inkOfTilted(_ q:TiltedFrame)->LocalRect {
        let r=LocalRect(u0:-q.hw,u1:q.hw,v0:-q.hh,v1:q.hh)
        guard figure,let g=sampleGrid() else { return r }
        let nu=max(1,Int(ceil(q.hw*2/g.k))),nv=max(1,Int(ceil(q.hh*2/g.k)))
        var hu=[Int](repeating:0,count:nu),hv=[Int](repeating:0,count:nv),total=0
        for case let s? in samples(q,r,g) where g.cell(g.own,s.x,s.y)>0 {
            hu[min(nu-1,Int(floor((s.u-r.u0)/g.k)))]+=1;hv[min(nv-1,Int(floor((s.v-r.v0)/g.k)))]+=1;total+=1
        }
        guard nu>=3,nv>=3,Double(total)>=Double(nu*nv)*0.03 else { return r }
        var a=0,b=nv-1,c=0,d=nu-1
        while a<b && Double(hv[a])<max(2,Double(nu)*0.08) { a+=1 };while b>a && Double(hv[b])<max(2,Double(nu)*0.08) { b-=1 }
        while c<d && Double(hu[c])<max(2,Double(nv)*0.08) { c+=1 };while d>c && Double(hu[d])<max(2,Double(nv)*0.08) { d-=1 }
        var ink=LocalRect(u0:r.u0+Double(c)*g.k,u1:min(r.u1,r.u0+Double(d+1)*g.k),v0:r.v0+Double(a)*g.k,v1:min(r.v1,r.v0+Double(b+1)*g.k))
        if ink.width<r.width*0.5 { ink.u0=r.u0;ink.u1=r.u1 };if ink.height<r.height*0.5 { ink.v0=r.v0;ink.v1=r.v1 };return ink
    }
    private struct Spot { var rank:Int;var side:String;var gap:Double;var cost:Double;var x:Double;var y:Double;var beside:Bool=false }
    private func spots(ink:LocalRect,tw:Double,th:Double,size:Double,lh:Double,tilted:Bool)->[Spot] {
        let near=max(2,(size*0.22*4).rounded()/4),far=max(near,(lh*0.5*4).rounded()/4)
        let cx=(ink.u0+ink.u1)/2,cy=(ink.v0+ink.v1)/2;var out:[Spot]=[]
        for (gap,extra) in [(near,0.0),(far,0.5)] {
            if extra>0 && far<=near { continue }
            out.append(Spot(rank:0,side:"below",gap:gap,cost:extra,x:cx,y:ink.v1+gap+th/2))
            out.append(Spot(rank:1,side:"above",gap:gap,cost:0.25+extra,x:cx,y:ink.v0-gap-th/2))
            out.append(Spot(rank:2,side:"right",gap:gap,cost:2+extra,x:ink.u1+gap+tw/2,y:cy,beside:true))
            out.append(Spot(rank:2,side:"left",gap:gap,cost:2.25+extra,x:ink.u0-gap-tw/2,y:cy,beside:true))
            if ink.height>=th*2 { for (side,x) in [("right",ink.u1+gap+tw/2),("left",ink.u0-gap-tw/2)] { for y in [ink.v0+th/2,ink.v1-th/2] {
                out.append(Spot(rank:3,side:side,gap:gap,cost:2.5+extra,x:x,y:y,beside:true))
            } } }
        }
        return out
    }
    func search(source:CGRect,blocked:[CGRect],before:Bool=false,options:Options,measure:Measure)->Placement? {
        searchImpl(source:source,tilted:nil,blocked:blocked,before:before,options:options,measure:measure)
    }
    func searchTilted(frame:TiltedFrame,blocked:[CGRect],before:Bool=false,options:Options,measure:Measure)->Placement? {
        searchImpl(source:nil,tilted:frame,blocked:blocked,before:before,options:options,measure:measure)
    }
    private func searchImpl(source:CGRect?,tilted q:TiltedFrame?,blocked:[CGRect],before:Bool,options:Options,measure:Measure)->Placement? {
        guard options.start.isFinite,options.minimum.isFinite,options.minimum>0,options.start>=options.minimum,
            options.start <= 2_048, options.lines.isFinite, options.lines > 0,
            sampleGrid() != nil else { return nil }
        if let q, ![q.cx,q.cy,q.angle,q.hw,q.hh].allSatisfy(\.isFinite) || q.hw <= 0 || q.hh <= 0 { return nil }
        if let source, ![source.minX,source.minY,source.width,source.height].allSatisfy(\.isFinite) || source.width <= 0 || source.height <= 0 { return nil }
        let box=source.map(inkOf),ink=q.map(inkOfTilted) ?? LocalRect(u0:Double(box!.minX),u1:Double(box!.maxX),v0:Double(box!.minY),v1:Double(box!.maxY))
        let fw=Double(frame.width)-8,sw=min(ink.width,fw),sideWidth=max(ink.u0-Double(frame.minX)-8,Double(frame.maxX)-ink.u1-8)
        var placed:Placement?
        for relaxed in options.texture ? [false,true]:[false] {
            if relaxed && placed != nil { break }
            var size=relaxed ? max(options.start,11):options.start
            let minimum=relaxed ? max(options.minimum,11):options.minimum
            while size>=minimum {
                let lh=(size*1.2*100).rounded()/100
                let candidates=q == nil ? [sw,fw,sideWidth,sw/2,sw/3]:[sw,fw*0.75,sw/2,sw/3]
                var widths:[Double]=[]
                for value in candidates { let width=value.rounded();if width>=size*4 && !widths.contains(width) { widths.append(width) } }
                for width in widths {
                    let texts=measure(size,width,lh)
                    guard !texts.isEmpty,texts.count<=2,texts.allSatisfy({ [$0.minX,$0.minY,$0.width,$0.height].allSatisfy(\.isFinite) && $0.width>0 && $0.height>0 && $0.height<=lh*(options.lines+0.6) && $0.width<=width+1 && !$0.isNull }) else { continue }
                    let tw=Double(texts.map(\.width).max()!),th=Double(texts.reduce(CGFloat(0)) { $0+$1.height })
                    for spot in spots(ink:ink,tw:tw,th:th,size:size,lh:lh,tilted:q != nil) {
                        var r=LocalRect(u0:spot.x-tw/2,u1:spot.x+tw/2,v0:spot.y-th/2,v1:spot.y+th/2)
                        if q == nil && !spot.beside { let left=max(Double(frame.minX)+4,min(Double(frame.maxX)-4-tw,r.u0));r.u1=left+tw;r.u0=left }
                        let next=CGRect(x:r.u0,y:r.v0,width:r.width,height:r.height)
                        if let q {
                            if corners(q,r).contains(where: { $0.x<frame.minX+4 || $0.x>frame.maxX-4 || $0.y<frame.minY+4 || $0.y>frame.maxY-4 }) { increment("frame");continue }
                            if blocked.contains(where: { meets(corners(q,r),$0,q) }) { increment("blocked");continue }
                        } else {
                            if next.minY<frame.minY+4 || next.maxY>frame.maxY-4 || next.minX<frame.minX+4 || next.maxX>frame.maxX-4 || abs(r.u0-(spot.x-tw/2))>tw*0.25+1 { increment("frame");continue }
                            if r.u0<ink.u1 && r.u1>ink.u0 && r.v0<ink.v1 && r.v1>ink.v0 { increment("source");continue }
                            if blocked.contains(where: { next.minX-3<$0.maxX && next.maxX+3>$0.minX && next.minY-3<$0.maxY && next.maxY+3>$0.minY }) { increment("blocked");continue }
                        }
                        let m=max(3,size*0.2);var pad=LocalRect(u0:r.u0-m,u1:r.u1+m,v0:r.v0-m,v1:r.v1+m)
                        if spot.side=="below" { pad.v0=max(pad.v0,ink.v1+1) };if spot.side=="above" { pad.v1=min(pad.v1,ink.v0-1) }
                        if spot.beside && spot.side=="right" { pad.u0=max(pad.u0,ink.u1+1) };if spot.beside && spot.side=="left" { pad.u1=min(pad.u1,ink.u0-1) }
                        let under=q.map { underneathTilted($0,pad,m) } ?? underneath(CGRect(x:pad.u0,y:pad.v0,width:pad.width,height:pad.height),inset:m)
                        if under.edge>(relaxed ? 0.32:0.16) || under.edgeMax>(relaxed ? 0.5:0.3) || under.rule>0.6 || figure && under.own>0.2 { increment("edge");continue }
                        let mu=(ink.u0+ink.u1)/2,mv=(ink.v0+ink.v1)/2,wide = !spot.beside
                        let between=wide ? LocalRect(u0:ink.u0-ink.width*0.25,u1:ink.u1+ink.width*0.25,v0:min(r.v0,mv),v1:max(r.v1,mv)):
                            LocalRect(u0:min(r.u0,mu),u1:max(r.u1,mu),v0:ink.v0-ink.height*0.25,v1:ink.v1+ink.height*0.25)
                        let gap=spot.side=="right" ? LocalRect(u0:ink.u1,u1:r.u1,v0:r.v0,v1:r.v1):LocalRect(u0:r.u0,u1:ink.u0,v0:r.v0,v1:r.v1)
                        let isDivided=q.map { dividedTilted($0,between,wide) || spot.beside && dividedTilted($0,gap,false) } ?? divided(CGRect(x:between.u0,y:between.v0,width:between.width,height:between.height),wide:wide)
                        if isDivided { increment("panel");continue }
                        let cost=spot.cost+under.edge*12+(options.start-size)/options.start*6+(relaxed ? 3:0)
                        if placed == nil || cost<placed!.cost {
                            let center=q.map { at($0,spot.x,spot.y) } ?? CGPoint(x:(r.u0+r.u1)/2,y:(r.v0+r.v1)/2)
                            let left=Double(center.x)-tw/2;var y=Double(center.y)-th/2,moves=[CGPoint](repeating:.zero,count:texts.count)
                            for i in (before ? [1,0]:[0,1]) where i<texts.count {
                                moves[i]=CGPoint(x:left+(tw-Double(texts[i].width))/2-Double(texts[i].minX),y:y-Double(texts[i].minY));y+=Double(texts[i].height)
                            }
                            placed=Placement(cost:cost,size:size,width:width,lineHeight:lh,moves:moves,edge:under.edge,rank:spot.rank,side:spot.side,gap:spot.gap,texture:relaxed,ink:box,
                                angle:q?.angle,center:q == nil ? nil:center,block:q == nil ? nil:CGSize(width:tw,height:th))
                        }
                    }
                }
                if let placed,(options.start-size)/options.start*6>=placed.cost { break }
                size=size>minimum ? max(minimum,(size*0.9*4).rounded()/4):0
            }
        }
        return placed
    }
}
