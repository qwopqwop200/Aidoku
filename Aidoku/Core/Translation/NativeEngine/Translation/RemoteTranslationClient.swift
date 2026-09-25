// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

/// Receives validated translations of a batch while its response streams.
/// Calls arrive in response order, each segment ID at most once per request
/// attempt. They are provisional: the final batch result is authoritative.
typealias RemoteTranslationPartialHandler = @Sendable ([RemoteTranslatedSegment]) -> Void

protocol RemoteTranslating: Sendable {
    func prepare(configuration: RemoteTranslationConfiguration) async

    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult

    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        onPartial: RemoteTranslationPartialHandler?
    ) async throws -> RemoteTranslationBatchResult
}

extension RemoteTranslating {
    func prepare(configuration: RemoteTranslationConfiguration) async {}

    /// Non-streaming clients only publish their final result.
    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        onPartial: RemoteTranslationPartialHandler?
    ) async throws -> RemoteTranslationBatchResult {
        try await translate(request, configuration: configuration)
    }
}

/// Per-endpoint record of whether a custom server accepts
/// the compact structured wire format. Only a server that identified itself as
/// a recent vLLM in a successful metadata or standard response is tried; a rejection or
/// an unverified malformed answer permanently returns it to the standard
/// structured request for this client.
final class CompactChatOutputRegistry: @unchecked Sendable {
    enum State: Equatable { case unknown, eligible, verified, unsupported }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private var metadataAttempts: [String: TimeInterval] = [:]
    private var metadataInFlight: [String: TimeInterval] = [:]
    private struct MetadataWaiter {
        let key: String
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private var metadataWaiters: [UUID: MetadataWaiter] = [:]
    var metadataWaiterCount: Int {
        lock.lock(); defer { lock.unlock() }
        return metadataWaiters.count
    }

    func beginMetadataProbe(endpoint: String, account: String, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard (states[endpoint] ?? .unknown) == .unknown else { return false }
        let key = endpoint + "\n" + account
        guard metadataInFlight[key] == nil else { return false }
        guard now - (metadataAttempts[key] ?? -.infinity) >= 300 else { return false }
        metadataAttempts = metadataAttempts.filter { now - $0.value < 300 }
        guard metadataAttempts.count < 32 else { return false }
        metadataAttempts[key] = now
        metadataInFlight[key] = now
        return true
    }

    func finishMetadataProbe(endpoint: String, account: String) {
        let key = endpoint + "\n" + account
        lock.lock()
        metadataInFlight.removeValue(forKey: key)
        let completed = metadataWaiters.filter { $0.value.key == key }
        for id in completed.keys { metadataWaiters.removeValue(forKey: id) }
        lock.unlock()
        for waiter in completed.values {
            waiter.timeout.cancel()
            waiter.continuation.resume()
        }
    }

    /// Cached OCR can finish before metadata. Give an already running probe
    /// at most 80 ms from its start, shared by all callers, not 80 ms per call.
    /// Late arrivals and endpoints without a probe never wait.
    func waitForMetadata(endpoint: String, account: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let key = endpoint + "\n" + account
                let remaining = metadataInFlight[key].map { 0.08 - (ProcessInfo.processInfo.systemUptime - $0) } ?? 0
                guard (states[endpoint] ?? .unknown) == .unknown, remaining > 0, metadataWaiters.count < 64 else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(min(0.08, remaining) * 1_000_000_000)) }
                    catch { return }
                    self?.finishMetadataWaiter(id, cancelled: false)
                }
                metadataWaiters[id] = MetadataWaiter(key: key, continuation: continuation, timeout: timeout)
                lock.unlock()
            }
        } onCancel: {
            self.finishMetadataWaiter(id, cancelled: true)
        }
        try Task.checkCancellation()
    }

    private func finishMetadataWaiter(_ id: UUID, cancelled: Bool) {
        lock.lock()
        let waiter = metadataWaiters.removeValue(forKey: id)
        lock.unlock()
        guard let waiter else { return }
        waiter.timeout.cancel()
        if cancelled { waiter.continuation.resume(throwing: CancellationError()) }
        else { waiter.continuation.resume() }
    }

    func state(for key: String) -> State {
        lock.lock(); defer { lock.unlock() }
        return states[key] ?? .unknown
    }

    func markEligible(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        if (states[key] ?? .unknown) == .unknown { states[key] = .eligible }
    }

    func markVerified(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        if states[key] == .eligible { states[key] = .verified }
    }

    func markUnsupported(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        states[key] = .unsupported
    }
}

