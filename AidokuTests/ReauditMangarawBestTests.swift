import AidokuRunner
import SwiftSoup
import Testing
@testable import Aidoku

struct ReauditMangarawBestTests {
    @Test func chapterNumberPrefersJapaneseChapterMarkerOverEarlierUnrelatedNumbers() throws {
        // Upstream parse_chapter_number searches for 第 before falling back to the first digit.
        let document = try SwiftSoup.parse("""
        <div id="chapterList"><ul><li><a href="/raw/series/special">
        <span class="text-ellipsis">2025年記念 第12.5話</span>
        </a></li></ul></div>
        """, "https://mangaraw.best/")
        let chapter = try #require(MangarawBestSourceRunner.parseChapters(document).first)
        #expect(chapter.chapterNumber == 12.5)
        #expect(chapter.title == "2025年記念 第12.5話")
    }

    @Test func chapterNumberRetainsUpstreamFallbackAndMalformedNumberBehavior() {
        #expect(MangarawBestSourceRunner.chapterNumber("特別編 7.5") == 7.5)
        #expect(MangarawBestSourceRunner.chapterNumber("第7.話") == 7)
        #expect(MangarawBestSourceRunner.chapterNumber("第特別編 5") == nil)
        #expect(MangarawBestSourceRunner.chapterNumber("第7..5話") == nil)
    }

    @Test func deepLinkRejectsUnsupportedURLSchemes() async throws {
        let runner = MangarawBestSourceRunner()
        // Upstream strip_base_url recognizes HTTP(S) and bare host links, not FTP URLs.
        #expect(try await runner.handleDeepLink(url: "ftp://mangaraw.best/raw/series/chapter") == nil)
        #expect(try await runner.handleDeepLink(url: "file://mangaraw.best/raw/series") == nil)
        let supported = try await runner.handleDeepLink(url: "https://mangaraw.best/raw/series/chapter?track=1#page")
        #expect(supported?.mangaKey == "series")
        #expect(supported?.chapterKey == "chapter")
    }
}
