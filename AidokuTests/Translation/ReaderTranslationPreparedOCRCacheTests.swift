import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationPreparedOCRCacheTests {
    @Test func preparedCacheStartsTranslationWhileAnotherPageOCRIsBlocked() async throws {
        let settings = settings()
        let prepared = ReaderTranslationImagePreparation.apply(regions, image: image(), settings: settings)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let page = Page(sourceId: "ready-cache", chapterId: "chapter", index: 0)
        try await disk.storeRegions(prepared,
            for: ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings), kind: .ocr,
            generation: await disk.currentGeneration(settings: settings))
        let gate = PreparedOCRGate()
        let busy = ReaderTranslationPreloader(translator: { regions, _, _ in regions }, recognizer: { _, _ in
            await gate.wait()
            return []
        })
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
        })
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

    @Test func diskReopenReusesVersionedReadingOrderWithoutAnImage() async throws {
        let settings = settings()
        let prepared = ReaderTranslationImagePreparation.apply(regions, image: image(), settings: settings)
        #expect(!ReaderTranslationImagePreparation.needsImage(prepared, settings: settings))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = Page(sourceId: "prepared-cache", chapterId: "chapter", index: 0,
                        imageURL: root.appendingPathComponent("does-not-exist.png").absoluteString)
        let disk = ReaderTranslationDiskCache(directory: root)
        let key = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings)
        try await disk.storeRegions(prepared, for: key, kind: .ocr, generation: await disk.currentGeneration(settings: settings))
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.regions(for: key, kind: .ocr) == prepared)
        let preloader = ReaderTranslationPreloader(diskCache: reopened,
            translator: { regions, _, _ in regions }, recognizer: { _, _ in
                Issue.record("Cached OCR must not run again")
                return []
            })
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
    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image {
            UIColor.white.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
    }
}

private actor PreparedOCRGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
