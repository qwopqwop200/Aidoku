import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// Real CoreText glyphs, styled alpha, fixed-origin native admission and final
/// compositing. Synthetic source pixels exercise the unchanged boundary veto;
/// these fixtures do not infer a physical component or use corpus/page rules.
@Suite(.serialized) @MainActor
struct NativeJointSourceWidthPackingTests {
    private typealias J = NativeJointSourceWidthPacking
    private typealias N = NativeFinalTextPaintAdmission
    private typealias P = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    private typealias L = NativeAOTTranslationPageComposer.TextLayer
    private typealias S = NativeBalloonPlacement.RetainedState
    private typealias Refinement = (layer: L, baseline: J.Tuple, changed: Set<String>)

    private static let page = CGRect(x: 0, y: 0, width: 2200, height: 1000)
    private static let font: CGFloat = 32
    private static let pitch: CGFloat = 64
    private static let face = "AppleSDGothicNeo-Regular"
    // Intentionally neither lexical nor geometric order. Typed arrays retain
    // this producer order; geometric source runs must only sort their indices.
    private static let owners = ["b-short", "a-long", "b-long", "a-short"]
    private static let texts = [
        "a-long": "ALPHA BRAVO CHARLIE DELTA ECHO", "a-short": "YES",
        "b-long": "ALPHA BRAVO CHARLIE DELTA ECHO", "b-short": "YES"
    ]

    private struct Fixture {
        var tuple: J.Tuple
        let layer: L
        let restored: CGImage
    }
    private enum FactoryDefect: CaseIterable {
        case nonfiniteFrame, overflowRange, nonfinitePitch
    }
    private enum InputDefect: CaseIterable {
        case duplicateID, auditOrder, shortRange, negativeRange, overflowRange
        case ownershipHole, zeroPitch, nanPitch, infinitePitch, booleanPitch
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func shape(_ owner: String, width: CGFloat) throws -> (fill: P, row: [String: Any]) {
        let text = try #require(Self.texts[owner])
        let font = CTFontCreateWithName(Self.face as CFString, Self.font, nil)
        let wrapped = try NativeWholeWordWrap.layout(text: text, font: font, size: Self.font,
            width: width, color: CGColor(gray: 0, alpha: 1))
        try #require(wrapped.completeOwnership && wrapped.unresolvedGlyphRanges.isEmpty)
        // A lexical width proposal can be narrower than an unbreakable word.
        // Reject that optional shape like the production factory, rather than
        // recording a test issue before the search tries its other widths.
        guard wrapped.requiredWidth <= width + 0.01 else {
            throw NativeWholeWordWrap.Failure.noFittingLayout
        }
        let plan = try NativeWholeWordGlyphPainter.positionRetainedPitch(wrapped, width: width,
            pitch: Self.pitch, outwardExtent: 4)
        var fill = try NativeWholeWordGlyphPainter.raster(plan, origin: CGPoint(x: 40, y: 140),
            scale: 1, pagePixels: Self.page.size)
        fill.ownerID = owner
        fill.displayStrokeEndpoint = 255
        fill.displayStrokeRatio = 0.125
        let sourceX: CGFloat
        switch owner {
        case "a-long": sourceX = 500
        case "a-short": sourceX = 650
        case "b-long": sourceX = 1500
        default: sourceX = 1650
        }
        let source = CGRect(x: sourceX, y: 128, width: 24, height: 600)
        let capacity = owner.hasPrefix("a-")
            ? CGRect(x: 1, y: 80, width: 949, height: 850)
            : CGRect(x: 1100, y: 80, width: 1099, height: 850)
        func normalized(_ rect: CGRect) -> [Double] {
            [rect.minX / Self.page.width, rect.minY / Self.page.height,
             rect.width / Self.page.width, rect.height / Self.page.height].map(Double.init)
        }
        let allowed = normalized(capacity)
        fill.textExpansionPolicy = .init(allowedRectNormalized: allowed, candidates: [allowed],
            maskCoverage: [1], backgroundRisk: [0], sourceFontPixels: Double(Self.font),
            kind: "source-near-limited-expansion", maskRectNormalized: nil, maskSpansNormalized: nil)
        fill.textPlacementGuide = .init(rectNormalized: normalized(source), horizontal: .center, vertical: .center)
        fill.sourceClusterAlignment = .init(groupID: "synthetic-source-cohort", axis: .top,
            anchorNormalized: 128 / Double(Self.page.height), anchorPolicy: "source-near-final-alpha", anchorsToSourceStart: true)
        fill.placementDomain = { capacity.contains($0) }
        let row: [String: Any] = [
            "id": owner, "sourceUTF16": text.utf16.count, "visibleUTF16": text.utf16.count,
            "fontSize": Double(Self.font), "interiorWordRetainedFace": Self.face,
            "retainedLinePitchOutputPixels": Double(Self.pitch), "appliedTrackingPixels": 0.0,
            "lineRangesUTF16": wrapped.rows.map { [$0.ownedRange.location, $0.ownedRange.length] },
            "actualCoreTextLineStrings": wrapped.rows.map { (text as NSString).substring(with: $0.paintedRange) },
            "frameOutputTopLeft": J.rect(fill.frame), "retainedFillBoundsOutput": J.rect(fill.frame)
        ]
        return (fill, row)
    }

