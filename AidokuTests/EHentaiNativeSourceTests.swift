import AidokuRunner
import Foundation
import SwiftSoup
import Testing
@testable import Aidoku

struct EHentaiNativeSourceTests {
    private static let galleryURL = "https://e-hentai.org/g/123/abcdef/"
    private static let compact = """
        <table class="itg"><tr><th>Title</th></tr><tr>
        <td class="glname"><a href="https://e-hentai.org/g/123/abcdef/?p=0"><div class="glink" title="日本語">Title</div></a></td>
        <td class="glthumb"><img data-src="https://example.invalid/cover.jpg"></td><td class="cn">Manga</td>
        <td><div class="gt" title="artist:someone">someone</div><div class="gtl" title="female:guro">guro</div>
        <div class="gt" title="language:japanese">Japanese</div></td></tr></table><a id="dnext" href="?next=123">Next</a>
        """

    @Test func compactListPreservesCursorTitleLanguageAndBlocklist() throws {
        let result = try EHentaiParser.list(SwiftSoup.parse(Self.compact))
        #expect(result.items.count == 1)
        #expect(result.lastGID == "123")
        #expect(result.hasNext)
        let item = try #require(result.items.first)
        #expect(item.url == Self.galleryURL)
        #expect(item.language == "japanese")
        #expect(item.manga(sourceKey: "multi.ehentai", japanese: true, basic: true).title == "日本語")
        #expect(item.blocked(by: ["guro"]))
        #expect(item.blocked(by: ["female:guro"]))
        #expect(!item.blocked(by: ["male:guro"]))
        #expect(item.manga(sourceKey: "multi.ehentai", japanese: false).authors == ["someone"])
    }

    @Test func extendedAndThumbnailModesUseTheirActualSelectors() throws {
        let extended = """
            <table class="itg glte"><tr><td class="gl1e"><a href="\(Self.galleryURL)"><img src="cover.jpg"></a></td>
            <td><div class="glname"><div class="glink" title="Other">Extended</div></div><div class="cn">Non-H</div></td></tr></table>
            """
        let thumbnail = """
            <div class="gl1t"><a href="\(Self.galleryURL)"><img src="thumb.jpg"></a><div class="glink">Thumb</div><div class="cn">Manga</div></div>
            """
        let extendedResult = try EHentaiParser.list(SwiftSoup.parse(extended))
        #expect(extendedResult.items.first?.title == "Extended")
        #expect(extendedResult.items.first?.manga(sourceKey: "test", japanese: false).contentRating == .safe)
        #expect(try EHentaiParser.list(SwiftSoup.parse(thumbnail)).items.first?.title == "Thumb")
        #expect(try EHentaiParser.list(SwiftSoup.parse("<table class='itg'><tr><td>No title or gallery URL</td></tr></table>")).items.isEmpty)
    }

    @Test func toplistPaginationUsesActiveRankPage() throws {
        let active = Self.compact + "<table><tr><td class='ptds'>198</td></tr></table>"
        #expect(try EHentaiParser.list(SwiftSoup.parse(active), toplist: true).hasNext)
        #expect(try !EHentaiParser.list(SwiftSoup.parse(active.replacingOccurrences(of: ">198<", with: ">199<")), toplist: true).hasNext)
    }

    @Test func galleryDetailKeepsMetadataAndReaderDirection() throws {
        let html = """
            <div id="gn">Title</div><div id="gj">日本語</div><div id="gd1"><div style="background:url('https://example.invalid/cover.jpg')"></div></div>
            <div id="gdc"><div>Manga</div></div><div id="gdn">Uploader</div><table id="gdd">
            <tr><td class="gdt1">Posted:</td><td class="gdt2">2026-09-30 12:30</td></tr>
            <tr><td class="gdt1">Language:</td><td class="gdt2">Japanese TR</td></tr>
            <tr><td class="gdt1">Length:</td><td class="gdt2">25 pages</td></tr></table>
            <div id="rating_label">Average: 4.5</div><div id="rating_count">10</div><table id="taglist">
            <tr><td class="tc">language:</td><td><div>japanese</div></td></tr><tr><td class="tc">artist:</td><td><div>Someone</div></td></tr></table>
            """
        let gallery = try EHentaiParser.detail(SwiftSoup.parse(html), url: Self.galleryURL)
        #expect(gallery.length == 25)
        #expect(gallery.language == "Japanese")
        #expect(gallery.translated)
        #expect(gallery.manga(sourceKey: "test", japanese: true).viewer == .rightToLeft)
        #expect(gallery.manga(sourceKey: "test", japanese: false).description?.contains("Rating: 4.5 (10 votes)") == true)
        #expect(gallery.item.cover == "https://example.invalid/cover.jpg")
    }

    @Test func viewerAndMPVKeysAreParsedAsDataIncludingBracketsInStrings() throws {
        #expect(EHentaiParser.viewer("https://e-hentai.org/s/imagekey/123-4")?.page == 4)
        #expect(EHentaiParser.viewer("https://e-hentai.org.evil/s/imagekey/123-4") == nil)
        let doc = try SwiftSoup.parse("<script>var mpvkey = \"key\"; var imagelist = [{\"k\":\"bracket]inside\"},{\"k\":\"other\"}];</script>")
        #expect(try EHentaiParser.mpv(doc)?.imageKeys == ["bracket]inside", "other"])
        #expect(try EHentaiParser.showkey(SwiftSoup.parse("<script>showkey=\"show\";</script>")) == "show")
        #expect(try EHentaiParser.nl(SwiftSoup.parse("<a id='loadfail' onclick=\"return nl('retry')\">Retry</a>")) == "retry")
    }

