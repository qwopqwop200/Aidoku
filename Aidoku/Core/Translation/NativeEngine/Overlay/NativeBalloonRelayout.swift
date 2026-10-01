import CoreGraphics
import Foundation

/// The final plated-caption reflow search. A candidate is committed only after
/// its final physical glyph rectangle has been measured on the same contour.
enum NativeBalloonRelayout {
    struct Entry {
        let text: String
        let renderedText: String
        let ink: CGRect
        let source: CGRect?
        let frame: CGRect?
        let font: Double
        let pitch: Double
        let foreign: [CGRect]
        var vertical = false
        var rotation: Double = 0
        var balancedColumn = false
        var wrappingScript = "korean"
        var visible = true
        var isUnit = false
        var hasInterior = true
        var tightInterior = false
        var strandedBefore = false
    }
    struct Candidate {
        let rect: CGRect
        let font: Double
        let pitch: Double
    }
    struct Measurement {
        let ink: CGRect
        let scrollWidth: Double
        let clientWidth: Double
        let splitsWord: Bool
        let strandedSyllable: Bool
    }
    struct Result {
        let candidate: Candidate
        let ink: CGRect
        let before: Double
        let outside: Double
        let oldLines: Int
        let newLines: Int
        let originalFont: Double
        var diagnostics: [Double] {
            [before, outside, Double(oldLines), Double(newLines)] +
                (candidate.font != originalFont ? [originalFont, candidate.font] : [])
        }
    }
    typealias Measure = (Candidate) -> Measurement?

    static func relayout(_ e: Entry, outside: (CGRect) -> Double, measure: Measure) -> Result? {
        guard !e.vertical, e.rotation == 0, !e.balancedColumn,
              ["korean", "word"].contains(e.wrappingScript), e.visible,
              !e.text.isEmpty, e.text.utf16.count <= 180, !e.text.contains("\r"), !e.text.contains("\n"),
              withoutSpace(e.text) == withoutSpace(e.renderedText),
              e.hasInterior, (!e.tightInterior || e.isUnit), let source = e.source,
              e.font.isFinite, e.font > 0 else { return nil }
        let size = e.font, lineHeight = e.pitch == 0 || !e.pitch.isFinite ? size * 1.2 : e.pitch
        let margin = max(1.5, size * 0.2)
        func grow(_ rect: CGRect) -> CGRect { rect.insetBy(dx: -margin, dy: -margin) }
        let before = outside(grow(e.ink))
        guard before >= 4 else { return nil }
        let oldLines = max(1, Int(floor(e.ink.height / lineHeight + 0.5)))
        let sx = source.midX, sy = source.midY
        var sizes = [size]
        if e.isUnit {
            var next = size - 0.5
            let minimum = max(size * 0.8, min(size, 8.5))
            while next >= minimum - 1e-6 { sizes.append(next); next -= 0.5 }
        }
        struct Best { let score: Double; let width: Double; let dx: Double; let dy: Double; let measurement: Measurement; let outside: Double; let font: Double; let pitch: Double; let count: Int }
        var best: Best?
        for fontSize in sizes {
            let lh = lineHeight * fontSize / size, tall = lh * Double(max(8, oldLines * 3))
            for scale in [1.0, 0.88, 0.76, 0.64, 0.54, 0.46] {
                let width = floor((Double(e.ink.width) * scale + 2) * 4) / 4
                if width < fontSize * 1.5 { break }
                let candidate = Candidate(rect: CGRect(x: sx - width / 2, y: sy - tall / 2, width: width, height: tall), font: fontSize, pitch: lh)
                guard let m = measure(candidate), m.scrollWidth <= m.clientWidth + 1, !m.splitsWord,
                      m.ink.width > 0, m.ink.height > 0 else { continue }
                let count = max(1, Int(floor(Double(m.ink.height) / lh + 0.5)))
                if m.strandedSyllable && !e.strandedBefore || count > oldLines && !growthKeepsLineLength(e.text, originalLines: oldLines, lines: count) { continue }
                let step = max(1, fontSize * 0.25), reach = fontSize * 2
                var dy = -reach
                while dy <= reach + 0.01 {
                    var dx = -reach
                    while dx <= reach + 0.01 {
                        let c = m.ink.offsetBy(dx: dx, dy: dy)
                        let framed = e.frame.map { c.minX >= $0.minX + 1 && c.minY >= $0.minY + 1 && c.maxX <= $0.maxX - 1 && c.maxY <= $0.maxY - 1 } ?? true
                        if framed {
                            let out = outside(grow(c))
                            if out <= before * 0.5 && before - out >= 4 &&
                                !e.foreign.contains(where: { c.minX - 1 < $0.maxX && c.maxX + 1 > $0.minX && c.minY - 1 < $0.maxY && c.maxY + 1 > $0.minY }) {
                                let score = out + 30 * Double(max(0, count - oldLines)) + 8 * hypot(dx, dy) / fontSize
                                if best == nil || best!.font == fontSize && score < best!.score || best!.font != fontSize && out < best!.outside {
                                    best = Best(score: score, width: width, dx: dx, dy: dy, measurement: m, outside: out, font: fontSize, pitch: lh, count: count)
                                }
                            }
                        }
                        dx += step
                    }
                    dy += step
                }
            }
            if let best, best.outside <= 2 { break }
        }
        guard let best else { return nil }
        let top = best.measurement.ink.minY + best.dy - 1
        let candidate = Candidate(rect: CGRect(x: sx - best.width / 2 + best.dx, y: top, width: best.width, height: best.measurement.ink.height + 2), font: best.font, pitch: best.pitch)
        guard let final = measure(candidate), final.ink.width > 0,
              outside(grow(final.ink)) <= best.outside + 2,
              final.scrollWidth <= final.clientWidth + 1, !final.splitsWord else { return nil }
        return Result(candidate: candidate, ink: final.ink, before: before, outside: outside(grow(final.ink)),
                      oldLines: oldLines, newLines: best.count, originalFont: size)
    }

