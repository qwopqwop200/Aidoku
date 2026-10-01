import CoreGraphics
import Foundation

/// The final opaque-plate readability pass, independent of source-repair trials.
/// Counter semantics and the source-paper read budget match the frozen pass.
enum NativeRotatedReadability {
    typealias Polygon = [[Double]]
    struct Entry {
        var text: String
        var renderedText: String
        var rect: CGRect
        var font: Double
        var pitch: Double
        var scale: Double = 1
        var angle: Double
        var background: [Double]
        var padding: [Double] = [0,0,0,0]
        var frame: CGRect?
        var imageSize: CGSize?
        var opaque = true
        var rootOwned = true
        var rotatingPanel = true
        var backgroundKind = "rotated-panel"
        var visible = true
        var uprightQuad = false
        var childCount = 0
        var vertical = false
        var korean = true
        var hasBackgroundImage = false
        var others: [Polygon] = []
        var lettering: [Polygon] = []
    }
    struct Candidate {
        var rect: CGRect
        var font: Double
        var pitch: Double
        var scale: Double
        var side: Double
        var paddingOverride: [Double]? = nil
        var padding: [Double] { paddingOverride ?? [0, side / scale, 0, side / scale] }
        var paintedWidth: Double { Double(rect.width) * scale }
    }
    struct Measurement {
        var rows: Int
        var broken: Bool
        var overflowWidth: Bool = false
        var overflowHeight: Bool = false
        /// Range union refined by whole-caption canvas metrics, local CSS axes.
        var ink: CGRect?
    }
    struct Budget {
        var pixels = 786_432
        var layouts = 0
        var lifted = 0
    }
    struct Result {
        var candidate: Candidate
        var ink: Polygon
        var clip: Polygon?
        var metadata: [String: String]
    }
    struct Hooks {
        var measure: (Candidate) -> Measurement?
        var longestWord: (Double) -> Double
        var read: (CGRect) -> [UInt8]?
    }
    static func valid(_ entry: Entry, opacity: Double, itemCount: Int) -> Bool {
        opacity == 1 && itemCount <= 256 && entry.rootOwned && entry.rotatingPanel && entry.backgroundKind == "rotated-panel" &&
            entry.visible && !entry.uprightQuad && entry.childCount == 0 && !entry.vertical && entry.korean &&
            !entry.text.isEmpty && entry.text.utf16.count <= 180 && !entry.text.contains("\r") && !entry.text.contains("\n") &&
            entry.renderedText == entry.text && entry.font > 0 && entry.font < 8.5 && entry.opaque && !entry.hasBackgroundImage &&
            entry.background.count == 3 && [entry.rect.minX,entry.rect.minY,entry.rect.width,entry.rect.height].allSatisfy(\.isFinite) &&
            entry.rect.size.width > 0 && entry.rect.size.height > 0
    }
    static func card(_ e: Entry, width: Double, height: Double, margin: Double = 0) -> Polygon {
        NativeSlantedGeometry.rotatedCard(cx: e.rect.midX,cy: e.rect.midY,width: width,height: height,angle: e.angle,margin: margin)
    }
    static func inkCard(_ e: Entry, ink: CGRect, candidate: Candidate) -> Polygon {
        let dx = (Double(ink.midX) - Double(candidate.rect.width) / 2) * candidate.scale
        let dy = Double(ink.midY) - Double(candidate.rect.height) / 2
        let cs = cos(e.angle), sn = sin(e.angle)
        return NativeSlantedGeometry.rotatedCard(cx: Double(e.rect.midX) + dx * cs - dy * sn,
            cy: Double(e.rect.midY) + dx * sn + dy * cs,width: Double(ink.width) * candidate.scale,
            height: Double(ink.height),angle: e.angle,margin: 1.5)
    }
    static func placed(_ e: Entry, font: Double, scale: Double, width: Double, height: Double, pitch: Double, side: Double) -> Candidate {
        let cssWidth = width / scale
        return Candidate(rect: CGRect(x: Double(e.rect.midX) - cssWidth / 2,y: Double(e.rect.midY) - height / 2,width: cssWidth,height: height),
                         font: font,pitch: pitch,scale: scale,side: side)
    }
    static func attempt(_ e: Entry, font: Double, scale: Double, width: Double, grow: Bool,
                        budget: inout Budget, measure: (Candidate) -> Measurement?) -> (Candidate,Polygon)? {
        budget.layouts += 1
        let side = max(1,font * 0.1), margin = max(1.5,font * 0.12)
        let ratio = e.pitch / e.font, pitch = font * max(1.1,min(1.2,ratio == 0 || !ratio.isFinite ? 1.2 : ratio))
        var c = placed(e,font: font,scale: scale,width: width,height: max(Double(e.rect.height),font * 1.2) * 8,pitch: pitch,side: side)
        guard let first = measure(c), first.rows > 0, !first.broken else { return nil }
        let height = grow ? max(Double(e.rect.height),Double(first.rows) * pitch + margin * 2) : Double(e.rect.height)
        guard Double(first.rows) * pitch <= height + 0.01 else { return nil }
        c = placed(e,font: font,scale: scale,width: width,height: height,pitch: pitch,side: side)
        guard let laid = measure(c), laid.rows == first.rows, !laid.broken, !laid.overflowWidth, !laid.overflowHeight,
              let ink = laid.ink else { return nil }
        guard Double(ink.minX) * scale >= side - 0.5,
              (Double(c.rect.width) - Double(ink.maxX)) * scale >= side - 0.5,
              Double(ink.minY) >= margin - 0.5, Double(ink.maxY) <= height - margin + 0.5 else { return nil }
        return (c,inkCard(e,ink: ink,candidate: c))
    }
    static func paperFits(_ e: Entry, width: Double, height: Double, budget: inout Budget, read: (CGRect) -> [UInt8]?) -> Bool {
        guard let frame = e.frame, let image = e.imageSize, frame.width > 0,frame.height > 0,image.width > 0,image.height > 0 else { return false }
        let grown = card(e,width: width + 2,height: height + 2)
        guard grown.allSatisfy({ $0[0] >= frame.minX && $0[1] >= frame.minY && $0[0] <= frame.maxX && $0[1] <= frame.maxY }) else { return false }
        let kx = Double(image.width / frame.width), ky = Double(image.height / frame.height)
        let left = max(0,floor((grown.map { $0[0] }.min()! - Double(frame.minX)) * kx))
        let top = max(0,floor((grown.map { $0[1] }.min()! - Double(frame.minY)) * ky))
        let right = min(Double(image.width),ceil((grown.map { $0[0] }.max()! - Double(frame.minX)) * kx))
        let bottom = min(Double(image.height),ceil((grown.map { $0[1] }.max()! - Double(frame.minY)) * ky))
        let w = Int(right - left), h = Int(bottom - top)
        guard w > 0,h > 0,w * h <= 262_144,w * h <= budget.pixels else { return false }
        budget.pixels -= w * h
        guard let rgba = read(CGRect(x:left,y:top,width:Double(w),height:Double(h))), rgba.count >= w * h * 4 else { return false }
        let cs = cos(e.angle),sn = sin(e.angle), W0 = Double(e.rect.width) * e.scale,H0 = Double(e.rect.height)
        var count = 0,sum = 0.0
        for y in 0..<h { for x in 0..<w {
            let px = (left + Double(x) + 0.5) / kx + Double(frame.minX - e.rect.midX)
            let py = (top + Double(y) + 0.5) / ky + Double(frame.minY - e.rect.midY)
            let lx = abs(px * cs + py * sn),ly = abs(-px * sn + py * cs)
            if lx > width / 2 + 1 || ly > height / 2 + 1 || lx <= W0 / 2 && ly <= H0 / 2 { continue }
            let i = (y * w + x) * 4
            let d = max(abs(Double(rgba[i]) - e.background[0]),abs(Double(rgba[i+1]) - e.background[1]),abs(Double(rgba[i+2]) - e.background[2]))
            if d > 24 { return false }
            count += 1;sum += d
        } }
        return count == 0 || sum / Double(count) <= 8
    }
    static func run(_ e: Entry, opacity: Double = 1, itemCount: Int = 1, budget: inout Budget, hooks: Hooks) -> Result? {
        guard valid(e,opacity: opacity,itemCount: itemCount) else { return nil }
        let sizes = [9.0,8.75,8.5].filter { $0 >= e.font + 0.25 && $0 <= e.font * 2 }
        guard !sizes.isEmpty else { return nil }
        let W0 = Double(e.rect.width) * e.scale,H0 = Double(e.rect.height)
        let before = e.others.map { NativeSlantedGeometry.convexDepth(card(e,width: W0,height: H0,margin: max(1,9 * 0.35)),$0) }
        let start = Candidate(rect: e.rect,font: e.font,pitch: e.pitch,scale: e.scale,side: 0,paddingOverride: e.padding)
        guard let startInk = hooks.measure(start)?.ink else { return nil }
        let inkBefore = e.lettering.map { NativeSlantedGeometry.convexDepth(inkCard(e,ink: startInk,candidate: start),$0) }
        for (factor,grow) in [(1.0,false),(1.0,true),(1.15,true),(1.3,true),(1.5,true),(1.75,true),(2.0,true),(2.5,true)] {
            for size in sizes {
                let width = W0 * factor,side = max(1,size * 0.1),longest = hooks.longestWord(size)
                for scale in [1.0,0.9] {
                    if scale < 1 ? !NativeSlantedTypographyTrial.condensedWordBound(longest,width - side * 2) : longest > width - side * 2 { continue }
                    guard let (c,ink) = attempt(e,font: size,scale: scale,width: width,grow: grow,budget: &budget,measure: hooks.measure) else { continue }
                    let reach = card(e,width: width,height: Double(c.rect.height),margin: max(1,size * 0.35))
                    if e.others.enumerated().contains(where: { NativeSlantedGeometry.convexDepth(reach,$0.element) > before[$0.offset] + 0.5 }) { continue }
                    if e.lettering.enumerated().contains(where: { NativeSlantedGeometry.convexDepth(ink,$0.element) > inkBefore[$0.offset] + 0.25 }) { continue }
                    let grown = width > W0 + 0.01 || Double(c.rect.height) > H0 + 0.01
                    if grown && !paperFits(e,width: width,height: Double(c.rect.height),budget: &budget,read: hooks.read) { continue }
                    var clip: Polygon?
                    if let f = e.frame {
                        let cs = cos(e.angle),sn = sin(e.angle),cx = Double(e.rect.midX),cy = Double(e.rect.midY)
                        clip = [[f.minX,f.minY],[f.maxX,f.minY],[f.maxX,f.maxY],[f.minX,f.maxY]].map { p in
                            [((p[0] - cx) * cs + (p[1] - cy) * sn) / scale + Double(c.rect.width) / 2,
                             -(p[0] - cx) * sn + (p[1] - cy) * cs + Double(c.rect.height) / 2]
                        }
                    }
                    func js(_ n: Double) -> String {n.rounded() == n ? String(Int(n)) : String(n)}
                    var metadata = ["readableLift":"\(js(e.font))->\(js(size))","readablePeer":js(e.font),
                        "readableLiftBox":"\(js(floor(width / W0 * 100 + 0.5) / 100))x\(js(floor(Double(c.rect.height) / H0 * 100 + 0.5) / 100))"]
                    if scale < 1 { metadata["bodyCondensed"] = js(scale) }
                    budget.lifted += 1
                    return .init(candidate: c,ink: ink,clip: clip,metadata: metadata)
                }
            }
        }
        return nil
    }
}
