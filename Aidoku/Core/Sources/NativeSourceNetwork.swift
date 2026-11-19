import AidokuRunner
import Foundation

/// Shared production transport for native source ports, including source cookies,
/// user-agent selection and interactive verification when the server requires it.
enum NativeSourceNetwork {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Native ports fetch HTML, JSON and short image probes. A hostile or misconfigured
    /// server must not make one request buffer an unbounded body in memory.
    static let maximumBodyBytes = 64 * 1024 * 1024

    static func fetch(sourceKey: String) -> Fetch {
        { original in
            try Task.checkCancellation()
            guard let url = original.url else { throw URLError(.badURL) }
            let request = await AidokuRunner.Source.modify(url: url, request: original)
            try Task.checkCancellation()
            let (data, response) = try await limitedData(for: request)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse,
               CloudflareHandler.shared.shouldHandle(response: http, data: data) {
                do {
                    return try await CloudflareHandler.shared.handle(request: request, fetch: { try await limitedData(for: $0) })
                } catch let error as CloudflareHandler.HandleError {
                    // Keep the blocked HTTP response available to the adapter, as
                    // the source transport did before the native migration.
                    LogManager.logger.error("Verification failed for native source \(sourceKey): \(error)")
                    try Task.checkCancellation()
                    return (data, response)
                }
            }
            return (data, response)
        }
    }

    /// Streams through `session` (the shared source session by default) and stops once the body exceeds `maximum`.
    /// The per-task body delegate leaves redirect handling to the session's delegate.
    static func limitedData(
        for request: URLRequest,
        session: URLSession? = nil,
        maximum: Int = maximumBodyBytes
    ) async throws -> (Data, URLResponse) {
        let resolvedSession: URLSession
        if let session { resolvedSession = session } else { resolvedSession = try await SourceNetwork.shared.session() }
        do {
            return try await SourceResponseBody.read(request, session: resolvedSession) { _ in .limited(maximum) }
        } catch is SourceResponseBody.TooLarge {
            throw URLError(.dataLengthExceedsMaximum)
        }
    }
}
