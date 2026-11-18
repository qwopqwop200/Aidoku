import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeLocalRFBoundarySupportTests {
    private let side = 256
    private let ownerBounds = [0.375, 0.25, 0.1875, 0.5]

    private func ring(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [CGPoint] {
        [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0),
         CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
    }

    private func region(holes: [[CGPoint]] = [], query: Int = 1) -> Ensemble100RFRegion {
        Ensemble100RFRegion(queryID: query, classID: 2, confidence: 0.95,
            bounds: CGRect(x: 0.125, y: 0.125, width: 0.75, height: 0.75),
            exterior: ring(0.125, 0.125, 0.875, 0.875), holes: holes)
    }

    private func image(gradient: Bool = true, splitColor: Bool = false, texture: Bool = false,
                       openTop: Bool = false, noRim: Bool = false, hole: Bool = false) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                var rgb = gradient ? [60 + x / 2, 50 + y / 2, 180] : [160, 160, 180]
                if splitColor { rgb = x < 128 ? [80, 125, 170] : [175, 80, 115] }
                if texture { rgb = (x + y) % 2 == 0 ? [70, 90, 130] : [205, 180, 210] }
                let vertical = (x == 32 || x == 224) && y >= 32 && y <= 224
                let horizontal = (y == 32 || y == 224) && x >= 32 && x <= 224
                let holeEdge = hole && (((x == 176 || x == 192) && y >= 104 && y <= 152) ||
                    ((y == 104 || y == 152) && x >= 176 && x <= 192))
                if (!noRim && (vertical || horizontal) && !(openTop && y == 32)) || holeEdge {
                    rgb = [8, 12, 16]
                }
                bytes[index] = UInt8(rgb[0]); bytes[index + 1] = UInt8(rgb[1]); bytes[index + 2] = UInt8(rgb[2])
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func apply(_ image: CGImage, regions: [Ensemble100RFRegion]? = nil,
                       enabled: Bool = true, source: [Double]? = nil) throws -> Ensemble100Proposal {
        let page = Ensemble100Page(sourceSHA256: "synthetic-source", original: image,
            restored: image, removalMask: image, viewport: CGSize(width: side, height: side),
            items: [["id": "synthetic-owner", "text": "complete text", "sourceBounds": source ?? ownerBounds]],
            rfRegions: regions ?? [region()], savedEvidence: [:])
        return try EnsembleCandidate03.withLocalRFBoundarySupport(enabled) {
            try EnsembleCandidate03.apply(page, parameters: [:])
        }
    }

    private func decision(_ proposal: Ensemble100Proposal) throws -> [String: Any] {
        try #require((proposal.audit["items"] as? [[String: Any]])?.first)
    }

    @Test func coloredAndGradientEnclosuresUseOnlyEstimatedInwardBody() throws {
        for split in [false, true] {
            let pixels = try image(splitColor: split)
            let disabled = try apply(pixels, enabled: false)
            #expect(try decision(disabled)["status"] as? String == "ambiguous-source-background")
            #expect(disabled.items[0]["balloonInterior"] == nil)
            let enabled = try apply(pixels)
            let audit = try decision(enabled)
            #expect(audit["localBoundaryStatus"] as? String == "supported")
            #expect(audit["localBoundarySamples"] as? Int == audit["localBoundarySupportedSamples"] as? Int)
            let body = try #require(enabled.items[0]["balloonInterior"] as? [String: Any])
            #expect(body["modelEstimated"] as? Bool == true)
            #expect(body["contourVerified"] as? Bool == false)
            #expect(body["nativeMaskSHA256"] == nil)
            let rect = try #require(body["rect"] as? [Double])
            #expect(rect[0] > 0.125 && rect[1] > 0.125)
            #expect(rect[0] + rect[2] < 0.875 && rect[1] + rect[3] < 0.875)
            #expect(enabled.items[0]["text"] as? String == "complete text")
        }
    }

    @Test func smoothGradientWithoutRimAndOpenSideAbstain() throws {
        for pixels in [try image(noRim: true), try image(openTop: true)] {
            let result = try apply(pixels)
            #expect(result.items[0]["balloonInterior"] == nil)
            #expect(try decision(result)["localBoundaryStatus"] as? String == "unsupported-local-edge")
        }
    }

    @Test func highFrequencyTextureCannotSupplyStablePairedPatches() throws {
        let result = try apply(image(texture: true))
        #expect(result.items[0]["balloonInterior"] == nil)
        #expect(try decision(result)["localBoundaryStatus"] as? String == "unsupported-local-edge")
    }

    @Test func ambiguousAndUnassociatedRFAbstainBeforeLocalPixelSupport() throws {
        let pixels = try image()
        let ambiguous = try apply(pixels, regions: [region(), region(query: 2)])
        #expect(ambiguous.items[0]["balloonInterior"] == nil)
        #expect(try decision(ambiguous)["rfAmbiguous"] as? Bool == true)
        #expect(try decision(ambiguous)["localBoundaryStatus"] as? String == "no-unambiguous-owner-polygon")
        let missing = try apply(pixels, regions: [])
        #expect(missing.items[0]["balloonInterior"] == nil)
        let lowConfidence = Ensemble100RFRegion(queryID: 3, classID: 2, confidence: 0.49,
            bounds: region().bounds, exterior: region().exterior, holes: [])
        #expect(try apply(pixels, regions: [lowConfidence]).items[0]["balloonInterior"] == nil)
    }

    @Test func supportedHoleIsExcludedAndUnsupportedHoleAbstains() throws {
        let hole = ring(176.0 / 256, 104.0 / 256, 192.0 / 256, 152.0 / 256)
        let result = try apply(image(hole: true), regions: [region(holes: [hole])])
        let body = try #require(result.items[0]["balloonInterior"] as? [String: Any])
        let rect = try #require(body["rect"] as? [Double])
        let spans = try #require(body["spans"] as? [Double])
        let step = rect[3] / Double(spans.count / 2)
        for row in 0..<(spans.count / 2) {
            let y0 = rect[1] + Double(row) * step, y1 = y0 + step
            if y0 < 152.0 / 256 && y1 > 104.0 / 256 {
                #expect(spans[row * 2 + 1] < 176.0 / 256)
            }
        }
        let unsupported = try apply(image(), regions: [region(holes: [hole])])
        #expect(unsupported.items[0]["balloonInterior"] == nil)
    }

    @Test func ownerAcrossHoleOrTooCloseToRimIsNotSilentlyClipped() throws {
        let hole = ring(0.43, 0.45, 0.50, 0.55)
        let result = try apply(image(), regions: [region(holes: [hole])])
        #expect(result.items[0]["balloonInterior"] == nil)
        let near = try apply(image(), source: [0.13, 0.25, 0.4, 0.5])
        #expect(near.items[0]["balloonInterior"] == nil)
    }

    @Test func existingUniformPaperPathIsIndependentOfOptIn() throws {
        let pixels = try image(gradient: false)
        let off = try apply(pixels, enabled: false), on = try apply(pixels)
        #expect(NSDictionary(dictionary: off.items[0]).isEqual(to: on.items[0]))
        #expect(try decision(on)["localBoundaryStatus"] == nil)
    }

    @Test func existingVerifiedContourIsRetainedWithoutRFOrPixelFallback() throws {
        let pixels = try image()
        let native: [String: Any] = ["contourVerified": true, "rect": [0.2, 0.2, 0.6, 0.6],
                                   "spans": [0.2, 0.8, 0.2, 0.8]]
        let page = Ensemble100Page(sourceSHA256: "synthetic-source", original: pixels,
            restored: pixels, removalMask: pixels, viewport: CGSize(width: side, height: side),
            items: [["id": "synthetic-owner", "text": "complete text", "sourceBounds": ownerBounds,
                     "balloonInterior": native]], rfRegions: [], savedEvidence: [:])
        let result = try EnsembleCandidate03.withLocalRFBoundarySupport(true) {
            try EnsembleCandidate03.apply(page, parameters: [:])
        }
        #expect(try decision(result)["status"] as? String == "existing-native-preserved")
        let retained = try #require(result.items[0]["balloonInterior"] as? [String: Any])
        #expect(NSDictionary(dictionary: retained).isEqual(to: native))
        #expect(result.items[0]["agent03BalloonEvidence"] == nil)
    }

    @Test func scopedOverrideRestoresEnvironmentWithoutMutation() {
        let expected = ProcessInfo.processInfo.environment["AIDOKU_LOCAL_RF_BOUNDARY_SUPPORT"] == "1"
        #expect(EnsembleCandidate03.localRFBoundarySupportEnabled == expected)
        EnsembleCandidate03.withLocalRFBoundarySupport(false) {
            #expect(!EnsembleCandidate03.localRFBoundarySupportEnabled)
            EnsembleCandidate03.withLocalRFBoundarySupport(true) {
                #expect(EnsembleCandidate03.localRFBoundarySupportEnabled)
            }
            #expect(!EnsembleCandidate03.localRFBoundarySupportEnabled)
        }
        #expect(EnsembleCandidate03.localRFBoundarySupportEnabled == expected)
    }
}
