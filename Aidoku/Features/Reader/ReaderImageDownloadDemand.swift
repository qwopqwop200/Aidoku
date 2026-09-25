import Foundation
import Nuke

/// A visible, cold network image temporarily reduces bulk download admission.
/// This lease follows image demand, not the lifetime of its reader/controller.
@MainActor
final class ReaderImageDownloadDemand {
    private let admission: BulkDownloadAdmission
    private var generation = UUID()
    private var isCold = false
    private var isVisible = false
    private var token: UUID?
    private var acquisition: Task<Void, Never>?

    init(admission: BulkDownloadAdmission = .shared) {
        self.admission = admission
    }

    deinit {
        acquisition?.cancel()
        if let token {
            let admission = admission
            Task { await admission.releaseReaderDemand(token) }
        }
    }

    @discardableResult
    func start(request: ImageRequest, pipeline: ImagePipeline, priority: ImageRequest.Priority) async -> UUID {
        end()
        let issued = generation
        isCold = ReaderImageDownloadCache.needsNetwork(request: request, pipeline: pipeline)
        updatePriority(priority)
        await acquisition?.value
        if Task.isCancelled { end(issued) }
        return issued
    }

    func updatePriority(_ priority: ImageRequest.Priority) {
        isVisible = priority >= .high
        guard isCold, isVisible else {
            release()
            return
        }
        guard token == nil, acquisition == nil else { return }
        let issued = generation
        let admission = admission
        acquisition = Task { [weak self] in
            guard let token = try? await admission.acquireReaderDemand() else { return }
            guard let self, !Task.isCancelled, self.generation == issued, self.isCold, self.isVisible else {
                await admission.releaseReaderDemand(token)
                return
            }
            self.token = token
            self.acquisition = nil
        }
    }

    func end(_ issued: UUID? = nil) {
        if let issued, issued != generation { return }
        generation = UUID()
        isCold = false
        isVisible = false
        release()
    }

    private func release() {
        acquisition?.cancel()
        acquisition = nil
        if let token {
            self.token = nil
            let admission = admission
            Task { await admission.releaseReaderDemand(token) }
        }
    }
}

/// Nuke stores original bytes without processor/thumbnail keys. Consult both
/// reusable disk forms without reading bytes or decoding them on MainActor.
enum ReaderImageDownloadCache {
    /// Processed images can be rebuilt from separately cached source bytes.
    /// A user-requested reload must invalidate both identities.
    static func removeCachedImageAndOriginal(for request: ImageRequest, pipeline: ImagePipeline) {
        pipeline.cache.removeCachedImage(for: request)
        var original = request
        original.processors = []
        original.thumbnail = nil
        pipeline.cache.removeCachedImage(for: original)
    }

    static func needsNetwork(request: ImageRequest, pipeline: ImagePipeline) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        if pipeline.cache.containsCachedImage(for: request, caches: .memory) { return false }
        guard !request.options.contains(.disableDiskCacheReads) else { return true }
        if pipeline.cache.containsCachedImage(for: request, caches: .disk) { return false }
        var original = request
        original.processors = []
        original.thumbnail = nil
        return !pipeline.cache.containsCachedImage(for: original, caches: .disk)
    }
}
