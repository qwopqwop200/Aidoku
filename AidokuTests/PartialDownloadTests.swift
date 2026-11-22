//
//  PartialDownloadTests.swift
//  Aidoku
//
//  Created by Pietro Baiguini on 8/20/26.
//

import AidokuRunner
@testable import Aidoku
import Foundation
import Testing

/// A download that stops with pages missing and one that is still running are both a staging
/// directory on disk, and only the failure marker tells them apart. These cover that distinction,
/// which is what a chapter being reported as downloaded while incomplete turned on.
@MainActor
struct PartialDownloadTests {
    @Test func reportsNoneWithoutAnyDirectory() {
        let chapter = identifier("none")
        defer { removeDirectories(for: chapter) }

        #expect(DownloadManager.shared.getDownloadStatus(for: chapter) == DownloadStatus.none)
    }

    @Test func reportsQueuedForUnmarkedStagingDirectory() {
        let cache = DownloadCache()
        let chapter = identifier("queued")
        defer { removeDirectories(for: chapter) }

        cache.tmpDirectory(for: chapter).createDirectory()

        #expect(DownloadManager.shared.getDownloadStatus(for: chapter) == .queued)
    }

    @Test func reportsFailedForMarkedStagingDirectory() throws {
        let cache = DownloadCache()
        let chapter = identifier("failed")
        defer { removeDirectories(for: chapter) }

        let tmpDirectory = cache.tmpDirectory(for: chapter)
        tmpDirectory.createDirectory()
        try Data("[3,7]".utf8).write(to: cache.failureMarker(inTmpDirectory: tmpDirectory))

        #expect(cache.hasFailureMarker(inTmpDirectory: tmpDirectory))
        #expect(DownloadManager.shared.getDownloadStatus(for: chapter) == .failed)
    }

    @Test func reportsFinishedForChapterDirectory() {
        let cache = DownloadCache()
        let chapter = identifier("finished")
        defer { removeDirectories(for: chapter) }

        cache.directory(for: chapter).createDirectory()

        #expect(DownloadManager.shared.getDownloadStatus(for: chapter) == .finished)
    }

    /// The batch lookup must agree with per-chapter lookups, including rejecting a sanitized alias.
    @Test func batchStatusesMatchSingleLookups() throws {
        let cache = DownloadCache()
        let owner = ChapterIdentifier(sourceKey: "test.partial-download", mangaKey: "batch", chapterKey: "part/one")
        let alias = ChapterIdentifier(sourceKey: "test.partial-download", mangaKey: "batch", chapterKey: "partone")
        let queued = ChapterIdentifier(sourceKey: "test.partial-download", mangaKey: "batch", chapterKey: "2")
        let missing = ChapterIdentifier(sourceKey: "test.partial-download", mangaKey: "batch", chapterKey: "3")
        defer { removeDirectories(for: owner) }

        let directory = cache.directory(for: owner)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = ComicInfo.load(
            manga: AidokuRunner.Manga(sourceKey: owner.sourceKey, key: owner.mangaKey, title: "Fixture"),
            chapter: AidokuRunner.Chapter(key: owner.chapterKey)
        )
        try Data(metadata.export().utf8).write(to: directory.appendingPathComponent("ComicInfo.xml"))
        cache.tmpDirectory(for: queued).createDirectory()

        let chapters = [owner, alias, queued, missing]
        let statuses = DownloadManager.shared.getDownloadStatuses(for: chapters)
        #expect(statuses == [owner: .finished, alias: .none, queued: .queued, missing: .none])
        for chapter in chapters {
            #expect(DownloadManager.shared.getDownloadStatus(for: chapter) == statuses[chapter])
        }
    }

    /// The marker lives inside the staging directory, so discarding a failed download stays a
    /// single removal and nothing is left beside it.
    @Test func markerLivesInsideTheStagingDirectory() {
        let cache = DownloadCache()
        let chapter = identifier("contained")
        defer { removeDirectories(for: chapter) }

        let tmpDirectory = cache.tmpDirectory(for: chapter)

        let marker = cache.failureMarker(inTmpDirectory: tmpDirectory)

        #expect(marker.deletingLastPathComponent().path == tmpDirectory.path)
    }
}

private extension PartialDownloadTests {
    // each test gets its own manga so that a leftover directory cannot affect another
    func identifier(_ name: String) -> ChapterIdentifier {
        .init(sourceKey: "test.partial-download", mangaKey: name, chapterKey: "1")
    }

    func removeDirectories(for chapter: ChapterIdentifier) {
        DownloadCache().directory(for: chapter.mangaIdentifier).removeItem()
    }
}
