import CoreGraphics
import Foundation

/// Late balloon-unit commit observes the already chosen glyph sizes, owning
/// surfaces and neighboring painted rectangles. It never runs in the base plan.
enum NativeTranslationBalloonUnitCommit {
    struct Interior { let rect: [Double]; let center: [Double]; let spans: [Double] }
    struct Unit { let members: [String]; let interior: Interior }
    struct Layer { let ownerID: String; let rect: CGRect; var participates = true }
    struct ProtectedSource { let id: String; let rects: [CGRect] }
    struct Placement { let rect: CGRect; let font: Double; let pitch: Double; let padding: Double; let order: Int; let members: Int; let from: Double }
    struct Record {
        let id: String
        let text: String
        let sourceBounds: [Double]
        let sourceRects: [CGRect]
        var ink: CGRect
        var font: Double
        var pitch: Double
        let sourceFontSize: Double?
        var unit: Unit?
        var hasNode = true
        var sourceVertical = false
        var rotation: Double = 0
        var vertical = false
        var balancedColumn = false
        var isRoot = true
        var transformNone = true
        var preservedGloss = false
        var hasScaleStyle = false
        var backgroundKind = "inpainted"
        var restoredSourcePanel = true
        var restoredSurfaceFontFit = false
        var hasRestoration = true
        var erasureComplete = true
        var provisional = false
        var restorationHidden = false
        var sourceAlignment: String?
        var sourceHeading = false
        var placement: Placement?
        var blocked: String?
    }
    struct Measurement { let ink: CGRect; let nodeRect: CGRect; let scrollWidth: Double; let clientWidth: Double }
    struct Result { let records: [Record]; let layouts: Int; let probes: Int; let outcomes: [String: Int] }
    typealias Measure = (Record, _ font: Double, _ width: Double, _ pitch: Double, _ padding: Double, _ commit: Bool) -> Measurement?

