import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeHitomiAuditTests {
    @Test func missingPlainTextDoesNotExpandIntoFollowingNamespaceResults() async throws {
        let fixture = Fixture(indexes: ["/artist/foo-all.nozomi": [123]])
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) }, preference: { _ in nil })
        // The recovered Rust returns "Search failed for term: missing" for an absent B-tree key.
        var failed = false
        do {
            _ = try await runner.getSearchMangaList(query: "missing artist:foo", page: 1, filters: [])
        } catch HitomiSearch.Failure.missingTerm {
            failed = true
        } catch {
            Issue.record("Unexpected search failure: \(error)")
        }
        #expect(failed)
    }

    @Test func authorUnionIntersectsSortedBaseTypeAndNegativeTerms() async throws {
        let fixture = Fixture(indexes: [
            "/popular/week-korean.nozomi": [6, 3, 5, 2, 4, 1],
            "/artist/some name-korean.nozomi": [1, 2, 3],
            "/group/some name-korean.nozomi": [3, 4, 5],
            "/tag/excluded-korean.nozomi": [3],
            "/type/manga-korean.nozomi": [1, 3, 4, 5]
        ])
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) }, preference: { $0 == "language" ? "ko" : nil })
        let result = try await runner.getSearchMangaList(query: "-tag:excluded", page: 1, filters: [
            .text(id: "author", value: "Some Name"),
            .sort(.init(id: "sort", index: 3, ascending: false)),
            .select(id: "type", value: "manga")
        ])
        #expect(result.entries.map(\.key) == ["5", "4", "1"])
        #expect(!result.hasNextPage)
    }

    @Test func authorAcceptsGroupWhenArtistEndpointFails() async throws {
        let fixture = Fixture(indexes: ["/group/some name-all.nozomi": [4, 2, 4]])
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) }, preference: { _ in nil })
        let result = try await runner.getSearchMangaList(query: nil, page: 1, filters: [.text(id: "author", value: "Some Name")])
        #expect(result.entries.map(\.key) == ["2", "4"])
    }

    @Test func cachedDetailsStillPropagateCancellation() async throws {
        let fixture = Fixture(indexes: [:])
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) })
        let manga = AidokuRunner.Manga(sourceKey: "multi.hitomi", key: "123", title: "Old")
        _ = try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cachedReaderStillPropagatesCancellationAndPreservesPageContext() async throws {
        let fixture = Fixture(indexes: [:])
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) })
        let manga = AidokuRunner.Manga(sourceKey: "multi.hitomi", key: "123", title: "Old")
        let chapter = AidokuRunner.Chapter(key: "123")
        let pages = try await runner.getPageList(manga: manga, chapter: chapter)
        guard let first = pages.first, case let .url(url, context) = first.content else {
            Issue.record("Missing URL page")
            return
        }
        #expect(url.absoluteString == "https://a2.gold-usergeneratedcontent.net/12345/3516/abcd.webp")
        #expect(context?["referer"] == "https://hitomi.la/reader/123.html")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.getPageList(manga: manga, chapter: chapter)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private actor Fixture {
        let indexes: [String: [UInt32]]
        init(indexes: [String: [UInt32]]) { self.indexes = indexes }

        func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
            let url = request.url!
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://hitomi.la/")
            let data: Data
            let status: Int
            if let ids = indexes[url.path] {
                data = Data(ids.flatMap { id in
                    [UInt8(truncatingIfNeeded: id >> 24), UInt8(truncatingIfNeeded: id >> 16),
                     UInt8(truncatingIfNeeded: id >> 8), UInt8(truncatingIfNeeded: id)]
                })
                status = 200
            } else if url.path == "/galleriesindex/version" {
                data = Data("1234".utf8)
                status = 200
            } else if url.pathExtension == "index" {
                // Empty leaf: zero keys, zero values, seventeen zero child addresses.
                data = Data(repeating: 0, count: 4 + 4 + 17 * 8)
                status = 200
            } else if url.path == "/gg.js" {
                data = Data("var gg = { b: '12345/', m: function(g) { var o = 0; switch(g) { case 3516: o = 1; break; } return o; }};".utf8)
                status = 200
            } else if url.path.hasPrefix("/galleries/") {
                let id = url.deletingPathExtension().lastPathComponent
                data = Data("var galleryinfo = {\"id\":\"\(id)\",\"title\":\"Gallery \(id)\",\"galleryurl\":\"/g/\(id)/\",\"type\":\"manga\",\"date\":\"2024-01-02\",\"files\":[{\"hash\":\"abcd\",\"haswebp\":1,\"hasavif\":0}]};".utf8)
                status = 200
            } else {
                data = Data()
                status = 404
            }
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}
