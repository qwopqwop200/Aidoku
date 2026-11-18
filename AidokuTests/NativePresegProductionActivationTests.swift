import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

private final class NativePresegProductionFixtureBundle: NSObject {}

/// Explicit affected suite: bounded signal fixtures and one 64px synthetic
/// detector call. No provider, network, dataset lookup or visual review.
@Suite(.serialized)
struct NativePresegProductionActivationTests {
    @available(iOS 18.0, *)
    private typealias G = NativeOCRIndividualGeometryHypotheses

    @available(iOS 18.0, *)
    private struct Signals: Decodable {
        let generatorFeatures: [[Double]]
        let generatorResiduals: [[Double]]
        let preFeatures: [[Double?]]
        let preKept: [Int]
        let dedupOutput: G.Output
        let dedupFeatures: [[Double?]]
        let dedupRecognition: [Double]
        let dedupKept: [Int]
    }

    @available(iOS 18.0, *)
    private func signals() throws -> Signals {
        let bundle = Bundle(for: NativePresegProductionFixtureBundle.self)
        let url = try #require(bundle.url(forResource: "NativePresegProductionSignals", withExtension: "json"))
        return try JSONDecoder().decode(Signals.self, from: Data(contentsOf: url))
    }

    @available(iOS 18.0, *)
    private func quad(x: Double, y: Double = 2, width: Double = 12, height: Double = 12) -> [G.Point] {
        [.init(x: x, y: y), .init(x: x + width, y: y),
         .init(x: x + width, y: y + height), .init(x: x, y: y + height)]
    }

    @available(iOS 18.0, *)
    private func bank(_ polygons: [[G.Point]]) -> G.Output {
        let records = polygons.enumerated().map { index, polygon in
            G.Record(requestID: "fresh-source-operation", sourceIndex: index, sourceParent: index,
                sourceMembers: [], alternativeID: "observed-quad", origin: .corrected,
                originalDetectorIndex: nil, polygon: polygon)
        }
        return G.emit(requestID: "fresh-source-operation", corrected: records,
            originals: [], layout: [], refinements: [], mode: .correctedOnly)
    }

