import CoreGraphics
import CoreText
import Foundation

/// Raw-contour proposals for the parent's standalone Item boundary.
/// No prepared Card, panel rectangle, source image global, labels or page selection.
enum NativeRawBalloonCapacity {
    struct Geometry {
        let glyphs: [CGRect]
        let rows: Int
        let complete: Bool
        let cuts: Int
        let singles: Int
    }
    struct Proposal {
        let item: NativeAOTRawTextPainter.Item
        let geometry: Geometry
        let fontFloor: CGFloat
    }
    struct Contour {
        let rect: CGRect
        let spans: [(CGFloat,CGFloat)]
        func contains(_ glyph: CGRect) -> Bool {
            guard rect.contains(glyph), !glyph.isEmpty else { return false }
            let step = rect.height/CGFloat(spans.count)
            let a = max(0,Int(floor((glyph.minY-rect.minY)/step)))
            let b = min(spans.count-1,Int(ceil((glyph.maxY-rect.minY)/step))-1)
            return a <= b && (a...b).allSatisfy { glyph.minX >= spans[$0].0 && glyph.maxX <= spans[$0].1 }
        }
    }
    static func contour(raw: [String:Any], viewport: CGSize) -> Contour? {
        let unit = raw["balloonUnit"] as? [String:Any]
        guard let obj = raw["balloonInterior"] as? [String:Any] ?? unit?["interior"] as? [String:Any],
              obj["contourVerified"] as? Bool == true, let r = obj["rect"] as? [Double],r.count == 4,
              let s = obj["spans"] as? [Double],s.count >= 4,s.count <= 2048,s.count%2 == 0,
              (r+s).allSatisfy(\.isFinite),r[2] > 0,r[3] > 0,
              CGRect(x:0,y:0,width:1,height:1).contains(CGRect(x:r[0],y:r[1],width:r[2],height:r[3])) else { return nil }
        var spans: [(CGFloat,CGFloat)] = []
        for i in stride(from:0,to:s.count,by:2) {
            guard s[i] >= r[0],s[i+1] <= r[0]+r[2],s[i] < s[i+1] else { return nil }
            spans.append((CGFloat(s[i])*viewport.width,CGFloat(s[i+1])*viewport.width))
        }
        guard zip(spans,spans.dropFirst()).allSatisfy({ min($0.0.1,$0.1.1) > max($0.0.0,$0.1.0) }) else { return nil }
        return Contour(rect:CGRect(x:r[0]*viewport.width,y:r[1]*viewport.height,width:r[2]*viewport.width,height:r[3]*viewport.height),spans:spans)
    }
    static let minimumOwnerMaskCoverage: CGFloat = 0.7

