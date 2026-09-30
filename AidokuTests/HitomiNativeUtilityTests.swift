import CryptoKit
import Foundation
import Testing
@testable import Aidoku

struct HitomiNativeUtilityTests {
    private static let url = URL(string: "https://ltn.gold-usergeneratedcontent.net/index-all.nozomi")!

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: Self.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func nozomiDecodesUnsignedBigEndianAndIgnoresTrailingBytes() {
        #expect(HitomiSearch.decodeNozomi(Data([0, 0, 0, 1, 255, 255, 255, 255, 0])) == [1, 4_294_967_295])
    }

    @Test func namespacedQueriesAndLanguageSettingsMatchSource() {
        #expect(HitomiSearch.nozomiURL(query: "female:big_breasts", language: "korean")?.absoluteString
                == "https://ltn.gold-usergeneratedcontent.net/tag/female:big%20breasts-korean.nozomi")
        #expect(HitomiSearch.nozomiURL(query: " artist: some_name ", language: "all")?.absoluteString
                == "https://ltn.gold-usergeneratedcontent.net/artist/some%20name-all.nozomi")
        #expect(HitomiSearch.nozomiURL(query: "language:japanese", language: "all")?.lastPathComponent == "index-japanese.nozomi")
        #expect(HitomiSearch.nozomiURL(query: "unknown:test", language: "all") == nil)
        #expect(HitomiSearch.nozomiURL(query: "artist:a/b?#", language: "all")?.absoluteString
                == "https://ltn.gold-usergeneratedcontent.net/artist/a%2Fb%3F%23-all.nozomi")
        #expect(HitomiSearch.language(code: "ko") == "korean")
        #expect(HitomiSearch.language(code: "ceb") == "cebuano")
        #expect(HitomiSearch.language(code: "unsupported") == "all")
        #expect(HitomiSearch.language(code: nil) == "all")
    }

    @Test func rangeIgnoredByServerSlicesRequestedOffset() throws {
        let data = Data((0..<20).map(UInt8.init))
        let result = try HitomiSearch.extractRange(data, response: response(200), range: 8...11)
        #expect(result == Data([8, 9, 10, 11]))
        #expect(throws: HitomiSearch.Failure.self) {
            try HitomiSearch.extractRange(data, response: response(200), range: 16...23)
        }
        #expect(try HitomiSearch.extractRange(data, response: response(200), range: 16...23, allowEnd: true)
                == Data([16, 17, 18, 19]))
    }

    @Test func rangeRejectsMismatchedOffsetsAndUnprovenEOF() throws {
        let data = Data([0, 0, 0, 1])
        #expect(try HitomiSearch.extractRange(data, response: response(206, headers: ["Content-Range": "bytes 4-7/8"]),
                                            range: 4...11, allowEnd: true) == data)
        #expect(throws: HitomiSearch.Failure.self) {
            try HitomiSearch.extractRange(data, response: response(206, headers: ["Content-Range": "bytes 0-3/8"]), range: 4...7)
        }
        #expect(throws: HitomiSearch.Failure.self) {
            try HitomiSearch.extractRange(data, response: response(206), range: 4...7)
        }
        #expect(throws: HitomiSearch.Failure.self) {
            try HitomiSearch.extractRange(Data(), response: response(416, headers: ["Content-Range": "bytes */100"]),
                                         range: 4...7, allowEnd: true)
        }
        #expect(try HitomiSearch.extractRange(Data(), response: response(416, headers: ["Content-Range": "bytes */4"]),
                                            range: 4...7, allowEnd: true).isEmpty)
    }

    @Test func binaryIndexRejectsTruncationAndOversizedCounts() throws {
        #expect(throws: HitomiSearch.Failure.self) { try HitomiSearch.decodeNode(Data([0, 0, 0, 17])) }
        #expect(throws: HitomiSearch.Failure.self) { try HitomiSearch.decodeNode(Data([0, 0, 0, 1, 0, 0, 0, 33])) }
        #expect(throws: HitomiSearch.Failure.self) { try HitomiSearch.decodeGalleryIDs(Data([255, 255, 255, 255])) }
        #expect(throws: HitomiSearch.Failure.self) { try HitomiSearch.decodeGalleryIDs(Data([0, 0, 0, 1, 0])) }
        #expect(try HitomiSearch.decodeGalleryIDs(Data([0, 0, 0, 1, 255, 255, 255, 255])) == [4_294_967_295])
    }

    @Test func binarySearchUsesNormalizedHashAndCachesOnlyIndexNodes() async throws {
        let key = Array(SHA256.hash(data: Data("some term".utf8)).prefix(4))
        let node = Data([0, 0, 0, 1, 0, 0, 0, 4] + key
                        + [0, 0, 0, 1] + [UInt8](repeating: 0, count: 8) + [0, 0, 0, 8]
                        + [UInt8](repeating: 0, count: 17 * 8))
        let transport = Transport(node: node)
        let search = HitomiSearch(fetch: { try await transport.fetch($0) })
        #expect(try await search.plainText("SOME_TERM") == [123])
        #expect(try await search.plainText("some term") == [123])
        let counts = await transport.counts
        #expect(counts.version == 1)
        #expect(counts.node == 1)
        #expect(counts.data == 2) // Result bodies are intentionally not cached.
        await search.clearCache()
        #expect(try await search.plainText("some term") == [123])
        #expect(await transport.counts.version == 2)
    }

    @Test func pageRejectsZeroAndCancellationBeforeTransport() async {
        let search = HitomiSearch(fetch: { _ in throw URLError(.cannotConnectToHost) })
        await #expect(throws: HitomiSearch.Failure.self) { try await search.nozomiPage(url: Self.url, page: 0) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await search.allNozomi(url: Self.url)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func ggRoutingParsesDataWithoutExecutingJavaScript() throws {
        let state = try HitomiGGState.parse("var gg = { b: '12345/', m: function(g) { var o = 0; switch(g) { case 3516: o = 1; break; } return o; }};")
        #expect(HitomiGGState.imageID(hash: "abcd") == 0xdbc)
        #expect(state.imageURL(hash: "abcd", extension: "avif")?.absoluteString
                == "https://a2.gold-usergeneratedcontent.net/12345/3516/abcd.avif")
        #expect(state.imageURL(hash: "0123", extension: "webp")?.host == "a1.gold-usergeneratedcontent.net")
        #expect(state.imageURL(hash: "invalid/hash", extension: "avif") == nil)
        #expect(state.imageURL(hash: "abcd", extension: "../x") == nil)
        #expect(throws: HitomiGGState.Failure.self) { try HitomiGGState.parse("b: '../../evil/'") }
    }

    @Test func galleryPayloadAndMixedIDsDecodeWithoutScriptEvaluation() throws {
        let data = try HitomiGalleryRouting.galleryJSON("var galleryinfo = {\"id\":123};\n")
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
        #expect(try JSONDecoder().decode(HitomiGalleryID.self, from: Data("123".utf8)).value == "123")
        #expect(try JSONDecoder().decode(HitomiGalleryID.self, from: Data("\"123\"".utf8)).value == "123")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HitomiGalleryID.self, from: Data("-1".utf8)) }
        #expect(throws: HitomiGGState.Failure.self) { try HitomiGalleryRouting.galleryJSON("galleryinfo = {}; alert(1);") }
        #expect(HitomiGalleryRouting.galleryID(url: "https://hitomi.la/reader/123.html") == 123)
        #expect(HitomiGalleryRouting.galleryID(url: "https://hitomi.la/g/456/") == 456)
        #expect(HitomiGalleryRouting.galleryID(url: "https://hitomi.la/galleries/title-789.html") == 789)
        #expect(HitomiGalleryRouting.galleryID(url: "https://hitomi.la.evil/reader/123.html") == nil)
    }

    private actor Transport {
        let node: Data
        var counts = (version: 0, node: 0, data: 0)
        init(node: Data) { self.node = node }
        func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
            let url = request.url!
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://hitomi.la/")
            let data: Data
            let headers: [String: String]
            let status: Int
            if url.lastPathComponent == "version" {
                counts.version += 1; data = Data("1234\n".utf8); headers = [:]; status = 200
            } else if url.pathExtension == "index" {
                counts.node += 1; data = node; headers = ["Content-Range": "bytes 0-\(node.count - 1)/\(node.count)"]; status = 206
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-463")
            } else {
                counts.data += 1; data = Data([0, 0, 0, 1, 0, 0, 0, 123]); headers = ["Content-Range": "bytes 0-7/8"]; status = 206
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-7")
            }
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }
}
