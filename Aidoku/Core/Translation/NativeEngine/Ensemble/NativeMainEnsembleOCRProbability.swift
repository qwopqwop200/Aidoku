import CoreGraphics
import Foundation

/// Per-invocation handoff of ALREADY materialized DB probabilities. No OCR, inference, resizing,
/// frame-to-image conversion, source hashing, mask construction, or global mutable observer.
/// promptVersion: technical-review-v1 + main-integration-v1.
enum NativeMainEnsembleOCRProbability {
    /// The existing detector's source-only map, not its padded model canvas or ROI upper bounds.
    /// region is in resized-source PIXELS; normalizedSourceBounds below describes the input image.
    struct Sample: Sendable {
        let sourceWidth: Int
        let sourceHeight: Int
        let resizedWidth: Int
        let resizedHeight: Int
        let region: CGRect
        let width: Int
        let height: Int
        let values: [Float]
        // Populated only by an actual producer hook or authenticated replay.
        // All existing callers default to nil and remain registered-but-unproven.
        var producer: NativeMainEnsembleDBCapability.Producer? = nil
        var detectorInputIdentity: String? = nil
        var consumerConfigurationSHA256: String? = nil
    }

    enum Status: String, Sendable {
        case registered
        case unboundOriginal = "unbound-original-CGImage"
        case cropTileOrUnknownSource = "crop-tile-or-unknown-input-source-bounds"
        case sourceGeometryMismatch = "source-geometry-mismatch-or-budget"
        case invalidMapGeometry = "invalid-map-geometry-or-budget"
        case partialOrPaddedMap = "partial-tile-or-padded-map"
        case upsampledMapUnsupported = "upsampled-map-not-supported-by-mask-contract"
        case valueCountMismatch = "map-value-count-mismatch"
        case invalidProbability = "nonfinite-or-out-of-range-probability"
        case cancelled
        case registrationFailed = "evidence-store-registration-failed"
    }

    struct Report: Sendable {
        let status: Status
        let width: Int
        let height: Int
        var detail: String? = nil
        var currentProducerVerified: Bool = false
        var registered: Bool { status == .registered }
        var audit: [String: Any] {
            ["status": status.rawValue, "width": width, "height": height,
             "detail": detail as Any? ?? NSNull(), "newModelCalls": 0,
             "sourceIdentityAuthority": "original-CGImage; canonical RGB hash delegated to evidence store",
             "valuesClampedOrSynthesized": false, "maskChanged": false,
             "currentProducerVerified": currentProducerVerified,
             "producerStatus": currentProducerVerified ? "actual-typed-producer" : "legacy-unproven-not-current"]
        }
    }

    typealias Observer = @Sendable (Sample) -> Report
    typealias Register = @Sendable (NativeMainAOTRemovalMaskBuilder.SourceProbability) throws -> Void

    /// A retained immutable CG object, NOT a DeviceRGB frame identity or a fabricated sRGB image.
    private struct Binding: @unchecked Sendable {
        let original: CGImage?
        let normalizedSourceBounds: CGRect?
        let canonicalIdentity: String?
    }

    /// Bind at the original-CGImage input boundary, before its existing RGBA conversion.
    /// normalizedSourceBounds MUST be explicitly unit for a full original input. Crops/tiles must
    /// supply their actual source extent; frame-only callers without the original object pass nil.
    /// Do not reconstruct a CGImage from NativeOCRRGBAFrame or borrow another same-sized page.
    /// An invalid or unavailable handoff returns a report; it never aborts otherwise valid OCR.
    static func observer(
        original: CGImage?,
        normalizedSourceBounds: CGRect?,
        register: @escaping Register = { try NativeMainEnsembleEvidenceStore.shared.register(probability: $0) }
    ) -> Observer {
        let binding = Binding(original: original, normalizedSourceBounds: normalizedSourceBounds, canonicalIdentity: nil)
        return { sample in receive(sample, binding: binding, register: register) }
    }

    static func fullPageObserver(original: CGImage, store: NativeMainEnsembleEvidenceStore = .shared) -> Observer {
        if let source = NativeMainEnsemblePreparedDB.SourceBinding(preparedOCROriginal: original) {
            return observer(source: source) { try store.register(probability: $0, source: source) }
        }
        return observer(original: original, normalizedSourceBounds: CGRect(x: 0, y: 0, width: 1, height: 1)) {
            try store.register(probability: $0)
        }
    }

