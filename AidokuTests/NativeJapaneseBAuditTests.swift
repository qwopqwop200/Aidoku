import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeJapaneseBAuditTests {
    @Test
    func japaneseBSearchRequestsEscapeLiteralPlusForFormQueryDecoders() async throws {
        let senManga = SenMangaSourceRunner(fetch: { request in
            #expect(request.url?.absoluteString.contains("query=A%2BB") == true)
            return (Data(#"{"series":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await senManga.getSearchMangaList(query: "A+B", page: 1, filters: [])

        let yomii = YomiiSourceRunner(fetch: { request in
            #expect(request.url?.absoluteString.contains("search_key=A%2BB") == true)
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await yomii.getSearchMangaList(query: "A+B", page: 1, filters: [])
    }

    @Test
    func rawOtakuEcchiRatingKeepsRecoveredTemplatePrecedence() async throws {
        // MangaReader parser.rs checks Ecchi before the Japanese adult-type fallback.
        let html = """
        <div id="ani_detail">
          <h1 class="manga_name">Book</h1>
          <div class="genres"><a>Ecchi</a></div>
          <div class="anisc-info"><div class="item">タイプ <span class="name">オトナコミック</span></div></div>
        </div>
        """
        let runner = RawOtakuSourceRunner(fetch: { request in
            (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await runner.getMangaUpdate(
            manga: .init(sourceKey: "ja.rawotaku", key: "/book", title: "Book"),
            needsDetails: true, needsChapters: false
        )
        #expect(result.contentRating == .suggestive)
    }
}
