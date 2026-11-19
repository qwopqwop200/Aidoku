// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct TranslationStreamingTests {
    private static func request(_ texts: [String], sfx: Bool = false, background: Bool = false) -> RemoteTranslationRequest {
        var request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko",
            segments: texts.enumerated().map { RemoteTranslationSegment(id: "segment-\($0.offset)", text: $0.element) })
        request.filtersSFX = sfx ? true : nil
        request.filtersBackground = background ? true : nil
        return request
    }

    private static func configuration(reasoning: OpenAIReasoningEffort = .none, provider: RemoteTranslationProvider = .custom,
                                      apiProtocol: RemoteTranslationProtocol = .chatCompletions)
        -> RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(provider: provider, apiProtocol: apiProtocol, baseURL: "https://llm.example/v1",
                                       model: "gemma", credentialAccount: "test", reasoningEffort: reasoning)
    }

    private static func matches(_ pattern: String, _ value: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: "^(?:" + pattern + ")$")
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// Builds an SSE body whose content deltas are `pieces`.
    static func sse(_ pieces: [String], finish: String? = "stop", done: Bool = true) throws -> Data {
        var body = ""
        for piece in pieces {
            let chunk: [String: Any] = ["object": "chat.completion.chunk",
                                        "choices": [["index": 0, "delta": ["content": piece], "finish_reason": NSNull()]]]
            body += "data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\n\n"
        }
        if let finish {
            let chunk: [String: Any] = ["choices": [["index": 0, "delta": [:] as [String: Any], "finish_reason": finish]]]
            body += "data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\r\n\r\n"
        }
        body += ": keep-alive\n\ndata: {\"choices\":[],\"usage\":{\"completion_tokens\":3}}\n\n"
        if done { body += "data: [DONE]\n\n" }
        return Data(body.utf8)
    }

    // MARK: Codec

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions])
    func metadataEnablesCompactOnFirstTranslation(apiProtocol: RemoteTranslationProtocol) async throws {
        let transport = MetadataStreamingTransport()
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        let configuration = Self.configuration(apiProtocol: apiProtocol)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { await client.prepare(configuration: configuration) } }
        }
        #expect(await transport.metadataCalls == 1)
        let result = try await client.translate(Self.request(["待て"]), configuration: configuration)
        #expect(result.translations.count == 1)
        #expect(await transport.translation.kinds == [.compact])
    }

    @Test(arguments: [200, 401, 404])
    func unknownMetadataKeepsPortableFirstRequest(status: Int) async throws {
        let transport = MetadataStreamingTransport(status: status, version: nil)
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        let configuration = Self.configuration(apiProtocol: .responses)
        await client.prepare(configuration: configuration)
        await client.prepare(configuration: configuration)
        _ = try await client.translate(Self.request(["待て"]), configuration: configuration)
        #expect(await transport.metadataCalls == 1)
        #expect(await transport.translation.kinds == [.standard])
    }

    @Test func metadataHintRetainsCompactRejectionFallback() async throws {
        let transport = MetadataStreamingTransport(mode: .rejectCompact)
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        let configuration = Self.configuration(apiProtocol: .responses)
        await client.prepare(configuration: configuration)
        _ = try await client.translate(Self.request(["待て"]), configuration: configuration)
        await client.prepare(configuration: configuration)
        #expect(await transport.translation.kinds == [.compact, .standard])
        #expect(client.compactOutput.state(for: try RemoteTranslationClient.compactCapabilityKey(for: configuration)) == .unsupported)
        #expect(await transport.metadataCalls == 1)
    }

    @Test func metadataSkipsUnsupportedConfigurations() async {
        let transport = MetadataStreamingTransport()
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        await client.prepare(configuration: Self.configuration(provider: .openAI))
        await client.prepare(configuration: Self.configuration(reasoning: .medium, apiProtocol: .responses))
        #expect(await transport.metadataCalls == 0)
    }

    @Test func metadataAdmissionIsBoundedAndRetriesAfterTTL() {
        let registry = CompactChatOutputRegistry()
        #expect(registry.beginMetadataProbe(endpoint: "a", account: "x", now: 0))
        #expect(!registry.beginMetadataProbe(endpoint: "a", account: "x", now: 299))
        #expect(registry.beginMetadataProbe(endpoint: "a", account: "y", now: 299))
        #expect(!registry.beginMetadataProbe(endpoint: "a", account: "x", now: 300))
        registry.finishMetadataProbe(endpoint: "a", account: "x")
        #expect(registry.beginMetadataProbe(endpoint: "a", account: "x", now: 300))
        for index in 0..<40 { _ = registry.beginMetadataProbe(endpoint: "\(index)", account: "x", now: 301) }
        #expect(!registry.beginMetadataProbe(endpoint: "overflow", account: "x", now: 302))
        #expect(registry.beginMetadataProbe(endpoint: "overflow", account: "x", now: 602))
        registry.markUnsupported("overflow")
        #expect(!registry.beginMetadataProbe(endpoint: "overflow", account: "x", now: 1000))
    }

    @Test func cachedOCRWaitsForInFlightMetadataBeforeFirstTranslation() async throws {
        let transport = ScriptedStreamingTransport(mode: .streamed)
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        let configuration = Self.configuration(apiProtocol: .responses)
        let endpoint = try RemoteTranslationClient.compactCapabilityKey(for: configuration)
        #expect(client.compactOutput.beginMetadataProbe(endpoint: endpoint, account: "test", now: ProcessInfo.processInfo.systemUptime))
        let translation = Task { try await client.translate(Self.request(["待て"]), configuration: configuration) }
        try await Self.waitForMetadataWaiters(client.compactOutput, count: 1)
        #expect(await transport.kinds.isEmpty)
        client.compactOutput.markEligible(endpoint)
        client.compactOutput.finishMetadataProbe(endpoint: endpoint, account: "test")
        _ = try await translation.value
        #expect(await transport.kinds == [.compact])
        #expect(client.compactOutput.metadataWaiterCount == 0)
    }

    @Test func metadataFailureReleasesFirstTranslationToPortableFormat() async throws {
        let transport = ScriptedStreamingTransport(mode: .streamed)
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        let configuration = Self.configuration(apiProtocol: .responses)
        let endpoint = try RemoteTranslationClient.compactCapabilityKey(for: configuration)
        #expect(client.compactOutput.beginMetadataProbe(endpoint: endpoint, account: "test", now: ProcessInfo.processInfo.systemUptime))
        let translation = Task { try await client.translate(Self.request(["待て"]), configuration: configuration) }
        try await Self.waitForMetadataWaiters(client.compactOutput, count: 1)
        client.compactOutput.finishMetadataProbe(endpoint: endpoint, account: "test")
        _ = try await translation.value
        #expect(await transport.kinds == [.standard])
    }

    @Test func metadataWaitCancellationDoesNotCancelSharedProbeOrSibling() async throws {
        let registry = CompactChatOutputRegistry()
        #expect(registry.beginMetadataProbe(endpoint: "endpoint", account: "account", now: ProcessInfo.processInfo.systemUptime))
        let cancelled = Task { try await registry.waitForMetadata(endpoint: "endpoint", account: "account") }
        let sibling = Task { try await registry.waitForMetadata(endpoint: "endpoint", account: "account") }
        try await Self.waitForMetadataWaiters(registry, count: 2)
        cancelled.cancel()
        do { try await cancelled.value; Issue.record("Cancelled metadata waiter completed successfully") }
        catch is CancellationError {} catch { throw error }
        #expect(registry.metadataWaiterCount == 1)
        #expect(!registry.beginMetadataProbe(endpoint: "endpoint", account: "account", now: ProcessInfo.processInfo.systemUptime + 301))
        registry.markEligible("endpoint")
        registry.finishMetadataProbe(endpoint: "endpoint", account: "account")
        try await sibling.value
        #expect(registry.metadataWaiterCount == 0)
    }

    @Test func slowMetadataHasOneSharedDeadlineAndOtherAccountsDoNotWait() async throws {
        let registry = CompactChatOutputRegistry()
        #expect(registry.beginMetadataProbe(endpoint: "endpoint", account: "account", now: ProcessInfo.processInfo.systemUptime))
        let waiter = Task { try await registry.waitForMetadata(endpoint: "endpoint", account: "account") }
        try await Self.waitForMetadataWaiters(registry, count: 1)
        try await registry.waitForMetadata(endpoint: "endpoint", account: "other")
        #expect(registry.metadataWaiterCount == 1)
        // The probe deliberately never completes. The deadline must release it.
        try await waiter.value
        #expect(registry.metadataWaiterCount == 0)
        try await registry.waitForMetadata(endpoint: "endpoint", account: "account")
        #expect(registry.metadataWaiterCount == 0)
        registry.finishMetadataProbe(endpoint: "endpoint", account: "account")
    }

    private static func waitForMetadataWaiters(_ registry: CompactChatOutputRegistry, count: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while registry.metadataWaiterCount != count {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("Metadata waiter was not registered")
                throw URLError(.timedOut)
            }
            await Task.yield()
        }
    }

    @Test func compactStreamingBodyReplacesSchemaWithExactGrammar() throws {
        let request = Self.request(["おい", "待て"])
        let options = RemoteTranslationClient.compactChatOptions(configuration: Self.configuration(), request: request)
        #expect(options == .init(compactStructuredOutput: true, stream: true))
        let body = try TranslationHTTPCodec.requestBody(configuration: Self.configuration(), request: request, chatOptions: options)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["response_format"] == nil)
        #expect(root["stream"] as? Bool == true)
        #expect(root["max_tokens"] as? Int == 8192)
        #expect((root["temperature"] as? NSNumber)?.doubleValue == 1.0)
        #expect(root["reasoning_effort"] as? String == "none")
        let pattern = try #require((root["structured_outputs"] as? [String: Any])?["regex"] as? String)
        #expect((root["structured_outputs"] as? [String: Any])?.count == 1)
        #expect(try Self.matches(pattern, #"{"translations":[{"id":"segment-0","text":"야"},{"id":"segment-1","text":"기다려 \"\\n\u00e9"}]}"#))
        #expect(try !Self.matches(pattern, #"{"translations": [{"id":"segment-0","text":"야"},{"id":"segment-1","text":"x"}]}"#))
        #expect(try !Self.matches(pattern, #"{"translations":[{"id":"segment-1","text":"야"},{"id":"segment-0","text":"x"}]}"#))
        #expect(try !Self.matches(pattern, #"{"translations":[{"id":"segment-0","text":""},{"id":"segment-1","text":"x"}]}"#))
        #expect(try !Self.matches(pattern, "{\"translations\":[{\"id\":\"segment-0\",\"text\":\"a\nb\"},{\"id\":\"segment-1\",\"text\":\"x\"}]}"))

        // The prompt is identical to the standard request; only wire options differ.
        let standard = try #require(JSONSerialization.jsonObject(with: TranslationHTTPCodec.requestBody(
            configuration: Self.configuration(), request: request)) as? [String: Any])
        #expect(standard["stream"] == nil && (standard["max_tokens"] as? Int) == 8192 && standard["structured_outputs"] == nil)
        #expect(standard["response_format"] != nil)
        #expect((standard["messages"] as? NSArray) == (root["messages"] as? NSArray))
    }

    @Test func thinkingUsesCompletionTokenBudget() throws {
        let request = Self.request(["待て"])
        let configuration = Self.configuration(reasoning: .low)
        let root = try #require(JSONSerialization.jsonObject(with: TranslationHTTPCodec.requestBody(
            configuration: configuration, request: request)) as? [String: Any])
        #expect(root["max_tokens"] == nil)
        #expect((root["max_completion_tokens"] as? NSNumber)?.intValue == 8192)
        #expect(root["min_p"] == nil)
        #expect((root["repetition_penalty"] as? NSNumber)?.doubleValue == 1.08)
    }

    @Test func compactResponsesPreservesPromptImageAndReasoningWithoutStreaming() throws {
        for hasImage in [false, true] {
            for filters in [(false, false), (true, false), (false, true), (true, true)] {
                var request = Self.request(["おい", "待て"], sfx: filters.0, background: filters.1)
                if hasImage { request.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9]) }
                let configuration = Self.configuration(reasoning: .low, apiProtocol: .responses)
                let options = RemoteTranslationClient.compactChatOptions(configuration: configuration, request: request)
                #expect(options == .init(compactStructuredOutput: true))
                let compact = try #require(JSONSerialization.jsonObject(with: TranslationHTTPCodec.requestBody(
                    configuration: configuration, request: request, chatOptions: options)) as? [String: Any])
                let standard = try #require(JSONSerialization.jsonObject(with: TranslationHTTPCodec.requestBody(
                    configuration: configuration, request: request)) as? [String: Any])
                #expect(compact["text"] == nil)
                #expect(compact["stream"] == nil && compact["max_tokens"] == nil && (compact["max_output_tokens"] as? Int) == 8192)
                var expected = standard
                expected.removeValue(forKey: "text")
                expected["structured_outputs"] = ["regex": try TranslationHTTPCodec.compactOutputPattern(
                    segmentIDs: request.segments.map(\.id), filtersSFX: filters.0, filtersBackground: filters.1)]
                #expect(NSDictionary(dictionary: compact).isEqual(to: expected))
                #expect(!RemoteTranslationClient.usesCompactOutput(configuration: configuration, request: request, state: .eligible))
            }
        }
    }

    @Test func compactGrammarCarriesClassificationKeysInPromptOrder() throws {
        let pattern = try TranslationHTTPCodec.compactOutputPattern(segmentIDs: ["a.b", "c:d"], filtersSFX: true, filtersBackground: true)
        #expect(try Self.matches(pattern, #"{"translations":[{"id":"a.b","text_role":"dialogue","text":"x"},{"id":"c:d","text_role":"sfx","text":"ドン"}]}"#))
        #expect(try !Self.matches(pattern, #"{"translations":[{"id":"aXb","text_role":"dialogue","text":"x"},{"id":"c:d","text_role":"sfx","text":"y"}]}"#))
        #expect(try !Self.matches(pattern, #"{"translations":[{"id":"a.b","text_role":"shout","text":"x"},{"id":"c:d","text_role":"sfx","text":"y"}]}"#))
        #expect(!TranslationHTTPCodec.supportsCompactOutput(segmentIDs: ["a b"]))
        #expect(throws: RemoteTranslationError.self) {
            try TranslationHTTPCodec.compactOutputPattern(segmentIDs: ["a\"b"], filtersSFX: false, filtersBackground: false)
        }
    }

    @Test func outputTokenCapIsSharedWithReasoning() throws {
        let short = Self.request(Array(repeating: "ドン", count: 64))
        #expect(TranslationHTTPCodec.maxOutputTokens == 8192)
        #expect(RemoteTranslationClient.compactChatOptions(configuration: Self.configuration(reasoning: .low), request: short)
            .maximumOutputTokens == nil)
        #expect(RemoteTranslationClient.compactChatOptions(configuration: Self.configuration(reasoning: .modelDefault), request: short)
            .maximumOutputTokens == nil)
    }

    @Test func compactOutputRequiresCustomChatEndpointVerifiedAsVLLM() {
        let request = Self.request(["a"])
        for state in [CompactChatOutputRegistry.State.unknown, .unsupported] {
            #expect(!RemoteTranslationClient.usesCompactOutput(configuration: Self.configuration(), request: request, state: state))
        }
        #expect(RemoteTranslationClient.usesCompactOutput(configuration: Self.configuration(), request: request, state: .eligible))
        #expect(!RemoteTranslationClient.usesCompactOutput(configuration: Self.configuration(provider: .openAI), request: request, state: .verified))
        let body = { (fingerprint: Any?) -> Data in
            var root: [String: Any] = ["choices": []]
            root["system_fingerprint"] = fingerprint
            return try! JSONSerialization.data(withJSONObject: root)
        }
        #expect(TranslationHTTPCodec.identifiesStructuredOutputServer(responseBody: body("vllm-0.27.0-33c9b453")))
        #expect(TranslationHTTPCodec.identifiesStructuredOutputServer(responseBody: body("vllm-1.0.0")))
        #expect(!TranslationHTTPCodec.identifiesStructuredOutputServer(responseBody: body("vllm-0.10.1")))
        #expect(!TranslationHTTPCodec.identifiesStructuredOutputServer(responseBody: body("fp_44709d6fcb")))
        #expect(!TranslationHTTPCodec.identifiesStructuredOutputServer(responseBody: body(nil)))
    }

    @Test func responsesReasoningKeepsStandardRequestsEvenForVerifiedServer() async throws {
        let request = Self.request(["おい"])
        for effort in [OpenAIReasoningEffort.modelDefault, .low, .high] {
            let configuration = Self.configuration(reasoning: effort, apiProtocol: .responses)
            for state in [CompactChatOutputRegistry.State.eligible, .verified] {
                #expect(!RemoteTranslationClient.usesCompactOutput(configuration: configuration, request: request, state: state))
            }
            let transport = ScriptedStreamingTransport(mode: .streamed)
            let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
            for _ in 0..<3 { _ = try await client.translate(request, configuration: configuration) }
            #expect(await transport.kinds == [.standard, .standard, .standard])
        }
        #expect(RemoteTranslationClient.usesCompactOutput(
            configuration: Self.configuration(apiProtocol: .responses), request: request, state: .verified))
        // Existing Chat Completions reasoning policy remains unchanged.
        #expect(RemoteTranslationClient.usesCompactOutput(
            configuration: Self.configuration(reasoning: .low), request: request, state: .verified))
    }

    @Test func responsesCompactRequiresExplicitRecentVLLMVersion() {
        let body = Data("{\"output\":[],\"kv_transfer_params\":null}".utf8)
        #expect(!TranslationHTTPCodec.identifiesStructuredOutputServer(responseBody: body, apiProtocol: .responses))
        for version in ["0.26.0", "uvicorn", "GemmaJsonProxy/1.0", "", "0.27", "0.27.bad", "0.27.0-dev", "0.27.0 ", "0..27"] {
            #expect(!TranslationHTTPCodec.identifiesStructuredOutputServer(
                responseBody: body, apiProtocol: .responses, vllmVersionHeader: version))
        }
        #expect(TranslationHTTPCodec.identifiesStructuredOutputServer(
            responseBody: body, apiProtocol: .responses, vllmVersionHeader: "0.27.0"))
    }

    // MARK: SSE decoding

    @Test func streamDecodingIsIndependentOfChunkBoundaries() throws {
        let content = #"{"translations":[{"id":"segment-0","text":"어이, \"기다려\" {}"},{"id":"segment-1","is":1,"text":"x"},{"id":"segment-1","text":"줄\n바꿈 \\ 끝 😀"}]}"#
        // Delta boundaries split an escape, a quote and a multi-byte scalar.
        let scalars = Array(content.unicodeScalars)
        var pieces: [String] = []
        var index = 0
        let sizes = [1, 2, 3, 5, 7]
        while index < scalars.count {
            let end = min(scalars.count, index + sizes[pieces.count % sizes.count])
            pieces.append(String(String.UnicodeScalarView(scalars[index..<end])))
            index = end
        }
        let body = try Self.sse(pieces)
        for step in [1, 2, 3, 17, body.count] {
            var decoder = ChatCompletionStreamDecoder()
            var offset = 0
            while offset < body.count {
                let end = min(body.count, offset + step)
                _ = try decoder.consume(body.subdata(in: offset..<end))
                offset = end
            }
            _ = try decoder.finish()
            #expect(decoder.content == content)
            #expect(decoder.finishReason == "stop")
            #expect(decoder.completed)
        }
    }

    @Test func streamHandlesLongFragmentedLinesAndUnterminatedFinalLine() throws {
        let text = String(repeating: "긴 번역 😀 \"인용\" ", count: 2_048)
        let body = try Self.sse(["앞", text, "뒤"])
        // A sliced Data has a nonzero startIndex. An unterminated final
        // [DONE] line also exercises the decoder's retained suffix.
        var prefixed = Data([0, 1, 2])
        prefixed.append(body)
        let sliced = prefixed.dropFirst(3).dropLast(2)
        var decoder = ChatCompletionStreamDecoder()
        var returned: [String] = []
        var offset = sliced.startIndex
        while offset < sliced.endIndex {
            let end = min(sliced.endIndex, offset + 31)
            returned += try decoder.consume(sliced[offset..<end])
            offset = end
        }
        #expect(!decoder.completed)
        returned += try decoder.finish()
        #expect(returned == ["앞", text, "뒤"])
        #expect(decoder.content == "앞" + text + "뒤")
        #expect(decoder.finishReason == "stop")
        #expect(decoder.completed)
        #expect(try decoder.finish().isEmpty)
    }

    @Test func streamedEnvelopeUsesNonStreamingValidation() throws {
        let content = #"{"translations":[{"id":"s","text_role":"sfx","text":"쾅"},{"id":"t","text_role":"dialogue","text":"안녕"}]}"#
        let parsed = try TranslationHTTPCodec.streamedChatTranslations(
            from: try Self.sse([String(content.prefix(20)), String(content.dropFirst(20))]),
            expectedSegmentIDs: ["s", "t"], sfxSourceTexts: ["s": "ドン", "t": "こんにちは"])
        #expect(parsed == [RemoteTranslatedSegment(id: "s", text: "쾅", isSFX: true, textRole: .sfx),
                           RemoteTranslatedSegment(id: "t", text: "안녕", isSFX: false, textRole: .dialogue)])
        let wrapped = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "finish_reason": "stop",
            "message": ["role": "assistant", "content": content]]]])
        #expect(try TranslationHTTPCodec.responseTranslations(from: wrapped, protocol: .chatCompletions, expectedSegmentIDs: ["s", "t"],
            sfxSourceTexts: ["s": "ドン", "t": "こんにちは"]) == parsed)

        let good = #"{"translations":[{"id":"s","text":"a"}]}"#
        #expect(throws: RemoteTranslationError.invalidResponse("the chat completion was truncated")) {
            try TranslationHTTPCodec.streamedChatTranslations(from: try Self.sse([good], finish: "length"), expectedSegmentIDs: ["s"])
        }
        #expect(throws: RemoteTranslationError.invalidResponse("the chat completion did not finish with text")) {
            try TranslationHTTPCodec.streamedChatTranslations(from: try Self.sse([good], finish: nil, done: false), expectedSegmentIDs: ["s"])
        }
        #expect(throws: RemoteTranslationError.refused) {
            try TranslationHTTPCodec.streamedChatTranslations(from: try Self.sse([good], finish: "content_filter"), expectedSegmentIDs: ["s"])
        }
        #expect(throws: RemoteTranslationError.invalidResponse("the chat completion stream returned an error")) {
            try TranslationHTTPCodec.streamedChatTranslations(from: Data("data: {\"error\":{\"message\":\"x\"}}\n\n".utf8),
                                                              expectedSegmentIDs: ["s"])
        }
    }

    // MARK: Client

    @Test func clientUpgradesVerifiedVLLMEndpointToStreamedCompactOutput() async throws {
        let transport = ScriptedStreamingTransport(mode: .streamed)
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        let request = Self.request(["おい", "待て", "ドン"])
        let first = try await client.translate(request, configuration: Self.configuration())
        let second = try await client.translate(request, configuration: Self.configuration())
        #expect(first == second)
        let kinds = await transport.kinds
        #expect(kinds == [.standard, .compact])
        #expect(client.compactOutput.state(for: try RemoteTranslationClient.compactCapabilityKey(for: Self.configuration())) == .verified)
    }

    @Test func clientFallsBackOnceWhenCompactOptionsAreRejected() async throws {
        let transport = ScriptedStreamingTransport(mode: .rejectCompact)
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        let request = Self.request(["おい"])
        let first = try await client.translate(request, configuration: Self.configuration())
        let second = try await client.translate(request, configuration: Self.configuration())
        let third = try await client.translate(request, configuration: Self.configuration())
        #expect(first == second && second == third)
        #expect(await transport.kinds == [.standard, .compact, .standard, .standard])
        #expect(client.compactOutput.state(for: try RemoteTranslationClient.compactCapabilityKey(for: Self.configuration())) == .unsupported)
    }

    @Test func clientFallsBackWhenUnverifiedCompactAnswerIsMalformed() async throws {
        let transport = ScriptedStreamingTransport(mode: .malformedCompact)
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        let request = Self.request(["おい"])
        _ = try await client.translate(request, configuration: Self.configuration())
        let second = try await client.translate(request, configuration: Self.configuration())
        #expect(second.translations == [RemoteTranslatedSegment(id: "segment-0", text: "ko:おい")])
        #expect(await transport.kinds == [.standard, .compact, .standard])
    }

    @Test func unknownServersKeepStandardRequests() async throws {
        let transport = ScriptedStreamingTransport(mode: .streamed, fingerprint: nil)
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
        let request = Self.request(["おい"])
        for _ in 0..<3 { _ = try await client.translate(request, configuration: Self.configuration()) }
        #expect(await transport.kinds == [.standard, .standard, .standard])
    }

    @Test func responsesCompactUpgradeAndFallbackPreserveResults() async throws {
        let configuration = Self.configuration(apiProtocol: .responses)
        let request = Self.request(["おい", "待て"])
        for mode in [ScriptedStreamingTransport.Mode.streamed, .rejectCompact, .malformedCompact] {
            let transport = ScriptedStreamingTransport(mode: mode)
            let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: transport)
            let first = try await client.translate(request, configuration: configuration)
            let second = try await client.translate(request, configuration: configuration)
            let third = try await client.translate(request, configuration: configuration)
            #expect(first == second && second == third)
            let succeeds = mode == .streamed
            #expect(await transport.kinds == (succeeds ? [.standard, .compact, .compact] : [.standard, .compact, .standard, .standard]))
            #expect(client.compactOutput.state(for: try RemoteTranslationClient.compactCapabilityKey(for: configuration)) == (succeeds ? .verified : .unsupported))
        }
        let unknown = ScriptedStreamingTransport(mode: .streamed, fingerprint: nil)
        let client = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: unknown)
        for _ in 0..<3 { _ = try await client.translate(request, configuration: configuration) }
        #expect(await unknown.kinds == [.standard, .standard, .standard])
        let versioned = ScriptedStreamingTransport(mode: .streamed, fingerprint: nil, versionHeader: "0.27.0")
        let versionedClient = RemoteTranslationClient(credentialStore: StreamingTestCredential(), transport: versioned)
        for _ in 0..<2 { _ = try await versionedClient.translate(request, configuration: configuration) }
        #expect(await versioned.kinds == [.standard, .compact])
    }
}

