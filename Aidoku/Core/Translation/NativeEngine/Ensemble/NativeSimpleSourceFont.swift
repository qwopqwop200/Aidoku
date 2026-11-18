import CoreGraphics
import Foundation

/// Source-only zero-font-head EM candidate. No font family, target text,
/// learned prior, glyph-template/PCA extraction, or typography/layout decisions.
/// Caller supplies ORIGINAL OCR Unicode-scalar count, never translated text.
enum NativeSimpleSourceFont {
    static let identity = "simple-source-font-geometry-unicode-scalars-v1"
    static let clusterMaximumRatio = 1.05
    enum Failure: Error { case invalidGeometry, invalidOriginalCount, invalidCalibration, invalidConsistencyRule }

    struct ConsistencyRule: Sendable, Equatable {
        static let identity = "font-member-logratio-canonical-complete-link-v1"
        let bodyRatioWeight: Double
        let maximumLogDistance: Double
        init(bodyRatioWeight: Double, maximumLogDistance: Double) {
            self.bodyRatioWeight = bodyRatioWeight; self.maximumLogDistance = maximumLogDistance
        }
    }

    struct Input: Sendable {
        let bounds: CGRect
        let originalCharacterCount: Int
        let memberPolygons: [[CGPoint]]
        init(bounds: CGRect, originalCharacterCount: Int, memberPolygons: [[CGPoint]] = []) {
            self.bounds = bounds; self.originalCharacterCount = originalCharacterCount; self.memberPolygons = memberPolygons
        }
    }

    struct Calibration: Sendable, Equatable {
        let scale: Double
        let bias: Double
        let bboxShortScale: Double
        let memberShortScale: Double
        static let identity = Calibration()
        init(scale: Double = 1, bias: Double = 0, bboxShortScale: Double = 0, memberShortScale: Double = 0) {
            self.scale = scale; self.bias = bias; self.bboxShortScale = bboxShortScale; self.memberShortScale = memberShortScale
        }
    }

    /// The generic geometry fallback, recomputed rather than inheriting an
    /// item's sourceFontSize (which can itself be a learned accepted estimate).
    /// Count ABI is sourceText.unicodeScalars.count, including whitespace. An
    /// observed zero count uses one only in the area/count denominator.
    static func prior(bounds: CGRect, originalCharacterCount: Int) throws -> Double {
        guard originalCharacterCount >= 0 else { throw Failure.invalidOriginalCount }
        let width = Double(bounds.size.width), height = Double(bounds.size.height)
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              width.isFinite, height.isFinite, width > 0, height > 0,
              (width * height).isFinite else { throw Failure.invalidGeometry }
        return max(8, min(min(width, height), sqrt(width * height / Double(max(1, originalCharacterCount)))))
    }

    /// One call is one source page. Complete-link bands use source-predicted EM
    /// alone. Returning the median in original input order also permits the
    /// existing exact-EM fallback fit closure without new renderer group IDs.
    static func estimate(_ inputs: [Input], calibration: Calibration = .identity,
                         cluster: Bool = true, relativeGap: Double = 0.05,
                         pageMedian: Bool = false, consistencyRule: ConsistencyRule? = nil) throws -> [Double] {
        guard calibration.scale.isFinite, calibration.bias.isFinite, calibration.bboxShortScale.isFinite, calibration.memberShortScale.isFinite,
              relativeGap.isFinite, relativeGap >= 0 else { throw Failure.invalidCalibration }
        if let rule = consistencyRule {
            guard rule.bodyRatioWeight.isFinite, rule.bodyRatioWeight >= 0,
                  rule.maximumLogDistance.isFinite, rule.maximumLogDistance >= 0,
                  !pageMedian else { throw Failure.invalidConsistencyRule }
        }
        let needsMembers = cluster && consistencyRule != nil
        var memberScales: [Double] = []
        if needsMembers { memberScales.reserveCapacity(inputs.count) }
        var values = try inputs.map { input -> Double in
            let source = try prior(bounds: input.bounds, originalCharacterCount: input.originalCharacterCount)
            let observedMember = calibration.memberShortScale != 0 || needsMembers ?
                try NativeSourceFontGeometryFeatures.memberShortMedian(input.memberPolygons) : nil
            // A declared geometry-prior fallback is not an observed glyph/font
            // feature and is never packaged as a fabricated legacy context.
            if needsMembers { memberScales.append(observedMember ?? source) }
            var value = calibration.scale * source
            if calibration.bboxShortScale != 0 {
                value += calibration.bboxShortScale * (try NativeSourceFontGeometryFeatures.shortSide(bounds: input.bounds))
            }
            if calibration.memberShortScale != 0 {
                value += calibration.memberShortScale * (observedMember ?? source)
            }
            value += calibration.bias
            guard value.isFinite else { throw Failure.invalidCalibration }
            return max(1, value)
        }
        guard cluster, values.count > 1 else { return values }
        if let rule = consistencyRule {
            return consistentValues(fontPixels: values, memberScales: memberScales, rule: rule)
        }
        let order = values.indices.sorted { values[$0] < values[$1] }
        var start = 0
        while start < order.count {
            let minimum = values[order[start]]
            var end = start + 1
            while end < order.count, pageMedian || values[order[end]] / minimum <= 1 + relativeGap { end += 1 }
            let size = end - start, middle = start + size / 2
            let median: Double
            if size % 2 == 1 { median = values[order[middle]] }
            else {
                let lower = values[order[middle - 1]], upper = values[order[middle]]
                median = lower + (upper - lower) * 0.5
            }
            for index in start..<end { values[order[index]] = median }
            start = end
        }
        return values
    }

    /// Canonical complete-link cover: sort by(raw EM, member scale), then join
    /// the first compatible cluster. Input-order ties have identical2ratio
    /// observations and are interchangeable. Thus source-owner permutations
    /// cannot change assigned EMs; return order remains the caller's order.
    private static func consistentValues(fontPixels: [Double], memberScales: [Double], rule: ConsistencyRule) -> [Double] {
        let order = fontPixels.indices.sorted {
            if fontPixels[$0] != fontPixels[$1] { return fontPixels[$0] < fontPixels[$1] }
            if memberScales[$0] != memberScales[$1] { return memberScales[$0] < memberScales[$1] }
            return $0 < $1 // Fully identical observations; not a model feature.
        }
        var groups: [[Int]] = []
        for index in order {
            var selected: Int?
            for group in groups.indices {
                if groups[group].allSatisfy({ other in
                    abs(log(fontPixels[index] / fontPixels[other])) +
                        rule.bodyRatioWeight * abs(log(memberScales[index] / memberScales[other])) <= rule.maximumLogDistance
                }) { selected = group; break }
            }
            if let selected { groups[selected].append(index) }
            else { groups.append([index]) }
        }
        var result = fontPixels
        for group in groups {
            let numeric = group.map { fontPixels[$0] }.sorted(), middle = group.count / 2
            let median = group.count % 2 == 1 ? numeric[middle] :
                numeric[middle - 1] + (numeric[middle] - numeric[middle - 1]) * 0.5
            for index in group { result[index] = median }
        }
        return result
    }
}
