import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// No models, provider, saved corpus decisions or runtime environment mutation.
@Suite(.serialized)
struct NativeSimpleRFBalloonPlacementIntegrationTests {
    private struct Fixture {
        let original: CGImage
        let viewport: CGSize
        let raw: [[String: Any]]
        let placement: NativeSimpleRFBalloonPlacement
    }

    private func image(width: Int = 162, height: Int = 162, gray: CGFloat = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func fixture() throws -> Fixture {
        let original = try image(), source = try NativeRFDETRSourceImage.decode(original)
        let viewport = CGSize(width: 162, height: 162)
        var mask = [Float](repeating: -3, count: 162 * 162)
        for y in 40..<120 {
            for x in 10..<65 { mask[y * 162 + x] = 2 }
            for x in 95..<150 { mask[y * 162 + x] = 2 }
        }
        for x in 65..<95 { mask[80 * 162 + x] = 2 } // Generic weak bridge.
        for y in 70..<75 { for x in 30..<35 { mask[y * 162 + x] = -3 } } // Real mask hole.
        var rf = NativeRFDETRLayoutResult(imageIdentity: source.identity, sourceWidth: 162, sourceHeight: 162,
            primitives: [], maskQueriesOmittedByBudget: 0, preprocessingMilliseconds: 0, modelMilliseconds: 0,
            decodeMilliseconds: 0, computeUnits: "synthetic-no-model", fromCache: true)
        rf.classEvidence = (0..<300).map { query in
            let logits: [Float] = [-20, -20, query == 7 ? -2 : -20, -20, -20]
            return NativeRFDETRClassEvidence(queryID: query, logits: logits,
                probabilities: logits.map { 1 / (1 + exp(-$0)) },
                normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                sourceBounds: CGRect(x: 0, y: 0, width: 162, height: 162),
                mask: NativeRFDETRLayoutMask(queryID: query, sourceWidth: 162, sourceHeight: 162, logits: mask))
        }
        func raw(_ id: String, x: Double, y: Double) -> [String: Any] {
            ["id": id, "text": "X", "sourceBounds": [x / 162, y / 162, 8.0 / 162, 10.0 / 162],
             "fontSize": 8.0, "sourceFontSize": 8.0, "sourceFontWeight": "regular", "renderBold": false,
             "renderPreserveRequestedFontSize": true]
        }
        let raws = [raw("left-a", x: 25, y: 50), raw("left-b", x: 40, y: 90), raw("right", x: 110, y: 60)]
        let configuration = NativeSimpleRFBalloonCoreDomain.Configuration(
            raw: NativeRFDETRBalloonDomainPolicy(queryLogit: -2, maskLogit: -1), coreRadius: 3)
        let placement = try NativeSimpleRFBalloonPlacement(original: original, rawRF: rf,
            items: raws, viewport: viewport, configuration: configuration)
        return Fixture(original: original, viewport: viewport, raw: raws, placement: placement)
    }

    @Test func nilPacketKeepsIncumbentDomainAndProtectedOwnerBehavior() throws {
        let f = try fixture(), raw = f.raw[0]
        #expect(NativeAOTRawTextPainter.placementDomain(raw: raw, viewport: f.viewport, scale: 1) == nil)
        let protected = CGRect(x: 25, y: 50, width: 8, height: 10)
        let oldGuard = try #require(NativeAOTRawTextPainter.placementDomain(raw: raw,
            viewport: f.viewport, scale: 1, protected: [protected], simplePlacement: nil))
        #expect(!oldGuard(protected))
        #expect(oldGuard(CGRect(x: 110, y: 60, width: 4, height: 4)))
    }

    @Test func actualPainterDomainRejectsSiblingHoleAndOneULPOutside() throws {
        let f = try fixture()
        let domain = try #require(NativeAOTRawTextPainter.placementDomain(raw: f.raw[0],
            viewport: f.viewport, scale: 1, simplePlacement: f.placement))
        #expect(domain(CGRect(x: 25, y: 50, width: 8, height: 10)))
        #expect(!domain(CGRect(x: 110, y: 60, width: 8, height: 10)))
        #expect(!domain(CGRect(x: 30, y: 70, width: 2, height: 2)))
        #expect(!domain(CGRect(x: CGFloat(10).nextDown, y: 50, width: 8, height: 10)))
        #expect(domain(CGRect(x: 10, y: 50, width: 8, height: 10)))
    }

    @Test func nonunitOutputConversionCannotRoundUnsafeHaloInward() throws {
        let f = try fixture(), scale = CGFloat(165) / 162
        let constraint = try #require(try f.placement.constraint(for: f.raw[0], viewport: f.viewport))
        let unsafe = CGRect(x: (10 * scale).nextDown, y: 50 * scale, width: 8 * scale, height: 10 * scale)
        // The old caller-side conversion loses the outside source pixel here.
        #expect(unsafe.minX / scale == 10)
        #expect(!constraint.contains(outputRect: unsafe, outputScale: scale, viewport: f.viewport))
        let domain = try #require(NativeAOTRawTextPainter.placementDomain(raw: f.raw[0],
            viewport: f.viewport, scale: scale, simplePlacement: f.placement))
        #expect(!domain(unsafe))
        #expect(domain(CGRect(x: 25 * scale, y: 50 * scale, width: 8 * scale, height: 10 * scale)))
        #expect(!domain(CGRect(x: 30 * scale, y: 70 * scale, width: 2 * scale, height: 2 * scale)))
        #expect(!constraint.contains(outputRect: unsafe, outputScale: 0, viewport: f.viewport))
        // Directed nonunit rounding may reject an exact model boundary by an
        // extra source pixel. The normal unit/source coordinate path must not.
        #expect(constraint.contains(outputRect: CGRect(x: 10, y: 50, width: 8, height: 10),
            outputScale: 1, viewport: f.viewport))
    }

    @Test func unknownOwnerIsNotAModelCertificateAndStaleKnownOwnerFailsClosed() throws {
        let f = try fixture()
        var unknown = f.raw[0]; unknown["id"] = "unobserved-owner"
        #expect(try f.placement.constraint(for: unknown, viewport: f.viewport) == nil)
        #expect(NativeAOTRawTextPainter.placementDomain(raw: unknown, viewport: f.viewport,
            scale: 1, simplePlacement: f.placement) == nil)
        let protected = CGRect(x: 25, y: 50, width: 8, height: 10)
        let unknownProtected = try #require(NativeAOTRawTextPainter.placementDomain(raw: unknown,
            viewport: f.viewport, scale: 1, protected: [protected], simplePlacement: f.placement))
        #expect(!unknownProtected(protected))
        var stale = f.raw[0], bounds = stale["sourceBounds"] as! [Double]
        bounds[0] += 1e-14; stale["sourceBounds"] = bounds
        let rejected = try #require(NativeAOTRawTextPainter.placementDomain(raw: stale,
            viewport: f.viewport, scale: 1, simplePlacement: f.placement))
        #expect(!rejected(CGRect(x: 25, y: 50, width: 8, height: 10)))
        #expect(!rejected(CGRect(x: 110, y: 60, width: 8, height: 10)))
        for field in ["keptLettering", "sourceTextOnly"] {
            var sourceOnly = f.raw[0]; sourceOnly[field] = true
            #expect(NativeAOTRawTextPainter.placementDomain(raw: sourceOnly, viewport: f.viewport,
                scale: 1, simplePlacement: f.placement) == nil)
        }
    }

    @Test func twoAxisOutputRoundingCannotRelaxTheVerticalDomain() throws {
        let f = try fixture(), scale = CGSize(width: CGFloat(165) / 162, height: CGFloat(166) / 162)
        let constraint = try #require(try f.placement.constraint(for: f.raw[0], viewport: f.viewport))
        let unsafeTop = CGRect(x: 25 * scale.width, y: (40 * scale.height).nextDown,
            width: 8 * scale.width, height: 10 * scale.height)
        #expect(!constraint.contains(outputRect: unsafeTop, outputScale: scale, viewport: f.viewport))
        let painterDomain = try #require(NativeAOTRawTextPainter.placementDomain(raw: f.raw[0],
            viewport: f.viewport, scale: scale.width, simplePlacement: f.placement, outputScaleY: scale.height))
        #expect(!painterDomain(unsafeTop))
        #expect(painterDomain(CGRect(x: 25 * scale.width, y: 50 * scale.height,
            width: 8 * scale.width, height: 10 * scale.height)))
        #expect(constraint.contains(outputRect: CGRect(x: 25 * scale.width, y: 50 * scale.height,
            width: 8 * scale.width, height: 10 * scale.height), outputScale: scale, viewport: f.viewport))
        #expect(!constraint.contains(outputRect: CGRect(x: 30 * scale.width, y: 70 * scale.height,
            width: 2 * scale.width, height: 2 * scale.height), outputScale: scale, viewport: f.viewport))
        #expect(!constraint.contains(outputRect: unsafeTop, outputScale: CGSize(width: 1, height: 0), viewport: f.viewport))
        #expect(constraint.contains(outputRect: CGRect(x: 10, y: 50, width: 8, height: 10),
            outputScale: CGSize(width: 1, height: 1), viewport: f.viewport))
        #expect(constraint.contains(outputRect: CGRect(x: 25 * scale.width, y: 40,
            width: 8 * scale.width, height: 10), outputScale: CGSize(width: scale.width, height: 1), viewport: f.viewport))
    }

    @Test func modelDomainAddsToRatherThanReplacesExistingNativeAndProtectedGates() throws {
        let f = try fixture()
        var raw = f.raw[0]
        raw["renderPreserveRequestedFontSize"] = false
        raw["originalClosedSurfaceCapacity"] = ["slotNormalized": [20.0 / 162, 45.0 / 162, 20.0 / 162, 30.0 / 162]]
        let domain = try #require(NativeAOTRawTextPainter.placementDomain(raw: raw,
            viewport: f.viewport, scale: 1, simplePlacement: f.placement))
        #expect(domain(CGRect(x: 25, y: 50, width: 5, height: 8)))
        let modelOnly = try #require(try f.placement.constraint(for: raw, viewport: f.viewport))
        let outsideSlot = CGRect(x: 45, y: 50, width: 3, height: 5)
        #expect(modelOnly.contains(viewportRect: outsideSlot, viewport: f.viewport))
        #expect(!domain(outsideSlot))
        let protected = CGRect(x: 25, y: 50, width: 5, height: 8)
        let both = try #require(NativeAOTRawTextPainter.placementDomain(raw: f.raw[0],
            viewport: f.viewport, scale: 1, protected: [protected], simplePlacement: f.placement))
        #expect(!both(protected))
    }

    @Test func explicitFallbackPrimitiveRetainsExactGateWithoutAmbientTaskLocal() throws {
        let f = try fixture(), pixels = try image(width: 4, height: 4, gray: 0)
        func primitive(_ frame: CGRect) -> NativeAOTTranslationPageComposer.TranslatedFillPrimitive {
            var value = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image: pixels, frame: frame, fontOutputPixels: 8)
            value.ownerID = "left-a"; value.hasFinalEffects = true
            // This is the production individualFallback hook, deliberately
            // explicit: the earlier renderCentered TaskLocal has already ended.
            value.placementDomain = NativeAOTRawTextPainter.placementDomain(raw: f.raw[0],
                viewport: f.viewport, scale: 1, simplePlacement: f.placement)
            return value
        }
        let good = primitive(CGRect(x: 25, y: 50, width: 4, height: 4))
        let page = CGRect(origin: .zero, size: f.viewport)
        let admitted = try NativeFinalTextPaintAdmission.place([good], page: page,
            fixedOrigins: ["left-a": good.frame.origin])
        #expect(admitted.fills.count == 1)
        #expect(admitted.audit.first?["domainContained"] as? Bool == true)
        for frame in [CGRect(x: 110, y: 60, width: 4, height: 4), CGRect(x: 30, y: 70, width: 4, height: 4)] {
            let forbidden = primitive(frame)
            #expect(throws: NativeFinalTextPaintAdmission.Failure.self) {
                _ = try NativeFinalTextPaintAdmission.place([forbidden], page: page,
                    fixedOrigins: ["left-a": frame.origin])
            }
        }
        let axes = CGSize(width: CGFloat(165) / 162, height: CGFloat(166) / 162)
        let unsafeFrame = CGRect(x: 25 * axes.width, y: (40 * axes.height).nextDown, width: 4, height: 4)
        var nonSquare = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image: pixels,
            frame: unsafeFrame, fontOutputPixels: 8)
        nonSquare.ownerID = "left-a"; nonSquare.hasFinalEffects = true
        nonSquare.placementDomain = NativeAOTRawTextPainter.placementDomain(raw: f.raw[0],
            viewport: f.viewport, scale: axes.width, simplePlacement: f.placement, outputScaleY: axes.height)
        #expect(throws: NativeFinalTextPaintAdmission.Failure.self) {
            _ = try NativeFinalTextPaintAdmission.place([nonSquare],
                page: CGRect(x: 0, y: 0, width: 165, height: 166),
                fixedOrigins: ["left-a": unsafeFrame.origin])
        }
    }

    @Test func realRenderCenteredScopesTaskLocalAndRestoresNormalOffBehavior() throws {
        let f = try fixture(), raw = f.raw[0]
        let item = NativeAOTRawTextPainter.Item(id: "left-a", text: "X",
            frame: CGRect(x: 18, y: 45, width: 40, height: 20), fontSize: 8, lineHeight: 12,
            chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "source-fixture")
        let before = try NativeAOTRawTextPainter.renderCentered(items: [item], rawItems: [raw],
            viewport: f.viewport, restored: f.original, allowShrink: false)
        let bound = try NativeAOTRawTextPainter.renderCentered(items: [item], rawItems: [raw],
            viewport: f.viewport, restored: f.original, allowShrink: false, simplePlacement: f.placement)
        #expect(before.complete && bound.complete && bound.paintedItems == 1)
        let admission = try #require(bound.audit["finalPaintAdmission"] as? [[String: Any]])
        #expect(admission.count == 1 && admission[0]["domainAvailable"] as? Bool == true)
        #expect(admission[0]["domainContained"] as? Bool == true)
        #expect(NativeAOTRawTextPainter.placementDomain(raw: raw, viewport: f.viewport, scale: 1) == nil)
        let offAgain = try NativeAOTRawTextPainter.renderCentered(items: [item], rawItems: [raw],
            viewport: f.viewport, restored: f.original, allowShrink: false, simplePlacement: nil)
        #expect(try NativeMandatoryDisplayStroke.rgba(before.image) == NativeMandatoryDisplayStroke.rgba(offAgain.image))
        var stale = raw, bounds = raw["sourceBounds"] as! [Double]
        bounds[0] += 1e-14; stale["sourceBounds"] = bounds
        #expect(throws: (any Error).self) {
            _ = try NativeAOTRawTextPainter.renderCentered(items: [item], rawItems: [stale],
                viewport: f.viewport, restored: f.original, allowShrink: false, simplePlacement: f.placement)
        }
        #expect(NativeAOTRawTextPainter.placementDomain(raw: raw, viewport: f.viewport, scale: 1) == nil)
        let nonSquare = try image(width: 165, height: 166)
        let twoAxis = try NativeAOTRawTextPainter.renderCentered(items: [item], rawItems: [raw],
            viewport: f.viewport, restored: nonSquare, allowShrink: false, simplePlacement: f.placement)
        #expect(twoAxis.complete && twoAxis.image.width == 165 && twoAxis.image.height == 166)
        let twoAxisAdmission = try #require(twoAxis.audit["finalPaintAdmission"] as? [[String: Any]])
        #expect(twoAxisAdmission.first?["domainContained"] as? Bool == true)
    }
}
