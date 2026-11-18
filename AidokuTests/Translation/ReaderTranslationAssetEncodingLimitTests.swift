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

    @Test func settledPNGReturnsBeforeEncodingAndSharesOneReplay() async throws {
        let fixture = EncodingLimitFixture()
        let pngGate = BlockingAssetEncoder()
        defer { pngGate.release(); fixture.close() }
        let context = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 36)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 2, y: 3, width: 14, height: 22))
        }
        let expectedBytes = try #require(frame.pngData())
        let asset = ReaderTranslationRenderAsset(typography: expectedBytes,
            layers: .init(masks: [], surfaces: [], paintBounds: []),
            displayRect: CGRect(origin: .zero, size: frame.size), sourceSize: frame.size, regions: [], sourceDigest: "source")
        #expect(fixture.cache.prepareSettledAssetAfterDisplay(key: "png", context: context, bitmapBytes: 32_768) {
            _ = pngGate.encode(asset)
            return asset
        })
        try await waitUntil { pngGate.started == 1 }
        #expect(!fixture.cache.prepareSettledAssetAfterDisplay(key: "second", context: context, bitmapBytes: 32_768) {
            Issue.record("A second decoded page was retained")
            return asset
        })
        let replay = Task { await fixture.cache.renderAsset(for: "png") }
        try await waitUntil { fixture.cache.pendingAssetReads == 1 }
        pngGate.release()
        let stored = try #require(await replay.value)
        #expect(stored.typography == expectedBytes)
        #expect(stored.regionsDigest == asset.regionsDigest)
        #expect(pngGate.started == 1)
        fixture.encoder.release()
        try await waitUntil { fixture.cache.pendingAssetWrites == 0 }
        fixture.cache.clearMemory()
        #expect(await fixture.cache.renderAsset(for: "png")?.typography == expectedBytes)
    }

    @Test(arguments: [false, true])
    func invalidatedSettledPNGDoesNotPublishOrFreeItsRasterEarly(clear: Bool) async throws {
        let fixture = EncodingLimitFixture()
        let pngGate = BlockingAssetEncoder()
        defer { pngGate.release(); fixture.close() }
        let asset = fixture.asset(0)
        let context = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        #expect(fixture.cache.prepareSettledAssetAfterDisplay(key: "old", context: context, bitmapBytes: 1024) {
            _ = pngGate.encode(asset)
            return asset
        })
        try await waitUntil { pngGate.started == 1 }
        if clear { fixture.cache.clearMemory() }
        else { await fixture.cache.removeRenderAsset(for: "old") }
        let next = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        #expect(!fixture.cache.prepareSettledAssetAfterDisplay(key: "new", context: next, bitmapBytes: 1024) { asset })
        pngGate.release()
        try await waitUntil { fixture.cache.activeAssetEncodings == 0 }
        #expect(await fixture.cache.renderAsset(for: "old") == nil)
        #expect(fixture.encoder.started == 0)
    }

    @Test func failedSettledPNGLeavesPreviousAssetAndFreesAdmission() async throws {
        let fixture = EncodingLimitFixture()
        defer { fixture.close() }
        fixture.encoder.release()
        let previous = fixture.asset(0)
        let generation = await fixture.disk.currentGeneration(settings: fixture.settings)
        await fixture.cache.storeRenderAsset(previous, key: "png", diskGeneration: generation)
        let context = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        #expect(fixture.cache.prepareSettledAssetAfterDisplay(key: "png", context: context, bitmapBytes: 1024) {
            throw ReaderTranslationImageExporter.ExportError.renderFailed
        })
        try await waitUntil { fixture.cache.pendingAssetWrites == 0 }
        #expect(await fixture.cache.renderAsset(for: "png")?.typography == previous.typography)
        #expect(fixture.cache.activeAssetEncodings == 0)
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
