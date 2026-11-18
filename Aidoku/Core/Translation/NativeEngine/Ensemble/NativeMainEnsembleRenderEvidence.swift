import CoreGraphics
import Foundation

/// Explicit immutable, per-render source evidence. Complete required render
/// slots do not imply all OCR stages were observed; preserve actual availability.
/// No registry, token, lock,
/// model execution, source catalog or lookup fallback is owned by this value.
/// A producer contract is audit context, NOT model-weight attestation.
struct NativeMainEnsembleRenderEvidence {
    enum Failure: Error {
        case sourceBinding, missingOCRStage, invalidDBGeometry, invalidDBValues
        case invalidProducerContract, invalidRevision, resourceBudget
    }
    enum DBOrigin: String {
        case controlledLiveFullMap
        case authenticatedSavedFullMapLegacyProducerUnproven
    }
    struct DBGeometry {
        let resizedWidth: Int
        let resizedHeight: Int
        let region: CGRect // Resized-source pixels, not padded model canvas.
        let origin: DBOrigin
    }
    struct Selection {
        let regions: [Ensemble100RFRegion]
        let probability: NativeMainAOTRemovalMaskBuilder.SourceProbability
        let ocr: NativeMainEnsembleOCREvidence.Packet
        let revisionData: Data?
        let unownedMasks: [NativeCausalUnownedInkLiveRecovery.AffiliatedMask]
        let audit: [String: Any]
    }

    private let original: CGImage
    private let canonicalIdentity: String
    private let normalRF: NativeRFDETRLayoutResult
    private let regions: [Ensemble100RFRegion]
    private let probability: NativeMainAOTRemovalMaskBuilder.SourceProbability
    private let dbGeometry: DBGeometry
    private let ocr: NativeMainEnsembleOCREvidence.Packet
    private let producerContract: String
    private let currentDBProducerAttested: Bool
    private let revisionData: Data?
    // Byte-freeze Any-valued affiliation audits rather than retaining mutable
    // caller dictionaries. The native parser validates exact runs on selection.
    private let unownedPayload: Data?

    /// Renderer-only factory keeps raw model masks private. No alternate RF
    /// region list is passed into source inference, grouping or erasure.
    func makeSimplePlacement(items: [[String: Any]], viewport: CGSize) throws -> NativeSimpleRFBalloonPlacement? {
        try NativeSimpleRFBalloonPlacement.prepareIfRequested(original: original,
            rawRF: normalRF, items: items, viewport: viewport)
    }

