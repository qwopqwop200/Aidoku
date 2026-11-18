import Foundation

/// Numeric candidate graph from font_weight_estimation/runtime.py. One call is
/// exactly one page: context includes every row, including the row being scored.
/// The caller owns measurement/version binding and frozen registry access. This
/// layer has no image, font, training, annotation, or source-identity access.
/// Later image policies in source_runtime.py are deliberately outside this graph.
enum NativeSourceWeightGraph {
    typealias Matrix = [[Double]]
    typealias Row = [String: Any]
    typealias Probability = (String, Matrix) throws -> Matrix
    private typealias M = NativeSourceFontGraphMath

    private static func invalid(_ message: String) -> NativeSourceFontGraphError {
        .invalid(message)
    }
    private static func object(_ config: Row, _ key: String) throws -> Row {
        guard let value = config[key] as? Row else { throw invalid("Missing weight metadata: \(key)") }
        return value
    }
    private static func number(_ config: Row, _ key: String) throws -> Double {
        guard let value = config[key] as? NSNumber, value.doubleValue.isFinite else {
            throw invalid("Invalid weight metadata: \(key)")
        }
        return value.doubleValue
    }
    private static func width(_ config: Row, _ key: String) throws -> Int {
        let value = try number(config, key)
        guard value > 0, value <= 100_000, value.rounded(.towardZero) == value else {
            throw invalid("Invalid weight feature count: \(key)")
        }
        return Int(value)
    }

    /// NumPy median and linear quantiles; concatenate raw, clipped robust z, center.
    static func pageContext(_ rows: Matrix) throws -> Matrix {
        guard let first = rows.first, !first.isEmpty else { throw invalid("Invalid source features") }
        try M.validate(rows, width: first.count, count: rows.count, name: "page context")
        var center: [Double] = [], spread: [Double] = []
        center.reserveCapacity(first.count)
        spread.reserveCapacity(first.count)
        // Median and both quartiles use the same stable order. Keep their
        // individual arithmetic unchanged and reuse the column storage.
        var column = [Double](repeating: 0, count: rows.count)
        for j in first.indices {
            for i in rows.indices { column[i] = rows[i][j] }
            column.sort()
            center.append(M.median(sorted: column))
            spread.append(max(M.quantile(sorted: column, 0.75) - M.quantile(sorted: column, 0.25), 0.02))
        }
        return rows.map { row in
            row + row.indices.map { M.clip((row[$0] - center[$0]) / spread[$0], -8, 8) } + center
        }
    }

    static func whiteBodyBold(style: Row, paired: [Double], policy: Row) throws -> Bool {
        let fill = try M.vector(object(style, "fill"), "rgb")
        let background = try M.vector(object(style, "background"), "rgb")
        guard fill.count == 3, background.count == 3, (fill + background).allSatisfy(\.isFinite) else {
            throw invalid("Invalid source palette")
        }
        let outline = style["outline"] as? Row ?? [:]
        if try fill.min()! <= number(policy, "minimumWhiteFill")
            || background.max()! >= number(policy, "maximumBlackBackground") || M.flag(outline, "present") { return false }
        try M.validate([paired], width: 48, count: 1, name: "paired glyph evidence")
        // Flattened (3 families, 2 channels, 8 fields); validity selects channel 0.
        let sans = paired[21] > 0 ? 16 : 24, serif = paired[37] > 0 ? 32 : 40
        let serifBody = try paired[serif] >= number(policy, "serifFit")
            && paired[serif + 3] >= number(policy, "serifHeavyMargin")
            && paired[sans + 3] >= number(policy, "blackSansMinimumMargin")
        let sansBody = try paired[sans] >= number(policy, "blackSansFit")
            && paired[sans + 3] >= number(policy, "blackSansHeavyMargin")
        return serifBody || sansBody
    }

    /// First maximum fit wins ties (NumPy argmax), irrespective of band validity field 13.
    static func confirmation(_ bands: Matrix, policy: Row) throws -> [Bool] {
        guard let first = bands.first else { return [] }
        guard !first.isEmpty, first.count.isMultiple(of: 14) else { throw invalid("Invalid differential weight bands") }
        try M.validate(bands, width: first.count, count: bands.count, name: "differential weight bands")
        return try bands.map { row in
            var best = 0
            for offset in stride(from: 14, to: row.count, by: 14) where row[offset + 12] > row[best + 12] { best = offset }
            return try row[best] >= number(policy, "minimumAddedStem")
                && row[best + 5] >= number(policy, "minimumCommonBody")
                && row[best + 12] >= number(policy, "minimumGlyphFit")
                && row[best + 4] <= number(policy, "maximumReconstructionError")
        }
    }

    private static func renderPolicy(_ label: String) -> Row {
        ["sourceWeight": label, "renderBold": label == "bold", "renderWeight": label == "bold" ? "bold" : "regular",
         "requiresTranslationSpanAlignment": label == "mixed", "translatedStyleRuns": [Row]()]
    }
    private static func scores(_ head: Row, _ raw: Matrix, _ probability: Probability) throws -> [Double] {
        let features = try pageContext(raw)
        guard try features[0].count == width(head, "featureCount"), let identity = M.modelID(head["model"]), !identity.isEmpty else {
            throw invalid("Weight head feature contract differs")
        }
        let result = try probability(identity, features)
        guard result.count == raw.count, result.allSatisfy({
            $0.count == 2 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        }) else { throw invalid("Invalid weight head probabilities") }
        return result.map { $0[1] }
    }

