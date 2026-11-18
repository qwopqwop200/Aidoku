import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Shared operating-default and explicit-comparison policy/cache guards.
/// No model resources, predictions, images or provider.
struct NativeOCRSourceAnchorMainPolicyTests {
    @available(iOS 18.0, *)
    @Test func partialTextOverlapCanSupportTheBoundaryAndRemainAnIndependentCandidate() {
        func line(_ y: CGFloat, legacy: Bool) -> NativeCoreMLOCRLine {
            let quad = [CGPoint(x: 10, y: y), CGPoint(x: 110, y: y),
                        CGPoint(x: 110, y: y + 20), CGPoint(x: 10, y: y + 20)]
            var row = NativeCoreMLOCRLine(polygon: quad, text: "本文", score: 0.9, orientation: .horizontal)
            row.isLegacyComplement = legacy
            return row
        }
        let primary = line(20, legacy: false)
        let partial = line(27, legacy: true)
        let pair = NativeOCRLegacyComplementFilter.representatives([primary, partial], width: 150, height: 100)
        #expect(pair.map(\.isLegacyComplement) == [false, true])
        #expect(pair.first?.preCalibrationPolygon == primary.polygon)
        #expect(pair.last?.polygon == partial.polygon)
        let twin = line(20, legacy: true)
        let identical = NativeOCRLegacyComplementFilter.representatives([primary, twin], width: 150, height: 100)
        #expect(identical.count == 1)
    }
    @available(iOS 18.0, *)
    @Test func combinedBranchesPreserveSuppressedPacketsAndRebaseMembership() throws {
        let q = [CGPoint(x: 1, y: 1), CGPoint(x: 8, y: 1), CGPoint(x: 8, y: 9), CGPoint(x: 1, y: 9)]
        func packets(_ texts: [String]) -> [NativeCoreMLOCRLine] {
            NativeOCRAcceptedSource.bindingPrimary(texts.map {
                .init(polygon: q, text: $0, score: 0.8, orientation: .vertical)
            }, width: 10, height: 10)
        }
        let primary = packets(["body", "old alias"])
        let legacy = packets(["reading", "legacy body", "legacy alias"])
        var retained = legacy[1]
        let original = try #require(retained.acceptedSource.membership)
        retained.acceptedSource = .init(.init(table: original.table, body: [1], readings: [0],
            unknownDedup: [2], hasUntrackedInputs: false), layoutPolygon: q, detectorSignals: [0.9])
        let joint = try NativeOCRRawCanonicalRuntime.joinedLines(current: [primary[0]], legacy: [retained],
                                                                width: 10, height: 10)
        let first = try #require(joint.first?.acceptedSource.membership)
        let last = try #require(joint.last?.acceptedSource.membership)
        #expect(first.table === last.table)
        #expect(first.table.packets.map(\.text) == ["body", "old alias", "reading", "legacy body", "legacy alias"])
        #expect(first.body == [0])
        #expect(last.body == [3])
        #expect(last.readings == [2])
        #expect(last.unknownDedup == [4])
        #expect(!first.isLegacyComplement)
        #expect(last.isLegacyComplement)
        #expect(joint.map(\.isLegacyComplement) == [false, true])
        #expect(joint.last?.acceptedSource.detectorSignals == [0.9])
    }