    init(original: CGImage, normalRF: NativeRFDETRLayoutResult,
         probability: NativeMainAOTRemovalMaskBuilder.SourceProbability,
         dbGeometry: DBGeometry, ocr: NativeMainEnsembleOCREvidence.Packet,
         producerContract: String, revisionData: Data? = nil,
         unownedMasks: [NativeCausalUnownedInkLiveRecovery.AffiliatedMask] = [],
         validatedDB: NativeMainEnsemblePreparedDB? = nil) throws {
        guard !producerContract.isEmpty, producerContract.utf8.count <= 1024 else {
            throw Failure.invalidProducerContract
        }
        let source = try NativeRFDETRSourceImage.decode(original)
        let identity = source.identity
        guard probability.original === original,
              ocr.binding.contentIdentity == identity,
              ocr.binding.width == source.width, ocr.binding.height == source.height else {
            throw Failure.sourceBinding
        }
        // Present [] is observed-empty, distinct from an unavailable stage.
        guard ocr.stages[.finalRegions] != nil, ocr.stages[.nativeLines] != nil else {
            throw Failure.missingOCRStage
        }
        guard probability.width > 0, probability.height > 0,
              probability.width <= 2000, probability.height <= 2000,
              probability.width <= source.width, probability.height <= source.height,
              dbGeometry.resizedWidth == probability.width,
              dbGeometry.resizedHeight == probability.height,
              dbGeometry.region == CGRect(x: 0, y: 0, width: probability.width, height: probability.height) else {
            throw Failure.invalidDBGeometry
        }
        guard probability.values.count == probability.width * probability.height,
              probability.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw Failure.invalidDBValues
        }
        if let validatedDB {
            // Only the existing sealed current ensure can attest a producer.
            // Merely attaching an arbitrary capability record is insufficient.
            try validatedDB.validate(original: original)
            let sealed = validatedDB.probability
            guard probability.original === sealed.original,
                  probability.width == sealed.width, probability.height == sealed.height,
                  probability.capability?.source == validatedDB.expected.source,
                  probability.capability?.producer == validatedDB.expected.producer,
                  probability.capability?.mapSHA256 == sealed.capability?.mapSHA256,
                  NativeMainEnsembleDBCapability.digest(probability.values) == sealed.capability?.mapSHA256 else {
                throw Failure.invalidDBValues
            }
        }
        // Bound retained RF/DB bytes. Adapter consumes the actual typed RF mask
        // result, not bbox logs or fabricated segmentation polygons.
        guard normalRF.evidenceStorageBytes <= 64 * 1024 * 1024,
              ocr.retainedBytes <= NativeMainEnsembleOCREvidence.maximumPageBytes else {
            throw Failure.resourceBudget
        }
        let regions = try NativeMainRFRegionAdapter.regions(from: normalRF, source: source)
        if let revisionData {
            guard revisionData.count <= 2 * 1024 * 1024,
                  (try JSONSerialization.jsonObject(with: revisionData)) is [String: Any] else {
                throw Failure.invalidRevision
            }
            // Renderer performs source/member/display validation with the
            // existing NativeMainSourceRevision validator before using it.
        }
        let unownedPayload: Data?
        if unownedMasks.isEmpty {
            unownedPayload = nil
        } else {
            let payload = try NativeCausalUnownedInkLiveRecovery.maskPayload(unownedMasks, original: original)
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard bytes.count <= 4 * 1024 * 1024 else { throw Failure.resourceBudget }
            _ = try NativeCausalUnownedInkLiveRecovery.masksFromPayload(
                JSONSerialization.jsonObject(with: bytes), original: original)
            unownedPayload = bytes
        }
        self.original = original
        canonicalIdentity = identity
        self.normalRF = normalRF
        self.regions = regions
        self.probability = probability
        self.dbGeometry = dbGeometry
        self.ocr = ocr
        self.producerContract = producerContract
        currentDBProducerAttested = validatedDB != nil
        self.revisionData = revisionData
        self.unownedPayload = unownedPayload
    }

    /// Select all slots from this one value exactly once per renderer call.
    /// Equivalent pixels in a different CGImage cannot replace DB.original.
    func selection(for source: CGImage) throws -> Selection {
        guard source === original, probability.original === source,
              (try NativeRFDETRSourceImage.decode(source)).identity == canonicalIdentity else {
            throw Failure.sourceBinding
        }
        let masks = try unownedPayload.map {
            try NativeCausalUnownedInkLiveRecovery.masksFromPayload(
                JSONSerialization.jsonObject(with: $0), original: source)
        } ?? []
        let audit: [String: Any] = [
            "path": "explicit-immutable-complete-snapshot-v1", "allRequiredSlotsAvailable": true,
            "sourceIdentityDomain": "canonical-rgb8", "sourceIdentity": canonicalIdentity,
            "sourceWidth": source.width, "sourceHeight": source.height,
            "strongOriginalDBObjectPreserved": true, "globalStoreLookups": 0,
            "RF": ["available": true, "primitiveCount": normalRF.primitives.count,
                   "adaptedRegionCount": regions.count, "sourceIdentity": normalRF.imageIdentity,
                   "authority": "actual typed normal RF result; model provenance belongs to controlled producer contract"],
            "DB": ["available": true, "origin": dbGeometry.origin.rawValue,
                   "mapWidth": probability.width, "mapHeight": probability.height,
                   "fullUnpaddedSourceGridValidated": true, "finiteUnitValuesValidated": true,
                   "currentModelProducerAttested": currentDBProducerAttested,
                   "authority": currentDBProducerAttested ? "existing sealed current DB ensure; source/grid/map checked" :
                    "source/geometry/value binding only; no typed current-model producer proof claimed"],
            "OCR": ["available": true, "stageAvailability": Dictionary(uniqueKeysWithValues:
                NativeMainEnsembleOCREvidence.Stage.allCases.map {
                    ($0.rawValue, ocr.stages[$0].map { "observed:\($0.count)" } ?? "unavailable")
                }), "observedStageCount": ocr.stages.count,
                "hasAllFiveObserved": [.finalRegions, .nativeLines, .detector, .recognized, .rejected]
                    .allSatisfy { ocr.stages[$0] != nil },
                "retainedBytes": ocr.retainedBytes],
            "producerContract": producerContract,
            "revisionAvailable": revisionData != nil, "unownedMaskCount": masks.count,
            "modelCalls": 0, "GTAtRuntime": false]
        return .init(regions: regions, probability: probability, ocr: ocr,
                     revisionData: revisionData, unownedMasks: masks, audit: audit)
    }
}
