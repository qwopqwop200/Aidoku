import Foundation
import Testing
@testable import AidokuRunner

struct SourceInvocationTests {
    private struct EchoRunner: Runner {
        let features = SourceFeatures()
        var onRequest: @Sendable () -> Void = {}

        func getSearchMangaList(query: String?, page: Int, filters: [FilterValue]) throws -> MangaPageResult {
            .init(entries: [], hasNextPage: false)
        }
        func getMangaUpdate(manga: Manga, needsDetails: Bool, needsChapters: Bool) throws -> Manga {
            onRequest()
            return manga
        }
        func getPageList(manga: Manga, chapter: Chapter) throws -> [Page] {
            onRequest()
            return [.init(content: .text(chapter.key))]
        }
    }

    private func source(languages: [String] = ["ja"], onRequest: @escaping @Sendable () -> Void = {}) -> Source {
        Source(key: "test.invocation", name: "Fixture", version: 1, languages: languages, contentRating: .safe,
               runner: EchoRunner(onRequest: onRequest))
    }

    @Test func fillingMissingLanguagesPreservesExplicitLanguagesAndInput() async throws {
        let input = Manga(sourceKey: "", key: "m", title: "M", chapters: [.init(key: "first"), .init(key: "second", language: "en")])
        let single = try await source().getMangaUpdate(manga: input, needsDetails: true, needsChapters: true)
        let multi = try await source(languages: ["en", "ja"]).getMangaUpdate(manga: input, needsDetails: true, needsChapters: true)
        #expect(single.chapters?.map(\.language) == ["ja", "en"])
        #expect(multi.chapters == input.chapters)
        #expect(input.chapters?.first?.language == nil)
    }

    private enum Request: CaseIterable, Sendable {
        case manga, pages

        func invoke(_ source: Source) async throws {
            let manga = Manga(sourceKey: "", key: "m", title: "M")
            switch self {
                case .manga: _ = try await source.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
                case .pages: _ = try await source.getPageList(manga: manga, chapter: .init(key: "c"))
            }
        }
    }

    @Test(arguments: Request.allCases)
    private func cancelledCallerDoesNotInvokeRunner(_ request: Request) async {
        let source = source { Issue.record("Runner executed after cancellation") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await request.invoke(source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: Request.allCases)
    private func cancelledInvocationDiscardsLateSuccess(_ request: Request) async {
        let source = source { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try await request.invoke(source) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
