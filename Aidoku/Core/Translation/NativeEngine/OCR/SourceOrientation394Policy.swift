import Foundation
import CoreGraphics
import CoreFoundation

// Isolated DEFAULT-OFF proposal. No GT, identity gates, frame reads or native calls.
// Inputs must be tied to ONE actual retained root and its unchanged applied graph.
enum SourceOrientation394Policy {
    struct Features: Codable {
        let areaRatio: Double
        let widthRatio: Double
        let centerCorrection: Double
        let normalPadding: Double
        let fitImprovement: Double
        let normalBodyCellSupportLoss: Int
        let normalRLECellSupportLoss: Int
    }
    struct NativeCandidate {
        let rawOffer: [String: Any]
        let nativeAdmissionPassed: Bool // aggregate ACTUAL native outcome, never raw admissionGranted
        let sourceHardRejections: [String]
        let originalRecord: [String: Any] // retain all soft obligations, losses and member outcomes
    }
    struct Choice {
        let nativeIndex: Int
        let features: Features
        let candidate: NativeCandidate
        let finalAdmissionGranted = false // selection is NOT final semantic admission
    }

    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let d = number(value), d >= 0, d < Double(Int.max), d.rounded(.towardZero) == d else { return nil }
        return Int(d)
    }
    static func points(_ value: Any?) -> [CGPoint]? {
        guard let values = value as? [Any], values.count == 4 else { return nil }
        var p: [CGPoint] = []
        for v in values {
            if let a = v as? [Any], a.count == 2,
               let x = number(a[0]), let y = number(a[1]) {
                p.append(CGPoint(x: x, y: y))
            } else if let d = v as? [String: Any],
                      let x = number(d["x"]), let y = number(d["y"]) {
                p.append(CGPoint(x: x, y: y))
            } else { return nil }
        }
        return p
    }
    // Original vertices, shifted shoelace; no snapping, hull, rectangle approximation,
    // GEOS or Float32. Double area can differ in last bits from C++ long-double area.
    // Parent must compare Boolean eligibility exactly before use.
    static func convexArea(_ p: [CGPoint]) -> Double? {
        guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let ox = Double(p[0].x), oy = Double(p[0].y)
        let x = p.map { Double($0.x) - ox }, y = p.map { Double($0.y) - oy }
        var twice = 0.0, sign = 0
        for i in 0..<4 {
            let j = (i + 1) % 4, k = (i + 2) % 4
            twice += x[i] * y[j] - x[j] * y[i]
            let cross = (x[j] - x[i]) * (y[k] - y[j]) - (y[j] - y[i]) * (x[k] - x[j])
            guard cross.isFinite, cross != 0 else { return nil }
            let s = cross > 0 ? 1 : -1
            if sign != 0 && sign != s { return nil }
            sign = s
        }
        let area = abs(twice) / 2
        return area.isFinite && area > 0 ? area : nil
    }
    static func projectionSpan(_ p: [CGPoint], nx: Double, ny: Double) -> Double? {
        // Deliberately keep original absolute-coordinate projection and two-term
        // multiply/add order from frozen numpy `quad @ normal`; no re-centering.
        let v = p.map { Double($0.x) * nx + Double($0.y) * ny }
        guard let lo = v.min(), let hi = v.max(), lo.isFinite, hi.isFinite, hi > lo else { return nil }
        return hi - lo
    }
    static func describe(rawOffer: [String: Any], actualPrior: [CGPoint],
                         factoryReceipt: [String: Any]) -> Features? {
        guard let r = rawOffer["sourceReceipt"] as? [String: Any],
              let q = points(rawOffer["polygon"]),
              let recordedPrior = points(r["actualCurrentPrior"]),
              recordedPrior == actualPrior,
              let pa = convexArea(actualPrior), let qa = convexArea(q),
              let normal = r["normal"] as? [Any], normal.count == 2,
              let nx = number(normal[0]), let ny = number(normal[1]), nx * nx + ny * ny > 0,
              let pw = projectionSpan(actualPrior, nx: nx, ny: ny),
              let qw = projectionSpan(q, nx: nx, ny: ny),
              let w = number(r["nativeW"]), w > 0,
              let correction = number(r["normalCenterCorrectionFromPrior"]),
              let padding = number(r["normalPaddingNativeW"]), padding >= 0,
              let objective = number(r["angleSearchObjective"]),
              let family = r["supportFamily"] as? String,
              let searches = factoryReceipt["searches"] as? [[String: Any]],
              let bodyLoss = nonnegativeInt(r["normalBodyCellSupportLoss"]),
              let rleLoss = nonnegativeInt(r["normalRLECellSupportLoss"]) else { return nil }
        let matching = searches.filter { ($0["supportFamily"] as? String) == family }
        guard matching.count == 1,
              let search = matching[0]["search"] as? [String: Any],
              let priorFit = number(search["sourceAngleScore"]) else { return nil }
        let f = Features(areaRatio: qa / pa, widthRatio: qw / pw,
                         centerCorrection: abs(correction) / w, normalPadding: padding,
                         fitImprovement: (priorFit - objective) / max(abs(priorFit), 1e-12),
                         normalBodyCellSupportLoss: bodyLoss, normalRLECellSupportLoss: rleLoss)
        guard [f.areaRatio, f.widthRatio, f.centerCorrection, f.normalPadding,
               f.fitImprovement].allSatisfy({ $0.isFinite }) else { return nil }
        return f
    }
    static func passes(_ f: Features) -> Bool {
        f.normalBodyCellSupportLoss == 0 && f.normalRLECellSupportLoss == 0 &&
        f.areaRatio <= 1.3 && f.widthRatio >= 1.0 &&
        f.centerCorrection <= 0.05 && f.normalPadding >= 0.05
    }
    static func mayNominate(raw: [String: Any], actualPrior: [CGPoint],
                            factoryReceipt: [String: Any]) -> Bool {
        // Generator raw hardRejections == wrapper sourceHardRejections in actual392.
        // If caller lifts wrapper sourceHardRejections, enforce BOTH lists.
        guard let hard = raw["hardRejections"] as? [String], hard.isEmpty else { return false }
        if let lifted = raw["sourceHardRejections"] {
            guard let hard = lifted as? [String], hard.isEmpty else { return false }
        }
        guard let f = describe(rawOffer: raw, actualPrior: actualPrior,
                               factoryReceipt: factoryReceipt) else { return false }
        return passes(f) // deliberately NO native pass requirement: generation preflight
    }
    static func choose(nativeOrdered: [NativeCandidate], actualPrior: [CGPoint],
                       factoryReceipt: [String: Any]) -> Choice? {
        var best: Choice? = nil
        var bestImprovement = -Double.infinity
        for (index, c) in nativeOrdered.enumerated() {
            guard c.nativeAdmissionPassed, c.sourceHardRejections.isEmpty,
                  mayNominate(raw: c.rawOffer, actualPrior: actualPrior, factoryReceipt: factoryReceipt),
                  let f = describe(rawOffer: c.rawOffer, actualPrior: actualPrior,
                                   factoryReceipt: factoryReceipt) else { continue }
            if f.fitImprovement > bestImprovement {
                best = Choice(nativeIndex: index, features: f, candidate: c)
                bestImprovement = f.fitImprovement
            }
        }
        return best // exact-score ties keep first ORIGINAL native order; nil means prior
    }
}
