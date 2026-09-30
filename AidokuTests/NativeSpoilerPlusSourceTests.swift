import AidokuRunner
import Foundation
import Testing
import UIKit
@testable import Aidoku

struct NativeSpoilerPlusSourceTests {
    @Test func decodedKeysRoundTripWithoutDoubleEncodingAndRejectForeignHosts() throws {
        let key = try #require(SpoilerPlusSourceRunner.key("https://spoilerplus.tv/title-raw-free/%E7%AC%AC1%E8%A9%B1/"))
        #expect(key == "/title-raw-free/第1話/")
        #expect(try SpoilerPlusSourceRunner.url(key).absoluteString == "https://spoilerplus.tv/title-raw-free/%E7%AC%AC1%E8%A9%B1/")
        #expect(SpoilerPlusSourceRunner.key("https://spoilerplus.tv.evil.test/title/") == nil)
        #expect(SpoilerPlusSourceRunner.key("//evil.test/title/") == nil)
        #expect(SpoilerPlusSourceRunner.cleanTitle("Title Raw Free") == "Title")
    }
    @Test func windowNumbersKeepFractionalChaptersAndIgnoreWhitespace() {
        let script = "window.MangaId =  20466 ;window.CNumber = 417.5;"
        #expect(SpoilerPlusSourceRunner.windowNumber(script, name: "window.MangaId", fractional: false) == "20466")
        #expect(SpoilerPlusSourceRunner.windowNumber(script, name: "window.CNumber", fractional: true) == "417.5")
    }
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
    @Test func xorPermutationRejectsMalformedAndNonSquareKeys() throws {
        let mask = "spoilerplus.tv".utf8.reduce(UInt8(0), ^)
        func encode(_ string: String) -> String { string.utf8.map { String(format: "%02x", $0 ^ mask) }.joined() }
        #expect(try SpoilerPlusImageCodec.order(encode("3,2,1,0")) == [3, 2, 1, 0])
        #expect(throws: (any Error).self) { try SpoilerPlusImageCodec.order("xyz") }
        #expect(throws: (any Error).self) { try SpoilerPlusImageCodec.order(encode("0,1,2")) }
        #expect(throws: (any Error).self) { try SpoilerPlusImageCodec.order(encode("0,0,0,0")) }
    }
}
