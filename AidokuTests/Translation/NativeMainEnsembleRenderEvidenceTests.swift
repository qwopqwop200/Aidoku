import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Model-free synthetic carriers through the shared snapshot and real adapters.
/// No model resources, corpus paths, inference or shared evidence-store mutation.
@Suite struct NativeMainEnsembleRenderEvidenceTests {
    private typealias Snapshot = NativeMainEnsembleRenderEvidence
    private typealias OCR = NativeMainEnsembleOCREvidence
    private typealias Probability = NativeMainAOTRemovalMaskBuilder.SourceProbability

    @available(iOS 18.0, *)
    private func image(gray: CGFloat = 0.5) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    @available(iOS 18.0, *)
    private func packet(source: CGImage, stages: [OCR.Stage] = [.finalRegions, .nativeLines]) throws -> OCR.Packet {
        let binding = try OCR.liveBinding(original: source)
        return try OCR.Packet(binding: binding, stages: stages.map {
            try OCR.project(rows: [], stage: $0, space: .normalizedTopLeft, binding: binding)
        })
    }

    @available(iOS 18.0, *)
    private func normalRF(source: CGImage) throws -> NativeRFDETRLayoutResult {
        let identity = try NativeRFDETRSourceImage.decode(source).identity
        let mask = NativeRFDETRLayoutMask(queryID: 1, sourceWidth: 8, sourceHeight: 8,
            logits: [Float](repeating: 1, count: NativeRFDETRLayoutResource.maskSide * NativeRFDETRLayoutResource.maskSide))
        let primitive = NativeRFDETRLayoutPrimitive(queryID: 1, semanticClass: .balloon, confidence: 0.9,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            sourceBounds: CGRect(x: 0, y: 0, width: 8, height: 8), mask: mask)
        return NativeRFDETRLayoutResult(imageIdentity: identity, sourceWidth: 8, sourceHeight: 8,
            primitives: [primitive], maskQueriesOmittedByBudget: 0, preprocessingMilliseconds: 0,
            modelMilliseconds: 0, decodeMilliseconds: 0, computeUnits: "synthetic-no-model", fromCache: false)
    }

    @available(iOS 18.0, *)
    private var fullGeometry: Snapshot.DBGeometry {
        .init(resizedWidth: 4, resizedHeight: 4, region: CGRect(x: 0, y: 0, width: 4, height: 4),
              origin: .authenticatedSavedFullMapLegacyProducerUnproven)
    }

    @available(iOS 18.0, *)
    private func snapshot(source: CGImage, probability: Probability? = nil,
                          geometry: Snapshot.DBGeometry? = nil, ocr: OCR.Packet? = nil,
                          rf: NativeRFDETRLayoutResult? = nil) throws -> Snapshot {
        try Snapshot(original: source, normalRF: rf ?? normalRF(source: source),
            probability: probability ?? Probability(original: source, width: 4, height: 4,
                values: [Float](repeating: 0.25, count: 16)),
            dbGeometry: geometry ?? fullGeometry, ocr: ocr ?? packet(source: source),
            producerContract: "synthetic structural test; no model producer attestation",
            revisionData: nil, unownedMasks: [])
    }

    @available(iOS 18.0, *)
    @Test func observedEmptyBanksAndActualRFMaskRemainAvailable() throws {
        let source = try image()
        let selected = try snapshot(source: source).selection(for: source)
        #expect(selected.ocr.stages[.finalRegions]?.isEmpty == true)
        #expect(selected.ocr.stages[.nativeLines]?.isEmpty == true)
        #expect(selected.ocr.stages[.detector] == nil)
        #expect(selected.probability.original === source)
        let region = try #require(selected.regions.first)
        #expect(!region.exterior.isEmpty)
        let identity = try NativeRFDETRSourceImage.decode(source).identity
        #expect(region.sourcePixelMask?.contains(sourceX: 2, sourceY: 2, sourceIdentity: identity) == true)
        let saved = try selected.ocr.savedEvidence(currentOriginalItems: [], removalMaskAvailable: false)
        let originalOCR = try #require(saved["originalOCR"] as? [String: Any])
        #expect(originalOCR["authority"] as? String == "observed-final-regions")
        #expect((originalOCR["regions"] as? [[String: Any]])?.isEmpty == true)
    }

