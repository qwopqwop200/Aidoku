import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Runs packaged production heads rather than a saved prediction fixture.
@Suite(.serialized)
struct NativeSourceInferenceActivationTests {
    /// Two 日 glyphs are drawn on a generated page. The geometry describes
    /// that drawing; the RF planes and all downstream model results are live.
    @available(iOS 18.0, *)
    private func makeSourceInput() async throws -> SourceNativeInput {
        let width = 96, height = 128
        var rgb = Data(repeating: 255, count: width * height * 3)
        for top in [24, 68] {
            for y in 0..<32 {
                for x in 0..<26 where x < 3 || x >= 23 || y < 3 || (14..<17).contains(y) || y >= 29 {
                    let offset = ((top + y) * width + 34 + x) * 3
                    rgb[offset] = 16
                    rgb[offset + 1] = 16
                    rgb[offset + 2] = 16
                }
            }
        }
        let source = try NativeRFDETRSourceImage(width: width, height: height, rgb: rgb)
        let detector = NativeRFDETRLayoutDetector(cacheByteLimit: 0, retainAllQueryMasks: true)
        let layout = try await detector.detect(source: source)
        let rf = try NativePixelRFEvidence(result: layout)
        let bounds: [Double] = [34.0 / 96, 24.0 / 128, 26.0 / 96, 76.0 / 128]
        let polygon: [[Double]] = [[34.0 / 96, 24.0 / 128], [60.0 / 96, 24.0 / 128],
                       [60.0 / 96, 100.0 / 128], [34.0 / 96, 100.0 / 128]]
        let item: [String: Any] = ["text": "日日", "sourceOriginalText": "日日",
            "sourceBounds": bounds, "sourcePolygon": polygon, "sourceFontSize": 32, "sourceConfidence": 1.0]
        let row: [String: Any] = ["source": "日日", "sourceBounds": bounds, "polygon": polygon, "confidence": 1.0]
        let owners = try NativeSourceInputFactory.make(source: source, items: [item],
            sourceEvidence: ["originalOCR": ["regions": [row]]], rf: rf, ops: NativeOpenCVAppearanceImageOperations())
        #expect(owners.count == 1)
        return try #require(owners.first?.input)
    }