    struct Interior {
        let rect: CGRect
        let scale: Double
        let width: Int
        let height: Int
        let fill: [UInt8]
        let surfaceRGB: [Double]
        let tight: Bool
        let integral: [Int]
        var native = false
        func outside(_ r: CGRect) -> Double {
            let x0 = Int(floor(Double(r.minX - rect.minX) * scale)), y0 = Int(floor(Double(r.minY - rect.minY) * scale))
            let x1 = Int(ceil(Double(r.maxX - rect.minX) * scale)), y1 = Int(ceil(Double(r.maxY - rect.minY) * scale))
            let total = max(0, x1 - x0) * max(0, y1 - y0)
            let cx0 = max(0,min(width,x0)), cy0 = max(0,min(height,y0)), cx1 = max(0,min(width,x1)), cy1 = max(0,min(height,y1))
            let stride = width + 1
            return Double(total - (integral[cy1 * stride + cx1] - integral[cy0 * stride + cx1] - integral[cy1 * stride + cx0] + integral[cy0 * stride + cx0]))
        }
    }
    /// The frozen nativeUnitInterior raster, including quantized span edges and
    /// integer summed-area queries. This is different from a Boolean contour fit.
    static func nativeUnitInterior(frame: CGRect, rect: [CGFloat], spans: [Double], surfaceRGB: [Double]? = nil) -> Interior? {
        guard [frame.minX,frame.minY,frame.width,frame.height].allSatisfy(\.isFinite), frame.width > 0, frame.height > 0,
              rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > 0, rect[3] > 0,
              spans.count >= 2, spans.count.isMultiple(of: 2), spans.allSatisfy(\.isFinite) else { return nil }
        let left = frame.minX + rect[0] * frame.width, top = frame.minY + rect[1] * frame.height
        let right = frame.minX + (rect[0] + rect[2]) * frame.width, bottom = frame.minY + (rect[1] + rect[3]) * frame.height
        let scale = min(2,sqrt(250_000 / max(1,Double((right-left)*(bottom-top)))))
        let w = Int(ceil(Double(right-left)*scale)), h = Int(ceil(Double(bottom-top)*scale))
        guard w >= 8, h >= 8 else { return nil }
        let count = spans.count / 2
        var fill = [UInt8](repeating:0,count:w*h), area = 0
        for y in 0..<h {
            let band = min(count-1,Int(floor((Double(y)+0.5)/Double(h)*Double(count))))
            let l = spans[band*2], rr = spans[band*2+1]
            if !(l >= 0 && rr > l) { continue }
            let x0 = max(0,Int(ceil((Double(frame.minX)+l*Double(frame.width)-Double(left))*scale-0.5)))
            let x1 = min(w,Int(floor((Double(frame.minX)+rr*Double(frame.width)-Double(left))*scale-0.5))+1)
            if x0 < x1 { for x in x0..<x1 {fill[y*w+x]=1;area+=1} }
        }
        guard area > 0 else { return nil }
        var integral = [Int](repeating:0,count:(w+1)*(h+1))
        for y in 0..<h {
            var run = 0
            for x in 0..<w {run+=Int(fill[y*w+x]);integral[(y+1)*(w+1)+x+1]=integral[y*(w+1)+x+1]+run}
        }
        let paper = surfaceRGB.flatMap { $0.count == 3 && $0.allSatisfy(\.isFinite) ? $0 : nil } ?? [255,255,255]
        return Interior(rect:CGRect(x:left,y:top,width:right-left,height:bottom-top),scale:scale,width:w,height:h,
                        fill:fill,surfaceRGB:paper,tight:false,integral:integral,native:true)
    }

    private static func withoutSpace(_ text: String) -> String {
        String(text.unicodeScalars.filter { !space($0.value) })
    }
    private static func space(_ code: UInt32) -> Bool {
        [0x9,0xA,0xB,0xC,0xD,0x20,0xA0,0x1680,0x2028,0x2029,0x202F,0x205F,0x3000,0xFEFF].contains(code) || code >= 0x2000 && code <= 0x200A
    }
    private static func growthKeepsLineLength(_ text: String, originalLines: Int, lines: Int) -> Bool {
        let count = withoutSpace(text).utf16.count
        guard count > 0, lines >= 1 else { return false }
        if lines < 3 || count < 8 { return true }
        return Double(count) / Double(lines) >= 2.5 || Double(count) / Double(lines) >= Double(count) / Double(max(1, originalLines))
    }
}
