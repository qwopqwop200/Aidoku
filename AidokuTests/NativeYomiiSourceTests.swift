import AidokuRunner
import Foundation
import SwiftSoup
import Testing
@testable import Aidoku

struct NativeYomiiSourceTests {
    private static let listHTML = #"<ul id="free-genre-list"><li data-id="12"><span class="homelist-title"> Example </span><div class="homelist-thumb" style="background-image:url('https://cdn.test/cover.webp')"></div><div class="homelist-genre"><span>액션, 성인 (120화)</span></div></li></ul><a class="pg_next" href="?page=2">Next</a>"#
    private static let detailHTML = #"<div id="cover-info"><h2 class="title">Updated</h2><img class="banner" src="/cover.webp"><div class="genre"><a class="genre-link">액션, 성인</a></div><div class="content"><a class="genre-link">Description</a></div><span class="publisher">작가 : Author</span></div><button class="episode" onclick="location.href='/bbs/board.php?bo_table=toons&amp;wr_id=90&amp;is=12'"><span class="episode-title">Episode 90</span><div class="episode-banner" style="background:url('https://cdn.test/thumb.webp')"></div></button><a class="pg_page" href="?page=2">2</a>"#

    @Test func recoveredListingSelectorsAndRating() throws {
        let document = try SwiftSoup.parse(Self.listHTML, "https://11toon.com")
        let cards = try YomiiSourceRunner.cards(document, sourceKey: "ko.yomii", completed: true)
        #expect(cards.count == 1)
        #expect(cards[0].key == "12")
        #expect(cards[0].title == "Example")
        #expect(cards[0].cover == "https://cdn.test/cover.webp")
        #expect(cards[0].tags == ["액션", "성인"])
        #expect(cards[0].contentRating == .suggestive)
        #expect(cards[0].status == .completed)
        #expect(cards[0].viewer == .rightToLeft)
        #expect(throws: YomiiSourceRunner.Failure.self) { try YomiiSourceRunner.listingItems("unknown") }
    }

    @Test func recoveredAJAXArrayAndObjectSearchSort() throws {
        let rows = #"[{"wr_id":"12","wr_subject":" First ","ca_name":"액션, 성인","wr_content":"Desc","wr_6":"Artist","wr_datetime":"2024-02-01","num":"2"},{"wr_id":"13","wr_subject":"Second","ca_name":"액션","wr_content":"","wr_6":"","wr_datetime":"2024-01-01","num":"10"}]"#
        let filters: [AidokuRunner.FilterValue] = [.sort(.init(id: "sort", index: 1, ascending: false)), .select(id: "genre", value: "액션")]
        let array = try YomiiSourceRunner.searchMangas(Data(rows.utf8), sourceKey: "ko.yomii", filters: filters)
        let object = try YomiiSourceRunner.searchMangas(Data("{\"list\":\(rows)}".utf8), sourceKey: "ko.yomii", filters: filters)
        #expect(array == object)
        #expect(array.map(\.key) == ["13", "12"])
        #expect(array[1].authors == ["Artist"])
        #expect(array[1].cover == "https://11toon8.com/data/toon_category/12.webp")
        #expect(array[1].description == "Desc")
        #expect(throws: YomiiSourceRunner.Failure.self) {
            try YomiiSourceRunner.searchMangas(Data("{}".utf8), sourceKey: "ko.yomii", filters: [])
        }
    }

    @Test func detailsAndAllChapterPagesUseRecoveredRoutes() async throws {
        let recorder = Requests()
        let runner = YomiiSourceRunner(fetch: { request in
            await recorder.record(request)
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            let html = page == "2" ? #"<button class="episode" onclick="go('wr_id=89&amp;is=12')"><span class="episode-title">Episode 89</span></button>"# : Self.detailHTML
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await runner.getMangaUpdate(manga: .init(sourceKey: "ko.yomii", key: "12", title: "Old"), needsDetails: true, needsChapters: true)
        #expect(result.title == "Updated")
        #expect(result.authors == ["Author"])
        #expect(result.description == "Description")
        #expect(result.chapters?.map(\.key) == ["90", "89"])
        #expect(result.chapters?.first?.language == "ko")
        #expect(result.chapters?.first?.thumbnail == "https://cdn.test/thumb.webp")
        #expect(await recorder.count == 2)
    }

    @Test func readerChoosesAlternateOnProbeFailureWithoutEvaluatingScripts() async throws {
        let runner = YomiiSourceRunner(fetch: { request in
            let html = #"<script>var img_list = ['https://cdn.test/primary.webp']; var img_list_2 = ['https://cdn.test/alternate.webp']; throw new Error('never executed');</script>"#
            let status = request.httpMethod == "HEAD" ? 404 : 200
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        let pages = try await runner.getPageList(manga: .init(sourceKey: "ko.yomii", key: "12", title: "Book"), chapter: .init(key: "90"))
        #expect(pages.count == 1)
        if case let .url(url, _) = pages[0].content { #expect(url.absoluteString == "https://cdn.test/alternate.webp") }
        else { Issue.record("Expected a native image URL") }
        let document = try SwiftSoup.parse("<script>var img_list = [alert('x')];</script>")
        #expect(try YomiiSourceRunner.scriptImages(document, marker: "var img_list = [").isEmpty)
    }

    @Test func AJAXDoesNotRequestAnotherPageAndCancellationPropagates() async throws {
        let runner = YomiiSourceRunner(fetch: { _ in throw CancellationError() })
        let empty = try await runner.getSearchMangaList(query: "term", page: 2, filters: [])
        #expect(empty.entries.isEmpty)
        do {
            _ = try await runner.getSearchMangaList(query: "term", page: 1, filters: [])
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func homeUsesRecoveredTitlesAndComponentShapes() async throws {
        let runner = YomiiSourceRunner(fetch: { request in
            (Data(Self.listHTML.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let home = try await runner.getHome()
        #expect(home.components.map(\.title) == ["오늘의 추천", "방금 올라온 만화", "지금 인기 있는 만화", "정주행하기 좋은 완결작"])
        if case let .bigScroller(entries, interval) = home.components[0].value {
            #expect(entries.count == 1)
            #expect(interval == 6)
        } else { Issue.record("Expected daily big scroller") }
        if case let .mangaList(ranking, size, _, _) = home.components[2].value {
            #expect(ranking)
            #expect(size == 5)
        } else { Issue.record("Expected popular ranked list") }
        if case .scroller = home.components[3].value {} else { Issue.record("Expected completed scroller") }
    }

    private actor Requests {
        var count = 0
        func record(_ request: URLRequest) {
            count += 1
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://11toon.com")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == YomiiSourceRunner.userAgent)
        }
    }
}