    @available(iOS 18.0, *)
    @Test func complementCannotBridgePrimaryParagraphOrSuppressPrimaryOwner() throws {
        func line(_ x: CGFloat, score: Double) -> NativeCoreMLOCRLine {
            .init(polygon: [CGPoint(x: x, y: 10), CGPoint(x: x+10, y: 10),
                            CGPoint(x: x+10, y: 70), CGPoint(x: x, y: 70)],
                  text: "本文", score: score, orientation: .vertical)
        }
        let primary = NativeOCRAcceptedSource.bindingPrimary([line(20, score: 0.8)], width: 100, height: 100)
        let legacy = NativeOCRAcceptedSource.bindingPrimary([line(32, score: 0.98), line(44, score: 0.95)],
                                                           width: 100, height: 100)
        let combined = try NativeOCRRawCanonicalRuntime.joinedLines(current: primary, legacy: legacy, width: 100, height: 100)
        let grouped = try NativeParagraphFragmentGrouping.simpleNativeResult(combined, width: 100, height: 100, scopes: [])
        #expect(grouped.regions.map { $0.acceptedSource.membership?.body } == [Set([0]), Set([1,2])])
        let twin = NativeOCRAcceptedSource.bindingPrimary([line(20, score: 0.99)], width: 100, height: 100)
        let twins = try NativeOCRRawCanonicalRuntime.joinedLines(current: primary, legacy: twin, width: 100, height: 100)
        let duplicate = try NativeParagraphFragmentGrouping.simpleNativeResult(twins, width: 100, height: 100, scopes: [])
        let retained = NativeFinalOutputDuplicateResolver.applying(duplicate.regions)
        #expect(retained.suppressed == 1)
        #expect(retained.regions.first?.id == "native-line-0")
    }
    @available(iOS 18.0, *)
    @Test func complementDuplicateRetainsErasureAncestryAndProtectsIndependentBodies() throws {
        func line(_ y: CGFloat, _ text: String) -> NativeCoreMLOCRLine {
            .init(polygon: [CGPoint(x: 10, y: y), CGPoint(x: 110, y: y),
                            CGPoint(x: 110, y: y + 20), CGPoint(x: 10, y: y + 20)],
                  text: text, score: 0.95, orientation: .horizontal)
        }
        let primary = NativeOCRAcceptedSource.bindingPrimary([line(10, "本文です"), line(34, "次です")], width: 200, height: 200)
        let legacy = NativeOCRAcceptedSource.bindingPrimary([line(12, "本文です"), line(100, "別の本文")], width: 200, height: 200)
        let joined = try NativeOCRRawCanonicalRuntime.joinedLines(current: primary, legacy: legacy, width: 200, height: 200)
        let grouped = try joined.flatMap {
            try NativeParagraphFragmentGrouping.simpleNativeResult([$0], width: 200, height: 200, scopes: []).regions
        }
        try #require(grouped.count == 4)
        var paragraph = grouped[0]
        paragraph.acceptedSource = .union([grouped[0].acceptedSource, grouped[1].acceptedSource])
        let filtered = NativeFinalOutputDuplicateResolver.applyingComplementOwners([paragraph, grouped[2], grouped[3]])
        #expect(filtered.suppressed == 1)
        let retained = try #require(filtered.regions.first?.acceptedSource.membership)
        #expect(retained.body == [0, 1])
        #expect(retained.unknownDedup == [2])
        #expect(filtered.regions.last?.source == "別の本文")
        var compound = grouped[2]
        compound.acceptedSource = .union([grouped[2].acceptedSource, grouped[3].acceptedSource])
        #expect(NativeFinalOutputDuplicateResolver.applyingComplementOwners([paragraph, compound]).suppressed == 0)
        // A same-size complement twin of a surviving primary reads no new text.
        #expect(NativeFinalOutputDuplicateResolver.applyingComplementOwners([grouped[0], grouped[2]]).suppressed == 1)
        #expect(NativeFinalOutputDuplicateResolver.applyingComplementOwners([grouped[2], grouped[3]]).suppressed == 0)
    }

