import Foundation
import CoreGraphics

/// Adjacent rotated source columns share translated lines only when the sampled
/// line margins remain on the union of their unchanged, individually tilted plates.
enum NativeTranslationDisplayGroups {
    struct Cell {
        let id: String
        let text: String
        let glyph: Double
        let font: Double
        let color: [Double]
        let width: Double
        let height: Double
        let angle: Double
        let center: CGPoint
    }
    struct Measurement { let size: CGSize; let lines: [CGRect]; let scrollWidth: Double; let clientWidth: Double }
    struct Placement { let id: String; let members: [String]; let order: Int; let originalFont: Double; let font: Double; let pitch: Double; let padding: Double; let rect: CGRect; let angle: Double; let lines: [CGRect] }
    struct Result { let placements: [Placement]; let groups: Int; let probes: Int }
    typealias Measure = (Cell, _ font: Double, _ width: Double, _ pitch: Double, _ padding: Double) -> Measurement?
    static func arrange(_ cells:[Cell],foreign:[String:CGRect],measure:Measure)->Result {
        guard cells.count>=2 else {return .init(placements:[],groups:0,probes:0)}
        func turn(_ p:CGPoint,_ a:Double)->CGPoint {CGPoint(x:p.x*cos(a)-p.y*sin(a),y:p.x*sin(a)+p.y*cos(a))}
        var parent=Array(cells.indices)
        func find(_ i:Int)->Int {if parent[i] != i {parent[i]=find(parent[i])};return parent[i]}
        for i in cells.indices {for j in cells.indices where j>i {
            let a=cells[i],b=cells[j],theta=(a.angle+b.angle)/2
            guard abs(a.angle-b.angle)<=0.2,max(a.glyph,b.glyph)/min(a.glyph,b.glyph)<=1.35,
                  a.color.count==3,b.color.count==3,zip(a.color,b.color).map({abs($0-$1)}).max()!<=48 else {continue}
            let ap=turn(a.center,-theta),bp=turn(b.center,-theta),gap=abs(ap.x-bp.x)-(a.width+b.width)/2,
                overlap=min(ap.y+a.height/2,bp.y+b.height/2)-max(ap.y-a.height/2,bp.y-b.height/2)
            if gap<=0.3*min(a.glyph,b.glyph),gap > -0.5*min(a.width,b.width),overlap>=0.5*min(a.height,b.height) {parent[find(i)]=find(j)}
        }}
        var roots:[Int]=[],groups:[[Cell]]=[]
        for i in cells.indices {let root=find(i);if let at=roots.firstIndex(of:root) {groups[at].append(cells[i])}else {roots.append(root);groups.append([cells[i]])}}
        var placements:[Placement]=[],acceptedGroups=0,probes=0,currentForeign=foreign
        for group in groups where group.count>=2 && group.count<=4 {
            let theta=group.reduce(0) {$0+$1.angle}/Double(group.count)
            struct RotatedCell {let order:Int;let cell:Cell;let center:CGPoint}
            let rotated:[RotatedCell]=group.enumerated().map {index,cell in .init(order:index,cell:cell,center:turn(cell.center,-theta))}
            let ordered=rotated.sorted {a,b in a.center.x==b.center.x ? a.order<b.order:a.center.x>b.center.x}
            let left=ordered.map {Double($0.center.x)-$0.cell.width/2}.min()!,right=ordered.map {Double($0.center.x)+$0.cell.width/2}.max()!,
                topY=ordered.map {Double($0.center.y)-$0.cell.height/2}.min()!,bottom=ordered.map {Double($0.center.y)+$0.cell.height/2}.max()!
            let fonts=group.map(\.font),glyphs=group.map(\.glyph).sorted(),floorSize=max(fonts.max()!*0.85,fonts.min()!*1.3),
                ceiling=floor(min(128,glyphs[(glyphs.count-1)/2]*0.8)*4)/4
            guard ceiling>=floorSize else {continue}
            let ids=Set(group.map(\.id)),obstacles=currentForeign.filter {!ids.contains($0.key)}.map(\.value).filter {$0.width>0 && $0.height>0}
            let width=right-left,cx=(left+right)/2
            func onPlates(_ x:Double,_ y:Double)->Bool {
                let page=turn(CGPoint(x:x,y:y),theta)
                return group.contains {c in let p=turn(CGPoint(x:page.x-c.center.x,y:page.y-c.center.y),-c.angle);return abs(p.x)<=c.width/2-2 && abs(p.y)<=c.height/2-2}
            }
            var font=ceiling,chosen:[Placement]?
            while font>=floorSize && chosen==nil {
                let pad=max(2,font*0.12),pitch=font*1.2
                var blocks:[(Cell,Measurement)]=[],fits=true
                for entry in ordered {
                    let cell=entry.cell
                    probes+=1
                    guard let m=measure(cell,font,width,pitch,pad),m.scrollWidth<=m.clientWidth+1 else {fits=false;break}
                    let ls=m.lines.filter {$0.width>0 && $0.height>0},count=max(1,Int(floor(Double(m.size.height)/pitch+0.5)))
                    let characters=cell.text.replacingOccurrences(of:"[\\s\\uFEFF]+",with:"",options:.regularExpression).utf16.count
                    if ls.isEmpty || characters==0 || count>=3 && characters>=8 && Double(characters)/Double(count)<2.5 {fits=false;break}
                    blocks.append((cell,.init(size:m.size,lines:ls,scrollWidth:m.scrollWidth,clientWidth:m.clientWidth)))
                }
                if fits {
                    let gap=font*0.1,total=blocks.reduce(0.0) {$0+Double($1.1.size.height)}+gap*Double(blocks.count-1)
                    if total<=bottom-topY-4 {
                        let middle=(topY+bottom)/2-total/2,step=max(2,font/3)
                        var starts=[middle],d=step
                        while d<=(bottom-topY)/2 {starts += [middle-d,middle+d];d+=step}
                        for start in starts {
                            if start<topY+1.5 || start+total>bottom-1.5 {continue}
                            var y=start,ok=true,proposed:[Placement]=[]
                            for (cell,m) in blocks {
                                var physical:[CGRect]=[]
                                for line in m.lines {
                                    let l=cx-width/2+Double(line.minX)-pad*0.5,r=cx-width/2+Double(line.maxX)+pad*0.5,t=y+Double(line.minY)-pad*0.5,b=y+Double(line.maxY)+pad*0.5
                                    var sx=l
                                    while sx<=r+0.01 && ok {
                                        var sy=t
                                        while sy<=b+0.01 && ok {if !onPlates(min(sx,r),min(sy,b)) {ok=false};sy+=max(1,(b-t)/2)}
                                        sx+=max(1,min(font/4,(r-l)/2))
                                    }
                                    if !ok {break}
                                    let corners=[CGPoint(x:l,y:t),CGPoint(x:r,y:t),CGPoint(x:l,y:b),CGPoint(x:r,y:b)].map {turn($0,theta)}
                                    let lx=corners.map(\.x).min()!,ly=corners.map(\.y).min()!,rx=corners.map(\.x).max()!,by=corners.map(\.y).max()!,p=CGRect(x:lx,y:ly,width:rx-lx,height:by-ly)
                                    if obstacles.contains(where:{p.minX<$0.maxX && p.maxX>$0.minX && p.minY<$0.maxY && p.maxY>$0.minY}) {ok=false;break}
                                    let paintedCorners=[CGPoint(x:cx-width/2+Double(line.minX),y:y+Double(line.minY)),CGPoint(x:cx-width/2+Double(line.maxX),y:y+Double(line.minY)),CGPoint(x:cx-width/2+Double(line.minX),y:y+Double(line.maxY)),CGPoint(x:cx-width/2+Double(line.maxX),y:y+Double(line.maxY))].map {turn($0,theta)}
                                    let pl=paintedCorners.map(\.x).min()!,pt=paintedCorners.map(\.y).min()!,pr=paintedCorners.map(\.x).max()!,pb=paintedCorners.map(\.y).max()!
                                    physical.append(CGRect(x:pl,y:pt,width:pr-pl,height:pb-pt))
                                }
                                if !ok {break}
                                let page=turn(CGPoint(x:cx,y:y+Double(m.size.height)/2),theta)
                                proposed.append(.init(id:cell.id,members:group.map(\.id),order:proposed.count,originalFont:cell.font,font:font,pitch:pitch,padding:pad,
                                    rect:CGRect(x:Double(page.x)-width/2,y:Double(page.y)-Double(m.size.height)/2,width:width,height:Double(m.size.height)),angle:theta,lines:physical))
                                y+=Double(m.size.height)+gap
                            }
                            if ok {chosen=proposed;break}
                        }
                    }
                }
                let next=floor(font*0.94*4)/4
                if next>=font {break};font=next
            }
            if let chosen {
                placements+=chosen;acceptedGroups+=1
                for placement in chosen {currentForeign[placement.id]=placement.lines.reduce(CGRect.null) {$0.union($1)}}
            }
        }
        return .init(placements:placements,groups:acceptedGroups,probes:probes)
    }
}