    private func fixture() throws -> Fixture {
        let context = try bitmap(width: Int(Self.page.width), height: Int(Self.page.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(Self.page)
        let restored = try #require(context.makeImage())
        let made = try Self.owners.map { try shape($0, width: 700) }
        let supports = try made.map { try N.retainedFootprint($0.fill) }
        var fixed: [String: CGPoint] = [:]
        for owner in Self.owners {
            let base: CGFloat = owner.hasPrefix("a-") ? 100 : 1200
            let x: CGFloat
            if owner.hasSuffix("long") {
                x = base
            } else {
                let peer = owner.hasPrefix("a-") ? "a-long" : "b-long"
                let index = try #require(Self.owners.firstIndex(of: peer))
                x = base + supports[index].bounds.width + 12
            }
            fixed[owner] = CGPoint(x: x, y: 128)
        }
        // Establish genuine initial native state, not hand-authored receipts.
        let tuple = try N.place(made.map(\.fill), page: Self.page, fixedOrigins: fixed)
        try #require(tuple.fills.count == Self.owners.count && tuple.audit.count == Self.owners.count)
        let actual = try tuple.fills.map { try N.retainedFootprint($0) }
        var rows: [[String: Any]] = []
        for i in Self.owners.indices {
            var row = made[i].row
            let delta = CGPoint(x: actual[i].bounds.minX - supports[i].bounds.minX,
                                y: actual[i].bounds.minY - supports[i].bounds.minY)
            for key in ["frameOutputTopLeft", "retainedFillBoundsOutput"] {
                var box = try #require(row[key] as? [CGFloat])
                box[0] += delta.x; box[1] += delta.y
                row[key] = box
            }
            rows.append(row)
        }
        let seed = L(image: restored, expectedItems: 4, paintedItems: 4, complete: true,
            audit: ["rawNativeItems": rows])
        let layer = try NativeAOTTranslationPageComposer.refineFinalReadability(layer: seed,
            fills: tuple.fills, restored: restored, admittedOverride: tuple, forceRepaint: true)
        return Fixture(tuple: tuple, layer: layer, restored: restored)
    }

    private func source(vetoSecondRun: Bool) throws -> NativeSourcePhysicalInteriorContext {
        let width = Int(Self.page.width), height = Int(Self.page.height)
        var rgb = [UInt8](repeating: 255, count: width * height * 3)
        if vetoSecondRun {
            // Actual original-pixel contrast field, only near run B. The native
            // source gate itself decides; no boundary/risk callback is mocked.
            for y in 0..<height { for x in 1000..<width {
                let value: UInt8 = (x / 2 + y / 2) % 2 == 0 ? 0 : 255
                let i = (y * width + x) * 3
                rgb[i] = value; rgb[i + 1] = value; rgb[i + 2] = value
            } }
        }
        return try #require(NativeSourcePhysicalInteriorContext(rgb: rgb, width: width, height: height,
            erased: [UInt8](repeating: 0, count: width * height),
            sourceIdentity: vetoSecondRun ? "synthetic-second-run-edges" : "synthetic-uniform-source", sourceOpaque: true))
    }

