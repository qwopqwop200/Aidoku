// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

struct TranslationHTTPTransportMetrics: Equatable, Sendable {
    let responseHeadersMilliseconds: Double?
    let firstBodyByteMilliseconds: Double?
    let bodyMilliseconds: Double?
    let totalMilliseconds: Double?

    static let unmeasured = Self(
        responseHeadersMilliseconds: nil,
        firstBodyByteMilliseconds: nil,
        bodyMilliseconds: nil,
        totalMilliseconds: nil
    )
}

struct TranslationHTTPResponse: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
    let metrics: TranslationHTTPTransportMetrics

    init(
        data: Data,
        response: HTTPURLResponse,
        metrics: TranslationHTTPTransportMetrics = .unmeasured
    ) {
        self.data = data
        self.response = response
        self.metrics = metrics
    }
}

/// Receives response body bytes as they arrive (2xx responses only), in
/// order, before the complete response is returned.
typealias TranslationHTTPBodyObserver = @Sendable (Data) -> Void

protocol TranslationHTTPTransport: Sendable {
    func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
        bypassesProxy: Bool
    ) async throws -> TranslationHTTPResponse

    func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
        bypassesProxy: Bool,
        onBodyData: TranslationHTTPBodyObserver?
    ) async throws -> TranslationHTTPResponse
}

extension TranslationHTTPTransport {
    /// Buffered transports deliver the complete body once.
    func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
        bypassesProxy: Bool,
        onBodyData: TranslationHTTPBodyObserver?
    ) async throws -> TranslationHTTPResponse {
        let response = try await data(for: request, maximumResponseBytes: maximumResponseBytes, bypassesProxy: bypassesProxy)
        if let onBodyData, (200...299).contains(response.response.statusCode), !response.data.isEmpty {
            onBodyData(response.data)
        }
        return response
    }
}

