import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationProgressTests {
    @Test func incrementalProgressMatchesFullOverlayMergeAndPreservesSnapshots() async throws {
        var settings = ReaderTranslationSettings()
        settings.model = "test-model"
        var regions = (0..<192).map { index in
            var region = ReaderTranslationRegion(id: "r\(index)",
                rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), source: "台詞\(index)")
            region.polygon = [.zero, CGPoint(x: 0.4, y: 0.3)]
            region.auxiliaryInkRects = [CGRect(x: 0.2, y: 0.1, width: 0.01, height: 0.02)]
            region.sourceOrientation = .vertical
            return region
        }
        let plans = ReaderTranslationService.plans(regions: regions, settings: settings)
        #expect(plans.count > 1)
        var expected: [Int: NativeTranslationReuseIdentity] = [:]
        for plan in plans {
            for (id, identity) in try NativeTranslationReuseIdentity.identitiesBySegmentID(
                configuration: settings.configuration, request: plan.request) {
                expected[plan.inputIndicesBySegmentID[id]!] = identity
            }
        }
        for index in regions.indices {
            regions[index].translation = "previous-\(index)"
            if index % 3 == 0 { regions[index].translationReuseIdentity = expected[index] }
            if index % 3 == 1 {
                var stale = settings
                stale.model = "old-model"
                let plan = plans.first { $0.inputIndicesBySegmentID.values.contains(index) }!
                regions[index].translationReuseIdentity = try NativeTranslationReuseIdentity.identitiesBySegmentID(
                    configuration: stale.configuration, request: plan.request)[regions[index].id]
            }
        }
        let progress = try ReaderTranslationProgress(regions: regions, plans: plans, configuration: settings.configuration)
        var completed: [Int: NativeTranslationReuseValue] = [:]
        func reference() -> [ReaderTranslationRegion] {
            let items = regions.enumerated().map { $0.element.overlayItem(index: $0.offset, imageSize: CGSize(width: 1, height: 1)) }
            let merged = NativeProgressiveTranslationOverlay.merge(items: items, expectedIdentities: expected, completedTranslations: completed)
            return zip(regions, merged).map { region, item in
                var value = region
                value.translation = item.translatedText
                value.translationReuseIdentity = item.translationReuseIdentity
                return value
            }
        }
        let initial = await progress.snapshot()
        #expect(initial == reference())
        var referenceMS = 0.0, incrementalMS = 0.0
        // Out-of-order and duplicate callbacks also preserve earlier snapshots.
        for index in Array(plans.indices.reversed()) + [0] {
            let result = RemoteTranslationBatchResult(translations: plans[index].request.segments.map {
                RemoteTranslatedSegment(id: $0.id, text: "번역-\($0.id)")
            } + [.init(id: "unknown", text: "ignored")], source: .network, providerRequestID: nil)
            for segment in result.translations {
                if let inputIndex = plans[index].inputIndicesBySegmentID[segment.id] {
                    completed[inputIndex] = .init(identity: expected[inputIndex]!, translatedText: segment.text)
                }
            }
            let start = ProcessInfo.processInfo.systemUptime
            let actual = await progress.complete(index: index, result: result)
            incrementalMS += (ProcessInfo.processInfo.systemUptime - start) * 1000
            let referenceStart = ProcessInfo.processInfo.systemUptime
            let original = reference()
            referenceMS += (ProcessInfo.processInfo.systemUptime - referenceStart) * 1000
            #expect(actual == original)
            #expect(await progress.snapshot() == original)
        }
        #expect(initial[0].translation == "previous-0")
        #expect(initial[1].translation == nil)
        #expect(initial[2].translation == nil)
        print("PROGRESS_BENCH regions=\(regions.count) batches=\(plans.count) reference_ms=\(referenceMS) incremental_ms=\(incrementalMS)")
    }
}
