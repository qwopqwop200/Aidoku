// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation
import XCTest
@testable import Aidoku

private actor NativeBatchPlannerCountingTranslator: RemoteTranslating {
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var requestedSegmentIDs: [[String]] = []

    func translate(
        _ request: RemoteTranslationRequest,
        configuration: RemoteTranslationConfiguration
    ) async throws -> RemoteTranslationBatchResult {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        requestedSegmentIDs.append(request.segments.map(\.id))
        do {
            try await Task.sleep(for: .milliseconds(40))
            activeCalls -= 1
        } catch {
            activeCalls -= 1
            throw error
        }
        return RemoteTranslationBatchResult(
            translations: request.segments.map {
                RemoteTranslatedSegment(
                    id: $0.id,
                    text: "translated:\($0.text)"
                )
            },
            source: .network,
            providerRequestID: nil
        )
    }

    func snapshot() -> (calls: Int, maximumActive: Int) {
        (requestedSegmentIDs.count, maximumActiveCalls)
    }
}

final class NativeTranslationBatchPlannerTests: XCTestCase {
    func testStableFrameLeadingBatchAndTailPreserveReadingOrderAndCaps()
        throws
    {
        let cases = [1, 4, 5, 16, 64, 65, 100, 129]

        for count in cases {
            let plans = makePlans(count: count)
            XCTAssertEqual(
                plans.flatMap { $0.request.segments.map(\.id) },
                (0..<count).map { "segment-\($0)" }
            )
            if let leading = plans.first {
                XCTAssertLessThanOrEqual(
                    leading.request.segments.count,
                    NativeTranslationBatchPlanner.leadingMaximumSegments
                )
                if count >= NativeTranslationBatchPlanner.leadingMinimumSegments {
                    XCTAssertGreaterThanOrEqual(
                        leading.request.segments.count,
                        NativeTranslationBatchPlanner.leadingMinimumSegments
                    )
                }
            }
            for (index, plan) in plans.dropFirst().enumerated() {
                XCTAssertLessThanOrEqual(
                    plan.request.segments.count,
                    NativeTranslationBatchPlanner.tailMaximumSegments
                )
                if index < plans.dropFirst().count - 1 {
                    XCTAssertGreaterThanOrEqual(
                        plan.request.segments.count,
                        NativeTranslationBatchPlanner.tailMinimumStableSegments
                    )
                }
            }
            for plan in plans {
                try plan.request.validate()
            }
        }
    }

    func testSourceByteLimitSplitsBeforePreferredCountCap() throws {
        let maximumSegment = String(
            repeating: "a",
            count: RemoteTranslationRequest.maximumSegmentTextBytes
        )
        let plans = makePlans(count: 9, text: maximumSegment)

        XCTAssertEqual(plans.flatMap { $0.request.segments }.count, 9)
        for plan in plans {
            XCTAssertLessThanOrEqual(
                plan.request.segments.reduce(0) {
                    $0 + $1.text.utf8.count
                },
                RemoteTranslationRequest.maximumSourceBytes
            )
            try plan.request.validate()
        }
    }

    func testMappingAndSemanticFieldsSurviveEveryChunk() {
        let context = ["prior subtitle"]
        let glossary = [
            TranslationGlossaryEntry(source: "猫", target: "고양이"),
        ]
        let candidates = (0..<16).map { index in
            NativeTranslationBatchCandidate(
                inputIndex: 100 + index,
                segment: RemoteTranslationSegment(
                    id: "mapped-\(index)",
                    text: "source-\(index)"
                )
            )
        }
        let plans = NativeTranslationBatchPlanner.makeBatches(
            candidates: candidates,
            sourceLanguage: "ja",
            targetLanguage: "ko",
            context: context,
            glossary: glossary
        )

        XCTAssertEqual(plans.flatMap { $0.request.segments }.count, 16)
        for plan in plans {
            XCTAssertEqual(plan.request.sourceLanguage, "ja")
            XCTAssertEqual(plan.request.targetLanguage, "ko")
            XCTAssertEqual(plan.request.context, context)
            XCTAssertEqual(plan.request.glossary, glossary)
            for segment in plan.request.segments {
                let ordinal = Int(segment.id.dropFirst("mapped-".count))
                XCTAssertEqual(
                    plan.inputIndicesBySegmentID[segment.id],
                    ordinal.map { 100 + $0 }
                )
            }
        }
    }

