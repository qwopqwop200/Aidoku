import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeSoraRawSourceTests {
    private func runner(_ body: String) -> SoraRawSourceRunner {
        SoraRawSourceRunner(fetch: { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }
    @Test func nextDataListingPreservesCoverAuthorsAndPagination() async throws {
        let html = #"<script id="__NEXT_DATA__">{"props":{"pageProps":{"data":{"results":[{"name":" Series ","slug":"series-1","author":"A, B","thumbnail":"https://example.test/cover","type":"incomplete","is_adult":"no"}],"pagination":{"current_page":1,"total_page":2}}}}}</script>"#
        let result = try await runner(html).getSearchMangaList(query: nil, page: 1, filters: [])
        #expect(result.hasNextPage)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].key == "series-1")
        #expect(result.entries[0].title == "Series")
        #expect(result.entries[0].authors == ["A", "B"])
        #expect(result.entries[0].viewer == .unknown)
        #expect(result.entries[0].contentRating == .safe)
    }
    @Test func detailsUseGenreSlugAndEditorDocumentAndFractionalChapterIDs() async throws {
        let html = #"<script id="__NEXT_DATA__">{"props":{"pageProps":{"data":{"manga":{"id":123,"name":"Title","slug":"title-123","image":"cover.jpg","type":"complete","is_adult":"yes","genres":[{"name":"Overseas","slug":"kaigai-manga"}],"content":"{\"blocks\":[{\"data\":{\"text\":\"<b>Synopsis</b>\"}}]}","chapters":[{"id":456,"name":"74.2","title":" extra ","path":"title-123-ch-74-2","published_at":"2026-09-30T01:02:03.000Z"}]}}}}}</script>"#
        let source = runner(html)
        let manga = AidokuRunner.Manga(sourceKey: "ja.soraraw", key: "title-123", title: "Old")
        let updated = try await source.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
        #expect(updated.viewer == .webtoon)
        #expect(updated.description == "Synopsis")
        #expect(updated.status == .completed)
        #expect(updated.chapters?.first?.key == "123/456")
        #expect(updated.chapters?.first?.chapterNumber == 74.2)
        #expect(updated.chapters?.first?.url?.absoluteString == "https://soraraw.com/manga/title-123/ch-74-2")
        #expect(updated.chapters?.first?.language == nil)
    }
    @Test func catalogueSearchChecksAlternateNamesAndAuthorAndEndsOn404() async throws {
        let source = SoraRawSourceRunner(fetch: { request in
            let first = request.url!.path == "/mangas_1.json"
            let body = #"{"list":[{"name":"Title","slug":"title","alt_names":"Alias","author":"Someone","img":"image.jpg"}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: first ? 200 : 404, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await source.getSearchMangaList(query: "alias", page: 1, filters: [.text(id: "author", value: "someone")])
        #expect(result.entries.map(\.key) == ["title"])
        #expect(!result.hasNextPage)
        #expect(result.entries[0].cover == "https://i.mangaraw.lat/image.jpg")
    }
}
