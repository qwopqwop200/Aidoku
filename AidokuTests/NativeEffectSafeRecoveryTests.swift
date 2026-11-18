import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeEffectSafeRecoveryTests {
    private struct PitchFixture {
        let context: NativeEffectSafePitch.Context
        let font: CTFont
        let text: String
        let size: CGFloat = 24
        let width: CGFloat = 140

        func plan() throws -> NativeFinalTextFlow.Plan {
            try context.activate("first")
            var positionerCalls = 0
            let value = try NativeWholeWordWrap.withInitialWordObjective(false) {
                try NativeFinalTextFlow.horizontalFixedWidth(
                    text: text, font: font, size: size, width: width,
                    minimumLineHeight: 34.56, outwardExtent: 4, color: CGColor(gray: 0, alpha: 1),
                    preferWholeWords: true,
                    certifiedPositioner: { wrapped, width in
                        positionerCalls += 1
                        return try context.certify(wrapped).position(wrapped, width: width)
                    })
            }
            let plan = try #require(value)
            #expect(positionerCalls == 1)
            #expect(plan.complete && plan.visibleUTF16 == text.utf16.count)
            try #require(plan.lines.count > 1)
            return plan
        }

        func wrapAgain() throws -> NativeWholeWordWrap.Result {
            try NativeWholeWordWrap.layoutInternal(
                text: text, font: font, size: size, width: width,
                captionBoundaryRules: false, tracking: 0, color: CGColor(gray: 0, alpha: 1),
                necessaryCJK: true, preferWholeWords: true)
        }
    }

    private static func pitchFixture() throws -> PitchFixture {
        let size: CGFloat = 24
        let text = "한글 기준행\nÁgj 혼합행\nABCpq"
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, size, nil)
        let face = CTFontCopyPostScriptName(font) as String
        let raw: [String: Any] = [
            "sourceFontSize": 24.0,
            "ensembleStrokeRatio": 0.08,
            "ensembleDisplayStroke": [255.0, 255.0, 255.0],
            "sourceAppearance": ["outline": ["present": true, "widthPx": 2.0, "rgb": [255.0, 255.0, 255.0]]]
        ]
        let style = try NativeSourceStylePaint.style(raw)
        let configs = [
            NativeEffectSafePitch.Config(owner: "first", text: text, font: size, face: face,
                family: "shared", minimum: 34.56, raw: raw, style: style, sourceOnly: false),
            NativeEffectSafePitch.Config(owner: "second", text: text, font: size, face: face,
                family: "shared", minimum: 48, raw: raw, style: style, sourceOnly: false)
        ]
        let context = try NativeEffectSafePitch.Context(configs, page: CGRect(x: 0, y: 0, width: 400, height: 400))
        return PitchFixture(context: context, font: font, text: text)
    }

    @Test(arguments: [CGFloat(0), 0.25, 0.5, 0.75])
    func explicitPositionerRetainsCertificateAndVerifiesActualPaintPhase(phase: CGFloat) throws {
        let fixture = try Self.pitchFixture()
        let plan = try fixture.plan()
        let certificate = try #require(fixture.context.certificate(lines: plan.lines))
        #expect(certificate.owner == "first")
        #expect(certificate.pitch >= 48)
        for i in plan.baselines.indices.dropFirst() {
            #expect(abs(plan.baselines[i].y - plan.baselines[i - 1].y - certificate.pitch) < 0.000001)
        }
        try fixture.context.verify(lines: plan.lines, ranges: plan.ranges, origins: plan.baselines,
            box: CGRect(x: phase, y: phase, width: fixture.width, height: plan.size.height), font: fixture.size)
        #expect(fixture.context.finalChecks == 1)
        #expect(fixture.context.audit["actualGuardAndSourceBandsUnchanged"] as? Bool == true)
        #expect(fixture.context.audit["typedRowOwnershipRequired"] as? Bool == true)
    }

    @Test func flowWithoutPositionerDoesNotAcquireAnImplicitPitchCertificate() throws {
        let fixture = try Self.pitchFixture()
        try fixture.context.activate("first")
        let result = try NativeEffectSafePitch.$current.withValue(fixture.context) {
            try NativeFinalTextFlow.horizontalFixedWidth(
                text: fixture.text, font: fixture.font, size: fixture.size, width: fixture.width,
                minimumLineHeight: 34.56, outwardExtent: 4, color: CGColor(gray: 0, alpha: 1),
                preferWholeWords: true, certifiedPositioner: nil)
        }
        let plan = try #require(result)
        #expect(plan.complete)
        #expect(fixture.context.certificate(lines: plan.lines) == nil)
        #expect(fixture.context.finalChecks == 0)
    }

    private enum PositionerFailure: Error { case rejected }

    @Test func explicitPositionerFailurePropagatesWithoutUncertifiedFallback() throws {
        let fixture = try Self.pitchFixture()
        var invoked = false
        #expect(throws: PositionerFailure.self) {
            _ = try NativeFinalTextFlow.horizontalFixedWidth(
                text: fixture.text, font: fixture.font, size: fixture.size, width: fixture.width,
                minimumLineHeight: 34.56, outwardExtent: 4, color: CGColor(gray: 0, alpha: 1),
                preferWholeWords: true, certifiedPositioner: { _, _ in
                    invoked = true
                    throw PositionerFailure.rejected
                })
        }
        #expect(invoked)
    }

    @Test func familyProofEnforcesRequestedMinimumAndOneCommonPitch() throws {
        let fixture = try Self.pitchFixture()
        let plan = try fixture.plan()
        let certificate = try #require(fixture.context.certificate(lines: plan.lines))
        let pitch = Double(certificate.pitch)
        try fixture.context.validateFamilies([
            ["id": "first", "retainedLinePitchOutputPixels": pitch],
            ["id": "second", "retainedLinePitchOutputPixels": pitch]
        ])
        #expect(throws: NativeEffectSafePitch.Failure.self) {
            try fixture.context.validateFamilies([
                ["id": "first", "retainedLinePitchOutputPixels": pitch],
                ["id": "second", "retainedLinePitchOutputPixels": pitch + 1]
            ])
        }
        #expect(throws: NativeEffectSafePitch.Failure.self) {
            try fixture.context.validateFamilies([["id": "first", "retainedLinePitchOutputPixels": pitch - 1]])
        }
    }

    @Test func certificateRejectsOverlappingRowsBeforeSuccessfulFinalCheck() throws {
        let fixture = try Self.pitchFixture()
        let plan = try fixture.plan()
        let collapsed = plan.baselines.map { CGPoint(x: $0.x, y: 0) }
        #expect(throws: NativeEffectSafePitch.Failure.self) {
            try fixture.context.verify(lines: plan.lines, ranges: plan.ranges, origins: collapsed,
                box: .zero, font: fixture.size)
        }
        #expect(fixture.context.finalChecks == 0)
    }

    @Test func certificateRejectsChangedUTF16OwnershipAndFont() throws {
        let fixture = try Self.pitchFixture()
        let plan = try fixture.plan()
        var ranges = plan.ranges
        ranges[0].length += 1
        #expect(throws: NativeEffectSafePitch.Failure.self) {
            try fixture.context.verify(lines: plan.lines, ranges: ranges, origins: plan.baselines,
                box: .zero, font: fixture.size)
        }
        #expect(throws: NativeEffectSafePitch.Failure.self) {
            try fixture.context.verify(lines: plan.lines, ranges: plan.ranges, origins: plan.baselines,
                box: .zero, font: fixture.size + 1)
        }
        #expect(fixture.context.finalChecks == 0)
    }

    @Test func certificateCannotAuthorizeNewCTLinesEvenWithIdenticalTextAndRanges() throws {
        let fixture = try Self.pitchFixture()
        let plan = try fixture.plan()
        let certificate = try #require(fixture.context.certificate(lines: plan.lines))
        let fresh = try fixture.wrapAgain()
        #expect(fresh.text == fixture.text)
        #expect(fresh.rows.map(\.ownedRange) == plan.ranges)
        #expect(throws: NativeEffectSafePitch.Failure.self) {
            _ = try certificate.position(fresh, width: fixture.width)
        }
    }

    enum OriginScenario: CaseIterable, Sendable {
        case disjointBands, bodySourceAndPeer, fixedOrigin, lockedCluster
    }

    private static let originPage = CGRect(x: 0, y: 0, width: 20, height: 20)

    private static func originFootprint() -> NativeFinalTextPaintAdmission.Footprint {
        NativeFinalTextPaintAdmission.Footprint(
            runs: [.init(y: 0, left: 0, right: 3), .init(y: 1, left: 1, right: 5), .init(y: 3, left: 2, right: 4)],
            bounds: CGRect(x: 0, y: 0, width: 5, height: 4), pixels: 9)
            .translated(CGPoint(x: 6, y: 7))
    }

    private static func originPolicy() -> NativeTextExpansionPolicy {
        NativeTextExpansionPolicy(
            allowedRectNormalized: [0, 0, 1, 1], candidates: [[0, 0, 1, 1]], maskCoverage: [1],
            backgroundRisk: [0], sourceFontPixels: 5, kind: "inside-balloon-mask",
            maskRectNormalized: [0, 0, 1, 1],
            maskSpansNormalized: [0.05, 0.9, 0.1, 0.85, 0.075, 0.925, 0.15, 0.9],
            maskIntervalRowsNormalized: [[0.05, 0.4, 0.5, 0.9], [0.1, 0.85], [0.075, 0.4, 0.55, 0.925], [0.15, 0.9]])
    }

    @Test(arguments: OriginScenario.allCases)
    func exactOriginsMatchExhaustiveNativePredicate(scenario: OriginScenario) throws {
        let footprint = Self.originFootprint()
        let policy = Self.originPolicy()
        try #require(policy.valid)
        let body: CGRect? = scenario == .bodySourceAndPeer ? CGRect(x: 3, y: 4, width: 13, height: 12) : nil
        let fixed: CGPoint? = scenario == .fixedOrigin ? CGPoint(x: 3, y: 3) : nil
        let cluster: (NativeSourceClusterAlignment.Axis, CGFloat)? = scenario == .lockedCluster ? (.left, 7) : nil
        func valid(_ support: NativeFinalTextPaintAdmission.Footprint) -> Bool {
            Self.originPage.insetBy(dx: 1, dy: 1).contains(support.bounds) &&
                support.bounds.minX >= 2 && support.bounds.minY >= 3 &&
                (body?.contains(support.bounds) ?? true) &&
                !support.bounds.intersects(CGRect(x: 10, y: 8, width: 3, height: 4)) &&
                support.runs.allSatisfy {
                    policy.allows(CGRect(x: $0.left, y: $0.y, width: $0.right - $0.left, height: 1), page: Self.originPage)
                }
        }
        let result = try NativeExactAlphaOrigins.make(footprint, page: Self.originPage, margin: 1,
            policy: policy, body: body, fixedOrigin: fixed, cluster: cluster, budget: .init(), validate: valid)
        // Independent exhaustive oracle: call the native predicate, never duplicate interval intersection.
        var expected = Set<String>()
        for dy in -20...20 {
            for dx in -20...20 {
                let shift = CGPoint(x: dx, y: dy)
                let support = footprint.translated(shift)
                if let fixed, support.bounds.origin != fixed { continue }
                if let cluster, support.bounds.minX != cluster.1 { continue }
                if valid(support) { expected.insert(Self.originKey(shift)) }
            }
        }
        try #require(!expected.isEmpty)
        #expect(result.status == .complete)
        #expect(Set(result.shifts.map(Self.originKey)) == expected)
    }

    private static func originKey(_ shift: CGPoint) -> String { "\(Int(shift.x)),\(Int(shift.y))" }

    @Test func exactOriginBudgetExhaustionReturnsUnknownWithoutCandidates() throws {
        let budget = NativeExactAlphaOrigins.Budget()
        #expect(budget.charge(1_000_000))
        var validations = 0
        let result = try NativeExactAlphaOrigins.make(Self.originFootprint(), page: Self.originPage, margin: 1,
            policy: Self.originPolicy(), body: nil, fixedOrigin: nil, cluster: nil, budget: budget,
            validate: { _ in validations += 1; return true })
        #expect(result.status == .unknown && result.shifts.isEmpty)
        #expect(validations == 0)
        #expect(budget.remaining == 0)
        #expect(!budget.charge(1))
    }

    @Test func oversizedExactOriginDomainIsUnknownRatherThanAnAcceptedPrefix() throws {
        let policy = NativeTextExpansionPolicy(
            allowedRectNormalized: [0, 0, 1, 1], candidates: [[0, 0, 1, 1]], maskCoverage: [1],
            backgroundRisk: [0], sourceFontPixels: 5, kind: "inside-balloon-mask",
            maskRectNormalized: [0, 0, 1, 1], maskSpansNormalized: [0, 1, 0, 1])
        try #require(policy.valid)
        var validations = 0
        let result = try NativeExactAlphaOrigins.make(Self.originFootprint(),
            page: CGRect(x: 0, y: 0, width: 40, height: 40), margin: 1,
            policy: policy, body: nil, fixedOrigin: nil, cluster: nil, budget: .init(),
            validate: { _ in validations += 1; return true })
        #expect(result.status == .unknown && result.reason == "origin-budget")
        #expect(result.shifts.isEmpty && validations == 0)
    }

    @Test func nativeValidatorCanRejectAnOtherwiseAvailableMaskOrigin() throws {
        var validations = 0
        let result = try NativeExactAlphaOrigins.make(Self.originFootprint(), page: Self.originPage, margin: 1,
            policy: Self.originPolicy(), body: nil, fixedOrigin: CGPoint(x: 3, y: 3), cluster: nil,
            budget: .init(), validate: { _ in validations += 1; return false })
        #expect(validations == 1)
        #expect(result.status == .complete && result.shifts.isEmpty)
    }

    @Test func malformedRunsAndFractionalFixedOriginsRemainUnknown() throws {
        let malformed = NativeFinalTextPaintAdmission.Footprint(
            runs: [.init(y: Int.min, left: 0, right: 3)], bounds: CGRect(x: 0, y: 0, width: 3, height: 1), pixels: 3)
        let rejected = try NativeExactAlphaOrigins.make(malformed, page: Self.originPage, margin: 1,
            policy: Self.originPolicy(), body: nil, fixedOrigin: nil, cluster: nil, budget: .init(), validate: { _ in true })
        #expect(rejected.status == .unknown && rejected.shifts.isEmpty)
        let fractional = try NativeExactAlphaOrigins.make(Self.originFootprint(), page: Self.originPage, margin: 1,
            policy: Self.originPolicy(), body: nil, fixedOrigin: CGPoint(x: 3.5, y: 3), cluster: nil,
            budget: .init(), validate: { _ in true })
        #expect(fractional.status == .unknown && fractional.reason == "fractional-fixed-origin")
        #expect(fractional.shifts.isEmpty)
    }

    @Test func exactOriginCancellationPropagates() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let result = try NativeExactAlphaOrigins.make(Self.originFootprint(), page: Self.originPage, margin: 1,
                policy: Self.originPolicy(), body: nil, fixedOrigin: nil, cluster: nil,
                budget: .init(), validate: { _ in true })
            return result.shifts.isEmpty
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func exactOriginsKeepAnActiveBodyRigidWithItsConfiguredGap() throws {
        let page = CGRect(x: 0, y: 0, width: 128, height: 128)
        let context = try #require(CGContext(data: nil, width: 5, height: 5, bitsPerComponent: 8, bytesPerRow: 20,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 5, height: 5))
        let image = try #require(context.makeImage())
        let packets = (0..<2).map { order in
            NativeBalloonPlacement(crossAlignment: .center, bodyID: "neutral-body",
                rectNormalized: [0.125, 0.125, 0.5, 0.5], biasNormalized: [0, 0], flow: .column,
                paddingEm: 0, gapEm: 0.12, maskSHA256: String(repeating: "0", count: 64), order: order)
        }
        let bounds = Array(repeating: CGRect(x: 0, y: 0, width: 5, height: 5), count: 2)
        let targets = try NativeBalloonPlacement.targets(packets.map { Optional($0) },
            bounds: bounds, fonts: [24, 24], page: page)
        var fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive] = []
        for i in 0..<2 {
            let target = try #require(targets[i])
            let desired = CGPoint(x: target.x + 1, y: target.y + 1)
            let rect = [Double(desired.x / 128), Double(desired.y / 128), 5.0 / 128, 5.0 / 128]
            let interval = [Double(desired.x / 128), Double((desired.x + 5) / 128)]
            let policy = NativeTextExpansionPolicy(
                allowedRectNormalized: [0.125, 0.125, 0.5, 0.5], candidates: [rect], maskCoverage: [1],
                backgroundRisk: [0], sourceFontPixels: 24, kind: "inside-balloon-mask",
                maskRectNormalized: rect, maskSpansNormalized: interval + interval)
            try #require(policy.valid)
            var fill = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(
                image: image, frame: bounds[i], fontOutputPixels: 24)
            fill.ownerID = "neutral-\(i)"
            fill.hasFinalEffects = true
            fill.balloonPlacement = packets[i]
            fill.textExpansionPolicy = policy
            fill.placementDomain = { policy.allows($0, page: page) }
            fills.append(fill)
        }
        let result = try NativeExactAlphaOrigins.$enabled.withValue(true) {
            try NativeFinalTextPaintAdmission.place(fills, page: page)
        }
        let expectedRGBA = try NativeMandatoryDisplayStroke.rgba(image)
        for i in 0..<2 {
            let target = try #require(targets[i])
            #expect(result.fills[i].frame.origin == CGPoint(x: target.x + 1, y: target.y + 1))
            #expect(result.fills[i].fontOutputPixels == 24)
            #expect(result.audit[i]["balloonBodyPlaced"] as? Bool == true)
            #expect(result.audit[i]["balloonTargetRelaxed"] as? Bool == false)
            let evidence = try #require(result.audit[i]["exactAlphaCandidateEvidence"] as? [String: Any])
            #expect(evidence["rigidBodyCommonOrigins"] as? Int == 1)
            let actualRGBA = try NativeMandatoryDisplayStroke.rgba(result.fills[i].image)
            #expect(actualRGBA == expectedRGBA)
        }
        #expect(result.fills[1].frame.minY - result.fills[0].frame.maxY == 3)
    }

    private static func beginRecovery(_ ledger: NativeRecoveryDrawBudget.Ledger) {
        ledger.beginRecovery(after: NSError(domain: "neutral-recovery-test", code: 1))
    }

    @Test func ordinaryDrawsDoNotConsumeTheAdditionalOwnerFontAllowance() throws {
        let ledger = NativeRecoveryDrawBudget.Ledger()
        for _ in 0..<10 { try ledger.chargeDraw(owner: "owner", fontPixels: 24) }
        #expect(!ledger.recoveryActive && ledger.additionalDraws == 0)
        Self.beginRecovery(ledger)
        #expect(ledger.remaining(owner: "owner", fontPixels: 24) == 8)
        for _ in 0..<8 { try ledger.chargeDraw(owner: "owner", fontPixels: 24, stage: "measured-pitch") }
        #expect(throws: NativeRecoveryDrawBudget.Failure.self) {
            try ledger.chargeDraw(owner: "owner", fontPixels: 24)
        }
        #expect(ledger.remaining(owner: "owner", fontPixels: 24) == 0)
        #expect(ledger.remaining(owner: "owner", fontPixels: 25) == 8)
        #expect(ledger.remaining(owner: "other", fontPixels: 24) == 8)
        #expect(ledger.audit["ordinaryDraws"] as? Int == 10)
        #expect(ledger.audit["recoveryDraws"] as? Int == 8)
        #expect(ledger.audit["totalDraws"] as? Int == 18)
        #expect(ledger.audit["rejectedDrawRequests"] as? Int == 1)
        #expect(ledger.audit["ordinaryAndRecoveryCombinedBudgetUnchanged"] as? Bool == false)
    }

    @Test func additionalPageLimitIsSharedAcrossOwners() throws {
        let ledger = NativeRecoveryDrawBudget.Ledger()
        Self.beginRecovery(ledger)
        for owner in 0..<16 {
            for _ in 0..<8 { try ledger.chargeDraw(owner: "owner-\(owner)", fontPixels: 24) }
        }
        #expect(ledger.additionalDraws == 128)
        #expect(ledger.remaining(owner: "unused", fontPixels: 24) == 0)
        #expect(throws: NativeRecoveryDrawBudget.Failure.self) {
            try ledger.chargeDraw(owner: "unused", fontPixels: 24)
        }
        #expect(ledger.additionalDraws == 128)
        #expect(ledger.audit["totalDraws"] as? Int == 128)
    }

    @Test func beginningRecoveryAgainPreservesSpentCreditsAndOriginalFailure() throws {
        let ledger = NativeRecoveryDrawBudget.Ledger()
        let original = NSError(domain: "neutral-recovery-test", code: 1)
        ledger.beginRecovery(after: original)
        try ledger.chargeDraw(owner: "owner", fontPixels: 24)
        ledger.beginRecovery(after: NSError(domain: "neutral-recovery-test", code: 2))
        let remembered = try #require(ledger.legacyFailure as? NSError)
        #expect(remembered === original)
        #expect(ledger.recoveryActive && ledger.remaining(owner: "owner", fontPixels: 24) == 7)
    }

    @Test func nativeMetricsScopesCannotReplenishTheWholePageDrawLedger() throws {
        let ledger = NativeRecoveryDrawBudget.Ledger()
        Self.beginRecovery(ledger)
        try NativeRecoveryDrawBudget.$current.withValue(ledger) {
            try NativeFixedFontRecovery.withMetrics {
                try NativeRecoveryDrawBudget.current?.chargeDraw(owner: "owner", fontPixels: 24)
            }
            try NativeFixedFontRecovery.withMetrics {
                try NativeRecoveryDrawBudget.current?.chargeDraw(owner: "owner", fontPixels: 24)
            }
        }
        #expect(ledger.additionalDraws == 2)
        #expect(ledger.remaining(owner: "owner", fontPixels: 24) == 6)
    }

    @Test func malformedDrawRequestsDoNotChangeCounters() throws {
        let ledger = NativeRecoveryDrawBudget.Ledger()
        Self.beginRecovery(ledger)
        for size: CGFloat in [0, -1, .nan, .infinity, 2049] {
            #expect(throws: NativeRecoveryDrawBudget.Failure.self) {
                try ledger.chargeDraw(owner: "owner", fontPixels: size)
            }
        }
        #expect(ledger.additionalDraws == 0)
        #expect(ledger.audit["ordinaryDraws"] as? Int == 0)
    }

    @Test func cancelledDrawRequestsDoNotSpendRecoveryCredits() async {
        let ledger = NativeRecoveryDrawBudget.Ledger()
        Self.beginRecovery(ledger)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try ledger.chargeDraw(owner: "owner", fontPixels: 24)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ledger.additionalDraws == 0)
        #expect(ledger.remaining(owner: "owner", fontPixels: 24) == 8)
    }
}
