import Foundation

/// Observation-only ports of directional/reference/soft/ordered_ink_rules and
/// font_context_soft.regular_glyph_agreement. Caller owns measurements, complete
/// same-page peer batches, frozen policies and their version/hash binding.
/// No extraction, fonts, segmentation/RF/model calls, IDs or metadata loading.
enum NativeSourceWeightImagePolicy {
    typealias Row = [String: Any]

    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case let .invalid(message): return message } }
    }

    private static func fail(_ message: String) -> Failure { .invalid(message) }
    private static func object(_ value: Any?, _ name: String, missing: Bool = false) throws -> Row {
        if value == nil && missing { return [:] }
        guard let row = value as? Row else { throw fail("Expected dictionary: \(name)") }
        return row
    }
    private static func array(_ value: Any?, _ name: String, missing: Bool = false) throws -> [Any] {
        if value == nil && missing { return [] }
        guard let values = value as? [Any] else { throw fail("Expected array: \(name)") }
        return values
    }
    private static func text(_ row: Row, _ key: String) throws -> String {
        guard let value = row[key] as? String else { throw fail("Missing string: \(key)") }
        return value
    }
    private static func number(_ value: Any?, _ name: String, default fallback: Double? = nil,
                               convertString: Bool = false) throws -> Double {
        guard let value else {
            if let fallback { return fallback }
            throw fail("Missing number: \(name)")
        }
        if let n = value as? NSNumber { return n.doubleValue }
        if convertString, let s = value as? String,
           let n = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return n }
        throw fail("Invalid number: \(name)")
    }
    private static func n(_ row: Row, _ key: String, default fallback: Double? = nil) throws -> Double {
        try number(row[key], key, default: fallback)
    }
    // Python truthiness: notably NaN is true, null/empty collections are false.
    private static func truth(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let n = value as? NSNumber { return n.doubleValue != 0 }
        if let s = value as? String { return !s.isEmpty }
        if let a = value as? [Any] { return !a.isEmpty }
        if let d = value as? Row { return !d.isEmpty }
        return true
    }
    private static func words(_ observation: Row) throws -> [Row] {
        try array(observation["words"], "words", missing: true).map { try object($0, "word") }
    }
    private static func glyphs(_ word: Row) throws -> [Any] {
        let ordered = try object(word["orderedGlyphs"], "orderedGlyphs", missing: true)
        return try array(ordered["glyphs"], "glyphs", missing: true)
    }
    private static func sourceLabel(_ row: Row) throws -> String? {
        guard let value = row["sourceWeight"] else { throw fail("Missing sourceWeight") }
        return value as? String
    }
    private static func quantileValue(_ group: Row, _ q: Int) throws -> Double {
        let values = try array(group["quantiles"], "quantiles")
        let index = q < 0 ? values.count + q : q
        guard values.indices.contains(index) else { throw fail("Directional quantile index out of range") }
        return try number(values[index], "quantile")
    }
    private static func quantile(_ values: [Double], _ q: Double) -> Double {
        if values.contains(where: { $0.isNaN }) { return .nan }
        let sorted = values.sorted(), position = Double(values.count - 1) * q
        let i = Int(position), j = min(i + 1, sorted.count - 1), t = position - Double(i)
        let difference = sorted[j] - sorted[i]
        return t < 0.5 ? sorted[i] + difference * t : sorted[j] - difference * (1 - t)
    }
    private static func renderPolicy(_ label: String) -> Row {
        ["sourceWeight": label, "renderBold": label == "bold", "renderWeight": label == "bold" ? "bold" : "regular",
         "requiresTranslationSpanAlignment": label == "mixed", "translatedStyleRuns": [Row]()]
    }
    private static func updated(_ prior: Row, flag: String, promote: Bool) -> Row {
        var result = prior
        result[flag] = promote
        if promote { result.merge(renderPolicy("bold")) { _, value in value } }
        return result
    }

    /// EXACTLY one complete page, not one call per row. Mixed rows are eligible
    /// controls (only baseline bold is excluded), but can never themselves promote.
    static func classifyDirectionalPage(observations: [Row], predictions: [Row], policy: Row) throws -> [Bool] {
        guard observations.count == predictions.count else { throw fail("Directional page peer count differs") }
        let field = try text(policy, "direction"), mode = try text(policy, "mode")
        let rawQ = try n(policy, "quantile")
        guard rawQ.isFinite, rawQ.rounded(.towardZero) == rawQ, abs(rawQ) < Double(Int.max) else {
            throw fail("Invalid directional quantile index")
        }
        let q = Int(rawQ)
        // Empty Python batches fail at ~np.array([]), whose dtype is float.
        guard !observations.isEmpty else { throw fail("Invalid empty directional page") }
        let labels = try predictions.map { try sourceLabel($0) }
        var values = [Double](), counts = [Double](), usable = [Bool](), other = [Double](), controls = [Double]()
        for (i, observation) in observations.enumerated() {
            let measured = try object(observation[mode], mode), groups = try object(measured["groups"], "groups")
            let group = try object(groups[field], field)
            let value = try quantileValue(group, q), count = try n(group, "count")
            let ok = try n(measured, "components") >= 2 && count >= 16
            values.append(value); counts.append(count); usable.append(ok)
            if ok && labels[i] != "bold" { controls.append(value) }
            // Actual directional_ink producer's stable insertion order. Preserve
            // Python min's first-NaN behaviour on the three canonical groups.
            let canonical = ["verticalStems", "horizontalStems", "diagonalStems"]
            let keys = canonical.filter { groups[$0] != nil } + groups.keys.filter { !canonical.contains($0) }.sorted()
            var minimum: Double?
            for name in keys where name != field {
                let g = try object(groups[name], name)
                if try n(g, "count") >= 16 {
                    let v = try quantileValue(g, q)
                    if minimum == nil || v < minimum! { minimum = v }
                }
            }
            other.append(minimum ?? 0)
        }
        // Python max(1e-6, NaN) returns its first argument, unlike a blanket
        // nonfinite rejection. Do not prefilter controls or page context.
        let quartile = controls.count >= 2 ? quantile(controls, 0.25) : 0
        let denominator = quartile > 1e-6 ? quartile : 1e-6
        let width = try n(policy, "minimumWidthEm"), direction = try n(policy, "minimumDirectionContrast")
        let relative = try n(policy, "minimumPageRelative"), rays = try n(policy, "minimumDirectionalRays")
        let score = try text(policy, "existingScoreField")
        // NumPy's &= constructs score values for every row, even those that fail.
        let scorePass = try predictions.map { row in
            score == "none" ? true : try n(row, score, default: 0) >= n(policy, "minimumExistingScore")
        }
        return predictions.indices.map { i in
            let contrast = other[i] > 0 ? values[i] / other[i] : 0
            let pageRelative = controls.count >= 2 ? values[i] / denominator : 0
            return usable[i] && values[i] >= width && contrast >= direction && pageRelative >= relative
                && counts[i] >= rays && scorePass[i] && labels[i] == "regular"
        }
    }
    static func applyDirectionalPage(observations: [Row], predictions: [Row], policy: Row) throws -> [Row] {
        let added = try classifyDirectionalPage(observations: observations, predictions: predictions, policy: policy)
        return zip(predictions, added).map { updated($0, flag: "directionalInkRescueApplied", promote: $1) }
    }

    static func referenceWordPasses(_ word: Row, policy: Row) throws -> Bool {
        // Python constructs all thresholds before examining the first measurement.
        let checks: [(String, Double?, Double?)] = try [
            ("matchedReferenceWeight", 700, nil), ("templateFit", n(policy, "minimumFit"), nil),
            ("normalTemplateMargin", n(policy, "minimumNormalMargin"), nil),
            ("weightFraction", n(policy, "minimumStrokeFraction"), nil),
            ("fractionSpread", nil, n(policy, "maximumFractionSpread"))]
        for (key, lower, upper) in checks {
            let value = try number(word[key], key, default: .nan, convertString: true)
            if !value.isFinite || (lower != nil && value < lower!) || (upper != nil && value > upper!) { return false }
        }
        if let minimum = policy["minimumRegisteredFraction"], !(minimum is NSNull) {
            let evidence = try object(word["registeredStrokeProfile"], "registeredStrokeProfile", missing: true)
            if !truth(evidence["usable"]) { return false }
            let fraction = try number(evidence["medianWeightFraction"], "medianWeightFraction", default: .nan, convertString: true)
            let support = try number(evidence["correspondingSourceSupport"], "correspondingSourceSupport", default: .nan, convertString: true)
            if try !fraction.isFinite || !support.isFinite || fraction < number(minimum, "minimumRegisteredFraction")
                || support < n(policy, "minimumRegisteredSupport") { return false }
        }
        return true
    }
    static func applyReference(observation: Row, prediction: Row, policy: Row) throws -> Row {
        let measured = try words(observation)
        var agrees = 0
        for word in measured where try referenceWordPasses(word, policy: policy) { agrees += 1 }
        var promote = try sourceLabel(prediction) == "regular" && !measured.isEmpty
            && Double(agrees) / Double(measured.count) >= n(policy, "minimumWordAgreement")
        let field = try policy["existingScoreField"].map { value -> String in
            guard let s = value as? String else { throw fail("Invalid score field") }; return s
        } ?? "none"
        if field != "none" {
            let scorePass = try n(prediction, field, default: 0) >= n(policy, "minimumExistingScore")
            promote = promote && scorePass
        }
        return updated(prediction, flag: "registeredInkRescueApplied", promote: promote)
    }

    static func softWordPasses(_ word: Row, policy: Row) throws -> Bool {
        if !truth(word["usable"]) { return false }
        let checks: [(String, Double)] = try [
            ("matchedWeight", 700), ("templateFit", n(policy, "minimumFit")),
            ("normalTemplateMargin", n(policy, "minimumNormalMargin")),
            ("medianWeightFraction", n(policy, "minimumSoftFraction")),
            ("correspondingSourceSupport", n(policy, "minimumSourceSupport"))]
        for (key, minimum) in checks {
            let value = try number(word[key], key, default: .nan, convertString: true)
            if !value.isFinite || value < minimum { return false }
        }
        return true
    }
    static func softProposes(observation: Row, confidence: Double, policy: Row) throws -> Bool {
        if !truth(observation["words"]) || !confidence.isFinite { return false }
        if try confidence < n(policy, "minimumExistingScore") { return false }
        let measured = try array(observation["words"], "words", missing: true)
        guard let expected = observation["expectedWordCount"] else { throw fail("Missing number: expectedWordCount") }
        // Python count != None/string is true (incomplete), not a numeric cast.
        guard let count = expected as? NSNumber, Double(measured.count) == count.doubleValue else { return false }
        for rawWord in measured {
            if try !softWordPasses(object(rawWord, "word"), policy: policy) { return false }
        }
        return true
    }
    static func applySoft(observation: Row, prior: Row, policy: Row) throws -> Row {
        let regular = try sourceLabel(prior) == "regular"
        let promote = try regular && softProposes(observation: observation,
            confidence: n(prior, "polarityRescueScore", default: 0), policy: policy)
        return updated(prior, flag: "softInkRescueApplied", promote: promote)
    }

    static func expectedGlyphCounts(members: [Row]) throws -> [Int] {
        try members.prefix(6).map { member in
            let normalized = try text(member, "text").precomposedStringWithCanonicalMapping
            return normalized.unicodeScalars.filter { scalar in
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber: return true
                default: return false
                }
            }.count
        }
    }
    static func outlineWitness(style: Row, policy: Row) throws -> Bool {
        let outline = try object(style["outline"], "outline", missing: true)
        if !truth(outline["present"]) { return false }
        let probability = try n(outline, "probability", default: 0)
        if !probability.isFinite { return false }
        if try probability < n(policy, "minimumOutlineProbability") { return false }
        let background = try object(style["background"], "background", missing: true)
        let fill = try object(style["fill"], "fill", missing: true)
        var colors = [[Double]]()
        for paint in [outline, background, fill] {
            guard let value = paint["rgb"], !(value is NSNull) else { return false }
            let color = try array(value, "rgb")
            if color.count != 3 { return false }
            let rgb = try color.map { try number($0, "rgb") }
            if !rgb.allSatisfy(\.isFinite) { return false }
            colors.append(rgb)
        }
        let separation = try n(policy, "minimumPaintSeparation")
        return colors.dropFirst().allSatisfy { color in
            let sum = zip(colors[0], color).reduce(0.0) { total, pair in
                let delta = pair.0 - pair.1; return total + delta * delta
            }
            return sqrt(sum) >= separation
        }
    }
    static func orderedProposes(observation: Row, confidence: Double, policy: Row) throws -> Bool {
        if !truth(observation["words"]) { return false }
        let measured = try array(observation["words"], "words", missing: true)
        let expected = try array(observation["expectedGlyphCounts"], "expectedGlyphCounts", missing: true)
        if measured.count != expected.count || !confidence.isFinite { return false }
        if try confidence < n(policy, "minimumExistingScore") { return false }
        if truth(policy["requireWitnessedOutline"]) && !truth(observation["outlineWitnessed"]) { return false }
        for (rawWord, rawCount) in zip(measured, expected) {
            let word = try object(rawWord, "word")
            let checks = try [("templateFit", n(policy, "minimumWordFit")),
                              ("normalTemplateMargin", n(policy, "minimumWordMargin")), ("matchedWeight", 700.0)]
            for (key, threshold) in checks {
                let value = try n(word, key, default: .nan)
                if !value.isFinite || value < threshold { return false }
            }
            let gs = try glyphs(word)
            guard let expectedCount = rawCount as? NSNumber else { return false }
            let count = expectedCount.doubleValue
            if try Double(gs.count) != count || count < n(policy, "minimumIndependentGlyphs") { return false }
            var margins = [Double]()
            for rawGlyph in gs {
                let glyph = try object(rawGlyph, "glyph")
                let floors = try [("templateFit", n(policy, "minimumGlyphFit")), ("referenceKnownSupport", n(policy, "minimumKnownSupport"))]
                for (key, floor) in floors {
                    let value = try n(glyph, key, default: .nan)
                    if !value.isFinite || value < floor { return false }
                }
                let margin = try n(glyph, "heavyMargin", default: .nan)
                if !margin.isFinite || margin <= 0 { return false }
                margins.append(margin)
            }
            // Valid frozen policies require >=1 independent glyph. Preserve an
            // invalid zero-glyph configuration's Python division error as a throw.
            guard !margins.isEmpty else { throw fail("division by zero") }
            if try margins.reduce(0, +) / Double(margins.count) < n(policy, "minimumMeanGlyphMargin") { return false }
        }
        return true
    }
    static func applyOrdered(observation: Row, prior: Row, policy: Row) throws -> Row {
        let regular = try sourceLabel(prior) == "regular"
        let promote = try regular && orderedProposes(observation: observation,
            confidence: n(prior, "polarityRescueScore", default: 0), policy: policy)
        return updated(prior, flag: "orderedInkRescueApplied", promote: promote)
    }
    /// Independent REGULAR glyph agreement only; incomplete/unreliable/missing
    /// glyphs are not veto evidence. Parent owns remeasurement and veto flags.
    static func regularGlyphAgreement(observation: Row, counts: [Int], policy: Row) throws -> Bool {
        if !truth(observation["words"]) { return false }
        let measured = try array(observation["words"], "words", missing: true)
        if measured.count != counts.count { return false }
        for (rawWord, count) in zip(measured, counts) {
            let word = try object(rawWord, "word")
            let gs = try glyphs(word)
            if try Double(count) < n(policy, "minimumIndependentGlyphs") || gs.count != count { return false }
            for rawGlyph in gs {
                let glyph = try object(rawGlyph, "glyph")
                let floors = try [("templateFit", n(policy, "minimumGlyphFit")), ("referenceKnownSupport", n(policy, "minimumKnownSupport"))]
                for (key, floor) in floors {
                    let value = try n(glyph, key, default: .nan)
                    if !value.isFinite || value < floor { return false }
                }
                let margin = try n(glyph, "heavyMargin", default: .nan)
                if !margin.isFinite || margin >= 0 { return false }
            }
        }
        return true
    }
}
