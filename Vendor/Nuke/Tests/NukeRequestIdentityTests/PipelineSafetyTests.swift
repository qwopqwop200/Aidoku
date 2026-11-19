import Foundation
import Testing
@testable import Nuke

struct PipelineSafetyTests {
    @Test(arguments: [Int64(16), Int64.max]) @ImagePipelineActor
    func resumedLengthIsRejectedBeforeReservation(expectedLength: Int64) async throws {
        let loader = SafetyControlledLoader(expectedLength: expectedLength, statusCode: 206)
        let pipeline = ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.isRateLimiterEnabled = false
            $0.maximumResponseDataSize = 8
        }
        let request = ImageRequest(url: URL(string: "https://safety.invalid/resume/\(UUID())")!)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Length": "16", "Accept-Ranges": "bytes", "ETag": "fixture"]))
        let partial = try #require(ResumableData(response: response, data: Data([1])))
        ResumableDataStorage.shared.register(pipeline.id)
        ResumableDataStorage.shared.storeResumableData(partial, for: request, pipeline: pipeline)
        let task = Task { try await pipeline.data(for: request) }
        defer { task.cancel() }
        try await waitFor { loader.loads == 1 }
        #expect(loader.request?.value(forHTTPHeaderField: "Range") == "bytes=1-")
        loader.receive(Data([2]))
        loader.complete()
        do {
            _ = try await task.value
            Issue.record("Oversized resumed response must fail")
        } catch {
            guard case ImagePipeline.Error.dataDownloadExceededMaximumSize = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    private func waitFor(_ condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class SafetyControlledLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var onData: (@Sendable (Data, URLResponse) -> Void)?
    private var onCompletion: (@Sendable (Error?) -> Void)?
    private var savedRequest: URLRequest?
    private var count = 0
    let expectedLength: Int64
    let statusCode: Int
    init(expectedLength: Int64 = 2, statusCode: Int = 200) {
        self.expectedLength = expectedLength
        self.statusCode = statusCode
    }
    var loads: Int { lock.withLock { count } }
    var request: URLRequest? { lock.withLock { savedRequest } }
    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        lock.withLock { onData = didReceiveData; onCompletion = completion; savedRequest = request; count += 1 }
        return AnonymousCancellable { [weak self] in self?.complete(URLError(.cancelled)) }
    }
    func receive(_ data: Data) {
        let (callback, request) = lock.withLock { (onData, savedRequest) }
        guard let url = request?.url,
              let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil,
                                             headerFields: ["Content-Length": String(expectedLength)]) else { return }
        callback?(data, response)
    }
    func complete(_ error: Error? = nil) {
        let callback = lock.withLock { let callback = onCompletion; onCompletion = nil; return callback }
        callback?(error)
    }
}