    @available(iOS 18.0, *)
    @Test func realBoundedSourceRunsSelectedSegmentationAppearanceAndFontTogether() async throws {
        let input = try await makeSourceInput()
        let runtime = try NativeOperationalSourceInference.defaultBackend()
        if runtime.inferencePolicy.usesMinimalM1Style {
            // The rich input cannot enter the minimal runtime ABI.
            // Its actual RGB/RF/member geometry/prior are independently valid
            // minimal observations; no absent rich evidence is manufactured.
            do {
                _ = try runtime.predict([input], returnFontStages: true)
                Issue.record("Minimal policy accepted the rich replay entry")
            } catch NativeOperationalSourceInference.Failure.minimalEntryRequired {}
            let segmentation = try NativeMinimalSourceSegmentation(
                configuration: NativeSourceInferencePolicy.primaryM1Configuration)
            let observed = try segmentation.predict(.init(width: input.width, height: input.height,
                rgb: input.rgb, fullRF: input.rf, coarseRF: input.coarseRF,
                memberPolygons: input.memberPolygons, fontPixels: input.fontPriorSourcePixels,
                rfModelWeightsSHA256: input.rfModelWeightsSHA256))
            let primary = try #require(observed.primary)
            #expect(primary.count == input.width * input.height)
            #expect(observed.mask.contains { $0 != 0 })
            let minimal = NativeMinimalSourceStyleInput(width: input.width, height: input.height,
                rgb: input.rgb, ownMask: observed.mask, primary: primary,
                fontPriorSourcePixels: input.fontPriorSourcePixels, bbox: input.bbox,
                sourceIdentity: input.sourceIdentity, sourceText: input.sourceText,
                memberPolygons: input.memberPolygons)
            let variant = try #require(runtime.inferencePolicy.m1StyleVariant)
            let page = try NativeM1SourcePageInference(variant: variant,
                presenceABI: runtime.inferencePolicy.m1PresenceABI)
            let prediction = try page.predict([minimal])
            #expect(prediction.styles.count == 1 && prediction.weights.count == 1)
            let style = try #require(prediction.styles[0]["nativeSourceInference"] as? [String: Any])
            #expect(style["sourceFeatureCount"] as? Int == 44)
            #expect(style["roleModelCount"] as? Int == 5)
            #expect(style["rich209Executed"] as? Bool == false)
            #expect(prediction.weights[0]["raw597OnlyBridge"] as? Bool == true)
            #expect(prediction.weights[0]["weightModelRoleCount"] as? Int == 1)
            #expect(prediction.audit["BODYPageBatchForwardCalls"] as? Int == 1)
            #expect(prediction.audit["coreModelForwardCalls"] as? Int == 0)
            let fonts = try NativeSourceInferencePolicy.simpleFontConfiguration.estimate([
                .init(bounds: input.bbox, originalCharacterCount: input.sourceText.unicodeScalars.count,
                    memberPolygons: input.memberPolygons)
            ])
            #expect(fonts.count == 1 && fonts[0].isFinite && fonts[0] > 0)
            return
        }
        // Explicit accepted/simple-font rollback policies retain the original
        // actual rich segmentation/appearance/font/BODY assertions unchanged.
        let result = try runtime.predict([input], returnFontStages: true)
        #expect(result.inputs.count == 1 && result.styles.count == 1 && result.font.values.count == 1)
        #expect(result.inputs[0].primary.count == input.width * input.height)
        #expect(result.inputs[0].boundary.count == input.width * input.height)
        #expect(result.inputs[0].ownMask.contains { $0 != 0 })
        #expect(result.font.values.allSatisfy { $0.isFinite && $0 > 0 })
        #expect(runtime.inferencePolicy == NativeSourceInferencePolicy.selected)
        if runtime.inferencePolicy == .accepted {
            // Explicit rollback still exercises the complete original graph.
            #expect(result.font.stages["round198"] == result.font.values)
        } else {
            #expect(runtime.inferencePolicy.usesSingleBodyWeight)
            #expect(result.font.estimatorIdentity == NativeSimpleSourceFont.identity)
            #expect(result.font.stages.isEmpty)
            let weights = try #require(result.weights)
            #expect(weights.count == 1)
            #expect(weights[0]["weightModelRoleCount"] as? Int == 1)
            #expect(weights[0]["acceptedFontHeadUsed"] as? Bool == false)
            #expect(weights[0]["PCAUsed"] as? Bool == false)
            #expect(weights[0]["prototypeBanksUsed"] as? Bool == false)
            let expected = try NativeSourceInferencePolicy.simpleFontConfiguration.estimate([
                .init(bounds: input.bbox, originalCharacterCount: input.sourceText.unicodeScalars.count,
                    memberPolygons: input.memberPolygons)
            ])
            #expect(result.font.values == expected)
        }
        let audit = try #require(result.styles[0]["nativeSourceInference"] as? [String: Any])
        #expect(audit["requiredPhysicalPoliciesExecuted"] as? Bool == true)
    }

