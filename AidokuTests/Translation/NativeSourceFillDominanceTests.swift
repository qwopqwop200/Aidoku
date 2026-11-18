import Foundation
import Testing
@testable import Aidoku

/// Synthetic source observations exercise production selection, not a duplicate colour algorithm.
struct NativeSourceFillDominanceTests {
    private let pink: [Double] = [211, 68, 150]
    private let blue: [Double] = [25, 105, 207]
    private let nearbyBlue: [Double] = [27, 106, 208]
    private let green: [Double] = [25, 180, 55]
    private let paper: [Double] = [250, 250, 248]

    private func observation(_ rgb: [Double], _ mass: Any) -> [String: Any] {
        ["rgb": rgb, "observedMass": mass]
    }

    private func prediction(_ observations: [[String: Any]]? = nil) -> [String: Any] {
        ["sourceOnly": true, "inferenceUsesGT": false,
         "fill": ["rgb": pink, "colors": [pink, blue, nearbyBlue]],
         "outline": ["present": false, "rgb": paper, "widthPx": 0.0],
         "shadow": ["present": false],
         "background": ["rgb": paper, "colors": [paper], "observedContextWeights": [1.0]],
         "pixelRoleEvidence": ["GTAtInference": false, "roles": [
             "fill": ["confidentSamples": 200, "meanProbability": 0.95,
                 "observedColours": observations ?? [observation(blue, 0.4),
                     observation(nearbyBlue, 0.2), observation(pink, 0.1)]],
             "background": ["confidentSamples": 200, "meanProbability": 0.95,
                 "observedColours": [observation(paper, 1.0)]]]]]
    }

    private func withRole(_ prediction: [String: Any], name: String,
                          edit: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var result = prediction
        var evidence = try #require(result["pixelRoleEvidence"] as? [String: Any])
        var roles = try #require(evidence["roles"] as? [String: Any])
        var role = try #require(roles[name] as? [String: Any])
        edit(&role)
        roles[name] = role
        evidence["roles"] = roles
        result["pixelRoleEvidence"] = evidence
        return result
    }

