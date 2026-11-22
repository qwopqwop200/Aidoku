import Foundation
import Testing
@testable import Aidoku

/// Translation cache, cache identity, batching and provider-capability memory.
struct TranslationServiceCacheTests {
    private func key(_ text: String = "こんにちは") throws -> TranslationCacheKey {
        let config = RemoteTranslationConfiguration.openAI(model: "cache-test")
        return TranslationCacheKey(configuration: config, endpoint: try config.validatedEndpoint(),
            request: .init(sourceLanguage: "ja", targetLanguage: "ko", sourceText: text))
    }

    private func answer(_ key: TranslationCacheKey, text: String = "안녕하세요") -> [RemoteTranslatedSegment] {
        key.segments.map { .init(id: $0.id, text: text) }
    }

    // MARK: Memory cache

    @Test func invalidAnswersNeverBecomeHits() async throws {
        let cache = TranslationCache()
        let key = try key()
        let invalid: [[RemoteTranslatedSegment]] = [[], [.init(id: "wrong", text: "answer")],
            [.init(id: key.segments[0].id, text: " \n ")], answer(key) + answer(key)]
        for value in invalid {
            await cache.insert(value, for: key)
            #expect(await cache.value(for: key) == nil)
        }
        await cache.insert(answer(key), for: key)
        #expect(await cache.value(for: key)?.source == .memoryCache)
    }

    @Test func budgetEvictsLeastRecentlyUsedEntry() async throws {
        let cache = TranslationCache(maxSizeMiB: 1)
        let text = String(repeating: "a", count: 300 * 1024)
        let keys = try (0..<4).map { try key("source-\($0)") }
        for key in keys.prefix(3) { await cache.insert(answer(key, text: text), for: key) }
        #expect(await cache.value(for: keys[0]) != nil)
        // A fourth ~300 KiB entry exceeds 1 MiB and evicts the least recently used one.
        await cache.insert(answer(keys[3], text: text), for: keys[3])
        #expect(await cache.value(for: keys[1]) == nil)
        #expect(await cache.value(for: keys[0]) != nil)
        #expect(await cache.value(for: keys[3]) != nil)
    }

