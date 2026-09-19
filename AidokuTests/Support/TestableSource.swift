//
//  TestableSource.swift
//  Aidoku
//
//  Created by skitty on 8/21/26.
//

import AidokuRunner
import Foundation

extension AidokuRunner.Source {
    static func test(runner: TestableSourceRunner) -> AidokuRunner.Source {
        .init(
            url: nil,
            key: "test",
            name: "Test",
            version: 1,
            languages: ["multi"],
            contentRating: .safe,
            runner: runner
        )
    }
}

actor TestableSourceStorage {
    var nextDescriptor: Int32 = 0
    var processedContexts: [PageContext?] = []
    private var liveDescriptors = Set<Int32>()
    func liveCount() -> Int { liveDescriptors.count }
    func remove(_ value: Int32) { liveDescriptors.remove(value) }

    func getContexts() -> [PageContext?] {
        processedContexts
    }

    func process(_ context: PageContext?) {
        processedContexts.append(context)
    }

    func store() -> Int32 {
        nextDescriptor += 1
        liveDescriptors.insert(nextDescriptor)
        return nextDescriptor
    }
}

final class TestableSourceRunner: AidokuRunner.Runner {
    let features: AidokuRunner.SourceFeatures

    let storage = TestableSourceStorage()
    let failsProcessing: Bool
    init(failsProcessing: Bool = false, processesPages: Bool = true, processesCovers: Bool = false) {
        self.failsProcessing = failsProcessing
        features = .init(processesPages: processesPages, processesCovers: processesCovers)
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        manga
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        []
    }

    func processPageImage(response: Response, context: PageContext?) async throws -> PlatformImage? {
        await storage.process(context)
        if failsProcessing { throw CancellationError() }
        return nil
    }

    func processCoverImage(response: Response) async throws -> PlatformImage? {
        if failsProcessing { throw CancellationError() }
        return nil
    }

    func store<T: Sendable>(value _: T) async throws -> Int32 {
        await storage.store()
    }

    func remove(value: Int32) async throws {
        await storage.remove(value)
    }
}
