import Foundation
import Testing
@testable import Nuke

struct PipelineSafetyTests {
    @Test(arguments: [false, true])
    func encodedDiskWritesRespectRequestOption(disabled: Bool) async throws {
        let cache = SafetyDataCache()
        let pipeline = ImagePipeline {
            $0.dataCache = cache
            $0.imageCache = nil
            $0.dataCachePolicy = .storeEncodedImages
            $0.makeImageEncoder = { _ in SafetyEncoder() }
        }
        let request = ImageRequest(id: UUID().uuidString, image: { ImageContainer(image: PlatformImage()) },
                                   options: disabled ? [.disableDiskCacheWrites] : [])
        _ = try await pipeline.image(for: request)
        try await waitForIdle(pipeline.configuration.imageEncodingQueue)
        #expect(cache.writes == (disabled ? 0 : 1))
    }

    @Test @ImagePipelineActor
    func cancelledFailedCacheDecodeDoesNotStartTransport() async throws {
        let gate = SafetyGate()
        defer { gate.release() }
        let cache = SafetyDataCache()
        let loader = SafetyControlledLoader()
        let pipeline = ImagePipeline {
            $0.dataCache = cache
            $0.imageCache = nil
            $0.dataLoader = loader
            $0.isRateLimiterEnabled = false
            $0.makeImageDecoder = { _ in SafetyFailingDecoder(gate: gate) }
        }
        let request = ImageRequest(url: URL(string: "https://safety.invalid/cancelled-cache")!)
        pipeline.cache.storeCachedData(Data([0]), for: request)
        // Retain the worker to exercise its late callback after disposal.
        let worker = TaskLoadImage(pipeline, request)
        let subscriber = NSObject()
        let subscription = try #require(worker.publisher.subscribe(subscriber: subscriber) { _ in })
        try await waitFor { gate.entered }
        subscription.unsubscribe()
        gate.release()
        try await waitForIdle(pipeline.configuration.imageDecodingQueue)
        #expect(worker.isDisposed)
        #expect(loader.loads == 0)
    }

    @Test func latePreviewDecompressionCannotReplaceFinalCacheEntry() async throws {
        let gate = SafetyGate()
        defer { gate.release() }
        let loader = SafetyControlledLoader()
        let delegate = SafetyDecompressionDelegate(gate: gate)
        let pipeline = ImagePipeline(delegate: delegate) {
            $0.dataLoader = loader
            $0.dataCache = nil
            $0.imageCache = ImageCache()
            $0.isRateLimiterEnabled = false
            $0.isProgressiveDecodingEnabled = true
            $0.makeImageDecoder = { _ in SafetyPreviewDecoder() }
        }
        let request = ImageRequest(url: URL(string: "https://safety.invalid/late-preview")!)
        let task = pipeline.imageTask(with: request)
        defer { task.cancel() }
        try await waitFor { loader.loads == 1 }
        loader.receive(Data([1]))
        try await waitFor { gate.entered }
        loader.receive(Data([2]))
        loader.complete()
        let final = try await task.response
        #expect(!final.isPreview)
        gate.release()
        try await waitForIdle(pipeline.configuration.imageDecompressingQueue)
        #expect(pipeline.cache[request]?.isPreview == false)
    }

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

    @ImagePipelineActor private func waitForIdle(_ queue: TaskQueue) async throws {
        let deadline = Date().addingTimeInterval(3)
        while queue.runningCount != 0 || queue.pendingCount != 0 {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class SafetyGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var isReleased = false
    var entered: Bool { condition.withLock { didEnter } }
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        didEnter = true
        while !isReleased { condition.wait() }
    }
    func release() {
        condition.withLock { isReleased = true; condition.broadcast() }
    }
}

private struct SafetyFailingDecoder: ImageDecoding {
    let gate: SafetyGate
    func decode(_ data: Data) throws -> ImageContainer {
        gate.wait()
        throw ImageDecodingError.unknown
    }
}

private struct SafetyPreviewDecoder: ImageDecoding {
    var isAsynchronous: Bool { false }
    func decode(_ data: Data) throws -> ImageContainer { make(preview: false) }
    func decodePartiallyDownloadedData(_ data: Data) -> ImageContainer? { make(preview: true) }
    private func make(preview: Bool) -> ImageContainer {
        let image = PlatformImage()
        ImageDecompression.setDecompressionNeeded(true, for: image)
        return ImageContainer(image: image, isPreview: preview)
    }
}

private final class SafetyDecompressionDelegate: ImagePipeline.Delegate {
    let gate: SafetyGate
    init(gate: SafetyGate) { self.gate = gate }
    func shouldDecompress(response: ImageResponse, for request: ImageRequest, pipeline: ImagePipeline) -> Bool { true }
    func decompress(response: ImageResponse, request: ImageRequest, pipeline: ImagePipeline) -> ImageResponse {
        if response.isPreview { gate.wait() }
        return response
    }
}

private struct SafetyEncoder: ImageEncoding {
    func encode(_ image: PlatformImage) -> Data? { Data([1, 2, 3]) }
}

private final class SafetyDataCache: DataCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var writeCount = 0
    var writes: Int { lock.withLock { writeCount } }
    func cachedData(for key: String) -> Data? { lock.withLock { values[key] } }
    func containsData(for key: String) -> Bool { cachedData(for: key) != nil }
    func storeData(_ data: Data, for key: String) { lock.withLock { values[key] = data; writeCount += 1 } }
    func removeData(for key: String) { lock.withLock { values[key] = nil } }
    func removeAll() { lock.withLock { values.removeAll() } }
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