    @Test func quickOpenAndDeepLinksRequireActualGalleryHost() async throws {
        #expect(EHentaiParser.quickIDToken("123 abc")?.token == "abc")
        #expect(EHentaiParser.quickIDToken("123/abc")?.gid == "123")
        #expect(EHentaiParser.quickIDToken("123/abc?evil") == nil)
        #expect(EHentaiParser.galleryIDToken("https://e-hentai.org.evil/g/123/abc/") == nil)
        let runner = EHentaiSourceRunner(preference: { $0 == "domain" ? "exhentai.org" : nil })
        #expect(try await runner.handleDeepLink(url: "https://e-hentai.org/g/123/abc/?p=2")?.mangaKey == "https://exhentai.org/g/123/abc/")
        #expect(try await runner.handleDeepLink(url: "https://evil.invalid/g/123/abc/") == nil)
    }

    @Test func nativeSearchPreservesTagSyntaxFiltersLanguageAndCursor() async throws {
        let storage = Preferences(["language": "ko"])
        let transport = Transport { request, _ in Data(Self.compact.utf8) }
        let runner = EHentaiSourceRunner(fetch: { try await transport.fetch($0) }, preference: { storage.get($0) },
                                        setPreference: { storage.set($0, $1) })
        let filters: [AidokuRunner.FilterValue] = [.text(id: "author", value: "Author"), .text(id: "tags", value: "tag, -bad, ~other"),
                                     .select(id: "min_rating", value: "4"), .text(id: "min_pages", value: "10"),
                                     .multiselect(id: "categories", included: ["f_manga"], excluded: [])]
        let result = try await runner.getSearchMangaList(query: "word", page: 1, filters: filters)
        #expect(result.entries.count == 1)
        _ = try await runner.getSearchMangaList(query: "word", page: 2, filters: filters)
        let requests = await transport.requests
        let first = try #require(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems)
        let query = first.first { $0.name == "f_search" }?.value ?? ""
        #expect(query.contains("~artist:\"Author$\" ~group:\"Author$\""))
        #expect(query.contains("-\"bad$\" ~\"other$\""))
        #expect(query.contains("language:\"korean$\""))
        #expect(first.first { $0.name == "f_manga" }?.value == "1")
        #expect(first.first { $0.name == "f_doujinshi" }?.value == "0")
        #expect(first.first { $0.name == "f_srdd" }?.value == "4")
        #expect(requests[1].url?.query?.contains("next=123") == true)
    }

    @Test func imageAPIRetries509AndNeverForwardsAccountCookiesToExternalImageHost() async throws {
        let transport = Transport { request, count in
            if request.httpMethod == "POST" {
                let object: [String: Any] = count == 1 ? ["i3": "<img src='https://example.invalid/509.gif'>", "i6": "nl('retry')"]
                    : ["i3": "<img src='https://example.invalid/page.jpg'>"]
                return try JSONSerialization.data(withJSONObject: object)
            }
            throw URLError(.badServerResponse)
        }
        let runner = EHentaiSourceRunner(fetch: { try await transport.fetch($0) }, preference: { key in
            key == "ipb_member_id" ? "123" : key == "ipb_pass_hash" ? "secret" : nil
        })
        let context = ["mode": "showpage", "gid": "123", "imgkey": "image", "page": "1", "showkey": "show",
                       "viewer_url": "https://e-hentai.org/s/image/123-1"]
        let request = try await runner.getImageRequest(url: context["viewer_url"]!, context: context)
        #expect(request.url?.absoluteString == "https://example.invalid/page.jpg")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Cookie")?.contains("ipb_member_id=123") == true)
        let retry = try #require(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        #expect(retry["nl"] as? String == "retry")
    }

    @Test func APIErrorFallsBackToNativeHTMLImageExtraction() async throws {
        let transport = Transport { request, _ in
            request.httpMethod == "POST" ? Data("{\"error\":\"expired\"}".utf8)
                : Data("<img id='img' src='https://example.invalid/fallback.jpg'>".utf8)
        }
        let runner = EHentaiSourceRunner(fetch: { try await transport.fetch($0) })
        let request = try await runner.getImageRequest(url: "https://e-hentai.org/s/key/123-1",
                                                      context: ["gid": "123", "imgkey": "key", "showkey": "expired"])
        #expect(request.url?.absoluteString == "https://example.invalid/fallback.jpg")
    }

    @Test func dynamicListingsAndHomeKeepWatchedAndToplistComponents() async throws {
        let transport = Transport { _, _ in Data(Self.compact.utf8) }
        let runner = EHentaiSourceRunner(fetch: { try await transport.fetch($0) }, preference: { key in
            ["ipb_member_id", "ipb_pass_hash"].contains(key) ? "value" : nil
        })
        #expect(await runner.getListings().first?.id == "watched")
        let home = try await runner.getHome()
        #expect(home.components.map(\.title) == ["Top Yesterday", "Top Month", "Top Year", "Watched", "Popular", "Latest"])
        #expect(await transport.requests.count == 6)
    }

    private actor Transport {
        var requests: [URLRequest] = []
        let handler: @Sendable (URLRequest, Int) throws -> Data
        init(handler: @escaping @Sendable (URLRequest, Int) throws -> Data) { self.handler = handler }
        func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            return (try handler(request, requests.count), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
    }
    private final class Preferences: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String]
        init(_ values: [String: String]) { self.values = values }
        func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func set(_ key: String, _ value: String?) { lock.lock(); defer { lock.unlock() }; values[key] = value }
    }
}
