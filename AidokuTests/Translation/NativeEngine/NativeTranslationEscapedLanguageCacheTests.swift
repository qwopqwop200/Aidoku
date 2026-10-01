import Foundation
import Testing
@testable import Aidoku

struct NativeTranslationEscapedLanguageCacheTests {
    private static let source = "これはとても長い日本語の文章でまだ翻訳されていない内容を説明しています。"
    private static let wrongLanguage = "これはとても長い日本語の文章でまだ翻訳されていない内容を説明しています！"
    private static let translated = "아직 번역되지 않은 내용을 설명하는 긴 문장이에요."
    private static let configuration = RemoteTranslationConfiguration.openAI(model: "escaped-language-audit")

    private func request() -> RemoteTranslationRequest {
        .init(sourceLanguage: "ja", targetLanguage: "ko", segments: [.init(id: "caller", text: Self.source)])
    }

    private func escapedAnswer() -> String {
        Self.wrongLanguage.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined()
    }

    @Test(arguments: [false, true])
    func escapedSourceLanguageCannotHydrateMemoryOrReopenedDiskCache(reopen: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = request()
        let key = TranslationCacheKey(configuration: Self.configuration,
            endpoint: try Self.configuration.validatedEndpoint(), request: request)
        let original = try TranslationCache(storageRootURL: root)
        await original.insert([.init(id: "segment-0", text: escapedAnswer())], for: key)
        let cache = reopen ? try TranslationCache(storageRootURL: root) : original
        let client = EscapedLanguageAuditClient(firstAnswer: nil, validAnswer: Self.translated)
        let service = TranslationService(client: client, cache: cache)
        #expect(try await service.cachedResult(request, configuration: Self.configuration) == nil)
        #expect(try await service.cachedTranslation(request, configuration: Self.configuration) == nil)
        let repaired = try await service.translate(request, configuration: Self.configuration)
        #expect(repaired.singleText == Self.translated)
        #expect(repaired.source == .network)
        #expect(await client.calls == 1)
        let cached = try await service.translate(request, configuration: Self.configuration)
        #expect(cached.singleText == Self.translated)
        #expect(cached.source == .memoryCache)
        #expect(await client.calls == 1)
    }

    @Test func escapedWrongLanguageProviderAnswerRetriesBeforeBecomingCached() async throws {
        let request = request()
        let cache = try TranslationCache(configuration: .init(diskEnabled: false))
        let client = EscapedLanguageAuditClient(firstAnswer: escapedAnswer(), validAnswer: Self.translated)
        let service = TranslationService(client: client, cache: cache)
        let result = try await service.translate(request, configuration: Self.configuration)
        #expect(result.singleText == Self.translated)
        #expect(result.translations.map(\.id) == ["caller"])
        #expect(await client.calls == 2)
        let cached = try await service.translate(request, configuration: Self.configuration)
        #expect(cached.singleText == Self.translated)
        #expect(cached.source == .memoryCache)
        #expect(await client.calls == 2)
    }
}

private actor EscapedLanguageAuditClient: RemoteTranslating {
    let firstAnswer: String?
    let validAnswer: String
    private(set) var calls = 0

    init(firstAnswer: String?, validAnswer: String) {
        self.firstAnswer = firstAnswer
        self.validAnswer = validAnswer
    }

    func translate(_ request: RemoteTranslationRequest,
                   configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        calls += 1
        let text = calls == 1 ? (firstAnswer ?? validAnswer) : validAnswer
        return .init(translations: request.segments.map { .init(id: $0.id, text: text) }, source: .network, providerRequestID: nil)
    }
}
