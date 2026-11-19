import Testing
import Foundation
@testable import Aidoku

@Suite(.serialized) @MainActor
struct MangaDescriptionTranslationTests {
    @Test func cachedParagraphSurvivesAnotherParagraphFailingOffline() async {
        let fixture = DescriptionFixture()
        var settings = ReaderTranslationSettings()
        settings.translateMangaDescriptions = true
        settings.mangaDescriptionSourceLanguages = []
        settings.targetLanguage = "ko"
        let cached = "A detective travels around the world."
        let missing = "Another story has never been translated."
        #expect(await MangaDescriptionTranslation.translate(cached, settings: settings,
            service: ReaderTranslationService(client: DescriptionClient()), diskCache: fixture.disk) == "번역된 설명")
        let offline = DescriptionClient(fails: true)
        let result = await MangaDescriptionTranslation.translate(missing + "\n\n" + cached, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: ReaderTranslationDiskCache(directory: fixture.root))
        #expect(result == missing + "\n\n번역된 설명")
        #expect(await offline.requests.count == 1)
    }

    @Test func failurePreservesFullDescriptionAndDoesNotCacheIt() async throws {
        let fixture = DescriptionFixture()
        var settings = ReaderTranslationSettings()
        settings.translateMangaDescriptions = true
        let original = "A young detective travels around the world.\n\nHe discovers a secret hidden in an ancient city."
        #expect(await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: DescriptionClient(fails: true)), diskCache: fixture.disk) == original)
        #expect(try await fixture.disk.statistics().entries == 0)
    }

    @Test func longUnicodeDescriptionsAreNotTruncated() {
        let original = String(repeating: "長い物語の説明👨‍👩‍👧‍👦 and words\n", count: 2_000)
        let chunks = MangaDescriptionTranslation.chunks(original)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == original)
        #expect(chunks.allSatisfy { $0.utf8.count <= RemoteTranslationRequest.maximumSegmentTextBytes })
    }
}

private actor DescriptionClient: RemoteTranslating {
    let fails: Bool
    private(set) var requests: [RemoteTranslationRequest] = []
    init(fails: Bool = false) { self.fails = fails }
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        requests.append(request)
        if fails { throw URLError(.notConnectedToInternet) }
        return .init(translations: request.segments.map { .init(id: $0.id, text: "번역된 설명") }, source: .network, providerRequestID: nil)
    }
}

@MainActor private final class DescriptionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("description-cache-" + UUID().uuidString)
    lazy var disk = ReaderTranslationDiskCache(directory: root)
    deinit { try? FileManager.default.removeItem(at: root) }
}