private actor CustomProtocolPreferenceRegistry {
    struct Key: Hashable, Sendable {
        let provider: RemoteTranslationProvider
        let endpointNamespace: String
    }

    enum Selection: Sendable {
        case preferred(RemoteTranslationProtocol)
        case probeLeader(token: UUID, configured: RemoteTranslationProtocol)
        case probeFollower(token: UUID, configured: RemoteTranslationProtocol)
    }

    private struct Entry {
        var successfulPreference: RemoteTranslationProtocol?
        var probeToken: UUID?
        var candidateProtocol: RemoteTranslationProtocol?
    }

    private var entries: [Key: Entry] = [:]

    func begin(
        key: Key,
        configured: RemoteTranslationProtocol
    ) -> Selection {
        var entry = entries[key] ?? Entry()
        if let successfulPreference = entry.successfulPreference {
            return .preferred(successfulPreference)
        }
        if let probeToken = entry.probeToken {
            return .probeFollower(
                token: probeToken,
                configured: configured
            )
        }
        let token = UUID()
        entry.probeToken = token
        entry.candidateProtocol = nil
        entries[key] = entry
        return .probeLeader(token: token, configured: configured)
    }

    func resolvedProtocol(
        key: Key,
        probeToken: UUID
    ) -> RemoteTranslationProtocol? {
        guard let entry = entries[key] else { return nil }
        if let successfulPreference = entry.successfulPreference {
            return successfulPreference
        }
        guard entry.probeToken == probeToken else { return nil }
        return entry.candidateProtocol
    }

    func reportUnsupported(
        key: Key,
        failedProtocol: RemoteTranslationProtocol,
        alternateProtocol: RemoteTranslationProtocol
    ) {
        var entry = entries[key] ?? Entry()
        if entry.successfulPreference == failedProtocol {
            entry.successfulPreference = nil
        }
        entry.candidateProtocol = alternateProtocol
        entries[key] = entry
    }

    func reportSuccess(
        key: Key,
        apiProtocol: RemoteTranslationProtocol
    ) {
        entries[key] = Entry(
            successfulPreference: apiProtocol,
            probeToken: nil,
            candidateProtocol: nil
        )
    }

    func finishProbeFailure(key: Key, token: UUID?) {
        guard let token,
              var entry = entries[key],
              entry.probeToken == token,
              entry.successfulPreference == nil
        else {
            return
        }
        entry.probeToken = nil
        entry.candidateProtocol = nil
        entries[key] = entry
    }
}

final class RemoteTranslationClient: RemoteTranslating, @unchecked Sendable {
    /// A short grace window lets one request discover a fast 404/405/501 and
    /// publish the alternate endpoint before sibling batches duplicate that
    /// failed probe. If the configured endpoint is valid but slow, siblings
    /// resume after the grace window and retain normal provider parallelism.
    private static let protocolProbeGraceNanoseconds: UInt64 = 40_000_000

    private let credentialStore: TranslationCredentialProviding
    private let transport: TranslationHTTPTransport
    private let protocolPreferences = CustomProtocolPreferenceRegistry()
    private let imageSupport: TranslationImageSupport
    private let rechecksImageSupport: Bool
    let compactOutput = CompactChatOutputRegistry()
    private struct UnsupportedImageInput: Error {}

    init(
        credentialStore: TranslationCredentialProviding =
            KeychainTranslationCredentialStore(),
        transport: TranslationHTTPTransport = BoundedURLSessionTransport(),
        imageSupport: TranslationImageSupport = .shared,
        rechecksImageSupport: Bool = false
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.imageSupport = imageSupport
        self.rechecksImageSupport = rechecksImageSupport
    }

