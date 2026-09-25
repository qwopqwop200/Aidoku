import Foundation
import Testing
import UIKit
@testable import Aidoku

@MainActor
struct ReaderRenderAssetReadSchedulingTests {
    @Test func duplicateReadSharesDecodeAndOneCancelledConsumerDoesNotCancelTheOther() async throws {
        let fixture = AssetReadFixture()
        defer { fixture.close() }
        let expected = try await fixture.store("shared")
        let first = Task { await fixture.cache.renderAsset(for: "shared", priority: .prefetch) }
        try await waitUntil { fixture.decoder.started == 1 }
        let second = Task { await fixture.cache.renderAsset(for: "shared") }
        // Allow the second consumer to join the shared read before cancelling its peer.
        for _ in 0..<10 { await Task.yield() }
        first.cancel()
        #expect(await first.value == nil)
        #expect(fixture.decoder.started == 1)
        #expect(fixture.cache.pendingAssetReads == 1)
        fixture.decoder.release()
        let result = try #require(await second.value)
        #expect(result.typography == expected.typography)
        #expect(result.sourceDigest == expected.sourceDigest)
        #expect(fixture.decoder.started == 1)
        #expect(fixture.cache.pendingAssetReads == 0)
    }

    @Test func clearCancelsConsumersButCannotFreeSlotsStillOwnedBySynchronousDecode() async throws {
        let fixture = AssetReadFixture()
        defer { fixture.close() }
        for key in ["a", "b", "c", "d", "replacement"] { _ = try await fixture.store(key) }
        let tasks = ["a", "b", "c", "d"].map { key in
            Task { await fixture.cache.renderAsset(for: key, priority: .prefetch) }
        }
        try await waitUntil { fixture.decoder.started == 2 && fixture.cache.pendingAssetReads == 4 }
        fixture.cache.clearMemory()
        for task in tasks { #expect(await task.value == nil) }
        let replacement = Task { await fixture.cache.renderAsset(for: "replacement") }
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.decoder.started == 2)
        fixture.decoder.release()
        #expect(await replacement.value != nil)
        #expect(fixture.decoder.maximumActive == 2)
        #expect(fixture.decoder.started == 3)
        #expect(fixture.cache.pendingAssetReads == 0)
    }

    @Test func queuedReadObservesLaterPromotionOfOriginalConsumerToken() async throws {
        let fixture = AssetReadFixture()
        defer { fixture.close() }
        for key in ["blocker-a", "blocker-b", "older-prefetch", "visible"] { _ = try await fixture.store(key) }
        let blockers = ["blocker-a", "blocker-b"].map { key in
            Task { await fixture.cache.renderAsset(for: key, priority: .prefetch) }
        }
        try await waitUntil { fixture.decoder.started == 2 }
        let earlier = Task { await fixture.cache.renderAsset(for: "older-prefetch", priority: .prefetch) }
        try await waitUntil { fixture.cache.pendingAssetReads == 3 }
        let promotion = TranslationRequestPromotion()
        let visible = Task { await fixture.cache.renderAsset(for: "visible", priority: .promotable(promotion)) }
        try await waitUntil { fixture.cache.pendingAssetReads == 4 }
        promotion.promote()
        fixture.decoder.releaseOne()
        try await waitUntil { fixture.decoder.started == 3 }
        #expect(fixture.decoder.startedKeys[2] == "visible")
        fixture.decoder.release()
        for blocker in blockers { #expect(await blocker.value != nil) }
        #expect(await earlier.value != nil)
        #expect(await visible.value != nil)
    }

    @Test func removingAssetCancelsSharedReadAndCannotRepopulateMemory() async throws {
        let fixture = AssetReadFixture()
        defer { fixture.close() }
        _ = try await fixture.store("removed")
        let read = Task { await fixture.cache.renderAsset(for: "removed") }
        try await waitUntil { fixture.decoder.started == 1 }
        await fixture.cache.removeRenderAsset(for: "removed")
        #expect(await read.value == nil)
        fixture.decoder.release()
        #expect(await fixture.cache.renderAsset(for: "removed") == nil)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AssetReadTimeout.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum AssetReadTimeout: Error { case expired }

@MainActor private final class AssetReadFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("asset-read-" + UUID().uuidString)
    let decoder = BlockingAssetDecoder()
    lazy var disk = ReaderTranslationDiskCache(directory: root)
    lazy var cache = ReaderTranslationRenderCache(disk: disk, decodeAsset: { [decoder] in decoder.decode($0) })

    func store(_ key: String) async throws -> ReaderTranslationRenderAsset {
        let asset = ReaderTranslationRenderAsset(typography: Data(repeating: 65, count: 512 * 1024),
            layers: .init(masks: [], surfaces: [], paintBounds: []),
            displayRect: CGRect(x: 0, y: 0, width: 16, height: 16), sourceSize: CGSize(width: 16, height: 16),
            regions: [], sourceDigest: key)
        try await disk.store(JSONEncoder().encode(asset), for: ReaderTranslationRenderCache.renderAssetStorageKey(key),
                             kind: .layout, generation: await disk.currentGeneration())
        return asset
    }

    func close() {
        decoder.release()
        cache.clearMemory()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class BlockingAssetDecoder: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var permits = 0
    private var keys: [String] = []
    private var starts = 0
    private var active = 0
    private var maximum = 0
    var startedKeys: [String] { condition.lock(); defer { condition.unlock() }; return keys }
    var started: Int { condition.lock(); defer { condition.unlock() }; return starts }
    var maximumActive: Int { condition.lock(); defer { condition.unlock() }; return maximum }

    func decode(_ data: Data) -> ReaderTranslationRenderAsset? {
        let asset = try? JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: data)
        condition.lock()
        keys.append(asset?.sourceDigest ?? "missing")
        starts += 1
        active += 1
        maximum = max(maximum, active)
        let deadline = Date().addingTimeInterval(10)
        while !released && permits == 0 && condition.wait(until: deadline) {}
        if !released && permits > 0 { permits -= 1 }
        condition.unlock()
        condition.lock()
        active -= 1
        condition.unlock()
        return asset
    }

    func releaseOne() {
        condition.lock()
        permits += 1
        condition.broadcast()
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
