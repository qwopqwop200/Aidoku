import CoreGraphics
import Foundation

/// Mode-specific fitBalloon search4484–4972. Glyph shaping and surface inspection
/// are explicit callbacks; rejected placements still publish their measured ink
/// frame for the subsequent clear-region search.
enum NativeEarlyBalloonSearch {
    final class Session {
        var typeBudget = 32_768
        var surfaceBudget = 2_097_152
        var centreFrames: [String: [String: CGRect]] = [:]
    }
    struct Input {
        var id: String
        var font: CGFloat
        var priorFont: CGFloat?
        var minimum: CGFloat = 5
        var sourceGlyph: CGFloat
        var sourceWidth: CGFloat
        var baseWidth: CGFloat
        var sourceCentre: CGPoint
        var originalCentre: CGPoint
        var offsetSearch = false
        var clearSearch = false
        var provisional = false
        var auxiliaryOriginalPreserved = false
    }
    struct Grid {
        var width: Int
        var height: Int
        var crop: CGRect
        var kx: CGFloat
        var ky: CGFloat
        var sourceSpan: CGRect
        var clear: (Int, Int, Int, Int) -> Bool
    }
    struct Attempt<Value> {
        var frame: CGRect? = nil
        var value: Value? = nil
        var rank: Int = 0
    }
    struct Accepted<Value> {
        var value: Value
        var size: CGFloat
        var width: CGFloat
        var wordFlow: Bool
        var emergency: Bool
        var clearRegion: Bool
    }
    static func run<Value>(_ input: Input, session: Session,
        fontSizes: (CGFloat, CGFloat) -> [CGFloat], restoredFloor: (CGFloat, CGFloat) -> CGFloat?,
        emergencySizes: (CGFloat, CGFloat, [CGFloat]) -> [CGFloat],
        lineWidth: (CGFloat) -> CGFloat, wordWidth: (CGFloat) -> CGFloat,
        makeGrid: () -> Grid?,
        layout: (CGFloat, CGPoint, CGFloat, CGSize) -> Attempt<Value>) -> Accepted<Value>? {
        let measured = input.clearSearch ? session.centreFrames[input.id]:nil
        session.centreFrames[input.id] = nil
        let font = input.font, prior = input.priorFont.flatMap { $0 == 0 || $0.isNaN ? nil:$0 } ?? font
        guard font.isFinite, font > 0, let floor = restoredFloor(prior, input.minimum) else { return nil }
        var sizes = fontSizes(font, input.minimum).filter { $0 >= floor }
        let emergency = input.auxiliaryOriginalPreserved ? []:emergencySizes(prior,input.minimum,sizes).filter { $0 < font }
        sizes += emergency.filter { !input.provisional || $0 >= 7 }
        if input.offsetSearch {
            sizes = sizes.filter { $0 >= 7 }.reversed()
            if font > 7 && !sizes.contains(7) { sizes.insert(7,at:0) }
        }
        if input.clearSearch { sizes = sizes.filter { $0 >= min(font,8.5) && !emergency.contains($0) } }
        if input.clearSearch {
            let glyph = input.sourceGlyph
            guard glyph.isFinite else { return nil }
            let potential = Foundation.floor(max(min(32,glyph*0.95,font*3),glyph>=40 ? min(64,glyph*0.8,font*3):0)*4)/4
            if potential >= font*1.1 {
                let lower = min(potential,32)*0.85
                var larger: [CGFloat] = []
                for i in 0..<6 {
                    let size = Foundation.floor((potential-(potential-font)*CGFloat(i)/6)*4)/4
                    if size > font && !larger.contains(size) { larger.append(size) }
                }
                sizes = (larger + sizes.filter { $0 <= font }).filter { $0 >= lower }
            }
        }
        guard !sizes.isEmpty else { return nil }
        var centres = input.offsetSearch ? [input.sourceCentre,
            CGPoint(x:input.sourceCentre.x-6,y:input.sourceCentre.y),CGPoint(x:input.sourceCentre.x+6,y:input.sourceCentre.y),
            CGPoint(x:input.sourceCentre.x,y:input.sourceCentre.y-6),CGPoint(x:input.sourceCentre.x,y:input.sourceCentre.y+6),
            CGPoint(x:input.sourceCentre.x-12,y:input.sourceCentre.y),CGPoint(x:input.sourceCentre.x+12,y:input.sourceCentre.y),
            CGPoint(x:input.sourceCentre.x,y:input.sourceCentre.y-12),CGPoint(x:input.sourceCentre.x,y:input.sourceCentre.y+12)]
            :[input.sourceCentre,input.originalCentre]
        var seen: [CGPoint] = []
        centres = centres.filter { point in
            if seen.contains(where:{abs($0.x-point.x)<0.5 && abs($0.y-point.y)<0.5}) { return false }
            seen.append(point);return true
        }
        func widths(_ size: CGFloat) -> [CGFloat] {
            var raw = [input.baseWidth*size/font,input.sourceWidth,input.baseWidth*0.75,input.baseWidth*1.15,input.sourceWidth*0.8]
            if input.offsetSearch { raw += [input.sourceWidth*0.6,input.baseWidth*0.55] }
            let advance = lineWidth(size)
            if advance+2 < size*1.8 { raw.append(ceil((advance+2)*4)/4) }
            var distinct: [CGFloat] = []
            for value in raw {
                let width = Foundation.floor(value*4)/4
                if !distinct.contains(width) { distinct.append(width) }
            }
            return distinct
        }
        func margin(_ size: CGFloat) -> CGSize {
            input.clearSearch && size>font ? CGSize(width:max(1,size*0.1),height:max(0.75,size*0.1)):.init(width:1,height:0.75)
        }
        func key(_ size:CGFloat,_ width:CGFloat)->String { "\(Double(size))|\(Double(width))" }
        var frames: [String: CGRect] = [:], attempts = 0, exhausted = false
        func measure(_ size:CGFloat,_ anchor:CGPoint,_ width:CGFloat)->Attempt<Value> {
            let result = layout(size,anchor,width,margin(size))
            if !input.clearSearch,anchor == input.sourceCentre,let frame=result.frame { frames[key(size,width)]=frame }
            return result
        }
        func fit(_ size:CGFloat,_ anchor:CGPoint,_ measures:[CGFloat])->Accepted<Value>? {
            var best: (width:CGFloat,rank:Int,first:Bool,value:Value)?
            var first: (width:CGFloat,rank:Int,first:Bool,value:Value)?
            var last: CGFloat?
            for index in measures.indices {
                let previous = attempts; attempts += 1
                if previous >= 90+emergency.count*10 { exhausted=true;return nil }
                let passed = measure(size,anchor,measures[index]);last = passed.value != nil ? measures[index]:nil
                guard let value=passed.value else { continue }
                best=(measures[index],passed.rank,true,value);first=best
                if passed.rank>0 {
                    for other in Array(measures.dropFirst(index+1))+[Foundation.floor(wordWidth(size)*4)/4] {
                        if other == best?.width { continue }
                        let repaired = measure(size,anchor,other);last = repaired.value != nil ? other:nil
                        if let value=repaired.value,let current=best,repaired.rank<current.rank { best=(other,repaired.rank,false,value) }
                        if best?.rank == 0 { break }
                    }
                }
                break
            }
            guard var winner=best else { return nil }
            if last != winner.width,measure(size,anchor,winner.width).value == nil {
                guard let fallback=first,measure(size,anchor,fallback.width).value != nil else { return nil }
                winner=fallback
            }
            return Accepted(value:winner.value,size:size,width:winner.width,wordFlow:!winner.first,
                emergency:emergency.contains(size),clearRegion:false)
        }
        if !input.clearSearch {
            for size in sizes { for anchor in centres {
                if let accepted=fit(size,anchor,widths(size)) { return accepted }
                if exhausted { return nil }
            } }
            session.centreFrames[input.id]=frames;return nil
        }
        guard let grid=makeGrid(),grid.kx>0,grid.ky>0 else { return nil }
        let scx=(input.sourceCentre.x-grid.crop.minX)*grid.kx,scy=(input.sourceCentre.y-grid.crop.minY)*grid.ky
        var moves=0
        search: for size in sizes {
            let measures=widths(size)
            for width in measures {
                let previous=attempts;attempts += 1
                if previous >= 90+emergency.count*10 { break search }
                var next=measured?[key(size,width)]
                if next == nil {
                    let attempt=measure(size,input.sourceCentre,width)
                    if attempt.value != nil {
                        if let accepted=fit(size,input.sourceCentre,[width]+measures.filter { $0 != width }) { return accepted }
                        if exhausted { return nil }
                        continue
                    }
                    next=attempt.frame
                }
                guard let frame=next else { continue }
                let m=margin(size),bw=Int(ceil((frame.width+2*m.width)*grid.kx))+2,bh=Int(ceil((frame.height+2*m.height)*grid.ky))+2
                if bw>grid.width || bh>grid.height { continue }
                let ox=frame.midX-input.sourceCentre.x,oy=frame.midY-input.sourceCentre.y
                let span=grid.sourceSpan
                let t0=max(0,Int(ceil(span.minY-CGFloat(bh)/2))),t1=min(grid.height-bh,Int(Foundation.floor(span.maxY-CGFloat(bh)/2)))
                let l0=max(0,Int(ceil(span.minX-CGFloat(bw)/2))),l1=min(grid.width-bw,Int(Foundation.floor(span.maxX-CGFloat(bw)/2)))
                var best:(l:Int,t:Int,d:CGFloat)?
                if t0<=t1 && l0<=l1 { for t in t0...t1 { for l in l0...l1 {
                    let d=pow(CGFloat(l)+CGFloat(bw)/2-scx,2)+pow(CGFloat(t)+CGFloat(bh)/2-scy,2)
                    if best.map({d >= $0.d}) == true || !grid.clear(l,t,bw,bh) { continue }
                    best=(l,t,d)
                } } }
                guard let best else { continue }
                let anchor=CGPoint(x:grid.crop.minX+(CGFloat(best.l)+CGFloat(bw)/2)/grid.kx-ox,
                    y:grid.crop.minY+(CGFloat(best.t)+CGFloat(bh)/2)/grid.ky-oy)
                if abs(anchor.x-input.sourceCentre.x)<0.5 && abs(anchor.y-input.sourceCentre.y)<0.5 { continue }
                moves += 1;if moves>12 { break search }
                if var accepted=fit(size,anchor,[width]+measures.filter { $0 != width }) { accepted.clearRegion=true;return accepted }
                if exhausted { break search }
            }
        }
        return nil
    }
}