    /// Start alongside OCR; translation only gives an in-flight probe a short grace. A metadata
    /// hint only makes compact output eligible; strict decoding and fallback
    /// still verify the actual protocol on its first translation.
    func prepare(configuration: RemoteTranslationConfiguration) async {
        guard !Task.isCancelled, configuration.provider == .custom,
              configuration.apiProtocol != .responses || configuration.reasoningEffort == .none,
              let endpoint = try? configuration.validatedEndpoint(),
              compactOutput.beginMetadataProbe(endpoint: endpoint.absoluteString,
                  account: configuration.credentialAccount, now: ProcessInfo.processInfo.systemUptime)
        else { return }
        defer { compactOutput.finishMetadataProbe(endpoint: endpoint.absoluteString, account: configuration.credentialAccount) }
        do {
            let secret = try credentialStore.secret(for: configuration.credentialAccount)
            guard !secret.isEmpty, secret.utf8.count <= KeychainTranslationCredentialStore.maximumSecretBytes,
                  !secret.contains("\r"), !secret.contains("\n"), !secret.contains("\0") else { return }
            var base = endpoint.deletingLastPathComponent()
            if configuration.apiProtocol == .chatCompletions { base.deleteLastPathComponent() }
            var request = URLRequest(url: base.appendingPathComponent("models"),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
            request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response = try await transport.data(for: request, maximumResponseBytes: 64 * 1024,
                                                    bypassesProxy: endpoint.scheme == "http")
            try Task.checkCancellation()
            guard (200...299).contains(response.response.statusCode),
                  TranslationHTTPCodec.identifiesStructuredOutputServer(responseBody: Data(),
                    apiProtocol: configuration.apiProtocol,
                    vllmVersionHeader: response.response.value(forHTTPHeaderField: "X-vLLM-Version")) else { return }
            compactOutput.markEligible(endpoint.absoluteString)
            ReaderTranslationDiagnostics.record("api_compact_metadata_ready")
        } catch {
            // Metadata is optional. Ordinary translation retains its existing
            // credential errors, timeout policy and portable response format.
        }
    }

    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult {
        try await translate(request, configuration: configuration, onPartial: nil)
    }

    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        onPartial: RemoteTranslationPartialHandler?
    ) async throws -> RemoteTranslationBatchResult {
        try Task.checkCancellation()
        try request.validate()
        var effectiveRequest = request
        if !rechecksImageSupport, imageSupport.status(for: configuration) == .unsupported {
            effectiveRequest.imageJPEG = nil
        }
        do {
            let result = try await translateUsingSupportedProtocol(effectiveRequest, configuration: configuration, onPartial: onPartial)
            if effectiveRequest.imageJPEG != nil {
                imageSupport.record(.supported, for: configuration)
            }
            return result
        } catch is UnsupportedImageInput {
            try Task.checkCancellation()
            imageSupport.record(.unsupported, for: configuration)
            effectiveRequest.imageJPEG = nil // Also clears the prepared base64 data URL.
            return try await translateUsingSupportedProtocol(effectiveRequest, configuration: configuration, onPartial: onPartial)
        }
    }