    private func exercise(_ fixture: Fixture, vetoSecondRun: Bool = false,
                          budget: J.SearchBudget = .init(), defect: FactoryDefect? = nil,
                          cancelSecondRun: Bool = false) throws -> Refinement {
        let context = try source(vetoSecondRun: vetoSecondRun)
        return try NativeSourcePhysicalInteriorContext.$cohortBoundaryContext.withValue(context) {
            try J.refine(layer: fixture.layer, baseline: fixture.tuple, texts: Self.texts,
                page: Self.page, restored: fixture.restored, budget: budget) { owner, width, pitch in
                if cancelSecondRun && owner.hasPrefix("b-") {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
                #expect(pitch == Self.pitch)
                var candidate = try shape(owner, width: width)
                switch defect {
                case .nonfiniteFrame: candidate.fill.frame.origin.x = .nan
                case .overflowRange: candidate.row["lineRangesUTF16"] = [[Int.max, Int.max]]
                case .nonfinitePitch: candidate.row["retainedLinePitchOutputPixels"] = Double.nan
                case nil: break
                }
                return candidate
            }
        }
    }

    private func rows(_ layer: L) throws -> [[String: Any]] {
        let rows = try #require(layer.audit["rawNativeItems"] as? [[String: Any]])
        try #require(rows.compactMap { $0["id"] as? String } == Self.owners)
        return rows
    }
    private func diagnostics(_ result: Refinement) throws -> [String: Any] {
        try #require(result.layer.audit["jointSourceWidthPacking"] as? [String: Any])
    }
    private func snapshotsMatch(_ before: J.Tuple, _ after: J.Tuple) throws {
        try #require(before.fills.count == Self.owners.count && before.audit.count == Self.owners.count)
        try #require(after.fills.count == Self.owners.count && after.audit.count == Self.owners.count)
        #expect(before.fills.compactMap(\.ownerID) == after.fills.compactMap(\.ownerID))
        for i in Self.owners.indices {
            let owner = Self.owners[i]
            let a = try S.decode(try #require(before.audit[i][S.auditKey]), owner: owner)
            let b = try S.decode(try #require(after.audit[i][S.auditKey]), owner: owner)
            #expect(a == b)
        }
    }
    private func firstRunMatches(_ expected: Refinement, _ actual: Refinement) throws {
        let oldRows = try rows(expected.layer), newRows = try rows(actual.layer)
        for i in Self.owners.indices where Self.owners[i].hasPrefix("a-") {
            #expect(NativeBodySourceAnchorRecovery.carrierPreserved(expected.baseline.fills[i], actual.baseline.fills[i], shift: .zero))
            #expect(try NativeMandatoryDisplayStroke.rgba(expected.baseline.fills[i].image)
                == NativeMandatoryDisplayStroke.rgba(actual.baseline.fills[i].image))
            #expect(NSDictionary(dictionary: oldRows[i]).isEqual(to: newRows[i]))
            let a = try N.retainedFootprint(expected.baseline.fills[i])
            let b = try N.retainedFootprint(actual.baseline.fills[i])
            #expect(a.bounds == b.bounds && a.pixels == b.pixels)
        }
    }

    @Test func twoDisjointRunsKeepFirstNativeSelectionAndFullRowMetadata() throws {
        let f = try fixture()
        #expect(J.sourceRuns(f.tuple.fills, page: Self.page) == [[1, 3], [2, 0]])
        let first = try exercise(f, budget: .init(factoryCalls: 128, proofChecks: 128, admissions: 1))
        let both = try exercise(f)
        let detail = try diagnostics(both)
        let runs = try #require(detail["runs"] as? [[String: Any]])
        #expect(runs.count == 2 && runs.allSatisfy { $0["status"] as? String == "selected" })
        #expect(detail["completeAdmissions"] as? Int == 2)
        #expect(both.changed == Set(Self.owners))
        try firstRunMatches(first, both)
        try snapshotsMatch(f.tuple, both.baseline)
        let actualRows = try rows(both.layer)
        #expect(actualRows.compactMap { $0["id"] as? String } == Self.owners)
        #expect(both.baseline.audit.compactMap { $0["owner"] as? String } == Self.owners)
        for owner in ["a-long", "b-long"] {
            let i = try #require(Self.owners.firstIndex(of: owner))
            #expect(try #require(actualRows[i]["lineRangesUTF16"] as? [[Int]]).count > 1)
            #expect(both.baseline.fills[i].fontOutputPixels == Self.font)
            #expect(J.number(actualRows[i]["retainedLinePitchOutputPixels"]) == Double(Self.pitch))
        }
    }

    @Test func secondRunOriginalBoundaryVetoRetainsFirstCommittedRowsAndPaint() throws {
        let f = try fixture()
        let first = try exercise(f, budget: .init(factoryCalls: 128, proofChecks: 128, admissions: 1))
        let veto = try exercise(f, vetoSecondRun: true)
        let detail = try diagnostics(veto)
        let runs = try #require(detail["runs"] as? [[String: Any]])
        #expect(runs.count == 2)
        let second = try #require(runs.last)
        #expect(runs.first?["status"] as? String == "selected")
        #expect(second["status"] as? String == "incumbent-retained")
        let attempts = try #require(second["attempts"] as? [[String: Any]])
        #expect(!attempts.isEmpty)
        #expect(attempts.contains { ($0["reason"] as? String)?.contains("preserved-source-boundary-veto") == true })
        #expect(detail["completeAdmissions"] as? Int == 1)
        #expect(veto.changed == Set(["a-long", "a-short"]))
        try firstRunMatches(first, veto)
        try snapshotsMatch(f.tuple, veto.baseline)
        let beforeRows = try rows(f.layer), afterRows = try rows(veto.layer)
        for i in Self.owners.indices where Self.owners[i].hasPrefix("b-") {
            #expect(NativeBodySourceAnchorRecovery.carrierPreserved(f.tuple.fills[i], veto.baseline.fills[i], shift: .zero))
            #expect(try NativeMandatoryDisplayStroke.rgba(f.tuple.fills[i].image)
                == NativeMandatoryDisplayStroke.rgba(veto.baseline.fills[i].image))
            #expect(NSDictionary(dictionary: beforeRows[i]).isEqual(to: afterRows[i]))
        }
    }

    @Test func exhaustedAdmissionOrFactoryBudgetStopsWithoutUndoingCommittedRun() throws {
        let f = try fixture()
        let first = try exercise(f, budget: .init(factoryCalls: 128, proofChecks: 128, admissions: 1))
        let detail = try diagnostics(first)
        #expect(detail["stoppedByBudget"] as? Bool == true)
        #expect(detail["completeAdmissions"] as? Int == 1)
        #expect(first.changed == Set(["a-long", "a-short"]))
        let runs = try #require(detail["runs"] as? [[String: Any]])
        #expect(runs.last?["status"] as? String == "search-budget-exhausted-before-run")
        let zero = try exercise(f, budget: .init(factoryCalls: 0, proofChecks: 128, admissions: 64))
        let noWork = try diagnostics(zero)
        #expect(noWork["factoryCalls"] as? Int == 0 && noWork["completeAdmissions"] as? Int == 0)
        #expect(zero.changed.isEmpty)
        #expect(NSDictionary(dictionary: f.layer.audit).isEqual(to: withoutJointDiagnostics(zero.layer)))
        try snapshotsMatch(f.tuple, first.baseline)
    }

    // Budget diagnostics are new, while every original layer field must remain.
    private func withoutJointDiagnostics(_ layer: L) -> [String: Any] {
        var audit = layer.audit
        audit.removeValue(forKey: "jointSourceWidthPacking")
        return audit
    }

    @Test func malformedInventoryRangesAndPitchRejectBeforeFactoryCalls() throws {
        let f = try fixture()
        for defect in InputDefect.allCases {
            var tuple = f.tuple, audit = f.layer.audit
            var raw = try rows(f.layer)
            switch defect {
            case .duplicateID: raw[1]["id"] = raw[0]["id"]
            case .auditOrder: tuple.audit.swapAt(0, 1)
            case .shortRange: raw[0]["lineRangesUTF16"] = [[0]]
            case .negativeRange: raw[0]["lineRangesUTF16"] = [[-1, 2]]
            case .overflowRange: raw[0]["lineRangesUTF16"] = [[Int.max, Int.max]]
            case .ownershipHole:
                raw[0]["lineRangesUTF16"] = [[1, 2]]
                raw[0]["actualCoreTextLineStrings"] = ["ES"]
            case .zeroPitch: raw[0]["retainedLinePitchOutputPixels"] = 0.0
            case .nanPitch: raw[0]["retainedLinePitchOutputPixels"] = Double.nan
            case .infinitePitch: raw[0]["retainedLinePitchOutputPixels"] = Double.infinity
            case .booleanPitch: raw[0]["retainedLinePitchOutputPixels"] = true
            }
            audit["rawNativeItems"] = raw
            let layer = L(image: f.layer.image, expectedItems: 4, paintedItems: 4, complete: true, audit: audit)
            var factoryCalls = 0
            #expect(throws: J.Failure.self) {
                _ = try J.refine(layer: layer, baseline: tuple, texts: Self.texts, page: Self.page, restored: f.restored) { _, _, _ in
                    factoryCalls += 1
                    return nil
                }
            }
            #expect(factoryCalls == 0)
        }
    }

