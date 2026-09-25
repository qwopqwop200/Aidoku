//
//  ReaderPagePrefetcher.swift
//  Aidoku
//
//  Created by Amqx on 8/26/26.
//

import AidokuRunner
import Foundation
import Nuke

/// Fetches page image data into the disk cache before a page view exists to display them.
@MainActor
final class ReaderPagePrefetcher {
    private let prefetcher = ImagePrefetcher(pipeline: .shared, destination: .diskCache)

    private var reservations = ReaderPagePrefetchReservations()
    /// Incremented on reset, to drop fetches that were being prepared at the time.
    private var generation = 0

    /// Fetch the first `count` pages of a chapter, skipping any that were already requested.
    func prefetch(pages: [Page], count: Int, chapterKey: String, sourceKey: String) async {
        guard !Task.isCancelled else { return }
        let reservation = reservations.reserve(
            count: min(max(0, count), pages.count), chapterKey: chapterKey, sourceKey: sourceKey
        )
        guard !reservation.indices.isEmpty else { return }
        // Reserve before suspension to avoid duplicates, but only retain pages
        // actually submitted. Cancellation must leave the remainder retryable.
        var submitted = Set<Int>()
        defer { reservations.finish(reservation, submitted: submitted) }

        let generation = generation
        let source = await SourceManager.shared.source(for: sourceKey)

        var requests: [ImageRequest] = []
        var requestIndices = Set<Int>()
        for index in reservation.indices {
            guard !Task.isCancelled, generation == self.generation else { return }
            let page = pages[index]
            guard
                page.image == nil,
                page.zipURL == nil,
                let imageURL = page.imageURL,
                let url = URL(string: imageURL),
                !url.isFileURL
            else {
                submitted.insert(index)
                continue
            }
            requests.append(await ReaderPageView.imageRequest(url: url, context: page.context, source: source))
            guard !Task.isCancelled, generation == self.generation else { return }
            requestIndices.insert(index)
            // Start early without increasing the prefetcher's concurrency or
            // decoding any images. Request modification can itself suspend.
            if requests.count == 2 {
                prefetcher.startPrefetching(with: requests)
                submitted.formUnion(requestIndices)
                requests.removeAll(keepingCapacity: true)
                requestIndices.removeAll(keepingCapacity: true)
            }
        }

        guard !Task.isCancelled, !requests.isEmpty, generation == self.generation else { return }
        prefetcher.startPrefetching(with: requests)
        submitted.formUnion(requestIndices)
    }

    /// Cancel outstanding fetches and forget what's been requested.
    func reset() {
        generation += 1
        prefetcher.stopPrefetching()
        reservations.reset()
    }
}

/// Tracks preparation leases separately from requests handed to Nuke. A reset
/// invalidates old leases so their eventual cancellation cannot release new work.
struct ReaderPagePrefetchReservations {
    struct Key: Hashable {
        let chapter: String
        let source: String
    }

    struct Reservation {
        let key: Key
        let generation: Int
        let indices: [Int]
    }

    private var generation = 0
    private var reserved: [Key: Set<Int>] = [:]

    mutating func reserve(count: Int, chapterKey: String, sourceKey: String) -> Reservation {
        let key = Key(chapter: chapterKey, source: sourceKey)
        let existing = reserved[key] ?? []
        let indices = (0..<max(0, count)).filter { !existing.contains($0) }
        reserved[key, default: []].formUnion(indices)
        return Reservation(key: key, generation: generation, indices: indices)
    }

    mutating func finish(_ reservation: Reservation, submitted: Set<Int>) {
        guard reservation.generation == generation else { return }
        reserved[reservation.key]?.subtract(Set(reservation.indices).subtracting(submitted))
    }

    mutating func reset() {
        generation += 1
        reserved.removeAll()
    }
}
