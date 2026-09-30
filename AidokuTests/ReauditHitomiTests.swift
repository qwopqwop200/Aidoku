import AidokuRunner
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

struct ReauditHitomiTests {
    @Test(arguments: [false, true])
    func cacheClearDoesNotRememberAnAlreadyPendingGalleryResponse(restart: Bool) async throws {
        let fixture = PausedTransport(path: "/galleries/123.js")
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) })
        let manga = AidokuRunner.Manga(sourceKey: "multi.hitomi", key: "123", title: "Old")
        let pending = Task { try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: false) }
        await fixture.waitUntilPaused()
        if restart { try await runner.restart() } else { await runner.clearCache() }
        await fixture.resume()
        _ = try await pending.value
        _ = try await runner.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: false)
        #expect(await fixture.count("/galleries/123.js") == 2)
    }

    @Test func cacheClearDoesNotRememberAnAlreadyPendingIndexVersion() async throws {
        let fixture = PausedTransport(path: "/galleriesindex/version")
        let search = HitomiSearch(fetch: { try await fixture.fetch($0) })
        let pending = Task { try await search.plainText("term") }
        await fixture.waitUntilPaused()
        await search.clearCache()
        await fixture.resume()
        #expect(try await pending.value == [123])
        #expect(try await search.plainText("term") == [123])
        #expect(await fixture.count("/galleriesindex/version") == 2)
    }

    @Test(arguments: ["/galleriesindex/version", "/galleriesindex/galleries.1234.index"], [false, true])
    func sourceLifecycleInvalidatesPendingSearchCaches(path: String, restart: Bool) async throws {
        let fixture = PausedTransport(path: path)
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) }, preference: { _ in nil })
        let pending = Task { try await runner.getSearchMangaList(query: "term", page: 1, filters: []) }
        await fixture.waitUntilPaused()
        if restart { try await runner.restart() } else { await runner.clearCache() }
        await fixture.resume()
        #expect(try await pending.value.entries.map(\.key) == ["123"])
        #expect(try await runner.getSearchMangaList(query: "term", page: 1, filters: []).entries.map(\.key) == ["123"])
        #expect(await fixture.count("/galleriesindex/version") == 2)
        #expect(await fixture.count("/galleriesindex/galleries.1234.index") == 2)
    }

    @Test(arguments: [false, true])
    func cacheClearDoesNotRememberAnAlreadyPendingRoutingResponse(restart: Bool) async throws {
        let fixture = PausedTransport(path: "/gg.js")
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) })
        let manga = AidokuRunner.Manga(sourceKey: "multi.hitomi", key: "123", title: "Old")
        let chapter = AidokuRunner.Chapter(key: "123")
        let pending = Task { try await runner.getPageList(manga: manga, chapter: chapter) }
        await fixture.waitUntilPaused()
        if restart { try await runner.restart() } else { await runner.clearCache() }
        await fixture.resume()
        _ = try await pending.value
        _ = try await runner.getPageList(manga: manga, chapter: chapter)
        #expect(await fixture.count("/gg.js") == 2)
        #expect(await fixture.count("/galleries/123.js") == 2)
    }

    @Test func cacheClearDuringGalleryFetchDoesNotEraseTheActiveReadersRouting() async throws {
        let fixture = PausedTransport(path: "/galleries/456.js")
        let runner = HitomiSourceRunner(fetch: { try await fixture.fetch($0) })
        let manga = AidokuRunner.Manga(sourceKey: "multi.hitomi", key: "123", title: "Old")
        _ = try await runner.getPageList(manga: manga, chapter: .init(key: "123"))
        let pending = Task { try await runner.getPageList(manga: manga, chapter: .init(key: "456")) }
        await fixture.waitUntilPaused()
        await runner.clearCache()
        await fixture.resume()
        let pages = try await pending.value
        #expect(pages.count == 1)
    }

    private actor PausedTransport {
        private let path: String
        private var didPause = false
        private var pausedWaiter: CheckedContinuation<Void, Never>?
        private var resumeWaiter: CheckedContinuation<Void, Never>?
        private var counts: [String: Int] = [:]

        init(path: String) { self.path = path }

        func count(_ path: String) -> Int { counts[path, default: 0] }

        func waitUntilPaused() async {
            if didPause { return }
            await withCheckedContinuation { pausedWaiter = $0 }
        }

        func resume() {
            resumeWaiter?.resume()
            resumeWaiter = nil
        }

        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!
            counts[url.path, default: 0] += 1
            if url.path == path, !didPause {
                await withCheckedContinuation { continuation in
                    resumeWaiter = continuation
                    didPause = true
                    pausedWaiter?.resume()
                    pausedWaiter = nil
                }
            }
            let data: Data
            if url.path == "/galleriesindex/version" {
                data = Data("1234".utf8)
            } else if url.pathExtension == "index" {
                let key = Array(SHA256.hash(data: Data("term".utf8)).prefix(4))
                data = Data([0, 0, 0, 1, 0, 0, 0, 4] + key + [0, 0, 0, 1]
                            + [UInt8](repeating: 0, count: 8) + [0, 0, 0, 8]
                            + [UInt8](repeating: 0, count: 17 * 8))
            } else if url.pathExtension == "data" {
                data = Data([0, 0, 0, 1, 0, 0, 0, 123])
            } else if url.path == "/gg.js" {
                data = Data("var gg = { b: '12345/', m: function(g) { var o = 0; switch(g) { case 3516: o = 1; break; } return o; }};".utf8)
            } else {
                let id = url.deletingPathExtension().lastPathComponent
                data = Data("var galleryinfo = {\"id\":\"\(id)\",\"title\":\"Gallery \(id)\",\"galleryurl\":\"/g/\(id)/\",\"type\":\"manga\",\"date\":\"2024-01-02\",\"files\":[{\"hash\":\"abcd\"}]};".utf8)
            }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
