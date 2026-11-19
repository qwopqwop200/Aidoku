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
}
