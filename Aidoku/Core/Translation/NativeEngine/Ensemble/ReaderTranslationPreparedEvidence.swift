import CoreGraphics
import Foundation

/// Shared RAM-only page artifact. Recognition binds BEFORE detector registration;
/// prepared work, the session window, and each pending native render retain it.
/// Dropping one owner never closes another owner's render. The last reference
/// releases the lease, including cancellation/error paths. Never archive it.
final class ReaderTranslationPreparedEvidence: @unchecked Sendable {
    typealias Acquire = @Sendable (CGImage) throws -> NativeMainEnsembleEvidenceLease?
    enum Failure: Error { case differentOriginal }
    private let lock = NSLock()
    private typealias BoundLease = (lease: NativeMainEnsembleEvidenceLease, sourceIdentity: NativeRFOCRSourceReuse.VerifiedIdentity?)
    private let acquire: @Sendable (CGImage) throws -> BoundLease?
    // The lease pins the content-addressed evidence. Only a repeated bind
    // needs object identity; a queued page need not own its decoded pixels.
    private weak var original: CGImage?
    private var bound: BoundLease?

    init(store: NativeMainEnsembleEvidenceStore = .shared) {
        acquire = { original in
            guard NativeMainEnsembleRenderer.enabled else { return nil }
            let source = try NativeMainEnsemblePreparedDB.SourceBinding(original: original)
            return (try store.lease(source: source), source.verifiedIdentity)
        }
    }

    init(acquire: @escaping Acquire) {
        self.acquire = { original in try acquire(original).map { ($0, nil) } }
    }

    /// The digest attests only to the exact upright raster that acquired the lease.
    func sourceIdentity(for image: CGImage) -> String? { verifiedIdentity(for: image)?.digest }

    func verifiedIdentity(for image: CGImage) -> NativeRFOCRSourceReuse.VerifiedIdentity? {
        lock.lock(); defer { lock.unlock() }
        return original === image ? bound?.sourceIdentity : nil
    }

    func bind(original: CGImage) throws {
        lock.lock(); defer { lock.unlock() }
        if bound != nil {
            guard self.original === original else { throw Failure.differentOriginal }
            return
        }
        guard let observation = try acquire(original) else { return }
        self.original = original
        bound = observation
    }
}
