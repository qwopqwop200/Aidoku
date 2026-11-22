import Foundation

/// Content-free correlation shared by reader milestones and fine-grained phase timings.
/// A page token is a truncated existing SHA-256 identity, never a URL or source text.
enum ReaderTranslationDiagnostics {
    struct Context: Sendable, Equatable {
        let trace: UInt64
        let pageToken: UInt64
    }
    @TaskLocal static var context: Context?
    private static let identityLock = NSLock()
    private static var nextIdentity: UInt64 = 0

    static func makeContext(pageKey: String) -> Context {
        let token = UInt64(pageKey.prefix(16), radix: 16) ?? 0
        if let context, context.pageToken == token, token != 0 { return context }
        let identity = identityLock.withLock { nextIdentity &+= 1; return nextIdentity }
        return Context(trace: identity, pageToken: token)
    }

    private static let sink: TranslationPerformanceFileWriter? = {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return TranslationPerformanceFileWriter(directory: directory, filename: "reader-memory-events", samplesMemory: true)
    }()
    static func record(_ event: String, page: Int = -1, count: Int = 0, code: Int = 0,
                       context explicit: Context? = nil, elapsedMilliseconds: Double? = nil, outcome: Int = 0) {
        sink?.recordReader(event, page: page, count: count, code: code, context: explicit ?? context,
                           elapsedMilliseconds: elapsedMilliseconds, outcome: outcome)
    }

    static func measure<T>(_ event: String, context: Context? = ReaderTranslationDiagnostics.context, operation: () async throws -> T) async rethrows -> T {
        try await $context.withValue(context) {
            let started = ProcessInfo.processInfo.systemUptime
            record(event + "_begin", context: context)
            func finish(error: Error? = nil) {
                record(event + "_end", code: error.map { ($0 as NSError).code } ?? 0,
                    context: context, elapsedMilliseconds: max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000),
                    outcome: error == nil ? 0 : (error is CancellationError ? 1 : 2))
            }
            do {
                let result = try await operation()
                finish()
                return result
            } catch {
                finish(error: error)
                throw error
            }
        }
    }
}
