// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

protocol RemoteTranslating: Sendable {
    func prepare(configuration: RemoteTranslationConfiguration) async

    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult
}

extension RemoteTranslating {
    func prepare(configuration: RemoteTranslationConfiguration) async {}
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

actor CustomProtocolPreferenceRegistry {
    struct Key: Hashable, Sendable {
        let provider: RemoteTranslationProvider
        let endpointNamespace: String
        let configuredProtocol: RemoteTranslationProtocol
        let model: String
        let credentialAccount: String
        let credentialGeneration: UInt64
    }

    enum Selection: Sendable {
        case preferred(RemoteTranslationProtocol)
        case probeLeader(token: UUID, configured: RemoteTranslationProtocol)
        case probeFollower(token: UUID, configured: RemoteTranslationProtocol)

        /// Followers may observe the shared probe but do not own its lifetime.
        var failureOwnershipToken: UUID? {
            if case let .probeLeader(token, _) = self { return token }
            return nil
        }
    }

    private struct Entry {
        var successfulPreference: RemoteTranslationProtocol?
        var probeToken: UUID?
        var candidateProtocol: RemoteTranslationProtocol?
    }

    private var entries: [Key: Entry] = [:]

    func begin(key: Key, configured: RemoteTranslationProtocol) -> Selection {
        var entry = entries[key] ?? Entry()
        if let successfulPreference = entry.successfulPreference { return .preferred(successfulPreference) }
        if let probeToken = entry.probeToken { return .probeFollower(token: probeToken, configured: configured) }
        let token = UUID()
        entry.probeToken = token
        entry.candidateProtocol = nil
        entries[key] = entry
        return .probeLeader(token: token, configured: configured)
    }

    func resolvedProtocol(key: Key, probeToken: UUID) -> RemoteTranslationProtocol? {
        guard let entry = entries[key] else { return nil }
        if let successfulPreference = entry.successfulPreference { return successfulPreference }
        guard entry.probeToken == probeToken else { return nil }
        return entry.candidateProtocol
    }

    func reportUnsupported(
        key: Key,
        failedProtocol: RemoteTranslationProtocol,
        alternateProtocol: RemoteTranslationProtocol
    ) {
        var entry = entries[key] ?? Entry()
        if entry.successfulPreference == failedProtocol { entry.successfulPreference = nil }
        entry.candidateProtocol = alternateProtocol
        entries[key] = entry
    }

    func reportSuccess(key: Key, apiProtocol: RemoteTranslationProtocol) {
        entries[key] = Entry(successfulPreference: apiProtocol, probeToken: nil, candidateProtocol: nil)
    }

    func finishProbeFailure(key: Key, token: UUID?) {
        guard let token, var entry = entries[key], entry.probeToken == token, entry.successfulPreference == nil else { return }
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
        credentialStore: TranslationCredentialProviding = KeychainTranslationCredentialStore(),
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
              let compactKey = try? Self.compactCapabilityKey(for: configuration),
              compactOutput.beginMetadataProbe(endpoint: compactKey,
                  account: configuration.credentialAccount, now: ProcessInfo.processInfo.systemUptime)
        else { return }
        defer { compactOutput.finishMetadataProbe(endpoint: compactKey, account: configuration.credentialAccount) }
        do {
            let secret = try credentialStore.secret(for: configuration.credentialAccount)
            guard KeychainTranslationCredentialStore.isStorableSecret(secret) else { return }
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
            compactOutput.markEligible(compactKey)
            ReaderTranslationDiagnostics.record("api_compact_metadata_ready")
        } catch {
            // Metadata is optional; translation reports its own errors.
        }
    }

    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult {
        try Task.checkCancellation()
        try request.validate()
        // Page-lettering classification is a single-pass decision: no
        // source-alignment retries, protocol fallback or image downgrade.
        if request.translatesPageLettering == true {
            guard request.imageJPEG != nil, request.filtersSFX == true, request.filtersBackground == true else {
                throw RemoteTranslationError.invalidRequest("page translation requires image, SFX and background roles")
            }
            return try await translateOnce(request, configuration: configuration)
        }
        var effectiveRequest = request
        if !rechecksImageSupport, imageSupport.status(for: configuration) == .unsupported {
            effectiveRequest.imageJPEG = nil
        }
        do {
            return try await translateRecoveringSourceAlignment(effectiveRequest, configuration: configuration)
        } catch is UnsupportedImageInput {
            try Task.checkCancellation()
            imageSupport.record(.unsupported, for: configuration)
            effectiveRequest.imageJPEG = nil
            return try await translateRecoveringSourceAlignment(effectiveRequest, configuration: configuration)
        }
    }

    private func translateRecoveringSourceAlignment(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult {
        let result = try await translateUsingSupportedProtocol(request, configuration: configuration)
        if request.imageJPEG != nil {
            imageSupport.record(.supported, for: configuration)
        }
        return try await TranslationHTTPCodec.recoveringIndependentSourceAlignment(request: request, result: result) { isolated in
            // Call below this recovery entry point: an independently confirmed
            // coinciding translation is accepted without recursively retrying.
            try await self.translateUsingSupportedProtocol(isolated, configuration: configuration)
        }
    }

    private func translateUsingSupportedProtocol(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult {
        guard configuration.provider == .custom else {
            return try await translateOnce(request, configuration: configuration)
        }

        let key = try Self.protocolPreferenceKey(for: configuration)
        let selection = await protocolPreferences.begin(key: key, configured: configuration.apiProtocol)
        let preferredProtocol: RemoteTranslationProtocol
        let probeToken = selection.failureOwnershipToken
        switch selection {
        case let .preferred(apiProtocol):
            preferredProtocol = apiProtocol
        case let .probeLeader(_, configured):
            preferredProtocol = configured
        case let .probeFollower(token, configured):
            try await Task.sleep(nanoseconds: Self.protocolProbeGraceNanoseconds)
            preferredProtocol = await protocolPreferences.resolvedProtocol(key: key, probeToken: token) ?? configured
        }

        struct UnsupportedEndpoint: Error {}
        func attempt(
            _ apiProtocol: RemoteTranslationProtocol,
            configuration: RemoteTranslationConfiguration,
            allowsFallback: Bool
        ) async throws -> RemoteTranslationBatchResult {
            do {
                let result = try await translateOnce(request, configuration: configuration)
                await protocolPreferences.reportSuccess(key: key, apiProtocol: apiProtocol)
                return result
            } catch let error as UnsupportedImageInput {
                // The endpoint exists; only its image input was rejected.
                await protocolPreferences.reportSuccess(key: key, apiProtocol: apiProtocol)
                throw error
            } catch let error as RemoteTranslationError where allowsFallback && Self.isUnsupportedEndpoint(error) {
                throw UnsupportedEndpoint()
            } catch {
                await protocolPreferences.finishProbeFailure(key: key, token: probeToken)
                throw error
            }
        }

        let preferredConfiguration = try Self.configuration(configuration, replacingAPIProtocol: preferredProtocol)
        do {
            return try await attempt(preferredProtocol, configuration: preferredConfiguration, allowsFallback: true)
        } catch is UnsupportedEndpoint {
            let alternateProtocol: RemoteTranslationProtocol = preferredProtocol == .responses ? .chatCompletions : .responses
            let alternateConfiguration = try Self.configuration(configuration, replacingAPIProtocol: alternateProtocol)
            await protocolPreferences.reportUnsupported(
                key: key, failedProtocol: preferredProtocol, alternateProtocol: alternateProtocol
            )
            return try await attempt(alternateProtocol, configuration: alternateConfiguration, allowsFallback: false)
        }
    }

    private func translateOnce(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult {
        let segmentCount = request.segments.count
        let endpointStartedAt = ProcessInfo.processInfo.systemUptime
        let endpoint = try configuration.validatedEndpoint()
        Self.recordPhase("endpoint", segmentCount: segmentCount, since: endpointStartedAt)

        let keychainStartedAt = ProcessInfo.processInfo.systemUptime
        let apiKey: String
        do {
            apiKey = try credentialStore.secret(for: configuration.credentialAccount)
        } catch TranslationCredentialStoreError.notFound {
            throw RemoteTranslationError.missingCredential
        } catch {
            throw RemoteTranslationError.credentialAccessFailed
        }
        guard KeychainTranslationCredentialStore.isStorableSecret(apiKey) else { throw RemoteTranslationError.credentialAccessFailed }
        Self.recordPhase("keychain", segmentCount: segmentCount, since: keychainStartedAt)

        if request.translatesPageLettering == true {
            // Compact-output negotiation may retry after a rejected grammar.
            // The one-call page path uses the portable schema directly.
            return try await exchange(request, configuration: configuration, endpoint: endpoint, apiKey: apiKey,
                chatOptions: .standard).batch
        }

        let compactKey = try Self.compactCapabilityKey(for: configuration)
        if Self.usesCompactOutput(configuration: configuration, request: request, state: .eligible) {
            try await compactOutput.waitForMetadata(endpoint: compactKey, account: configuration.credentialAccount)
        }
        let compactState = compactOutput.state(for: compactKey)
        if Self.usesCompactOutput(configuration: configuration, request: request, state: compactState) {
            do {
                let result = try await exchange(request, configuration: configuration, endpoint: endpoint, apiKey: apiKey,
                                                chatOptions: Self.compactChatOptions(configuration: configuration, request: request))
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
                                        chatOptions: .standard)
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
        guard configuration.provider == .custom, state == .eligible || state == .verified,
              // Responses grammar support is verified only for direct answers;
              // reasoning plus grammar may be incompatible on custom endpoints.
              configuration.apiProtocol != .responses || configuration.reasoningEffort == .none else { return false }
        return TranslationHTTPCodec.supportsCompactOutput(segmentIDs: request.segments.map(\.id))
    }

    static func compactChatOptions(
        configuration: RemoteTranslationConfiguration,
        request: RemoteTranslationRequest
    ) -> TranslationHTTPCodec.ChatWireOptions {
        configuration.apiProtocol == .responses
            ? TranslationHTTPCodec.ChatWireOptions(compactStructuredOutput: true)
            : TranslationHTTPCodec.ChatWireOptions(compactStructuredOutput: true, stream: true, maximumOutputTokens: nil)
    }

    private struct ExchangeResult {
        let batch: RemoteTranslationBatchResult
        let identifiesStructuredOutputServer: Bool
    }

    private func exchange(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration,
        endpoint: URL,
        apiKey: String,
        chatOptions: TranslationHTTPCodec.ChatWireOptions
    ) async throws -> ExchangeResult {
        let segmentCount = request.segments.count
        let encodeStartedAt = ProcessInfo.processInfo.systemUptime
        var urlRequest = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: configuration.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(chatOptions.stream ? "text/event-stream, application/json" : "application/json",
                            forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("Aidoku-iOS/1", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = try TranslationHTTPCodec.requestBody(
            configuration: configuration, request: request, chatOptions: chatOptions
        )
        Self.recordPhase("encode", segmentCount: segmentCount, since: encodeStartedAt)

        // SSE framing repeats per-chunk metadata around each token; the
        // assembled content is still bounded by the envelope parser.
        let maximumBodyBytes = chatOptions.stream
            ? configuration.maximumResponseBytes.multipliedReportingOverflow(by: 8).partialValue
            : configuration.maximumResponseBytes
        let transportResponse: TranslationHTTPResponse
        do {
            transportResponse = try await transport.data(
                for: urlRequest, maximumResponseBytes: maximumBodyBytes, bypassesProxy: endpoint.scheme == "http"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RemoteTranslationError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            if Self.isPrivateTailnetEndpoint(endpoint), Self.isConnectivityFailure(error.code) {
                throw RemoteTranslationError.privateTailnetUnavailable
            }
            throw RemoteTranslationError.transport(error.code)
        } catch {
            throw RemoteTranslationError.transport(.unknown)
        }
        let body = transportResponse.data
        let response = transportResponse.response
        TranslationPerformanceDiagnostics.transportCompleted(
            segmentCount: segmentCount, responseBytes: body.count,
            statusCode: response.statusCode, metrics: transportResponse.metrics
        )

        try Task.checkCancellation()
        let requestID = sanitizedRequestID(response.value(forHTTPHeaderField: "x-request-id"))
        guard (200...299).contains(response.statusCode) else {
            if request.imageJPEG != nil,
               TranslationImageSupport.isUnsupportedResponse(status: response.statusCode, body: body) {
                throw UnsupportedImageInput()
            }
            throw RemoteTranslationError.httpStatus(response.statusCode, requestID: requestID)
        }
        let isEventStream = chatOptions.stream && (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased().contains("text/event-stream")
        guard body.count <= (isEventStream ? maximumBodyBytes : configuration.maximumResponseBytes) else {
            throw RemoteTranslationError.responseTooLarge
        }
        let parseStartedAt = ProcessInfo.processInfo.systemUptime
        let sources = Dictionary(uniqueKeysWithValues: request.segments.map { ($0.id, $0.text) })
        let expectedIDs = request.segments.map(\.id)
        let sfxSources = request.filtersSFX == true ? sources : nil
        let backgroundSources = request.filtersBackground == true ? sources : nil
        let translations = try isEventStream
            ? TranslationHTTPCodec.streamedChatTranslations(
                from: body, expectedSegmentIDs: expectedIDs,
                sfxSourceTexts: sfxSources, backgroundSourceTexts: backgroundSources)
            : TranslationHTTPCodec.responseTranslations(
                from: body, protocol: configuration.apiProtocol, expectedSegmentIDs: expectedIDs,
                sfxSourceTexts: sfxSources, backgroundSourceTexts: backgroundSources)
        Self.recordPhase("parse", segmentCount: segmentCount, since: parseStartedAt)
        try Task.checkCancellation()
        return ExchangeResult(
            batch: RemoteTranslationBatchResult(translations: translations, source: .network, providerRequestID: requestID),
            // Only custom, non-page requests consume this capability hint.
            // Avoid decoding the response envelope again for every reader page.
            identifiesStructuredOutputServer: configuration.provider == .custom && request.translatesPageLettering != true &&
                !chatOptions.compactStructuredOutput && !isEventStream &&
                TranslationHTTPCodec.identifiesStructuredOutputServer(
                    responseBody: body, apiProtocol: configuration.apiProtocol,
                    vllmVersionHeader: response.value(forHTTPHeaderField: "X-vLLM-Version")
                )
        )
    }

    private static func recordPhase(_ phase: String, segmentCount: Int, since startedAt: TimeInterval) {
        TranslationPerformanceDiagnostics.clientPhaseCompleted(
            phase: phase, segmentCount: segmentCount,
            elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: startedAt)
        )
    }

    private static func isUnsupportedEndpoint(_ error: RemoteTranslationError) -> Bool {
        guard case let .httpStatus(status, _) = error else { return false }
        return status == 404 || status == 405 || status == 501
    }

    private static func isPrivateTailnetEndpoint(_ endpoint: URL) -> Bool {
        endpoint.host?.lowercased().hasSuffix(".ts.net") ?? false
    }

    private static func isConnectivityFailure(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
             .notConnectedToInternet, .secureConnectionFailed: true
        default: false
        }
    }

    /// A gateway may route models or credentials to different backends. A
    /// rejection or verification from one route must not affect another route.
    static func compactCapabilityKey(for configuration: RemoteTranslationConfiguration) throws -> String {
        let fields = [configuration.provider.rawValue, configuration.apiProtocol.rawValue,
            try configuration.validatedEndpoint().absoluteString, configuration.model,
            configuration.credentialAccount, String(configuration.credentialGeneration),
            configuration.reasoningEffort.rawValue]
        return String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    }

    private static func protocolPreferenceKey(
        for configuration: RemoteTranslationConfiguration
    ) throws -> CustomProtocolPreferenceRegistry.Key {
        CustomProtocolPreferenceRegistry.Key(
            provider: configuration.provider,
            endpointNamespace: try protocolEndpointNamespace(for: configuration).absoluteString,
            configuredProtocol: configuration.apiProtocol,
            model: configuration.model,
            credentialAccount: configuration.credentialAccount,
            credentialGeneration: configuration.credentialGeneration
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
        guard apiProtocol != configuration.apiProtocol else { return configuration }
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
            allowsInsecureLocalhostForDevelopment: configuration.allowsInsecureLocalhostForDevelopment
        )
    }

    private static func protocolEndpointNamespace(
        for configuration: RemoteTranslationConfiguration
    ) throws -> URL {
        let normalizationError = RemoteTranslationError.invalidConfiguration("provider endpoint could not be normalized")
        guard var components = URLComponents(url: try configuration.validatedEndpoint(), resolvingAgainstBaseURL: false) else {
            throw normalizationError
        }
        var segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch configuration.apiProtocol {
        case .responses:
            if segments.last?.caseInsensitiveCompare("responses") == .orderedSame {
                segments.removeLast()
            }
        case .chatCompletions:
            if segments.count >= 2,
               segments[segments.count - 2].caseInsensitiveCompare("chat") == .orderedSame,
               segments.last?.caseInsensitiveCompare("completions") == .orderedSame {
                segments.removeLast(2)
            }
        }
        components.path = segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let namespace = components.url else { throw normalizationError }
        return namespace
    }

    private func sanitizedRequestID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        else { return nil }
        return value
    }
}
