import AidokuRunner
import Foundation

/// Ties partial-home sink cleanup to its caller so late partials never reach a successor.
enum SourceHomeSubscription {
    static func load(
        publisher: SinglePublisher<Home>?,
        receive: @escaping @Sendable (Home) -> Void,
        operation: @escaping @Sendable () async throws -> Home
    ) async throws -> Home {
        let token = await publisher?.sink(to: receive)
        do {
            let result = try await PartialResultSubscription.$id.withValue(token) {
                try Task.checkCancellation()
                return try await operation()
            }
            if let publisher, let token { await publisher.removeSink(token: token) }
            return result
        } catch {
            if let publisher, let token { await publisher.removeSink(token: token) }
            throw error
        }
    }
}