    @Test func malformedFactoryRastersNeverReplaceAuthenticIncumbentShapes() throws {
        let f = try fixture()
        let originalRows = try rows(f.layer)
        for defect in FactoryDefect.allCases {
            let result = try exercise(f, defect: defect)
            let actualRows = try rows(result.layer)
            // A valid native translation of an incumbent remains permitted;
            // rejecting a bad factory output must not be confused with a veto
            // on independently admitted unchanged glyph shapes.
            for i in Self.owners.indices {
                let actualRanges = try #require(actualRows[i]["lineRangesUTF16"] as? [[Int]])
                let originalRanges = try #require(originalRows[i]["lineRangesUTF16"] as? [[Int]])
                #expect(actualRanges == originalRanges)
                #expect(try NativeMandatoryDisplayStroke.rgba(result.baseline.fills[i].image)
                    == NativeMandatoryDisplayStroke.rgba(f.tuple.fills[i].image))
            }
            let detail = try diagnostics(result)
            let runs = try #require(detail["runs"] as? [[String: Any]])
            let inventories = runs.compactMap { $0["generation"] as? [[String: Any]] }
                .flatMap { $0 }.compactMap { $0["shapes"] as? [[String: Any]] }
            #expect(!inventories.isEmpty && inventories.allSatisfy { $0.count == 1 })
            try snapshotsMatch(f.tuple, result.baseline)
        }
    }

