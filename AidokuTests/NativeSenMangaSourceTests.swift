import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeSenMangaSourceTests {
    private func runner(_ fixture: String) -> SenMangaSourceRunner {
        SenMangaSourceRunner(fetch: { request in
            (Data(fixture.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }

    @Test func updatesPreserveNullStatusAndMapChaptersRatingAndUTCDate() async throws {
        let source = runner(#"{"title":"Updated","genre":"Action, Mature, ","type":"Manhwa","status":null,"description":"Text","chapterList":[{"title":"Chapter 8","number":"8","url":"8.123","full_url":"/manga/series/chapter-8.123/","datetime":"2026-09-30T01:02:03Z"}]}"#)
        let original = AidokuRunner.Manga(sourceKey: "ja.senmanga", key: "series", title: "Old", status: .ongoing)
        let result = try await source.getMangaUpdate(manga: original, needsDetails: true, needsChapters: true)
        #expect(result.title == "Updated")
        #expect(result.status == .ongoing)
        #expect(result.contentRating == .suggestive)
        #expect(result.viewer == .webtoon)
        #expect(result.tags == ["Action", "Mature"])
        #expect(result.chapters?.first?.title == nil)
        #expect(result.chapters?.first?.chapterNumber == 8)
        #expect(result.chapters?.first?.key == "8.123")
        #expect(result.chapters?.first?.dateUploaded != nil)
        #expect(result.chapters?.first?.url?.absoluteString == "https://raw.senmanga.com/manga/series/chapter-8.123/")
    }
}