    @Test func purgeClearsMemoryAndLegacyRecordsAndRejectsEarlierAdmissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("browser-app/translation-cache-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = directory.appendingPathComponent("0123456789abcdef-0123456789abcdef-01234567.json")
        let unmanaged = directory.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: record)
        try Data("{}".utf8).write(to: unmanaged)
        let cache = TranslationCache(storageRootURL: root)
        let key = try key()
        await cache.insert(answer(key), for: key)
        let lease = await cache.lookup(for: key).storageGeneration
        try await cache.purgeAll()
        #expect(await cache.value(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(FileManager.default.fileExists(atPath: unmanaged.path))
        // A provider result admitted before the purge cannot refill the cache.
        await cache.insert(answer(key), for: key, admittedStorageGeneration: lease)
        #expect(await cache.value(for: key) == nil)
    }

    // MARK: Reuse identity

    @Test func reuseIdentityInvalidatesEveryTranslationSemanticFamily() throws {
        let base = try identity(configuration(), request())
        let configurations = [
            configuration(provider: .custom, apiProtocol: .chatCompletions, baseURL: "https://example.com/v1"),
            configuration(model: "gpt-5"), configuration(credentialAccount: "rotated"),
            configuration(credentialGeneration: 8), configuration(instructions: "different instructions"),
            configuration(reasoningEffort: .high)
        ]
        for variant in configurations { #expect(try identity(variant, request()) != base) }
        for variant in [request(sourceLanguage: "auto"), request(targetLanguage: "en"), request(firstText: "違う文字"),
                        request(secondText: "変更された隣の文字")] {
            #expect(try identity(configuration(), variant) != base)
        }
        #expect(try identity(configuration(), request(), segmentID: "segment-1") != base)
        // Transport-only limits do not change what was translated.
        #expect(try identity(configuration(timeout: 120), request()) == base)
    }

    @Test func trackerIDsDoNotChangeBatchLocalReuseIdentity() throws {
        let original = request()
        let renumbered = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [
            .init(id: "tracker-900", text: original.segments[0].text),
            .init(id: "tracker-901", text: original.segments[1].text)])
        let before = try NativeTranslationReuseIdentity.identitiesBySegmentID(configuration: configuration(), request: original)
        let after = try NativeTranslationReuseIdentity.identitiesBySegmentID(configuration: configuration(), request: renumbered)
        #expect(before["segment-0"] == after["tracker-900"])
        #expect(before["segment-1"] == after["tracker-901"])
    }

    // MARK: Batch planning

    @Test func batchesPreserveReadingOrderAndHonorHardLimits() throws {
        for count in [0, 1, 64, 65, 129] {
            let batches = plans(count: count)
            #expect(batches.flatMap { $0.request.segments.map(\.id) } == (0..<count).map { "segment-\($0)" })
            let limit = RemoteTranslationRequest.maximumSegments
            #expect(batches.count == (count + limit - 1) / limit)
            for plan in batches { try plan.request.validate() }
        }
        let maximumSegment = String(repeating: "a", count: RemoteTranslationRequest.maximumSegmentTextBytes)
        let byteLimited = plans(count: 9, text: maximumSegment)
        #expect(byteLimited.map { $0.request.segments.count } == [8, 1])
        for plan in byteLimited {
            #expect(plan.request.segments.reduce(0) { $0 + $1.text.utf8.count } <= RemoteTranslationRequest.maximumSourceBytes)
            #expect(plan.request.segments.allSatisfy { plan.inputIndicesBySegmentID[$0.id] != nil })
        }
    }

    // MARK: Provider capabilities

    @Test(arguments: ["model", "account", "generation"])
    func protocolFallbackDoesNotLeakAcrossProviderRoutes(field: String) async throws {
        let transport = ProviderRouteTransport(rejectFirstResponses: true)
        let client = RemoteTranslationClient(credentialStore: TestCredentials(), transport: transport)
        let request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", segments: [.init(id: "line", text: "Hello")])
        func route(model: String = "model-a", account: String = "account-a", generation: UInt64 = 0) -> RemoteTranslationConfiguration {
            .init(provider: .custom, apiProtocol: .responses, baseURL: "https://cache-audit.example/v1", model: model,
                  credentialAccount: account, credentialGeneration: generation, reasoningEffort: .none)
        }
        _ = try await client.translate(request, configuration: route())
        _ = try await client.translate(request, configuration: route(model: field == "model" ? "model-b" : "model-a",
            account: field == "account" ? "account-b" : "account-a", generation: field == "generation" ? 1 : 0))
        #expect(await transport.paths == ["/v1/responses", "/v1/chat/completions", "/v1/responses"])
    }

    @Test func unsupportedImageRetriesTextAndRemembersAcrossClients() async throws {
        let suite = "ImageSupport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = imageConfiguration()
        let transport = ImageSupportTransport()
        let client = RemoteTranslationClient(credentialStore: TestCredentials(), transport: transport,
            imageSupport: TranslationImageSupport(defaults: defaults))
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", sourceText: "Hello")
        request.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
        #expect(try await client.translate(request, configuration: configuration).translations.first?.text == "안녕하세요")
        #expect(TranslationImageSupport(defaults: defaults).status(for: configuration) == .unsupported)
        let secondClient = RemoteTranslationClient(credentialStore: TestCredentials(), transport: transport,
            imageSupport: TranslationImageSupport(defaults: defaults))
        _ = try await secondClient.translate(request, configuration: configuration)
        #expect(await transport.images == [true, false, false])
    }

    @Test(arguments: [401, 500])
    func unrelatedErrorsDoNotDisableImagesOrRetry(status: Int) async throws {
        let suite = "ImageErrors.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let support = TranslationImageSupport(defaults: defaults)
        let configuration = imageConfiguration()
        let transport = ImageSupportTransport(failureStatus: status, message: "Invalid API key or request")
        let client = RemoteTranslationClient(credentialStore: TestCredentials(), transport: transport, imageSupport: support)
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", sourceText: "Hello")
        request.imageJPEG = Data([1, 2, 3])
        await #expect(throws: RemoteTranslationError.httpStatus(status, requestID: nil)) {
            try await client.translate(request, configuration: configuration)
        }
        #expect(await transport.images == [true])
        #expect(support.status(for: configuration) == .unknown)
    }

    @Test func pageLetteringImageRejectionIsTypedHTTPError() async throws {
        let transport = ImageSupportTransport()
        let client = RemoteTranslationClient(credentialStore: TestCredentials(), transport: transport)
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", sourceText: "Hello")
        request.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
        request.filtersSFX = true; request.filtersBackground = true; request.translatesPageLettering = true
        await #expect(throws: RemoteTranslationError.httpStatus(400, requestID: nil)) {
            try await client.translate(request, configuration: imageConfiguration())
        }
        #expect(await transport.images == [true])
    }

    // MARK: Helpers

    private func identity(_ configuration: RemoteTranslationConfiguration, _ request: RemoteTranslationRequest,
                          segmentID: String = "segment-0") throws -> NativeTranslationReuseIdentity {
        try #require(try NativeTranslationReuseIdentity.identitiesBySegmentID(
            configuration: configuration, request: request)[segmentID])
    }

    private func configuration(
        provider: RemoteTranslationProvider = .openAI, apiProtocol: RemoteTranslationProtocol = .responses,
        baseURL: String = "https://api.openai.com", model: String = "gpt-5-mini", credentialAccount: String = "openai",
        credentialGeneration: UInt64 = 7, instructions: String = "Translate faithfully.",
        reasoningEffort: OpenAIReasoningEffort = .low, timeout: TimeInterval = 60
    ) -> RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(provider: provider, apiProtocol: apiProtocol, baseURL: baseURL, model: model,
            credentialAccount: credentialAccount, credentialGeneration: credentialGeneration, instructions: instructions,
            reasoningEffort: reasoningEffort, timeout: timeout, maximumResponseBytes: 1024 * 1024,
            allowsInsecureLocalhostForDevelopment: false)
    }

    private func request(sourceLanguage: String = "ja", targetLanguage: String = "ko",
                         firstText: String = "同じ文字", secondText: String = "次の文字") -> RemoteTranslationRequest {
        RemoteTranslationRequest(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
            segments: [.init(id: "segment-0", text: firstText), .init(id: "segment-1", text: secondText)])
    }

    private func plans(count: Int, text: String? = nil) -> [NativeTranslationBatchPlan] {
        NativeTranslationBatchPlanner.makeBatches(candidates: (0..<count).map {
            NativeTranslationBatchCandidate(inputIndex: $0, segment: .init(id: "segment-\($0)", text: text ?? "source-\($0)"))
        }, sourceLanguage: "ja", targetLanguage: "ko")
    }

    private func imageConfiguration() -> RemoteTranslationConfiguration {
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "ImageSettings.\(UUID().uuidString)")!)
        settings.custom.baseURL = "https://image-support-tests.example/\(UUID().uuidString)/v1"
        settings.custom.apiProtocol = .chatCompletions
        settings.model = "text-model"
        settings.sourceLanguage = "auto"
        settings.targetLanguage = "ko"
        settings.includePageImage = true
        settings.usesOCRLanguagePolicy = false
        return settings.configuration
    }
}

