// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation
import Testing
@testable import Aidoku

struct TranslationStreamingTests {
    private static func request(_ texts: [String]) -> RemoteTranslationRequest {
        RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko",
            segments: texts.enumerated().map { RemoteTranslationSegment(id: "segment-\($0.offset)", text: $0.element) })
    }

    private static func configuration() -> RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(provider: .custom, apiProtocol: .chatCompletions, baseURL: "https://llm.example/v1",
                                       model: "gemma", credentialAccount: "test", reasoningEffort: .none)
    }

    /// Builds an SSE body whose content deltas are `pieces`.
    static func sse(_ pieces: [String], finish: String = "stop") throws -> Data {
        var body = ""
        for piece in pieces {
            let chunk: [String: Any] = ["object": "chat.completion.chunk",
                                        "choices": [["index": 0, "delta": ["content": piece], "finish_reason": NSNull()]]]
            body += "data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\n\n"
        }
        let chunk: [String: Any] = ["choices": [["index": 0, "delta": [:] as [String: Any], "finish_reason": finish]]]
        body += "data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\r\n\r\n"
        body += ": keep-alive\n\ndata: {\"choices\":[],\"usage\":{\"completion_tokens\":3}}\n\ndata: [DONE]\n\n"
        return Data(body.utf8)
    }

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
                try decoder.consume(body.subdata(in: offset..<end))
                offset = end
            }
            try decoder.finish()
            #expect(decoder.content == content)
            #expect(decoder.finishReason == "stop")
        }
    }

    @Test func streamedRefusalAndErrorChunksAreRejected() throws {
        let good = #"{"translations":[{"id":"s","text":"a"}]}"#
        #expect(throws: RemoteTranslationError.refused) {
            try TranslationHTTPCodec.streamedChatTranslations(from: try Self.sse([good], finish: "content_filter"), expectedSegmentIDs: ["s"])
        }
        #expect(throws: RemoteTranslationError.invalidResponse("the chat completion stream returned an error")) {
            try TranslationHTTPCodec.streamedChatTranslations(from: Data("data: {\"error\":{\"message\":\"x\"}}\n\n".utf8),
                                                              expectedSegmentIDs: ["s"])
        }
    }

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
}

private struct StreamingTestCredential: TranslationCredentialProviding {
    func secret(for account: String) throws -> String { "unit-test-only" }
}

/// Answers "ko:<source>" for every segment. Standard requests receive a
/// buffered chat completion; compact requests receive SSE.
private actor ScriptedStreamingTransport: TranslationHTTPTransport {
    enum Mode { case streamed, rejectCompact }
    enum Kind: Equatable { case standard, compact }
    let mode: Mode
    private(set) var kinds: [Kind] = []

    init(mode: Mode) { self.mode = mode }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        let httpBody = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let compact = root["structured_outputs"] != nil
        #expect(compact == (root["stream"] as? Bool == true))
        #expect(compact == (root["response_format"] == nil))
        let messages = try #require(root["messages"] as? [[String: Any]])
        let text = try #require(messages.last?["content"] as? String)
        kinds.append(compact ? .compact : .standard)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let segments = try #require(payload["segments"] as? [[String: Any]])
        let items = segments.map { "{\"id\":\"\($0["id"] as! String)\",\"text\":\"ko:\($0["text"] as! String)\"}" }
        let content = "{\"translations\":[" + items.joined(separator: ",") + "]}"
        if compact, mode == .rejectCompact {
            return TranslationHTTPResponse(data: Data("{\"error\":{\"message\":\"bad\"}}".utf8),
                response: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        if compact {
            let pattern = try #require((root["structured_outputs"] as? [String: Any])?["regex"] as? String)
            let regex = try NSRegularExpression(pattern: "^(?:" + pattern + ")$")
            #expect(regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil)
            let pieces = items.enumerated().map { ($0.offset == 0 ? "{\"translations\":[" : ",") + $0.element } + ["]}"]
            let body = try TranslationStreamingTests.sse(pieces)
            return TranslationHTTPResponse(data: body, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!)
        }
        let envelope: [String: Any] = ["choices": [["index": 0, "finish_reason": "stop",
            "message": ["role": "assistant", "content": content]]], "system_fingerprint": "vllm-0.27.0-test"]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        return TranslationHTTPResponse(data: body, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!)
    }
}