    private func canonical(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func decoded(_ value: [String: Any]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: canonical(value)) as? [String: Any])
    }

    @Test func coherentObservedBlueBeatsUnsupportedPinkWithoutAveragingSourceColours() throws {
        let source = try decoded(prediction())
        let before = try canonical(source)
        // Neither blue mode alone supplies the combined .6 support. The answer
        // must be an actual observed colour, never a synthesized RGB average.
        let recovered = NativeSourceStyleConsistency.observedFillDominance(source)
        #expect(recovered?.selectedRGB == blue)
        #expect(try canonical(source) == before)
        let reordered = try withRole(source, name: "fill") {
            $0["observedColours"] = [observation(pink, 0.1), observation(nearbyBlue, 0.2), observation(blue, 0.4)]
        }
        #expect(NativeSourceStyleConsistency.observedFillDominance(reordered)?.selectedRGB == blue)
    }

    @Test func supportedPrimaryFillRemainsTheDisplayChoice() throws {
        let source = try decoded(prediction([observation(pink, 0.65),
            observation(blue, 0.2), observation(nearbyBlue, 0.1)]))
        #expect(NativeSourceStyleConsistency.observedFillDominance(source) == nil)
    }

    @Test func unreportedMassCompetesWithObservedWinnerIncludingExactTwofoldBoundary() throws {
        // Unreported support is a competitor, not zero or renormalized-away
        // evidence. The first case is exactly .6 versus unknown .3: floating
        // transport must not turn this inclusive twofold boundary into a veto.
        let qualified = [
            [observation(blue, 0.4), observation(nearbyBlue, 0.2), observation(pink, 0.1)],
            [observation(blue, 0.42), observation(nearbyBlue, 0.2), observation(pink, 0.1)]
        ]
        for observations in qualified {
            let source = try decoded(prediction(observations))
            let before = try canonical(source)
            #expect(NativeSourceStyleConsistency.observedFillDominance(source)?.selectedRGB == blue)
            #expect(try canonical(source) == before)
        }
        let unknownDominated = [
            [observation(blue, 0.56), observation(pink, 0.01)],
            [observation(blue, 0.30), observation(nearbyBlue, 0.26), observation(pink, 0.01)],
            [observation(blue, 0.39), observation(nearbyBlue, 0.2), observation(pink, 0.1)]
        ]
        for observations in unknownDominated {
            let source = try decoded(prediction(observations))
            let before = try canonical(source)
            #expect(NativeSourceStyleConsistency.observedFillDominance(source) == nil)
            #expect(try canonical(source) == before)
        }
    }

    @Test func tiedOrMultipleStrongChromaticFamiliesAbstain() throws {
        let variants = [
            [observation(blue, 0.45), observation(green, 0.45), observation(pink, 0.1)],
            [observation(blue, 0.3), observation(nearbyBlue, 0.3), observation(pink, 0.1)],
            [observation(blue, 0.4), observation(nearbyBlue, 0.15),
             observation(green, 0.35), observation(pink, 0.1)]
        ]
        for observations in variants {
            let source = try decoded(prediction(observations))
            #expect(NativeSourceStyleConsistency.observedFillDominance(source) == nil)
        }
    }

    @Test func observedBackgroundColourCannotBecomeReplacementInk() throws {
        let source = try withRole(prediction(), name: "background") {
            $0["observedColours"] = [observation(blue, 0.8), observation(paper, 0.2)]
        }
        #expect(NativeSourceStyleConsistency.observedFillDominance(try decoded(source)) == nil)
    }

    @Test func invalidObservationNumbersAndTotalMassNeverOverride() throws {
        // Bool must not bridge to a valid numeric mass; NaN is deliberately
        // supplied directly because strict JSON cannot carry it.
        let invalidMasses: [Any] = [Double.nan, Double.infinity, true, 1.01, -0.1, NSNull()]
        for mass in invalidMasses {
            let source = prediction([observation(blue, 0.4), observation(nearbyBlue, 0.2),
                observation(pink, 0.1), observation(green, mass)])
            #expect(NativeSourceStyleConsistency.observedFillDominance(source) == nil)
        }
        let overfull = prediction([observation(blue, 0.6), observation(nearbyBlue, 0.45),
            observation(pink, 0.1)])
        #expect(NativeSourceStyleConsistency.observedFillDominance(overfull) == nil)
        let booleanSamples = try withRole(prediction(), name: "fill") { $0["confidentSamples"] = true }
        #expect(NativeSourceStyleConsistency.observedFillDominance(booleanSamples) == nil)
        let invalidRGB = prediction([["rgb": [true, 105, 207] as [Any], "observedMass": 0.4],
            observation(nearbyBlue, 0.2), observation(pink, 0.1)])
        #expect(NativeSourceStyleConsistency.observedFillDominance(invalidRGB) == nil)
    }

    @Test func earlyOperationalAndLateHarmonizedChoicesAgreeWhileSourcePredictionStaysExact() throws {
        let source = try decoded(prediction())
        let original = try canonical(source)
        let binding = Dictionary(uniqueKeysWithValues: NativeOperationalAppearance.bindingKeys.map {
            ($0, String(repeating: "a", count: 64))
        })
        let packet: [String: Any] = ["schema": "aidoku-live-source-appearance-v1",
            "sourceOnly": true, "freshInference": true, "GTAtInference": false,
            "cachedPredictionsRead": false, "binding": binding, "prediction": source]
        let input: [String: Any] = ["id": "synthetic-owner", "sourceFontSize": 48.0,
            "sourceFontWeight": "regular", "renderBold": false, "text": "A 글",
            "sourceBounds": [0.1, 0.2, 0.3, 0.4]]
        let early = try NativeOperationalAppearance.apply(packet: canonical(packet), expectedBinding: binding, to: input)
        #expect(early["ensembleDisplayFill"] as? [Double] == blue)
        let late = try #require(NativeSourceStyleConsistency.harmonized([early]).first)
        #expect(late["renderSourceFillRGB"] as? [Double] == blue)
        for row in [early, late] {
            let retained = try #require(row["sourceAppearance"] as? [String: Any])
            #expect(try canonical(retained) == original)
            #expect(row["sourceAppearanceBinding"] as? [String: String] == binding)
            #expect(row["sourceFontSize"] as? Double == 48)
            #expect(row["renderBold"] as? Bool == false)
            #expect(row["text"] as? String == input["text"] as? String)
            #expect(row["sourceBounds"] as? [Double] == input["sourceBounds"] as? [Double])
        }
        #expect(try canonical(source) == original)
        let twice = try #require(NativeSourceStyleConsistency.harmonized([late]).first)
        #expect(try canonical(twice) == canonical(late))

        var supportedPacket = packet
        let supported = prediction([observation(pink, 0.65), observation(blue, 0.2), observation(nearbyBlue, 0.1)])
        supportedPacket["prediction"] = supported
        let controlEarly = try NativeOperationalAppearance.apply(
            packet: canonical(supportedPacket), expectedBinding: binding, to: input)
        let controlLate = try #require(NativeSourceStyleConsistency.harmonized([controlEarly]).first)
        #expect(controlEarly["ensembleDisplayFill"] as? [Double] == pink)
        #expect(controlLate["renderSourceFillRGB"] as? [Double] == pink)
        let controlSource = try #require(controlLate["sourceAppearance"] as? [String: Any])
        #expect(try canonical(controlSource) == canonical(supported))
    }
}
