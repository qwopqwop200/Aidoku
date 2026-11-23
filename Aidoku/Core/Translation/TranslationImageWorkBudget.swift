import Foundation
import ImageIO
import Nuke

/// A single admission point before reader/download decoding. Waiting operations
/// retain compressed bytes or file URLs, never a queue of decoded page images.
final class TranslationImageWorkBudget: Sendable {
    static let shared = TranslationImageWorkBudget()
    private static let reclamationGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    private let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)

    enum AdmissionError: Error { case insufficientMemory, imageTooLarge }

    /// Reclaims page caches first, then the resident pipeline models only if headroom is still
    /// short; each step rechecks so queued recoveries do not evict warm resources again.
    /// Returns whether the models were purged.
    static func reclaimIdleResources(requiredHeadroom: UInt64) async -> Bool {
        @Sendable func short() -> Bool { !Task.isCancelled && ProcessMemory.available() < requiredHeadroom }
        guard short() else { return false }
        do {
            return try await reclamationGate.withPermit {
                guard short() else { return false }
                ReaderTranslationDiagnostics.record("memory_reclaim_begin")
                defer { ReaderTranslationDiagnostics.record("memory_reclaim_end") }
                await MainActor.run { ImagePipeline.shared.configuration.imageCache?.removeAll() }
                if #available(iOS 18.0, *) { await ReaderTranslationPipelineService.shared.clearMemory() }
                guard short() else { return false }
                if #available(iOS 18.0, *) { await ReaderTranslationPipelineService.shared.releaseModels() }
                return true
            }
        } catch { return false } // A cancelled waiter must not evict resources.
    }

    static func requiredHeadroom(decodedBytes: UInt64) -> UInt64 {
        PipelinePerformanceProfile.current.requiredHeadroom(decodedBytes: decodedBytes)
    }

    static func decodedBytes(in data: Data) -> UInt64 {
        decodedBytes(from: CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
    }

    static func decodedBytes(at url: URL) -> UInt64 {
        decodedBytes(from: CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
    }

    private static func decodedBytes(from source: CGImageSource?) -> UInt64 {
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return 0 }
        return decodedBytes(width: width.uint64Value, height: height.uint64Value)
    }

    static func decodedBytes(width: UInt64, height: UInt64) -> UInt64 {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return overflow || byteOverflow ? .max : bytes
    }

    func checkHeadroom(decodedBytes: UInt64) throws {
        let required = Self.requiredHeadroom(decodedBytes: decodedBytes)
        guard required < ProcessInfo.processInfo.physicalMemory else { throw AdmissionError.imageTooLarge }
        guard ProcessMemory.available() >= required else { throw AdmissionError.insufficientMemory }
    }

    func withPermit<Value: Sendable>(
        priority: TranslationRequestPriority = .foreground,
        decodedBytes: UInt64 = 0,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let required = Self.requiredHeadroom(decodedBytes: decodedBytes)
        guard required < ProcessInfo.processInfo.physicalMemory else { throw AdmissionError.imageTooLarge }
        var purgedModels = false
        while true {
            try Task.checkCancellation()
            do {
                return try await gate.withPermit(priority: priority) {
                    guard ProcessMemory.available() >= required else { throw AdmissionError.insufficientMemory }
                    return try await operation()
                }
            } catch AdmissionError.insufficientMemory {
                try Task.checkCancellation()
                // Caches go first; pipeline models only once caches alone were insufficient.
                if !purgedModels { purgedModels = await Self.reclaimIdleResources(requiredHeadroom: required) }
                try Task.checkCancellation()
                // Re-enter the priority-aware gate at once after a successful reclamation.
                if ProcessMemory.available() >= required { continue }
                // Wait outside admission so a background download cannot hold the reader's slot.
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}
