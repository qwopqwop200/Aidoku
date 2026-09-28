import Foundation

/// Content-free correlation shared by reader milestones and fine-grained phase timings.
/// A page token is a truncated existing SHA-256 identity, never a URL or source text.
enum ReaderTranslationDiagnostics {
    struct Context: Sendable, Equatable {
        let trace: UInt64
        let pageToken: UInt64
        let page: Int
    }
    @TaskLocal static var context: Context?
    private static let identityLock = NSLock()
    private static var nextIdentity: UInt64 = 0

    static func makeContext(pageKey: String, page: Int = -1) -> Context {
        let token = UInt64(pageKey.prefix(16), radix: 16) ?? 0
        if let context, context.pageToken == token, token != 0 {
            return Context(trace: context.trace, pageToken: token, page: page >= 0 ? page : context.page)
        }
        let identity = identityLock.withLock { nextIdentity &+= 1; return nextIdentity }
        return Context(trace: identity, pageToken: token, page: page)
    }

    private static let sink: TranslationPerformanceFileWriter? = {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return TranslationPerformanceFileWriter(directory: directory, filename: "reader-memory-events", samplesMemory: true)
    }()
    private static let renderingProfileEnabled: Bool = {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("DisplayPerformance/run.json").path)
    }()

    static func renderingProfile(_ event: String, count: Int = 0, revision: UInt64 = 0) {
        guard renderingProfileEnabled else { return }
        record(event, count: count, code: Int(clamping: revision))
    }

    static func record(_ event: String, page: Int = -1, count: Int = 0, code: Int = 0,
                       context explicit: Context? = nil, elapsedMilliseconds: Double? = nil, outcome: Int = 0) {
        sink?.recordReader(event, page: page, count: count, code: code, context: explicit ?? context,
                           elapsedMilliseconds: elapsedMilliseconds, outcome: outcome)
    }

    struct Span: Sendable {
        let event: String
        let context: Context?
        private let started: TimeInterval
        init(_ event: String, context: Context? = ReaderTranslationDiagnostics.context, count: Int = 0) {
            self.event = event
            self.context = context
            started = ProcessInfo.processInfo.systemUptime
            ReaderTranslationDiagnostics.record(event + "_begin", count: count, context: context)
        }
        func finish(count: Int = 0, error: Error? = nil) {
            ReaderTranslationDiagnostics.record(event + "_end", count: count, code: error.map { ($0 as NSError).code } ?? 0,
                context: context, elapsedMilliseconds: max(0, (ProcessInfo.processInfo.systemUptime - started) * 1000),
                outcome: error == nil ? 0 : (error is CancellationError ? 1 : 2))
        }
    }

    static func measure<T>(_ event: String, context: Context? = ReaderTranslationDiagnostics.context, operation: () async throws -> T) async rethrows -> T {
        try await $context.withValue(context) {
            let span = Span(event)
            do {
                let result = try await operation()
                span.finish()
                return result
            } catch {
                span.finish(error: error)
                throw error
            }
        }
    }
}
