import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Source-only synthetic pixels and actual retained-support carriers. No model,
/// component-domain inference, image exports, or corpus/page-specific fixtures.
struct NativeSourceBoundaryContrastTests {
    private typealias Context = NativeSourcePhysicalInteriorContext
    private typealias Admission = NativeFinalTextPaintAdmission

    private func diagonalContext(highContrast: Bool = false) throws -> Context {
        let width = 96, height = 96
        let brown: [UInt8] = [126, 92, 64]
        // Every channel differs by less than 64, but one differs by more than
        // 32. The stronger control is visible to both contrast policies.
        let ink: [UInt8] = highContrast ? [46, 26, 16] : [82, 53, 33]
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height { for x in 0..<width {
            let colour = x == y ? ink : brown
            for channel in 0..<3 { rgb[(y * width + x) * 3 + channel] = colour[channel] }
        } }
        return try #require(Context(rgb: rgb, width: width, height: height,
            erased: [UInt8](repeating: 0, count: width * height),
            sourceIdentity: highContrast ? "synthetic-brown-strong-diagonal" : "synthetic-brown-low-diagonal",
            sourceOpaque: true))
    }

    private func support(x: Int, y: Int) -> Admission.Footprint {
        .init(runs: [.init(y: y, left: x, right: x + 2),
                     .init(y: y + 1, left: x, right: x + 2)],
            bounds: CGRect(x: x, y: y, width: 2, height: 2), pixels: 4)
    }

    @Test func lowContrastDiagonalVetoIsIndependentOfContrastCacheWarmupOrder() throws {
        let before = support(x: 35, y: 27)
        let after = before.translated(CGPoint(x: 0, y: 4))
        // Reusing each context in both directions catches either policy
        // contaminating the other policy's source-distance tiles.
        for order in [[64, 32, 64, 32], [32, 64, 32, 64]] {
            let context = try diagonalContext()
            for contrast in order {
                let result = context.boundaryClearance(before: before, after: after,
                    minimumChannelContrast: contrast)
                #expect(result.allowed == (contrast == 64))
                #expect(result.audit["contrastRange"] as? Int == contrast)
                #expect(result.audit["observationComplete"] as? Bool == true)
                #expect(result.audit["comparedAlphaPixels"] as? Int == 4)
                #expect(result.audit["physicalContainmentMeasured"] as? Bool == false)
                if contrast == 32 {
                    #expect((result.audit["adverseAlphaPixels"] as? Int ?? 0) > 0)
                } else {
                    #expect(result.audit["adverseAlphaPixels"] as? Int == 0)
                }
            }
        }
    }

    @Test func omittedContrastPreserves64PolicyAfterStrictCacheQueries() throws {
        let context = try diagonalContext()
        let before = support(x: 35, y: 27)
        let after = before.translated(CGPoint(x: 0, y: 4))
        let initial = context.boundaryClearance(before: before, after: after)
        #expect(initial.allowed == true)
        #expect(context.boundaryClearance(before: before, after: after,
            minimumChannelContrast: 32).allowed == false)
        let retainedDefault = context.boundaryClearance(before: before, after: after)
        let explicit64 = context.boundaryClearance(before: before, after: after,
            maximumAllowedDecreasePixels: 1, minimumChannelContrast: 64)
        #expect(retainedDefault.allowed == true)
        #expect(explicit64.allowed == true)
        #expect(retainedDefault.audit["contrastRange"] as? Int == 64)
        #expect(retainedDefault.audit["maximumAllowedDecreasePixels"] as? Int == 1)
        #expect(retainedDefault.audit["adverseAlphaPixels"] as? Int == initial.audit["adverseAlphaPixels"] as? Int)
    }

    @Test func zeroLossVetoesActualOnePixelApproachThatDefaultOneLossAllows() throws {
        let before = support(x: 35, y: 30)
        let after = before.translated(CGPoint(x: 0, y: 1))
        for order in [[1, 0, 1], [0, 1, 0]] {
            let context = try diagonalContext(highContrast: true)
            for loss in order {
                let result = context.boundaryClearance(before: before, after: after,
                    maximumAllowedDecreasePixels: loss)
                #expect(result.allowed == (loss == 1))
                #expect(result.audit["observationComplete"] as? Bool == true)
                if loss == 0 {
                    let witness = try #require(result.audit["firstAdverseOldNewXYDistance"] as? [Int])
                    #expect(witness.count == 6)
                    if witness.count == 6 {
                        #expect(witness[4] - witness[5] == 1)
                        #expect(witness[5] <= 2)
                    }
                }
            }
            #expect(context.boundaryClearance(before: before, after: after).allowed == true)
        }
    }

    @Test func invalidContrastOrLossReturnsUnknownWithoutPoisoningValidQueries() throws {
        let context = try diagonalContext()
        let before = support(x: 35, y: 27)
        let after = before.translated(CGPoint(x: 0, y: 4))
        for contrast in [0, 31, 33, 63, 65, Int.max] {
            let result = context.boundaryClearance(before: before, after: after,
                minimumChannelContrast: contrast)
            #expect(result.allowed == nil)
            #expect(result.audit["status"] as? String == "invalid-boundary-contrast-policy")
            #expect(result.audit["evidenceAvailable"] as? Bool == false)
        }
        for loss in [-1, 2, Int.max] {
            let result = context.boundaryClearance(before: before, after: after,
                maximumAllowedDecreasePixels: loss)
            #expect(result.allowed == nil)
            #expect(result.audit["status"] as? String == "invalid-margin-loss-policy")
            #expect(result.audit["evidenceAvailable"] as? Bool == false)
        }
        #expect(context.boundaryClearance(before: before, after: after).allowed == true)
        #expect(context.boundaryClearance(before: before, after: after,
            minimumChannelContrast: 32).allowed == false)
    }

    @Test func stricterContrastAndZeroLossPreserveStationaryAndRetreatingSupport() throws {
        let context = try diagonalContext()
        let before = support(x: 35, y: 27)
        for after in [before, before.translated(CGPoint(x: 0, y: -2))] {
            let result = context.boundaryClearance(before: before, after: after,
                maximumAllowedDecreasePixels: 0, minimumChannelContrast: 32)
            #expect(result.allowed == true)
            #expect(result.audit["adverseAlphaPixels"] as? Int == 0)
            #expect(result.audit["observationComplete"] as? Bool == true)
        }
    }
}