    /// Association belongs to the active source-text owner, not a nearby
    /// detector rectangle or the contour's own enclosing bounding box.
    static func isConnected(_ contour: Contour, raw: [String: Any], viewport: CGSize) -> Bool {
        guard raw["keptLettering"] as? Bool != true, raw["sourceTextOnly"] as? Bool != true,
              !(raw["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              let b = raw["sourceBounds"] as? [Double], b.count == 4, b.allSatisfy(\.isFinite),
              b[2] > 0, b[3] > 0, !contour.spans.isEmpty else { return false }
        let owner = CGRect(x:b[0]*viewport.width,y:b[1]*viewport.height,
            width:b[2]*viewport.width,height:b[3]*viewport.height)
        guard owner.width*owner.height > 0, contour.rect.contains(CGPoint(x:owner.midX,y:owner.midY)) else { return false }
        let step = contour.rect.height/CGFloat(contour.spans.count)
        guard step.isFinite, step > 0 else { return false }
        let centreRow = min(contour.spans.count-1,max(0,Int(floor((owner.midY-contour.rect.minY)/step))))
        guard owner.midX >= contour.spans[centreRow].0, owner.midX <= contour.spans[centreRow].1 else { return false }
        var covered: CGFloat = 0
        for (row, span) in contour.spans.enumerated() {
            let height = max(0,min(owner.maxY,contour.rect.minY+CGFloat(row+1)*step)
                - max(owner.minY,contour.rect.minY+CGFloat(row)*step))
            covered += height*max(0,min(owner.maxX,span.1)-max(owner.minX,span.0))
        }
        return covered/(owner.width*owner.height) >= minimumOwnerMaskCoverage - 1e-12
    }

    static func connectedContour(raw: [String: Any], viewport: CGSize) -> Contour? {
        if let result = contour(raw:raw,viewport:viewport) {
            return isConnected(result,raw:raw,viewport:viewport) ? result : nil
        }
        // A supported source estimate is an additional placement constraint,
        // not a native-mask receipt. Keep contour(raw:) verified-only so callers
        // cannot manufacture certification by parsing an estimated body.
        return NativeEnsembleLayoutContour.estimatedPlacementConstraint(raw:raw,viewport:viewport)
    }

    static func attributes(fontSize: CGFloat, pitch: CGFloat) -> [NSAttributedString.Key:Any] {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString,fontSize,nil)
        var alignment = CTTextAlignment.center, lo = max(fontSize,pitch), hi = max(fontSize,pitch)
        let paragraph = withUnsafePointer(to:&alignment) { a in withUnsafePointer(to:&lo) { l in withUnsafePointer(to:&hi) { h in
            let settings = [CTParagraphStyleSetting(spec:.alignment,valueSize:MemoryLayout<CTTextAlignment>.size,value:a),
                CTParagraphStyleSetting(spec:.minimumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:l),
                CTParagraphStyleSetting(spec:.maximumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:h)]
            return CTParagraphStyleCreate(settings,settings.count)
        } } }
        return [.init(kCTFontAttributeName as String):font,.init(kCTParagraphStyleAttributeName as String):paragraph]
    }
    static func measure(_ item: NativeAOTRawTextPainter.Item) -> Geometry {
        let attr = attributes(fontSize:item.fontSize,pitch:item.lineHeight)
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string:item.text,attributes:attr))
        let frame = CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:CGRect(origin:.zero,size:item.frame.size),transform:nil),nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating:.zero,count:lines.count)
        CTFrameGetLineOrigins(frame,CFRange(location:0,length:0),&origins)
        var glyphs: [CGRect] = [], cuts = 0, singles = 0
        let ns = item.text as NSString
        for (index,line) in lines.enumerated() {
            let range = CTLineGetStringRange(line), end = range.location+range.length
            if ns.substring(with:NSRange(location:range.location,length:range.length)).trimmingCharacters(in:.whitespacesAndNewlines).count == 1 { singles += 1 }
            if end > 0,end < ns.length,
               ns.substring(with:NSRange(location:end-1,length:1)).rangeOfCharacter(from:.letters) != nil,
               ns.substring(with:NSRange(location:end,length:1)).rangeOfCharacter(from:.letters) != nil { cuts += 1 }
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = attrs[kCTFontAttributeName] as! CTFont
                let count = CTRunGetGlyphCount(run)
                var gs = [CGGlyph](repeating:0,count:count), ps = [CGPoint](repeating:.zero,count:count)
                CTRunGetGlyphs(run,CFRange(location:0,length:0),&gs)
                CTRunGetPositions(run,CFRange(location:0,length:0),&ps)
                var bounds = [CGRect](repeating:.zero,count:count)
                CTFontGetBoundingRectsForGlyphs(font,.default,&gs,&bounds,count)
                for j in 0..<count where !bounds[j].isEmpty {
                    let b = bounds[j].offsetBy(dx:origins[index].x+ps[j].x,dy:origins[index].y+ps[j].y)
                    glyphs.append(CGRect(x:item.frame.minX+b.minX,y:item.frame.minY+item.frame.height-b.maxY,width:b.width,height:b.height))
                }
            }
        }
        return Geometry(glyphs:glyphs,rows:lines.count,complete:visible.location == 0 && visible.length == item.text.utf16.count,cuts:cuts,singles:singles)
    }
    static func wholeWords(_ text: String, width: CGFloat, font: CGFloat) -> String? {
        let attrs = attributes(fontSize:font,pitch:font*1.2)
        func length(_ s: String) -> CGFloat { CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string:s,attributes:attrs)),nil,nil,nil)) }
        var rows: [String] = []
        for paragraph in text.components(separatedBy:"\n") {
            var row = ""
            for token in paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                guard length(token) <= width-1 else { return nil }
                let next = row.isEmpty ? token : row+" "+token
                if length(next) > width-1 { rows.append(row); row = token } else { row = next }
            }
            rows.append(row)
        }
        return rows.joined(separator:"\n")
    }
    static func normalized(_ text:String) -> String { text.filter { !$0.isWhitespace } }
    /// Accumulate whole-word capacity and center refinements on the same owners.
    /// Never restart a later phase from the original page baseline.
    static func admit(rawItems: [[String:Any]], viewport: CGSize,
                      incumbents: [NativeAOTRawTextPainter.Item]) -> [NativeAOTRawTextPainter.Item] {
        var current = incumbents
        let raw = Dictionary(uniqueKeysWithValues:rawItems.compactMap { item -> (String,[String:Any])? in
            (item["id"] as? String).map { ($0,item) }
        })
        for phase in [3,4] {
            for i in current.indices {
                guard let owner = raw[current[i].id] else { continue }
                if let candidate = propose(raw:owner,viewport:viewport,incumbent:current[i],peers:current,revision:phase) {
                    current[i] = candidate.item
                }
            }
        }
        return current
    }
    static func propose(raw: [String:Any], viewport: CGSize, incumbent: NativeAOTRawTextPainter.Item,
                        peers: [NativeAOTRawTextPainter.Item], revision: Int = 4) -> Proposal? {
        guard raw["keptLettering"] as? Bool != true,raw["sourceTextOnly"] as? Bool != true,
              raw["vertical"] as? Bool != true,(raw["rotation"] as? NSNumber)?.doubleValue ?? 0 == 0,
              let surface = connectedContour(raw:raw,viewport:viewport),
              let b = raw["sourceBounds"] as? [Double],b.count == 4,
              let text = raw["typesettingText"] as? String ?? raw["text"] as? String else { return nil }
        let before = measure(incumbent)
        guard before.rows > 1 || !before.complete || before.cuts > 0 else { return nil }
        let sourceFont = (raw["sourceFontSize"] as? NSNumber)?.doubleValue ?? Double(incumbent.fontSize)
        let rawFont = (raw["fontSize"] as? NSNumber)?.doubleValue ?? Double(incumbent.fontSize)
        let desired = max(incumbent.fontSize,min(CGFloat(sourceFont)*0.9,CGFloat(rawFont)*1.4))
        let center = CGPoint(x:(b[0]+b[2]/2)*viewport.width,y:(b[1]+b[3]/2)*viewport.height)
        let peerGlyphs = peers.filter { $0.id != incumbent.id }.flatMap { measure($0).glyphs }
        let oldBounds = before.glyphs.reduce(CGRect.null) { $0.union($1) }
        let oldDistance = hypot(oldBounds.midX-center.x,oldBounds.midY-center.y)
        var best: Proposal?, bestScore = -CGFloat.infinity
        for factor: CGFloat in [1,0.94,0.88,0.82,0.76] {
            let font = max(incumbent.fontSize,desired*factor),pitch = font*1.2
            for fraction: CGFloat in [1,0.9,0.8,0.7,0.6,0.5,0.4] {
                let width = surface.rect.width*fraction
                guard revision < 4 || width >= font*2 else { continue }
                guard let wrapped = wholeWords(text,width:width,font:font),normalized(text) == normalized(wrapped) else { continue }
                let rows = wrapped.components(separatedBy:"\n").count
                let height = pitch*CGFloat(rows)+font*0.3
                guard height < surface.rect.height else { continue }
                for shift: CGFloat in [-0.5,0,0.5] {
                    var box = CGRect(x:center.x-width/2,y:center.y-height/2+shift*font,width:width,height:height)
                    var item = NativeAOTRawTextPainter.Item(id:incumbent.id,text:wrapped,frame:box,fontSize:font,lineHeight:pitch,
                        chosenFill:incumbent.chosenFill,colorAuthority:incumbent.colorAuthority)
                    var g = measure(item)
                    if revision >= 4, !g.glyphs.isEmpty {
                        let ink = g.glyphs.reduce(CGRect.null) { $0.union($1) }
                        box = box.offsetBy(dx:center.x-ink.midX,dy:center.y+shift*font-ink.midY)
                        item = .init(id:item.id,text:item.text,frame:box,fontSize:font,lineHeight:pitch,
                            chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
                        g = measure(item)
                    }
                    let newBounds = g.glyphs.reduce(CGRect.null) { $0.union($1) }
                    let centerGain = oldDistance-hypot(newBounds.midX-center.x,newBounds.midY-center.y)
                    guard g.complete,g.cuts == 0,g.singles <= before.singles,!g.glyphs.isEmpty,
                          revision < 4 || CGRect(origin:.zero,size:viewport).contains(box),
                          g.glyphs.allSatisfy({ surface.contains($0.insetBy(dx:-0.5,dy:-0.5)) }),
                          !g.glyphs.contains(where:{ a in peerGlyphs.contains { a.insetBy(dx:-0.5,dy:-0.5).intersects($0) } }),
                          font >= incumbent.fontSize*1.08 || g.cuts < before.cuts || g.singles < before.singles || !before.complete
                            || (revision >= 3 && centerGain >= font*0.5) else { continue }
                    if revision == 1, before.cuts == 0,before.singles == 0,g.rows < before.rows { continue }
                    let score = font/max(1,desired)*10-CGFloat(g.singles)*4-abs(box.midY-center.y)/surface.rect.height-CGFloat(g.rows)*0.03
                    if score > bestScore { best = Proposal(item:item,geometry:g,fontFloor:incumbent.fontSize);bestScore = score }
                }
            }
        }
        return best
    }
}
