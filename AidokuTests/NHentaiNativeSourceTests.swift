import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NHentaiNativeSourceTests {
    private static let gallery = """
    {"id":42,"title":{"english":"English title","japanese":"日本語","pretty":"Title"},
    "cover":{"path":"/galleries/12/cover.jpg"},"upload_date":1700000000,
    "tags":[{"name":"tag-low","count":1,"type":"tag"},{"name":"webtoon","count":5,"type":"tag"},
    {"name":"artist-a","count":2,"type":"artist"},{"name":"group-a","count":3,"type":"group"},
    {"name":"original","count":100,"type":"parody"},{"name":"Series","count":4,"type":"parody"},
    {"name":"Person","count":4,"type":"character"},{"name":"translated","count":1,"type":"language"},
    {"name":"english","count":1,"type":"language"},{"name":"rewrite","count":1,"type":"language"}],
    "num_pages":2,"num_favorites":7,"pages":[{"path":"galleries/12/1.jpg"},{"path":"https://cdn.invalid/2.png"}]}
    """
    private static let search = """
    {"result":[{"id":42,"thumbnail":"/galleries/12/thumb.jpg","english_title":"English title","japanese_title":"日本語"}],"num_pages":2}
    """

    private actor NetworkFixture {
        var requests: [URLRequest] = []
        let status: Int
        init(status: Int = 200) { self.status = status }
        func fetch(_ request: URLRequest) -> (Data, URLResponse) {
            requests.append(request)
            let data = request.url!.path.contains("/galleries/") ? NHentaiNativeSourceTests.gallery : NHentaiNativeSourceTests.search
            return (Data(data.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func searchPreservesV17FilterLanguageBlocklistAndPaginationContract() async throws {
        let fixture = NetworkFixture()
        let runner = NHentaiSourceRunner(fetch: { await fixture.fetch($0) },
                                        preference: { $0 == "language" ? "ja" : nil },
                                        stringListPreference: { _ in ["  Blocked TAG ", ""] })
        let result = try await runner.getSearchMangaList(query: "a+b", page: 1, filters: [
            .text(id: "author", value: "Author"), .text(id: "artist", value: "Artist"), .text(id: "groups", value: "Group"),
            .sort(.init(id: "sort", index: 2, ascending: false)),
            .multiselect(id: "tags", included: ["included tag"], excluded: ["excluded tag"]), .select(id: "genre", value: "Genre")
        ])
        #expect(result.entries.map(\.key) == ["42"])
        #expect(result.hasNextPage)
        let requests = await fixture.requests
        #expect(requests.count == 1)
        let components = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!
        let values = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        #expect(components.path == "/api/v2/search")
        #expect(values["query"] == "a+b Author artist:Artist group:Group tag:\"included tag\" -tag:\"excluded tag\" tag:\"Genre\" language:japanese -tag:\"blocked tag\"")
        #expect(values["sort"] == "popular-week")
        #expect(requests[0].url!.absoluteString.contains("a%2Bb"))
        #expect(requests[0].value(forHTTPHeaderField: "User-Agent")?.contains("iPhone OS 17_2") == true)
    }

    @Test func detailsChaptersAndCachedPageImagesMatchV17() async throws {
        let fixture = NetworkFixture()
        let runner = NHentaiSourceRunner(fetch: { await fixture.fetch($0) }, preference: { _ in nil })
        let manga = AidokuRunner.Manga(sourceKey: "multi.nhentai", key: "42", title: "Original")
        let updated = try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
        #expect(updated.tags == ["webtoon", "tag-low"])
        #expect(updated.artists == ["artist-a"])
        #expect(updated.authors == ["group-a", "artist-a"])
        #expect(updated.viewer == .webtoon && updated.updateStrategy == .never)
        #expect(updated.description == "#42  \nParodies: Series  \nCharacters: Person  \nPages: 2  \nFavorited by: 7")
        #expect(updated.chapters?.first?.scanlators == ["english"])
        #expect(updated.chapters?.first?.dateUploaded == Date(timeIntervalSince1970: 1700000000))
        let pages = try await runner.getPageList(manga: updated, chapter: updated.chapters![0])
        #expect(pages.count == 2)
        #expect(pages[0].content == .url(url: URL(string: "https://i.nhentai.net/galleries/12/1.jpg")!))
        #expect(pages[1].content == .url(url: URL(string: "https://cdn.invalid/2.png")!))
        #expect(await fixture.requests.count == 1)
        await runner.clearCache()
        _ = try await runner.getPageList(manga: updated, chapter: updated.chapters![0])
        #expect(await fixture.requests.count == 2)
    }
}
