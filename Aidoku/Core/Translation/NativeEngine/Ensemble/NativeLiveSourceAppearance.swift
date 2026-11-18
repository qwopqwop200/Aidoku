import CoreGraphics
import Foundation

/// Reader and host share the exact pre-shaping boundary. Backends install only
/// executable source inference, never a map of stored page/style predictions.
final class NativeLiveSourceAppearance: @unchecked Sendable {
    enum Failure:Error {case unsupportedNativeRuntime, sourceRFMismatch}
    static let shared = NativeLiveSourceAppearance()
    struct RFEvidence {
        let sourceIdentity: String
        let modelWeightsSHA256: String
        let regions: [Ensemble100RFRegion]
    }
    struct Output {
        let items: [[String: Any]]
        var sourceSegmentationMasks: NativeSelectedSourceSegmentationMasks? = nil
        var sourceRF: RFEvidence? = nil

        /// Fresh source-constructor RF belongs to this render transaction. Do
        /// not reread an older global RF entry after executable style inference.
        func resolvedRegions(original: CGImage, fallback: [Ensemble100RFRegion],
                             useFreshSourceRF: Bool = true) throws -> [Ensemble100RFRegion] {
            guard useFreshSourceRF, let sourceRF else { return fallback }
            guard sourceRF.modelWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                  sourceRF.sourceIdentity == (try NativeRFDETRSourceImage.decode(original)).identity else {
                throw Failure.sourceRFMismatch
            }
            return sourceRF.regions
        }
    }
    protocol Backend: AnyObject {
        func annotate(source: CGImage, items: [[String: Any]], sourceEvidence: [String: Any]) throws -> Output
    }
    private let lock = NSLock()
    private var backend: (any Backend)?

    func install(_ backend: any Backend) {
        lock.lock(); defer { lock.unlock() }
        self.backend = backend
    }

    func annotate(source: CGImage, items: [[String: Any]], sourceEvidence: [String: Any]) throws -> Output {
        lock.lock(); let selected = backend; lock.unlock()
        if let selected {return try selected.annotate(source:source,items:items,sourceEvidence:sourceEvidence)}
        if #available(iOS 18.0,macOS 15.0,*) {
            return try NativeOperationalSourceInference.annotateDefault(source:source,items:items,sourceEvidence:sourceEvidence)
        }
        throw Failure.unsupportedNativeRuntime
    }
}