    static func predictPage(bundle: Row, raw: Matrix, styles: [Row], paired: Matrix,
                            mixed: [Bool]? = nil, probability: Probability) throws -> [Row] {
        try M.validate(raw, width: width(bundle, "rawFeatureCount"), count: raw.count, name: "source features")
        try M.validate(paired, width: 48, count: raw.count, name: "source correction batch")
        guard styles.count == raw.count, mixed == nil || mixed?.count == raw.count else {
            throw invalid("Invalid source style/mixed batch")
        }
        if raw.isEmpty { return [] }
        let score = try scores(bundle, raw, probability), policy = try object(bundle, "physicalCorrection")
        let threshold = try number(bundle, "threshold")
        return try raw.indices.map { i in
            let correction = try whiteBodyBold(style: styles[i], paired: paired[i], policy: policy)
            let label = mixed?[i] == true ? "mixed" : (score[i] >= threshold || correction ? "bold" : "regular")
            var row = renderPolicy(label)
            row["boldScore"] = score[i]; row["physicalCorrection"] = correction; row["GTAtInference"] = false
            return row
        }
    }

    static func predictComplementaryPage(bundle: Row, raw: Matrix, fill71v1: Matrix, styles: [Row], paired: Matrix,
                                         mixed: [Bool]? = nil, probability: Probability) throws -> [Row] {
        try M.validate(raw, width: 866, count: raw.count, name: "complementary source")
        try M.validate(fill71v1, width: 71, count: raw.count, name: "fill-v1")
        var result = try predictPage(bundle: object(bundle, "primary"), raw: raw, styles: styles,
                                     paired: paired, mixed: mixed, probability: probability)
        if raw.isEmpty { return result }
        guard try number(bundle, "fillVersion") == 1 else { throw invalid("Polarity head feature version differs") }
        let polarity = try object(bundle, "polarity")
        let alternate = raw.indices.map { i in Array(raw[i][..<597]) + fill71v1[i] + Array(raw[i][604...]) }
        let score = try scores(polarity, alternate, probability), threshold = try number(polarity, "threshold")
        for i in result.indices {
            let rescue = result[i]["sourceWeight"] as? String == "regular" && score[i] >= threshold
            if rescue { result[i].merge(renderPolicy("bold")) { _, new in new } }
            result[i]["polarityRescueScore"] = score[i]; result[i]["polarityRescueApplied"] = rescue
        }
        return result
    }

    static func predictBandPage(bundle: Row, raw: Matrix, fill71v1: Matrix, styles: [Row], paired: Matrix,
                                bands: Matrix, mixed: [Bool]? = nil, probability: Probability) throws -> [Row] {
        try M.validate(raw, width: 866, count: raw.count, name: "band source")
        try M.validate(bands, width: width(bundle, "bandFeatureCount"), count: raw.count, name: "differential bands")
        var result = try predictComplementaryPage(bundle: object(bundle, "primary"), raw: raw, fill71v1: fill71v1,
                                                  styles: styles, paired: paired, mixed: mixed, probability: probability)
        if raw.isEmpty { return result }
        let body = try object(bundle, "body"), physical = try object(bundle, "physical"), stem = try object(bundle, "stem")
        let bodyScores = try scores(body, raw.map { Array($0[..<597]) }, probability)
        let physicalRaw = raw.indices.map { i in Array(raw[i][..<604]) + paired[i] + Array(raw[i][604...]) }
        let physicalScores = try scores(physical, physicalRaw, probability)
        let stemWidth = try width(stem, "rawFeatureCount")
        let stemRaw = stemWidth == bands[0].count ? bands : raw.indices.map { raw[$0] + bands[$0] }
        guard stemRaw[0].count == stemWidth else { throw invalid("Stem head layout differs") }
        let stemScores = try scores(stem, stemRaw, probability)
        let confirmed = try confirmation(bands, policy: object(bundle, "bandPolicy"))
        let bodyThreshold = try number(body, "threshold"), physicalThreshold = try number(physical, "threshold")
        let stemThreshold = try number(stem, "threshold")
        for i in result.indices {
            let agreed = bodyScores[i] >= bodyThreshold && physicalScores[i] >= physicalThreshold
            let learned = stemScores[i] >= stemThreshold
            let added = result[i]["sourceWeight"] as? String == "regular" && (learned || (agreed && confirmed[i]))
            if added { result[i].merge(renderPolicy("bold")) { _, new in new } }
            // Expose the two head scores as well as every original runtime flag.
            result[i]["bodyScore"] = bodyScores[i]; result[i]["physicalHeadScore"] = physicalScores[i]
            result[i]["stemRescueScore"] = stemScores[i]; result[i]["stemRescueApplied"] = added && learned
            result[i]["physicalHeadAgreement"] = agreed; result[i]["addedStemConfirmed"] = confirmed[i]
            result[i]["confirmedStemRescueApplied"] = added && agreed && confirmed[i]
        }
        return result
    }
}
