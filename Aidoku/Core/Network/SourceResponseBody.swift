import Foundation

/// A per-task delegate keeps the source's URLSession, cookie store, redirects and proxy configuration.
final class SourceResponseBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Policy {
        case headersOnly
        case limited(Int)
        case unrestricted
    }

    struct TooLarge: Error { let response: URLResponse }
    typealias Output = (Data, URLResponse)
    typealias SelectPolicy = @Sendable (URLResponse) -> Policy

    private let policy: SelectPolicy
    private let continuation: AsyncThrowingStream<Output, Error>.Continuation
    private var data = Data()
    private var response: URLResponse?
    private var limit: Int?
    private var finished = false

    private init(policy: @escaping SelectPolicy, continuation: AsyncThrowingStream<Output, Error>.Continuation) {
        self.policy = policy
        self.continuation = continuation
    }

    static func read(_ request: URLRequest, session: URLSession, policy: @escaping SelectPolicy) async throws -> Output {
        try Task.checkCancellation()
        let (results, continuation) = AsyncThrowingStream<Output, Error>.makeStream()
        let task = session.dataTask(with: request)
        task.delegate = SourceResponseBody(policy: policy, continuation: continuation)
        return try await withTaskCancellationHandler {
            task.resume()
            var iterator = results.makeAsyncIterator()
            do {
                guard let result = try await iterator.next() else { throw CancellationError() }
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        switch policy(response) {
        case .headersOnly:
            finish(response)
            completionHandler(.cancel)
        case let .limited(maximum):
            let http = response as? HTTPURLResponse
            let encoding = http?.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            // Encoded lengths and HEAD headers can describe different bytes from the delivered body.
            if dataTask.currentRequest?.httpMethod != "HEAD", encoding == nil || encoding == "identity",
               http?.statusCode != 204, http?.statusCode != 205, http?.statusCode != 304, response.expectedContentLength > Int64(maximum) {
                reject(response)
                completionHandler(.cancel)
            } else {
                limit = maximum
                completionHandler(.allow)
            }
        case .unrestricted:
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !finished else { return }
        if let limit, chunk.count > limit - data.count, let response {
            reject(response)
            dataTask.cancel()
        } else {
            data.append(chunk)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error {
            continuation.finish(throwing: error)
        } else if let response = task.response {
            finish(response)
        } else {
            continuation.finish(throwing: URLError(.badServerResponse))
        }
    }

    private func reject(_ response: URLResponse) {
        finished = true
        data = Data()
        continuation.finish(throwing: TooLarge(response: response))
    }

    private func finish(_ response: URLResponse) {
        finished = true
        continuation.yield((data, response))
        continuation.finish()
    }
}
