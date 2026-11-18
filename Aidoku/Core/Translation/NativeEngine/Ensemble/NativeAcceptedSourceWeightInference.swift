import CryptoKit
import Foundation

/// One estimate call's already-measured nominal ordered observation, not a
/// feature/global cache. Its immutable context/styles are scoped by requestID.
enum NativeSourceWeightOrderedObservationReuse {
    struct Binding: Equatable {
        let requestID: UUID
        let ownerIndex: Int
        let sourceIdentity: String
        let geometryMode: String
        let priorBits: UInt64
        let emBits: UInt64
        let angleBits: UInt64
    }
    struct Recorded {
        let binding: Binding
        let observation: [String: Any]
    }
    static func observation(_ recorded: Recorded?, binding: Binding,
                            factor: Double, ordered: Bool) -> [String: Any]? {
        guard factor == 0, ordered, let recorded, recorded.binding == binding else { return nil }
        return recorded.observation
    }
}

/// Source-only operational consumer of the registered frozen heads. All image
/// policies consume the SAME segmentation/RF/font/style packets, never GT rows.
final class NativeAcceptedSourceWeightInference {
    typealias Row = [String: Any]
    private typealias Policy = NativeSourceWeightImagePolicy
    enum Failure: Error { case invalid(String) }
    private let heads: NativeAppearanceModelHeads
    private let bundle: Row
    private let referencePairs: [Row]
    private let inkPairs: [Row]
    private let referencePolicies: [Row]
    private let font: NativeAcceptedSourceFontInference

    static func productionEnabled(heads: NativeAppearanceModelHeads) throws -> Bool {
        let data = try Data(contentsOf: heads.directory.appendingPathComponent("registry-index.json"))
        guard let index = try JSONSerialization.jsonObject(with: data) as? Row,
              let assets = index["metadataAssets"] as? [String: Row], let asset = assets["fontWeight"],
              let relative = asset["asset"] as? String, !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
              let digest = asset["sha256"] as? String else { throw Failure.invalid("font weight activation metadata") }
        let payload = try Data(contentsOf: heads.directory.appendingPathComponent(relative))
        guard SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined() == digest,
              let document = try JSONSerialization.jsonObject(with: payload) as? Row,
              document["schema"] as? Int == 1, document["sourceOnly"] as? Bool == true,
              document["GTAtInference"] as? Bool == false,
              let enabled = document["productionActivated"] as? Bool else { throw Failure.invalid("font weight activation binding") }
        return enabled
    }

