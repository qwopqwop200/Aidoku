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
        #expect(output.first { $0.id == "llm" }?.translation == "BOOM")
        #expect(output.first { $0.id == "llm" }?.preservesOriginalText == true)
        #expect(!ReaderTranslationRegion.overlayItems(output, imageSize: image.size).contains { $0.sourceText == "BOOM" })
        #expect(output.filter { $0.id.hasPrefix("d") }.allSatisfy { $0.translation == "번역" })
        let captured = await transport.captured
        #expect(captured.count == (try ReaderTranslationService.requests(regions: input, settings: settings)).count)
        #expect(captured.flatMap(\.texts).contains("ドン"))
        #expect(captured.allSatisfy { $0.sfx && $0.image == withImage })
        #expect(captured.allSatisfy { $0.hasBounds == withImage })
        #expect(captured.allSatisfy { $0.instructions.contains(withImage ? "An image is attached" : "No image is attached") })
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
        #expect(output[0].translation == "南館2F")
        #expect(output[0].preservesOriginalText)
        #expect(output[1].translation == "번역")
        #expect(output[2].translation == "번역")
        #expect(output[3].preservesOriginalText == sfx)
        #expect(!ReaderTranslationRegion.overlayItems(output, imageSize: CGSize(width: 100, height: 100)).contains { $0.sourceText == "南館2F" })
        let captured = await transport.captured
        #expect(captured.count == (try ReaderTranslationService.requests(regions: input, settings: settings)).count)
        let coordinateInstruction = withImage
            ? (sfx ? "normalized from the top left" : "using its normalized bbox")
            : (sfx ? "Do not infer" : "a guessed scene cannot establish a physical sign")
        #expect(captured.allSatisfy { $0.hasBounds && $0.image == withImage && $0.instructions.contains(coordinateInstruction) })
        let off = ReaderTranslationSettings(defaults: defaults)
        #expect(!off.filterBackgroundWithLLM)
        try settings.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).filterBackgroundWithLLM)
        var withoutBackground = settings
        withoutBackground.filterBackgroundWithLLM = false
        #expect(!settings.hasSameTranslation(as: withoutBackground))
        #expect(ReaderTranslationCacheIdentity.ocr(page: "p", settings: settings) == ReaderTranslationCacheIdentity.ocr(page: "p", settings: withoutBackground))
        #expect(ReaderTranslationCacheIdentity.unfilteredTranslation(page: "p", settings: settings) != ReaderTranslationCacheIdentity.unfilteredTranslation(page: "p", settings: withoutBackground))
        #expect(TitleTranslation.cacheKey("title", kind: .manga, settings: settings) == TitleTranslation.cacheKey("title", kind: .manga, settings: withoutBackground))
        let request = try #require(ReaderTranslationService.requests(regions: input, settings: settings).first)
        #expect(request.canonicalizedForTranslationSemantics().request.filtersBackground == true)
        var plain = request
        plain.filtersBackground = nil
        let endpoint = try settings.configuration.validatedEndpoint()
        #expect(TranslationCacheKey(configuration: settings.configuration, endpoint: endpoint, request: request) != TranslationCacheKey(configuration: settings.configuration, endpoint: endpoint, request: plain))
    }

    // Opt-in device/provider regression. The fixture contains only source text and image,
    // never credentials. Consume the input once so ordinary test runs cannot spend API calls.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("BackgroundFilterValidation/input.json").path)))
    func liveBackgroundSignsPreserveCaption() async throws {
        let folder = URL.documentsDirectory.appendingPathComponent("BackgroundFilterValidation")
        let inputURL = folder.appendingPathComponent("input.json")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let input = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: Data(contentsOf: inputURL)).map(\.region)
        let image = try #require(UIImage(contentsOfFile: folder.appendingPathComponent("original-top.jpg").path))
        var settings = ReaderTranslationSettings()
        settings.filterBackgroundWithLLM = true
        settings.includePageImage = true
        let result = try await ReaderTranslationService().translate(regions: input, settings: settings, image: image)
        let evidence = result.map { ["id": $0.id, "source": $0.source, "translation": $0.translation ?? "", "preserved": $0.preservesOriginalText] as [String: Any] }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("result.json"))
        #expect(result.count == 5)
        #expect(result.first?.preservesOriginalText == false)
        #expect(result.dropFirst().allSatisfy { $0.preservesOriginalText })
        #expect(ReaderTranslationRegion.overlayItems(result, imageSize: image.size).count == 1)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let host = try #require(window.rootViewController?.view)
        let rendered = try await ReaderTranslationImageExporter.render(image: image, regions: result, settings: settings,
            viewport: CGSize(width: 390, height: 700), aspectFit: true, host: host)
        try #require(rendered.pngData()).write(to: folder.appendingPathComponent("rendered.png"))
    }

    @Test func sfxRoleSurvivesContradictoryFlagOnlyWhenEnabled() throws {
        for enabled in [false, true] {
            var item: [String: Any] = ["id": "effect", "text": "잘못된 번역", "text_role": "sfx"]
            if enabled { item["is_sfx"] = false }
            let payload = try JSONSerialization.data(withJSONObject: ["translations": [item]])
            let wire = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": String(decoding: payload, as: UTF8.self)]]]])
            let result = try TranslationHTTPCodec.responseTranslations(from: wire, protocol: .chatCompletions, expectedSegmentIDs: ["effect"],
                sfxSourceTexts: enabled ? ["effect": "な"] : nil, backgroundSourceTexts: ["effect": "な"])
            #expect(result.first?.text == (enabled ? "な" : "잘못된 번역"))
            #expect(result.first?.isSFX == (enabled ? true : nil))
        }
    }

    // Opt-in real-page test uses the installed account without exporting its credential.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("SFXFragmentValidation/input.json").path)))
    func liveSFXFragmentsPreserveDialogue() async throws {
        let folder = URL.documentsDirectory.appendingPathComponent("SFXFragmentValidation")
        let inputURL = folder.appendingPathComponent("input.json")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let input = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: Data(contentsOf: inputURL)).map(\.region)
        let image = try #require(UIImage(contentsOfFile: folder.appendingPathComponent("source.png").path))
        var settings = ReaderTranslationSettings()
        settings.filterBackgroundWithLLM = true
        settings.filterSFXWithLLM = true
        settings.includePageImage = true
        let audit = QualityTranslationAuditTransport(base: BoundedURLSessionTransport(), outputDirectory: folder)
        let liveClient = RemoteTranslationClient(transport: audit)
        let result = try await ReaderTranslationService(client: liveClient).translate(regions: input, settings: settings, image: image)
        try await audit.flush(to: folder.appendingPathComponent("response-audit.json"))
        let evidence = result.map { ["id": $0.id, "source": $0.source, "translation": $0.translation ?? "", "preserved": $0.preservesOriginalText] as [String: Any] }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("result.json"))
        #expect(result.count == input.count)
        #expect(result.prefix(2).allSatisfy { $0.preservesOriginalText })
        #expect(result.dropFirst(2).allSatisfy { !$0.preservesOriginalText && $0.translation != nil })
        #expect(ReaderTranslationRegion.overlayItems(result, imageSize: image.size).count == input.count - 2)
        // Recognition errors must not turn visually matched effects into spoken words.
        let corrupted = input.enumerated().map { index, region in
            index < 2 ? ReaderTranslationRegion(id: region.id, rect: region.rect, source: index == 0 ? "S" : "7") : region
        }
        var corruptionSettings = settings
        corruptionSettings.sourceLanguage = "auto"
        corruptionSettings.translationSourceLanguages = [] // Exercise the LLM, not the language allowlist.
        let corruptedResult = try await ReaderTranslationService(client: liveClient).translate(regions: corrupted, settings: corruptionSettings, image: image)
        try await audit.flush(to: folder.appendingPathComponent("response-audit.json"))
        let corruptedEvidence = corruptedResult.map { ["id": $0.id, "source": $0.source, "translation": $0.translation ?? "", "preserved": $0.preservesOriginalText] as [String: Any] }
        try JSONSerialization.data(withJSONObject: corruptedEvidence, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("corrupted-result.json"))
        #expect(corruptedResult.count == input.count)
        #expect(corruptedResult.prefix(2).allSatisfy { $0.preservesOriginalText })
        #expect(corruptedResult.dropFirst(2).allSatisfy { !$0.preservesOriginalText && $0.translation != nil })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let host = try #require(window.rootViewController?.view)
        let rendered = try await ReaderTranslationImageExporter.render(image: image, regions: result, settings: settings,
            viewport: CGSize(width: 390, height: 700), aspectFit: true, host: host)
        try #require(rendered.pngData()).write(to: folder.appendingPathComponent("rendered.png"))
    }

    @Test func backgroundRoleControlsPreservation() throws {
        for role in ["background", "dialogue", "narration", "story_text", "sfx", "unknown", "invalid"] {
            let payload = try JSONSerialization.data(withJSONObject: ["translations": [["id": "b", "text": "번역", "text_role": role]]])
            let wire = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": String(decoding: payload, as: UTF8.self)]]]])
            if role == "invalid" {
                #expect(throws: RemoteTranslationError.self) {
                    try TranslationHTTPCodec.responseTranslations(from: wire, protocol: .chatCompletions, expectedSegmentIDs: ["b"], backgroundSourceTexts: ["b": "看板"])
                }
            } else {
                let result = try TranslationHTTPCodec.responseTranslations(from: wire, protocol: .chatCompletions, expectedSegmentIDs: ["b"], backgroundSourceTexts: ["b": "看板"])
                #expect(result.first?.text == (role == "background" ? "看板" : "번역"))
            }
        }
        #expect(TranslationHTTPCodec.backgroundInstructions(hasImage: true).contains("Relevance alone is not a plot clue."))
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
            #expect(reason.contains("no page image"))
        }
        #expect(await transport.captured.isEmpty)
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions])
    func smallEffectFlagPreservesSourceEvenWhenModelTranslates(apiProtocol: RemoteTranslationProtocol) throws {
        let values: [[String: Any]] = [
            ["id": "small", "text": "invented name", "is_sfx": true],
            ["id": "digit", "text": "346", "is_sfx": true],
            ["id": "reply", "text": "기다려", "is_sfx": false]
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
        #expect(result.map(\.text) == ["びくっ", "346", "기다려"])
        #expect(result.map(\.isSFX) == [true, true, false])
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
        let formatRoot = try #require(root[isResponses ? "text" : "response_format"] as? [String: Any])
        let format = try #require(formatRoot[isResponses ? "format" : "json_schema"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let translations = try #require(properties["translations"] as? [String: Any])
        let items = try #require(translations["items"] as? [String: Any])
        let required = try #require(items["required"] as? [String])
        let itemProperties = try #require(items["properties"] as? [String: Any])
        #expect(Set(required) == Set(itemProperties.keys))
        #expect(items["additionalProperties"] as? Bool == false)

        let messages = try #require(root[isResponses ? "input" : "messages"] as? [[String: Any]])
        let instructions = try #require(isResponses ? root["instructions"] as? String : messages.first?["content"] as? String)
        let content = try #require(messages.last?["content"])
        let parts = content as? [[String: Any]]
        let textPart = parts?.first { ["text", "input_text"].contains($0["type"] as? String ?? "") }
        let text = try #require(content as? String ?? textPart?["text"] as? String)
        let source = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let segments = try #require(source["segments"] as? [[String: Any]])
        let values = try segments.map { item -> [String: Any] in
            let original = try #require(item["text"] as? String)
            var value: [String: Any] = ["id": try #require(item["id"] as? String), "text": "번역"]
            if required.contains("is_sfx") { value["is_sfx"] = original == "BOOM" }
            if required.contains("text_role") {
                value["text_role"] = original == "南館2F" ? "background" : (original == "学園祭開幕" ? "narration" : "dialogue")
            }
            return value
        }
        captured.append(.init(texts: segments.compactMap { $0["text"] as? String }, sfx: required.contains("is_sfx"), image: (parts?.count ?? 0) > 1,
                              hasBounds: segments.allSatisfy { $0["bbox"] != nil }, instructions: instructions))
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": values]), as: UTF8.self)
        let envelope: [String: Any] = isResponses ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": payload]]]]] :
            ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": payload]]]]
        return TranslationHTTPResponse(data: try JSONSerialization.data(withJSONObject: envelope), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
