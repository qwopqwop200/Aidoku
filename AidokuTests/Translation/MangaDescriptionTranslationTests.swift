import Testing
import Foundation
import SwiftUI
import UIKit
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

    @Test func repairsEscapedLineBreaksWithoutDamagingURLs() {
        let text = #"Japanese title: title /n타입: artistcg /n페이지: 349\nSeries: original"#
        #expect(MangaDescriptionTranslation.normalizedLineBreaks(text) == "Japanese title: title\n타입: artistcg\n페이지: 349\nSeries: original")
        let url = "https://example.org/news/name?q=/new"
        #expect(MangaDescriptionTranslation.normalizedLineBreaks(url) == url)
        #expect(MangaDescriptionTranslation.normalizedLineBreaks("First\n\nSecond") == "First\n\nSecond")
    }

    @Test func modelCannotCollapseSourceLinesAndRestartKeepsLayout() async throws {
        let fixture = DescriptionFixture()
        var settings = ReaderTranslationSettings()
        settings.translateMangaDescriptions = true
        settings.mangaDescriptionSourceLanguages = []
        settings.targetLanguage = "ko"
        let original = "Japanese title: Alley Sister /nType: artistcg /nPages: 349 /nSeries: original"
        let client = DescriptionClient()
        let result = await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: client), diskCache: fixture.disk)
        #expect(result == Array(repeating: "번역된 설명", count: 4).joined(separator: "\n"))
        #expect(await client.requests.flatMap(\.segments).count == 4)
        let offline = DescriptionClient(fails: true)
        #expect(await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: ReaderTranslationDiskCache(directory: fixture.root)) == result)
        #expect(await offline.requests.isEmpty)
    }

    @Test func expandedAndCollapsedMarkdownRenderLineBreaks() throws {
        let text = "일본어 제목: 골목길의 시스터\n형식: artistcg\n페이지: 349\n시리즈: 오리지널"
        for expanded in [false, true] {
            let controller = UIHostingController(rootView: ExpandableTextView(text: text, expanded: .constant(expanded))
                .environmentObject(NavigationCoordinator(rootViewController: nil)))
            let flat = UIHostingController(rootView: ExpandableTextView(text: text.replacingOccurrences(of: "\n", with: " "),
                expanded: .constant(expanded)).environmentObject(NavigationCoordinator(rootViewController: nil)))
            let size = CGSize(width: 700, height: 1000)
            let height = controller.sizeThatFits(in: size).height
            #expect(height > flat.sizeThatFits(in: size).height + 30)
            controller.view.frame = CGRect(x: 0, y: 0, width: 700, height: height)
            controller.view.backgroundColor = .systemBackground
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("description-lines-\(expanded ? "expanded" : "collapsed").png")
            try image.pngData()?.write(to: path)
        }
    }

    @Test func preferencesPersistIndependently() throws {
        let suite = "description-settings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(!settings.translateMangaDescriptions && settings.mangaDescriptionSourceLanguages.isEmpty)
        let page = settings
        settings.translateMangaDescriptions = true
        settings.mangaDescriptionSourceLanguages = ["en", "ja"]
        try settings.save(defaults: defaults)
        let saved = ReaderTranslationSettings(defaults: defaults)
        #expect(saved.translateMangaDescriptions)
        #expect(saved.mangaDescriptionSourceLanguages == ["en", "ja"])
        #expect(saved.hasSameTranslation(as: page))
        #expect(saved.mangaTitleSourceLanguages.isEmpty && saved.chapterTitleSourceLanguages.isEmpty)
        settings.mangaDescriptionSourceLanguages = ["invalid"]
        #expect(throws: RemoteTranslationError.self) { try settings.save(defaults: defaults) }
    }

    @Test func descriptionFilterKeepsExcludedParagraphsAndReusesDisk() async throws {
        let fixture = DescriptionFixture()
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "ja"
        settings.translationSourceLanguages = ["ja"]
        settings.mangaTitleSourceLanguages = ["fr"]
        settings.chapterTitleSourceLanguages = ["ja"]
        settings.mangaDescriptionSourceLanguages = ["en"]
        settings.translateMangaDescriptions = true
        let english = "A young detective travels around the world to solve mysterious crimes."
        let japanese = "これは日本語の物語の説明です。少年は世界中を旅します。"
        let original = english + "\n\n" + japanese
        let client = DescriptionClient()
        let translated = await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: client), diskCache: fixture.disk)
        #expect(translated == "번역된 설명\n\n" + japanese)
        #expect(await client.requests.count == 1)
        let offline = DescriptionClient(fails: true)
        let reopened = ReaderTranslationDiskCache(directory: fixture.root)
        #expect(await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: reopened) == translated)
        #expect(await offline.requests.isEmpty)
        settings.translateMangaDescriptions = false
        #expect(await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: reopened) == original)
        #expect(await offline.requests.isEmpty)
        settings.translateMangaDescriptions = true
        settings.mangaDescriptionSourceLanguages = ["fr"]
        #expect(await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: reopened) == original)
        #expect(await offline.requests.isEmpty)
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

    @Test func cacheIdentityUsesOnlyDescriptionFilterAndPreservesFormattingInstructions() {
        var settings = ReaderTranslationSettings()
        let key = TitleTranslation.cacheKey("synopsis", kind: .description, settings: settings)
        settings.sourceLanguage = "ja"
        settings.mangaTitleSourceLanguages = ["en"]
        settings.chapterTitleSourceLanguages = ["fr"]
        #expect(TitleTranslation.cacheKey("synopsis", kind: .description, settings: settings) == key)
        settings.mangaDescriptionSourceLanguages = ["en"]
        #expect(TitleTranslation.cacheKey("synopsis", kind: .description, settings: settings) != key)
        let effective = TitleTranslation.effectiveSettings(settings, kind: .description)
        #expect(effective.configuration.instructions.contains("Markdown"))
        #expect(TitleTranslation.effectiveSettings(effective, kind: .description) == effective)
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