    @Test func nativeCGFloatNumbersRemainValidButNonfiniteAndBooleanScalarsDoNot() {
        #expect(J.number(CGFloat(32)) == 32 && J.number(32.0) == 32 && J.number(NSNumber(value: 32)) == 32)
        #expect(J.number(Double.nan) == nil && J.number(Double.infinity) == nil)
        #expect(J.number(true) == nil && J.number(NSNumber(value: false)) == nil)
    }

    private func withoutDebugWitnesses(_ layer: L) -> L {
        var audit = layer.audit
        audit.removeValue(forKey: "finalGlyphWitnesses")
        return L(image: layer.image, expectedItems: layer.expectedItems,
            paintedItems: layer.paintedItems, complete: layer.complete, audit: audit)
    }

    @Test func typedPinVerificationCannotElideFramesOrRGBAWithoutDebugWitnesses() throws {
        let f = try fixture()
        let first = try exercise(f, budget: .init(factoryCalls: 128, proofChecks: 128, admissions: 1))
        let both = try exercise(f)
        let before = withoutDebugWitnesses(first.layer), after = withoutDebugWitnesses(both.layer)
        let changed = Set(["b-long", "b-short"])
        let proof = try J.verifyPinnedPeers(before: first.baseline, after: both.baseline,
            beforeLayer: before, afterLayer: after, changed: changed)
        #expect(proof["typedPeerChecks"] as? Int == 2)
        #expect(proof["fullSnapshotChecks"] as? Int == 4)
        #expect(proof["optionalPNGChecks"] as? Int == 0 && proof["debugCaptureRequired"] as? Bool == false)
        let peer = try #require(Self.owners.firstIndex(of: "a-long"))
        var moved = both.baseline
        moved.fills[peer].frame.origin.x += 1
        #expect(throws: J.Failure.self) {
            _ = try J.verifyPinnedPeers(before: first.baseline, after: moved,
                beforeLayer: before, afterLayer: after, changed: changed)
        }
        var recolored = both.baseline
        let image = recolored.fills[peer].image
        var rgba = try NativeMandatoryDisplayStroke.rgba(image)
        let alpha = try #require(stride(from: 3, to: rgba.count, by: 4).first { rgba[$0] == 255 })
        rgba[alpha - 3] = rgba[alpha - 3] == 0 ? 1 : 0 // Same alpha; different actual glyph RGB.
        recolored.fills[peer].image = try NativeMandatoryDisplayStroke.image(rgba, width: image.width, height: image.height)
        #expect(throws: J.Failure.self) {
            _ = try J.verifyPinnedPeers(before: first.baseline, after: recolored,
                beforeLayer: before, afterLayer: after, changed: changed)
        }
    }

    @Test func lateCancellationAtSecondFactoryIsNotConvertedToRetainedSuccess() async throws {
        let f = try fixture()
        let firstIndex = try #require(Self.owners.firstIndex(of: "a-long"))
        let initialHeight = f.tuple.fills[firstIndex].image.height
        var firstNativePaintObserved = false
        let observer = NativeAOTTranslationPageComposer.CompletedPaintObserver { _, fills, _ in
            if let first = fills.first(where: { $0.ownerID == "a-long" }), first.image.height > initialHeight {
                firstNativePaintObserved = true
            }
        }
        let task = Task { @MainActor in
            try NativeAOTTranslationPageComposer.$completedPaintObserver.withValue(observer) {
                _ = try exercise(f, cancelSecondRun: true)
            }
        }
        do {
            try await task.value
            Issue.record("Second-run cancellation was converted into a successful retained result")
        } catch is CancellationError { }
        #expect(firstNativePaintObserved)
    }
}
