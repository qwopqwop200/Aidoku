import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderTranslationAssetEncodingLimitTests {
    @Test func completedAssetIsReusableWhileOptionalSerializationIsBlocked() async throws {
        let fixture = EncodingLimitFixture()
        defer { fixture.close() }
        let expected = fixture.asset(0)
        let context = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        fixture.cache.storeRenderAssetAfterDisplay(expected, key: "ready", context: context)
        try await waitUntil { fixture.encoder.started == 1 }
        #expect(fixture.cache.activeAssetEncodings == 1)
        #expect(fixture.cache.pendingAssetWrites == 1)
        #expect(try await fixture.disk.data(for: ReaderTranslationRenderCache.renderAssetStorageKey("ready"), kind: .layout) == nil)
        // Both foreground and speculative requests can replay the finished asset
        // even though its JSON encoder has not returned and no disk row exists.
        for priority in [TranslationRequestPriority.foreground, .prefetch] {
            let replay = try #require(await fixture.cache.renderAsset(for: "ready", priority: priority))
            #expect(replay.typography == expected.typography)
            #expect(replay.regionsDigest == expected.regionsDigest)
        }
        #expect(fixture.cache.pendingAssetReads == 0)
        #expect(fixture.cache.renderAssetBytes == expected.byteCost)
        #expect(fixture.cache.renderAssetBytes <= ReaderTranslationRenderCache.renderAssetByteLimit)
        fixture.cache.clearMemory()
        #expect(fixture.cache.renderAssetBytes == 0)
        #expect(await fixture.cache.renderAsset(for: "ready") == nil)
        fixture.encoder.release()
        try await waitUntil { fixture.cache.activeAssetEncodings == 0 }
        #expect(await fixture.cache.renderAsset(for: "ready") == nil)
    }

    @Test func sameKeyReplacementKeepsFourLiveEncodesAndPersistsLatest() async throws {
        let fixture = EncodingLimitFixture()
        defer { fixture.close() }
        let context = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        for index in 0..<4 {
            fixture.cache.storeRenderAssetAfterDisplay(fixture.asset(index), key: "same", context: context)
            try await waitUntil { fixture.encoder.started == index + 1 }
        }
        // All four cancelled encodes remain synchronously blocked inside the encoder.
        for index in 4..<24 {
            fixture.cache.storeRenderAssetAfterDisplay(fixture.asset(index), key: "same", context: context)
            await Task.yield()
        }
        try await waitUntil { fixture.cache.queuedAssetEncodings == 1 }
        #expect(fixture.encoder.started == 4)
        #expect(fixture.cache.activeAssetEncodings == 4)
        fixture.encoder.release()
        try await waitUntil { fixture.cache.activeAssetEncodings == 0 && fixture.encoder.started == 5 }
        let expected = fixture.asset(23)
        try await waitUntil {
            let data = try? await fixture.disk.data(for: ReaderTranslationRenderCache.renderAssetStorageKey("same"), kind: .layout)
            return data.flatMap { try? JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: $0) }?.typography == expected.typography
        }
        let stored = try #require(await fixture.cache.renderAsset(for: "same"))
        #expect(stored.typography == expected.typography)
        #expect(stored.regionsDigest == expected.regionsDigest)
        #expect(fixture.encoder.maximumActive == 4)
        #expect(fixture.cache.queuedAssetEncodings == 0)
    }

    @Test func clearCancelsWaitersWithoutReleasingStillRunningEncodes() async throws {
        let fixture = EncodingLimitFixture()
        defer { fixture.close() }
        let oldContext = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        for index in 0..<4 {
            fixture.cache.storeRenderAssetAfterDisplay(fixture.asset(index), key: "same", context: oldContext)
            try await waitUntil { fixture.encoder.started == index + 1 }
        }
        fixture.cache.storeRenderAssetAfterDisplay(fixture.asset(4), key: "same", context: oldContext)
        try await waitUntil { fixture.cache.queuedAssetEncodings == 1 }
        fixture.cache.clearMemory()
        try await waitUntil { fixture.cache.queuedAssetEncodings == 0 }
        #expect(fixture.cache.activeAssetEncodings == 4)
        let newContext = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        fixture.cache.storeRenderAssetAfterDisplay(fixture.asset(5), key: "new", context: newContext)
        try await waitUntil { fixture.cache.queuedAssetEncodings == 1 }
        #expect(fixture.encoder.started == 4)
        fixture.encoder.release()
        try await waitUntil { fixture.cache.activeAssetEncodings == 0 && fixture.encoder.started == 5 }
        try await waitUntil { await fixture.cache.renderAsset(for: "new") != nil }
        #expect(await fixture.cache.renderAsset(for: "same") == nil)
        #expect(fixture.encoder.maximumActive == 4)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for controlled asset encoder")
                throw EncodingLimitTimeout.expired
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum EncodingLimitTimeout: Error { case expired }

@MainActor private final class EncodingLimitFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("asset-encoding-" + UUID().uuidString)
    let suite = "asset-encoding-" + UUID().uuidString
    let encoder = BlockingAssetEncoder()
    lazy var disk = ReaderTranslationDiskCache(directory: root)
    lazy var cache = ReaderTranslationRenderCache(disk: disk, encodeAsset: { [encoder] in encoder.encode($0) })
    lazy var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: suite)!)

    func asset(_ index: Int) -> ReaderTranslationRenderAsset {
        ReaderTranslationRenderAsset(typography: Data("fixture-\(index)".utf8),
            layers: .init(masks: [], surfaces: [], paintBounds: []),
            displayRect: CGRect(x: 0, y: 0, width: 16, height: 16), sourceSize: CGSize(width: 16, height: 16),
            regions: [.init(id: "one", rect: CGRect(x: 0, y: 0, width: 1, height: 1), source: "original", translation: "translated")],
            sourceDigest: "source")
    }

    func close() {
        encoder.release()
        cache.clearMemory()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

// Blocks the actual synchronous encoding closure, so cancellation cannot pretend
// that its retained asset and temporary encoding buffers have already disappeared.
private final class BlockingAssetEncoder: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var starts = 0
    private var active = 0
    private var maximum = 0
    var started: Int { condition.lock(); defer { condition.unlock() }; return starts }
    var maximumActive: Int { condition.lock(); defer { condition.unlock() }; return maximum }

    func encode(_ asset: ReaderTranslationRenderAsset) -> Data? {
        condition.lock()
        starts += 1
        active += 1
        maximum = max(maximum, active)
        let deadline = Date().addingTimeInterval(10)
        while !released && condition.wait(until: deadline) {}
        condition.unlock()
        let data = try? JSONEncoder().encode(asset)
        condition.lock()
        active -= 1
        condition.unlock()
        return data
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