    /// The caller already computed this digest from the bound full-page CGImage.
    static func observer(source: NativeMainEnsemblePreparedDB.SourceBinding, register: @escaping Register) -> Observer {
        let binding = Binding(original: source.original, normalizedSourceBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                              canonicalIdentity: source.identity)
        return { sample in receive(sample, binding: binding, register: register) }
    }

    private static func receive(_ sample: Sample, binding: Binding, register: Register) -> Report {
        func report(_ status: Status, _ detail: String? = nil) -> Report {
            .init(status: status, width: sample.width, height: sample.height, detail: detail)
        }
        guard !Task.isCancelled else { return report(.cancelled) }
        guard let original = binding.original else { return report(.unboundOriginal) }
        guard let bounds = binding.normalizedSourceBounds,
              bounds == CGRect(x: 0, y: 0, width: 1, height: 1) else {
            return report(.cropTileOrUnknownSource)
        }
        guard sample.sourceWidth == original.width, sample.sourceHeight == original.height,
              sample.sourceWidth > 0, sample.sourceHeight > 0,
              sample.sourceWidth <= 16_384, sample.sourceHeight <= 16_384,
              sample.sourceWidth <= 16_777_216 / sample.sourceHeight else {
            return report(.sourceGeometryMismatch)
        }
        // Native detector's current modelMaximumSide is 2000. Bound the retained Float payload
        // without allocating/copying a map. The evidence store separately bounds source residency.
        guard sample.width > 0, sample.height > 0,
              sample.resizedWidth > 0, sample.resizedHeight > 0,
              sample.width <= 2_000, sample.height <= 2_000,
              sample.resizedWidth <= 2_000, sample.resizedHeight <= 2_000 else {
            return report(.invalidMapGeometry)
        }
        guard sample.region == CGRect(x: 0, y: 0, width: sample.resizedWidth, height: sample.resizedHeight),
              sample.width == sample.resizedWidth, sample.height == sample.resizedHeight else {
            return report(.partialOrPaddedMap)
        }
        // This is a downstream SourceProbability restriction. Never crop or resample to bypass it.
        guard sample.width <= original.width, sample.height <= original.height else {
            return report(.upsampledMapUnsupported)
        }
        guard sample.values.count == sample.width * sample.height else { return report(.valueCountMismatch) }
        for index in sample.values.indices {
            if index & 4095 == 0 && Task.isCancelled { return report(.cancelled) }
            let value = sample.values[index]
            guard value.isFinite, value >= 0, value <= 1 else {
                return report(.invalidProbability, "invalid cell at row-major index \(index)")
            }
        }
        guard !Task.isCancelled else { return report(.cancelled) }
        do {
            // Array storage is shared copy-on-write; preserve each Float bit and original CG object.
            var capability: NativeMainEnsembleDBCapability.Record?
            if let producer=sample.producer,let input=sample.detectorInputIdentity {
                let identity = try binding.canonicalIdentity ?? NativeRFDETRSourceImage.decode(original).identity
                let source=NativeMainEnsembleDBCapability.Source(canonicalIdentity:identity,
                    detectorInputIdentity:input,width:original.width,height:original.height)
                let grid=NativeMainEnsembleDBCapability.Grid(sourceWidth:sample.sourceWidth,
                    sourceHeight:sample.sourceHeight,resizedWidth:sample.resizedWidth,
                    resizedHeight:sample.resizedHeight,regionX:Int(sample.region.minX),
                    regionY:Int(sample.region.minY),regionWidth:Int(sample.region.width),
                    regionHeight:Int(sample.region.height),width:sample.width,height:sample.height,values:sample.values)
                let record=NativeMainEnsembleDBCapability.Record(source:source,producer:producer,grid:grid,
                    mapSHA256:NativeMainEnsembleDBCapability.digest(sample.values),origin:.live,
                    consumerConfigurationSHA256:sample.consumerConfigurationSHA256)
                try NativeMainEnsembleDBCapability.validate(record,expected:.init(source:source,producer:producer))
                capability=record
            }
            try register(.init(original: original, width: sample.width, height: sample.height,
                values: sample.values,capability:capability))
            return .init(status:.registered,width:sample.width,height:sample.height,
                currentProducerVerified:capability != nil)
        } catch is CancellationError {
            return report(.cancelled)
        } catch {
            return report(.registrationFailed, String(reflecting: error))
        }
    }
}
