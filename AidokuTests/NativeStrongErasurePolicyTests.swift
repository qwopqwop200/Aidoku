import Foundation
import Testing
@testable import Aidoku

/// Coreless policy/cache/actual-primary output seam; no model/resource loads.
struct NativeStrongErasurePolicyTests {
    @Test func weakRecoveryUsesOnlyOriginalStrongRunsAtEdgesAndGaps() throws {
        let values: [Float] = [0, 0.01, 0.08, Float(0.25).nextDown, 0.25, 0.6]
        for (width, height) in [(1, 7), (9, 1), (13, 11)] {
            let p = (0..<(width * height)).map { values[(($0 * 7) ^ ($0 / 5)) % values.count] }
            for r in 1...3 {
                for weak: Float in [0.01, 0.1, 0.25] {
                    let expected: [UInt8] = p.indices.map { i in
                        guard p[i] >= weak else { return 0 }
                        let x = i % width, y = i / width
                        for yy in max(0, y - r)...min(height - 1, y + r) {
                            for xx in max(0, x - r)...min(width - 1, x + r) where p[yy * width + xx] >= 0.25 {
                                return 255
                            }
                        }
                        return 0
                    }
                    let actual = try NativeMinimalSourceSegmentation.recoverWeak(primary: p, width: width, height: height,
                        strongThreshold: 0.25, recovery: .init(minimumPrimaryProbability: weak, radius: r))
                    #expect(actual == expected)
                }
            }
        }
    }

    @Test func independentPoliciesRetainFeatureM1AndTypedRollbacks() throws {
        typealias Policy = NativeSourceInferencePolicy
        let feature = Policy.primaryM1Configuration
        let old = Policy.primaryErasureConfiguration(.originalM1)
        let mild = Policy.primaryErasureConfiguration(.mild)
        let strong = Policy.primaryErasureConfiguration(.strong)
        #expect(feature == old)
        #expect(feature.policySHA256 == "3d14f38a5492ba23f3a748d0db59480e4f82007e59f0aa5f24d213084d205aa0")
        #expect(mild.policySHA256 == "dea785ae9a3c1414cfcad44ed2426d1550f517643a217580211064dcff2c37b9")
        #expect(strong.policySHA256 == "7f89e881323675c8c2e6d63cca2454995ee2effe49334e433630684efb0eed46")
        #expect(Policy.defaultErasurePolicy == .originalM1)
        for mode in [Policy.Mode.minimalPrimary, .minimalM1P9Body32, .minimalM1P9Body64, .minimalM1P9Body64Presence95,
                     .simpleFontAcceptedStyle, .simpleFontAcceptedStyleWeight,
                     .simpleFontAcceptedStyleBody, .simpleFontAcceptedStyleBodyFixedGap] {
            #expect(Policy.erasureConfiguration(for: mode) == old)
            #expect(Policy.erasureConfiguration(for: mode, erasurePolicy: .strong) == strong)
            #expect(Policy.erasureConfiguration(for: mode, erasurePolicy: .mild) == mild)
        }
        #expect(Policy.erasureConfiguration(for: .accepted) == nil)
        #expect(Policy.erasureConfiguration(for: .minimalRF) == nil)
    }

    @available(iOS 18.0, macOS 15.0, *)
    @Test func differingPolicyUsesActualPrimaryWithoutMutatingStyleMask() throws {
        let p: [Float] = [0.05, 0.1, 0.25, 0.1, 0.05]
        let feature = NativeSourceInferencePolicy.primaryM1Configuration
        let styleMask = try NativeMinimalSourceSegmentation.postprocessPrimary(p, width: 5, height: 1, configuration: feature)
        let observation = NativeMinimalSourceSegmentation.Output(mask: styleMask, primary: p, nativeSeed: nil,
            audit: ["policySHA256": feature.policySHA256])
        let erased = try NativeOperationalSourceInference.minimalErasureMask(observation: observation, width: 5, height: 1,
            configuration: NativeSourceInferencePolicy.primaryErasureConfiguration(.strong))
        #expect(styleMask == [255, 255, 255, 255, 255])
        #expect(erased == [0, 255, 255, 255, 0])
        #expect(observation.mask == styleMask)
        #expect(observation.primary == p)
    }

    @available(iOS 18.0, macOS 15.0, *)
    @Test func equalActualPolicyReusesMaskAndMissingPrimaryNeverFallsBack() throws {
        let feature = NativeSourceInferencePolicy.primaryM1Configuration
        let actual: [UInt8] = [0, 255, 255, 255, 0]
        // An absent primary proves the same-policy route does not replay p.
        let observation = NativeMinimalSourceSegmentation.Output(mask: actual, primary: nil, nativeSeed: nil,
            audit: ["policySHA256": feature.policySHA256])
        #expect(try NativeOperationalSourceInference.minimalErasureMask(observation: observation, width: 5, height: 1,
            configuration: feature) == actual)
        #expect(try NativeOperationalSourceInference.minimalErasureMask(observation: observation, width: 5, height: 1,
            configuration: nil) == actual)
        #expect(throws: (any Error).self) {
            try NativeOperationalSourceInference.minimalErasureMask(observation: observation, width: 5, height: 1,
                configuration: NativeSourceInferencePolicy.primaryErasureConfiguration(.strong))
        }
        let missingIdentity = NativeMinimalSourceSegmentation.Output(mask: actual, primary: nil, nativeSeed: nil, audit: [:])
        #expect(throws: (any Error).self) {
            try NativeOperationalSourceInference.minimalErasureMask(observation: missingIdentity, width: 5, height: 1,
                configuration: feature)
        }
    }

    @Test func defaultReusePublishesBothMaskIdentities() throws {
        if NativeSourceInferencePolicy.selected.usesMinimalM1Style {
            let cache = NativeSourceInferencePolicy.cacheProjection
            #expect(cache["sourceSegmentationPolicySHA256"] == NativeSourceInferencePolicy.primaryM1Configuration.policySHA256)
            #expect(cache["sourceErasurePolicySHA256"] == NativeSourceInferencePolicy.primaryErasureConfiguration(.originalM1).policySHA256)
            #expect(cache["sourceErasureSelection"] == NativeSourceInferencePolicy.ErasurePolicy.originalM1.rawValue)
            #expect(cache["sourceErasureMode"] == "M1-from-single-actual-primary;shared-style-and-erasure-mask")
        }
    }
}
