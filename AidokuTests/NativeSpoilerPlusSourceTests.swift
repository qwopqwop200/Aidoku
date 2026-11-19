import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeSpoilerPlusSourceTests {
    @Test func apiRequestUsesIDsAndRefererAndPassesOrderKeyToEveryPage() async throws {
        let source = SpoilerPlusSourceRunner(fetch: { request in
            if request.httpMethod == "POST" {
                #expect(request.url?.path == "/api/v1/get/c")
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://spoilerplus.tv/title-raw-free/chapter/")
                let json = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: NSNumber])
                #expect(json["m"]?.intValue == 20466)
                #expect(json["n"]?.doubleValue == 417.5)
                let body = #"{"c":"encoded-order","e":["/first.jpg","/second.jpg"]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let body = "<script>window.MangaId = 20466; window.CNumber = 417.5;</script>"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let pages = try await source.getPageList(manga: AidokuRunner.Manga(sourceKey: "ja.spoilerplus", key: "/title-raw-free/", title: "Title"),
                                               chapter: AidokuRunner.Chapter(key: "/title-raw-free/chapter/"))
        #expect(pages.count == 2)
        if case .url(let url, let context) = pages[0].content {
            #expect(url.absoluteString == "https://img-cdn.stackpathcdn.app/first.jpg")
            #expect(context?["key"] == "encoded-order")
        } else { Issue.record("Expected a native URL page") }
    }
}
