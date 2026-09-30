import AidokuRunner
import Foundation
import SwiftSoup
import Testing
@testable import Aidoku

struct ReauditYomiiTests {
    // Reduced public response corpus fetched 2026-09-30 using normal GET requests.
    // Listing: https://11toon.com/bbs/board.php?bo_table=toon_c&type=upd&page=1
    // Details/reader: bo_table=toons&is=33669, additionally wr_id=1830166 for reader.
    // Actual backed func58 (WASM SHA-256 d1fa9db...766a670) resolves // with https:
    // and / with the fixed https://11toon.com base, independent of document location.
    private static let listing = #"""
    <ul id="free-genre-list"><li data-id="33669">
      <div class="homelist-thumb" style="background-image: url('//11toon8.com/data/toon_category/33669.webp');"></div>
      <div class="homelist-title"><span>D제네시스 던전이 생기고 3년</span></div>
      <div class="homelist-genre"><span data-genre="romance">판타지 09.30<font color="red">(0)</font></span></div>
    </li></ul><a href="./board.php?bo_table=toon_c&amp;type=upd&amp;page=6" class="pg_page pg_next">다음</a>
    """#
    private static let chapterHTML = #"""
    <button type="button" class="episode is-series"
      onclick="location.href='./board.php?bo_table=toons&amp;wr_id=1830166&amp;stx=D제네시스 던전이 생기고 3년&amp;is=33669'">
      <div class="episode-banner" style="background-image: url('//11toon7.com/07/1830166.webp');"></div>
      <div class="episode-title ellipsis">D제네시스 던전이 …기고 3년 56화</div>
    </button>
    """#
    private static let readerHTML = #"""
    <script>
    var img_list = ["//www.pl3040.com/kr/07/33669/1830166/175417_4f57cf638720.jpg","//www.pl3040.com/kr/07/33669/1830166/175417_855d2a283469.jpg"];
    var img_list_2 = ["//www.pl4050.com/kr/07/33669/1830166/175417_4f57cf638720.jpg?v=ei","//www.pl4050.com/kr/07/33669/1830166/175417_855d2a283469.jpg?v=ei"];
    </script>
    """#

    @Test func publicCorpusCoversAndChapterThumbnailsResolveRecoveredRelativeForms() throws {
        let list = try SwiftSoup.parse(Self.listing, "https://redirect.test/bbs/board.php")
        let mangas = try YomiiSourceRunner.cards(list, sourceKey: "ko.yomii")
        #expect(mangas.count == 1)
        #expect(mangas.first?.cover == "https://11toon8.com/data/toon_category/33669.webp")
        #expect(mangas.first?.tags == ["판타지"])
        let chapters = try YomiiSourceRunner.chapters(SwiftSoup.parse(Self.chapterHTML), mangaKey: "33669")
        #expect(chapters.first?.key == "1830166")
        #expect(chapters.first?.thumbnail == "https://11toon7.com/07/1830166.webp")
        #expect(YomiiSourceRunner.styleURL("background:url( '/data/thumb.webp' )") == "https://11toon.com/data/thumb.webp")
        #expect(YomiiSourceRunner.styleURL("background:url(https://cdn.test/thumb.webp)") == "https://cdn.test/thumb.webp")
    }

    @Test func scriptRootPathsUseFixedBaseAndNeverEvaluateExpressions() throws {
        let html = #"<script>var img_list = [ '/data/one.jpg', "//cdn.test/two.jpg", "https://cdn.test/three.jpg", location.origin + '/four.jpg' ];</script>"#
        let images = try YomiiSourceRunner.scriptImages(SwiftSoup.parse(html, "https://redirect.test/bbs/"), marker: "var img_list = [")
        #expect(images.map(\.absoluteString) == ["https://11toon.com/data/one.jpg", "https://cdn.test/two.jpg", "https://cdn.test/three.jpg"])
    }

    @Test func publicReaderCorpusPreservesProbeStatusFallbackAndHeaders() async throws {
        for status in [200, 302, 404] {
            let requests = Requests()
            let runner = YomiiSourceRunner(fetch: { request in
                await requests.record(request)
                return (Data(Self.readerHTML.utf8), HTTPURLResponse(url: request.url!,
                    statusCode: request.httpMethod == "HEAD" ? status : 200, httpVersion: nil, headerFields: nil)!)
            })
            let pages = try await runner.getPageList(manga: .init(sourceKey: "ko.yomii", key: "33669", title: "D"),
                chapter: .init(key: "1830166"))
            #expect(pages.count == 2)
            if case let .url(url, _) = pages[0].content {
                #expect(url.host == (status == 404 ? "www.pl4050.com" : "www.pl3040.com"))
                #expect(url.scheme == "https")
            } else { Issue.record("Expected image URL") }
            let recorded = await requests.values
            #expect(recorded.filter { $0.httpMethod == "HEAD" }.count == (status == 404 ? 1 : 3))
            for request in recorded {
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://11toon.com")
                #expect(request.value(forHTTPHeaderField: "User-Agent") ==
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1")
            }
        }
    }

    @Test func cancellationFromHeadProbeDoesNotSelectAlternate() async throws {
        let runner = YomiiSourceRunner(fetch: { request in
            if request.httpMethod == "HEAD" { throw CancellationError() }
            return (Data(Self.readerHTML.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await runner.getPageList(manga: .init(sourceKey: "ko.yomii", key: "33669", title: "D"),
                chapter: .init(key: "1830166"))
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func textQueryUsesRecoveredLatestOrderAndIgnoresHiddenGenreSort() async throws {
        // Reduced rows from normal /bbs/ajax.search.php?search_key=D response, with
        // opposite filter values to expose func124's explicit query-branch reset.
        let json = #"""
        {"status":true,"list":[
          {"wr_id":"35381","wr_subject":"MAD","ca_name":"SF,액션","wr_content":"",
           "wr_6":"오오토리 유스케","wr_datetime":"2024-08-12 09:40:43"},
          {"wr_id":"36772","wr_subject":"DVD","ca_name":"순정","wr_content":"",
           "wr_6":"천계영","wr_datetime":"2026-07-08 16:03:21"}
        ],"counts":2}
        """#
        let requests = Requests()
        let runner = YomiiSourceRunner(fetch: { request in
            await requests.record(request)
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await runner.getSearchMangaList(query: " D ", page: 1,
            filters: [.sort(.init(id: "sort", index: 1, ascending: true)), .select(id: "genre", value: "SF")])
        #expect(result.entries.map(\.key) == ["36772", "35381"])
        #expect(!result.hasNextPage)
        let recorded = await requests.values
        #expect(recorded.count == 1)
        #expect(recorded.first?.url?.absoluteString == "https://11toon.com/bbs/ajax.search.php?search_key=D")
    }

    private actor Requests {
        var values: [URLRequest] = []
        func record(_ request: URLRequest) { values.append(request) }
    }
}
