// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation
import os

/// Numeric, content-free translation timing for device performance diagnosis.
/// Never log OCR text, translated text, credentials, endpoints, model names,
/// or provider request identifiers here.
enum TranslationPerformanceDiagnostics {
    private static let logger = os.Logger(
        subsystem: "app.aidoku.Aidoku",
        category: "TranslationPerformance"
    )

    static func serviceCompleted(
        source: TranslationResultSource,
        segmentCount: Int,
        sourceBytes: Int,
        elapsedMilliseconds: Double
    ) {
        TranslationPerformanceFileLog.record(.service, fields: [.source: sourceCode(source), .segments: Double(segmentCount),
            .sourceBytes: Double(sourceBytes), .elapsedMilliseconds: elapsedMilliseconds])
        logger.notice(
            "service_complete source=\(source.rawValue, privacy: .public) segments=\(segmentCount, privacy: .public) source_bytes=\(sourceBytes, privacy: .public) elapsed_ms=\(elapsedMilliseconds, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    static func providerAttemptCompleted(
        attempt: Int,
        segmentCount: Int,
        sourceBytes: Int,
        elapsedMilliseconds: Double
    ) {
        TranslationPerformanceFileLog.record(.providerAttempt, fields: [.attempt: Double(attempt), .segments: Double(segmentCount),
            .sourceBytes: Double(sourceBytes), .elapsedMilliseconds: elapsedMilliseconds])
        logger.notice(
            "provider_attempt_complete attempt=\(attempt, privacy: .public) segments=\(segmentCount, privacy: .public) source_bytes=\(sourceBytes, privacy: .public) elapsed_ms=\(elapsedMilliseconds, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    static func providerAttemptFailed(
        attempt: Int,
        reason: String,
        willRetry: Bool,
        segmentCount: Int,
        sourceBytes: Int,
        elapsedMilliseconds: Double
    ) {
        TranslationPerformanceFileLog.record(.providerFailure, fields: [.attempt: Double(attempt), .retry: willRetry ? 1 : 0,
            .reason: reason == "invalid_structured_response" ? 1 : 0, .segments: Double(segmentCount),
            .sourceBytes: Double(sourceBytes), .elapsedMilliseconds: elapsedMilliseconds])
        logger.error(
            "provider_attempt_failed attempt=\(attempt, privacy: .public) reason=\(reason, privacy: .public) retry=\(willRetry, privacy: .public) segments=\(segmentCount, privacy: .public) source_bytes=\(sourceBytes, privacy: .public) elapsed_ms=\(elapsedMilliseconds, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    static func clientPhaseCompleted(
        phase: String,
        segmentCount: Int,
        elapsedMilliseconds: Double
    ) {
        if let event = TranslationPerformanceFileLog.Event(rawValue: phase) {
            TranslationPerformanceFileLog.record(event, fields: [.segments: Double(segmentCount), .elapsedMilliseconds: elapsedMilliseconds])
        }
        logger.notice(
            "client_phase_complete phase=\(phase, privacy: .public) segments=\(segmentCount, privacy: .public) elapsed_ms=\(elapsedMilliseconds, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    static func transportCompleted(
        segmentCount: Int,
        responseBytes: Int,
        statusCode: Int,
        metrics: TranslationHTTPTransportMetrics
    ) {
        let statusClass = statusCode / 100
        TranslationPerformanceFileLog.record(.transport, fields: [.segments: Double(segmentCount),
            .responseBytes: Double(responseBytes), .statusClass: Double(statusClass), .statusCode: Double(statusCode),
            .responseHeadersMilliseconds: metrics.responseHeadersMilliseconds ?? -1,
            .firstBodyByteMilliseconds: metrics.firstBodyByteMilliseconds ?? -1,
            .bodyMilliseconds: metrics.bodyMilliseconds ?? -1, .totalMilliseconds: metrics.totalMilliseconds ?? -1])
        // `-1` means a custom/test transport could not provide this phase.
        // The delegate-backed production transport records response headers,
        // first body byte, body receive, and full transport duration separately.
        logger.notice(
            "transport_complete segments=\(segmentCount, privacy: .public) response_bytes=\(responseBytes, privacy: .public) status_code=\(statusCode, privacy: .public) status_class=\(statusClass, privacy: .public) response_headers_ms=\(metrics.responseHeadersMilliseconds ?? -1, format: .fixed(precision: 1), privacy: .public) first_body_byte_ms=\(metrics.firstBodyByteMilliseconds ?? -1, format: .fixed(precision: 1), privacy: .public) body_ms=\(metrics.bodyMilliseconds ?? -1, format: .fixed(precision: 1), privacy: .public) total_ms=\(metrics.totalMilliseconds ?? -1, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    static func batchGroupCompleted(
        batchCount: Int,
        totalSegments: Int,
        sourceBytes: Int,
        elapsedMilliseconds: Double,
        combinedSource: TranslationResultSource
    ) {
        TranslationPerformanceFileLog.record(.batch, fields: [.batchCount: Double(batchCount), .segments: Double(totalSegments),
            .sourceBytes: Double(sourceBytes), .elapsedMilliseconds: elapsedMilliseconds, .source: sourceCode(combinedSource)])
        logger.notice(
            "batch_group_complete batch_count=\(batchCount, privacy: .public) total_segments=\(totalSegments, privacy: .public) source_bytes=\(sourceBytes, privacy: .public) elapsed_ms=\(elapsedMilliseconds, format: .fixed(precision: 1), privacy: .public) combined_source=\(combinedSource.rawValue, privacy: .public)"
        )
    }

    private static func sourceCode(_ source: TranslationResultSource) -> Double {
        switch source {
        case .network: 0
        case .memoryCache: 1
        case .diskCache: 2
        }
    }

    static func elapsedMilliseconds(since uptime: TimeInterval) -> Double {
        max(
            0,
            (ProcessInfo.processInfo.systemUptime - uptime) * 1_000
        )
    }

    static func sourceBytes(
        in request: RemoteTranslationRequest
    ) -> Int {
        request.segments.reduce(into: 0) {
            $0 += $1.text.utf8.count
        }
    }
}

enum MetadataTranslationPriority: Int, Sendable {
    case sourceMenuTitle = 2
    case mangaTitle
    case description
    case author
    case tag
}

enum TranslationRequestPriority: Sendable {
    case foreground
    case prefetch
    case metadata(MetadataTranslationPriority)
    case promotable(TranslationRequestPromotion)
    case shared(TranslationRequestPrioritySet)

    var isForeground: Bool {
        switch self {
        case .foreground: true
        case .prefetch, .metadata: false
        case .promotable(let promotion): promotion.isForeground
        case .shared(let priorities): priorities.schedulingRank == 0
        }
    }

    var schedulingRank: Int {
        switch self {
        case .foreground: 0
        case .prefetch: 1
        case .promotable(let promotion): promotion.isForeground ? 0 : 1
        case .shared(let priorities): priorities.schedulingRank
        case .metadata(let priority): priority.rawValue
        }
    }
}

/// Only the provider's shared worker owns this aggregate; consumer priorities
/// point to original callers, never back to the aggregate itself.
final class TranslationRequestPrioritySet: @unchecked Sendable {
    private let lock = NSLock()
    private var consumers: [UUID: TranslationRequestPriority] = [:]

    var schedulingRank: Int {
        let priorities = lock.withLock { Array(consumers.values) }
        return priorities.map(\.schedulingRank).min() ?? Int.max
    }

    func set(_ priority: TranslationRequestPriority, for consumer: UUID) {
        lock.withLock { consumers[consumer] = priority }
    }

    func remove(_ consumer: UUID) { _ = lock.withLock { consumers.removeValue(forKey: consumer) } }
}

/// Shared by one page's queued provider requests. Promotion never cancels or
/// duplicates an in-flight request.
final class TranslationRequestPromotion: @unchecked Sendable {
    private let lock = NSLock()
    private var foreground = false

    var isForeground: Bool { lock.withLock { foreground } }

    func promote() { lock.withLock { foreground = true } }
}

/// Page work precedes metadata; each priority remains FIFO.
/// All priorities share the configured total request cap.
actor TranslationProviderRequestLimiter {
    private struct Waiter {
        let id: UUID
        let priority: TranslationRequestPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var maximumConcurrentRequests: Int
    private var activeRequests = 0
    private var waiters: [Waiter] = []
    var queuedRequestCount: Int { waiters.count }

    init(maximumConcurrentRequests: Int) {
        precondition(maximumConcurrentRequests > 0)
        self.maximumConcurrentRequests = maximumConcurrentRequests
    }

    func setMaximumConcurrentRequests(_ value: Int) {
        precondition(value > 0)
        guard !Task.isCancelled else { return }
        maximumConcurrentRequests = value
        admitWaiters()
    }

    func withPermit<Value: Sendable>(
        priority: TranslationRequestPriority = .foreground,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let waiterID = UUID()
        try await acquire(waiterID: waiterID, priority: priority)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(waiterID: UUID, priority: TranslationRequestPriority) async throws {
        try Task.checkCancellation()
        if activeRequests < maximumConcurrentRequests {
            activeRequests += 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, priority: priority, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        activeRequests = max(0, activeRequests - 1)
        admitWaiters()
    }

    private func admitWaiters() {
        // Lowering a live limit lets existing requests drain before admitting more.
        while activeRequests < maximumConcurrentRequests, !waiters.isEmpty {
            let index = waiters.indices.min {
                let left = waiters[$0].priority.schedulingRank
                let right = waiters[$1].priority.schedulingRank
                return left == right ? $0 < $1 : left < right
            } ?? 0
            activeRequests += 1
            waiters.remove(at: index).continuation.resume()
        }
    }
}

actor TranslationService {
    private static let maximumStructuredOutputRetries = 5
    /// Split repair already spent the parent's attempt. Five retries for every
    /// leaf let a persistently malformed provider turn one 64-segment batch
    /// into ~450 serial calls (minutes of backoff); descendants retry once.
    static let splitDescendantMaximumRetries = 1
    private static let structuredOutputRetryDelaysNanoseconds: [UInt64] = [
        300_000_000,
        500_000_000,
        1_000_000_000,
        1_000_000_000,
        2_000_000_000,
    ]

    private struct InFlightRequest {
        let id: UUID
        let cacheStorageGeneration: UInt64
        let networkTask: Task<Void, Never>
        let priorities: TranslationRequestPrioritySet
        var waiters:
            [UUID: CheckedContinuation<RemoteTranslationBatchResult, Error>]
    }

    private let client: RemoteTranslating
    private let cache: TranslationCache
    private let providerRequestLimiter: TranslationProviderRequestLimiter?
    private var inFlight: [TranslationCacheKey: InFlightRequest] = [:]
    var inFlightConsumerCount: Int { inFlight.values.reduce(0) { $0 + $1.waiters.count } }
    private var purgeGeneration: UInt64 = 0
    private var purgeTask: Task<Void, Error>?

    init(
        client: RemoteTranslating,
        cache: TranslationCache,
        providerRequestLimiter: TranslationProviderRequestLimiter? = nil
    ) {
        self.client = client
        self.cache = cache
        self.providerRequestLimiter = providerRequestLimiter
    }

    /// Reads matching translations without entering provider admission.
    func cachedResult(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult? {
        try Task.checkCancellation()
        try request.validate()
        let canonical = request.canonicalizedForTranslationSemantics()
        let key = TranslationCacheKey(configuration: configuration,
                                      endpoint: try configuration.validatedEndpoint(), request: canonical.request)
        while true {
            try Task.checkCancellation()
            let admittedGeneration = purgeGeneration
            if let purgeTask { try await purgeTask.value; continue }
            let lookup = await cache.lookup(for: key)
            try Task.checkCancellation()
            guard admittedGeneration == purgeGeneration, purgeTask == nil else { continue }
            guard let cached = lookup.value,
                  !ReaderTranslationLanguageFilter.containsWrongLanguage(cached.translations, request: canonical.request) else { return nil }
            return try canonical.restoringCallerSegmentIDs(in: RemoteTranslationBatchResult(
                translations: cached.translations, source: cached.source, providerRequestID: nil
            ))
        }
    }

    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        priority: TranslationRequestPriority = .foreground
    ) async throws -> RemoteTranslationBatchResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let segmentCount = request.segments.count
        let sourceBytes = TranslationPerformanceDiagnostics.sourceBytes(
            in: request
        )
        try Task.checkCancellation()
        try request.validate()
        let canonicalRequest =
            request.canonicalizedForTranslationSemantics()
        let endpoint = try configuration.validatedEndpoint()
        let key = TranslationCacheKey(
            configuration: configuration,
            endpoint: endpoint,
            request: canonicalRequest.request
        )
        var cacheStorageGeneration: UInt64 = 0
        var purgeAdmissionGeneration: UInt64 = 0

        // A user purge is an admission barrier as well as a storage operation.
        // Recheck its epoch after the cache actor hop so a request cannot pass
        // the gate just before a concurrent purge starts.
        while true {
            try Task.checkCancellation()
            let admittedGeneration = purgeGeneration
            if let purgeTask {
                try await purgeTask.value
                continue
            }

            // Cache storage is an optimization. A corrupt or unavailable cache
            // must not disable translation; the cache retains its own safe
            // diagnostic.
            let lookup = await cache.lookup(for: key)
            try Task.checkCancellation()
            guard admittedGeneration == purgeGeneration,
                  purgeTask == nil
            else {
                continue
            }
            if let cached = lookup.value, !ReaderTranslationLanguageFilter.containsWrongLanguage(cached.translations, request: canonicalRequest.request) {
                let canonicalResult = RemoteTranslationBatchResult(
                    translations: cached.translations,
                    source: cached.source,
                    providerRequestID: nil
                )
                let result = try canonicalRequest.restoringCallerSegmentIDs(
                    in: canonicalResult
                )
                TranslationPerformanceDiagnostics.serviceCompleted(
                    source: result.source,
                    segmentCount: segmentCount,
                    sourceBytes: sourceBytes,
                    elapsedMilliseconds:
                        TranslationPerformanceDiagnostics
                            .elapsedMilliseconds(since: startedAt)
                )
                return result
            }
            cacheStorageGeneration = lookup.storageGeneration
            purgeAdmissionGeneration = admittedGeneration
            break
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let canonicalResult: RemoteTranslationBatchResult =
                try await withCheckedThrowingContinuation {
                    (
                        continuation:
                            CheckedContinuation<RemoteTranslationBatchResult, Error>
                    ) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                register(
                    waiterID: waiterID,
                    continuation: continuation,
                    key: key,
                    request: canonicalRequest.request,
                    configuration: configuration,
                    cacheStorageGeneration: cacheStorageGeneration,
                    purgeAdmissionGeneration: purgeAdmissionGeneration,
                    priority: priority
                )
            }
            try Task.checkCancellation()
            let result = try canonicalRequest.restoringCallerSegmentIDs(
                in: canonicalResult
            )
            TranslationPerformanceDiagnostics.serviceCompleted(
                source: result.source,
                segmentCount: segmentCount,
                sourceBytes: sourceBytes,
                elapsedMilliseconds:
                    TranslationPerformanceDiagnostics
                        .elapsedMilliseconds(since: startedAt)
            )
            return result
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, for: key)
            }
        }
    }

    /// Cancels every pre-boundary request and purges the backing cache while
    /// preventing newly admitted translations from racing the deletion. Calls
    /// arriving during the purge wait for this task before cache lookup or
    /// provider registration.
    func purgeCache() async throws {
        if let purgeTask {
            try await purgeTask.value
            return
        }

        purgeGeneration &+= 1
        let generation = purgeGeneration
        cancelAllRequests()
        let task = Task { [cache, weak self] in
            do {
                try await cache.purgeAll()
                await self?.finishPurge(generation: generation)
            } catch {
                await self?.finishPurge(generation: generation)
                throw error
            }
        }
        purgeTask = task
        try await task.value
    }

    private func finishPurge(generation: UInt64) {
        if purgeGeneration == generation {
            purgeTask = nil
        }
    }

    private func cancelAllRequests() {
        let requests = Array(inFlight.values)
        inFlight.removeAll(keepingCapacity: false)
        for request in requests {
            request.networkTask.cancel()
            for continuation in request.waiters.values {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func register(
        waiterID: UUID,
        continuation: CheckedContinuation<RemoteTranslationBatchResult, Error>,
        key: TranslationCacheKey,
        request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        cacheStorageGeneration: UInt64,
        purgeAdmissionGeneration: UInt64,
        priority: TranslationRequestPriority
    ) {
        guard purgeAdmissionGeneration == purgeGeneration,
              purgeTask == nil
        else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if var existing = inFlight[key] {
            existing.priorities.set(priority, for: waiterID)
            existing.waiters[waiterID] = continuation
            inFlight[key] = existing
            return
        }

        let requestID = UUID()
        let priorities = TranslationRequestPrioritySet()
        priorities.set(priority, for: waiterID)
        let networkTask = Task { [client, providerRequestLimiter] in
            do {
                let result = try await Self.requestProvider(
                    client: client,
                    request: request,
                    configuration: configuration,
                    providerRequestLimiter: providerRequestLimiter,
                    priority: .shared(priorities)
                )
                await finish(
                    key: key,
                    requestID: requestID,
                    result: result
                )
            } catch {
                finish(
                    key: key,
                    requestID: requestID,
                    error: error
                )
            }
        }
        inFlight[key] = InFlightRequest(
            id: requestID,
            cacheStorageGeneration: cacheStorageGeneration,
            networkTask: networkTask,
            priorities: priorities,
            waiters: [waiterID: continuation]
        )
    }

    private static func requestProvider(
        client: RemoteTranslating,
        request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        providerRequestLimiter: TranslationProviderRequestLimiter?,
        priority: TranslationRequestPriority,
        allowsParallelSplit: Bool = true,
        maximumRetries: Int = maximumStructuredOutputRetries
    ) async throws -> RemoteTranslationBatchResult {
        var attempt = 0
        while true {
            attempt += 1
            let attemptStartedAt = ProcessInfo.processInfo.systemUptime
            let segmentCount = request.segments.count
            let sourceBytes = TranslationPerformanceDiagnostics.sourceBytes(
                in: request
            )
            do {
                let result: RemoteTranslationBatchResult
                if let providerRequestLimiter {
                    result = try await providerRequestLimiter.withPermit(priority: priority) {
                        TranslationPerformanceDiagnostics.clientPhaseCompleted(
                            phase: "provider_queue",
                            segmentCount: segmentCount,
                            elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: attemptStartedAt)
                        )
                        return try await performProviderAttempt(
                            client: client, request: request, configuration: configuration)
                    }
                } else {
                    result = try await performProviderAttempt(
                        client: client, request: request, configuration: configuration)
                }
                TranslationPerformanceDiagnostics
                    .providerAttemptCompleted(
                        attempt: attempt,
                        segmentCount: segmentCount,
                        sourceBytes: sourceBytes,
                        elapsedMilliseconds:
                            TranslationPerformanceDiagnostics
                                .elapsedMilliseconds(
                                    since: attemptStartedAt
                                )
                    )
                return result
            } catch {
                if case let RemoteTranslationError.invalidResponse(reason) = error {
                    // Only locally defined parser reasons; never record response bodies or text.
                    let knownReasons = [
                        "response body is not valid JSON", "response root must be a JSON object",
                        "the Responses API returned an error object", "the Responses API response is incomplete",
                        "the Responses API did not complete successfully", "missing Responses API output array",
                        "a Responses API output item did not complete", "expected exactly one Responses API output_text item",
                        "missing chat completions choices array", "expected exactly one chat completion choice at index zero",
                        "the chat completion was truncated", "the chat completion did not finish with text",
                        "expected exactly one text content part", "missing chat completion message content",
                        "structured translation is not valid JSON", "structured translation does not match the required schema",
                        "structured translation contains an invalid segment", "structured translation is missing one or more segment IDs",
                        "translation is still in source language"
                    ]
                    ReaderTranslationDiagnostics.record("api_invalid_response", count: attempt,
                                                        code: knownReasons.firstIndex(of: reason).map { $0 + 1 } ?? 0)
                }
                // Page batches have one primary call, including malformed or
                // untranslated answers. Non-page callers retain format
                // repair; HTTP/transport failures already propagate unchanged.
                let allowsFormatRepair = request.translatesPageLettering != true
                let isRepairable = Self.isStructuredOutputRetryable(error)
                if allowsFormatRepair, isRepairable, attempt == 1, request.segments.count > 1 {
                    // Split on the first malformed multi-segment answer to avoid
                    // another full-batch round trip. Reduce the problem while keeping
                    // the original IDs, context, validation and cancellation.
                    try Task.checkCancellation()
                    ReaderTranslationDiagnostics.record("api_batch_split", count: request.segments.count)
                    let middle = request.segments.count / 2
                    let parts = [Array(request.segments[..<middle]), Array(request.segments[middle...])].map { segments in
                        var part = RemoteTranslationRequest(sourceLanguage: request.sourceLanguage,
                            targetLanguage: request.targetLanguage, segments: segments)
                        part.copyImageRepresentation(from: request)
                        part.filtersSFX = request.filtersSFX
                        part.filtersBackground = request.filtersBackground
                        part.translatesPageLettering = request.translatesPageLettering
                        return part
                    }
                    let recovered: [RemoteTranslatedSegment]
                    if allowsParallelSplit, providerRequestLimiter != nil {
                        // Only the first repair branches concurrently. Descendants
                        // are serial so malformed responses cannot grow a task tree.
                        recovered = try await withThrowingTaskGroup(of: (Int, [RemoteTranslatedSegment]).self) { group in
                            for (index, part) in parts.enumerated() {
                                group.addTask {
                                    let value = try await requestProvider(client: client, request: part, configuration: configuration,
                                        providerRequestLimiter: providerRequestLimiter, priority: priority, allowsParallelSplit: false,
                                        maximumRetries: splitDescendantMaximumRetries)
                                    return (index, value.translations)
                                }
                            }
                            var values = [[RemoteTranslatedSegment]](repeating: [], count: parts.count)
                            for try await (index, translations) in group { values[index] = translations }
                            return values.flatMap { $0 }
                        }
                    } else {
                        var values: [RemoteTranslatedSegment] = []
                        for part in parts {
                            let value = try await requestProvider(client: client, request: part, configuration: configuration,
                                providerRequestLimiter: providerRequestLimiter, priority: priority, allowsParallelSplit: false,
                                maximumRetries: splitDescendantMaximumRetries)
                            values.append(contentsOf: value.translations)
                        }
                        recovered = values
                    }
                    return RemoteTranslationBatchResult(translations: recovered, source: .network, providerRequestID: nil)
                }
                let willRetry =
                    allowsFormatRepair &&
                    isRepairable &&
                    attempt <= min(maximumRetries, maximumStructuredOutputRetries)
                TranslationPerformanceDiagnostics.providerAttemptFailed(
                    attempt: attempt,
                    reason:
                        isRepairable
                        ? "invalid_structured_response"
                        : "remote_error",
                    willRetry: willRetry,
                    segmentCount: segmentCount,
                    sourceBytes: sourceBytes,
                    elapsedMilliseconds:
                        TranslationPerformanceDiagnostics
                            .elapsedMilliseconds(
                                since: attemptStartedAt
                            )
                )
                guard willRetry else {
                    throw error
                }
                // Retry malformed or incomplete structured output up to five
                // times after the initial request, but never retry
                // credentials, policy, refusals, HTTP failures, transport
                // failures, or cancellation.
                try Task.checkCancellation()
                try await Task.sleep(
                    nanoseconds:
                        structuredOutputRetryDelaysNanoseconds[attempt - 1]
                )
            }
        }
    }

    /// Keep provider queueing out of the client duration. The client includes request encoding/transport/validation,
    /// whose nested phases further separate local work from server response wait.
    private static func performProviderAttempt(
        client: RemoteTranslating,
        request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult {
        try Task.checkCancellation()
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            TranslationPerformanceDiagnostics.clientPhaseCompleted(
                phase: "provider_client",
                segmentCount: request.segments.count,
                elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: startedAt)
            )
        }
        let result = try await client.translate(request, configuration: configuration)
        guard !ReaderTranslationLanguageFilter.containsWrongLanguage(result.translations, request: request) else {
            throw RemoteTranslationError.invalidResponse("translation is still in source language")
        }
        return result
    }

    private static func isStructuredOutputRetryable(_ error: Error) -> Bool {
        if let remoteError = error as? RemoteTranslationError,
           case .invalidResponse = remoteError
        {
            return true
        }
        if error is DecodingError {
            return true
        }
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain &&
            cocoaError.code == CocoaError.propertyListReadCorrupt.rawValue
    }

    private func cancelWaiter(_ waiterID: UUID, for key: TranslationCacheKey) {
        guard var request = inFlight[key],
              let continuation = request.waiters.removeValue(forKey: waiterID)
        else {
            return
        }
        request.priorities.remove(waiterID)
        continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty {
            request.networkTask.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = request
        }
    }

    private func finish(
        key: TranslationCacheKey,
        requestID: UUID,
        result: RemoteTranslationBatchResult
    ) async {
        guard let request = inFlight[key],
              request.id == requestID
        else {
            return
        }
        await cache.insert(
            result.translations,
            for: key,
            admittedStorageGeneration: request.cacheStorageGeneration
        )
        guard let completed = inFlight[key],
              completed.id == requestID
        else {
            return
        }
        inFlight.removeValue(forKey: key)
        for continuation in completed.waiters.values {
            continuation.resume(returning: result)
        }
    }

    private func finish(
        key: TranslationCacheKey,
        requestID: UUID,
        error: Error
    ) {
        guard let request = inFlight[key],
              request.id == requestID
        else {
            return
        }
        inFlight.removeValue(forKey: key)
        for continuation in request.waiters.values {
            continuation.resume(throwing: error)
        }
    }
}

enum BoundedTranslationBatchExecutor {
    private struct IndexedBatchResult: Sendable {
        let index: Int
        let result: RemoteTranslationBatchResult
    }

    static let allowedMaximumConcurrentRequests = 64

    /// Runs an already-bounded request group concurrently while retaining the
    /// original result indices. Cache hits complete first; smaller batches then
    /// enter limited provider slots first. Throwing task-group semantics cancel
    /// siblings on failure and never return a partial group.
    static func translate(
        _ requests: [RemoteTranslationRequest],
        configuration: RemoteTranslationConfiguration,
        service: TranslationService,
        maximumConcurrentRequests: Int,
        priority: TranslationRequestPriority
    ) async throws -> [RemoteTranslationBatchResult] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let totalSegments = requests.reduce(into: 0) {
            $0 += $1.segments.count
        }
        let sourceBytes = requests.reduce(into: 0) {
            $0 += TranslationPerformanceDiagnostics.sourceBytes(in: $1)
        }
        let concurrency = min(
            max(
                1,
                min(
                    allowedMaximumConcurrentRequests,
                    maximumConcurrentRequests
                )
            ),
            requests.count
        )
        var cachedResults = Array<RemoteTranslationBatchResult?>(repeating: nil, count: requests.count)
        for index in requests.indices {
            cachedResults[index] = try await service.cachedResult(requests[index], configuration: configuration)
        }
        let submissionOrder = requests.indices.filter { cachedResults[$0] == nil }.sorted { left, right in
            let leftCount = requests[left].segments.count
            let rightCount = requests[right].segments.count
            if leftCount != rightCount {
                return leftCount < rightCount
            }
            let leftBytes = TranslationPerformanceDiagnostics.sourceBytes(
                in: requests[left]
            )
            let rightBytes = TranslationPerformanceDiagnostics.sourceBytes(
                in: requests[right]
            )
            if leftBytes != rightBytes {
                return leftBytes < rightBytes
            }
            return left < right
        }
        let results = try await withThrowingTaskGroup(
            of: IndexedBatchResult.self,
            returning: [RemoteTranslationBatchResult].self
        ) { group in
            defer { group.cancelAll() }
            var nextSubmission = 0
            var active = 0
            var completedCount = cachedResults.compactMap { $0 }.count
            var orderedResults = cachedResults

            while true {
                try Task.checkCancellation()
                let limit = priority.isForeground ? concurrency
                    : min(2, max(1, maximumConcurrentRequests - 1))
                while active < limit, nextSubmission < submissionOrder.count {
                    let index = submissionOrder[nextSubmission]
                    nextSubmission += 1
                    active += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return try await IndexedBatchResult(
                            index: index,
                            result: service.translate(
                                requests[index],
                                configuration: configuration,
                                priority: priority
                            )
                        )
                    }
                }
                if completedCount == requests.count { break }
                guard let completed = try await group.next() else { break }
                active -= 1
                completedCount += 1
                orderedResults[completed.index] = completed.result
            }

            try Task.checkCancellation()
            return try orderedResults.enumerated().map { index, result in
                guard let result else {
                    throw RemoteTranslationError.invalidResponse(
                        "translation batch \(index) did not complete"
                    )
                }
                return result
            }
        }
        if let combinedSource = results.combinedTranslationSource {
            TranslationPerformanceDiagnostics.batchGroupCompleted(
                batchCount: requests.count,
                totalSegments: totalSegments,
                sourceBytes: sourceBytes,
                elapsedMilliseconds:
                    TranslationPerformanceDiagnostics.elapsedMilliseconds(
                        since: startedAt
                    ),
                combinedSource: combinedSource
            )
        }
        return results
    }
}