    static func commit(records input: [Record], layers: [Layer], kept: [ProtectedSource], frame: CGRect,
                       minimumFont: Double = 5, readableMinimum: Double = 8.5,
                       measure: Measure, widestWord: (String, Double) -> Double,
                       verify: ((Record, Placement, Measurement) -> CGRect?)? = nil) -> Result {
        var records = input, done = Set<String>(), layouts = 0, probes = 0, outcomes: [String: Int] = [:]
        let activeLayers = layers.filter(\.participates)
        func outcome(_ key: String) { outcomes[key,default:0]+=1 }
        func valid(_ r: CGRect) -> Bool { r.size.width > 0 && r.size.height > 0 }
        for lead in records.indices {
            guard let unit = records[lead].unit else { continue }
            let key = unit.members.joined(separator:"|")
            guard !key.isEmpty, done.insert(key).inserted,
                  [frame.minX,frame.minY,frame.width,frame.height].allSatisfy(\.isFinite),
                  unit.interior.rect.count == 4, unit.interior.rect.allSatisfy(\.isFinite), unit.interior.rect[2]>0, unit.interior.rect[3]>0, unit.interior.center.count == 2, unit.interior.center.allSatisfy(\.isFinite), unit.interior.spans.count >= 2, unit.interior.spans.allSatisfy(\.isFinite) else {continue}
            let indices = unit.members.compactMap { id in records.firstIndex { $0.id == id } }
            guard indices.count == unit.members.count, indices.allSatisfy({records[$0].hasNode}) else {continue}
            let members=indices.map {records[$0]},b=unit.interior
            func blocker(_ m:Record)->String? {
                if m.rotation != 0 || m.vertical || m.balancedColumn {return "shape"}
                if !m.isRoot || !m.transformNone || m.preservedGloss {return "placed"}
                if m.hasScaleStyle {return "condensed"}
                if m.backgroundKind != "inpainted" || !m.restoredSourcePanel && !m.restoredSurfaceFontFit {return "surface"}
                if !m.hasRestoration || !m.erasureComplete || m.provisional || m.restorationHidden {return "erasure"}
                if activeLayers.contains(where:{$0.ownerID==m.id}) {return "plate"}
                return nil
            }
            let aligned=members.indices.contains {i in members.indices.contains {j in
                if j<=i || members[i].sourceVertical || members[j].sourceVertical {return false}
                let a=members[i].sourceBounds,c=members[j].sourceBounds
                guard a.count==4,c.count==4 else {return false}
                let w=min(a[2],c[2]);return abs(a[0]-c[0])<=w*0.15 && abs(a[0]+a[2]/2-c[0]-c[2]/2)>w*0.25
            }} || members.contains {($0.sourceAlignment?.hasPrefix("left") ?? false) || $0.sourceHeading}
            if let blocked = aligned ? "aligned" : members.compactMap(blocker).first {
                outcome(blocked);records[indices[0]].blocked=blocked;continue
            }
            let sizes=members.map(\.font)
            guard sizes.allSatisfy({$0>0}) else {continue}
            let glyphs=members.compactMap(\.sourceFontSize).filter {$0>0}
            if glyphs.count==members.count, glyphs.max()!>glyphs.min()!*1.25,sizes.max()!>sizes.min()!*1.25 {outcome("emphasis");continue}
            let chars=members.map {Double(max(1,$0.text.utf16.count))}
            let mean=zip(sizes,chars).reduce(0) {$0+$1.0*$1.1}/chars.reduce(0,+)
            let floorSize=max(mean,sizes.max()!*0.9,minimumFont,sizes.map {min($0,readableMinimum)}.max()!),ceiling=min(32,sizes.max()!)
            if floorSize>ceiling {continue}
            let rect=CGRect(x:frame.minX+b.rect[0]*frame.width,y:frame.minY+b.rect[1]*frame.height,width:b.rect[2]*frame.width,height:b.rect[3]*frame.height)
            let center=CGPoint(x:frame.minX+b.center[0]*frame.width,y:frame.minY+b.center[1]*frame.height),bands=b.spans.count/2
            let runs=(0..<bands).map {k -> [CGFloat]? in let l=b.spans[k*2],r=b.spans[k*2+1];return l>=0 && r>l ? [frame.minX+l*frame.width,frame.minX+r*frame.width]:nil}
            func holds(_ q:CGRect)->Bool {
                if q.minY<rect.minY || q.maxY>rect.maxY {return false}
                let step=rect.height/CGFloat(bands)
                guard step>0 else {return false}
                let first=max(0,Int(floor((q.minY-rect.minY)/step))),last=min(bands-1,Int(ceil((q.maxY-rect.minY)/step))-1)
                if first>last {return false}
                for k in first...last {guard let run=runs[k],run[0]<=q.minX,run[1]>=q.maxX else {return false}}
                return true
            }
            let ids=Set(unit.members)
            let obstacles=(records.filter {!ids.contains($0.id) && $0.hasNode}.map(\.ink)+activeLayers.filter {!ids.contains($0.ownerID)}.map(\.rect)+records.filter {!ids.contains($0.id)}.flatMap(\.sourceRects)+kept.filter {!ids.contains($0.id)}.flatMap(\.rects)).filter(valid)
            func clear(_ q:CGRect)->Bool {!obstacles.contains {q.minX<$0.maxX && q.maxX>$0.minX && q.minY<$0.maxY && q.maxY>$0.minY}}
            let ratios=members.map {$0.pitch/$0.font == 0 ? 1.2:$0.pitch/$0.font}
            func blocks(_ f:Double,_ w:Double,_ committing:Bool=false)->[Measurement]? {
                let pad=max(1,min(3,f*0.15));var result:[Measurement]=[]
                for i in members.indices {
                    if !committing {let prior=probes;probes+=1;if prior>=480 {return nil}}
                    guard let m=measure(members[i],f,w,f*ratios[i],pad,committing),m.scrollWidth<=m.clientWidth+1,valid(m.ink) else {return nil}
                    result.append(m)
                };return result
            }
            struct Found {let font:Double;let width:Double;let measured:[Measurement];let inks:[CGRect]}
            func place(_ f:Double,_ w:Double)->Found? {
                guard let measured=blocks(f,w) else {return nil}
                let gap=f*0.3,height=measured.reduce(0) {$0+$1.ink.height}+gap*Double(measured.count-1),margin=f*0.2
                let shifts=[0.0,0.08,-0.08,0.16,-0.16,0.25,-0.25]
                for sy in shifts {for sx in shifts.prefix(5) {
                    let cx=center.x+sx*rect.width;var top=center.y-height/2,inks:[CGRect]=[]
                    top+=sy*rect.height
                    for m in measured {
                        let q=CGRect(x:cx-m.ink.width/2,y:top,width:m.ink.width,height:m.ink.height)
                        if !holds(q.insetBy(dx:-margin,dy:-margin)) || !clear(q) {inks=[];break}
                        inks.append(q);top+=m.ink.height+gap
                    }
                    if inks.count==measured.count {return Found(font:f,width:w,measured:measured,inks:inks)}
                }};return nil
            }
            func attempt(_ f:Double)->Found? {
                let narrow=ceil(members.map {widestWord($0.text,f)}.max() ?? 0)+2,wide=floor(Double(rect.width)-f*0.4-6)
                if narrow>wide {return nil}
                for k in 0...6 {
                    let w=floor(wide-(wide-narrow)*Double(k)/6+0.5)
                    if let found=place(f,w) {return found}
                    if probes>=480 {return nil}
                };return nil
            }
            var low=floorSize,high=ceiling,best=attempt(ceiling)
            if best==nil,let smallest=attempt(low) {
                best=smallest
                for _ in 0..<5 where high-low>0.25 {
                    let middle=floor((low+high)/2*4)/4;if middle<=low {break}
                    if let found=attempt(middle) {best=found;low=middle}else {high=middle}
                }
            }
            guard let best else {let why=probes>=480 ? "budget":"no-fit";outcome(why);records[indices[0]].blocked=why;continue}
            guard blocks(best.font,best.width,true) != nil else {continue}
            var proposed:[Record]=[],failed=false
            let pad=max(1,min(3,best.font*0.15))
            for i in members.indices {
                let m=best.measured[i],q=best.inks[i]
                let placement=Placement(rect:CGRect(x:q.minX-(m.ink.minX-m.nodeRect.minX),y:q.minY-(m.ink.minY-m.nodeRect.minY),width:m.nodeRect.width,height:m.nodeRect.height),font:best.font,pitch:best.font*ratios[i],padding:pad,order:i,members:members.count,from:sizes[i])
                let actual: CGRect
                if let verify {
                    guard let measured=verify(members[i],placement,m) else {failed=true;continue}
                    actual=measured
                } else {
                    actual=m.ink.offsetBy(dx:placement.rect.minX-m.nodeRect.minX,dy:placement.rect.minY-m.nodeRect.minY)
                }
                if abs(actual.minX-q.minX)>1 || abs(actual.minY-q.minY)>1 || abs(actual.maxY-q.maxY)>1 {failed=true}
                var record=members[i];record.placement=placement;record.ink=actual;record.font=placement.font;record.pitch=placement.pitch;proposed.append(record)
            }
            if failed {outcome("verify");continue}
            for (index,record) in zip(indices,proposed) {records[index]=record};layouts+=1
        }
        return Result(records:records,layouts:layouts,probes:probes,outcomes:outcomes)
    }
}