    @available(iOS 18.0, *)
    @Test func wideComplementCoveredByPrimaryTextIsSuppressedButNewTextSurvives() throws {
        func line(_ y: CGFloat, _ height: CGFloat, _ text: String) -> NativeCoreMLOCRLine {
            .init(polygon: [CGPoint(x: 10, y: y), CGPoint(x: 110, y: y),
                            CGPoint(x: 110, y: y + height), CGPoint(x: 10, y: y + height)],
                  text: text, score: 0.95, orientation: .horizontal)
        }
        func owners(_ legacy: [NativeCoreMLOCRLine]) throws -> [ReaderTranslationRegion] {
            let primary = NativeOCRAcceptedSource.bindingPrimary([line(10, 20, "それも嘘ですね"), line(40, 20, "よしよし")],
                                                                 width: 200, height: 200)
            let complement = NativeOCRAcceptedSource.bindingPrimary(legacy, width: 200, height: 200)
            let joined = try NativeOCRRawCanonicalRuntime.joinedLines(current: primary, legacy: complement, width: 200, height: 200)
            return try joined.flatMap {
                try NativeParagraphFragmentGrouping.simpleNativeResult([$0], width: 200, height: 200, scopes: []).regions
            }
        }
        // A wide read spanning both primaries that repeats a primary line.
        let repeated = try owners([line(8, 54, "それも\n嘘ですね\n嘘ですね")])
        try #require(repeated.count == 3)
        let merged = NativeFinalOutputDuplicateResolver.applyingComplementOwners(repeated)
        #expect(merged.suppressed == 1)
        #expect(merged.regions.map(\.source) == repeated.prefix(2).map(\.source))
        // Erasure ancestry is retained by the primary it duplicates.
        #expect(merged.regions.first?.acceptedSource.membership?.unknownDedup == [2])
        // The same geometry with genuinely new text, and a mostly new read inside one line, are kept.
        #expect(NativeFinalOutputDuplicateResolver.applyingComplementOwners(try owners([line(8, 54, "まったく別の台詞")])).suppressed == 0)
        #expect(NativeFinalOutputDuplicateResolver.applyingComplementOwners(try owners([line(12, 16, "嘘みたいな話")])).suppressed == 0)
        #expect(NativeFinalOutputDuplicateResolver.applyingComplementOwners(try owners([line(12, 16, "嘘で")])).suppressed == 1)
        // A variant reading inside one single-line primary is that line read twice.
        #expect(NativeFinalOutputDuplicateResolver.applyingComplementOwners(try owners([line(11, 18, "それも嘘でずね")])).suppressed == 1)
    }

    @available(iOS 18.0, *)
    @Test func bundledRecoveryHeadsDecodeFromTheRunningApp() throws {
        let provider = NativeOCRRawGeometryModelBundle.Provider(bundle: .main)
        guard case let .full(models) = try provider.acquire(.full, cancellationCheck: {}) else {
            Issue.record("The packaged recovery heads must be available to the manga pipeline.")
            return
        }
        #expect(models.auxiliary != nil)
    }

