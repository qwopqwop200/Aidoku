import CoreGraphics
import Foundation

/// Initial artwork protection freezes the accepted lines before reducing font
/// metrics. The old erasure plate is released only by an owned restored surface.
enum NativeArtworkProtection {
    struct Flow {
        var breaks = 0
        var badStarts = 0
        var badEnds = 0
        var hangulFragments = 0
        var punctuationOnly = 0
        func fits(_ original: Flow) -> Bool {
            breaks <= original.breaks && badStarts <= original.badStarts && badEnds <= original.badEnds &&
                hangulFragments <= original.hangulFragments && punctuationOnly <= original.punctuationOnly
        }
    }
    struct Measurement {
        var ink: [CGRect]
        var lines: Int
        var lineStarts: [Int]
        var flow: Flow
        var contentFits: Bool
        var box: CGRect? { ink.isEmpty ? nil : ink.reduce(CGRect.null) { $0.union($1) } }
    }
    struct Entry {
        var id: String
        var text: String
        var font: Double
        var sizes: [Double]
        var frame: CGRect
        var source: CGRect
        var background: [Double]
        var plate: CGRect?
        var original: Measurement?
        var enabled = true
        var balancedColumn = false
        var rotation: Double = 0
        var rightToLeft = false
        var alreadyRestored = false
        var otherSources: [CGRect] = []
        var otherText: [CGRect] = []
        var erasureComplete = false
        var residualLettering: Bool? = nil
        var hasSurfaceQuery = false
        var hasSourceImage = false
    }
    struct Candidate {
        var rect: CGRect
        var font: Double
        var frozenLines: [String]
    }
    struct Budget {
        var type = 8192
        var probePixels = 32768
        var surface = 1_048_576
    }
    struct Result {
        var candidate: Candidate
        var measurement: Measurement
        var releasedPlate: Bool
        var metadata: [String: String]
    }
    struct Hooks {
        var residualLettering: (() -> Bool)? = nil
        /// Canvas32x32 draw over this viewport rectangle, straight source RGBA.
        var read: (CGRect) -> [UInt8]?
        var measure: (Candidate) -> Measurement?
        /// Remaining allowance is debited by the actual queried mask/pool work.
        var surface: ((Measurement, inout Int) -> Bool)? = nil
    }
    static func shared(_ plate: CGRect, sources: [CGRect], text: [CGRect]) -> Bool {
        (sources.map { $0.insetBy(dx:-3,dy:-3) } + text).contains { other in
            min(plate.maxX,other.maxX) - max(plate.minX,other.minX) > 0.04 &&
                min(plate.maxY,other.maxY) - max(plate.minY,other.minY) > 0.04
        }
    }
    static func riskPoints(rgba: [UInt8],box: CGRect,source: CGRect,background: [Double]) -> [CGPoint] {
        guard rgba.count >= 4096,background.count == 3 else { return [] }
        let owned = source.insetBy(dx:-3,dy:-3)
        var points: [CGPoint] = []
        for y in 0..<32 { for x in 0..<32 {
            let px = box.minX + (Double(x)+0.5)/32*box.width,py = box.minY + (Double(y)+0.5)/32*box.height
            if px >= owned.minX && px <= owned.maxX && py >= owned.minY && py <= owned.maxY { continue }
            let p = (y*32+x)*4
            if rgba[p+3] >= 250 && max(abs(background[0]-Double(rgba[p])),abs(background[1]-Double(rgba[p+1])),abs(background[2]-Double(rgba[p+2]))) > 48 {
                points.append(CGPoint(x:px,y:py))
            }
        } }
        return points
    }
    static func risk(_ box: CGRect,points: [CGPoint]) -> Int {
        points.filter { $0.x >= box.minX-3 && $0.x <= box.maxX+3 && $0.y >= box.minY-3 && $0.y <= box.maxY+3 }.count
    }
    static func frozenLines(text: String,starts: [Int]) -> [String] {
        let value = text as NSString
        let boundaries = Array(Set([0]+starts)).sorted()
        guard boundaries.allSatisfy({ $0 >= 0 && $0 <= value.length }) else { return [] }
        return boundaries.enumerated().map { index,start in
            let end = index+1<boundaries.count ? boundaries[index+1] : value.length
            return value.substring(with:NSRange(location:start,length:end-start))
        }
    }
    static func run(_ e: Entry,budget: inout Budget,hooks: Hooks) -> Result? {
        guard e.enabled,!e.balancedColumn,e.rotation == 0,!e.rightToLeft,!e.text.contains("\r"),!e.text.contains("\n"),!e.alreadyRestored,
              !e.sizes.isEmpty,e.text.utf16.count*e.sizes.count <= budget.type else { return nil }
        budget.type -= e.text.utf16.count*e.sizes.count
        guard let original = e.original,let box = original.box else { return nil }
        let residual: Bool
        if e.erasureComplete,e.residualLettering == nil { residual = hooks.residualLettering?() ?? false }
        else { residual = e.residualLettering ?? false }
        guard let plate = e.plate else { return nil }
        let shared = shared(plate,sources:e.otherSources,text:e.otherText)
        var points: [CGPoint] = []
        if e.hasSourceImage,budget.probePixels >= 1024 {
            budget.probePixels -= 1024
            guard let rgba = hooks.read(box),rgba.count >= 4096 else { return nil }
            points = riskPoints(rgba:rgba,box:box,source:e.source,background:e.background)
        }
        let before = risk(box,points:points),area = Double(before)/1024*box.width*box.height
        guard area >= 80 || e.hasSurfaceQuery else { return nil }
        let lines = frozenLines(text:e.text,starts:original.lineStarts)
        guard !lines.isEmpty else { return nil }
        for size in e.sizes {
            let candidate = Candidate(rect:box,font:size,frozenLines:lines)
            guard let measured = hooks.measure(candidate),measured.contentFits,let next = measured.box,
                  measured.flow.fits(original.flow),measured.lines == original.lines,
                  next.minX >= box.minX-0.04,next.minY >= box.minY-0.04,next.maxX <= box.maxX+0.04,next.maxY <= box.maxY+0.04 else { continue }
            var restored = false
            if !shared,e.erasureComplete,!residual,e.hasSurfaceQuery,let surface = hooks.surface,budget.surface > 0 {
                let allowance = min(budget.surface,65536)
                var remaining = allowance
                restored = surface(measured,&remaining)
                budget.surface -= allowance-remaining
            }
            let after = risk(next,points:points)
            guard restored || area >= 80 && Double(after) <= Double(before)*0.65 else { continue }
            func js(_ value:Double) -> String {value.rounded() == value ? String(Int(value)) : String(value)}
            var metadata = ["artworkFit":restored ? "restored-surface":"smaller-caption","artworkOriginalFont":js(e.font),
                "artworkFinalFont":js(size),"artworkSourceErasure":restored ? "restored":"covered",
                "artworkRiskBefore":String(before),"artworkRiskAfter":String(after),"sourcePanelFinalFont":js(size)]
            if let data = try? JSONSerialization.data(withJSONObject:[box.minX,box.minY,box.width,box.height]),let text = String(data:data,encoding:.utf8) {metadata["artworkOriginalInk"] = text}
            if restored {metadata["sourcePanelTextFit"] = "inside";metadata["sourceBackgroundColor"] = "inpainted";metadata["sourceAppliedBackgroundRGB"] = ""}
            return .init(candidate:candidate,measurement:measured,releasedPlate:restored,metadata:metadata)
        }
        return nil
    }
}