    private func translateUsingSupportedProtocol(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        onPartial: RemoteTranslationPartialHandler?
    ) async throws -> RemoteTranslationBatchResult {
        guard configuration.provider == .custom else {
            return try await translateOnce(
                request,
                configuration: configuration,
                onPartial: onPartial
            )
        }

        let key = try Self.protocolPreferenceKey(for: configuration)
        let selection = await protocolPreferences.begin(
            key: key,
            configured: configuration.apiProtocol
        )
        let preferredProtocol: RemoteTranslationProtocol
        let probeToken: UUID?
        switch selection {
        case let .preferred(apiProtocol):
            preferredProtocol = apiProtocol
            probeToken = nil
        case let .probeLeader(token, configured):
            preferredProtocol = configured
            probeToken = token
        case let .probeFollower(token, configured):
            try await Task.sleep(
                nanoseconds: Self.protocolProbeGraceNanoseconds
            )
            preferredProtocol = await protocolPreferences.resolvedProtocol(
                key: key,
                probeToken: token
            ) ?? configured
            probeToken = token
        }

        let preferredConfiguration = try Self.configuration(
            configuration,
            replacingAPIProtocol: preferredProtocol
        )
        do {
            let result = try await translateOnce(
                request,
                configuration: preferredConfiguration,
                onPartial: onPartial
            )
            await protocolPreferences.reportSuccess(
                key: key,
                apiProtocol: preferredProtocol
            )
            return result
        } catch let error as RemoteTranslationError {
            guard Self.isUnsupportedEndpoint(error) else {
                await protocolPreferences.finishProbeFailure(
                    key: key,
                    token: probeToken
                )
                throw error
            }
            let alternateProtocol: RemoteTranslationProtocol =
                preferredProtocol == .responses
                    ? .chatCompletions
                    : .responses
            let alternateConfiguration = try Self.configuration(
                configuration,
                replacingAPIProtocol: alternateProtocol
            )
            await protocolPreferences.reportUnsupported(
                key: key,
                failedProtocol: preferredProtocol,
                alternateProtocol: alternateProtocol
            )
            do {
                let result = try await translateOnce(
                    request,
                    configuration: alternateConfiguration,
                    onPartial: onPartial
                )
                await protocolPreferences.reportSuccess(
                    key: key,
                    apiProtocol: alternateProtocol
                )
                return result
            } catch is UnsupportedImageInput {
                // The endpoint exists; only its image input was rejected.
                await protocolPreferences.reportSuccess(key: key, apiProtocol: alternateProtocol)
                throw UnsupportedImageInput()
            } catch {
                await protocolPreferences.finishProbeFailure(
                    key: key,
                    token: probeToken
                )
                throw error
            }
        } catch is UnsupportedImageInput {
            await protocolPreferences.reportSuccess(key: key, apiProtocol: preferredProtocol)
            throw UnsupportedImageInput()
        } catch {
            await protocolPreferences.finishProbeFailure(key: key, token: probeToken)
            throw error
        }
    }

    private func translateOnce(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        onPartial: RemoteTranslationPartialHandler?
    ) async throws -> RemoteTranslationBatchResult {
        let segmentCount = request.segments.count
        let endpointStartedAt = ProcessInfo.processInfo.systemUptime
        let endpoint = try configuration.validatedEndpoint()
        TranslationPerformanceDiagnostics.clientPhaseCompleted(
            phase: "endpoint",
            segmentCount: segmentCount,
            elapsedMilliseconds: TranslationPerformanceDiagnostics
                .elapsedMilliseconds(since: endpointStartedAt)
        )

        let keychainStartedAt = ProcessInfo.processInfo.systemUptime
        let apiKey: String
        do {
            apiKey = try credentialStore.secret(for: configuration.credentialAccount)
        } catch TranslationCredentialStoreError.notFound {
            throw RemoteTranslationError.missingCredential
        } catch {
            throw RemoteTranslationError.credentialAccessFailed
        }
        guard !apiKey.isEmpty,
              apiKey.utf8.count <= KeychainTranslationCredentialStore.maximumSecretBytes,
              !apiKey.contains("\r"),
              !apiKey.contains("\n"),
              !apiKey.contains("\0")
        else {
            throw RemoteTranslationError.credentialAccessFailed
        }
        TranslationPerformanceDiagnostics.clientPhaseCompleted(
            phase: "keychain",
            segmentCount: segmentCount,
            elapsedMilliseconds: TranslationPerformanceDiagnostics
                .elapsedMilliseconds(since: keychainStartedAt)
        )

        let compactKey = endpoint.absoluteString
        if Self.usesCompactOutput(configuration: configuration, request: request, state: .eligible) {
            try await compactOutput.waitForMetadata(endpoint: compactKey, account: configuration.credentialAccount)
        }
        let compactState = compactOutput.state(for: compactKey)
        if Self.usesCompactOutput(configuration: configuration, request: request, state: compactState) {
            do {
                let result = try await exchange(request, configuration: configuration, endpoint: endpoint, apiKey: apiKey,
                                                chatOptions: Self.compactChatOptions(configuration: configuration, request: request),
                                                onPartial: onPartial)
                compactOutput.markVerified(compactKey)
                return result.batch
            } catch let error as RemoteTranslationError {
                // Fall back once to the standard request when the server rejects
                // the compact options, or when a server that has not yet produced
                // a valid compact answer returns an unusable one.
                let rejected: Bool
                switch error {
                case let .httpStatus(status, _): rejected = status == 400 || status == 422
                case .invalidResponse: rejected = compactState == .eligible
                default: rejected = false
                }
                guard rejected else { throw error }
                compactOutput.markUnsupported(compactKey)
                ReaderTranslationDiagnostics.record("api_compact_output_fallback", count: segmentCount)
                try Task.checkCancellation()
            }
        }
        let result = try await exchange(request, configuration: configuration, endpoint: endpoint, apiKey: apiKey,
                                        chatOptions: .standard, onPartial: nil)
        if result.identifiesStructuredOutputServer, configuration.provider == .custom {
            compactOutput.markEligible(compactKey)
        }
        return result.batch
    }

