import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderRenderAssetMutationTests {
    @Test func removingWhileDirectStoreEncodesDoesNotResurrectAsset() async throws {
        let fixture = AssetMutationFixture()
        defer { fixture.close() }
        let generation = await fixture.disk.currentGeneration()
        let writer = Task { await fixture.cache.storeRenderAsset(fixture.asset("old"), key: "page", diskGeneration: generation) }
        try await waitUntil { fixture.encoder.started }
        await fixture.cache.removeRenderAsset(for: "page")
        fixture.encoder.release()
        await writer.value
        #expect(await fixture.cache.renderAsset(for: "page") == nil)
        #expect(try await fixture.disk.data(for: ReaderTranslationRenderCache.renderAssetStorageKey("page"), kind: .layout) == nil)
    }

    @Test func newerDirectStoreWinsWhenOlderEncoderFinishesLast() async throws {
        let fixture = AssetMutationFixture()
        defer { fixture.close() }
        let generation = await fixture.disk.currentGeneration()
        let old = Task { await fixture.cache.storeRenderAsset(fixture.asset("old"), key: "page", diskGeneration: generation) }
        try await waitUntil { fixture.encoder.started }
        await fixture.cache.storeRenderAsset(fixture.asset("new"), key: "page", diskGeneration: generation)
        fixture.encoder.release()
        await old.value
        #expect(await fixture.cache.renderAsset(for: "page")?.sourceDigest == "new")
        let stored = try #require(try await fixture.disk.data(for: ReaderTranslationRenderCache.renderAssetStorageKey("page"), kind: .layout))
        #expect(try JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: stored).sourceDigest == "new")
    }

    @Test func oldDiskDecodeCannotReplaceNewlyStoredAsset() async throws {
        let fixture = AssetMutationFixture()
        defer { fixture.close() }
        let generation = await fixture.disk.currentGeneration()
        try await fixture.disk.store(JSONEncoder().encode(fixture.asset("old")),
            for: ReaderTranslationRenderCache.renderAssetStorageKey("page"), kind: .layout, generation: generation)
        let read = Task { await fixture.cache.renderAsset(for: "page") }
        try await waitUntil { fixture.decoder.started }
        await fixture.cache.storeRenderAsset(fixture.asset("new"), key: "page", diskGeneration: generation)
        fixture.decoder.release()
        // The superseded reader receives the replacement without re-rendering.
        #expect(await read.value?.sourceDigest == "new")
        #expect(await fixture.cache.renderAsset(for: "page")?.sourceDigest == "new")
    }

    @Test func queuedAfterDisplayCannotOvertakeNewerDirectStore() async throws {
        let fixture = AssetMutationFixture()
        defer { fixture.close() }
        let generation = await fixture.disk.currentGeneration()
        let context = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        // There is no suspension between scheduling the old background write and
        // issuing the direct replacement on MainActor.
        fixture.cache.storeRenderAssetAfterDisplay(fixture.asset("old"), key: "page", context: context)
        await fixture.cache.storeRenderAsset(fixture.asset("new"), key: "page", diskGeneration: generation)
        fixture.encoder.release()
        try await waitUntil { fixture.cache.pendingAssetWrites == 0 && fixture.cache.activeAssetEncodings == 0 }
        #expect(await fixture.cache.renderAsset(for: "page")?.sourceDigest == "new")
        let stored = try #require(try await fixture.disk.data(for: ReaderTranslationRenderCache.renderAssetStorageKey("page"), kind: .layout))
        #expect(try JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: stored).sourceDigest == "new")
    }

    @Test func laterAfterDisplaySupersedesBlockedDirectStore() async throws {
        let fixture = AssetMutationFixture()
        defer { fixture.close() }
        let generation = await fixture.disk.currentGeneration()
        let old = Task { await fixture.cache.storeRenderAsset(fixture.asset("old"), key: "page", diskGeneration: generation) }
        try await waitUntil { fixture.encoder.started }
        let context = fixture.cache.renderAssetStorageContext(settings: fixture.settings)
        fixture.cache.storeRenderAssetAfterDisplay(fixture.asset("new"), key: "page", context: context)
        try await waitUntil { fixture.cache.pendingAssetWrites == 0 }
        fixture.encoder.release()
        await old.value
        #expect(await fixture.cache.renderAsset(for: "page")?.sourceDigest == "new")
        let stored = try #require(try await fixture.disk.data(for: ReaderTranslationRenderCache.renderAssetStorageKey("page"), kind: .layout))
        #expect(try JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: stored).sourceDigest == "new")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw AssetMutationTimeout.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum AssetMutationTimeout: Error { case expired }

@MainActor private final class AssetMutationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("asset-mutation-" + UUID().uuidString)
    let suite = "asset-mutation-settings-" + UUID().uuidString
    lazy var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: suite)!)
    let encoder = AssetMutationBarrier()
    let decoder = AssetMutationBarrier()
    lazy var disk = ReaderTranslationDiskCache(directory: root)
    lazy var cache = ReaderTranslationRenderCache(disk: disk, encodeAsset: { [encoder] asset in
        if asset.sourceDigest == "old" { encoder.wait() }
        return try? JSONEncoder().encode(asset)
    }, decodeAsset: { [decoder] data in
        let asset = try? JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: data)
        if asset?.sourceDigest == "old" { decoder.wait() }
        return asset
    })

    func asset(_ digest: String) -> ReaderTranslationRenderAsset {
        .init(typography: Data(digest.utf8), layers: .init(masks: [], surfaces: [], paintBounds: []),
              displayRect: CGRect(x: 0, y: 0, width: 16, height: 16), sourceSize: CGSize(width: 16, height: 16),
              regions: [], sourceDigest: digest)
    }

    func close() {
        encoder.release()
        decoder.release()
        cache.clearMemory()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class AssetMutationBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return entered }

    func wait() {
        condition.lock()
        entered = true
        let deadline = Date().addingTimeInterval(8)
        while !released && condition.wait(until: deadline) {}
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
