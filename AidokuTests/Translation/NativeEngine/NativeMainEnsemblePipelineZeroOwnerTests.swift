import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Actual main-pipeline regressions, not readiness-resolver or backend mocks.
/// All source/mask pixels are tiny deterministic synthetic fixtures.
@Suite(.serialized) @MainActor
struct NativeMainEnsemblePipelineZeroOwnerTests {
    private let width = 8
    private let height = 6

    private func image(stale: Bool = false) throws -> CGImage {
        var rgba: [UInt8] = []
        for y in 0..<height { for x in 0..<width {
            if stale { rgba += [240, 20, 220, 255] }
            else { rgba += [UInt8(17 + x * 9), UInt8(31 + y * 11), UInt8(75 + x + y), 255] }
        } }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func mask(nonzero: Bool) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        if nonzero {
            for y in 1..<5 { for x in 2..<6 { pixels[y * width + x] = 255 } }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func assertPassThrough(_ result: NativeAOTTranslationPageComposer.Result,
                                   original: CGImage, proposedNonzero: Bool) throws {
        // Identity proves the production branch returned the source directly,
        // rather than an approximately equivalent canvas/color-space roundtrip.
        #expect(result.image === original)
        #expect(result.restored === original)
        #expect(try NativeMandatoryDisplayStroke.rgba(result.image) == NativeMandatoryDisplayStroke.rgba(original))
        let applied = try #require(result.removalMask)
        #expect(applied.width == width && applied.height == height)
        let maskRGBA = try NativeMandatoryDisplayStroke.rgba(applied)
        for offset in stride(from: 0, to: maskRGBA.count, by: 4) {
            #expect(maskRGBA[offset] == 0 && maskRGBA[offset + 1] == 0 && maskRGBA[offset + 2] == 0)
        }
        let textRGBA = try NativeMandatoryDisplayStroke.rgba(result.text)
        #expect(stride(from: 3, to: textRGBA.count, by: 4).allSatisfy { textRGBA[$0] == 0 })
        #expect(result.audit["mainPipelineApplied"] as? Bool == true)
        #expect(result.audit["expectedTranslationItems"] as? Int == 0)
        #expect(result.audit["paintedTranslationItems"] as? Int == 0)
        #expect(result.audit["complete"] as? Bool == true)
        #expect(result.audit["qualityAccepted"] as? Bool == false)
        let restoration = try #require(result.audit["restoration"] as? [String: Any])
        #expect(restoration["status"] as? String == "source-pass-through-no-retained-text")
        #expect(restoration["sourceImageReturnedDirectly"] as? Bool == true)
        #expect(restoration["backendRequests"] as? Int == 0)
        #expect(restoration["inferenceCalls"] as? Int == 0)
        #expect(restoration["appliedMaskPixels"] as? Int == 0)
        #expect(restoration["backendMayRun"] as? Bool == false)
        #expect(restoration["callerRestorationMayBeReused"] as? Bool == false)
        #expect(restoration["erasureMode"] as? String == "replace-retained-text")
        #expect(restoration["proposedHasRemovalPixels"] as? Bool == proposedNonzero)
        #expect(restoration["appliedHasRemovalPixels"] as? Bool == false)
        let readiness = try #require(result.audit["removalReadiness"] as? [String: Any])
        #expect(readiness["activeTranslationOwners"] as? Int == 0)
        #expect(readiness["originalSourcePassThrough"] as? Bool == true)
        #expect(readiness["upstreamTranslationCompletenessVerified"] as? Bool == false)
    }

    @Test(arguments: [false, true])
    func zeroRetainedMainPipelineRejectsStaleRestorationForEmptyAndNonemptyProposedMask(nonzero: Bool) throws {
        let original = try image(), stale = try image(stale: true), proposed = try mask(nonzero: nonzero)
        let sourceBefore = try NativeMandatoryDisplayStroke.rgba(original)
        let maskBefore = try NativeMandatoryDisplayStroke.rgba(proposed)
        #expect(sourceBefore != (try NativeMandatoryDisplayStroke.rgba(stale)))
        // Turn off only boundary calibration so caller-restoration reuse would
        // otherwise be eligible. All main candidate stages retain their defaults.
        let result = try NativeMainEnsemblePipeline.render(original: original, rawItems: [],
            viewport: CGSize(width: width, height: height), rfRegions: [], restored: stale,
            baseRemovalMask: proposed, savedEvidence: ["originalOCR": ["regions": [[String: Any]]()]],
            parameters: ["aotBoundaryBias": ["enabled": 0]])
        try assertPassThrough(result, original: original, proposedNonzero: nonzero)
        #expect(result.image !== stale && result.restored !== stale)
        #expect(try NativeMandatoryDisplayStroke.rgba(original) == sourceBefore)
        #expect(try NativeMandatoryDisplayStroke.rgba(proposed) == maskBefore)
    }

    @Test func defaultMainPipelineIgnoresProposedErasureWithoutRetainedTextOrExplicitEraseMode() throws {
        let original = try image(), proposed = try mask(nonzero: true)
        // Omit both parameters and erasureMode: exercise actual deployed defaults,
        // including enabled AOT boundary calibration, without a caller restoration.
        let result = try NativeMainEnsemblePipeline.render(original: original, rawItems: [],
            viewport: CGSize(width: width, height: height), rfRegions: [], baseRemovalMask: proposed)
        try assertPassThrough(result, original: original, proposedNonzero: true)
    }
}
