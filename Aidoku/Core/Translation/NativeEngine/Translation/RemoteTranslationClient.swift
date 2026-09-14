// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

protocol RemoteTranslating: Sendable {
    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult
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

    init(
        credentialStore: TranslationCredentialProviding =
            KeychainTranslationCredentialStore(),
        transport: TranslationHTTPTransport = BoundedURLSessionTransport()
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult {
        try Task.checkCancellation()
        try request.validate()
        guard configuration.provider == .custom else {
            return try await translateOnce(
                request,
                configuration: configuration
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
                configuration: preferredConfiguration
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
                    configuration: alternateConfiguration
                )
                await protocolPreferences.reportSuccess(
                    key: key,
                    apiProtocol: alternateProtocol
                )
                return result
            } catch {
                await protocolPreferences.finishProbeFailure(
                    key: key,
                    token: probeToken
                )
                throw error
            }
        }
    }

    private func translateOnce(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
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

        let encodeStartedAt = ProcessInfo.processInfo.systemUptime
        var urlRequest = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.timeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("Aidoku-iOS/1", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = try TranslationHTTPCodec.requestBody(
            configuration: configuration,
            request: request
        )
        TranslationPerformanceDiagnostics.clientPhaseCompleted(
            phase: "encode",
            segmentCount: segmentCount,
            elapsedMilliseconds: TranslationPerformanceDiagnostics
                .elapsedMilliseconds(since: encodeStartedAt)
        )

        let transportResponse: TranslationHTTPResponse
        do {
            transportResponse = try await transport.data(
                for: urlRequest,
                maximumResponseBytes: configuration.maximumResponseBytes,
                bypassesProxy: endpoint.scheme == "http"
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
            throw RemoteTranslationError.httpStatus(
                response.statusCode,
                requestID: requestID
            )
        }
        guard body.count <= configuration.maximumResponseBytes else {
            throw RemoteTranslationError.responseTooLarge
        }
        let parseStartedAt = ProcessInfo.processInfo.systemUptime
        let translations = try TranslationHTTPCodec.responseTranslations(
            from: body,
            protocol: configuration.apiProtocol,
            expectedSegmentIDs: request.segments.map(\.id)
        )
        TranslationPerformanceDiagnostics.clientPhaseCompleted(
            phase: "parse",
            segmentCount: segmentCount,
            elapsedMilliseconds: TranslationPerformanceDiagnostics
                .elapsedMilliseconds(since: parseStartedAt)
        )
        try Task.checkCancellation()
        return RemoteTranslationBatchResult(
            translations: translations,
            source: .network,
            providerRequestID: requestID
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
