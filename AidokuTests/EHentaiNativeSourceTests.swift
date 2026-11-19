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

    @Test func oversizedResponsesKeepTheSourceLimitAndRefreshCookie() async throws {
        let storage = Preferences(["domain": "exhentai.org"])
        let runner = EHentaiSourceRunner(fetch: { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Set-Cookie": "igneous=updated; Path=/"])!
            throw SourceResponseBody.TooLarge(response: response)
        }, preference: { storage.get($0) }, setPreference: { storage.set($0, $1) })
        do {
            _ = try await runner.getSearchMangaList(query: "term", page: 1, filters: [])
            Issue.record("Expected the gallery size limit")
        } catch EHentaiSourceRunner.Failure.resourceLimit {}
        #expect(storage.get("igneous") == "updated")
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
