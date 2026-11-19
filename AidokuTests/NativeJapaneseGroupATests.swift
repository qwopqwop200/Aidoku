import AidokuRunner
import Foundation
import SwiftSoup
import Testing
@testable import Aidoku

struct NativeJapaneseGroupATests {
    @Test func mangaRawBestListingKeepsBareSlugLazyCoverAndPagination() throws {
        let doc = try SwiftSoup.parse("""
        <div class="manga-vertical"><a href="/raw/series/di-2hua"></a>
        <div class="post-title"><a>Series</a></div><img class="cover" src="/placeholder" data-src="/cover.jpg"></div>
        <a class="paging_prevnext next" href="/manga-list?page=4">Last</a>
        """, "https://mangaraw.best/")
        let result = try MangarawBestSourceRunner.parseListing(doc, sourceKey: "ja.mangarawbest", page: 2)
        #expect(result.entries.first?.key == "series")
        #expect(result.entries.first?.cover == "https://mangaraw.best/cover.jpg")
        #expect(result.hasNextPage)
        #expect(try !MangarawBestSourceRunner.parseListing(doc, sourceKey: "ja.mangarawbest", page: 4).hasNextPage)
    }

    @Test func mangaRawJPListingScopesFirstBlockAndCleansTitle() throws {
        let doc = try SwiftSoup.parse("""
        <div class="post-list"><a href="/manga-raw/one/"><h3>One Raw Free</h3><img data-src="/one.jpg" src="data:image/png;base64,placeholder"></a></div>
        <div class="post-list"><a href="/manga-raw/two/"><h3>Ranking</h3></a></div>
        """, "https://mangarawjp.tv/")
        let result = try MangarawJPSourceRunner.parseListing(doc, sourceKey: "ja.mangarawjp")
        #expect(result.entries.count == 1)
        #expect(result.entries[0].key == "/manga-raw/one/")
        #expect(result.entries[0].title == "One")
        #expect(result.entries[0].cover == "https://mangarawjp.tv/one.jpg")
    }

    @Test func rawdevartDecimalChapterKeysAndNullableListsDecode() throws {
        #expect(RawdevartSourceRunner.chapterKey(34.2) == "34.2")
        #expect(RawdevartSourceRunner.chapterKey(1) == "1")
        let data = Data("""
        {"manga_list":[{"manga_id":854721,"manga_name":" AR/MS!! ","manga_cover_img":"small","manga_cover_img_full":"full"}],"pagi":{"button":{"next":2}},"genreOpt":null}
        """.utf8)
        let response = try JSONDecoder().decode(RawdevartSourceRunner.ListResponse.self, from: data)
        let result = response.mangaPage(sourceKey: "ja.rawdevart")
        #expect(result.hasNextPage)
        #expect(result.entries[0].key == "854721")
        #expect(result.entries[0].cover == "full")
        #expect(result.entries[0].title == "AR/MS!!")
    }

    /// Relative dates built from server text never become non-finite.
    @Test func mangaRawBestOverflowingRelativeDatesAreRejected() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(MangarawBestSourceRunner.relativeDate("2日前", now: now) == now.addingTimeInterval(-2 * 86400))
        #expect(MangarawBestSourceRunner.relativeDate(String(repeating: "9", count: 306) + "年前", now: now) == nil)
        #expect(MangarawBestSourceRunner.relativeDate(String(repeating: "9", count: 400) + "秒前", now: now) == nil)
    }
}
