import Foundation

struct TranslationHTTPTransportMetrics: Equatable, Sendable {
    var responseHeadersMilliseconds: Double?
    var firstBodyByteMilliseconds: Double?
    var bodyMilliseconds: Double?
    var totalMilliseconds: Double?

    static let unmeasured = Self()
}

struct TranslationHTTPResponse: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
    var metrics = TranslationHTTPTransportMetrics.unmeasured
}

protocol TranslationHTTPTransport: Sendable {
    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse
}

/// URLSession's convenience `data(for:)` buffers the complete response before
/// callers can enforce a limit. This delegate-backed transport cancels a task
/// as soon as its advertised or observed body size exceeds the configured cap.
final class BoundedURLSessionTransport: NSObject, TranslationHTTPTransport, @unchecked Sendable {
    private struct RequestKey: Hashable {
        let session: ObjectIdentifier
        let taskIdentifier: Int
    }

    private final class RequestState {
        let maximumResponseBytes: Int
        let continuation: CheckedContinuation<TranslationHTTPResponse, Error>
        let startedAt = ProcessInfo.processInfo.systemUptime
        var response: HTTPURLResponse?
        var responseHeadersAt: TimeInterval?
        var firstBodyByteAt: TimeInterval?
        var data = Data()

        init(maximumResponseBytes: Int, continuation: CheckedContinuation<TranslationHTTPResponse, Error>) {
            self.maximumResponseBytes = maximumResponseBytes
            self.continuation = continuation
            data.reserveCapacity(min(maximumResponseBytes, 64 * 1024))
        }

        func completedResponse(at completedAt: TimeInterval) -> TranslationHTTPResponse? {
            guard let response else { return nil }
            let bodyStartedAt = firstBodyByteAt ?? responseHeadersAt
            return TranslationHTTPResponse(
                data: data,
                response: response,
                metrics: TranslationHTTPTransportMetrics(
                    responseHeadersMilliseconds: responseHeadersAt.map { Self.elapsedMilliseconds(from: startedAt, to: $0) },
                    firstBodyByteMilliseconds: firstBodyByteAt.map { Self.elapsedMilliseconds(from: startedAt, to: $0) },
                    bodyMilliseconds: bodyStartedAt.map { Self.elapsedMilliseconds(from: $0, to: completedAt) },
                    totalMilliseconds: Self.elapsedMilliseconds(from: startedAt, to: completedAt)
                )
            )
        }

        private static func elapsedMilliseconds(from start: TimeInterval, to end: TimeInterval) -> Double {
            max(0, (end - start) * 1_000)
        }
    }

    private final class CancellableTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancellationRequested = false

        func install(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancellationRequested
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancellationRequested = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private let stateLock = NSLock()
    private var states: [RequestKey: RequestState] = [:]
    private let delegateProxy: BoundedURLSessionDelegateProxy

    // Created eagerly (lazy properties would race on concurrent first calls). The sessions retain a
    // proxy with a weak owner, avoiding a transport -> session -> delegate -> transport cycle.
    private var standardSession: URLSession!
    private var directSession: URLSession!

    override init() {
        delegateProxy = BoundedURLSessionDelegateProxy()
        super.init()
        delegateProxy.owner = self
        standardSession = makeSession(bypassesProxy: false)
        directSession = makeSession(bypassesProxy: true)
    }

    deinit {
        delegateProxy.owner = nil
        standardSession?.invalidateAndCancel()
        directSession?.invalidateAndCancel()
    }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        guard maximumResponseBytes > 0 else {
            throw RemoteTranslationError.invalidConfiguration("response size limit must be positive")
        }
        try Task.checkCancellation()

        let taskBox = CancellableTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session: URLSession = bypassesProxy ? directSession : standardSession
                let task = session.dataTask(with: request)
                let key = requestKey(session: session, task: task)
                let state = RequestState(maximumResponseBytes: maximumResponseBytes, continuation: continuation)
                stateLock.withLock { states[key] = state }

                // Install after registering the continuation so a racing cancellation can complete it.
                taskBox.install(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let key = requestKey(session: session, task: task)
        completionHandler(nil)
        finish(key: key, result: .failure(RemoteTranslationError.redirectRejected))
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let key = requestKey(session: session, task: dataTask)
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(key: key, result: .failure(RemoteTranslationError.invalidResponse("the provider did not return an HTTP response")))
            return
        }

        stateLock.lock()
        guard let state = states[key] else {
            stateLock.unlock()
            completionHandler(.cancel)
            return
        }
        let tooLarge = response.expectedContentLength > 0 &&
            response.expectedContentLength > Int64(state.maximumResponseBytes)
        if !tooLarge {
            state.response = response
            state.responseHeadersAt = ProcessInfo.processInfo.systemUptime
        }
        stateLock.unlock()

        if tooLarge {
            completionHandler(.cancel)
            finish(key: key, result: .failure(RemoteTranslationError.responseTooLarge))
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = requestKey(session: session, task: dataTask)
        var oversizedState: RequestState?

        stateLock.lock()
        if let state = states[key] {
            let nextCount = state.data.count.addingReportingOverflow(data.count)
            if nextCount.overflow || nextCount.partialValue > state.maximumResponseBytes {
                oversizedState = states.removeValue(forKey: key)
            } else {
                if state.firstBodyByteAt == nil {
                    state.firstBodyByteAt = ProcessInfo.processInfo.systemUptime
                }
                state.data.append(data)
            }
        }
        stateLock.unlock()

        if let oversizedState {
            dataTask.cancel()
            oversizedState.continuation.resume(throwing: RemoteTranslationError.responseTooLarge)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = requestKey(session: session, task: task)
        let state = stateLock.withLock { states.removeValue(forKey: key) }
        guard let state else { return }

        let completedAt = ProcessInfo.processInfo.systemUptime
        if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.completedResponse(at: completedAt) {
            state.continuation.resume(returning: response)
        } else {
            state.continuation.resume(throwing: RemoteTranslationError.invalidResponse("the provider response was incomplete"))
        }
    }

    private func makeSession(bypassesProxy: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // An inactive private tailnet must fail within the timeout instead of appearing frozen.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = RemoteTranslationConfiguration.maximumTimeout
        configuration.timeoutIntervalForResource = RemoteTranslationConfiguration.maximumTimeout
        configuration.httpMaximumConnectionsPerHost = BoundedTranslationBatchExecutor.allowedMaximumConcurrentRequests
        if bypassesProxy { configuration.connectionProxyDictionary = [:] }
        return URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: nil)
    }

    private func requestKey(session: URLSession, task: URLSessionTask) -> RequestKey {
        RequestKey(session: ObjectIdentifier(session), taskIdentifier: task.taskIdentifier)
    }

    private func finish(key: RequestKey, result: Result<TranslationHTTPResponse, Error>) {
        let state = stateLock.withLock { states.removeValue(forKey: key) }
        state?.continuation.resume(with: result)
    }
}

/// URLSession retains its delegate until invalidation; a weak owner lets the transport deinitialize.
private final class BoundedURLSessionDelegateProxy: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    weak var owner: BoundedURLSessionTransport?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let owner else {
            completionHandler(nil)
            task.cancel()
            return
        }
        owner.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request,
                         completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let owner else {
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
