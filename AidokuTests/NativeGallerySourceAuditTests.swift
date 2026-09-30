import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeGallerySourceAuditTests {
    // multi.ehentai v2 uses QueryParameters/encode_uri_component. A literal '+'
    // must survive form-style query decoding instead of becoming a space.
    @Test func eHentaiSearchEscapesLiteralPlusInSearchAndArtistNames() async throws {
        let transport = SearchTransport()
        let runner = EHentaiSourceRunner(fetch: { try await transport.fetch($0) }, preference: { _ in nil })
        _ = try await runner.getSearchMangaList(query: "C++", page: 1, filters: [.text(id: "artist", value: "A+B")])
        let request = try #require(await transport.requests.first)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let encoded = try #require(components.percentEncodedQuery)
        #expect(encoded.contains("C%2B%2B"))
        #expect(encoded.contains("A%2BB"))
        let formDecoded = encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
        #expect(formDecoded.contains("f_search=C++ artist:\"A+B$\""))
    }

    private actor SearchTransport {
        var requests: [URLRequest] = []
        func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
            requests.append(request)
            return (Data("<html><body></body></html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                                         httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
    }
}