    @Test func rawOnlyBBoxCacheCannotServeRecoveryOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ReaderTranslationDiskCache(directory: directory)
        let settings = ReaderTranslationSettings()
        let previous = ReaderTranslationCacheIdentity.ocr(page: "recovery", settings: settings,
            rawCanonicalRevision: "main-source-anchor-no-prerec-simple-rec64-nms-det085-longitudinal104-v4")
        let current = ReaderTranslationCacheIdentity.ocr(page: "recovery", settings: settings)
        let stale = Data("old source boxes".utf8)
        try await cache.store(stale, for: previous, kind: .ocr, generation: 0)
        let original = try await cache.data(for: previous, kind: .ocr)
        let hit = try await cache.data(for: current, kind: .ocr)
        #expect(original == stale)
        #expect(current != previous)
        #expect(hit == nil)
    }

    @Test func estimatedLineExtentPreservesWidthAndStaysInsideThePage() {
        let v = [CGPoint(x: 20, y: 10), CGPoint(x: 30, y: 10), CGPoint(x: 30, y: 110), CGPoint(x: 20, y: 110)]
        let expected = [CGPoint(x: 20, y: 8), CGPoint(x: 30, y: 8), CGPoint(x: 30, y: 112), CGPoint(x: 20, y: 112)]
        #expect(NativeOCRRawCanonicalPolicy.estimatedLineExtent(v, width: 200, height: 200) == expected)
        let horizontal = v.map { CGPoint(x: $0.y, y: $0.x) }
        #expect(NativeOCRRawCanonicalPolicy.estimatedLineExtent(horizontal, width: 200, height: 200)
                == expected.map { CGPoint(x: $0.y, y: $0.x) })
        #expect(NativeOCRRawCanonicalPolicy.estimatedLineExtent(v, width: 200, height: 110) == v)
        #expect(NativeOCRRawCanonicalPolicy.estimatedLineExtent(Array(v.prefix(3)), width: 200, height: 200) == Array(v.prefix(3)))
    }

    @available(iOS 18.0, *)
    @Test func estimatedExtentCannotBridgeTwoSeparateRecognizedLines() throws {
        let originals: [NativeCoreMLOCRLine] = [40, 166].map { x in
            let p = [CGPoint(x: x, y: 80), CGPoint(x: x + 100, y: 80),
                     CGPoint(x: x + 100, y: 100), CGPoint(x: x, y: 100)]
            return .init(polygon: p, text: "本文", score: 0.95, orientation: .horizontal)
        }
        let bound = NativeOCRAcceptedSource.bindingPrimary(originals, width: 400, height: 400)
        let calibrated = bound.map { original in
            let q = NativeOCRRawCanonicalPolicy.estimatedLineExtent(original.polygon, width: 400, height: 400)
            var line = NativeCoreMLOCRLine(polygon: q, text: original.text, score: original.score,
                                           orientation: original.orientation, acceptedSource: original.acceptedSource)
            line.preCalibrationPolygon = original.polygon
            return line
        }
        let result = try NativeParagraphFragmentGrouping.simpleNativeResult(calibrated, width: 400, height: 400, scopes: [])
        #expect(result.outputOwners == 2)
        let expectedPolygons = calibrated.map { line in
            line.polygon.map { point in CGPoint(x: point.x / 400, y: point.y / 400) }
        }
        let renderedPolygons = result.regions.map(\.polygon)
        #expect(renderedPolygons == expectedPolygons)
    }
    @available(iOS 18.0, *)
    @Test func appTaskLocalAndHostFallbackShareNoAuxiliaryPreRecognitionDefault() {
        let policy = NativeOCRRawCanonicalPolicy.defaultSourceAnchorMode
        #expect(policy == .noPreRecognition)
        #expect(NativeOCRRawCanonicalRuntime.sourceAnchorMode == policy)
        #expect(NativeOCRRawCanonicalPolicy.resolvedSourceAnchorMode(override: nil) == policy)
        #expect(policy != .fixedPreRecognition)
        #expect(NativeOCRRawCanonicalPolicy.version != NativeOCRRawCanonicalPolicy.disabledComparisonVersion)
    }

    @available(iOS 18.0, *)
    @Test func explicitComparisonOverridesArePreservedAndInvalidValuesDoNotFallback() {
        for mode: NativeOCRRawCanonicalPolicy.SourceAnchorMode in [
            .disabled, .fixedPreRecognition, .noPreRecognition, .noPreRecognitionTerminalRecovery
        ] {
            #expect(NativeOCRRawCanonicalPolicy.resolvedSourceAnchorMode(override: mode.rawValue) == mode)
        }
        #expect(NativeOCRRawCanonicalPolicy.resolvedSourceAnchorMode(override: "") == nil)
        #expect(NativeOCRRawCanonicalPolicy.resolvedSourceAnchorMode(override: "invalid-mode") == nil)
        #expect(NativeOCRRawCanonicalPolicy.resolvedSourceAnchorMode(override:
            "source-anchor-primary-geometry-fixed-prerec-v1") == nil)
    }

    @available(iOS 18.0, *)
    @Test func taskLocalComparisonRestoresSharedDefault() {
        let initial = NativeOCRRawCanonicalRuntime.sourceAnchorMode
        NativeOCRRawCanonicalRuntime.$sourceAnchorMode.withValue(.disabled) {
            #expect(NativeOCRRawCanonicalRuntime.sourceAnchorMode == .disabled)
        }
        #expect(NativeOCRRawCanonicalRuntime.sourceAnchorMode == initial)
        #expect(initial == NativeOCRRawCanonicalPolicy.defaultSourceAnchorMode)
    }

    @available(iOS 18.0, *)
    @Test func actualOCRAndDerivedTranslationCacheIdentitiesFenceEveryExplicitMode() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let modes: [NativeOCRRawCanonicalPolicy.SourceAnchorMode] = [
            .disabled, .fixedPreRecognition, .noPreRecognition, .noPreRecognitionTerminalRecovery
        ]
        let ocrKeys = modes.map { mode in
            NativeOCRRawCanonicalRuntime.$sourceAnchorMode.withValue(mode) {
                ReaderTranslationCacheIdentity.ocr(page: "source-anchor-policy-test", settings: settings)
            }
        }
        let translationKeys = modes.map { mode in
            NativeOCRRawCanonicalRuntime.$sourceAnchorMode.withValue(mode) {
                ReaderTranslationCacheIdentity.translation(page: "source-anchor-policy-test", settings: settings)
            }
        }
        #expect(Set(ocrKeys).count == modes.count)
        #expect(Set(translationKeys).count == modes.count)
        #expect(ReaderTranslationCacheIdentity.ocr(page: "source-anchor-policy-test", settings: settings) == ocrKeys[2])
        #expect(ocrKeys[0] != ocrKeys[1])
    }

    @available(iOS 18.0, *)
    @Test func simpleDeduplicationFencesOCRAndDerivedTranslationCaches() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let alternatives: [NativeSimpleOCRDedup.Configuration?] = [nil,
            .init(iouThreshold: 0.85, rank: .recognition),
            .init(iouThreshold: 0.9, rank: .recognition)]
        let keys = alternatives.map { configuration in
            NativeOCRRawCanonicalRuntime.$simpleDeduplication.withValue(configuration) {
                [ReaderTranslationCacheIdentity.ocr(page: "simple-dedup", settings: settings),
                 ReaderTranslationCacheIdentity.translation(page: "simple-dedup", settings: settings)]
            }
        }
        #expect(Set(keys.map { $0[0] }).count == alternatives.count)
        #expect(Set(keys.map { $0[1] }).count == alternatives.count)
        #expect(NativeOCRRawCanonicalRuntime.simpleDeduplication?.iouThreshold == 0.85)
        #expect(NativeOCRRawCanonicalRuntime.simpleDeduplication?.rank == .recognition)
    }

    @Test func optionalRecognitionAdmissionFencesOCRAndDerivedTranslationCaches() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let alternatives: [NativeSimpleRecognitionAdmission.Configuration?] = [nil,
            .init(confidenceFloor: 0.7, agreementFloor: 0.25),
            .init(confidenceFloor: 0.8, agreementFloor: 0.25),
            .init(confidenceFloor: 0.8, agreementFloor: nil)]
        let baseline = ReaderTranslationCacheIdentity.ocr(page: "simple-rec", settings: settings)
        let keys = alternatives.map { configuration in
            NativeSimpleRecognitionAdmission.$configuration.withValue(configuration) {
                [ReaderTranslationCacheIdentity.ocr(page: "simple-rec", settings: settings),
                 ReaderTranslationCacheIdentity.translation(page: "simple-rec", settings: settings)]
            }
        }
        #expect(Set(keys.map { $0[0] }).count == alternatives.count)
        #expect(Set(keys.map { $0[1] }).count == alternatives.count)
        #expect(keys[0][0] == baseline)
        #expect(NativeSimpleRecognitionAdmission.configuration == nil)
    }
}
