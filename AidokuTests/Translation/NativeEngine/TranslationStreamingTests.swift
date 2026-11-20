// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
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
            let pieces = items.enumerated().map { ($0.offset == 0 ? "{\"translations\":[" : ",") + $0.element } + ["]}"]
            let body = try TranslationStreamingTests.sse(pieces)
            return TranslationHTTPResponse(data: body, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!)
        }
        var envelope: [String: Any] = ["choices": [["index": 0, "finish_reason": "stop",
                                                    "message": ["role": "assistant", "content": content]]]]
        if responses {
            envelope = ["status": "completed", "output": [["type": "message", "status": "completed",
                "content": [["type": "output_text", "text": content]]]]]
        }
        envelope["system_fingerprint"] = "vllm-0.27.0-test"
        let body = try JSONSerialization.data(withJSONObject: envelope)
        return TranslationHTTPResponse(data: body, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!)
    }
}