    static func usesCompactOutput(
        configuration: RemoteTranslationConfiguration,
        request: RemoteTranslationRequest,
        state: CompactChatOutputRegistry.State
    ) -> Bool {
        guard configuration.provider == .custom,
              state == .eligible || state == .verified else { return false }
        // Responses grammar support is verified only for direct answers;
        // reasoning plus grammar may be incompatible on custom endpoints.
        if configuration.apiProtocol == .responses, configuration.reasoningEffort != .none {
            return false
        }
        return TranslationHTTPCodec.supportsCompactOutput(segmentIDs: request.segments.map(\.id))
    }

    static func compactChatOptions(
        configuration: RemoteTranslationConfiguration,
        request: RemoteTranslationRequest
    ) -> TranslationHTTPCodec.ChatWireOptions {
        // Responses keeps its existing buffered protocol and token policy.
        // Only Chat Completions uses the SSE decoder and max_tokens option.
        if configuration.apiProtocol == .responses {
            return .init(compactStructuredOutput: true)
        }
        return TranslationHTTPCodec.ChatWireOptions(
            compactStructuredOutput: true,
            stream: true,
            // Reasoning tokens count toward max_tokens; only cap direct answers.
            maximumOutputTokens: configuration.reasoningEffort == .none
                ? TranslationHTTPCodec.maximumOutputTokens(for: request) : nil
        )
    }

    private struct ExchangeResult {
        let batch: RemoteTranslationBatchResult
        let identifiesStructuredOutputServer: Bool
    }

    /// Streamed partial output state. URLSession delivers body bytes on its
    /// serial delegate queue; the lock only guards against observer reuse.
    private final class PartialStreamState: @unchecked Sendable {
        private let lock = NSLock()
        private var decoder = ChatCompletionStreamDecoder()
        private var scanner = StreamedTranslationItemScanner()
        private var published = Set<String>()
        private var failed = false
        private let expectedIDs: Set<String>
        private let sfxSourceTexts: [String: String]?
        private let backgroundSourceTexts: [String: String]?
        private let handler: RemoteTranslationPartialHandler

        init(request: RemoteTranslationRequest, handler: @escaping RemoteTranslationPartialHandler) {
            expectedIDs = Set(request.segments.map(\.id))
            let sources = Dictionary(uniqueKeysWithValues: request.segments.map { ($0.id, $0.text) })
            sfxSourceTexts = request.filtersSFX == true ? sources : nil
            backgroundSourceTexts = request.filtersBackground == true ? sources : nil
            self.handler = handler
        }

        func consume(_ data: Data) {
            lock.lock()
            var segments: [RemoteTranslatedSegment] = []
            if !failed {
                do {
                    for delta in try decoder.consume(data) {
                        for item in scanner.append(delta) {
                            guard let segment = TranslationHTTPCodec.streamedSegment(
                                fromItemJSON: item, expectedSegmentIDs: expectedIDs,
                                sfxSourceTexts: sfxSourceTexts, backgroundSourceTexts: backgroundSourceTexts
                            ), published.insert(segment.id).inserted else { continue }
                            segments.append(segment)
                        }
                    }
                } catch {
                    failed = true // A non-SSE body; the final parse decides.
                }
            }
            lock.unlock()
            if !segments.isEmpty { handler(segments) }
        }
    }

