import Foundation
import ImageIO
import Nuke

/// A single admission point before reader/download decoding. Waiting operations
/// retain compressed bytes or file URLs, never a queue of decoded page images.
final class TranslationImageWorkBudget: Sendable {
    static let shared = TranslationImageWorkBudget()
    static let minimumHeadroom: UInt64 = 1_280 * 1_024 * 1_024
    private let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    private let availableMemory: @Sendable () -> UInt64

    init(availableMemory: @escaping @Sendable () -> UInt64 = { ReaderTranslationSession.processAvailableMemory() }) {
        self.availableMemory = availableMemory
    }

    enum AdmissionError: Error { case insufficientMemory, imageTooLarge }

    /// Reclaim page caches first, then warm OCR runtimes only if headroom is
    /// still short. Waiting on headroom without releasing these owners can
    /// otherwise stall indefinitely, but reloading models that did not need to
    /// be released costs the next page a cold OCR start.
    @discardableResult
    static func reclaimIdleResources(
        requiredHeadroom: UInt64 = minimumHeadroom,
        availableMemory: @Sendable () -> UInt64 = { ReaderTranslationSession.processAvailableMemory() }
    ) async -> Bool {
        await reclaimIdleResources(requiredHeadroom: requiredHeadroom, availableMemory: availableMemory, purgeCaches: {
            await MainActor.run {
                ImagePipeline.shared.configuration.imageCache?.removeAll()
                ReaderTranslationRenderCache.shared.clearMemory()
                ReaderTranslationImageExporter.clearIdleRenderer()
            }
        }, purgeModels: {
            if #available(iOS 18.0, *) { await ReaderOCRService.shared.purge() }
        })
    }

    /// Returns whether the OCR models were purged.
    @discardableResult
    static func reclaimIdleResources(
        requiredHeadroom: UInt64,
        availableMemory: @Sendable () -> UInt64,
        purgeCaches: @Sendable () async -> Void,
        purgeModels: @Sendable () async -> Void
    ) async -> Bool {
        ReaderTranslationDiagnostics.record("memory_reclaim_begin")
        defer { ReaderTranslationDiagnostics.record("memory_reclaim_end") }
        await purgeCaches()
        guard availableMemory() < requiredHeadroom else { return false }
        await purgeModels()
        return true
    }

    static func requiredHeadroom(decodedBytes: UInt64) -> UInt64 {
        let (working, overflow) = decodedBytes.multipliedReportingOverflow(by: 3)
        let (total, additionOverflow) = working.addingReportingOverflow(512 * 1_024 * 1_024)
        return overflow || additionOverflow ? .max : max(minimumHeadroom, total)
    }

    static func decodedBytes(in data: Data) -> UInt64 {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return 0 }
        let (pixels, overflow) = width.uint64Value.multipliedReportingOverflow(by: height.uint64Value)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return overflow || byteOverflow ? .max : bytes
    }

    func checkHeadroom(decodedBytes: UInt64) throws {
        let required = Self.requiredHeadroom(decodedBytes: decodedBytes)
        guard required < ProcessInfo.processInfo.physicalMemory else { throw AdmissionError.imageTooLarge }
        guard availableMemory() >= required else { throw AdmissionError.insufficientMemory }
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
                return try await gate.withPermit(priority: priority) { [availableMemory] in
                    guard availableMemory() >= required else { throw AdmissionError.insufficientMemory }
                    return try await operation()
                }
            } catch AdmissionError.insufficientMemory {
                // Caches go first; OCR models only once caches alone were insufficient.
                if !purgedModels {
                    purgedModels = await Self.reclaimIdleResources(requiredHeadroom: required, availableMemory: availableMemory)
                }
                // Release admission before waiting so a background download
                // cannot hold the foreground reader's slot during pressure.
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}
