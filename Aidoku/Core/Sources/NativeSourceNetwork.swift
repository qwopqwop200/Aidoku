import AidokuRunner
import Foundation

/// Shared production transport for native source ports, including source cookies,
/// user-agent selection and interactive verification when the server requires it.
enum NativeSourceNetwork {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func fetch(sourceKey: String) -> Fetch {
        { original in
            try Task.checkCancellation()
            guard let url = original.url else { throw URLError(.badURL) }
            let request = await AidokuRunner.Source.modify(url: url, request: original)
            try Task.checkCancellation()
            let (data, response) = try await SourceNetwork.shared.data(for: request)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse,
               CloudflareHandler.shared.shouldHandle(response: http, data: data) {
                do {
                    return try await CloudflareHandler.shared.handle(request: request)
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
}
