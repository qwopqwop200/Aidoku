//
//  PageTracker.swift
//  Aidoku
//
//  Created by Skitty on 10/6/25.
//

import AidokuRunner
import Foundation

/// A tracker that automatically tracks chapter read progress, syncing remote and local history.
protocol PageTracker: Tracker {
    /// Sets the read progress of a chapter.
    func setProgress(trackId: String, chapterId: ChapterIdentifier, progress: ChapterReadProgress) async throws

    /// Gets the read progress of multiple chapters.
    ///
    /// - Returns: A dictionary mapping chapter keys to their read progress.
    func getProgress(trackId: String, chapters: [AidokuRunner.Chapter]) async throws -> [String: ChapterReadProgress]
}

struct ChapterReadProgress: Codable, Equatable {
    let completed: Bool
    let page: Int
    var date: Date?
}

struct PageTrackUpdate: Codable, Equatable {
    let trackerId: String
    let trackId: String
    let chapterId: ChapterIdentifier
    let progress: ChapterReadProgress
    var failCount: Int = 0
}


extension PageTrackUpdate {
    struct Key: Hashable {
        let tracker: String
        let track: String
        let chapter: ChapterIdentifier
    }
    var key: Key { Key(tracker: trackerId, track: trackId, chapter: chapterId) }

    static func reconcile(pending: [Self], sent: [Self], failed: [Self]) -> [Self] {
        let sentByKey = Dictionary(sent.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        let failedByKey = Dictionary(failed.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        return pending.compactMap { update in
            guard sentByKey[update.key] == update else { return update }
            return failedByKey[update.key]
        }
    }

    /// Preserve latest-arrival ordering while replacing duplicates in linear time.
    static func merging(pending: [Self], updates: [Self]) -> [Self] {
        var seen: Set<Key> = []
        return (pending + updates).reversed().filter { seen.insert($0.key).inserted }.reversed()
    }
}
