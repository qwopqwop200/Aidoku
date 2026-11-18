import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSourceEstimatedContourConstraintTests {
    private let viewport = CGSize(width: 100, height: 100)
    private let sourceSHA256 = String(repeating: "a", count: 64)

    private func withSource<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try NativeSupportedEstimatedContour.withSource(sourceSHA256: sourceSHA256, regions: [], operation: operation)
    }

    private func owner() -> [String: Any] {
        var raw: [String: Any] = ["id": "fixture-owner", "text": "complete text", "fontSize": 10,
         "sourceBounds": [0.3, 0.3, 0.2, 0.2],
         "balloonInterior": ["rect": [0.1, 0.1, 0.8, 0.8],
                             "spans": [0.1, 0.9, 0.1, 0.9, 0.1, 0.9, 0.1, 0.9],
                             "modelEstimated": true, "contourVerified": false],
         "agent03BalloonEvidence": ["source": "original-rgb",
                                    "authority": "rf-polygon-original-rgb-boundary-supported"]]
        raw[NativeSupportedEstimatedContour.receiptKey] = NativeSupportedEstimatedContour.receipt(
            raw: raw, sourceSHA256: sourceSHA256,
            regionsSHA256: NativeSupportedEstimatedContour.materialization([]),
            rasterSHA256: String(repeating: "b", count: 64))
        return raw
    }

    @Test func disabledScopeRetainsVerifiedOnlyBehavior() {
        NativeEnsembleLayoutContour.withSupportedEstimatedContour(false) {
            #expect(!NativeEnsembleLayoutContour.supportedEstimatedContourEnabled)
            #expect(NativeEnsembleLayoutContour.estimatedPlacementConstraint(raw: owner(), viewport: viewport) == nil)
            #expect(NativeRawBalloonCapacity.connectedContour(raw: owner(), viewport: viewport) == nil)
            #expect(NativeRawBalloonCapacity.contour(raw: owner(), viewport: viewport) == nil)
            #expect(NativeAOTRawTextPainter.placementDomain(raw: owner(), viewport: viewport, scale: 1) == nil)
        }
    }

    @Test func supportedEstimateConstrainsFinalDomainWithoutNativeCertification() throws {
        try withSource { try NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
            let raw = owner()
            #expect(NativeEnsembleLayoutContour.contour(raw: raw, viewport: viewport) != nil)
            #expect(NativeEnsembleLayoutContour.estimatedPlacementConstraint(raw: raw, viewport: viewport) != nil)
            #expect(NativeRawBalloonCapacity.contour(raw: raw, viewport: viewport) == nil)
            #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) != nil)
            let domain = try #require(NativeAOTRawTextPainter.placementDomain(raw: raw, viewport: viewport, scale: 1))
            #expect(domain(CGRect(x: 35, y: 35, width: 5, height: 5)))
            #expect(!domain(CGRect(x: 2, y: 35, width: 5, height: 5)))
            #expect(NativeAOTRawTextPainter.renderMaskSurface(raw: raw, viewport: viewport, scale: 1) == nil)
        } }
    }

    @Test func unsupportedModelProposalDoesNotBecomePlacementAuthority() {
        withSource { NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
            var raw = owner()
            raw.removeValue(forKey: NativeSupportedEstimatedContour.receiptKey)
            raw.removeValue(forKey: "agent03BalloonEvidence")
            #expect(NativeEnsembleLayoutContour.contour(raw: raw, viewport: viewport) == nil)
            #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) == nil)
            raw["agent03BalloonEvidence"] = ["source": "original-rgb", "authority": "raw-rf-box"]
            #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) == nil)
        } }
    }

    @Test func estimateWithStaleNativeReceiptCannotCertifyMask() {
        withSource { NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
            var raw = owner()
            var body = raw["balloonInterior"] as! [String: Any]
            body["nativeMaskSHA256"] = String(repeating: "a", count: 64)
            raw["balloonInterior"] = body
            #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) == nil)
            #expect(NativeAOTRawTextPainter.renderMaskSurface(raw: raw, viewport: viewport, scale: 1) == nil)
        } }
    }

    @Test func verifiedNativeContourRetainsPriority() throws {
        try NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
            var raw = owner()
            var body = raw["balloonInterior"] as! [String: Any]
            body["contourVerified"] = true
            body["modelEstimated"] = false
            raw["balloonInterior"] = body
            raw.removeValue(forKey: "agent03BalloonEvidence")
            let native = try #require(NativeRawBalloonCapacity.contour(raw: raw, viewport: viewport))
            let connected = try #require(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport))
            #expect(native.rect == connected.rect)
        }
    }

    @Test func unsupportedOwnerAndDisconnectedBandsAreRejected() {
        withSource { NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
            var raw = owner()
            raw["sourceBounds"] = [0.95, 0.95, 0.04, 0.04]
            #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) == nil)
            raw = owner()
            var body = raw["balloonInterior"] as! [String: Any]
            body["spans"] = [0.1, 0.5, 0.5, 0.9, 0.1, 0.5, 0.1, 0.9]
            raw["balloonInterior"] = body
            #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) == nil)
        } }
    }

    @Test func invalidAndUnboundedGeometryAreRejected() {
        withSource { NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
            let raw = owner()
            #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: .zero) == nil)
            var bad = raw
            var body = raw["balloonInterior"] as! [String: Any]
            body["spans"] = [0.1, Double.nan, 0.1, 0.9]
            bad["balloonInterior"] = body
            #expect(NativeRawBalloonCapacity.connectedContour(raw: bad, viewport: viewport) == nil)
            body["spans"] = Array(repeating: [0.1, 0.9], count: 1025).flatMap { $0 }
            bad["balloonInterior"] = body
            #expect(NativeRawBalloonCapacity.connectedContour(raw: bad, viewport: viewport) == nil)
        } }
    }

    @Test func localWindowCannotInventMissingPhysicalContour() {
        NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
            var raw = owner()
            raw.removeValue(forKey: "balloonInterior")
            raw["textExpansionPolicy"] = ["kind": "source-near-limited-expansion",
                                          "allowedRectNormalized": [0.0, 0.0, 1.0, 1.0]]
            #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) == nil)
        }
    }

    @Test func nestedOverrideRestoresOuterAndEnvironmentDefaults() {
        let environmentDefault = ProcessInfo.processInfo.environment["AIDOKU_SUPPORTED_ESTIMATED_CONTOUR"] == "1"
        #expect(NativeEnsembleLayoutContour.supportedEstimatedContourEnabled == environmentDefault)
        withSource { NativeEnsembleLayoutContour.withSupportedEstimatedContour(false) {
            #expect(NativeRawBalloonCapacity.connectedContour(raw: owner(), viewport: viewport) == nil)
            NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
                #expect(NativeRawBalloonCapacity.connectedContour(raw: owner(), viewport: viewport) != nil)
            }
            #expect(NativeRawBalloonCapacity.connectedContour(raw: owner(), viewport: viewport) == nil)
        } }
        #expect(NativeEnsembleLayoutContour.supportedEstimatedContourEnabled == environmentDefault)
    }

    @Test func sourceOwnerMaterializationAndContourChangesInvalidateReceipt() {
        NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
            withSource {
                let raw = owner()
                #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) != nil)
                NativeSupportedEstimatedContour.withSource(sourceSHA256: String(repeating: "c", count: 64), regions: []) {
                    #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) == nil)
                }
                // Even the same source/RF in a later invocation needs fresh RGB evidence.
                withSource {
                    #expect(NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) == nil)
                }
                for key in ["id", "sourceBounds", "balloonInterior", NativeSupportedEstimatedContour.receiptKey] {
                    var changed = raw
                    switch key {
                    case "id": changed[key] = "other-owner"
                    case "sourceBounds": changed[key] = [0.31, 0.3, 0.2, 0.2]
                    case "balloonInterior":
                        var body = raw[key] as! [String: Any]
                        body["spans"] = [0.2, 0.8, 0.1, 0.9, 0.1, 0.9, 0.2, 0.8]
                        changed[key] = body
                    default:
                        var receipt = raw[key] as! [String: Any]
                        receipt["rfMaterializationSHA256"] = String(repeating: "d", count: 64)
                        changed[key] = receipt
                    }
                    #expect(NativeRawBalloonCapacity.connectedContour(raw: changed, viewport: viewport) == nil)
                }
            }
        }
    }

    private func rimImage(open: Bool) -> CGImage {
        let size = 200
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            if abs(hypot(Double(x) + 0.5 - 100, Double(y) + 0.5 - 100) - 70) <= 2,
               !(open && x > 160 && abs(y - 100) < 10) {
                for c in 0..<3 { bytes[(y * size + x) * 4 + c] = 0 }
            }
        } }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func currentClosedRGBRimCertifiesWhileOpenAmbiguousAndHoleBodiesAbstain() throws {
        let ring = (0..<128).map { i -> CGPoint in
            let t = Double(i) * 2 * .pi / 128
            return CGPoint(x: 0.5 + cos(t) * 0.35, y: 0.5 + sin(t) * 0.35)
        }
        let region = Ensemble100RFRegion(queryID: 1, classID: 2, confidence: 0.99,
            bounds: CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7), exterior: ring, holes: [])
        try EnsembleCandidate03.withLocalRFBoundarySupport(true) {
            try NativeEnsembleLayoutContour.withSupportedEstimatedContour(true) {
                for control in ["closed", "open", "ambiguous", "hole"] {
                    let image = rimImage(open: control == "open")
                    let hole = Ensemble100RFRegion(queryID: 1, classID: 2, confidence: 0.99,
                        bounds: region.bounds, exterior: ring,
                        holes: [[CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.25, y: 0.4), CGPoint(x: 0.2, y: 0.5)]])
                    let regions = control == "ambiguous" ? [region, region] : [control == "hole" ? hole : region]
                    let raw: [String: Any] = ["id": "rim-owner", "text": "complete text", "sourceBounds": [0.45, 0.45, 0.1, 0.1]]
                    try NativeSupportedEstimatedContour.withSource(sourceSHA256: sourceSHA256, regions: regions) {
                        let size = CGSize(width: 200, height: 200)
                        let initial = try NativeOperationalRenderExpansion.annotate(items: [raw], viewport: size, source: image, regions: regions)
                        let page = Ensemble100Page(sourceSHA256: sourceSHA256, original: image, restored: image,
                            removalMask: image, viewport: size, items: initial, rfRegions: regions, savedEvidence: [:])
                        let output = try EnsembleCandidate03.apply(page, parameters: [:]).items[0]
                        let contour = NativeRawBalloonCapacity.connectedContour(raw: output, viewport: page.viewport)
                        var user = initial[0]
                        user["id"] = "user-authored"
                        user.removeValue(forKey: "renderExpansionPolicyOrigin")
                        let refreshed = try NativeOperationalRenderExpansion.reannotateGenerated(items: [output, user], viewport: size,
                            source: image, regions: regions)
                        #expect(try JSONSerialization.data(withJSONObject: refreshed[1], options: [.sortedKeys]) ==
                            JSONSerialization.data(withJSONObject: user, options: [.sortedKeys]))
                        try NativeEnsembleLayoutContour.withSupportedEstimatedContour(false) {
                            let disabled = try NativeOperationalRenderExpansion.reannotateGenerated(items: [output, user], viewport: size,
                                source: image, regions: regions)
                            #expect(try JSONSerialization.data(withJSONObject: disabled, options: [.sortedKeys]) ==
                                JSONSerialization.data(withJSONObject: [output, user], options: [.sortedKeys]))
                        }
                        #expect((contour != nil) == (control == "closed"))
                        #expect((output[NativeSupportedEstimatedContour.receiptKey] != nil) == (control == "closed"))
                        #expect(NativeRawBalloonCapacity.contour(raw: output, viewport: page.viewport) == nil)
                        if let contour {
                            let policy = try #require(refreshed[0]["textExpansionPolicy"] as? [String: Any])
                            let body = try #require(output["balloonInterior"] as? [String: Any])
                            #expect(policy["kind"] as? String == "inside-balloon-mask")
                            #expect(policy["maskRectNormalized"] as? [Double] == body["rect"] as? [Double])
                            #expect(policy["maskSpansNormalized"] as? [Double] == body["spans"] as? [Double])
                            #expect(contour.contains(CGRect(x: 95, y: 95, width: 10, height: 10)))
                            #expect(!contour.contains(CGRect(x: contour.rect.minX, y: contour.rect.minY, width: 10, height: 10)))
                        }
                    }
                }
            }
        }
    }
}
