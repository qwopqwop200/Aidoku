import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeRetainedSourceRiskTests {
    private func source() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 17, height: 17, bitsPerComponent: 8,
            bytesPerRow: 68, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 17, height: 17))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 1, height: 1))
        return try #require(context.makeImage())
    }

    private func footprint(_ x: Int, _ y: Int) -> NativeFinalTextPaintAdmission.Footprint {
        .init(runs: [.init(y: y, left: x, right: x + 1)],
            bounds: CGRect(x: x, y: y, width: 1, height: 1), pixels: 1)
    }

    private func evidence(_ image: CGImage, missingMask: Bool = false,
                          identityOverride: String? = nil) throws -> NativeLiveSourceAppearance.RFEvidence {
        let identity = try NativeRFDETRSourceImage.decode(image).identity
        let mask = Ensemble100RFSourcePixelMask(sourceIdentity: identity, queryID: 3,
            sourceWidth: 17, sourceHeight: 17, sample: { _, _ in true })
        let region = Ensemble100RFRegion(queryID: 3, classID: 1, confidence: 0.9,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), exterior: [], holes: [],
            sourcePixelMask: missingMask ? nil : mask)
        return .init(sourceIdentity: identityOverride ?? identity,
            modelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256, regions: [region])
    }

    @Test func contrastUsesActualRGBMedianAndReplicatedBorders() {
        var rgb = [UInt8](repeating: 255, count: 5 * 5 * 3)
        rgb[(2 * 5 + 2) * 3 + 1] = 0 // Colour contrast need not change every channel.
        #expect(NativeSourceContrastSupport.contains(rgb: rgb, width: 5, height: 5, x: 2, y: 2, radius: 1) == true)
        #expect(NativeSourceContrastSupport.contains(rgb: rgb, width: 5, height: 5, x: 0, y: 0, radius: 1) == false)
        #expect(NativeSourceContrastSupport.contains(rgb: rgb, width: 5, height: 5, x: -1, y: 0, radius: 1) == nil)
        #expect(NativeSourceContrastSupport.contains(rgb: [], width: 5, height: 5, x: 0, y: 0, radius: 1) == nil)
        #expect(NativeSourceContrastSupport.contains(rgb: rgb, width: 5, height: 5, x: 0, y: 0, radius: 0) == nil)
    }

    @Test func riskAndPhysicalContextShareExactCanonicalRGBWithoutSharingAuthority() throws {
        let image = try source()
        let canonical = try NativeRFDETRSourceImage.decode(image)
        var observation = NativeRetainedSourceRisk.OriginalObservation(image)
        let wrong = NativeRetainedSourceRisk.make(original: &observation, erased: [UInt8](repeating: 0, count: 289),
            evidence: try evidence(image, identityOverride: "another-source"))
        #expect(wrong.gate?.evaluate(footprint(1, 1), footprint(8, 8)) == nil)
        let first = try observation.pixels(), second = try observation.pixels()
        #expect(first.identity.source == canonical.identity && second.identity.source == canonical.identity)
        #expect(first.rgb == [UInt8](canonical.rgb) && second.rgb == first.rgb)
        let sameStorage = first.rgb.withUnsafeBufferPointer { a in
            second.rgb.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
        #expect(sameStorage)
        observation.finish()
        let restored = try observation.pixels()
        #expect(restored.rgb == first.rgb)
        let reusedAfterFinish = first.rgb.withUnsafeBufferPointer { a in
            restored.rgb.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
        #expect(!reusedAfterFinish)
    }

    @Test func freshRFAndSourceContrastRejectOnlyIncreasedRetainedInkRisk() throws {
        let image = try source()
        let report = NativeRetainedSourceRisk.make(original: image, erased: [UInt8](repeating: 0, count: 289),
            evidence: try evidence(image))
        let gate = try #require(report.gate)
        #expect(gate.evaluate(footprint(1, 1), footprint(8, 8)) == false)
        #expect(gate.evaluate(footprint(8, 8), footprint(1, 1)) == true)
        #expect(gate.evaluate(footprint(8, 8), footprint(8, 8)) == true)
        #expect(gate.evaluate(footprint(1, 1), footprint(16, 16)) == true)
    }

    @Test func actualErasureExemptsOnlyRemovedSourcePixels() throws {
        let image = try source()
        var erased = [UInt8](repeating: 0, count: 289)
        erased[8 * 17 + 8] = 1
        let report = NativeRetainedSourceRisk.make(original: image, erased: erased, evidence: try evidence(image))
        #expect(report.gate?.evaluate(footprint(1, 1), footprint(8, 8)) == true)
    }

    @Test func missingMasksAndWrongSourceNeverBecomeNegativeEvidence() throws {
        let image = try source(), erased = [UInt8](repeating: 0, count: 289)
        let missing = NativeRetainedSourceRisk.make(original: image, erased: erased,
            evidence: try evidence(image, missingMask: true))
        let wrong = NativeRetainedSourceRisk.make(original: image, erased: erased,
            evidence: try evidence(image, identityOverride: "another-source"))
        let missingGate = try #require(missing.gate), wrongGate = try #require(wrong.gate)
        #expect(missingGate.evaluate(footprint(1, 1), footprint(8, 8)) == nil)
        #expect(wrongGate.evaluate(footprint(1, 1), footprint(8, 8)) == nil)
        #expect(NativeRetainedSourceRisk.make(original: image, erased: erased, evidence: nil).gate == nil)
    }

    @Test func riskContextIsScopedAndRestoresAnOuterTransaction() {
        let outer = NativeFinalTextPaintAdmission.RetainedSourceRiskGate { _, _ in true }
        let inner = NativeFinalTextPaintAdmission.RetainedSourceRiskGate { _, _ in false }
        #expect(NativeFinalTextPaintAdmission.retainedSourceRiskGate == nil)
        NativeFinalTextPaintAdmission.$retainedSourceRiskGate.withValue(outer) {
            #expect(NativeFinalTextPaintAdmission.retainedSourceRiskGate === outer)
            NativeFinalTextPaintAdmission.$retainedSourceRiskGate.withValue(inner) {
                #expect(NativeFinalTextPaintAdmission.retainedSourceRiskGate === inner)
            }
            #expect(NativeFinalTextPaintAdmission.retainedSourceRiskGate === outer)
        }
        #expect(NativeFinalTextPaintAdmission.retainedSourceRiskGate == nil)
    }

    @Test func finalGutterPolishPreservesAllIncumbentsWhenRiskVetoesMotion() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage()), page = CGRect(x: 0, y: 0, width: 160, height: 120)
        let policy = NativeTextExpansionPolicy(allowedRectNormalized: [0, 0, 1, 1], candidates: [[0, 0, 1, 1]],
            maskCoverage: [1], backgroundRisk: [0], sourceFontPixels: 10, kind: "source-near-limited-expansion",
            maskRectNormalized: nil, maskSpansNormalized: nil)
        var fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive] = []
        for (index, x, preferred) in [(0, 20, 18), (1, 30, 33)] {
            var fill = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image: image,
                frame: CGRect(x: x, y: 30, width: 8, height: 8), fontOutputPixels: 10)
            fill.ownerID = "peer-\(index)"; fill.hasFinalEffects = true
            fill.textExpansionPolicy = policy
            fill.sourceClusterAlignment = .init(groupID: "cohort", axis: .top, anchorNormalized: 0.25)
            fill.textPlacementGuide = .init(rectNormalized: [Double(preferred)/160, 0.25, 8.0/160, 8.0/120],
                horizontal: .left, vertical: .top)
            fills.append(fill)
        }
        let incumbent = try NativeFinalTextPaintAdmission.place(fills, page: page,
            fixedOrigins: ["peer-0": CGPoint(x: 20, y: 30), "peer-1": CGPoint(x: 30, y: 30)])
        let improved = NativeFinalTextPaintAdmission.refineGutters(incumbent, page: page)
        #expect(improved.fills.map(\.frame) != incumbent.fills.map(\.frame))
        for decision: Bool? in [false, nil] {
            var observations = 0
            let gate = NativeFinalTextPaintAdmission.RetainedSourceRiskGate { old, new in
                observations += 1
                #expect(old.pixels == new.pixels && old.bounds.size == new.bounds.size)
                return decision
            }
            let preserved = NativeFinalTextPaintAdmission.$retainedSourceRiskGate.withValue(gate) {
                NativeFinalTextPaintAdmission.refineGutters(incumbent, page: page)
            }
            #expect(observations > 0)
            #expect(preserved.fills.count == incumbent.fills.count)
            #expect(preserved.fills.map(\.frame) == incumbent.fills.map(\.frame))
        }
    }
}
