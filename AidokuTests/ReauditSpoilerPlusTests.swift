import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct ReauditSpoilerPlusTests {
    @Test(arguments: [false, true])
    func invalidationDoesNotRepopulateCacheFromAnAlreadyPendingResponse(restart: Bool) async throws {
        let transport = PausedTransport()
        let source = SpoilerPlusSourceRunner(fetch: { await transport.fetch($0) })
        let manga = AidokuRunner.Manga(sourceKey: "ja.spoilerplus", key: "/first-raw-free/", title: "First")
        let pending = Task { try await source.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: false) }
        await transport.waitUntilPaused()
        if restart { try await source.restart() } else { await source.clearCache() }
        await transport.resume()
        let activeResult = try await pending.value
        #expect(activeResult.title == "First")
        _ = try await source.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: false)
        #expect(await transport.fetchCount() == 2)
    }

    @Test(arguments: ["123", "null", "[]", "{}"])
    func presentNonStringOrderKeyIsRejectedLikeAuthenticSerde(keyJSON: String) async throws {
        let source = apiSource(json: "{\"c\":\(keyJSON),\"e\":[\"/first.jpg\"]}")
        await #expect(throws: URLError.self) {
            try await source.getPageList(
                manga: .init(sourceKey: "ja.spoilerplus", key: "/test-raw-free/", title: "Test"),
                chapter: .init(key: "/test-raw-free/第420話/")
            )
        }
    }

    @Test func absentOrderKeyRetainsAuthenticSerdeDefault() async throws {
        let source = apiSource(json: "{\"e\":[\"/first.jpg\"]}")
        let pages = try await source.getPageList(
            manga: .init(sourceKey: "ja.spoilerplus", key: "/test-raw-free/", title: "Test"),
            chapter: .init(key: "/test-raw-free/第420話/")
        )
        #expect(pages.count == 1)
        if case let .url(_, context) = pages[0].content { #expect(context?["key"] == "") }
        else { Issue.record("Expected URL page") }
    }

    @Test func sharedLinkQueryAndFragmentDoNotBecomeChapterIdentity() async throws {
        let source = SpoilerPlusSourceRunner()
        // Intentional repair of an inherited upstream bug: share metadata must
        // not turn a series into a chapter or become a percent-encoded path suffix.
        for url in ["https://spoilerplus.tv/Test-raw-free?track=1#reader",
                    "https://spoilerplus.tv/Test-raw-free/?track=1#reader"] {
            let link = try #require(try await source.handleDeepLink(url: url))
            #expect(link.mangaKey == "/Test-raw-free/")
            #expect(link.chapterKey == nil)
        }
        let chapter = try #require(try await source.handleDeepLink(
            url: "https://spoilerplus.tv/Test-raw-free/%E7%AC%AC420%E8%A9%B1/?track=1#page-2"
        ))
        #expect(chapter.mangaKey == "/Test-raw-free/")
        #expect(chapter.chapterKey == "/Test-raw-free/第420話/")
        #expect(try await source.handleDeepLink(url: "https://spoilerplus.tv/ranking/?track=1") == nil)
        #expect(try await source.handleDeepLink(url: "https://spoilerplus.tv.evil.test/Test-raw-free/") == nil)
    }

    @Test func suspendedOldDetailsCannotPublishIntoReplacementSubscription() async throws {
        let transport = PausedTransport()
        let source = SpoilerPlusSourceRunner(fetch: { await transport.fetch($0) })
        let partialPublisher = await source.partialMangaPublisher
        let publisher = try #require(partialPublisher)
        let recorder = MangaRecorder()
        let firstToken = await publisher.sink { _ in }
        let old = Task {
            try await PartialResultSubscription.$id.withValue(firstToken) {
                try await source.getMangaUpdate(
                    manga: .init(sourceKey: "ja.spoilerplus", key: "/first-raw-free/", title: "First"),
                    needsDetails: true, needsChapters: true
                )
            }
        }
        await transport.waitUntilPaused()
        let secondToken = await publisher.sink { recorder.record($0) }
        _ = try await PartialResultSubscription.$id.withValue(secondToken) {
            try await source.getMangaUpdate(
                manga: .init(sourceKey: "ja.spoilerplus", key: "/second-raw-free/", title: "Second"),
                needsDetails: true, needsChapters: true
            )
        }
        await transport.resume()
        _ = try await old.value
        #expect(recorder.titles == ["Second"])
        await publisher.removeSink(token: secondToken)
    }

    @Test func cachedMangaStillPropagatesCancellation() async throws {
        let source = SpoilerPlusSourceRunner(fetch: { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("<h1 class='title-detail'>試験 Raw Free</h1>".utf8), response)
        })
        let manga = AidokuRunner.Manga(sourceKey: "ja.spoilerplus", key: "/test-raw-free/", title: "試験")
        _ = try await source.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func wpComicsDescriptionPreservesExplicitBreaksAndNormalizesOtherWhitespace() async throws {
        // The authentic WpComics text_with_newlines branch distinguishes <br> from
        // source formatting whitespace. Expected text is fixed independently of the port.
        let html = """
        <h1 class="title-detail">試験 Raw Free</h1>
        <div class="detail-content">
          <p>第一行<br>第二行 <strong>強調</strong><br><br>第四行 &amp; 続き</p>
          <p>次の段落
             続き</p>
        </div>
        """
        let source = SpoilerPlusSourceRunner(fetch: { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(html.utf8), response)
        })
        let manga = try await source.getMangaUpdate(
            manga: AidokuRunner.Manga(sourceKey: "ja.spoilerplus", key: "/test-raw-free/", title: "試験"),
            needsDetails: true, needsChapters: false
        )
        #expect(manga.description == "第一行\n第二行 強調\n\n第四行 & 続き\n次の段落 続き")
    }

    private func apiSource(json: String) -> SpoilerPlusSourceRunner {
        SpoilerPlusSourceRunner(fetch: { request in
            let body = request.httpMethod == "POST" ? json : "<script>window.MangaId = 20466; window.CNumber = 420;</script>"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
    }

    private final class MangaRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ manga: AidokuRunner.Manga) { lock.withLock { values.append(manga.title) } }
        var titles: [String] { lock.withLock { values } }
    }

    private actor PausedTransport {
        private var didPause = false
        private var requests = 0
        private var pausedWaiter: CheckedContinuation<Void, Never>?
        private var resumeWaiter: CheckedContinuation<Void, Never>?

        func fetchCount() -> Int { requests }

        func waitUntilPaused() async {
            if didPause { return }
            await withCheckedContinuation { pausedWaiter = $0 }
        }
        func resume() {
            resumeWaiter?.resume()
            resumeWaiter = nil
        }
        func fetch(_ request: URLRequest) async -> (Data, URLResponse) {
            requests += 1
            if !didPause {
                await withCheckedContinuation { continuation in
                    resumeWaiter = continuation
                    didPause = true
                    pausedWaiter?.resume()
                    pausedWaiter = nil
                }
            }
            let title = request.url!.path.contains("first-raw-free") ? "First" : "Second"
            return (Data("<h1 class='title-detail'>\(title) Raw Free</h1>".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