    private func exchange(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        endpoint: URL,
        apiKey: String,
        chatOptions: TranslationHTTPCodec.ChatWireOptions,
        onPartial: RemoteTranslationPartialHandler?
    ) async throws -> ExchangeResult {
        let segmentCount = request.segments.count
        let encodeStartedAt = ProcessInfo.processInfo.systemUptime
        var urlRequest = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.timeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(chatOptions.stream ? "text/event-stream, application/json" : "application/json",
                            forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("Aidoku-iOS/1", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = try TranslationHTTPCodec.requestBody(
            configuration: configuration,
            request: request,
            chatOptions: chatOptions
        )
        TranslationPerformanceDiagnostics.clientPhaseCompleted(
            phase: "encode",
            segmentCount: segmentCount,
            elapsedMilliseconds: TranslationPerformanceDiagnostics
                .elapsedMilliseconds(since: encodeStartedAt)
        )

        // SSE framing repeats per-chunk metadata around each token; the
        // assembled content is still bounded by the envelope parser.
        let maximumBodyBytes = chatOptions.stream
            ? configuration.maximumResponseBytes.multipliedReportingOverflow(by: 8).partialValue
            : configuration.maximumResponseBytes
        let partialState = chatOptions.stream ? onPartial.map { PartialStreamState(request: request, handler: $0) } : nil
        let bodyObserver: TranslationHTTPBodyObserver? = partialState.map { state in { data in state.consume(data) } }
        let transportResponse: TranslationHTTPResponse
        do {
            transportResponse = try await transport.data(
                for: urlRequest,
                maximumResponseBytes: maximumBodyBytes,
                bypassesProxy: endpoint.scheme == "http",
                onBodyData: bodyObserver
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RemoteTranslationError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            if Self.isPrivateTailnetEndpoint(endpoint),
               Self.isConnectivityFailure(error.code)
            {
                throw RemoteTranslationError.privateTailnetUnavailable
            }
            throw RemoteTranslationError.transport(error.code)
        } catch {
            throw RemoteTranslationError.transport(.unknown)
        }
        let body = transportResponse.data
        let response = transportResponse.response
        TranslationPerformanceDiagnostics.transportCompleted(
            segmentCount: segmentCount,
            responseBytes: body.count,
            statusClass: response.statusCode / 100,
            metrics: transportResponse.metrics
        )

        try Task.checkCancellation()
        let requestID = sanitizedRequestID(
            response.value(forHTTPHeaderField: "x-request-id")
        )
        guard (200...299).contains(response.statusCode) else {
            if request.imageJPEG != nil,
               TranslationImageSupport.isUnsupportedResponse(status: response.statusCode, body: body) {
                throw UnsupportedImageInput()
            }
            throw RemoteTranslationError.httpStatus(
                response.statusCode,
                requestID: requestID
            )
        }
        let isEventStream = chatOptions.stream && (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased().contains("text/event-stream")
        guard body.count <= (isEventStream ? maximumBodyBytes : configuration.maximumResponseBytes) else {
            throw RemoteTranslationError.responseTooLarge
        }
        let parseStartedAt = ProcessInfo.processInfo.systemUptime
        let sources = Dictionary(uniqueKeysWithValues: request.segments.map { ($0.id, $0.text) })
        let translations: [RemoteTranslatedSegment]
        if isEventStream {
            translations = try TranslationHTTPCodec.streamedChatTranslations(
                from: body,
                expectedSegmentIDs: request.segments.map(\.id),
                sfxSourceTexts: request.filtersSFX == true ? sources : nil,
                backgroundSourceTexts: request.filtersBackground == true ? sources : nil
            )
        } else {
            translations = try TranslationHTTPCodec.responseTranslations(
                from: body,
                protocol: configuration.apiProtocol,
                expectedSegmentIDs: request.segments.map(\.id),
                sfxSourceTexts: request.filtersSFX == true ? sources : nil,
                backgroundSourceTexts: request.filtersBackground == true ? sources : nil
            )
        }
        TranslationPerformanceDiagnostics.clientPhaseCompleted(
            phase: "parse",
            segmentCount: segmentCount,
            elapsedMilliseconds: TranslationPerformanceDiagnostics
                .elapsedMilliseconds(since: parseStartedAt)
        )
        try Task.checkCancellation()
        return ExchangeResult(
            batch: RemoteTranslationBatchResult(
                translations: translations,
                source: .network,
                providerRequestID: requestID
            ),
            identifiesStructuredOutputServer: !chatOptions.compactStructuredOutput && !isEventStream &&
                TranslationHTTPCodec.identifiesStructuredOutputServer(
                    responseBody: body, apiProtocol: configuration.apiProtocol,
                    vllmVersionHeader: response.value(forHTTPHeaderField: "X-vLLM-Version")
                )
        )
    }

    private static func isUnsupportedEndpoint(
        _ error: RemoteTranslationError
    ) -> Bool {
        guard case let .httpStatus(status, _) = error else { return false }
        return status == 404 || status == 405 || status == 501
    }

    private static func isPrivateTailnetEndpoint(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host?.lowercased() else { return false }
        return host.hasSuffix(".ts.net")
    }

    private static func isConnectivityFailure(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .networkConnectionLost,
             .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func protocolPreferenceKey(
        for configuration: RemoteTranslationConfiguration
    ) throws -> CustomProtocolPreferenceRegistry.Key {
        let namespace = try protocolEndpointNamespace(for: configuration)
        return CustomProtocolPreferenceRegistry.Key(
            provider: configuration.provider,
            endpointNamespace: namespace.absoluteString
        )
    }

    /// Builds a protocol-specific configuration from the normalized endpoint
    /// namespace. This also supports a custom base URL entered as a complete
    /// endpoint (for example `/v1/responses`): switching to the remembered or
    /// fallback protocol must replace that suffix instead of appending to it.
    private static func configuration(
        _ configuration: RemoteTranslationConfiguration,
        replacingAPIProtocol apiProtocol: RemoteTranslationProtocol
    ) throws -> RemoteTranslationConfiguration {
        guard apiProtocol != configuration.apiProtocol else {
            return configuration
        }
        let namespace = try protocolEndpointNamespace(for: configuration)
        return RemoteTranslationConfiguration(
            provider: configuration.provider,
            apiProtocol: apiProtocol,
            baseURL: namespace.absoluteString,
            model: configuration.model,
            credentialAccount: configuration.credentialAccount,
            credentialGeneration: configuration.credentialGeneration,
            instructions: configuration.instructions,
            reasoningEffort: configuration.reasoningEffort,
            timeout: configuration.timeout,
            maximumResponseBytes: configuration.maximumResponseBytes,
            allowsInsecureLocalhostForDevelopment:
                configuration.allowsInsecureLocalhostForDevelopment
        )
    }

    private static func protocolEndpointNamespace(
        for configuration: RemoteTranslationConfiguration
    ) throws -> URL {
        let endpoint = try configuration.validatedEndpoint()
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw RemoteTranslationError.invalidConfiguration(
                "provider endpoint could not be normalized"
            )
        }
        var segments = components.path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        switch configuration.apiProtocol {
        case .responses:
            if segments.last?.caseInsensitiveCompare("responses") == .orderedSame {
                segments.removeLast()
            }
        case .chatCompletions:
            if segments.count >= 2,
               segments[segments.count - 2].caseInsensitiveCompare("chat") ==
                .orderedSame,
               segments.last?.caseInsensitiveCompare("completions") ==
                .orderedSame
            {
                segments.removeLast(2)
            }
        }
        components.path = segments.isEmpty
            ? "/"
            : "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let namespace = components.url else {
            throw RemoteTranslationError.invalidConfiguration(
                "provider endpoint could not be normalized"
            )
        }
        return namespace
    }

    private func sanitizedRequestID(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) ||
                      $0 == "-" || $0 == "_"
              })
        else {
            return nil
        }
        return value
    }
}