    @available(iOS 18.0, *)
    @Test func packagedRawHeadsAndPreRECPolicyReproduceRecordedSourceSignals() throws {
        // Production loader, app bundle, strict schemas and original model
        // bytes. Resource absence or partial auxiliary loading must fail here.
        let models = try #require(try NativeOCRRawGeometryModelBundle.load(
            bundle: .main, request: .primaryGateAndAuxiliary))
        let auxiliary = try #require(models.auxiliary)
        let fixture = try signals()
        #expect(models.primary.featureNames == NativeOCRRawCanonicalGeometry.featureNames)
        #expect(auxiliary.featureNames == models.primary.featureNames)
        #expect(models.preRecognition.stage == .beforeRecognition)
        #expect(models.preRecognition.featureNames == NativeOCRPreRecognitionFeatures.featureNames)

        // Measured, label-free numeric traces exercise the actual packaged
        // primary heads; expected residuals were frozen independently.
        for (features, expected) in zip(fixture.generatorFeatures, fixture.generatorResiduals) {
            let actual = try #require(models.primary.residual(features: features))
            #expect(actual.count == expected.count)
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 1e-11 })
            let aux = try #require(auxiliary.residual(features: features))
            let reference = try #require(models.auxiliaryReference.residual(features: features))
            #expect(aux.count == 8 && aux.allSatisfy { $0.isFinite })
            #expect(reference.count == 8 && reference.allSatisfy { $0.isFinite })
        }
        #expect(models.gate.keep(rawFeatures: [Float](repeating: .nan, count: 155)))

        let input = G.admitting(bank(fixture.preFeatures.indices.map { quad(x: Double($0) * 20) }),
            bboxScores: [Double](repeating: 0.9, count: fixture.preFeatures.count), threshold: 0.085)
        let admitted = try NativeOCRPreRecognitionFilter.apply(input,
            features: fixture.preFeatures.map { $0.map { $0 ?? .nan } }, model: models.preRecognition)
        #expect(admitted.report.keptIndices == fixture.preKept)
        #expect(!fixture.preKept.isEmpty && fixture.preKept.count < fixture.preFeatures.count)
        #expect(admitted.report.recognizerCalls == 0)
        #expect(admitted.output.individuals == fixture.preKept.map { input.individuals[$0] })
    }

    @available(iOS 18.0, *)
    @Test func correctedDetectorGateAndReaderConfidenceAreIndependent() throws {
        let side = 64
        let levels: [Float] = [0.084, 0.085, 0.9]
        var probabilities = [Float](repeating: 0, count: side * side)
        for (index, value) in levels.enumerated() {
            for y in 0..<side {
                for x in (index * 20)..<(index * 20 + 18) { probabilities[y * side + x] = value }
            }
        }
        let sample = NativeMainEnsembleOCRProbability.Sample(sourceWidth: side, sourceHeight: side,
            resizedWidth: side, resizedHeight: side, region: CGRect(x: 0, y: 0, width: side, height: side),
            width: side, height: side, values: probabilities)
        let input = bank((0..<3).map { quad(x: Double($0 * 20 + 2)) })
        let admitted = try NativeOCRBBoxConfidenceAdmission.apply(input, probability: sample,
            sourceWidth: side, sourceHeight: side, enabled: true)
        #expect(admitted.report.applied)
        #expect(admitted.report.threshold == 0.085)
        #expect(admitted.output.individuals.map { $0.provenance[0].sourceIndex } == [1, 2])
        #expect(ReaderOCRConfiguration(modelTier: .manga).confidenceThreshold == 0.30)
        #expect(ReaderOCRConfiguration(modelTier: .manga, confidenceThreshold: 0.42).confidenceThreshold == 0.42)
    }

    @available(iOS 18.0, *)
    @Test func approvedNativeDedupRetainsDirectWitnessAndOriginalGeometry() throws {
        let fixture = try signals()
        let source166 = fixture.dedupFeatures.map { $0.map { $0 ?? .nan } }
        let result = try NativeOCRPostRecognitionDeduplication.apply(fixture.dedupOutput, source166: source166)
        #expect(result.report.keptIndices == fixture.dedupKept)
        #expect(!result.report.replacements.isEmpty)
        #expect(result.report.polygonIoUThreshold == 0.85)
        #expect(result.report.replacements.allSatisfy { result.report.keptIndices.contains($0.retainedIndex) })
        #expect(result.output.individuals == fixture.dedupKept.map { fixture.dedupOutput.individuals[$0] })

        // Lost RF confidence is not evidence for deleting this source. The
        // retained geometry and source records must survive an abstention.
        let unavailable = source166.map { row in var row = row; row[8] = .nan; return row }
        let abstained = try NativeOCRPostRecognitionDeduplication.apply(fixture.dedupOutput, source166: unavailable)
        #expect(abstained.output.individuals == fixture.dedupOutput.individuals)
    }

    @available(iOS 18.0, *)
    @Test(arguments: ["source-identity", "model-weights", "source-size", "support-fields"])
    func defaultMangaPipelineRejectsUnboundRaw165EvidenceBeforeDetection(kind: String) async throws {
        let side = 64
        let bytes = Data(repeating: 255, count: side * side * 4)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let cells = 162 * 162
        let actualIdentity = try NativeRFDETRSourceImage.decode(image).identity
        let evidenceIdentity = kind == "source-identity" ? "synthetic-source" : actualIdentity
        let weights = kind == "model-weights" ? String(repeating: "0", count: 64)
            : NativeRFDETRLayoutResource.highresSourceWeightsSHA256
        var support = [Float](repeating: 0, count: 17 * cells)
        if kind == "support-fields" { support[0] = .nan }
        let grid = NativeRFDETRSemanticGrid(width: side, height: side, side: 162,
            probabilities: [Float](repeating: 0, count: 4 * cells),
            modelWeightsSHA256: weights,
            imageIdentity: evidenceIdentity, weightedMeanProbabilities: [Float](repeating: 0, count: 4 * cells))
        let unbound = NativeRFDETRLayoutResult(imageIdentity: evidenceIdentity,
            sourceWidth: kind == "source-size" ? side + 1 : side, sourceHeight: side,
            primitives: [], maskQueriesOmittedByBudget: 0, preprocessingMilliseconds: 0, modelMilliseconds: 0,
            decodeMilliseconds: 0, computeUnits: "synthetic", fromCache: false, semanticGrid: grid,
            sourceSupportGrid: .init(native17Fields: support))
        // Use the real production convenience initializer, not injected model
        // state. Current source/highres weight constants intentionally alias;
        // foreign source identity, wrong weights/size or invalid native17 fields
        // must fail before DET can emit an unrelated small-source map error.
        let pipeline = NativeCoreMLOCRPipeline(modelTier: .manga,
            detectorMaximumSide: side, recognizerMaximumWidth: side, bundle: .main)
        do {
            _ = try await pipeline.recognize(image: image, requestID: "fresh-default-manga-operation",
                confidenceThreshold: ReaderOCRConfiguration(modelTier: .manga).confidenceThreshold, rfLayout: unbound)
            Issue.record("Default Manga pipeline admitted unbound raw canonical RF evidence: \(kind)")
        } catch NativeOCRRawCanonicalRuntime.Failure.missingEvidence {
            // Correct: this evidence cannot supply THIS source's source165 ABI.
        } catch {
            await pipeline.purgeResources()
            throw error
        }
        await pipeline.purgeResources()
    }
}
