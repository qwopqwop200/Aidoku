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
    static func reconcile(pending: [Self], sent: [Self], failed: [Self]) -> [Self] {
        pending.compactMap { update in
            guard sent.contains(update) else { return update }
            return failed.first {
                $0.trackerId == update.trackerId && $0.trackId == update.trackId && $0.chapterId == update.chapterId
            }
        }
    }
}
