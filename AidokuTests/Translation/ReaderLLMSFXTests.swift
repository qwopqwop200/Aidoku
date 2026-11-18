import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderLLMSFXTests {
    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions], [false, true])
    func combinedTranslationAndClassification(apiProtocol: RemoteTranslationProtocol, withImage: Bool) async throws {
        let name = "LLMSFX.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://sfx-\(apiProtocol.rawValue)-\(withImage).example"
        settings.custom.apiProtocol = apiProtocol
        settings.model = "test"
        settings.filterSFXWithLLM = true
        settings.includePageImage = withImage
        let dialogue = (0..<3).map { i in
            ReaderTranslationRegion(id: "d\(i)", rect: CGRect(x: 0.05, y: 0.1 + Double(i) * 0.2, width: 0.2, height: 0.025), source: "今日は晴れですね")
        }
        let input = dialogue + [ReaderTranslationRegion(id: "local", rect: CGRect(x: 0.7, y: 0.7, width: 0.15, height: 0.12), source: "ドン"),
                               ReaderTranslationRegion(id: "llm", rect: CGRect(x: 0.7, y: 0.9, width: 0.1, height: 0.06), source: "BOOM")]
        let transport = SFXTransport()
        let client = RemoteTranslationClient(credentialStore: SFXCredential(), transport: transport)
        let service = ReaderTranslationService(client: client)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let output = try await service.translate(regions: input, settings: settings, image: image)
        #expect(output.first { $0.id == "local" }?.translation == "번역") // Only the LLM decides whether this is an effect.
        #expect(output.first { $0.id == "llm" }?.translation == "번역")
        #expect(output.first { $0.id == "llm" }?.preservesOriginalText == true)
        #expect(!ReaderTranslationRegion.overlayItems(output, imageSize: image.size).contains { $0.sourceText == "BOOM" })
        #expect(ReaderTranslationRegion.layoutItems(output, imageSize: image.size).contains {
            $0.sourceText == "BOOM" && $0.keepsSourceLettering
        })
        #expect(output.filter { $0.id.hasPrefix("d") }.allSatisfy { $0.translation == "번역" })
        let captured = await transport.captured
        #expect(captured.count == 1)
        #expect(captured.flatMap(\.texts).contains("ドン"))
        // Legacy display preferences cannot remove the page's image or classifications.
        #expect(captured.allSatisfy { $0.classifiesRole && $0.image && $0.hasBounds })
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions], 0..<4)
    func backgroundClassification(apiProtocol: RemoteTranslationProtocol, mode: Int) async throws {
        let sfx = mode & 1 != 0
        let withImage = mode & 2 != 0
        let name = "Background.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://background-\(UUID()).example"
        settings.custom.apiProtocol = apiProtocol
        settings.model = "test"
        settings.includePageImage = withImage
        settings.filterBackgroundWithLLM = true
        settings.filterSFXWithLLM = sfx
        let input = ["南館2F", "学園祭開幕", "メイドか", "BOOM"].enumerated().map {
            ReaderTranslationRegion(id: "b\($0.offset)", rect: CGRect(x: 0.1, y: Double($0.offset) * 0.2, width: 0.2, height: 0.1), source: $0.element)
        }
        let transport = SFXTransport()
        let service = ReaderTranslationService(client: RemoteTranslationClient(credentialStore: SFXCredential(), transport: transport))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let output = try await service.translate(regions: input, settings: settings, image: image)
        #expect(output.count == input.count)
        #expect(output[0].translation == "번역")
        #expect(!output[0].preservesOriginalText)
        #expect(output[1].translation == "번역")
        #expect(output[2].translation == "번역")
        #expect(output[3].translation == "번역" && !output[3].preservesOriginalText)
        #expect(ReaderTranslationRegion.overlayItems(output, imageSize: CGSize(width: 100, height: 100)).contains { $0.sourceText == "南館2F" })
        let captured = await transport.captured
        #expect(captured.count == 1)
        #expect(captured.allSatisfy { $0.hasBounds && $0.image && $0.classifiesRole })
        let off = ReaderTranslationSettings(defaults: defaults)
        #expect(off.filterBackgroundWithLLM)
        try settings.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).filterBackgroundWithLLM)
        var withoutBackground = settings
        withoutBackground.filterBackgroundWithLLM = false
        #expect(settings.hasSameTranslation(as: withoutBackground))
        #expect(ReaderTranslationCacheIdentity.ocr(page: "p", settings: settings) == ReaderTranslationCacheIdentity.ocr(page: "p", settings: withoutBackground))
        #expect(ReaderTranslationCacheIdentity.unfilteredTranslation(page: "p", settings: settings) == ReaderTranslationCacheIdentity.unfilteredTranslation(page: "p", settings: withoutBackground))
        #expect(TitleTranslation.cacheKey("title", kind: .manga, settings: settings) == TitleTranslation.cacheKey("title", kind: .manga, settings: withoutBackground))
        let request = try #require(ReaderTranslationService.requests(regions: input, settings: settings).first)
        #expect(request.canonicalizedForTranslationSemantics().request.filtersBackground == true)
        var plain = request
        plain.filtersBackground = nil
        let endpoint = try settings.configuration.validatedEndpoint()
        #expect(TranslationCacheKey(configuration: settings.configuration, endpoint: endpoint, request: request) != TranslationCacheKey(configuration: settings.configuration, endpoint: endpoint, request: plain))
    }

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

    @Test func persistenceCacheIdentityAndCanonicalGeometry() throws {
        let name = "LLMSFXSettings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var off = ReaderTranslationSettings(defaults: defaults)
        #expect(off.filterSFXWithLLM)
        off.filterSFXWithLLM = false
        var on = off; on.filterSFXWithLLM = true
        try on.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).filterSFXWithLLM)
        #expect(off.hasSameTranslation(as: on))
        #expect(ReaderTranslationCacheIdentity.ocr(page: "p", settings: off) == ReaderTranslationCacheIdentity.ocr(page: "p", settings: on))
        #expect(ReaderTranslationCacheIdentity.unfilteredTranslation(page: "p", settings: off) == ReaderTranslationCacheIdentity.unfilteredTranslation(page: "p", settings: on))
        try off.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).filterSFXWithLLM)
        #expect(TitleTranslation.cacheKey("name", kind: .manga, settings: off) == TitleTranslation.cacheKey("name", kind: .manga, settings: on))
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", segments: [.init(id: "ocr-9", text: "BOOM", bounds: [0.1, 0.2, 0.3, 0.4])])
        let endpoint = try on.configuration.validatedEndpoint()
        let base = TranslationCacheKey(configuration: on.configuration, endpoint: endpoint, request: request)
        request.filtersSFX = true
        let canonical = request.canonicalizedForTranslationSemantics()
        #expect(canonical.request.filtersSFX == true)
        #expect(canonical.request.segments[0].bounds == request.segments[0].bounds)
        #expect(TranslationCacheKey(configuration: on.configuration, endpoint: endpoint, request: request) != base)
        let restored = try canonical.restoringCallerSegmentIDs(in: .init(translations: [.init(id: "segment-0", text: "BOOM", isSFX: true)], source: .network, providerRequestID: nil))
        #expect(restored.translations[0].id == "ocr-9")
        #expect(restored.translations[0].isSFX == true)
    }

    @Test func imageAttachmentCannotSilentlyFallBackToTextOnly() async throws {
        let name = "MissingSFXImage.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://missing-image.example"
        settings.model = "test"
        settings.filterSFXWithLLM = true
        settings.includePageImage = true
        let transport = SFXTransport()
        let service = ReaderTranslationService(client: RemoteTranslationClient(credentialStore: SFXCredential(), transport: transport))
        do {
            _ = try await service.translate(regions: [
                ReaderTranslationRegion(id: "effect", rect: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1), source: "BOOM")
            ], settings: settings)
            Issue.record("An explicitly requested page image must not silently disappear")
        } catch let error as RemoteTranslationError {
            guard case .invalidRequest(let reason) = error else { throw error }
            #expect(!reason.isEmpty)
        }
        #expect(await transport.captured.isEmpty)
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
