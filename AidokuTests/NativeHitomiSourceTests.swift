import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeHitomiSourceTests {
    private static let gallery = #"{"id":"123","title":"English | Fallback Japanese","japanese_title":"Japanese","galleryurl":"/galleries/example-123.html","type":"manga","language":"korean","date":"2024-01-02 03:04:05","files":[{"hash":"abcdef0123","haswebp":1,"hasavif":0}],"artists":[{"artist":"Artist"}],"groups":[{"group":"Group"}],"tags":[{"tag":"comic","female":"1"}]}"#

    @Test func metadataPreservesTitleAuthorsAndViewer() throws {
        let gallery = try JSONDecoder().decode(HitomiGallery.self, from: Data(Self.gallery.utf8))
        let japanese = gallery.manga(sourceKey: "multi.hitomi", japanese: true)
        #expect(japanese.title == "Japanese")
        #expect(japanese.authors == ["Group", "Artist"])
        #expect(japanese.tags == ["comic♀"])
        #expect(japanese.viewer == .webtoon)
        #expect(japanese.cover == "https://atn.gold-usergeneratedcontent.net/avifbigtn/3/12/abcdef0123.avif")
        #expect(gallery.manga(sourceKey: "multi.hitomi", japanese: false).title == "English | Fallback Japanese")
    }

    @Test func singleIndexSearchPaginatesWithRangeRequests() async throws {
        let index = Data((1...30).flatMap { id -> [UInt8] in [0, 0, 0, UInt8(id)] })
        let runner = HitomiSourceRunner(fetch: { request in
            let url = request.url!
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://hitomi.la/")
            if url.path.hasPrefix("/galleries/") {
                let id = url.deletingPathExtension().lastPathComponent
                let info = "var galleryinfo = {\"id\":\"\(id)\",\"title\":\"Gallery \(id)\",\"galleryurl\":\"/g/\(id)/\",\"type\":\"manga\",\"date\":\"2024-01-02\",\"files\":[{\"hash\":\"abcd\",\"haswebp\":1,\"hasavif\":0}]};"
                return (Data(info.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            #expect(url.path == "/index-all.nozomi")
            let bounds = try #require(request.value(forHTTPHeaderField: "Range")).dropFirst(6).split(separator: "-").compactMap { Int($0) }
            let last = min(bounds[1], index.count - 1)
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                           headerFields: ["Content-Range": "bytes \(bounds[0])-\(last)/\(index.count)"])!
            return (index[bounds[0]...last], response)
        }, preference: { _ in nil })
        let first = try await runner.getSearchMangaList(query: nil, page: 1, filters: [])
        #expect(first.entries.map(\.key) == (1...25).map(String.init))
        #expect(first.hasNextPage)
        let second = try await runner.getSearchMangaList(query: nil, page: 2, filters: [])
        #expect(second.entries.map(\.key) == (26...30).map(String.init))
        #expect(!second.hasNextPage)
    }

    @Test func rangeSearchPreservesWholeIndexSizeLimit() async throws {
        let runner = HitomiSourceRunner(fetch: { request in
            #expect(request.value(forHTTPHeaderField: "Range") != nil)
            let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil,
                                           headerFields: ["Content-Range": "bytes 0-103/100000001"])!
            return (Data(repeating: 0, count: 104), response)
        }, preference: { _ in nil })
        await #expect(throws: HitomiSearch.Failure.resourceLimit) {
            _ = try await runner.getSearchMangaList(query: nil, page: 1, filters: [])
        }
    }

    @Test func binaryIndexRejectsTruncationAndOversizedCounts() throws {
        #expect(throws: HitomiSearch.Failure.self) { try HitomiSearch.decodeNode(Data([0, 0, 0, 17])) }
        #expect(throws: HitomiSearch.Failure.self) { try HitomiSearch.decodeNode(Data([0, 0, 0, 1, 0, 0, 0, 33])) }
        #expect(throws: HitomiSearch.Failure.self) { try HitomiSearch.decodeGalleryIDs(Data([255, 255, 255, 255])) }
        #expect(try HitomiSearch.decodeGalleryIDs(Data([0, 0, 0, 1, 255, 255, 255, 255])) == [4_294_967_295])
    }

    @Test func ggRoutingParsesDataWithoutExecutingJavaScriptOrEscapingPaths() throws {
        let state = try HitomiGGState.parse("var gg = { b: '12345/', m: function(g) { var o = 0; switch(g) { case 3516: o = 1; break; } return o; }};")
        #expect(state.imageURL(hash: "abcd", extension: "avif")?.absoluteString
                == "https://a2.gold-usergeneratedcontent.net/12345/3516/abcd.avif")
        #expect(state.imageURL(hash: "invalid/hash", extension: "avif") == nil)
        #expect(state.imageURL(hash: "abcd", extension: "../x") == nil)
        #expect(throws: HitomiGGState.Failure.self) { try HitomiGGState.parse("b: '../../evil/'") }
        #expect(HitomiSearch.nozomiURL(query: "artist:a/b?#", language: "all")?.absoluteString
                == "https://ltn.gold-usergeneratedcontent.net/artist/a%2Fb%3F%23-all.nozomi")
    }

    @Test func deepLinksRequireRealHitomiHost() {
        #expect(HitomiSourceRunner.galleryID("https://hitomi.la/reader/123.html") == 123)
        #expect(HitomiSourceRunner.galleryID("https://hitomi.la.evil.test/reader/123.html") == nil)
        #expect(HitomiSourceRunner.galleryID("https://evil.test/?hitomi.la/reader/123.html") == nil)
    }
}