    @available(iOS 18.0, *)
    @Test func unavailableFinalOrNativeBanksAreNotObservedEmpty() throws {
        let source = try image()
        for stages: [OCR.Stage] in [[], [.finalRegions], [.nativeLines]] {
            let missing = try packet(source: source, stages: stages)
            #expect(throws: Snapshot.Failure.self) {
                _ = try snapshot(source: source, ocr: missing)
            }
        }
    }

    @available(iOS 18.0, *)
    @Test func rejectsMalformedProbabilityShapeAndNonfiniteValues() throws {
        let source = try image()
        for values: [Float] in [[0], [Float](repeating: 0, count: 15)] {
            let malformed = Probability(original: source, width: 4, height: 4, values: values)
            #expect(throws: Snapshot.Failure.self) {
                _ = try snapshot(source: source, probability: malformed)
            }
        }
        for value: Float in [.nan, .infinity, -.infinity, -0.01, 1.01] {
            var values = [Float](repeating: 0.25, count: 16)
            values[0] = value
            let malformed = Probability(original: source, width: 4, height: 4, values: values)
            #expect(throws: Snapshot.Failure.self) {
                _ = try snapshot(source: source, probability: malformed)
            }
        }
    }

    @available(iOS 18.0, *)
    @Test func rejectsPartialPaddedOrUpsizedProbabilityGeometry() throws {
        let source = try image()
        for geometry in [
            Snapshot.DBGeometry(resizedWidth: 4, resizedHeight: 4,
                region: CGRect(x: 1, y: 0, width: 4, height: 4), origin: .controlledLiveFullMap),
            Snapshot.DBGeometry(resizedWidth: 5, resizedHeight: 4,
                region: CGRect(x: 0, y: 0, width: 5, height: 4), origin: .controlledLiveFullMap),
            Snapshot.DBGeometry(resizedWidth: 4, resizedHeight: 4,
                region: CGRect(x: 0, y: 0, width: 3, height: 4), origin: .controlledLiveFullMap)
        ] {
            #expect(throws: Snapshot.Failure.self) {
                _ = try snapshot(source: source, geometry: geometry)
            }
        }
        let upsampled = Probability(original: source, width: 9, height: 9,
            values: [Float](repeating: 0.25, count: 81))
        let geometry = Snapshot.DBGeometry(resizedWidth: 9, resizedHeight: 9,
            region: CGRect(x: 0, y: 0, width: 9, height: 9), origin: .controlledLiveFullMap)
        #expect(throws: Snapshot.Failure.self) {
            _ = try snapshot(source: source, probability: upsampled, geometry: geometry)
        }
    }

    @available(iOS 18.0, *)
    @Test func rejectsDifferentSourceObjectsAndRFOrOCRBindings() throws {
        let source = try image(), equalPixels = try image(), foreignPixels = try image(gray: 0)
        let evidence = try snapshot(source: source)
        #expect(throws: Snapshot.Failure.self) { _ = try evidence.selection(for: equalPixels) }
        #expect(throws: Snapshot.Failure.self) { _ = try evidence.selection(for: foreignPixels) }
        let wrongObject = Probability(original: equalPixels, width: 4, height: 4,
            values: [Float](repeating: 0.25, count: 16))
        #expect(throws: Snapshot.Failure.self) {
            _ = try snapshot(source: source, probability: wrongObject)
        }
        let foreignRF = try normalRF(source: foreignPixels)
        #expect(throws: NativeMainRFRegionAdapter.Failure.self) {
            _ = try snapshot(source: source, rf: foreignRF)
        }
        let foreignOCR = try packet(source: foreignPixels)
        #expect(throws: Snapshot.Failure.self) { _ = try snapshot(source: source, ocr: foreignOCR) }
    }

    @available(iOS 18.0, *)
    @Test func sameSourceSnapshotsKeepTheirOwnProbabilityValues() throws {
        let source = try image()
        var firstValues = [Float](repeating: 0.125, count: 16)
        let first = try snapshot(source: source,
            probability: Probability(original: source, width: 4, height: 4, values: firstValues))
        let second = try snapshot(source: source,
            probability: Probability(original: source, width: 4, height: 4,
                values: [Float](repeating: 0.875, count: 16)))
        firstValues[0] = 0.5
        #expect(try first.selection(for: source).probability.values == [Float](repeating: 0.125, count: 16))
        #expect(try second.selection(for: source).probability.values == [Float](repeating: 0.875, count: 16))
    }

    @available(iOS 18.0, *)
    @Test func explicitNilRevisionEmptyMasksAndUnprovenProducerStayExplicit() throws {
        let source = try image()
        let selected = try snapshot(source: source).selection(for: source)
        #expect(selected.revisionData == nil)
        #expect(selected.unownedMasks.isEmpty)
        let db = try #require(selected.audit["DB"] as? [String: Any])
        #expect(db["currentModelProducerAttested"] as? Bool == false)
        #expect(db["origin"] as? String == Snapshot.DBOrigin.authenticatedSavedFullMapLegacyProducerUnproven.rawValue)
        #expect(selected.audit["globalStoreLookups"] as? Int == 0)
    }
}
