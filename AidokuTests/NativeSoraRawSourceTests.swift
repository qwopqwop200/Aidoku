import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeSoraRawSourceTests {
    private func runner(_ body: String) -> SoraRawSourceRunner {
        SoraRawSourceRunner(fetch: { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }
    @Test func nextDataListingPreservesCoverAuthorsAndPagination() async throws {
        let html = #"<script id="__NEXT_DATA__">{"props":{"pageProps":{"data":{"results":[{"name":" Series ","slug":"series-1","author":"A, B","thumbnail":"https://example.test/cover","type":"incomplete","is_adult":"no"}],"pagination":{"current_page":1,"total_page":2}}}}}</script>"#
        let result = try await runner(html).getSearchMangaList(query: nil, page: 1, filters: [])
        #expect(result.hasNextPage)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].key == "series-1")
        #expect(result.entries[0].title == "Series")
        #expect(result.entries[0].authors == ["A", "B"])
        #expect(result.entries[0].viewer == .unknown)
        #expect(result.entries[0].contentRating == .safe)
    }
}
