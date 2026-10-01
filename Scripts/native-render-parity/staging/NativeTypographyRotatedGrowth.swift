import Foundation
import CoreGraphics

/// Frozen rotated-body/display growth. Native probes supply actual word Range
/// rows and Canvas-compatible font metrics; source and plate geometry are fixed.
enum NativeTypographyRotatedGrowth {
    struct Peer {
        var text: String
        var script: String
        var glyph: Double
        var font: Double
        var source: CGRect?
        var visible = true
    }
    struct Input {
        var text: String
        var script: String
        var font: Double
        var glyph: Double
        var box: CGRect
        var source: CGRect?
        var itemBox: CGRect
        var rotation: Double
        var upright = false
        var cap: Double = .infinity
        var ratio = 1.2
        var strict = false
        var rotatingPanel = true
        var backgroundKind = "rotated-panel"
        var vertical = false
        var wrappingScript = "korean"
        var visible = true
        var plainText = true
        var opaque = true
        var originalRows: [CGRect]
        var originalPageInk: CGRect
        var peers: [Peer] = []
        var otherLinePolygons: [[[[Double]]]] = []
        var others: [CGRect] = []
        var foreignCards: [CGRect] = []
    }
    struct Trial {
        var font: Double
        var side: Double
        var scale: Double
        var pitch: Double
        var shift: Double
    }
    struct Measurement {
        var rows: [CGRect]
        var ink: CGRect
        var scrollWidth: Double
        var clientWidth: Double
        var scrollHeight: Double
        var clientHeight: Double
        var badLineStart = false
    }
    struct FontMetrics {
        var fontAscent: Double
        var fontDescent: Double
        var actualAscent: Double
        var actualDescent: Double
        var actualLeft: Double
        var actualRight: Double
        var advance: Double
    }
    struct Result {var trial:Trial;var body:Bool;var pageInk:CGRect}
    static func meets(_ a:CGRect,_ b:CGRect)->Bool {a.minX<b.maxX && a.maxX>b.minX && a.minY<b.maxY && a.maxY>b.minY}
    static func touching(_ a:CGRect,_ cards:[CGRect])->Double {
        cards.reduce(0) {$0+max(0,Double(min(a.maxX,$1.maxX)-max(a.minX,$1.minX)))*max(0,Double(min(a.maxY,$1.maxY)-max(a.minY,$1.minY)))}
    }
    static func painted(_ ink:CGRect,box:CGRect,angle:Double)->(rect:CGRect,corners:[[Double]]) {
        let cx=Double(box.midX),cy=Double(box.midY),c=cos(angle),s=sin(angle)
        let corners=[[Double(ink.minX),Double(ink.minY)],[Double(ink.maxX),Double(ink.minY)],
                     [Double(ink.maxX),Double(ink.maxY)],[Double(ink.minX),Double(ink.maxY)]].map {p in
            [cx+(p[0]-cx)*c-(p[1]-cy)*s,cy+(p[0]-cx)*s+(p[1]-cy)*c]
        }
        let xs=corners.map {$0[0]},ys=corners.map {$0[1]},left=xs.min()!,top=ys.min()!
        return (CGRect(x:left,y:top,width:xs.max()!-left,height:ys.max()!-top),corners)
    }
    static func inkIn(_ rows:[CGRect],scale:Double,metrics:FontMetrics)->CGRect? {
        guard let first=rows.first,let last=rows.last,
              [metrics.fontAscent,metrics.fontDescent,metrics.actualAscent,metrics.actualDescent,
               metrics.actualLeft,metrics.actualRight,metrics.advance].allSatisfy(\.isFinite) else{return nil}
        func baseline(_ r:CGRect)->Double {Double(r.minY)+(Double(r.height)-metrics.fontAscent-metrics.fontDescent)/2+metrics.fontAscent}
        let one=rows.count==1,left=Double(rows.map(\.minX).min()!)-(one ? metrics.actualLeft*scale:0)
        let right=one ? Double(first.minX)+metrics.actualRight*scale:Double(rows.map(\.maxX).max()!)
        let top=baseline(first)-metrics.actualAscent,bottom=baseline(last)+metrics.actualDescent
        return CGRect(x:left,y:top,width:right-left,height:bottom-top)
    }
    static func grow(_ e:Input,advance:(String,Double)->Double,metrics:(Double)->FontMetrics?,
                     measure:(Trial)->Measurement?,convexOverlap:(([[Double]],[[Double]])->Bool)?=nil,
                     containsUpright:(CGRect)->Bool)->Result? {
        guard e.rotatingPanel,e.backgroundKind=="rotated-panel",!e.vertical,["korean","word"].contains(e.wrappingScript),
              e.visible,!e.text.isEmpty,e.text.utf16.count<=180,e.plainText,e.font>0,e.glyph>0,e.opaque else{return nil}
        if e.glyph<40 {
            return body(e,advance:advance,metrics:metrics,measure:measure,convexOverlap:convexOverlap,containsUpright:containsUpright)
        }
        let target=floor(min(128,e.glyph*0.8,e.cap)*4)/4
        guard target>e.font else{return nil}
        let before=e.others.filter {meets(e.originalPageInk,$0)}.count,cardsBefore=touching(e.originalPageInk,e.foreignCards)
        let words=e.text.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        for size in NativeTypographyPlateGrowth.displaySizes(target,e.font) {
            if size<=e.font {break}
            let pad=max(3,min(8,size*0.15))
            guard (words.map {advance($0,size)}.max() ?? -.infinity)<=Double(e.box.width)-pad*2 else{continue}
            let trial=Trial(font:size,side:0,scale:1,pitch:size*e.ratio,shift:0)
            guard let m=measure(trial),m.ink.width>0,m.ink.minX>=e.box.minX+pad-0.5,m.ink.maxX<=e.box.maxX-pad+0.5,
                  m.ink.minY>=e.box.minY+pad-0.5,m.ink.maxY<=e.box.maxY-pad+0.5,
                  (!e.upright || containsUpright(m.ink)),
                  NativeTypographyPlateGrowth.keepsLineLength(e.text,before:max(1,e.originalRows.count),after:max(1,m.rows.count)),
                  !(e.strict && m.badLineStart) else{continue}
            let page=painted(m.ink,box:e.box,angle:e.upright ? 0:e.rotation).rect
            guard e.others.filter({meets(page,$0)}).count<=before,touching(page,e.foreignCards)<=cardsBefore+1 else{continue}
            return Result(trial:trial,body:false,pageInk:page)
        }
        return nil
    }
    static func body(_ e:Input,advance:(String,Double)->Double,metrics:(Double)->FontMetrics?,measure:(Trial)->Measurement?,
                     convexOverlap:(([[Double]],[[Double]])->Bool)?,containsUpright:(CGRect)->Bool)->Result? {
        guard !e.text.contains("\n"),!e.text.contains("\r"),let own=e.source else{return nil}
        func key(_ text:String)->String {
            text.unicodeScalars.filter {!CharacterSet.whitespacesAndNewlines.contains($0) && !".,!?~…—-".unicodeScalars.contains($0)}
                .map(String.init).joined()
        }
        func spread(_ a:Double,_ b:Double)->Double {max(a,b)/min(a,b)}
        let peers=e.peers.filter {peer in
            guard peer.visible,peer.script==e.script,peer.glyph>0 else{return false}
            if !key(peer.text).isEmpty,key(peer.text)==key(e.text){return true}
            guard let r=peer.source,spread(peer.glyph,e.glyph)<=1.22 else{return false}
            return max(own.minX-r.maxX,r.minX-own.maxX,own.minY-r.maxY,r.minY-own.maxY)<=3*max(peer.glyph,e.glyph)
        }.map(\.font).filter(\.isFinite)
        let rows=e.peers.filter {peer in
            guard peer.visible,let r=peer.source,peer.glyph>0,spread(peer.glyph,e.glyph)<=1.35 else{return false}
            let a=[own.minX,own.minY,own.width,own.height],b=[r.minX,r.minY,r.width,r.height]
            for (i,j) in [(1,0),(0,1)] {
                let overlap=min(a[i]+a[i+2],b[i]+b[i+2])-max(a[i],b[i])
                let gap=max(a[j],b[j])-min(a[j]+a[j+2],b[j]+b[j+2])
                if overlap>0.6*min(a[i+2],b[i+2]) && gap<3*max(a[i+2],b[i+2]) {return true}
            }
            return false
        }.map(\.font).filter(\.isFinite)
        let sizeCap:Double=peers.min().map {max(e.font,floor($0*1.2*4)/4)} ?? Double.infinity
        let rowCap:Double=rows.min().map {max(e.font,floor($0*1.12*4)/4)} ?? Double.infinity
        let peerCap=min(sizeCap,rowCap)
        let target=floor(min(32,e.glyph*0.9,e.cap,peerCap)*4)/4
        guard target>=e.font*1.05,let initialMetrics=metrics(e.font),let start=inkIn(e.originalRows,scale:1,metrics:initialMetrics),e.box.height>0 else{return nil}
        let angle=e.upright ? 0:e.rotation,before=painted(start,box:e.box,angle:angle)
        func hits(_ r:(rect:CGRect,corners:[[Double]]))->Int {
            // The caller supplies one polygon per foreign Range fragment. A
            // caption is counted once; its groups remain distinct in Input.
            e.otherLinePolygons.filter {fragments in fragments.contains {q in
                if let convexOverlap{return convexOverlap(r.corners,q)}
                return r.rect.minX<q[1][0] && r.rect.maxX>q[0][0] && r.rect.minY<q[2][1] && r.rect.maxY>q[0][1]
            }}.count
        }
        func crowded(_ r:CGRect)->Int {e.others.filter {o in
            let area=max(0,min(r.maxX,o.maxX)-max(r.minX,o.minX))*max(0,min(r.maxY,o.maxY)-max(r.minY,o.minY))
            return area>0.08*min(r.width*r.height,o.width*o.height)
        }.count}
        let hitsBefore=hits(before),cardsBefore=touching(before.rect,e.foreignCards),crowdedBefore=crowded(e.originalPageInk)
        let count=min(16,Int(ceil(log(target/(e.font*1.04))/log(1/0.96)))+1)
        var sizes:[Double]=[]
        for i in 0..<count {let size=floor(target*pow(e.font*1.04/target,count>1 ? Double(i)/Double(count-1):0)*4)/4
            if size>e.font,!sizes.contains(size){sizes.append(size)}}
        let words=e.text.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        for size in sizes {
            let margin=max(1.5,size*0.12),side=max(1,size*0.1),longest=words.map {advance($0,size)}.max() ?? -.infinity
            for scale in [1.0,0.9] {
                let available=Double(e.box.width)-side*2
                if scale<1 ? !(longest.isFinite && available.isFinite && available>0 && longest>available && longest*scale<=available):longest>available {continue}
                var trial=Trial(font:size,side:side,scale:scale,pitch:size*e.ratio,shift:0)
                guard var m=measure(trial) else{continue}
                let n=m.rows.count
                guard n>0,n<=e.originalRows.count,NativeTypographyPlateGrowth.keepsLineLength(e.text,before:e.originalRows.count,after:n),
                      !(e.strict && m.badLineStart) else{continue}
                let pitch=min(size*e.ratio,Double(e.box.height)/Double(n))
                guard n<=1 || pitch>=size*1.1 else{continue}
                trial.pitch=pitch
                guard let remeasured=measure(trial) else{continue};m=remeasured
                guard m.rows.count==n,m.scrollWidth<=m.clientWidth+0.5,m.scrollHeight<=m.clientHeight+0.5,
                      let face=metrics(size),var ink=inkIn(m.rows,scale:scale,metrics:face) else{continue}
                let shift=((Double(e.box.maxY)-Double(ink.maxY))-(Double(ink.minY)-Double(e.box.minY)))/2
                if abs(shift)>0.25,Double(n)*pitch+abs(shift)*2<=Double(e.box.height)+0.01 {
                    trial.shift=shift
                    guard let shifted=measure(trial),shifted.rows.count==n,shifted.scrollHeight<=shifted.clientHeight+0.5,
                          let next=inkIn(shifted.rows,scale:scale,metrics:face) else{continue};m=shifted;ink=next
                } else if abs(shift)>0.25,n==1 {
                    let room=Double(e.box.height)-abs(shift)*2
                    guard room>0 else{continue};trial.pitch=min(pitch,room);trial.shift=shift
                    guard let shifted=measure(trial),shifted.rows.count==n,shifted.scrollHeight<=shifted.clientHeight+0.5,
                          let next=inkIn(shifted.rows,scale:scale,metrics:face) else{continue};m=shifted;ink=next
                }
                guard ink.minX>=e.box.minX+side-0.5,ink.maxX<=e.box.maxX-side+0.5,
                      ink.minY>=e.box.minY+margin-0.5,ink.maxY<=e.box.maxY-margin+0.5,
                      (!e.upright || containsUpright(ink)) else{continue}
                let grown=painted(ink,box:e.box,angle:angle)
                guard hits(grown)<=hitsBefore,touching(grown.rect,e.foreignCards)<=cardsBefore+1,
                      crowded(painted(m.ink,box:e.box,angle:angle).rect)<=crowdedBefore else{continue}
                return Result(trial:trial,body:true,pageInk:grown.rect)
            }
        }
        return nil
    }
}
