import Darwin
import Foundation

// Mac host platform bridges for the V2 compile closure. The legacy recognizer
// references the app-only ReaderTranslationSession memory probe; the host
// supplies the same vm_statistics64 estimate as Scripts/image-translation/HostSupport.swift.
enum ReaderTranslationSession {
    static func processAvailableMemory() -> UInt64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return (UInt64(statistics.free_count) + UInt64(statistics.inactive_count)) * UInt64(vm_page_size)
    }
}

/// The app's reader diagnostics sink is not part of the V2 host; legacy
/// translation transport calls are accepted and dropped.
enum ReaderTranslationDiagnostics {
    static func record(_ event: String, page: Int = -1, count: Int = 0, code: Int = 0,
                       elapsedMilliseconds: Double? = nil, outcome: Int = 0) {}
}

/// Content-free timing hooks of the legacy TranslationService (app file log);
/// the V2 host records its own per-stage timings instead.
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
