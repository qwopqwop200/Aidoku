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
        settings.filterJapaneseSFX = true
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
        #expect(!output.contains { $0.id == "local" }) // Local OR LLM, never both required.
        #expect(output.first { $0.id == "llm" }?.translation == "BOOM")
        #expect(output.first { $0.id == "llm" }?.preservesOriginalText == true)
        #expect(!ReaderTranslationRegion.overlayItems(output, imageSize: image.size).contains { $0.sourceText == "BOOM" })
        #expect(output.filter { $0.id.hasPrefix("d") }.allSatisfy { $0.translation == "번역" })
        let captured = await transport.captured
        #expect(captured.count == (try ReaderTranslationService.requests(regions: input, settings: settings)).count)
        #expect(captured.allSatisfy { !$0.texts.contains("ドン") && $0.sfx && $0.image == withImage })
        #expect(captured.allSatisfy { $0.hasBounds == withImage })
        #expect(captured.allSatisfy { $0.instructions.contains(withImage ? "An image is attached" : "No image is attached") })
    }

    @Test func persistenceCacheIdentityAndCanonicalGeometry() throws {
        let name = "LLMSFXSettings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let off = ReaderTranslationSettings(defaults: defaults)
        #expect(!off.filterSFXWithLLM)
        var on = off; on.filterSFXWithLLM = true
        try on.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).filterSFXWithLLM)
        #expect(!off.hasSameTranslation(as: on))
        #expect(ReaderTranslationCacheIdentity.ocr(page: "p", settings: off) == ReaderTranslationCacheIdentity.ocr(page: "p", settings: on))
        #expect(ReaderTranslationCacheIdentity.unfilteredTranslation(page: "p", settings: off) != ReaderTranslationCacheIdentity.unfilteredTranslation(page: "p", settings: on))
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

    @Test func invalidClassificationCannotSilentlyRemoveText() throws {
        for invalid in ["true" as Any, 1, NSNull()] {
            let payload = try JSONSerialization.data(withJSONObject: ["translations": [["id": "s", "text": "translated", "is_sfx": invalid]]])
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
        #expect(String(decoding: on, as: UTF8.self).contains("is_sfx"))
    }
}

private struct SFXCredential: TranslationCredentialProviding {
    func secret(for account: String) throws -> String { "test-only" }
}

private actor SFXTransport: TranslationHTTPTransport {
    struct Capture: Sendable { let texts: [String]; let sfx: Bool; let image: Bool; let hasBounds: Bool; let instructions: String }
    var captured: [Capture] = []
    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let isResponses = root["input"] != nil
        let messages = try #require(root[isResponses ? "input" : "messages"] as? [[String: Any]])
        let instructions = try #require(isResponses ? root["instructions"] as? String : messages.first?["content"] as? String)
        let content = try #require(messages.last?["content"])
        let parts = content as? [[String: Any]]
        let text = try #require(content as? String ?? parts?.first?["text"] as? String)
        let source = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let segments = try #require(source["segments"] as? [[String: Any]])
        let values = try segments.map { item -> [String: Any] in
            let original = try #require(item["text"] as? String)
            return ["id": try #require(item["id"] as? String), "text": "번역", "is_sfx": original == "BOOM"]
        }
        captured.append(.init(texts: segments.compactMap { $0["text"] as? String }, sfx: instructions.contains("is_sfx"), image: (parts?.count ?? 0) > 1,
                              hasBounds: segments.allSatisfy { $0["bbox"] != nil }, instructions: instructions))
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": values]), as: UTF8.self)
        let envelope: [String: Any] = isResponses ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": payload]]]]] :
            ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": payload]]]]
        return TranslationHTTPResponse(data: try JSONSerialization.data(withJSONObject: envelope), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
