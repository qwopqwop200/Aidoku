import Foundation

// Mac host stand-ins for app-only symbols referenced by the pipeline compile closure.

/// The app's reader diagnostics sink is not part of the pipeline host; legacy
/// translation transport calls are accepted and dropped.
enum ReaderTranslationDiagnostics {
    static func record(_ event: String, page: Int = -1, count: Int = 0, code: Int = 0,
                       elapsedMilliseconds: Double? = nil, outcome: Int = 0) {}
}

/// Content-free timing hooks of the legacy TranslationService (app file log);
/// the pipeline host records its own per-stage timings instead.
enum TranslationPerformanceDiagnostics {
    static func clientPhaseCompleted(phase: String, segmentCount: Int, elapsedMilliseconds: Double) {}
    static func transportCompleted(segmentCount: Int, responseBytes: Int, statusCode: Int,
                                   metrics: TranslationHTTPTransportMetrics) {}
    static func elapsedMilliseconds(since uptime: TimeInterval) -> Double {
        max(0, (ProcessInfo.processInfo.systemUptime - uptime) * 1_000)
    }
}

/// Connection cap read by BoundedURLSessionTransport (same value as TranslationService.swift).
enum BoundedTranslationBatchExecutor { static let allowedMaximumConcurrentRequests = 64 }