    init(heads: NativeAppearanceModelHeads, font: NativeAcceptedSourceFontInference, fontResources: URL? = nil) throws {
        self.heads = heads; self.font = font
        let registry = try NativeFrozenSourceModel.Registry(directory: heads.directory, includeMetadata: true)
        let metadata = try registry.metadataTreeFoundation
        guard let accepted = metadata["font-weight/complete-complementary"] as? Row,
              let references = accepted["referencePairs"] as? [Row], references.count == 4,
              let ink = accepted["referenceInkPairs"] as? [Row] else { throw Failure.invalid("accepted weight metadata") }
        bundle = accepted
        referencePairs = try NativeSourceWeightFontResources.pairs(references, resourceRoot: fontResources)
        inkPairs = try NativeSourceWeightFontResources.pairs(ink, resourceRoot: fontResources)
        var policies = [Row]()
        if let policy = accepted["referenceInkPolicy"] as? Row { policies.append(policy) }
        policies += accepted["referenceInkAdditionalPolicies"] as? [Row] ?? []
        referencePolicies = try policies.map { original in
            var policy = original
            if let info = policy["informationFont"] as? Row {
                let pair = try NativeSourceWeightFontResources.pairs([["name": "information", "regular": info, "heavy": info]],
                                                                    resourceRoot: fontResources)[0]
                policy["informationFont"] = pair["regular"]
            }
            return policy
        }
    }
    private func number(_ row: Row, _ key: String) throws -> Double {
        guard let value = row[key] as? NSNumber, value.doubleValue.isFinite else { throw Failure.invalid(key) }
        return value.doubleValue
    }
    private func score(_ row: Row, _ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
    private func regular(_ row: Row) -> Bool { row["sourceWeight"] as? String == "regular" }
    private func probability(_ identity: String, _ values: [[Double]]) throws -> [[Double]] {
        try heads.model(identity).predictProbability(values)
    }
    private func evidence(_ context: NativeAcceptedSourceFontInference.SourceFontContext, _ styles: [Row],
                          _ index: Int, _ em: Double, _ kind: String, ordered: Bool = false,
                          policy: Row? = nil, angle: Double? = nil) throws -> Row {
        try font.weightImageEvidence(context, index: index, style: styles[index], sourceEM: em, kind: kind,
            references: kind == "normalization-bands" ? referencePairs : inkPairs,
            ordered: ordered, policy: policy, sourceAngle: angle)
    }
    private func members(_ context: NativeAcceptedSourceFontInference.SourceFontContext, _ index: Int) -> [Row] {
        let input = context.packets[index]
        return input.wordEvidence.filter {
            $0.bbox.minX >= 0 && $0.bbox.minY >= 0 &&
            $0.bbox.maxX <= CGFloat(input.width) + 1 && $0.bbox.maxY <= CGFloat(input.height) + 1
        }.map { ["text": $0.text] }
    }
    private func reference(_ context: NativeAcceptedSourceFontInference.SourceFontContext, _ styles: [Row],
                           _ index: Int, _ em: Double, _ prior: Row, _ policy: Row) throws -> Row {
        let field = policy["existingScoreField"] as? String ?? "none"
        let eligible = try regular(prior) && (field == "none" || score(prior, field) >= number(policy, "minimumExistingScore"))
        var observation: Row = ["words": [Row]()], measured = false, information: Int?
        if eligible {
            if policy["minimumInformativeGlyphs"] != nil {
                let value = try evidence(context, styles, index, em, "information", policy: policy)
                guard let count = value["informativeGlyphs"] as? Int else { throw Failure.invalid("glyph information") }
                information = count
                if Double(count) < (try number(policy, "minimumInformativeGlyphs")) {
                    var result = prior; result["referenceInformativeGlyphs"] = count; result["glyphInformationRescueApplied"] = false
                    return result
                }
            }
            if !members(context, index).isEmpty {
                measured = true
                let eligibility = try evidence(context, styles, index, em, "eligibility")
                guard let stages = eligibility["stages"] as? [Row], stages.count == 3 else { throw Failure.invalid("stroke eligibility") }
                let widths = try stages.map { stage -> Double in
                    guard let q = stage["pairedQuantiles"] as? [Double], q.count == 4 else { throw Failure.invalid("stroke quantiles") }
                    return q[2]
                }
                let components = try stages.map { try number($0, "components") }
                if widths.max()! >= 0.10 && components.max()! >= 2 {
                    observation = try evidence(context, styles, index, em, "reference")
                    if policy["requireCompleteWordEvidence"] as? Bool == true,
                       (observation["words"] as? [Row])?.count != min(6, members(context, index).count) {
                        observation = ["words": [Row]()]
                    }
                }
            }
        }
        var result = try Policy.applyReference(observation: observation, prediction: prior, policy: policy)
        result["registeredInkRescueApplied"] = result["registeredInkRescueApplied"] as? Bool == true || prior["registeredInkRescueApplied"] as? Bool == true
        result["referenceSourceMeasured"] = measured || prior["referenceSourceMeasured"] as? Bool == true
        if let information {
            result["referenceInformativeGlyphs"] = information
            result["glyphInformationRescueApplied"] = result["sourceWeight"] as? String != prior["sourceWeight"] as? String
        }
        return result
    }
    private func soft(_ context: NativeAcceptedSourceFontInference.SourceFontContext, _ styles: [Row],
                      _ index: Int, _ em: Double, _ prior: Row, _ policy: Row) throws -> Row {
        guard regular(prior), score(prior, "polarityRescueScore") >= (try number(policy, "minimumExistingScore")) else {
            var result = prior; result["softInkRescueApplied"] = false; result["softSourceMeasured"] = false; return result
        }
        let measured = try evidence(context, styles, index, em, "soft")
        var result = try Policy.applySoft(observation: measured, prior: prior, policy: policy)
        result["softSourceMeasured"] = true; return result
    }
    private func orderedEligible(_ prior: Row, _ style: Row, _ policy: Row) throws -> Bool {
        try regular(prior) && score(prior, "polarityRescueScore") >= number(policy, "minimumExistingScore") &&
            Policy.outlineWitness(style: style, policy: policy)
    }
    private func ordered(_ context: NativeAcceptedSourceFontInference.SourceFontContext, _ styles: [Row],
                         _ index: Int, _ em: Double, _ prior: Row, _ policy: Row,
                         requestID: UUID, nominal: inout [Int: NativeSourceWeightOrderedObservationReuse.Recorded]) throws -> Row {
        guard try orderedEligible(prior, styles[index], policy) else {
            var result = prior; result["orderedInkRescueApplied"] = false; result["orderedSourceMeasured"] = false; return result
        }
        var measured = try evidence(context, styles, index, em, "soft", ordered: true)
        // Record BEFORE policy-only annotations. refineScale's factor0 requests
        // the same kind/ordered/references/angle/EM from this immutable context.
        nominal[index] = .init(binding: nominalBinding(context, index, em, requestID), observation: measured)
        measured["expectedGlyphCounts"] = try Policy.expectedGlyphCounts(members: members(context, index))
        measured["outlineWitnessed"] = true
        var result = try Policy.applyOrdered(observation: measured, prior: prior, policy: policy)
        result["orderedSourceMeasured"] = true; return result
    }
    private func nominalBinding(_ context: NativeAcceptedSourceFontInference.SourceFontContext,
                                _ index: Int, _ em: Double, _ requestID: UUID) -> NativeSourceWeightOrderedObservationReuse.Binding {
        .init(requestID: requestID, ownerIndex: index, sourceIdentity: context.packets[index].sourceIdentity,
              geometryMode: context.geometryMode == .bboxOnly ? "bbox-only" : "original-members",
              priorBits: context.originalPriors[index].bitPattern, emBits: em.bitPattern,
              angleBits: context.angles131[index].bitPattern)
    }
    private func render(_ label: String, into result: inout Row) {
        result["sourceWeight"] = label; result["renderBold"] = label == "bold"
        result["renderWeight"] = label == "bold" ? "bold" : "regular"
        result["requiresTranslationSpanAlignment"] = label == "mixed"; result["translatedStyleRuns"] = [Row]()
    }

    func estimate(_ context: NativeAcceptedSourceFontInference.SourceFontContext, styles: [Row],
                  diagnostics: (@Sendable (_ sourceIndex:Int,_ stage:String,_ payload:[String:Any]) throws -> Void)? = nil) throws -> [Row] {
        guard context.geometryMode == .bboxOnly, context.packets.count == styles.count else { throw Failure.invalid("weight normalization geometry") }
        if context.packets.isEmpty { return [] }
        let requestID = UUID()
        var nominalOrdered: [Int: NativeSourceWeightOrderedObservationReuse.Recorded] = [:]
        let measurementStart = diagnostics == nil ? nil : DispatchTime.now().uptimeNanoseconds
        let measurements = try font.weightMeasurements(context, styles: styles)
        if let diagnostics {
            let measurementMicroseconds = Double(DispatchTime.now().uptimeNanoseconds - measurementStart!) / 1000
            let registry = try Data(contentsOf: heads.directory.appendingPathComponent("registry-index.json"))
            let modelIdentity = NativeFrozenSourceSHA256.hex(registry)
            for i in context.packets.indices {
                try diagnostics(i, "weight-features", [
                    "schema": "aidoku-native-source-features-v1", "sourceOnly": true, "GTAtInference": false,
                    "registrySHA256": modelIdentity,
                    "raw866": measurements.raw866[i], "fill71": measurements.fill71[i],
                    "paired48": measurements.paired48[i], "bands112": measurements.bands112[i],
                    "angle131": measurements.angles131[i], "sourceEM": measurements.sourceEMs[i],
                    "mixed": measurements.mixed[i],
                    "residualReused": measurements.residualReused[i],
                    "batchMeasurementMicroseconds": measurementMicroseconds, "batchOwners": context.packets.count,
                    "physicalReferenceAvailable": measurements.physicalReferenceAvailable])
            }
        }
        var predictions = try NativeSourceWeightGraph.predictBandPage(bundle: bundle, raw: measurements.raw866,
            fill71v1: measurements.fill71, styles: styles, paired: measurements.paired48, bands: measurements.bands112,
            mixed: measurements.mixed, probability: probability)
        let ems = context.finalSourceEMs
        if let policy = bundle["directionalInkPolicy"] as? Row {
            let values = try ems.indices.map { try evidence(context, styles, $0, ems[$0], "directional") }
            predictions = try Policy.applyDirectionalPage(observations: values, predictions: predictions, policy: policy)
        }
        for policy in referencePolicies {
            predictions = try predictions.indices.map { try reference(context, styles, $0, ems[$0], predictions[$0], policy) }
        }
        if let policy = bundle["softInkPolicy"] as? Row {
            predictions = try predictions.indices.map { try soft(context, styles, $0, ems[$0], predictions[$0], policy) }
        }
        if let policy = bundle["orderedInkPolicy"] as? Row {
            predictions = try predictions.indices.map {
                try ordered(context, styles, $0, ems[$0], predictions[$0], policy,
                            requestID: requestID, nominal: &nominalOrdered)
            }
            for i in predictions.indices where predictions[i]["softInkRescueApplied"] as? Bool == true {
                let observed = try evidence(context, styles, i, ems[i], "soft", ordered: true)
                let veto = try Policy.regularGlyphAgreement(observation: observed,
                    counts: Policy.expectedGlyphCounts(members: members(context, i)), policy: policy)
                predictions[i]["sourceSoftGlyphConfirmationMeasured"] = true
                predictions[i]["sourceSoftGlyphConflictVetoApplied"] = veto
                if veto { render("regular", into: &predictions[i]); predictions[i]["softInkRescueApplied"] = false }
            }
        }
        predictions = try refineConfidence(context, styles, measurements, predictions)
        predictions = try refineScale(context, styles, predictions, requestID: requestID, nominalOrdered: nominalOrdered)
        for i in predictions.indices {
            predictions[i]["sameCallFontSignalsUsed"] = measurements.residualReused[i]
            predictions[i]["sourceWeightResidualRemeasured"] = !measurements.residualReused[i]
            predictions[i]["sourcePhysicalReferenceAvailable"] = measurements.physicalReferenceAvailable
        }
        return predictions
    }

    private func headScores(_ config: Row, _ values: [[Double]]) throws -> [Double] {
        let expanded = try NativeSourceWeightGraph.pageContext(values)
        guard expanded.first?.count == Int(try number(config, "featureCount")),
              let identity = NativeSourceFontGraphMath.modelID(config["model"]) else { throw Failure.invalid("weight head feature layout") }
        let result = try probability(identity, expanded)
        guard result.count == values.count, result.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) else {
            throw Failure.invalid("source weight probability")
        }
        return result.map { $0[1] }
    }
    private func refineConfidence(_ context: NativeAcceptedSourceFontInference.SourceFontContext, _ styles: [Row],
                                  _ measured: NativeSourceWeightMeasurements.Result, _ predictions: [Row]) throws -> [Row] {
        guard let primary = bundle["primary"] as? Row, let polarity = primary["polarity"] as? Row,
              let stem = bundle["stem"] as? Row, let base = primary["primary"] as? Row else { throw Failure.invalid("weight bounds metadata") }
        let ems = context.finalSourceEMs, low = ems.map { max(1, $0 - 2) }, high = ems.map { $0 + 2 }
        let actual = predictions.map { score($0, "polarityRescueScore") }
        var upper = actual, result = predictions
        func polarityScores(_ fills: [[Double]]) throws -> [Double] {
            let raw = measured.raw866.indices.map { i in
                Array(measured.raw866[i][..<597]) + fills[i] + Array(measured.raw866[i][604...])
            }
            return try headScores(polarity, raw)
        }
        for variantEMs in [low, high] {
            let fills = try variantEMs.indices.map { i -> [Double] in
                let values = try evidence(context, styles, i, variantEMs[i], "normalization")
                guard let vector = values["fill71"] as? [Double], vector.count == 71 else { throw Failure.invalid("source fill71 uncertainty") }
                return vector
            }
            let coherent = try polarityScores(fills)
            for i in upper.indices { upper[i] = max(upper[i], coherent[i]) }
            for i in fills.indices {
                var peerVariant = measured.fill71; peerVariant[i] = fills[i]
                let scores = try polarityScores(peerVariant)
                for j in upper.indices { upper[j] = max(upper[j], scores[j]) }
            }
        }
        let policies = referencePolicies.filter { $0["existingScoreField"] as? String == "polarityRescueScore" }
        let floors = try policies.map { try number($0, "minimumExistingScore") }
        let nominalFloor = floors.min() ?? .infinity
        for policy in policies {
            let floor = try number(policy, "minimumExistingScore")
            for i in result.indices where regular(result[i]) && nominalFloor <= actual[i] && actual[i] < floor && floor <= upper[i] {
                var prior = result[i]; prior["polarityRescueScore"] = upper[i]
                result[i] = try reference(context, styles, i, ems[i], prior, policy)
                result[i]["polarityRescueScore"] = actual[i]
                result[i]["sourcePolaritySampledUpperConfidence"] = upper[i]
                result[i]["sourceEmConfidenceBoundUsed"] = true
            }
        }
        if let policy = bundle["softInkPolicy"] as? Row {
            let floor = try number(policy, "minimumExistingScore")
            for i in result.indices where regular(result[i]) && actual[i] < floor && floor <= upper[i] {
                var prior = result[i]; prior["polarityRescueScore"] = upper[i]
                result[i] = try soft(context, styles, i, ems[i], prior, policy)
                result[i]["polarityRescueScore"] = actual[i]
                result[i]["sourcePolaritySampledUpperConfidence"] = upper[i]
                result[i]["sourceEmConfidenceBoundUsed"] = true
            }
        }
        let stemWidth = Int(try number(stem, "rawFeatureCount")), stemThreshold = try number(stem, "threshold")
        for i in result.indices where regular(result[i]) && result[i]["addedStemConfirmed"] as? Bool == true {
            var maximum = score(result[i], "stemRescueScore")
            for em in [low[i], high[i]] {
                let value = try evidence(context, styles, i, em, "normalization-bands", angle: measured.angles131[i])
                guard let row = value["bands112"] as? [Double], row.count == 112 else { throw Failure.invalid("source band uncertainty") }
                var variant = measured.bands112; variant[i] = row
                let features = stemWidth == row.count ? variant : variant.indices.map { measured.raw866[$0] + variant[$0] }
                maximum = max(maximum, try headScores(stem, features)[i])
            }
            if maximum >= stemThreshold {
                render("bold", into: &result[i]); result[i]["sourceEmStemBoundRescueApplied"] = true
                result[i]["sourceStemSampledUpperConfidence"] = maximum
            }
        }
        if let policy = bundle["directionalInkPolicy"] as? Row {
            let threshold = try number(base, "threshold")
            let before = predictions.map { original -> Row in
                var row = original
                if row["sourceWeight"] as? String != "mixed" {
                    let modelBold = score(row, "boldScore") >= threshold ||
                        ["physicalCorrection", "polarityRescueApplied", "stemRescueApplied", "confirmedStemRescueApplied"].contains { row[$0] as? Bool == true }
                    row["sourceWeight"] = modelBold ? "bold" : "regular"
                }
                return row
            }
            let observed = try low.indices.map { try evidence(context, styles, $0, low[$0], "directional") }
            let added = try Policy.classifyDirectionalPage(observations: observed, predictions: before, policy: policy)
            for i in result.indices where added[i] && regular(result[i]) {
                render("bold", into: &result[i]); result[i]["sourceEmDirectionalBoundRescueApplied"] = true
            }
        }
        return result
    }
    private func fitQuality(_ observation: Row, _ counts: [Int]) -> [Double]? {
        guard let words = observation["words"] as? [Row], !words.isEmpty, words.count == counts.count else { return nil }
        var wordFits = [Double](), glyphFits = [Double]()
        for (word, count) in zip(words, counts) {
            guard count > 0, let ordered = word["orderedGlyphs"] as? Row,
                  let glyphs = ordered["glyphs"] as? [Row], glyphs.count == count,
                  let fit = word["templateFit"] as? Double, fit.isFinite else { return nil }
            wordFits.append(fit)
            for glyph in glyphs {
                guard let value = glyph["templateFit"] as? Double, value.isFinite else { return nil }
                glyphFits.append(value)
            }
        }
        return [wordFits.min()!, glyphFits.reduce(0, +) / Double(glyphFits.count)]
    }
    private func refineScale(_ context: NativeAcceptedSourceFontInference.SourceFontContext, _ styles: [Row],
                             _ predictions: [Row], requestID: UUID,
                             nominalOrdered: [Int: NativeSourceWeightOrderedObservationReuse.Recorded]) throws -> [Row] {
        guard let policy = bundle["orderedInkPolicy"] as? Row else { return predictions }
        var result = predictions
        for i in result.indices {
            let prior = predictions[i], em = context.finalSourceEMs[i]
            guard try orderedEligible(prior, styles[i], policy) else { continue }
            let counts = try Policy.expectedGlyphCounts(members: members(context, i)), radius = min(2, 0.05 * em)
            var selection: (rank: [Double], em: Double, observation: Row)?
            for factor in [0.0, -0.5, 0.5, -1.0, 1.0] {
                let candidate = em + factor * radius
                let observed: Row
                if let reused = NativeSourceWeightOrderedObservationReuse.observation(nominalOrdered[i],
                    binding: nominalBinding(context, i, candidate, requestID), factor: factor, ordered: true) {
                    observed = reused
                } else {
                    observed = try evidence(context, styles, i, candidate, "soft", ordered: true)
                }
                guard let quality = fitQuality(observed, counts) else { continue }
                let rank = quality + [-abs(candidate - em)]
                if selection == nil || selection!.rank.lexicographicallyPrecedes(rank) { selection = (rank, candidate, observed) }
            }
            guard let selected = selection else {
                result[i]["sourceFontScaleFitMeasured"] = true; result[i]["sourceFontScaleFitApplied"] = false; continue
            }
            var observation = selected.observation
            observation["expectedGlyphCounts"] = counts; observation["outlineWitnessed"] = true
            result[i] = try Policy.applyOrdered(observation: observation, prior: prior, policy: policy)
            result[i]["sourceFontScaleFitMeasured"] = true
            result[i]["sourceFontScaleFitApplied"] = result[i]["sourceWeight"] as? String != prior["sourceWeight"] as? String
            result[i]["sourceWeightMeasurementEM"] = selected.em; result[i]["sourceFontScaleUncertaintyPx"] = radius
            result[i]["sourceFontScaleHypotheses"] = 5
        }
        return result
    }
}
