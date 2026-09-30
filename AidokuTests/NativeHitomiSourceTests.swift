import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeHitomiSourceTests {
    private static let gallery = #"{"id":"123","title":"English | Fallback Japanese","japanese_title":"Japanese","galleryurl":"/galleries/example-123.html","type":"manga","language":"korean","date":"2024-01-02 03:04:05","files":[{"hash":"abcdef0123","haswebp":1,"hasavif":0}],"artists":[{"artist":"Artist"}],"groups":[{"group":"Group"}],"tags":[{"tag":"comic","female":"1"}]}"#

    @Test func metadataPreservesTitleAuthorsViewerAndSettings() throws {
        let gallery = try JSONDecoder().decode(HitomiGallery.self, from: Data(Self.gallery.utf8))
        let japanese = gallery.manga(sourceKey: "multi.hitomi", japanese: true)
        #expect(japanese.title == "Japanese")
        #expect(japanese.authors == ["Group", "Artist"])
        #expect(japanese.artists == ["Artist"])
        #expect(japanese.tags == ["comic♀"])
        #expect(japanese.viewer == .webtoon)
        #expect(japanese.updateStrategy == .never)
        #expect(japanese.cover == "https://atn.gold-usergeneratedcontent.net/avifbigtn/3/12/abcdef0123.avif")
        #expect(japanese.description?.contains("English title: English | Fallback Japanese") == true)
        #expect(gallery.files[0].isGIF)
        #expect(gallery.manga(sourceKey: "multi.hitomi", japanese: false).title == "English | Fallback Japanese")
    }

    @Test func detailsAndChaptersShareGalleryCache() async throws {
        let fixture = GalleryFixture()
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) }, preference: { key in
            key == "titlePreference" ? "japanese" : nil
        })
        let manga = AidokuRunner.Manga(sourceKey: "multi.hitomi", key: "123", title: "Old")
        let updated = try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
        #expect(updated.title == "Japanese")
        #expect(updated.chapters?.first?.key == "123")
        #expect(updated.chapters?.first?.scanlators == ["korean"])
        #expect(updated.chapters?.first?.dateUploaded != nil)
        let chaptersOnly = try await runner.getMangaUpdate(manga: manga, needsDetails: false, needsChapters: true)
        #expect(chaptersOnly.title == "Old")
        #expect(await fixture.count == 1)
        await runner.clearCache()
        _ = try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: false)
        #expect(await fixture.count == 2)
    }

    @Test func cancelledGalleryFanOutDoesNotBecomeEmptySuccess() async throws {
        let runner = HitomiSourceRunner(fetch: { _ in throw CancellationError() })
        let manga = AidokuRunner.Manga(sourceKey: "multi.hitomi", key: "123", title: "Old")
        do {
            _ = try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: false)
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }

    @Test func imageRequestPreservesReaderReferer() async throws {
        let runner = HitomiSourceRunner()
        let request = try await runner.getImageRequest(url: "https://example.com/image.avif", context: ["referer": "https://hitomi.la/reader/123.html"])
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://hitomi.la/reader/123.html")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://hitomi.la")
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("image/avif") == true)
    }

    @Test func deepLinksRequireRealHitomiHost() {
        #expect(HitomiSourceRunner.galleryID("https://hitomi.la/reader/123.html") == 123)
        #expect(HitomiSourceRunner.galleryID("https://hitomi.la/g/123/") == 123)
        #expect(HitomiSourceRunner.galleryID("https://hitomi.la/galleries/title-123.html") == 123)
        #expect(HitomiSourceRunner.galleryID("https://hitomi.la.evil.test/reader/123.html") == nil)
        #expect(HitomiSourceRunner.galleryID("https://evil.test/?hitomi.la/reader/123.html") == nil)
    }

    private actor GalleryFixture {
        var count = 0
        func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
            count += 1
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://hitomi.la/")
            let body = "var galleryinfo = \(NativeHitomiSourceTests.gallery);"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
