import Foundation
import CryptoKit
import CoreGraphics
import UIKit
import Testing
@testable import Aidoku

@Suite(.serialized)
struct TranslationImageSupportTests {
    @Test func imageDigestMemoPreservesIdentityAcrossCopiesAndInvalidatesOnMutation() throws {
        var request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", sourceText: "画像")
        request.imageJPEG = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        let originalBytes = try #require(request.imageJPEG)
        let expected = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        #expect(request.imageDigest == expected)
        let canonical = request.canonicalizedForTranslationSemantics().request
        #expect(canonical.imageDigest == expected)
        var copied = request
        copied.imageJPEG?[2] = 3
        #expect(copied.imageDigest != expected)
        #expect(request.imageJPEG == originalBytes && request.imageDigest == expected)
        #expect(canonical.imageDigest == expected)
        copied.copyImageRepresentation(from: request)
        #expect(copied.imageDigest == expected)
        copied.imageJPEG = nil
        #expect(copied.imageDigest == nil)
        let encoded = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["imageDigestMemo"] == nil && object["imageDigest"] == nil)
        let decoded = try JSONDecoder().decode(RemoteTranslationRequest.self, from: encoded)
        #expect(decoded == request && decoded.imageDigest == expected)
        let configuration = RemoteTranslationConfiguration.openAI(model: "image-digest-fixture")
        let endpoint = try configuration.validatedEndpoint()
        #expect(TranslationCacheKey(configuration: configuration, endpoint: endpoint, request: request) ==
            TranslationCacheKey(configuration: configuration, endpoint: endpoint, request: decoded))
    }

    private static let roleSamples: [(String, String)] = [
        ("Please open the door and come inside.", "dialogue"),
        ("Three days later, the travelers returned.", "narration"),
        ("The secret of the ancient forest", "story_text"),
        ("Fresh bread sold here every morning", "background"),
        ("BOOM!", "sfx")
    ]

    // Shared immutable bytes only; settings, services and transports remain isolated per case.
    private static let fixtureSize = CGSize(width: 32, height: 32)
    private static let fixtureJPEG: Result<Data, Error> = Result {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: fixtureSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return try ReaderTranslationImagePreparation.translationJPEG(image)
    }

    private func settings() -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "ImageSettings.\(UUID().uuidString)")!)
        settings.provider = .custom
        settings.custom.baseURL = "https://image-support-tests.example/\(UUID().uuidString)/v1"
        settings.model = "text-model"
        settings.sourceLanguage = "auto"
        settings.targetLanguage = "ko"
        settings.includePageImage = true
        // English role samples; the default manga tier admits only CJK sources.
        settings.usesOCRLanguagePolicy = false
        return settings
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions])
    func unsupportedImageRetriesTextAndRemembersAcrossClients(apiProtocol: RemoteTranslationProtocol) async throws {
        let suite = "ImageSupport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let support = TranslationImageSupport(defaults: defaults)
        var settings = settings()
        settings.custom.apiProtocol = apiProtocol
        let transport = ImageSupportTransport()
        let client = RemoteTranslationClient(credentialStore: ImageSupportCredentials(), transport: transport, imageSupport: support)
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", sourceText: "Hello")
        request.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
        let first = try await client.translate(request, configuration: settings.configuration)
        #expect(first.translations.first?.text == "안녕하세요")
        #expect(support.status(for: settings.configuration) == .unsupported)
        let secondClient = RemoteTranslationClient(credentialStore: ImageSupportCredentials(), transport: transport,
            imageSupport: TranslationImageSupport(defaults: defaults))
        _ = try await secondClient.translate(request, configuration: settings.configuration)
        #expect(await transport.images == [true, false, false])
        let payloads = await transport.textPayloads
        #expect(payloads.allSatisfy { $0 == payloads.first })
        let bodies = await transport.bodies
        #expect(!bodies[1].contains("data:image/"))
        #expect(!bodies[1].contains("input_image"))
        #expect(!bodies[1].contains("image_url"))
    }

    @Test func manualProbeRejectsUnsupportedImagesAndExplicitRetestUsesImages() async throws {
        let suite = "ImageProbe.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let support = TranslationImageSupport(defaults: defaults)
        let settings = settings()
        let transport = ImageSupportTransport()
        var failed = false
        do {
            _ = try await ReaderTranslationConnectionTest.translate(settings: settings, apiKey: "test-only",
                savedCredentials: ImageSupportCredentials(), transport: transport, imageSupport: support)
        } catch { failed = true }
        #expect(failed)
        #expect(await transport.images == [true])
        await transport.acceptImages()
        let second = try await ReaderTranslationConnectionTest.translate(settings: settings, apiKey: "test-only",
            savedCredentials: ImageSupportCredentials(), transport: transport, imageSupport: support)
        #expect(second == "안녕하세요")
        #expect(await transport.images == [true, true])
    }

    @Test func legacyDisabledImageSettingCannotMakePageProbeTextOnly() async throws {
        var settings = settings()
        settings.includePageImage = false
        let transport = ImageSupportTransport()
        await transport.acceptImages()
        _ = try await ReaderTranslationConnectionTest.translate(settings: settings, apiKey: "test-only",
            savedCredentials: ImageSupportCredentials(), transport: transport)
        #expect(await transport.images == [true])
    }

    @Test func protocolAndImageFallbackComposeWithoutRepeatingMissingEndpoint() async throws {
        let settings = settings()
        let transport = ImageSupportTransport(responsesUnavailable: true)
        let client = RemoteTranslationClient(credentialStore: ImageSupportCredentials(), transport: transport)
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", sourceText: "Hello")
        request.imageJPEG = Data([1])
        let result = try await client.translate(request, configuration: settings.configuration)
        #expect(result.translations.first?.text == "안녕하세요")
        #expect(await transport.images == [true, true, false])
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions], 0..<4)
    func nonPageImageFallbackKeepsRequestedFields(apiProtocol: RemoteTranslationProtocol, filters: Int) async throws {
        var settings = settings()
        settings.custom.apiProtocol = apiProtocol
        let transport = ImageSupportTransport()
        let client = RemoteTranslationClient(credentialStore: ImageSupportCredentials(), transport: transport)
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko",
            segments: [.init(id: "dialogue", text: "Hello", bounds: [0.1, 0.1, 0.2, 0.2])])
        request.imageJPEG = Data([1])
        request.filtersSFX = filters & 1 != 0
        request.filtersBackground = filters & 2 != 0
        let result = try await client.translate(request, configuration: settings.configuration)
        #expect(result.translations.first?.id == "dialogue")
        #expect(result.translations.first?.text == "안녕하세요")
        // A remembered rejection must produce the same text-only request too.
        _ = try await client.translate(request, configuration: settings.configuration)
        let bodies = await transport.bodies
        #expect(bodies.count == 3)
        var textOnly = request
        textOnly.imageJPEG = nil
        let expected = try #require(JSONSerialization.jsonObject(with: TranslationHTTPCodec.requestBody(
            configuration: settings.configuration, request: textOnly)) as? NSDictionary)
        for body in bodies.dropFirst() {
            let root = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? NSDictionary)
            #expect(root == expected)
            // Requests no longer carry context or glossary fields.
            #expect(!body.contains("Nearby dialogue"))
            #expect(!body.contains("data:image"))
            #expect(!body.contains("input_image"))
            #expect(!body.contains("image_url"))
            let fields = try ImageSupportTransport.requiredFields(in: root as! [String: Any], responses: apiProtocol == .responses)
            #expect(!fields.contains("is_sfx"))
            #expect(fields.contains("text_role") == (filters & 3 != 0))
            #expect(!fields.contains("editorial_role"))
        }
    }

    @Test(arguments: [400, 401, 403, 413, 429, 500, 503])
    func unrelatedErrorsDoNotDisableImagesOrRetry(status: Int) async throws {
        let suite = "ImageErrors.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let support = TranslationImageSupport(defaults: defaults)
        let settings = settings()
        let transport = ImageSupportTransport(failureStatus: status, message: "Invalid API key or request")
        let client = RemoteTranslationClient(credentialStore: ImageSupportCredentials(), transport: transport, imageSupport: support)
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", sourceText: "Hello")
        request.imageJPEG = Data([1, 2, 3])
        do {
            _ = try await client.translate(request, configuration: settings.configuration)
            Issue.record("Unrelated errors must propagate")
        } catch let error as RemoteTranslationError {
            #expect(error == .httpStatus(status, requestID: nil))
        }
        #expect(await transport.images == [true])
        #expect(support.status(for: settings.configuration) == .unknown)
    }

    @Test func textFailureAfterImageRejectionPropagatesWithoutLooping() async throws {
        let transport = ImageSupportTransport(textFailure: 401)
        let settings = settings()
        let client = RemoteTranslationClient(credentialStore: ImageSupportCredentials(), transport: transport)
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", sourceText: "Hello")
        request.imageJPEG = Data([1])
        do {
            _ = try await client.translate(request, configuration: settings.configuration)
            Issue.record("Text authentication failure must propagate")
        } catch let error as RemoteTranslationError { #expect(error == .httpStatus(401, requestID: nil)) }
        #expect(await transport.images == [true, false])
    }

    @Test(arguments: [
        "This model does not support image inputs.",
        "Invalid content type. image_url is only supported by certain models.",
        "Multimodal input is not supported.",
        "Image URLs are not supported by this model.",
        "This is not a vision model."
    ])
    func recognizesExplicitCapabilityErrors(message: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["error": ["message": message]])
        #expect(TranslationImageSupport.isUnsupportedResponse(status: 400, body: data))
        #expect(!TranslationImageSupport.isUnsupportedResponse(status: 429, body: data))
    }

    @Test(arguments: [
        "Unsupported image format.", "Unsupported image dimensions.", "Invalid image data.",
        "Unsupported response_format parameter.", "Unable to download image URL."
    ])
    func doesNotMisclassifyMalformedImagesOrOtherParameters(message: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["error": ["message": message]])
        #expect(!TranslationImageSupport.isUnsupportedResponse(status: 400, body: data))
    }
}

