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
        request.prepareImageRepresentation()
        let originalBytes = try #require(request.imageJPEG)
        let expected = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        #expect(request.imageDigest == expected)
        let canonical = request.canonicalizedForTranslationSemantics().request
        #expect(canonical.imageDigest == expected)
        var copied = request
        copied.imageJPEG?[2] = 3
        #expect(copied.imageDigest != expected)
        #expect(copied.preparedImageDataURL == nil)
        #expect(request.imageJPEG == originalBytes && request.imageDigest == expected)
        #expect(canonical.imageDigest == expected)
        copied.copyImageRepresentation(from: request)
        #expect(copied.imageDigest == expected)
        #expect(copied.preparedImageDataURL == request.preparedImageDataURL)
        copied.imageJPEG = nil
        #expect(copied.imageDigest == nil && copied.preparedImageDataURL == nil)
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
        ("BOOM!", "sfx"),
        ("What could this possibly mean?", "unknown")
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

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions], 0..<16)
    func readerFilterAndImageMatrix(apiProtocol: RemoteTranslationProtocol, mode: Int) async throws {
        // Four filter combinations x disabled/supported/rejected/known-unsupported images.
        var settings = settings()
        settings.custom.apiProtocol = apiProtocol
        settings.filterSFXWithLLM = mode & 1 != 0
        settings.filterBackgroundWithLLM = mode & 2 != 0
        let imageMode = mode / 4
        settings.includePageImage = imageMode != 0
        let transport = ImageSupportTransport(roles: Dictionary(uniqueKeysWithValues: Self.roleSamples))
        if imageMode == 0 || imageMode == 1 { await transport.acceptImages() }
        if imageMode == 3 { TranslationImageSupport.shared.record(.unsupported, for: settings.configuration) }
        let service = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: ImageSupportCredentials(), transport: transport))
        let regions = Self.roleSamples.enumerated().map { index, sample in
            ReaderTranslationRegion(id: "line-\(index)", rect: CGRect(x: 0.1, y: 0.05 + Double(index) * 0.13, width: 0.6, height: 0.1),
                                    source: sample.0)
        }
        let jpeg = try Self.fixtureJPEG.get()
        let providedImage = imageMode == 1 || imageMode == 2 ? jpeg : nil
        let output = try await service.translate(regions: regions, settings: settings, preparedImageJPEG: providedImage)
        #expect(output.count == regions.count)
        for (index, sample) in Self.roleSamples.enumerated() {
            let retained = (sample.1 == "sfx" && settings.filterSFXWithLLM)
                || (sample.1 == "background" && settings.filterBackgroundWithLLM)
            #expect(output[index].translation == (retained ? sample.0 : "translated:" + sample.0))
            #expect(output[index].preservesOriginalText == retained)
        }
        let overlays = ReaderTranslationRegion.overlayItems(output, imageSize: Self.fixtureSize)
        #expect(overlays.count == output.filter { !$0.preservesOriginalText }.count)
        #expect(await transport.images == (imageMode == 2 ? [true, false] : [imageMode == 1]))
        let bodies = await transport.bodies
        for (index, body) in bodies.enumerated() {
            let root = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            let instructions: String
            let schema: [String: Any]
            let imageURLs: [String]
            if apiProtocol == .responses {
                instructions = try #require(root["instructions"] as? String)
                schema = try #require(((root["text"] as? [String: Any])?["format"] as? [String: Any])?["schema"] as? [String: Any])
                let content = try #require((root["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
                imageURLs = content.filter { $0["type"] as? String == "input_image" }.compactMap { $0["image_url"] as? String }
            } else {
                instructions = try #require((root["messages"] as? [[String: Any]])?.first?["content"] as? String)
                schema = try #require(((root["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
                let content = (root["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]] ?? []
                imageURLs = content.filter { $0["type"] as? String == "image_url" }.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
            }
            let translations = try #require((schema["properties"] as? [String: Any])?["translations"] as? [String: Any])
            let properties = try #require((translations["items"] as? [String: Any])?["properties"] as? [String: Any])
            #expect((properties["is_sfx"] != nil) == settings.filterSFXWithLLM)
            #expect((properties["text_role"] != nil) == settings.filterBackgroundWithLLM)
            let attached = imageMode == 1 || (imageMode == 2 && index == 0)
            #expect(imageURLs.count == (attached ? 1 : 0))
            if attached {
                let imageURL = try #require(imageURLs.first)
                #expect(imageURL.hasPrefix("data:image/jpeg;base64,"))
                #expect(Data(base64Encoded: String(imageURL.dropFirst("data:image/jpeg;base64,".count))) == jpeg)
            }
            if attached {
                #expect(!instructions.contains("No image is attached"))
                #expect(!instructions.contains("Text-only SFX classification"))
                #expect(!instructions.contains("Text-only text_role classification"))
            } else {
                #expect(!instructions.contains("An image is attached"))
                #expect(!instructions.contains("Image context: The attached image"))
                #expect(!instructions.contains("use the image and context"))
                #expect(instructions.contains("Text-only SFX classification") == settings.filterSFXWithLLM)
                #expect(instructions.contains("Text-only text_role classification") == settings.filterBackgroundWithLLM)
            }
        }
        // The first rejection changes image semantics; warm the resulting text cache,
        // then prove the next read neither retranslates nor changes preserved text.
        let second = try await service.translate(regions: regions, settings: settings, preparedImageJPEG: providedImage)
        #expect(second.map(\.translation) == output.map(\.translation))
        let count = await transport.images.count
        _ = try await service.translate(regions: regions, settings: settings, preparedImageJPEG: providedImage)
        #expect(await transport.images.count == count)
        #expect(count == (imageMode == 2 ? 3 : 1))
    }

    private func settings() -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "ImageSettings.\(UUID().uuidString)")!)
        settings.provider = .custom
        settings.custom.baseURL = "https://image-support-tests.example/\(UUID().uuidString)/v1"
        settings.model = "text-model"
        settings.sourceLanguage = "auto"
        settings.targetLanguage = "ko"
        settings.includePageImage = true
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
        request.prepareImageRepresentation()
        let first = try await client.translate(request, configuration: settings.configuration)
        #expect(first.singleText == "안녕하세요")
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

    @Test func manualProbeFallsBackAndExplicitRetestRestoresImages() async throws {
        let suite = "ImageProbe.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let support = TranslationImageSupport(defaults: defaults)
        let settings = settings()
        let transport = ImageSupportTransport()
        let first = try await ReaderTranslationConnectionTest.translate(settings: settings, apiKey: "test-only",
            savedCredentials: ImageSupportCredentials(), transport: transport, imageSupport: support)
        #expect(first == "안녕하세요")
        #expect(support.status(for: settings.configuration) == .unsupported)
        #expect(await transport.images == [true, false])
        let revision = support.revision(for: settings.configuration)
        await transport.acceptImages()
        _ = try await ReaderTranslationConnectionTest.translate(settings: settings, apiKey: "test-only",
            savedCredentials: ImageSupportCredentials(), transport: transport, imageSupport: support)
        #expect(await transport.images == [true, false, true])
        #expect(support.status(for: settings.configuration) == .supported)
        #expect(support.revision(for: settings.configuration) > revision)
    }

    @Test func disabledImageSettingKeepsProbeTextOnly() async throws {
        var settings = settings()
        settings.includePageImage = false
        let transport = ImageSupportTransport()
        _ = try await ReaderTranslationConnectionTest.translate(settings: settings, apiKey: "test-only",
            savedCredentials: ImageSupportCredentials(), transport: transport)
        #expect(await transport.images == [false])
    }

    @Test func protocolAndImageFallbackComposeWithoutRepeatingMissingEndpoint() async throws {
        let settings = settings()
        let transport = ImageSupportTransport(responsesUnavailable: true)
        let client = RemoteTranslationClient(credentialStore: ImageSupportCredentials(), transport: transport)
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko", sourceText: "Hello")
        request.imageJPEG = Data([1])
        let result = try await client.translate(request, configuration: settings.configuration)
        #expect(result.singleText == "안녕하세요")
        #expect(await transport.images == [true, true, false])
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions], 0..<4)
    func imageFallbackKeepsFiltersAndUsesTextOnlyInstructions(apiProtocol: RemoteTranslationProtocol, filters: Int) async throws {
        var settings = settings()
        settings.custom.apiProtocol = apiProtocol
        let transport = ImageSupportTransport()
        let client = RemoteTranslationClient(credentialStore: ImageSupportCredentials(), transport: transport)
        var request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko",
            segments: [.init(id: "dialogue", text: "Hello", bounds: [0.1, 0.1, 0.2, 0.2])],
            context: ["Nearby dialogue"], glossary: [.init(source: "Alice", target: "앨리스")])
        request.imageJPEG = Data([1])
        request.prepareImageRepresentation()
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
            #expect(body.contains("Nearby dialogue"))
            #expect(body.contains("Alice"))
            #expect(!body.contains("An image is attached"))
            #expect(!body.contains("Image context: The attached image"))
            #expect(!body.contains("use the image and context"))
            #expect(!body.contains("Require visual evidence"))
            #expect(!body.contains("Inspect the original lettering"))
            #expect(!body.contains("data:image"))
            #expect(!body.contains("input_image"))
            #expect(!body.contains("image_url"))
            if filters != 0 { #expect(body.contains("No image is attached")) }
            if filters & 1 != 0 { #expect(body.contains("Text-only SFX classification")) }
            if filters & 2 != 0 { #expect(body.contains("Text-only text_role classification")) }
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

    @Test func knownUnsupportedReaderNeedsNoImageAndCacheChangesOnRecovery() async throws {
        let settings = settings()
        let support = TranslationImageSupport.shared
        let initialKey = ReaderTranslationCacheIdentity.translation(page: "page", settings: settings)
        support.record(.unsupported, for: settings.configuration)
        #expect(!settings.shouldAttachPageImage)
        let fallbackKey = ReaderTranslationCacheIdentity.translation(page: "page", settings: settings)
        let transport = ImageSupportTransport()
        let service = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: ImageSupportCredentials(), transport: transport))
        let translated = try await service.translate(regions: [.init(id: "line", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2),
            source: "Please open the door and come inside.")], settings: settings)
        #expect(translated.first?.translation == "안녕하세요")
        #expect(await transport.images == [false])
        support.record(.supported, for: settings.configuration)
        #expect(settings.shouldAttachPageImage)
        let recoveredKey = ReaderTranslationCacheIdentity.translation(page: "page", settings: settings)
        #expect(initialKey != fallbackKey)
        #expect(fallbackKey != recoveredKey)
        #expect(initialKey != recoveredKey)
        var changed = settings
        changed.model = "other-model"
        #expect(support.status(for: changed.configuration) == .unknown)
        changed = settings
        changed.credentialGeneration += 1
        #expect(support.status(for: changed.configuration) == .unknown)
        changed = settings
        changed.custom.baseURL = "https://another-image-support-test.example/v1"
        #expect(support.status(for: changed.configuration) == .unknown)
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
        let translations: [[String: Any]] = segments.map { segment in
            let source = segment["text"] as? String ?? ""
            let role = roles?[source] ?? "dialogue"
            // Deliberately translate even excluded roles: the production parser
            // must restore their exact source text instead of trusting this output.
            var translated: [String: Any] = ["id": segment["id"]!, "text": roles == nil ? "안녕하세요" : "translated:" + source]
            let bodyText = String(decoding: body, as: UTF8.self)
            if bodyText.contains("\"is_sfx\":") { translated["is_sfx"] = role == "sfx" }
            if bodyText.contains("\"text_role\":") { translated["text_role"] = role }
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
