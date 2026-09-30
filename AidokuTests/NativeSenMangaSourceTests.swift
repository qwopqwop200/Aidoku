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

    @Test func directoryUsesEncodedQueryValidSortAndNullablePagination() async throws {
        let source = SenMangaSourceRunner(fetch: { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "query", value: "日本 & manga")))
            #expect(query.contains(URLQueryItem(name: "order", value: "updated")))
            #expect(!query.contains(where: { $0.name == "genre" }))
            let json = #"{"currentPage":null,"totalPages":null,"series":[{"title":"Title","slug":"series","cover":"https://images.invalid/a.jpg","status":"Completed"}]}"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await source.getSearchMangaList(query: "日本 & manga", page: 1, filters: [
            .sort(.init(id: "sort", index: 2, ascending: false)), .select(id: "genre", value: "")
        ])
        #expect(result.entries.first?.key == "series")
        #expect(result.entries.first?.status == .completed)
        #expect(!result.hasNextPage)
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

    @Test func pagesRejectEmptyAndNonHTTPResponses() async throws {
        let manga = AidokuRunner.Manga(sourceKey: "ja.senmanga", key: "series", title: "Title")
        let chapter = AidokuRunner.Chapter(key: "8.123")
        await #expect(throws: URLError.self) {
            _ = try await runner(#"{"pages":[]}"#).getPageList(manga: manga, chapter: chapter)
        }
        await #expect(throws: URLError.self) {
            _ = try await runner(#"{"pages":["file:///private/image.jpg"]}"#).getPageList(manga: manga, chapter: chapter)
        }
        let pages = try await runner(#"{"pages":["https://images.invalid/1.jpg","https://images.invalid/2.jpg"]}"#)
            .getPageList(manga: manga, chapter: chapter)
        #expect(pages.count == 2)
    }

    @Test func migrationUsesAPIChapterIdentityAndDeepLinksCheckExactHost() async throws {
        let source = runner(#"{"title":"Title","chapterList":[{"number":"8","url":"8.123"}]}"#)
        #expect(try await source.handleMigration(kind: .manga, mangaKey: "/series/", chapterKey: nil) == "series")
        #expect(try await source.handleMigration(kind: .chapter, mangaKey: "/series", chapterKey: "/series/8") == "8.123")
        #expect(try await source.handleDeepLink(url: "https://raw.senmanga.com/manga/series/chapter-8.123/")?.chapterKey == "8.123")
        #expect(try await source.handleDeepLink(url: "https://raw.senmanga.com.attacker.invalid/manga/series/") == nil)
        #expect(try await source.handleDeepLink(url: "https://raw.senmanga.com/manga/series/chapter-/") == nil)
    }

    @Test func cancellationInsensitiveFetchCannotPublishDecodedResults() async throws {
        let source = SenMangaSourceRunner(fetch: { request in
            withUnsafeCurrentTask { $0?.cancel() }
            return (Data(#"{"series":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let task = Task { try await source.getSearchMangaList(query: nil, page: 1, filters: []) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
