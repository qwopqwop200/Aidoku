import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct ReauditEHentaiTests {
    // Authentic v2 home.rs skips a section whose response cannot become HTML.
    // A valid HTTP status does not imply that a response is valid UTF-8 HTML.
    @Test func oneUndecodableHomeSectionPreservesOtherSectionsAndPartials() async throws {
        let runner = EHentaiSourceRunner(fetch: { request in
            let body: Data
            if request.url?.path == "/popular" {
                body = Data([0xFF])
            } else {
                body = Data("""
                    <table class="itg"><tr><td class="glname">
                    <a href="https://e-hentai.org/g/42/token/"><div class="glink">Gallery</div></a>
                    </td><td class="cn">Manga</td></tr></table>
                    """.utf8)
            }
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                                         httpVersion: "HTTP/1.1", headerFields: [:])!)
        }, preference: { _ in nil }, listPreference: { _ in [] }, setPreference: { _, _ in })
        let publisher = try #require(runner.partialHomePublisher)
        let recorder = HomeRecorder()
        let token = await publisher.sink { recorder.record($0) }
        let home = try await PartialResultSubscription.$id.withValue(token) { try await runner.getHome() }
        await publisher.removeSink(token: token)

        #expect(home.components.map(\.title) == ["Top Yesterday", "Top Month", "Top Year", "Popular", "Latest"])
        #expect(home.components.map(Self.entryCount) == [1, 1, 1, 0, 1])
        let snapshots = recorder.snapshots
        #expect(snapshots.count == 5) // skeleton plus four independently successful sections
        #expect(snapshots.first?.components.map(Self.entryCount) == [0, 0, 0, 0, 0])
        #expect(snapshots.last == home)
    }

    @Test func transportCancellationIsNotConvertedToAnEmptyHomeSection() async {
        let runner = EHentaiSourceRunner(fetch: { _ in throw CancellationError() },
                                        preference: { _ in nil }, listPreference: { _ in [] },
                                        setPreference: { _, _ in })
        await #expect(throws: CancellationError.self) { try await runner.getHome() }
    }

    private static func entryCount(_ component: HomeComponent) -> Int {
        switch component.value {
        case .bigScroller(let entries, _): entries.count
        case .scroller(let entries, _): entries.count
        case .mangaList(_, _, let entries, _): entries.count
        default: 0
        }
    }

    private final class HomeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Home] = []
        func record(_ home: Home) { lock.withLock { values.append(home) } }
        var snapshots: [Home] { lock.withLock { values } }
    }
}