    func testIdenticalFrameUsesCacheAndChangedTailKeepsHeadChunk()
        async throws
    {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try TranslationCache(
            configuration: .init(
                memoryEnabled: true,
                diskEnabled: false,
                maxSizeMiB: 1
            ),
            storageRootURL: root
        )
        let translator = NativeBatchPlannerCountingTranslator()
        let service = TranslationService(client: translator, cache: cache)
        let coordinator = LatestTranslationCoordinator(service: service)
        let configuration = RemoteTranslationConfiguration.openAI(
            model: "gpt-5-mini"
        )
        let original = makePlans(count: 16)

        let first = try await coordinator.translateLatestBatches(
            original.map(\.request),
            configuration: configuration
        )
        XCTAssertTrue(first.allSatisfy { $0.source == .network })
        var snapshot = await translator.snapshot()
        XCTAssertEqual(snapshot.calls, original.count)
        XCTAssertEqual(snapshot.maximumActive, original.count)

        let identical = try await coordinator.translateLatestBatches(
            original.map(\.request),
            configuration: configuration
        )
        XCTAssertTrue(identical.allSatisfy { $0.source == .memoryCache })
        snapshot = await translator.snapshot()
        XCTAssertEqual(
            snapshot.calls,
            original.count,
            "identical frame hit the network"
        )

        var changedCandidates = makeCandidates(count: 16)
        changedCandidates[13] = NativeTranslationBatchCandidate(
            inputIndex: 13,
            segment: RemoteTranslationSegment(
                id: "segment-13",
                text: "changed-tail"
            )
        )
        let changed = makePlans(candidates: changedCandidates)
        XCTAssertEqual(changed.count, original.count)
        let changedBatchIndices = original.indices.filter {
            original[$0].request != changed[$0].request
        }
        XCTAssertEqual(changedBatchIndices.count, 1)
        let changedBatchIndex = try XCTUnwrap(changedBatchIndices.first)
        let reusableBatchIndex = try XCTUnwrap(
            original.indices.first { $0 != changedBatchIndex }
        )
        let originalHeadIdentities =
            try NativeTranslationReuseIdentity.identitiesBySegmentID(
                configuration: configuration,
                request: original[reusableBatchIndex].request
            )
        let changedHeadIdentities =
            try NativeTranslationReuseIdentity.identitiesBySegmentID(
                configuration: configuration,
                request: changed[reusableBatchIndex].request
            )
        let originalTailIdentities =
            try NativeTranslationReuseIdentity.identitiesBySegmentID(
                configuration: configuration,
                request: original[changedBatchIndex].request
            )
        let changedTailIdentities =
            try NativeTranslationReuseIdentity.identitiesBySegmentID(
                configuration: configuration,
                request: changed[changedBatchIndex].request
            )
        XCTAssertEqual(changedHeadIdentities, originalHeadIdentities)
        XCTAssertNotEqual(changedTailIdentities, originalTailIdentities)
        let reusableSegmentID = try XCTUnwrap(
            original[reusableBatchIndex].request.segments.first?.id
        )
        let reusableHead = try XCTUnwrap(
            originalHeadIdentities[reusableSegmentID]
        )
        let reuseIndex = NativeTranslationReuseIndex(values: [
            NativeTranslationReuseValue(
                identity: reusableHead,
                translatedText: "cached-head"
            ),
        ])
        XCTAssertEqual(
            reuseIndex.value(
                matching: changedHeadIdentities[reusableSegmentID]
            )?.translatedText,
            "cached-head"
        )

        let mixed = try await coordinator.translateLatestBatches(
            changed.map(\.request),
            configuration: configuration
        )
        XCTAssertEqual(
            mixed.filter { $0.source == .network }.count,
            1
        )
        XCTAssertEqual(
            mixed.filter { $0.source == .memoryCache }.count,
            mixed.count - 1
        )
        XCTAssertEqual(mixed.combinedTranslationSource, .network)
        snapshot = await translator.snapshot()
        XCTAssertEqual(
            snapshot.calls,
            original.count + 1,
            "an unchanged chunk should not trigger another provider call"
        )
    }

