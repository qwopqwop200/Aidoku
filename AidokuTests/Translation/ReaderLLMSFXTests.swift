import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderLLMSFXTests {
    @Test func sfxRoleRejectsObsoleteDuplicateFlag() throws {
        for enabled in [false, true] {
            var item: [String: Any] = ["id": "effect", "text": "잘못된 번역", "text_role": "sfx"]
            if enabled { item["is_sfx"] = false }
            let payload = try JSONSerialization.data(withJSONObject: ["translations": [item]])
            let wire = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": String(decoding: payload, as: UTF8.self)]]]])
            if enabled {
                #expect(throws: RemoteTranslationError.self) {
                    try TranslationHTTPCodec.responseTranslations(from: wire, protocol: .chatCompletions,
                        expectedSegmentIDs: ["effect"], sfxSourceTexts: ["effect": "な"], backgroundSourceTexts: ["effect": "な"])
                }
            } else {
                let result = try TranslationHTTPCodec.responseTranslations(from: wire, protocol: .chatCompletions,
                    expectedSegmentIDs: ["effect"], backgroundSourceTexts: ["effect": "な"])
                #expect(result.first?.text == "잘못된 번역")
                #expect(result.first?.textRole == .sfx && result.first?.isSFX == true)
            }
        }
    }

    @Test func backgroundRolePreservesTranslatedOutput() throws {
        for role in ["background", "dialogue", "narration", "story_text", "sfx", "error", "unknown", "invalid"] {
            let payload = try JSONSerialization.data(withJSONObject: ["translations": [["id": "b", "text": "번역", "text_role": role]]])
            let wire = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": String(decoding: payload, as: UTF8.self)]]]])
            if role == "invalid" || role == "unknown" {
                #expect(throws: RemoteTranslationError.self) {
                    try TranslationHTTPCodec.responseTranslations(from: wire, protocol: .chatCompletions, expectedSegmentIDs: ["b"], backgroundSourceTexts: ["b": "看板"])
                }
            } else {
                let result = try TranslationHTTPCodec.responseTranslations(from: wire, protocol: .chatCompletions, expectedSegmentIDs: ["b"], backgroundSourceTexts: ["b": "看板"])
                #expect(result.first?.text == "번역")
                #expect(result.first?.textRole?.rawValue == role)
            }
        }
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions])
    func smallEffectFlagPreservesModelTranslation(apiProtocol: RemoteTranslationProtocol) throws {
        let values: [[String: Any]] = [
            ["id": "small", "text": "움찔", "text_role": "sfx"],
            ["id": "digit", "text": "346", "text_role": "sfx"],
            ["id": "reply", "text": "기다려", "text_role": "dialogue"]
        ]
        let payload = try JSONSerialization.data(withJSONObject: ["translations": values])
        let content = String(decoding: payload, as: UTF8.self)
        let envelope: [String: Any] = apiProtocol == .responses
            ? ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": content]]]]]
            : ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": content]]]]
        let result = try TranslationHTTPCodec.responseTranslations(
            from: JSONSerialization.data(withJSONObject: envelope), protocol: apiProtocol,
            expectedSegmentIDs: ["small", "digit", "reply"],
            sfxSourceTexts: ["small": "びくっ", "digit": "346", "reply": "待って"])
        #expect(result.map(\.text) == ["움찔", "346", "기다려"])
        #expect(result.map(\.isSFX) == [true, true, false])
    }

    @Test func invalidClassificationCannotSilentlyRemoveText() throws {
        for invalid in ["true" as Any, 1, NSNull()] {
            let payload = try JSONSerialization.data(withJSONObject: ["translations": [["id": "s", "text": "translated", "text_role": invalid]]])
            let wire = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": String(decoding: payload, as: UTF8.self)]]]])
            #expect(throws: RemoteTranslationError.self) {
                try TranslationHTTPCodec.responseTranslations(from: wire, protocol: .chatCompletions, expectedSegmentIDs: ["s"], sfxSourceTexts: ["s": "BANG"])
            }
        }
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", sourceText: "Hello")
        let off = try TranslationHTTPCodec.requestBody(configuration: ReaderTranslationSettings().configuration, request: request)
        #expect(!String(decoding: off, as: UTF8.self).contains("is_sfx"))
        request.filtersSFX = true
        let on = try TranslationHTTPCodec.requestBody(configuration: ReaderTranslationSettings().configuration, request: request)
        #expect(!String(decoding: on, as: UTF8.self).contains("is_sfx"))
        #expect(String(decoding: on, as: UTF8.self).contains("text_role"))
    }
}