    @Test func selectedSharedDefaultUsesMinimal64BodyAndOrientedGeometryWithExplicitRollback() {
        #expect(NativeSourceInferencePolicy.defaultMode == .minimalM1P9Body64Presence95)
        #expect(NativeSourceInferencePolicy.resolveMode(override: nil) == .minimalM1P9Body64Presence95)
        #expect(NativeSourceInferencePolicy.resolveMode(override: "minimal-m1-p9-body64-v1") == .minimalM1P9Body64)
        #expect(NativeSourceInferencePolicy.defaultMode.usesMinimalObservations)
        #expect(!NativeSourceInferencePolicy.defaultMode.usesAcceptedAppearance)
        #expect(NativeSourceInferencePolicy.defaultMode.usesSingleBodyWeight)
        #expect(NativeSourceInferencePolicy.defaultMode.m1StyleVariant == .rounds64)
        #expect(NativeSourceInferencePolicy.resolveMode(override: "simple-font-accepted-style-body-v1") == .simpleFontAcceptedStyleBody)
        #expect(NativeSourceInferencePolicy.resolveMode(override: "accepted") == .accepted)
        #expect(NativeSourceInferencePolicy.resolveMode(override: "invalid") == nil)
        let configuration = NativeSourceInferencePolicy.fontConfiguration(for: NativeSourceInferencePolicy.defaultMode)
        #expect(configuration.calibration.scale == 0.43853239073260936)
        #expect(configuration.calibration.bias == 4.094089327930639)
        #expect(configuration.calibration.bboxShortScale == 0)
        #expect(configuration.calibration.memberShortScale == 0.4140206805546956)
        #expect(configuration.relativeGap == 0.35 && configuration.cluster && !configuration.pageMedian)
        #expect(configuration.consistencyRule?.bodyRatioWeight == 0.8212525806130213)
        #expect(configuration.consistencyRule?.maximumLogDistance == 0.9705176286667344)
        #expect(configuration.cacheProjection["sourceFontGroupingRule"] == NativeSimpleSourceFont.ConsistencyRule.identity)
        let rollback = NativeSourceInferencePolicy.fontConfiguration(for: .simpleFontAcceptedStyleBodyFixedGap)
        #expect(rollback.calibration == configuration.calibration && rollback.relativeGap == configuration.relativeGap)
        #expect(rollback.consistencyRule == nil)
        #expect(rollback.cacheProjection != configuration.cacheProjection)
        #expect(NativeSourceInferencePolicy.resolveMode(override: "simple-font-accepted-style-body-fixed-gap-v1")
            == .simpleFontAcceptedStyleBodyFixedGap)
        #expect(NativeSourceInferencePolicy.Mode.simpleFontAcceptedStyleBody.usesAcceptedAppearance)
        #expect(!NativeSourceInferencePolicy.Mode.simpleFontAcceptedStyleBody.usesAcceptedWeight)
        #expect(NativeSourceInferencePolicy.Mode.simpleFontAcceptedStyleBody.usesSingleBodyWeight)
        #expect(!NativeSourceInferencePolicy.Mode.simpleFontAcceptedStyleBody.usesMinimalObservations)
        #expect(NativeSourceInferencePolicy.erasureConfiguration(for: NativeSourceInferencePolicy.defaultMode)
            == NativeSourceInferencePolicy.primaryM1Configuration)
        #expect(NativeSourceInferencePolicy.erasureConfiguration(for: .simpleFontAcceptedStyleBody)
            == NativeSourceInferencePolicy.primaryM1Configuration)
        #expect(NativeSourceInferencePolicy.erasureConfiguration(for: .simpleFontAcceptedStyleBody, erasurePolicy: .strong)?.policySHA256
            == "7f89e881323675c8c2e6d63cca2454995ee2effe49334e433630684efb0eed46")
        #expect(NativeSourceInferencePolicy.erasureConfiguration(for: .accepted) == nil)
        #expect(NativeSourceInferencePolicy.primaryM1Configuration.policySHA256
            == "3d14f38a5492ba23f3a748d0db59480e4f82007e59f0aa5f24d213084d205aa0")
    }

    @Test func observedPremergePolygonSurvivesNormalizedReaderTransport() throws {
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let members: [[[Double]]] = [[[20, 22], [38, 20], [42, 78], [22, 80]]]
        let row: [String: Any] = ["source": "二二", "confidence": 0.9,
            "rect": ["x": 0.2, "y": 0.2, "width": 0.22, "height": 0.6],
            "polygon": [[0.2, 0.2], [0.42, 0.2], [0.42, 0.8], [0.2, 0.8]],
            "sourceMemberPolygons": members]
        let binding = try NativeMainEnsembleOCREvidence.liveBinding(original: image)
        let stage = try NativeMainEnsembleOCREvidence.project(rows: [row], stage: .finalRegions,
            space: .normalizedTopLeft, binding: binding)
        let packet = try NativeMainEnsembleOCREvidence.Packet(binding: binding, stages: [stage])
        let saved = try packet.savedEvidence(currentOriginalItems: [], removalMaskAvailable: false)
        let original = try #require(saved["originalOCR"] as? [String: Any])
        let rows = try #require(original["regions"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["sourceMemberPolygons"] as? [[[Double]]] == members)
    }

    @available(iOS 18.0, *)
    @Test func readerBackendLoadsCompleteBundledSourceInferenceClosure() throws {
        // Real default retains selected rich segmentation + accepted colour
        // roles + physical glyph metrics/body1, not the full font graph.
        let runtime = try NativeOperationalSourceInference.defaultBackend()
        #expect(runtime.inferencePolicy == NativeSourceInferencePolicy.selected)
    }

    @Test func acceptedFontGraphLoadsPackagedFontsAndExecutesFreshSourcePixels() throws {
        let heads = try NativeAppearanceModelHeads(bundle: Bundle.main)
        let runtime = try NativeAcceptedSourceFontInference(heads: heads)
        let w = 30, h = 82, count = w * h
        var rgb = [UInt8](repeating: 255, count: count * 3)
        var mask = [UInt8](repeating: 0, count: count)
        // Two bounded glyph-like components exercise the actual OpenCV/template
        // measurements, reference exclusions and learned graph without GT input.
        for (x0, y0) in [(3, 9), (3, 49)] {
            for y in y0..<(y0 + 24) {
                for x in x0..<(x0 + 24) where y < y0 + 4 || y >= y0 + 20 || abs(x - x0 - 12) < 2 {
                    let p = y * w + x
                    mask[p] = 1
                    for c in 0..<3 { rgb[p * 3 + c] = 0 }
                }
            }
        }
        let polygon = [CGPoint(x: 3, y: 9), CGPoint(x: 27, y: 9), CGPoint(x: 27, y: 73), CGPoint(x: 3, y: 73)]
        var input = SourceNativeInput(width: w, height: h, rgb: rgb,
            rf: Array(repeating: 0, count: count * 27), coarseRF: Array(repeating: 0, count: count * 4),
            affinityScores: Array(repeating: 0, count: 5),
            rfModelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            memberPolygons: [polygon], mergedPolygon: polygon, bbox: CGRect(x: 3, y: 9, width: 24, height: 64),
            fontPriorSourcePixels: 24, crop: CGRect(x: 0, y: 0, width: w, height: h), pageSize: CGSize(width: w, height: h),
            sourceIdentity: "source-font-activation-synthetic-v1", sourceText: "二二", confidence: 0.9, role: "dialogue")
        input.primary = mask.map(Float.init)
        input.boundary = Array(repeating: 0, count: count)
        input.ownMask = mask; input.contextMask = mask
        input.ocr = Array(repeating: 0, count: count * 8)
        let style: [String: Any] = ["fill": ["rgb": [0, 0, 0]],
            "outline": ["present": false, "rgb": [255, 255, 255], "widthPx": 0],
            "shadow": ["present": false], "background": ["rgb": [255, 255, 255]]]
        let result = try runtime.estimate([input], styles: [style], returnStages: true)
        #expect(result.values.count == 1)
        #expect(result.values.allSatisfy { $0.isFinite && $0 > 0 })
        #expect(result.stages["point56"]?.count == 1)
        #expect(result.stages["round112"]?.count == 1)
        #expect(result.stages["round198"] == result.values)
        #expect(!result.fontFaces.isEmpty)
        NativeAppearanceInferenceGraph.installBuiltInPolicies()
        let appearance = try NativeAppearanceInferenceGraph(heads: heads)
        let prediction = try appearance.predict(input)
        let audit = try #require(prediction["nativeSourceInference"] as? [String: Any])
        #expect(audit["requiredPhysicalPoliciesExecuted"] as? Bool == true)
        #expect(audit["GTAtInference"] as? Bool == false)
        #expect(prediction["fill"] is [String: Any])
        #expect(prediction["outline"] is [String: Any])
        #expect(prediction["shadow"] is [String: Any])
        #expect(prediction["background"] is [String: Any])
    }
}
