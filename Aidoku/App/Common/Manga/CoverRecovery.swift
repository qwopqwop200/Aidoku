//
//  CoverRecovery.swift
//  Aidoku (iOS)
//
//  Created by neldra on 5/24/26.
//

import AidokuRunner
import Foundation
import Nuke

enum CoverRecovery {
    private static let staleStatusCodes: Set<Int> = [403, 404, 410]

    private static let coordinator = CoverRecoveryCoordinator()

    static func shouldRecover(from error: Error) -> Bool {
        guard
            let pipelineError = error as? ImagePipeline.Error,
            case let .dataLoadingFailed(loadingError) = pipelineError,
            let dataErr = loadingError as? DataLoader.Error,
            case let .statusCodeUnacceptable(code) = dataErr
        else { return false }
        return staleStatusCodes.contains(code)
    }

    static func recover(from error: Error, identifier: MangaIdentifier, failedURL: URL? = nil) async -> URL? {
        guard shouldRecover(from: error) else { return nil }
        return await coordinator.recover(identifier: identifier, failedURL: failedURL) {
            let stub = AidokuRunner.Manga(sourceKey: identifier.sourceKey, key: identifier.mangaKey, title: "")
            guard let cover = await MangaManager.shared.resetCover(manga: stub) else { return nil }
            return URL(string: cover)
        }
    }
}

/// Shares the recovery result, not just admission. One cancelled/reused cell
/// cannot discard a replacement that another visible consumer still needs.
actor CoverRecoveryCoordinator {
    private struct Key: Hashable { let identifier: MangaIdentifier; let failedURL: URL? }
    private struct Entry { let failedURL: URL?; let value: URL?; let expires: Date; let serial: UInt64 }
    private var pending: [Key: Task<URL?, Never>] = [:]
    private var completed: [MangaIdentifier: Entry] = [:]
    private var serial: UInt64 = 0
    private let capacity: Int
    private let now: @Sendable () -> Date

    init(capacity: Int = 128, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    func recover(identifier: MangaIdentifier, failedURL: URL?, operation: @escaping @Sendable () async -> URL?) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let key = Key(identifier: identifier, failedURL: failedURL)
        if let entry = completed[identifier], entry.expires > now() {
            // If the recovered URL itself failed, stop instead of creating a
            // cache-hit retry loop. Later demand can retry after the cooldown.
            if failedURL != nil, entry.value == failedURL { return nil }
            if entry.failedURL == failedURL { return entry.value }
        }
        if let task = pending[key] { return await task.value }
        let task = Task {
            let value = await operation()
            return value == failedURL ? nil : value
        }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        serial &+= 1
        completed[identifier] = Entry(failedURL: failedURL, value: value, expires: now().addingTimeInterval(value == nil ? 5 : 30), serial: serial)
        while completed.count > capacity, let oldest = completed.min(by: { $0.value.serial < $1.value.serial })?.key {
            completed.removeValue(forKey: oldest)
        }
        return value == failedURL ? nil : value
    }
}