    func testTrackerIDResetDoesNotChangeHybridBatchBoundaries() throws {
        let original = makePlans(count: 129)
        let renumbered = makePlans(candidates: (0..<129).map { index in
            NativeTranslationBatchCandidate(
                inputIndex: index,
                segment: RemoteTranslationSegment(
                    id: "reset-region-\(10_000 + index)",
                    text: "source-\(index)"
                )
            )
        })

        XCTAssertEqual(
            original.map { $0.request.segments.map(\.text) },
            renumbered.map { $0.request.segments.map(\.text) }
        )
        XCTAssertEqual(
            original.map { $0.request.segments.count },
            renumbered.map { $0.request.segments.count }
        )

        for (originalPlan, renumberedPlan) in zip(original, renumbered) {
            let originalIdentities =
                try NativeTranslationReuseIdentity.identitiesBySegmentID(
                    configuration: .openAI(model: "gpt-5-mini"),
                    request: originalPlan.request
                )
            let renumberedIdentities =
                try NativeTranslationReuseIdentity.identitiesBySegmentID(
                    configuration: .openAI(model: "gpt-5-mini"),
                    request: renumberedPlan.request
                )
            XCTAssertEqual(
                originalPlan.request.segments.enumerated().map {
                    originalIdentities[$0.element.id]
                },
                renumberedPlan.request.segments.enumerated().map {
                    renumberedIdentities[$0.element.id]
                }
            )
        }
    }

    func testCombinedSourceUsesNetworkThenDiskThenMemoryPriority() {
        XCTAssertNil([RemoteTranslationBatchResult]().combinedTranslationSource)
        XCTAssertEqual(
            [result(source: .memoryCache)].combinedTranslationSource,
            .memoryCache
        )
        XCTAssertEqual(
            [result(source: .memoryCache), result(source: .diskCache)]
                .combinedTranslationSource,
            .diskCache
        )
        XCTAssertEqual(
            [result(source: .diskCache), result(source: .network)]
                .combinedTranslationSource,
            .network
        )
    }

    private func makePlans(
        count: Int,
        text: String? = nil
    ) -> [NativeTranslationBatchPlan] {
        makePlans(candidates: makeCandidates(count: count, text: text))
    }

    private func makePlans(
        candidates: [NativeTranslationBatchCandidate]
    ) -> [NativeTranslationBatchPlan] {
        NativeTranslationBatchPlanner.makeBatches(
            candidates: candidates,
            sourceLanguage: "ja",
            targetLanguage: "ko",
            context: [],
            glossary: []
        )
    }

    private func makeCandidates(
        count: Int,
        text: String? = nil
    ) -> [NativeTranslationBatchCandidate] {
        (0..<count).map { index in
            NativeTranslationBatchCandidate(
                inputIndex: index,
                segment: RemoteTranslationSegment(
                    id: "segment-\(index)",
                    text: text ?? "source-\(index)"
                )
            )
        }
    }

    private func result(
        source: TranslationResultSource
    ) -> RemoteTranslationBatchResult {
        RemoteTranslationBatchResult(
            translations: [],
            source: source,
            providerRequestID: nil
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "aidoku-native-batch-planner-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }
}