private struct ImageSupportCredentials: TranslationCredentialProviding {
    func secret(for account: String) throws -> String { "test-only" }
}

private actor ImageSupportTransport: TranslationHTTPTransport {
    private(set) var images: [Bool] = []
    private(set) var bodies: [String] = []
    private(set) var textPayloads: [String] = []
    var rejectsImages = true
    let failureStatus: Int
    let message: String
    let textFailure: Int?
    let responsesUnavailable: Bool
    let roles: [String: String]?

    init(failureStatus: Int = 400, message: String = "This model does not support image inputs.", textFailure: Int? = nil,
         responsesUnavailable: Bool = false, roles: [String: String]? = nil) {
        self.failureStatus = failureStatus
        self.message = message
        self.textFailure = textFailure
        self.responsesUnavailable = responsesUnavailable
        self.roles = roles
    }
    func acceptImages() { rejectsImages = false }

    static func requiredFields(in root: [String: Any], responses: Bool) throws -> Set<String> {
        let formatRoot = try #require(root[responses ? "text" : "response_format"] as? [String: Any])
        let format = try #require(formatRoot[responses ? "format" : "json_schema"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let translations = try #require((schema["properties"] as? [String: Any])?["translations"] as? [String: Any])
        let item = try #require(translations["items"] as? [String: Any])
        let branches = item["anyOf"] as? [[String: Any]] ?? [item]
        let required = Set(try #require(branches.first?["required"] as? [String]))
        for branch in branches {
            let fields = try #require(branch["required"] as? [String])
            let properties = try #require(branch["properties"] as? [String: Any])
            #expect(Set(fields) == required && Set(properties.keys) == required)
            #expect(branch["additionalProperties"] as? Bool == false)
        }
        return required
    }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        let body = try #require(request.httpBody)
        bodies.append(String(decoding: body, as: UTF8.self))
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
        let text = try #require(content.compactMap { $0["text"] as? String }.first)
        textPayloads.append(text)
        let status = responses && responsesUnavailable ? 404 : (hasImage && rejectsImages ? failureStatus : (!hasImage ? textFailure ?? 200 : 200))
        let response = try #require(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil))
        if status != 200 {
            return .init(data: try JSONSerialization.data(withJSONObject: ["error": ["message": message]]), response: response)
        }
        let data = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let segments = try #require(data["segments"] as? [[String: Any]])
        let required = try Self.requiredFields(in: root, responses: responses)
        let translations: [[String: Any]] = segments.map { segment in
            let source = segment["text"] as? String ?? ""
            let role = roles?[source] ?? "dialogue"
            // Classification must not replace any translated role with source text.
            var translated: [String: Any] = ["id": segment["id"]!, "text": roles == nil ? "안녕하세요" : "translated:" + source]
            if required.contains("text_role") { translated["text_role"] = role }
            return translated
        }
        let output = try JSONSerialization.data(withJSONObject: ["translations": translations])
        let translated = String(decoding: output, as: UTF8.self)
        let envelope: [String: Any] = responses
            ? ["status": "completed", "output": [["type": "message", "status": "completed", "content": [["type": "output_text", "text": translated]]]]]
            : ["choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": translated]]]]
        return .init(data: try JSONSerialization.data(withJSONObject: envelope), response: response)
    }
}
