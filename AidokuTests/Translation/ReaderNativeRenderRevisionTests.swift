import Foundation
import SQLite3
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor struct ReaderNativeRenderRevisionTests {
    private let page = "native-live-paint-cache-fixture"
    private let size = CGSize(width: 2, height: 2)
    private var regions: [ReaderTranslationRegion] {
        [.init(id: "one", rect: CGRect(x: 0, y: 0, width: 1, height: 1), source: "原文", translation: "번역")]
    }
    private func keys(_ settings: ReaderTranslationSettings, previousRevision: String) -> (old: String, current: String) {
        let crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        var historicalParts = [previousRevision]
        // V315 already included segmentation policy: isolate only the render revision delta.
        if previousRevision == "reader-render-v315-current-db-capability" {
            historicalParts.append(NativeSourceSegmentationExecution.policySHA256)
        }
        historicalParts += [ReaderTranslationCacheIdentity.translation(page: page, settings: settings),
            ReaderTranslationCacheIdentity.encoded(settings.overlay), ReaderTranslationCacheIdentity.encoded(size),
            ReaderTranslationCacheIdentity.encoded(size), String(Double(1)), String(true),
            ReaderTranslationCacheIdentity.encoded(crop), String(false),
            "balanced-columns-v15-visible-balloon-fit", "source-rotation-v7-native-balloon-fit",
            "cache-revision-fixture-font", ProcessInfo.processInfo.operatingSystemVersionString]
        let historical = ReaderTranslationCacheIdentity.encoded(historicalParts)
        return (historical, ReaderTranslationCacheIdentity.render(page: page, settings: settings, imageSize: size,
            viewport: size, scale: 1, aspectFit: true, crop: crop, dark: false, letteringFontKey: "cache-revision-fixture-font"))
    }
    private func settings() -> ReaderTranslationSettings {
        var result = ReaderTranslationSettings()
        result.includePageImage = false
        return result
    }
    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
    }
    private func plan() throws -> Data {
        try JSONEncoder().encode(NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: []))
    }
    private func asset(_ image: UIImage) throws -> ReaderTranslationRenderAsset {
        let digest: String = try #require(ReaderTranslationRenderAsset.digestSource(image))
        return .init(typography: try #require(image.pngData()), layers: .init(masks: [], surfaces: [], paintBounds: []),
            displayRect: CGRect(origin: .zero, size: size), sourceSize: size, regions: regions,
            sourceDigest: digest, typographySize: size)
    }

    @Test func retainedBalloonRevisionInvalidatesV299() {
        #expect(ReaderTranslationCacheIdentity.renderRevision == "reader-render-v316-unchanged-symbol-source-preservation")
        let pair = keys(settings(), previousRevision: "reader-render-v299-source-local-boundary-veto")
        #expect(pair.old != pair.current)
    }

    @Test func sourceBoundaryRevisionInvalidatesV298() {
        #expect(ReaderTranslationCacheIdentity.renderRevision == "reader-render-v316-unchanged-symbol-source-preservation")
        let pair = keys(settings(), previousRevision: "reader-render-v298-terminal-source-body-contract")
        #expect(pair.old != pair.current)
    }

    @Test func terminalBodySourceContractRevisionInvalidatesV297() {
        #expect(ReaderTranslationCacheIdentity.renderRevision == "reader-render-v316-unchanged-symbol-source-preservation")
        let pair = keys(settings(), previousRevision: "reader-render-v297-source-preserving-body-anchor-recovery")
        #expect(pair.old != pair.current)
    }

    @Test(arguments: ["reader-render-v154-native-composition", "reader-render-v155-native-final-paint",
                      "reader-render-v156-native-live-paint", "reader-render-v157-native-restoration-quality",
                      "reader-render-v158-native-typography-and-source-donors",
                      "reader-render-v254-native-dense-requested-font-recovery",
                      "reader-render-v255-native-owner-source-paint",
                      "reader-render-v274-capacity-bounded-joint-tail-refinement",
                      "reader-render-v275-balloon-exclusion-lexical-capacity-source-cream",
                      "reader-render-v276-source-spacing-neutral-counter-contrast",
                      "reader-render-v277-final-body-ink-separation",
                      "reader-render-v278-observed-chromatic-core",
                      "reader-render-v279-readable-page-edge-margin",
                      "reader-render-v280-source-container-expansion-bound",
                      "reader-render-v281-lobe-aware-contour-clearance",
                      "reader-render-v282-retained-font-balloon-reflow",
                      "reader-render-v283-observed-ink-selected-mask-fringe",
                      "reader-render-v284-anchor-aware-terminal-word-reflow",
                      "reader-render-v285-content-bound-terminal-raster",
                      "reader-render-v286-interior-whole-word-priority",
                      "reader-render-v287-bounded-interior-word-widths",
                      "reader-render-v288-page-edge-peer-clearance",
                      "reader-render-v290-source-aware-guard-and-page-incumbent",
                      "reader-render-v291-paragraph-alignment-and-retained-source-risk",
                      "reader-render-v292-bound-source-contour-without-fill-guard",
                      "reader-render-v293-terminal-source-pixel-interior",
                      "reader-render-v294-source-outer-rim-without-new-hole-occlusion",
                      "reader-render-v295-source-near-rim-repair-without-new-hole-occlusion",
                      "reader-render-v296-isolated-initial-body-target-fallback",
                      "reader-render-v297-source-preserving-body-anchor-recovery",
                      "reader-render-v298-terminal-source-body-contract",
                      "reader-render-v299-source-local-boundary-veto",
                      "reader-render-v300-retained-balloon-state",
                      "reader-render-v303-contour-word-plans",
                      "reader-render-v313-compact-visible-ink-row-spacing",
                      "reader-render-v314-owned-white-core-mandatory-guard",
                      "reader-render-v315-current-db-capability"])
    func completedPreviousRenderBitmapAssetAndPlanCannotSatisfyCurrentReaderKeys(previousRevision: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = self.settings(), keys = self.keys(settings, previousRevision: previousRevision), disk = ReaderTranslationDiskCache(directory: directory)
        try await disk.synchronizeSettings(settings)
        let generation = await disk.currentGeneration(), cache = ReaderTranslationRenderCache(disk: disk)
        let image = self.image(), asset = try self.asset(image), plan = try self.plan()
        let oldSnapshot = ReaderTranslationRenderCache.snapshotKey(renderKey: keys.old, regions: regions)
        let oldPlan = ReaderTranslationRenderCache.layoutKey(renderKey: keys.old, regions: regions)
        let oldLoaded = ReaderTranslationRenderCache.loadedImageKey(renderKey: keys.old, regionsDigest: asset.regionsDigest,
            sourceDigest: try #require(asset.sourceDigest), size: size)
        await cache.store(image, key: oldSnapshot, pageIdentity: page, diskGeneration: generation)
        await cache.storeLayout(plan, key: oldPlan, diskGeneration: generation)
        await cache.storeRenderAsset(asset, key: keys.old, diskGeneration: generation)
        cache.storeLoadedImage(image, key: oldLoaded, pageIdentity: page, context: cache.renderAssetStorageContext(settings: settings))
        // Historical entries are genuine usable native payloads. Only their
        // render namespace changes; neither translation nor asset schema changes.
        #expect(asset.isValid)
        #expect(cache.cachedImage(for: oldSnapshot) === image)
        #expect(cache.cachedImage(for: oldLoaded) === image)
        #expect(await cache.layoutData(for: oldPlan) == plan)
        #expect(await cache.renderAsset(for: keys.old) != nil)
        #expect(keys.old != keys.current)
        #expect(await cache.load(ReaderTranslationRenderCache.snapshotKey(renderKey: keys.current, regions: regions), pageIdentity: page) == nil)
        #expect(await cache.layoutData(for: ReaderTranslationRenderCache.layoutKey(renderKey: keys.current, regions: regions)) == nil)
        #expect(await cache.renderAsset(for: keys.current) == nil)
        #expect(cache.cachedImage(for: ReaderTranslationRenderCache.loadedImageKey(renderKey: keys.current,
            regionsDigest: asset.regionsDigest, sourceDigest: try #require(asset.sourceDigest), size: size)) == nil)
    }

    @Test(arguments: ["reader-render-v154-native-composition", "reader-render-v155-native-final-paint",
                      "reader-render-v156-native-live-paint", "reader-render-v157-native-restoration-quality",
                      "reader-render-v158-native-typography-and-source-donors",
                      "reader-render-v254-native-dense-requested-font-recovery",
                      "reader-render-v255-native-owner-source-paint",
                      "reader-render-v274-capacity-bounded-joint-tail-refinement",
                      "reader-render-v275-balloon-exclusion-lexical-capacity-source-cream",
                      "reader-render-v276-source-spacing-neutral-counter-contrast",
                      "reader-render-v277-final-body-ink-separation",
                      "reader-render-v278-observed-chromatic-core",
                      "reader-render-v279-readable-page-edge-margin",
                      "reader-render-v280-source-container-expansion-bound",
                      "reader-render-v281-lobe-aware-contour-clearance",
                      "reader-render-v282-retained-font-balloon-reflow",
                      "reader-render-v283-observed-ink-selected-mask-fringe",
                      "reader-render-v288-page-edge-peer-clearance",
                      "reader-render-v290-source-aware-guard-and-page-incumbent",
                      "reader-render-v291-paragraph-alignment-and-retained-source-risk",
                      "reader-render-v292-bound-source-contour-without-fill-guard",
                      "reader-render-v293-terminal-source-pixel-interior",
                      "reader-render-v294-source-outer-rim-without-new-hole-occlusion",
                      "reader-render-v295-source-near-rim-repair-without-new-hole-occlusion",
                      "reader-render-v296-isolated-initial-body-target-fallback",
                      "reader-render-v297-source-preserving-body-anchor-recovery",
                      "reader-render-v298-terminal-source-body-contract",
                      "reader-render-v299-source-local-boundary-veto",
                      "reader-render-v300-retained-balloon-state",
                      "reader-render-v303-contour-word-plans",
                      "reader-render-v313-compact-visible-ink-row-spacing",
                      "reader-render-v314-owned-white-core-mandatory-guard",
                      "reader-render-v315-current-db-capability"])
    func persistedPreviousRenderPolicyRetiresRenderBytesAndLateWritesWhilePreservingOCRTranslationAndMetadata(previousRevision: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = self.settings(), keys = self.keys(settings, previousRevision: previousRevision), disk = ReaderTranslationDiskCache(directory: directory)
        try await disk.synchronizeSettings(settings)
        let generation = await disk.currentGeneration()
        let oldPlan = ReaderTranslationRenderCache.layoutKey(renderKey: keys.old, regions: regions)
        let oldAsset = ReaderTranslationRenderCache.renderAssetStorageKey(keys.old)
        try await disk.store(try plan(), for: oldPlan, kind: .layout, generation: generation)
        try await disk.store(try JSONEncoder().encode(asset(image())), for: oldAsset, kind: .layout, generation: generation)
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation, .metadata] {
            try await disk.store(Data("durable".utf8), for: "preserved", kind: kind,
                generation: await disk.currentGeneration(kind: kind))
        }
        var historicalPolicyParts = [previousRevision]
        if previousRevision == "reader-render-v315-current-db-capability" {
            historicalPolicyParts.append(NativeSourceSegmentationExecution.policySHA256)
        }
        historicalPolicyParts.append(ReaderTranslationCacheIdentity.encoded(settings.overlay))
        let historicalPolicy = ReaderTranslationCacheIdentity.encoded(historicalPolicyParts)
        var handle: OpaquePointer?
        #expect(sqlite3_open(directory.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "UPDATE cache_policy SET value='\(historicalPolicy)' WHERE name='layout'", nil, nil, nil) == SQLITE_OK)
        let reopened = ReaderTranslationDiskCache(directory: directory)
        try await reopened.synchronizeSettings(settings)
        #expect(try await reopened.data(for: oldPlan, kind: .layout) == nil)
        #expect(try await reopened.data(for: oldAsset, kind: .layout) == nil)
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation, .metadata] {
            #expect(try await reopened.data(for: "preserved", kind: kind) == Data("durable".utf8))
        }
        #expect(await reopened.currentGeneration() != generation)
        try await reopened.store(try plan(), for: "late-old-plan", kind: .layout, generation: generation)
        #expect(try await reopened.data(for: "late-old-plan", kind: .layout) == nil)
        let currentGeneration = await reopened.currentGeneration()
        let currentPlan = try plan()
        try await reopened.store(currentPlan, for: "new-plan", kind: .layout, generation: currentGeneration)
        // Compare the actual bytes stored, not a second JSON serialization.
        #expect(try await reopened.data(for: "new-plan", kind: .layout) == currentPlan)
    }
    @Test func jointSourcePageEdgeRevisionInvalidatesV300() {
        #expect(ReaderTranslationCacheIdentity.renderRevision == "reader-render-v316-unchanged-symbol-source-preservation")
        let pair = keys(settings(), previousRevision: "reader-render-v300-retained-balloon-state")
        #expect(pair.old != pair.current)
    }

    @Test func ownedWhiteCoreGuardRevisionInvalidatesV313() {
        #expect(ReaderTranslationCacheIdentity.renderRevision == "reader-render-v316-unchanged-symbol-source-preservation")
        let pair = keys(settings(), previousRevision: "reader-render-v313-compact-visible-ink-row-spacing")
        #expect(pair.old != pair.current)
    }

    @Test func unchangedSymbolSourcePreservationRevisionInvalidatesV315LayoutAndSnapshots() {
        #expect(ReaderTranslationCacheIdentity.renderRevision == "reader-render-v316-unchanged-symbol-source-preservation")
        let pair = keys(settings(), previousRevision: "reader-render-v315-current-db-capability")
        #expect(pair.old != pair.current)
        #expect(ReaderTranslationRenderCache.layoutKey(renderKey: pair.old, regions: regions) !=
            ReaderTranslationRenderCache.layoutKey(renderKey: pair.current, regions: regions))
        #expect(ReaderTranslationRenderCache.snapshotKey(renderKey: pair.old, regions: regions) !=
            ReaderTranslationRenderCache.snapshotKey(renderKey: pair.current, regions: regions))
        #expect(ReaderTranslationRenderCache.renderAssetStorageKey(pair.old) !=
            ReaderTranslationRenderCache.renderAssetStorageKey(pair.current))
    }

    @Test func currentDBCapabilityRevisionInvalidatesV314() {
        #expect(ReaderTranslationCacheIdentity.renderRevision == "reader-render-v316-unchanged-symbol-source-preservation")
        let pair = keys(settings(), previousRevision: "reader-render-v314-owned-white-core-mandatory-guard")
        #expect(pair.old != pair.current)
    }

}