/// URLSession's convenience `data(for:)` buffers the complete response before
/// callers can enforce a limit. This delegate-backed transport cancels a task
/// as soon as its advertised or observed body size exceeds the configured cap.
final class BoundedURLSessionTransport: NSObject, TranslationHTTPTransport,
    @unchecked Sendable {
    private struct RequestKey: Hashable {
        let session: ObjectIdentifier
        let taskIdentifier: Int
    }

    private final class RequestState {
        let maximumResponseBytes: Int
        let continuation: CheckedContinuation<TranslationHTTPResponse, Error>
        let onBodyData: TranslationHTTPBodyObserver?
        let startedAt: TimeInterval
        var response: HTTPURLResponse?
        var responseHeadersAt: TimeInterval?
        var firstBodyByteAt: TimeInterval?
        var data = Data()

        init(
            maximumResponseBytes: Int,
            continuation: CheckedContinuation<TranslationHTTPResponse, Error>,
            onBodyData: TranslationHTTPBodyObserver? = nil,
            startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) {
            self.maximumResponseBytes = maximumResponseBytes
            self.continuation = continuation
            self.onBodyData = onBodyData
            self.startedAt = startedAt
            data.reserveCapacity(min(maximumResponseBytes, 64 * 1024))
        }

        func completedResponse(
            at completedAt: TimeInterval
        ) -> TranslationHTTPResponse? {
            guard let response else { return nil }
            let bodyStartedAt = firstBodyByteAt ?? responseHeadersAt
            return TranslationHTTPResponse(
                data: data,
                response: response,
                metrics: TranslationHTTPTransportMetrics(
                    responseHeadersMilliseconds: responseHeadersAt.map {
                        Self.elapsedMilliseconds(from: startedAt, to: $0)
                    },
                    firstBodyByteMilliseconds: firstBodyByteAt.map {
                        Self.elapsedMilliseconds(from: startedAt, to: $0)
                    },
                    bodyMilliseconds: bodyStartedAt.map {
                        Self.elapsedMilliseconds(from: $0, to: completedAt)
                    },
                    totalMilliseconds: Self.elapsedMilliseconds(
                        from: startedAt,
                        to: completedAt
                    )
                )
            )
        }

        private static func elapsedMilliseconds(
            from start: TimeInterval,
            to end: TimeInterval
        ) -> Double {
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
            if shouldCancel {
                task.cancel()
            }
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

    // Initialize both sessions eagerly before this transport is published;
    // Swift lazy properties are not a synchronization primitive and two first
    // concurrent provider calls could otherwise race their initialization.
    // The sessions retain a proxy whose owner is weak, avoiding the usual
    // transport -> session -> delegate -> transport retain cycle.
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

    func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
        bypassesProxy: Bool
    ) async throws -> TranslationHTTPResponse {
        try await data(for: request, maximumResponseBytes: maximumResponseBytes, bypassesProxy: bypassesProxy, onBodyData: nil)
    }

    func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
        bypassesProxy: Bool,
        onBodyData: TranslationHTTPBodyObserver?
    ) async throws -> TranslationHTTPResponse {
        guard maximumResponseBytes > 0 else {
            throw RemoteTranslationError.invalidConfiguration(
                "response size limit must be positive"
            )
        }
        try Task.checkCancellation()

        let taskBox = CancellableTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session: URLSession =
                    bypassesProxy ? directSession : standardSession
                let task = session.dataTask(with: request)
                let key = RequestKey(
                    session: ObjectIdentifier(session),
                    taskIdentifier: task.taskIdentifier
                )
                let state = RequestState(
                    maximumResponseBytes: maximumResponseBytes,
                    continuation: continuation,
                    onBodyData: onBodyData
                )
                stateLock.lock()
                states[key] = state
                stateLock.unlock()

                // Install only after registering the continuation. A
                // cancellation racing this setup can then always complete it.
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
            finish(
                key: key,
                result: .failure(
                    RemoteTranslationError.invalidResponse(
                        "the provider did not return an HTTP response"
                    )
                )
            )
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

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let key = requestKey(session: session, task: dataTask)
        var oversizedState: RequestState?
        var observer: TranslationHTTPBodyObserver?

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
                if let status = state.response?.statusCode, (200...299).contains(status) {
                    observer = state.onBodyData
                }
            }
        }
        stateLock.unlock()
        // The session delegate queue is serial, so observers see body order.
        observer?(data)

        if let oversizedState {
            dataTask.cancel()
            oversizedState.continuation.resume(
                throwing: RemoteTranslationError.responseTooLarge
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let key = requestKey(session: session, task: task)
        stateLock.lock()
        let state = states.removeValue(forKey: key)
        stateLock.unlock()
        guard let state else { return }

        let completedAt = ProcessInfo.processInfo.systemUptime
        if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.completedResponse(at: completedAt) {
            state.continuation.resume(returning: response)
        } else {
            state.continuation.resume(
                throwing: RemoteTranslationError.invalidResponse(
                    "the provider response was incomplete"
                )
            )
        }
    }

    private func makeSession(bypassesProxy: Bool) -> URLSession {
        let configuration = Self.sessionConfiguration(
            bypassesProxy: bypassesProxy
        )
        return URLSession(
            configuration: configuration,
            delegate: delegateProxy,
            delegateQueue: nil
        )
    }

    static func sessionConfiguration(
        bypassesProxy: Bool
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // A private tailnet endpoint must fail within the request timeout when
        // its tunnel is inactive. Waiting for connectivity makes the settings
        // test and every OCR translation appear frozen.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost =
            BoundedTranslationBatchExecutor.allowedMaximumConcurrentRequests
        if bypassesProxy {
            configuration.connectionProxyDictionary = [:]
        }
        return configuration
    }

    private func requestKey(
        session: URLSession,
        task: URLSessionTask
    ) -> RequestKey {
        RequestKey(
            session: ObjectIdentifier(session),
            taskIdentifier: task.taskIdentifier
        )
    }

    private func finish(
        key: RequestKey,
        result: Result<TranslationHTTPResponse, Error>
    ) {
        stateLock.lock()
        let state = states.removeValue(forKey: key)
        stateLock.unlock()
        guard let state else { return }

        switch result {
        case let .success(value):
            state.continuation.resume(returning: value)
        case let .failure(error):
            state.continuation.resume(throwing: error)
        }
    }
}

/// URLSession strongly retains its delegate until invalidation. Keeping the
/// forwarding owner weak lets the transport deinitialize normally while still
/// preserving delegate-backed streaming response limits.
private final class BoundedURLSessionDelegateProxy: NSObject,
    URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable
{
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
        owner.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
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
        owner.urlSession(
            session,
            dataTask: dataTask,
            didReceive: response,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        owner?.urlSession(
            session,
            dataTask: dataTask,
            didReceive: data
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        owner?.urlSession(
            session,
            task: task,
            didCompleteWithError: error
        )
    }
}
