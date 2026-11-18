import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationPreparedOCRCacheTests {
    private let imageBudget = TranslationImageWorkBudget(availableMemory: { .max })

    @Test func boundWorkerDoesNotAdoptLocatorOnlyTranslationAndPersistsActualClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let page = Page(sourceId: "bound-worker", chapterId: "chapter", index: 0)
        let value = settings()
        let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: value)
        let stale = [regions[0]], fresh = [regions[1]]
        let proof = Self.fixtureProof
        try await disk.storeRegions(stale, for: key, kind: .translation,
                                    generation: await disk.currentGeneration(settings: value))
        let session = ReaderTranslationSession(processRecord: { _, _, _ in
            .init(regions: fresh, sourceRasterClaim: proof)
        }, diskCache: disk, availableMemory: { .max })
        defer { session.close() }
        session.update(items: [.init(page)], visible: [], context: "chapter")
        session.enable(settings: value)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let record = try await disk.regionRecord(for: key, kind: .translation, matching: proof) {
                #expect(record.regions == fresh)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The active worker did not persist its source-attested result")
    }

    @Test(arguments: [false, true])
    func foregroundDiskReplayPreservesLaterReplacementOrEviction(evicts: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = ReaderTranslationDiskCache(directory: root)
        let writer = ReaderTranslationDiskCache(directory: root)
        var value = settings()
        value.rightToLeftPanelOrder = false
        let pages = (0..<2).map { Page(sourceId: "disk-replay", chapterId: "chapter", index: $0) }
        let keys = pages.map { ReaderTranslationCacheIdentity.translation(page: $0.translationCacheKey, settings: value) }
        let proof = Self.fixtureProof
        var original = regions[0]
        original.translation = "기존 번역"
        var replacement = original
        replacement.translation = "새 번역"
        let nextPage = regions[1]
        let generation = await writer.currentGeneration(settings: value)
        try await writer.storeRegions([original], for: keys[0], kind: .translation, generation: generation, sourceRasterClaim: proof)
        let preloader = ReaderTranslationPreloader(diskCache: reader, translator: { records, _, _ in records },
            recognizer: { page, _ in
                #expect(page.index == 1)
                return [nextPage]
            }, availableMemory: { .max }, imagePreparationGate: imageBudget, fixtureSourceRasterClaim: { _ in proof })
        defer { preloader.cancel() }
        let session = ReaderTranslationSession(processRecord: { page, settings, progress in
            let record = try await preloader.translateRecord(page, settings: settings, onProgress: progress)
            if page.index == 0 {
                try #require(record.regions == [original])
                // Change the same source after its authenticated read and before the session receives it.
                if evicts {
                    try await writer.remove(keys[0], kind: .translation)
                } else {
                    try await writer.storeRegions([replacement], for: keys[0], kind: .translation,
                                                  generation: generation, sourceRasterClaim: proof)
                }
            }
            return record
        }, diskCache: reader, availableMemory: { .max })
        defer { session.close() }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "chapter")
        session.enable(settings: value)
        // The subsequent new page must cross the real persistence path.
        let deadline = Date().addingTimeInterval(5)
        while try await !writer.contains(keys[1], kind: .translation) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        await session.flushPendingDiskStores()
        let surviving = try await writer.regionRecord(for: keys[0], kind: .translation, matching: proof)
        #expect(surviving?.regions == (evicts ? nil : [replacement]))
        let fresh = try #require(try await writer.regionRecord(for: keys[1], kind: .translation, matching: proof))
        #expect(fresh.regions.first?.id == nextPage.id)
    }

    @Test func preparedCacheStartsTranslationWhileAnotherPageOCRIsBlocked() async throws {
        let settings = settings()
        let prepared = ReaderTranslationImagePreparation.apply(regions, image: image(), settings: settings)
        let proof = Self.fixtureProof
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let page = Page(sourceId: "ready-cache", chapterId: "chapter", index: 0)
        try await disk.storeRegions(prepared,
            for: ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings), kind: .ocr,
            generation: await disk.currentGeneration(settings: settings), sourceRasterClaim: proof)
        let gate = PreparedOCRGate()
        let busy = ReaderTranslationPreloader(translator: { regions, _, _ in regions }, recognizer: { _, _ in
            await gate.wait()
            return []
        }, imagePreparationGate: imageBudget)
        let blocker = Task { try await busy.translate(Page(sourceId: "blocked", chapterId: "chapter", index: 0), settings: settings) }
        defer { busy.cancel(); blocker.cancel(); Task { await gate.release() } }
        let startDeadline = Date().addingTimeInterval(5)
        while !(await gate.started) {
            guard Date() < startDeadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        let ready = ReaderTranslationPreloader(diskCache: disk, translator: { regions, _, _ in regions }, recognizer: { _, _ in
            Issue.record("A prepared cache hit must not recognize again")
            return []
        }, imagePreparationGate: imageBudget, fixtureSourceRasterClaim: { _ in proof })
        var finished = false
        let demand = Task {
            let result = try await ready.translate(page, settings: settings)
            finished = true
            return result
        }
        defer { ready.cancel(); demand.cancel() }
        let deadline = Date().addingTimeInterval(1)
        while !finished, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let finishedBeforeOCRRelease = finished
        await gate.release()
        #expect(try await demand.value == prepared)
        _ = try await blocker.value
        #expect(finishedBeforeOCRRelease, "Image-free cached text must not wait for another page's OCR permit")
    }

    @Test func diskReopenReusesVersionedReadingOrderWithObservedSourceProof() async throws {
        let settings = settings()
        let prepared = ReaderTranslationImagePreparation.apply(regions, image: image(), settings: settings)
        let proof = Self.fixtureProof
        #expect(!ReaderTranslationImagePreparation.needsImage(prepared, settings: settings))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = Page(sourceId: "prepared-cache", chapterId: "chapter", index: 0,
                        imageURL: root.appendingPathComponent("does-not-exist.png").absoluteString)
        let disk = ReaderTranslationDiskCache(directory: root)
        let key = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings)
        try await disk.storeRegions(prepared, for: key, kind: .ocr, generation: await disk.currentGeneration(settings: settings),
                                    sourceRasterClaim: proof)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.regions(for: key, kind: .ocr) == prepared)
        let preloader = ReaderTranslationPreloader(diskCache: reopened,
            translator: { regions, _, _ in regions }, recognizer: { _, _ in
                Issue.record("Cached OCR must not run again")
                return []
            }, fixtureSourceRasterClaim: { _ in proof })
        defer { preloader.cancel() }
        #expect(try await preloader.translate(page, settings: settings) == prepared)
        let restored = try #require(try await reopened.regions(for: key, kind: .ocr))
        #expect(ReaderTranslationService.plans(regions: prepared, settings: settings).map(\.request) ==
                ReaderTranslationService.plans(regions: restored, settings: settings).map(\.request))
    }

    @Test func legacyRegionsRemainReadableAndRequireOneImagePreparation() throws {
        let settings = settings()
        let prepared = ReaderTranslationImagePreparation.apply(regions, image: image(), settings: settings)
        let bytes = try JSONEncoder().encode(prepared.map(ReaderTranslationStoredRegion.init))
        var records = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        for index in records.indices {
            records[index].removeValue(forKey: "translationOrder")
            records[index].removeValue(forKey: "translationOrderVersion")
        }
        let restored = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
            from: JSONSerialization.data(withJSONObject: records)).map(\.region)
        #expect(restored.map(\.source) == prepared.map(\.source))
        #expect(ReaderTranslationImagePreparation.needsImage(restored, settings: settings))
        let refreshed = ReaderTranslationImagePreparation.apply(restored, image: image(), settings: settings)
        #expect(refreshed == prepared)
        #expect(!ReaderTranslationImagePreparation.needsImage(refreshed, settings: settings))
    }

    @Test(arguments: [false, true])
    func sameURLRequiresMatchingProcessedSourceProof(unclaimed: Bool) async throws {
        var settings = settings()
        settings.rightToLeftPanelOrder = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let sourceA = image(color: .white), sourceB = image(color: .black)
        let proofA = try #require(await Task.detached { ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: sourceA) }.value)
        let proofB = try #require(await Task.detached { ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: sourceB) }.value)
        #expect(proofA != proofB && sourceA.size == sourceB.size)
        let address = "https://example.invalid/same-page"
        let page = Page(sourceId: "source-claim", chapterId: "chapter", index: 0, imageURL: address)
        let key = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings)
        let generation = await disk.currentGeneration(settings: settings)
        let old = Array(regions.prefix(1)), fresh = Array(regions.suffix(1))
        try await disk.storeRegions(old, for: key, kind: .ocr, generation: generation,
                                    sourceRasterClaim: unclaimed ? nil : proofA)
        let probe = PreparedOCRInvocationCounter()
        let changed = ReaderTranslationPreloader(diskCache: disk, translator: { records, _, _ in records },
            recognizer: { _, _ in await probe.record(); return fresh },
            imagePreparationGate: imageBudget, fixtureSourceRasterClaim: { _ in proofB })
        #expect(try await changed.translate(page, settings: settings) == fresh)
        #expect(await probe.count == 1)
        changed.cancel()
        let translatedKey = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
        try await disk.remove(translatedKey, kind: .translation)
        #expect(try await disk.translatedRegions(page: page.translationCacheKey, settings: settings) == nil)
        let record = try #require(try await disk.regionRecord(for: key, kind: .ocr, matching: proofB))
        #expect(record.regions == fresh)
        let matched = ReaderTranslationPreloader(diskCache: disk, translator: { records, _, _ in records },
            recognizer: { _, _ in await probe.record(); return [] },
            imagePreparationGate: imageBudget, fixtureSourceRasterClaim: { _ in proofB })
        defer { matched.cancel() }
        #expect(try await matched.translate(page, settings: settings) == fresh)
        #expect(await probe.count == 1)
    }

    @Test func splitPresentationCannotUseFullPageOCRKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let full = Page(sourceId: "split-cache", chapterId: "chapter", index: 0)
        var half = full
        half.translationOriginalKey = full.translationCacheKey
        half.translationSourceRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let value = settings()
        let key = ReaderTranslationCacheIdentity.ocr(page: full.translationCacheKey, settings: value)
        let prepared = ReaderTranslationImagePreparation.apply(regions, image: image(), settings: value)
        let proof = Self.fixtureProof
        try await disk.storeRegions(prepared, for: key, kind: .ocr,
                                    generation: await disk.currentGeneration(settings: value), sourceRasterClaim: proof)
        let preloader = ReaderTranslationPreloader(diskCache: disk, translator: { regions, _, _ in regions },
            recognizer: { _, _ in Issue.record("Unexpected recognition"); return [] },
            fixtureSourceRasterClaim: { _ in proof })
        defer { preloader.cancel() }
        await #expect(throws: RemoteTranslationError.self) { try await preloader.translate(half, settings: value) }
        #expect(try await preloader.translate(full, settings: value) == prepared)
    }

    private nonisolated static let fixtureProof =
        ReaderTranslationSourceRasterClaim(processedFullSourceSHA256: String(repeating: "a", count: 64))!

    @Test func authenticatedTranslationDoesNotReadTheOCRArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let value = settings()
        let page = Page(sourceId: "translation-first", chapterId: "chapter", index: 0)
        let translationKey = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: value)
        let ocrKey = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: value)
        let generation = await disk.currentGeneration(settings: value)
        var region = regions[0]
        region.translation = "번역"
        try await disk.storeRegions([region], for: translationKey, kind: .translation, generation: generation,
                                    sourceRasterClaim: Self.fixtureProof)
        // A read evicts this malformed row, making an unnecessary OCR decode observable.
        try await disk.store(Data([0xFF]), for: ocrKey, kind: .ocr, generation: generation)
        let worker = ReaderTranslationPreloader(diskCache: disk, translator: { _, _, _ in throw URLError(.badServerResponse) },
            recognizer: { _, _ in throw URLError(.cannotDecodeContentData) }, imagePreparationGate: imageBudget,
            fixtureSourceRasterClaim: { _ in Self.fixtureProof })
        defer { worker.cancel() }
        for _ in 0..<2 {
            let record = try await worker.translateRecord(page, settings: value)
            #expect(record.regions == [region] && record.sourceRasterClaim == Self.fixtureProof)
            #expect(record.wasReadFromTranslationCache)
            #expect(try await disk.contains(ocrKey, kind: .ocr))
        }
        #expect(try await disk.regionRecord(for: ocrKey, kind: .ocr) == nil)
        #expect(try await !disk.contains(ocrKey, kind: .ocr))
    }

    @Test func translatedCandidateMatchesOnlyObservedFullSource() async throws {
        let settings = settings()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let page = Page(sourceId: "translated-claim", chapterId: "chapter", index: 0, imageURL: "https://example.invalid/same-page")
        let oldProof = Self.fixtureProof
        let newProof = try #require(ReaderTranslationSourceRasterClaim(processedFullSourceSHA256: String(repeating: "b", count: 64)))
        let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
        let generation = await disk.currentGeneration(settings: settings)
        var completed = regions[0]
        completed.translation = "기존 번역"
        let old = [completed], fresh = Array(regions.suffix(1))
        try await disk.storeRegions(old, for: key, kind: .translation, generation: generation, sourceRasterClaim: oldProof)
        let matched = ReaderTranslationPreloader(diskCache: disk, translator: { _, _, _ in
            Issue.record("An authenticated translation must not reach provider work"); return []
        }, recognizer: { _, _ in Issue.record("An authenticated translation must not reach OCR"); return [] },
            availableMemory: { .max }, imagePreparationGate: imageBudget, fixtureSourceRasterClaim: { _ in oldProof })
        let replay = try await matched.translateRecord(page, settings: settings)
        #expect(replay.regions == old && replay.sourceRasterClaim == oldProof)
        matched.cancel()
        var freshSettings = settings
        freshSettings.rightToLeftPanelOrder = false // use a one-region initialized mock, not a page loader
        let freshKey = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: freshSettings)
        try await disk.storeRegions(old, for: freshKey, kind: .translation,
            generation: await disk.currentGeneration(settings: freshSettings), sourceRasterClaim: oldProof)
        let changed = ReaderTranslationPreloader(diskCache: disk, translator: { records, _, _ in records },
            recognizer: { _, _ in fresh }, availableMemory: { .max }, imagePreparationGate: imageBudget,
            fixtureSourceRasterClaim: { _ in newProof })
        defer { changed.cancel() }
        let actual = try await changed.translateRecord(page, settings: freshSettings)
        #expect(actual.regions == fresh && actual.sourceRasterClaim == newProof)
    }

    @Test func speculativeAuthenticatedTranslationTransfersTheSameRecordAfterDiskEviction() async throws {
        var settings = settings()
        settings.rightToLeftPanelOrder = false
        settings.maximumConcurrentRequests = 2
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let head = Page(sourceId: "translated-lookahead", chapterId: "chapter", index: 0, imageURL: "https://example.invalid/0")
        let tail = Page(sourceId: head.sourceId, chapterId: head.chapterId, index: 1, imageURL: "https://example.invalid/1")
        let headRegion = regions[0]
        var region = regions[1]
        region.translation = "준비된 번역"
        let completed = [region], proof = Self.fixtureProof
        let key = ReaderTranslationCacheIdentity.translation(page: tail.translationCacheKey, settings: settings)
        try await disk.storeRegions(completed, for: key, kind: .translation,
            generation: await disk.currentGeneration(settings: settings), sourceRasterClaim: proof)
        let preloader = ReaderTranslationPreloader(diskCache: disk, translator: { records, _, _ in records },
            recognizer: { page, _ in
                if page.index == 1 { Issue.record("Lookahead cached hit must not rerun OCR") }
                return [headRegion]
            }, availableMemory: { .max }, imagePreparationGate: imageBudget, fixtureSourceRasterClaim: { _ in proof })
        defer { preloader.cancel() }
        preloader.nextPage = { $0.index == 0 ? tail : nil }
        var published: ReaderTranslationRegionArchive.Record?
        preloader.onPreparedRecord = { page, record, _ in if page.index == 1 { published = record } }
        _ = try await preloader.translateRecord(head, settings: settings)
        let deadline = Date().addingTimeInterval(2)
        while published == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(published?.regions == completed && published?.sourceRasterClaim == proof)
        try await disk.remove(key, kind: .translation)
        let consumed = try await preloader.translateRecord(tail, settings: settings)
        #expect(consumed.regions == completed && consumed.sourceRasterClaim == proof)
    }

    @Test func obsoleteIncompleteAndMalformedRanksAreRecalculated() {
        let settings = settings(), source = image()
        let prepared = ReaderTranslationImagePreparation.apply(regions, image: source, settings: settings)
        for variant in 0..<5 {
            var stale = prepared
            switch variant {
            case 0: stale[0].translationOrderVersion = "older-panel-algorithm"
            case 1: stale[0].translationOrder = nil
            case 2: stale[0].translationOrder = -1
            case 3: stale[0].translationOrder = stale[1].translationOrder
            default: stale[0].translationOrder = 50
            }
            #expect(ReaderTranslationImagePreparation.needsImage(stale, settings: settings))
            #expect(ReaderTranslationImagePreparation.apply(stale, image: source, settings: settings) == prepared)
        }
    }

    @Test func emptyAndSingleRegionPagesDoNotLoadAnImageForReadingOrder() {
        let settings = settings()
        #expect(!ReaderTranslationImagePreparation.needsImage([], settings: settings))
        #expect(!ReaderTranslationImagePreparation.needsImage(Array(regions.prefix(1)), settings: settings))
    }

    private var regions: [ReaderTranslationRegion] {
        [.init(id: "left", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3), source: "左の会話", sourceOrientation: .vertical),
         .init(id: "right", rect: CGRect(x: 0.65, y: 0.1, width: 0.2, height: 0.3), source: "右の会話", sourceOrientation: .vertical)]
    }
    private func settings() -> ReaderTranslationSettings {
        var value = ReaderTranslationSettings()
        value.rightToLeftPanelOrder = true
        value.sourceLanguage = "auto"
        value.translationSourceLanguages = []
        value.includePageImage = false
        return value
    }
    private func image(color: UIColor = .white) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image {
            color.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
    }
}

private actor PreparedOCRInvocationCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor PreparedOCRGate {
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