private struct StreamingTestCredential: TranslationCredentialProviding {
    func secret(for account: String) throws -> String { "unit-test-only" }
}

private actor MetadataStreamingTransport: TranslationHTTPTransport {
    let translation: ScriptedStreamingTransport
    let status: Int
    let version: String?
    private(set) var metadataCalls = 0

    init(status: Int = 200, version: String? = "0.27.0", mode: ScriptedStreamingTransport.Mode = .streamed) {
        self.status = status
        self.version = version
        translation = ScriptedStreamingTransport(mode: mode)
    }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        if request.httpMethod == "GET" {
            metadataCalls += 1
            #expect(request.url?.absoluteString == "https://llm.example/v1/models")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-only")
            #expect(request.timeoutInterval == 1.5 && maximumResponseBytes == 64 * 1024)
            var headers: [String: String] = [:]
            headers["X-vLLM-Version"] = version
            return TranslationHTTPResponse(data: Data("{\"data\":[]}".utf8), response:
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        return try await translation.data(for: request, maximumResponseBytes: maximumResponseBytes, bypassesProxy: bypassesProxy)
    }
}

/// Answers "ko:<source>" for every segment. Standard requests receive a
/// buffered chat completion; compact requests receive SSE.
private actor ScriptedStreamingTransport: TranslationHTTPTransport {
    enum Mode { case streamed, rejectCompact, malformedCompact }
    enum Kind: Equatable { case standard, compact }
    let mode: Mode
    let fingerprint: String?
    let versionHeader: String?
    private(set) var kinds: [Kind] = []

    init(mode: Mode, fingerprint: String? = "vllm-0.27.0-test", versionHeader: String? = nil) {
        self.mode = mode
        self.fingerprint = fingerprint
        self.versionHeader = versionHeader
    }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        let httpBody = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let compact = root["structured_outputs"] != nil
        let responses = request.url?.lastPathComponent == "responses"
        let text: String
        if responses {
            #expect(root["stream"] == nil)
            #expect(compact == (root["text"] == nil))
            let input = try #require(root["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: Any]])
            // A page image, when attached, precedes the segment JSON.
            text = try #require(content.first(where: { $0["type"] as? String == "input_text" })?["text"] as? String)
        } else {
            #expect(compact == (root["stream"] as? Bool == true))
            #expect(compact == (root["response_format"] == nil))
            let messages = try #require(root["messages"] as? [[String: Any]])
            if let plain = messages.last?["content"] as? String {
                text = plain
            } else {
                let parts = try #require(messages.last?["content"] as? [[String: Any]])
                text = try #require(parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String)
            }
        }
        kinds.append(compact ? .compact : .standard)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let segments = try #require(payload["segments"] as? [[String: Any]])
        // Role-classifying page requests require text_role between id and text.
        let role = String(decoding: httpBody, as: UTF8.self).contains("text_role") ? "\"text_role\":\"dialogue\"," : ""
        let items = segments.map { "{\"id\":\"\($0["id"] as! String)\"," + role + "\"text\":\"ko:\($0["text"] as! String)\"}" }
        let content = "{\"translations\":[" + items.joined(separator: ",") + "]}"
        if compact, mode == .rejectCompact {
            return TranslationHTTPResponse(data: Data("{\"error\":{\"message\":\"bad\"}}".utf8),
                response: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        if compact {
            let pattern = try #require((root["structured_outputs"] as? [String: Any])?["regex"] as? String)
            let regex = try NSRegularExpression(pattern: "^(?:" + pattern + ")$")
            #expect(regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil)
        }
        if compact, !responses {
            let streamed = mode == .malformedCompact ? "{\"translations\":[" : content
            let pieces = items.enumerated().map { ($0.offset == 0 ? "{\"translations\":[" : ",") + $0.element } + ["]}"]
            let body = try TranslationStreamingTests.sse(mode == .malformedCompact ? [streamed] : pieces)
            return TranslationHTTPResponse(data: body, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!)
        }
        var envelope: [String: Any] = ["choices": [["index": 0, "finish_reason": "stop",
                                                    "message": ["role": "assistant", "content": content]]]]
        if responses {
            envelope = ["status": "completed", "output": [["type": "message", "status": "completed",
                "content": [["type": "output_text", "text": compact && mode == .malformedCompact ? "{" : content]]]]]
        }
        envelope["system_fingerprint"] = fingerprint
        let body = try JSONSerialization.data(withJSONObject: envelope)
        var headers = ["Content-Type": "application/json"]
        headers["X-vLLM-Version"] = versionHeader
        return TranslationHTTPResponse(data: body, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: headers)!)
    }
}
