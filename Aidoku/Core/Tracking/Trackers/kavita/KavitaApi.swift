//
//  KomgaApi.swift
//  Aidoku
//
//  Created by Skitty on 10/23/25.
//

import Foundation

actor KavitaApi {
    func getState(sourceKey: String, seriesId: String) async throws -> TrackState? {
        let helper = KavitaHelper(sourceKey: sourceKey)
        let volumes: [KavitaVolume] = try await helper.request(path: "api/Series/volumes?seriesId=\(seriesId)")

        var totalVolumes = 0
        var totalChapters = 0

        for volume in volumes {
            if volume.number > 0 && volume.number < 100000 {
                totalVolumes = max(totalVolumes, volume.number)
            }
            let chapterMax = volume.chapters
                .compactMap { chapter -> Int? in
                    guard let number = Float(chapter.number) else { return nil }
                    if number > 0 && number < 100000 {
                        return Int(floor(number))
                    } else {
                        return nil
                    }
                }
                .max()
            if let chapterMax {
                totalChapters = max(totalChapters, chapterMax)
            }
        }

        let latestChapter: KavitaVolume.Chapter? = try? await helper.request(path: "api/Tachiyomi/latest-chapter?seriesId=\(seriesId)")

        return .init(
            progressUnit: .chapters,
            lastReadChapter: latestChapter.flatMap { chapter -> Float? in
                guard let number = Float(chapter.number) else { return nil }
                if number > 0 && number < 100000 {
                    return number
                } else {
                    return nil
                }
            },
            totalChapters: totalChapters,
            totalVolumes: totalVolumes
        )
    }

    func update(sourceKey: String, seriesId: String, update: TrackUpdate) async throws {
        guard let lastReadChapter = update.lastReadChapter else { return }

        let helper = KavitaHelper(sourceKey: sourceKey)

        let _: Bool = try await helper.request(
            path: "api/Tachiyomi/mark-chapter-until-as-read?seriesId=\(seriesId)&chapterNumber=\(lastReadChapter)",
            method: .POST,
            body: Data("{}".utf8)
        )
    }

    func updateReadProgress(
        sourceKey: String,
        seriesId: Int,
        chapterId: Int,
        progress: ChapterReadProgress
    ) async throws {
        let helper = KavitaHelper(sourceKey: sourceKey)

        struct Response: Decodable {
            let libraryId: Int
            let volumeId: Int
            let pages: Int
        }
        let response: Response = try await helper.request(path: "api/reader/chapter-info?chapterId=\(chapterId)")

        let pageNum = if progress.completed {
            response.pages
        } else {
            // The wire format is zero-based; reject an unrepresentable subtraction.
            try Self.zeroBasedPage(progress.page)
        }

        struct Payload: Encodable {
            let libraryId: Int
            let seriesId: Int
            let volumeId: Int
            let chapterId: Int
            let pageNum: Int
        }
        let payload = Payload(
            libraryId: response.libraryId,
            seriesId: seriesId,
            volumeId: response.volumeId,
            chapterId: chapterId,
            pageNum: pageNum
        )

        // Accept an empty successful response, but propagate transport and HTTP failures for retry.
        let _: KavitaEmptyResponse = try await helper.request(
            path: "api/reader/progress",
            method: .POST,
            body: JSONEncoder().encode(payload)
        )
    }

    func getSeriesReadProgress(sourceKey: String, seriesId: String) async throws -> [String: ChapterReadProgress] {
        let helper = KavitaHelper(sourceKey: sourceKey)
        let volumes: [KavitaVolume] = try await helper.request(path: "api/Series/volumes?seriesId=\(seriesId)")

        var progressMap: [String: ChapterReadProgress] = [:]

        for volume in volumes {
            for chapter in volume.chapters {
                let completed = chapter.pagesRead == chapter.pages
                let page = chapter.pagesRead
                if page == 0 && !completed {
                    continue // no progress, skip
                }
                let nextPage = chapter.pagesRead.addingReportingOverflow(1)
                guard !nextPage.overflow else { continue }
                progressMap["\(chapter.id)"] = .init(
                    completed: completed,
                    page: nextPage.partialValue,
                    date: chapter.lastReadingProgressUtc
                )
            }
        }

        return progressMap
    }

    static func zeroBasedPage(_ page: Int) throws -> Int {
        let result = page.subtractingReportingOverflow(1)
        guard !result.overflow else { throw URLError(.cannotParseResponse) }
        return result.partialValue
    }
}
