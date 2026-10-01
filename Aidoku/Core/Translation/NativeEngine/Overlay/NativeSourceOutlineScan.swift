import CoreGraphics
import Foundation

/// The frozen final source-outline pass's admission order, crop and pixel
/// budgets. Callers provide current painted state rather than inferred styles.
enum NativeSourceOutlineScan {
    struct Record {
        let id: String
        let sourceBounds: [Double]
        let sourceFrame: CGRect
        let sourceFontSize: Double?
        let sourceVertical: Bool
        let sourceColorEligible: Bool
        let visible: Bool
        let backgroundKind: String
        let appliedForeground: [Double]?
        let appliedStrokeWidth: Double
        let opaquePlate: [Double]?
        let sample: [String: Any]
        var reserveObservedDarkInk = false
        var partialMainbodyProof: String? = nil
    }
    struct Analysis {
        let ring: NativeSourceOutlineEvidence.Ring?
        let ringData: [String: Any]?
        let enclosed: [String: Any]?
        let rejection: String?
        let missingColumnRing: Bool
        let restored: Bool
        let slanted: Bool
    }
    typealias Reader = (_ sourcePixelRect: CGRect, _ width: Int, _ height: Int) -> [UInt8]?

    static func scan(records: [Record], imageSize: CGSize, displayFrame: CGRect?, reader: Reader) -> [String: Analysis] {
        guard imageSize.width > 0, imageSize.height > 0,
              [imageSize.width, imageSize.height].allSatisfy(\.isFinite) else { return [:] }
        func restored(_ e: Record) -> Bool { ["inpainted", "slanted-glyph-restored"].contains(e.backgroundKind) }
        func sampledStroke(_ e: Record) -> Bool {
            rgb(e.sample["stroke"]) != nil && confidence(e.sample, "stroke") >= 0.55
        }
        func rank(_ e: Record) -> Int {
            if e.reserveObservedDarkInk || !restored(e) { return 0 }
            return e.backgroundKind == "slanted-glyph-restored" && !sampledStroke(e) ? 2 : 1
        }
        let ordered = records.enumerated().sorted { a, b in rank(a.element) == rank(b.element) ? a.offset < b.offset : rank(a.element) < rank(b.element) }.map(\.element)
        var result: [String: Analysis] = [:], pixels = 393_216
        for e in ordered {
            let isRestored = restored(e), slanted = e.backgroundKind == "slanted-glyph-restored"
            guard e.visible, e.sourceColorEligible,
                  isRestored || ["readability-panel", "rotated-panel"].contains(e.backgroundKind) else { continue }
            let sampled = sampledStroke(e), fg = rgb(e.sample["foreground"])
            let fallback = slanted && fg != nil && e.appliedForeground != nil && gap(fg!, e.appliedForeground!) > 24
            let unresolvedColumnRing = e.sourceVertical && !sampled &&
                (fg != nil && confidence(e.sample, "foreground") >= 0.55 || e.partialMainbodyProof == "outlined-source-position")
            let missing = isRestored && unresolvedColumnRing
            let skip = isRestored && !missing && (e.appliedStrokeWidth > 0 || !sampled && !fallback)
            if skip && !e.reserveObservedDarkInk { continue }
            if !isRestored && rgb(e.opaquePlate) == nil { continue }
            let b = e.sourceBounds, frame = displayFrame ?? e.sourceFrame
            guard b.count == 4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0,
                  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), frame.width > 0 else { continue }
            let glyphCSS = e.sourceFontSize.flatMap { $0 > 0 ? $0 : nil } ?? min(b[2] * Double(frame.width), b[3] * Double(frame.height)) * 0.7
            if !glyphCSS.isFinite || glyphCSS <= 0 { continue }
            let iw = Double(imageSize.width), ih = Double(imageSize.height), glyphPixels = glyphCSS * iw / Double(frame.width)
            let pad = max(4, glyphPixels * 0.35)
            let x0 = max(0, floor(b[0] * iw - pad)), y0 = max(0, floor(b[1] * ih - pad))
            let x1 = min(iw, ceil((b[0] + b[2]) * iw + pad)), y1 = min(ih, ceil((b[1] + b[3]) * ih + pad))
            let sw = x1 - x0, sh = y1 - y0, scale = min(1, sqrt(40_000 / max(1, sw * sh)))
            let w = max(1, Int(floor(sw * scale))), h = max(1, Int(floor(sh * scale)))
            if w < 8 || h < 8 { continue }
            if w * h > pixels {
                result[e.id] = Analysis(ring: nil, ringData: nil, enclosed: nil, rejection: "budget", missingColumnRing: missing, restored: isRestored, slanted: slanted)
                continue
            }
            pixels -= w * h
            if skip { continue }
            guard let rgba = reader(CGRect(x: x0, y: y0, width: sw, height: sh), w, h), rgba.count == w * h * 4 else { continue }
            let box = [Int(floor((b[0] * iw - x0) * scale)), Int(floor((b[1] * ih - y0) * scale)),
                       Int(ceil(((b[0] + b[2]) * iw - x0) * scale)), Int(ceil(((b[1] + b[3]) * ih - y0) * scale))]
            var enclosed: [String: Any]?
            // A readability plate may be released later after ownership proof.
            // Retain the same closed-interior observation now, using this already
            // admitted source crop. Final style admission still requires the
            // card to be inpainted; observing a pair does not release a plate.
            if unresolvedColumnRing {
                let lettering = e.sample["lettering"] as? [String: Any], sourceInk = e.sample["sourceInk"] as? [String: Any]
                let candidate = rgb(e.sample["stroke"]) ?? rgb(lettering?["color"]) ?? fg
                if let candidate {
                    let corroborated = rgb(sourceInk?["stroke"]).map { gap($0, candidate) <= 32 } == true &&
                        rgb(sourceInk?["foreground"]).map { $0.min()! >= 225 } == true
                    if candidate.max()! - candidate.min()! >= 40 || corroborated {
                        enclosed = NativeSourceOutlineEvidence.enclosedCaptionOutline(rgba: rgba, width: w, height: h,
                            box: box.map(Double.init), glyph: glyphPixels * scale, ink: candidate, allowNeutral: corroborated)
                    }
                }
            }
            let candidates = [e.sample["foreground"], e.sample["displayForeground"],
                (e.sample["displayEvidence"] as? [String: Any])?["color"],
                (e.sample["lettering"] as? [String: Any])?["color"], e.sample["stroke"], e.sample["background"],
                e.sample["captionBackground"], (e.sample["surface"] as? [String: Any])?["color"]].map(rgb)
            let evidence = NativeSourceOutlineEvidence.ringPair(rgba: rgba, width: w, height: h,
                box: box, glyph: glyphPixels * scale, candidates: candidates)
            // Observe closed dark interiors before late plate release selects
            // the final fill. The final style pass requires both the retained
            // source-position proof and actually applied dark ink.
            if enclosed == nil, e.partialMainbodyProof == "outlined-source-position", fg == nil,
               confidence(e.sample, "background") >= 0.8,
               let background = rgb(e.sample["captionBackground"]) ?? rgb(e.sample["background"]), validDark(background),
               let ring = evidence.ring, ring.kind == "paper", ring.core.min()! >= 225,
               ring.outline.max()! <= 32, ring.surface?.flat == true, ring.surface!.rgb.max()! <= 32 {
                enclosed = NativeSourceOutlineEvidence.enclosedDarkCaptionOutline(rgba: rgba, width: w, height: h,
                    box: box.map(Double.init), glyph: glyphPixels * scale, background: background)
            }
            result[e.id] = Analysis(ring: evidence.ring, ringData: evidence.ring?.dictionary,
                enclosed: enclosed, rejection: evidence.rejection, missingColumnRing: missing, restored: isRestored, slanted: slanted)
        }
        return result
    }
    private static func rgb(_ value: Any?) -> [Double]? {
        guard let value = value as? [Double], value.count == 3, value.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) else { return nil }; return value
    }
    private static func validDark(_ color: [Double]) -> Bool { color.count == 3 && color.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 32 } }
    private static func confidence(_ sample: [String: Any], _ key: String) -> Double { (sample["confidence"] as? [String: Any])?[key] as? Double ?? 0 }
    private static func gap(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
}