private struct TestCredentials: TranslationCredentialProviding {
    func secret(for account: String) throws -> String { "test-only" }
}

private func envelope(_ text: String, responses: Bool) throws -> Data {
    try JSONSerialization.data(withJSONObject: responses
        ? ["status": "completed", "output": [["type": "message", "status": "completed",
            "content": [["type": "output_text", "text": text]]]]] as [String: Any]
        : ["choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": text]] as [String: Any]]] as [String: Any])
}

private actor ProviderRouteTransport: TranslationHTTPTransport {
    private(set) var paths: [String] = []
    private let rejectFirstResponses: Bool

    init(rejectFirstResponses: Bool) { self.rejectFirstResponses = rejectFirstResponses }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        let url = try #require(request.url)
        paths.append(url.path)
        let rejects = rejectFirstResponses && paths.count == 1 && url.lastPathComponent == "responses"
        let metadata = url.lastPathComponent == "models"
        let response = try #require(HTTPURLResponse(url: url, statusCode: rejects ? 404 : 200,
            httpVersion: nil, headerFields: metadata ? ["X-vLLM-Version": "0.27.0"] : nil))
        if rejects || metadata { return .init(data: Data("{}".utf8), response: response) }
        return .init(data: try envelope(#"{"translations":[{"id":"line","text":"안녕하세요"}]}"#,
            responses: url.lastPathComponent == "responses"), response: response)
    }
}

/// Rejects image requests with `failureStatus` and answers every text request.
private actor ImageSupportTransport: TranslationHTTPTransport {
    private(set) var images: [Bool] = []
    let failureStatus: Int
    let message: String

    init(failureStatus: Int = 400, message: String = "This model does not support image inputs.") {
        self.failureStatus = failureStatus
        self.message = message
    }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let responses = request.url?.lastPathComponent == "responses"
        let content: [[String: Any]]
        if responses {
            content = try #require((root["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        } else {
            let value = try #require((root["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "user" }?["content"])
            content = (value as? [[String: Any]]) ?? [["type": "text", "text": value]]
        }
        let hasImage = content.contains { ["image_url", "input_image"].contains($0["type"] as? String ?? "") }
        images.append(hasImage)
        let response = try #require(HTTPURLResponse(url: request.url!, statusCode: hasImage ? failureStatus : 200,
            httpVersion: nil, headerFields: nil))
        if hasImage {
            return .init(data: try JSONSerialization.data(withJSONObject: ["error": ["message": message]]), response: response)
        }
        let text = try #require(content.compactMap { $0["text"] as? String }.first)
        let segments = try #require((JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["segments"]
            as? [[String: Any]])
        let translations: [[String: Any]] = segments.map { ["id": $0["id"]!, "text": "안녕하세요"] }
        let output = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": translations]), as: UTF8.self)
        return .init(data: try envelope(output, responses: responses), response: response)
    }
}