private struct SFXCredential: TranslationCredentialProviding {
    func secret(for account: String) throws -> String { "test-only" }
}

private actor SFXTransport: TranslationHTTPTransport {
    struct Capture: Sendable {
        let texts: [String]
        let classifiesRole: Bool
        let image: Bool
        let hasBounds: Bool
    }
    var captured: [Capture] = []
    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let isResponses = root["input"] != nil
        let formatRoot = try #require(root[isResponses ? "text" : "response_format"] as? [String: Any])
        let format = try #require(formatRoot[isResponses ? "format" : "json_schema"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let translations = try #require(properties["translations"] as? [String: Any])
        let items = try #require(translations["items"] as? [String: Any])
        let branches = items["anyOf"] as? [[String: Any]] ?? [items]
        let required = try #require(branches.first?["required"] as? [String])
        for branch in branches {
            let itemProperties = try #require(branch["properties"] as? [String: Any])
            #expect(Set(required) == Set(itemProperties.keys))
            #expect(Set(try #require(branch["required"] as? [String])) == Set(required))
            #expect(branch["additionalProperties"] as? Bool == false)
        }
        #expect((root["temperature"] as? NSNumber)?.doubleValue == 1.0)
        #expect((root["top_p"] as? NSNumber)?.doubleValue == 0.95)
        #expect(root["min_p"] == nil)
        if root["top_k"] != nil {
            #expect((root["repetition_penalty"] as? NSNumber)?.doubleValue == 1.08)
        } else {
            #expect(root["repetition_penalty"] == nil)
        }
        #expect((root[isResponses ? "max_output_tokens" : "max_tokens"] as? NSNumber)?.intValue == 8192)
        if root["top_k"] != nil {
            #expect((root["top_k"] as? NSNumber)?.intValue == 64)
        }

        let messages = try #require(root[isResponses ? "input" : "messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"])
        let parts = content as? [[String: Any]]
        let textPart = parts?.first { ["text", "input_text"].contains($0["type"] as? String ?? "") }
        let text = try #require(content as? String ?? textPart?["text"] as? String)
        let source = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let segments = try #require(source["segments"] as? [[String: Any]])
        let values = try segments.map { item -> [String: Any] in
            let original = try #require(item["text"] as? String)
            var value: [String: Any] = ["id": try #require(item["id"] as? String), "text": "번역"]
            if required.contains("text_role") {
                value["text_role"] = original == "BOOM" ? "sfx" :
                    (original == "南館2F" ? "background" : (original == "学園祭開幕" ? "narration" : "dialogue"))
            }
            return value
        }
        #expect(Set(required) == ["id", "text_role", "text"])
        captured.append(.init(texts: segments.compactMap { $0["text"] as? String }, classifiesRole: required.contains("text_role"),
                              image: parts?.contains { ["image_url", "input_image"].contains($0["type"] as? String ?? "") } == true,
                              hasBounds: segments.allSatisfy { ($0["box_2d"] as? [Int])?.count == 4 }))
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": values]), as: UTF8.self)
        let envelope: [String: Any] = isResponses ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": payload]]]]] :
            ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": payload]]]]
        return TranslationHTTPResponse(data: try JSONSerialization.data(withJSONObject: envelope), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
