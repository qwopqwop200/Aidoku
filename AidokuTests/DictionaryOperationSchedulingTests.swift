import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct DictionaryOperationSchedulingTests {
    @Test(arguments: [false, true])
    func streamingLimitRejectsOversizedBodyWithOrWithoutLengthHeader(declared: Bool) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://dictionary-operation.invalid/oversized?declared=\(declared)")!
        await #expect(throws: (any Error).self) {
            _ = try await DictionaryFileOperations.boundedData(for: URLRequest(url: url), session: session, maximumBytes: 64)
        }
    }

    @Test func exactLimitReturnsUnchangedBytes() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://dictionary-operation.invalid/exact")!
        let data = try await DictionaryFileOperations.boundedData(for: URLRequest(url: url), session: session, maximumBytes: 64)
        #expect(data == Data(repeating: 65, count: 64))
    }

    @Test func cancellationAfterHeadersStopsAStalledStreamingBody() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://dictionary-operation.invalid/body-stall/" + UUID().uuidString)!
        let operation = Task {
            try await DictionaryFileOperations.boundedData(for: URLRequest(url: url), session: session, maximumBytes: 2 * 1024 * 1024)
        }
        defer { operation.cancel() }
        try await RegressionTestWait.until { DictionaryOperationURLProtocol.hasSentHeaders(url) }
        // Yield after a real streamed chunk so cancellation covers body consumption.
        try await Task.sleep(for: .milliseconds(20))
        operation.cancel()
        await #expect(throws: (any Error).self) { try await operation.value }
        try await RegressionTestWait.until { DictionaryOperationURLProtocol.hasStopped(url) }
        #expect(DictionaryOperationURLProtocol.requests(url) == 1)
    }

    @Test func oversizedOpenBodyAbortsTransportBeforeServerFinishes() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://dictionary-operation.invalid/oversized-open/" + UUID().uuidString)!
        await #expect(throws: (any Error).self) {
            _ = try await DictionaryFileOperations.boundedData(for: URLRequest(url: url), session: session, maximumBytes: 64)
        }
        #expect(DictionaryOperationURLProtocol.hasSentHeaders(url))
        try await RegressionTestWait.until { DictionaryOperationURLProtocol.hasStopped(url) }
        #expect(DictionaryOperationURLProtocol.requests(url) == 1)
    }

    @Test func downloadCancellationStopsActualTransferAndReleasesOperation() async throws {
        let manager = DictionaryManager.shared
        #expect(!manager.isImporting && !manager.isUpdating)
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://dictionary-operation.invalid/hold/" + UUID().uuidString)!
        let operation = Task { await manager.downloadDictionary(indexUrl: url.absoluteString, type: .term, session: session) }
        defer { operation.cancel() }
        try await RegressionTestWait.until { DictionaryOperationURLProtocol.hasStarted(url) }
        #expect(manager.isImporting)
        operation.cancel()
        #expect(await operation.value == false)
        try await RegressionTestWait.until { DictionaryOperationURLProtocol.hasStopped(url) }
        #expect(!manager.isImporting && !manager.isUpdating)
        #expect(DictionaryOperationURLProtocol.requests(url) == 1,
                "Cancellation during index fetch must never advance to archive transfer/import")
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DictionaryOperationURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class DictionaryOperationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var starts: [URL: Int] = [:]
    private static var stops: Set<URL> = []
    private static var headersSent: Set<URL> = []
    static func hasSentHeaders(_ url: URL) -> Bool { lock.withLock { headersSent.contains(url) } }
    static func hasStarted(_ url: URL) -> Bool { lock.withLock { starts[url] != nil } }
    static func hasStopped(_ url: URL) -> Bool { lock.withLock { stops.contains(url) } }
    static func requests(_ url: URL) -> Int { lock.withLock { starts[url, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dictionary-operation.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.starts[url, default: 0] += 1 }
        if url.path.hasPrefix("/hold") { return }
        let count = url.path == "/exact" ? 64 : 65
        let headers = url.query == "declared=true" ? ["Content-Length": String(count)] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                            headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        // URLSession.AsyncBytes buffers very small custom-protocol responses
        // until finish. A full chunk exercises streaming while the server stays open.
        let staysOpen = url.path.hasPrefix("/body-stall") || url.path.hasPrefix("/oversized-open")
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: staysOpen ? 1024 * 1024 : count))
        _ = Self.lock.withLock { Self.headersSent.insert(url) }
        if staysOpen { return }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if let url = request.url { _ = Self.lock.withLock { Self.stops.insert(url) } }
    }
}
