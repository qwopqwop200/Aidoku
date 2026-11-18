import CoreGraphics
import CoreText
import Foundation

/// Minimal native baseline, not the admitted final layout solver. The new route
/// never invokes prepareTextBoxes or paints panels. Subsequent workers provide
/// independently validated capacity/group proposals through this item boundary.
enum NativeAOTRawTextPainter {
    @TaskLocal private static var simpleRFPlacement: NativeSimpleRFBalloonPlacement?
    @TaskLocal private static var simpleRFOutputScale: CGSize?
    /// Qualified source contours use round joins by default; explicit zero
    /// rolls back. Ordinary strokes and unbound styles retain miter joins.
    static var roundedSourceJoinsEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_ROUNDED_SOURCE_JOINS"] != "0"
    }

    @discardableResult
    static func configureRoundedSourceJoins(in context: CGContext, sourceContourOnly: Bool,
                                           sourceOutlinePresent: Bool, enabled: Bool) -> Bool {
        guard enabled, sourceContourOnly, sourceOutlinePresent else { return false }
        context.setLineJoin(.round)
        return true
    }
    @TaskLocal private static var constrainedShapeRetryOverride: Bool?

    static func withConstrainedShapeCapacityRetry<Value>(_ enabled: Bool,
                                                        operation: () throws -> Value) rethrows -> Value {
        try $constrainedShapeRetryOverride.withValue(enabled, operation: operation)
    }

    private static var constrainedShapeCapacityRetryEnabled: Bool {
        constrainedShapeRetryOverride ??
            (ProcessInfo.processInfo.environment["AIDOKU_CONSTRAINED_SHAPE_CAPACITY_RETRY"] == "1")
    }
    struct Item {
        let id: String
        let text: String
        let frame: CGRect // top-left logical page coordinates
        let fontSize: CGFloat
        let lineHeight: CGFloat
        let chosenFill: CGColor // original prediction decision, BEFORE shaping
        let colorAuthority: String
    }
    enum Failure: Error { case invalidGeometry, incompleteText(String), allocation, invalidSourceWeight }
    private static func invalidGeometry(line:UInt = #line)->Failure {
        if ProcessInfo.processInfo.environment["AIDOKU_TRACE_RAW_GEOMETRY"] == "1" {
            fputs("Raw renderer invalid geometry at line \(line)\n",stderr)
        }
        return .invalidGeometry
    }

    /// Resolve before line measurement, so fitting and final paint use the same
    /// face. Legacy requests without a source decision retain their old face.
    static func sourceFontName(raw: [String:Any]?) throws -> String {
        let labelValue=raw?["sourceFontWeight"],boldValue=raw?["renderBold"]
        let hasLabel=labelValue != nil && !(labelValue is NSNull)
        let hasBold=boldValue != nil && !(boldValue is NSNull)
        guard hasLabel || hasBold else {return "AppleSDGothicNeo-Medium"}
        var label:String?,explicit:Bool?
        if hasLabel {
            guard let value=labelValue as? String,["regular","bold","mixed"].contains(value) else {throw Failure.invalidSourceWeight}
            label=value
        }
        if hasBold {
            guard let value=boldValue as? NSNumber,CFGetTypeID(value)==CFBooleanGetTypeID() else {throw Failure.invalidSourceWeight}
            explicit=value.boolValue
        }
        let selected=label.map {$0=="bold"} ?? explicit!
        if let label,let explicit,explicit != (label=="bold") {throw Failure.invalidSourceWeight}
        return selected ? "AppleSDGothicNeo-Bold":"AppleSDGothicNeo-Regular"
    }

    static func render(items: [Item], viewport: CGSize, restored: CGImage, allowShrink: Bool = false) throws -> NativeAOTTranslationPageComposer.TextLayer {
        try NativeOperationalAppearance.withChosenFills(items.map { ($0.id,$0.chosenFill) }) {
            try renderImpl(items: items, viewport: viewport, restored: restored, allowShrink: allowShrink, contours: [:])
        }
    }

    static func renderCentered(items: [Item], rawItems: [[String: Any]], viewport: CGSize,
                               restored: CGImage, allowShrink: Bool = false,
                               completePeerContext:Bool=true,
                               simplePlacement: NativeSimpleRFBalloonPlacement? = nil) throws -> NativeAOTTranslationPageComposer.TextLayer {
        try $simpleRFPlacement.withValue(simplePlacement) {
            try $simpleRFOutputScale.withValue(CGSize(width: CGFloat(restored.width) / viewport.width,
                height: CGFloat(restored.height) / viewport.height)) {
                try NativeOperationalAppearance.withChosenFills(items.map { ($0.id,$0.chosenFill) }) {
                    try renderCenteredWithChosenFills(items:items,rawItems:rawItems,viewport:viewport,
                        restored:restored,allowShrink:allowShrink,completePeerContext:completePeerContext)
                }
            }
        }
    }

    private static func renderCenteredWithChosenFills(items: [Item], rawItems: [[String: Any]], viewport: CGSize,
                               restored: CGImage, allowShrink: Bool,
                               completePeerContext:Bool) throws -> NativeAOTTranslationPageComposer.TextLayer {
        var contours: [String: NativeRawBalloonCapacity.Contour] = [:]
        let angleSourceContext=NativeSourceObstructionRecovery.sourceContext ??
            NativeSourcePhysicalInteriorContext.cohortBoundaryContext ?? NativeSourcePhysicalInteriorContext.current
        let angleAlignedRawOptions=NativeTextAlignmentPolicy.annotate(NativeOperationalAppearance.annotateContourPolicies(rawItems))
        let orientedRawOptions=NativeSourceTextRotation.annotate(angleAlignedRawOptions,
            pageSize:angleSourceContext?.sourcePageSize ?? viewport,
            pixelObservation:{raw,guide in angleSourceContext?.sourceTextRotation(raw:raw,guide:guide)})
        let options=Dictionary(uniqueKeysWithValues:orientedRawOptions.compactMap { raw -> (String,[String:Any])? in
            (raw["id"] as? String).map {($0,raw)} })
        for raw in rawItems {
            guard let id = raw["id"] as? String,
                  let contour = NativeEnsembleLayoutContour.contour(raw: raw, viewport: viewport) else { continue }
            contours[id] = contour
        }
        // A shared balloon can contain distinct paragraphs; never center each one independently.
        let sharedIDs = contours.compactMap { id, own -> String? in
            contours.contains(where: { otherID, other in
                guard otherID != id else { return false }
                let shared = own.rect.intersection(other.rect)
                return !shared.isNull && shared.width * shared.height >
                    min(own.rect.width * own.rect.height, other.rect.width * other.rect.height) * 0.5
            }) ? id : nil
        }
        for id in sharedIDs { contours.removeValue(forKey: id) }
        func legacyPage()throws->NativeAOTTranslationPageComposer.TextLayer {
            try NativeWholeWordWrap.withInitialWordObjective(
                ProcessInfo.processInfo.environment["AIDOKU_INITIAL_WORD_OBJECTIVE"] != "0") {
                try NativeTerminalRoundedSourcePaint.afterOuterSelection(
                    enabled:roundedSourceJoinsEnabled && NativeSourceStylePaint.roundedContourBindingEnabled,
                    restored:restored,declaredStyleCohorts:NativeTerminalRoundedSourcePaint.styleCohorts(rawItems)) {
                    try NativeJointSourceWidthPacking.afterSelection {
                        try renderImpl(items:items,viewport:viewport,restored:restored,
                            allowShrink:allowShrink,contours:contours,options:options,completePeerContext:completePeerContext)
                    }
                }
            }
        }
        let enabled=(ProcessInfo.processInfo.environment["AIDOKU_EXACT_ALPHA_EFFECT_PITCH"] ?? "1") == "1"
        guard enabled,completePeerContext,!allowShrink else {return try legacyPage()}
        let ledger=NativeRecoveryDrawBudget.Ledger()
        return try NativeRecoveryDrawBudget.$current.withValue(ledger) {
            defer {ledger.reportIfRequested()}
            do {return try legacyPage()}
            catch is CancellationError {throw CancellationError()}
            catch {
                let original=error
                guard error is FixedFontRecoveryFailure || {
                    if case NativeFinalTextPaintAdmission.Failure.noSafePlacement = error {return true};return false
                }() else {throw original}
                ledger.beginRecovery(after:original)
                do {
                    let recovered=try NativeExactAlphaOrigins.$enabled.withValue(true) {
                        try NativeEffectSafePitch.$fallbackEnabled.withValue(true) {try legacyPage()}
                    }
                    var audit=recovered.audit;audit["recoveryDrawBudget"]=ledger.audit
                    return .init(image:recovered.image,expectedItems:recovered.expectedItems,
                        paintedItems:recovered.paintedItems,complete:recovered.complete,audit:audit)
                } catch is CancellationError {throw CancellationError()}
                catch {
                    try Task.checkCancellation()
                    // Keep the incumbent failure contract, but do not discard the
                    // REAL later phase cause/ledger required for bounded diagnosis.
                    if var incumbent = original as? FixedFontRecoveryFailure {
                        incumbent.diagnostics["exactEffectPhaseFailure"] = String(reflecting:error)
                        incumbent.diagnostics["exactEffectPhaseLedger"] = ledger.audit
                        if let actual = error as? FixedFontRecoveryFailure {
                            incumbent.diagnostics["exactEffectPhaseDiagnostics"] = actual.diagnostics
                        }
                        throw incumbent
                    }
                    throw original
                }
            }
        }
    }

    /// Display orientation is explicit. Source Japanese direction does not
    /// silently turn a horizontal translated paragraph into vertical writing.
    static func vertical(_ raw: [String: Any]?) -> Bool {
        raw?["vertical"] as? Bool == true || raw?["writingMode"] as? String == "vertical-rl"
    }

    static func protectedRects(rawItems: [[String: Any]], viewport: CGSize, scale: CGFloat) -> [CGRect] {
        rawItems.compactMap { raw in
            guard raw["keptLettering"] as? Bool == true || raw["sourceTextOnly"] as? Bool == true,
                  let b = raw["sourceBounds"] as? [Double], b.count == 4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0 else { return nil }
            return CGRect(x: b[0] * viewport.width * scale, y: b[1] * viewport.height * scale,
                width: b[2] * viewport.width * scale, height: b[3] * viewport.height * scale)
        }
    }

    static func placementDomain(raw: [String: Any], viewport: CGSize, scale: CGFloat,
                                protected: [CGRect] = [],
                                simplePlacement: NativeSimpleRFBalloonPlacement? = nil,
                                outputScaleY: CGFloat? = nil) -> ((CGRect) -> Bool)? {
        let exact: NativeSimpleRFBalloonPlacement.Constraint?
        do { exact = try (simplePlacement ?? simpleRFPlacement)?.constraint(for: raw, viewport: viewport) }
        catch { return { _ in false } }
        var contains: ((CGRect) -> Bool)?
        if raw["renderPreserveRequestedFontSize"] as? Bool != true,
           let descriptor = raw["originalClosedSurfaceCapacity"] as? [String: Any],
           let r = descriptor["slotNormalized"] as? [Double], r.count == 4 {
            let box = CGRect(x: r[0] * viewport.width * scale, y: r[1] * viewport.height * scale,
                width: r[2] * viewport.width * scale, height: r[3] * viewport.height * scale)
            contains = { box.contains($0) }
        } else if let contour = NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) {
            // Estimated RF spans remain proposals, not a verified clipping domain.
            contains = { contour.contains(CGRect(x: $0.minX / scale, y: $0.minY / scale,
                width: $0.width / scale, height: $0.height / scale)) }
        }
        guard contains != nil || exact != nil || !protected.isEmpty else { return nil }
        let font = (raw["fontSize"] as? NSNumber).map { CGFloat($0.doubleValue) * scale } ?? 0
        let nativeMask = renderMaskSurface(raw: raw, viewport: viewport, scale: scale) != nil
        let exactScale = CGSize(width: scale, height: outputScaleY ?? simpleRFOutputScale?.height ?? scale)
        let padding = nativeMask ? max(2,font*0.2)
            : (font.isFinite && font > 0 ? NativeTextSpacing.padding(fontSize:font) : 1)
        return { rect in
            (contains?(rect.insetBy(dx:-padding,dy:-padding)) ?? true)
                && (exact?.contains(outputRect: rect, outputScale: exactScale, viewport: viewport) ?? true)
                && !protected.contains { $0.intersects(rect) }
        }
    }

    /// A native source-mask receipt carries strict boundary authority. Generic
    /// estimated RF contours retain their existing proposal-only behavior.
    static func renderMaskSurface(raw: [String: Any]?, viewport: CGSize, scale: CGFloat)
        -> NativeTextBoxContainment.Surface? {
        guard let raw, scale.isFinite, scale > 0,
              let obj = raw["balloonInterior"] as? [String: Any],
              let hash = obj["nativeMaskSHA256"] as? String, hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit }),
              let contour = NativeRawBalloonCapacity.connectedContour(raw: raw, viewport: viewport) else { return nil }
        let surface = NativeTextBoxContainment.Surface(
            rect: contour.rect.applying(CGAffineTransform(scaleX: scale,y: scale)),
            spans: contour.spans.map { ($0.0*scale,$0.1*scale) }, color: nil)
        return surface.certifiedSpans ? surface : nil
    }

    private static func sourceGuardedAttempt(items:[Item],viewport:CGSize,restored:CGImage,allowShrink:Bool,
        contours:[String:NativeRawBalloonCapacity.Contour],options:[String:[String:Any]],
        outputWidthPlans:[String:NativeOwnerOutputWidthPlan]=[:],capturePreparedFailure:Bool=false)throws
        ->(value:NativeAOTTranslationPageComposer.TextLayer,excludedOwners:Set<String>,primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive]) {
        let groups=Dictionary(uniqueKeysWithValues:items.compactMap {item -> (String,String)? in
            guard let raw=options[item.id],let policy=raw["textExpansionPolicy"]as?[String:Any],
                  policy["kind"]as?String=="source-near-limited-expansion",
                  raw["textPlacementGuide"]is[String:Any] else{return nil}
            let group=(raw["sourceClusterAlignment"]as?[String:Any])?["groupID"]as?String ?? "owner:"+item.id
            return (item.id,group)
        })
        let eligible=Set(groups.keys),page=CGRect(x:0,y:0,width:restored.width,height:restored.height)
        let scale=CGFloat(restored.width)/viewport.width
        var legacyRefinementOwners=Set<String>()
        typealias AttemptResult=(value:NativeAOTTranslationPageComposer.TextLayer,excludedOwners:Set<String>,primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive])
        var establishedReference:AttemptResult?
        func attempt(_ disabled:Set<String>)throws->(value:NativeAOTTranslationPageComposer.TextLayer,excludedOwners:Set<String>,primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive]) {
            let result=try NativeFinalTextFlow.withOwnerRefinementFallback(rejectedOwners:{error in
                guard case NativeFinalTextPaintAdmission.Failure.noSafePlacement(let cause)=error else{return nil}
                return Set(cause.split(separator:",").map(String.init))
            },recoverRefinement:{owners in
                guard let owner=owners.subtracting(legacyRefinementOwners).sorted().first else{return false}
                legacyRefinementOwners.insert(owner);return true
            }) { excluded,record in
                var retryOptions=options
                for id in legacyRefinementOwners {
                    if var raw=retryOptions[id] {raw["renderLegacyWordRefinement"]=true;retryOptions[id]=raw}
                }
                return try renderAttempt(items:items,viewport:viewport,restored:restored,allowShrink:allowShrink,
                    contours:contours,options:retryOptions,excludedTailOwners:excluded.union(disabled),recordRefinement:record,
                    outputWidthPlans:outputWidthPlans,capturePreparedFailure:capturePreparedFailure)
            }
            return (result.value.layer,result.excludedOwners.union(disabled),result.value.primitives)
        }
        func established()throws->AttemptResult {
            if let establishedReference {return establishedReference}
            let saved=legacyRefinementOwners
            legacyRefinementOwners=eligible
            defer {legacyRefinementOwners=saved}
            // Excluding optional refinements retains horizontalCandidates' base
            // word wrapper. Recovery must compare against this real admitted fit.
            let reference=try attempt(eligible);establishedReference=reference;return reference
        }
        func observations(_ layer:NativeAOTTranslationPageComposer.TextLayer)throws->[NativeSourceCohortPacking.Placement] {
            guard let rows=layer.audit["rawNativeItems"]as?[[String:Any]],
                  let paints=layer.audit["finalPaintAdmission"]as?[[String:Any]]else{throw invalidGeometry()}
            let painted=Dictionary(uniqueKeysWithValues:paints.compactMap {r -> (String,[String:Any])? in
                guard let id=r["owner"]as?String else{return nil};return (id,r)
            })
            let texts=Dictionary(uniqueKeysWithValues:items.map {($0.id,$0.text)})
            let records=try rows.compactMap {r -> NativeSourceCohortPacking.Placement? in
                guard let id=r["id"]as?String,let group=groups[id]else{return nil}
                guard let raw=options[id],let guide=try NativeTextPlacementGuide.decode(raw["textPlacementGuide"]),
                      let policy=try NativeTextExpansionPolicy.decode(raw["textExpansionPolicy"]),
                      let rawBounds=painted[id]?["finalFootprintOutputPixels"]as?[Any],
                      let font=r["fontSize"]as?Double,let text=texts[id],let ranges=r["lineRangesUTF16"]as?[[Int]]else{throw invalidGeometry()}
                let b=rawBounds.compactMap {($0 as?NSNumber)?.doubleValue}
                guard b.count==4,ranges.allSatisfy({$0.count==2})else{throw invalidGeometry()}
                let ns=ranges.map {NSRange(location:$0[0],length:$0[1])}
                let q=NativeRenderWrapQuality.evaluate(text,ranges:ns)
                return .init(owner:id,group:group,source:guide.rect(in:page),paint:CGRect(x:b[0],y:b[1],width:b[2],height:b[3]),
                    referenceFont:CGFloat(policy.sourceFontPixels),displayFont:CGFloat(font)*scale,
                    wrapPenalty:q.orphans*100+q.illegal+NativeRenderWrapQuality.shortTailOffsets(text,ranges:ns).count*10,
                    wordCuts:NativeRenderWrapQuality.wordCutOffsets(text,ranges:ns).count,
                    reflowAxis:policy.insideBalloon ? nil:try NativeSourceClusterAlignment.decode(raw["sourceClusterAlignment"])?.axis,softRows:ranges.count,
                    allowsUnalignedReflow:!policy.insideBalloon,allowsContainedReflow:policy.insideBalloon)
            }
            guard records.count==eligible.count else{throw invalidGeometry()}
            return records
        }
        var disabled=Set<String>()
        var comparisons=0
        func annotated(_ selected:(value:NativeAOTTranslationPageComposer.TextLayer,excludedOwners:Set<String>,primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive]))
            ->(value:NativeAOTTranslationPageComposer.TextLayer,excludedOwners:Set<String>,primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive]) {
            var audit=selected.value.audit;audit["sourceCohortComparisonRuns"]=comparisons
            audit["legacyWordRefinementOwners"]=legacyRefinementOwners.sorted()
            let value=NativeAOTTranslationPageComposer.TextLayer(image:selected.value.image,expectedItems:selected.value.expectedItems,
                paintedItems:selected.value.paintedItems,complete:selected.value.complete,audit:audit)
            return (value,selected.excludedOwners,selected.primitives)
        }
        func qualityAdmitted(_ selected:AttemptResult)throws->AttemptResult? {
            guard let reference=try? established()else{return annotated(selected)}
            let bad=NativeSourceCohortPacking.qualityRegressedOwners(before:try observations(reference.value),after:try observations(selected.value),allowGroupRowTrade:true)
            if bad.isEmpty {return annotated(selected)}
            var retry=bad.subtracting(legacyRefinementOwners)
            if retry.isEmpty {
                let affected=Set(bad.compactMap {groups[$0]})
                retry=Set(groups.keys.filter {groups[$0].map {affected.contains($0)} ?? false}).subtracting(legacyRefinementOwners)
            }
            guard !retry.isEmpty else{return annotated(reference)}
            legacyRefinementOwners.formUnion(retry);disabled.subtract(bad);return nil
        }
        for _ in 0...(groups.count*2) {
            let selected=try attempt(disabled)
            let rows=selected.value.audit["rawNativeItems"]as?[[String:Any]] ?? []
            let refined=Set(rows.compactMap {r -> String? in
                guard let id=r["id"]as?String,eligible.contains(id),r["tailRefinementOriginWidthPixels"]is NSNumber else{return nil}
                return id
            })
            guard !refined.isEmpty,let baseline=try? attempt(eligible)else{
                if let checked=try qualityAdmitted(selected) {return checked}
                continue
            }
            comparisons+=1
            let before=try observations(baseline.value),after=try observations(selected.value)
            let worse=NativeSourceCohortPacking.regressedGroups(before:before,after:after,allowGroupRowTrade:true)
            guard !worse.isEmpty else{
                if let checked=try qualityAdmitted(selected) {return checked}
                continue
            }
            // An expanded neighbour can displace an otherwise valid word fit.
            // Relieve that pressure before removing the displaced owner's fit.
            var rejected=NativeSourceCohortPacking.rejectedRefinementOwners(before:before,after:after,
                candidates:refined,preferExpansion:true)
            if rejected.isEmpty {rejected=refined}
            var legacyRetry=rejected.subtracting(legacyRefinementOwners)
            if legacyRetry.isEmpty {
                let remaining=Set(refined.subtracting(legacyRefinementOwners).filter {groups[$0].map {worse.contains($0)} ?? false})
                if !remaining.isEmpty {
                    legacyRetry=NativeSourceCohortPacking.rejectedRefinementOwners(before:before,after:after,
                        candidates:remaining,preferExpansion:true)
                }
            }
            if !legacyRetry.isEmpty {legacyRefinementOwners.formUnion(legacyRetry);continue}
            let next=disabled.union(rejected)
            guard next.count>disabled.count else{return annotated(baseline)}
            disabled=next
        }
        return annotated(try attempt(eligible))
    }

    struct CapacityMetric {
        let font: Double
        let cuts: Int
        let rows: Int
        let isolatedSingletonRows: Int
        let fontPixels: Double
        let paint: CGRect
        let readable: CGRect
        var styledRowGaps: [String: Double] = [:]
        var styledColumnGaps: [String: Double] = [:]
    }

    /// Count actual retained UTF16 rows, not an alternative tokenization. A
    /// singleton is a single alphanumeric grapheme incident to a soft word cut;
    /// intentional one-character paragraphs and punctuation-only rows do not count.
    static func capacitySegmentation(text: String, ranges: [[Int]], lines: [String]) throws
        -> (rows: Int, isolatedSingletonRows: Int, cuts: Int) {
        let original = text as NSString
        guard !ranges.isEmpty, ranges.count == lines.count else { throw invalidGeometry() }
        var owned: [NSRange] = [], retainedLines: [String] = []
        for (index, pair) in ranges.enumerated() {
            try Task.checkCancellation()
            guard pair.count == 2, pair[0] >= 0, pair[0] <= original.length,
                  pair[1] >= 0, pair[1] <= original.length - pair[0] else { throw invalidGeometry() }
            let range = NSRange(location: pair[0], length: pair[1])
            // Audit strings trim edge whitespace; UTF16 ownership still includes it.
            let retained = original.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard retained == lines[index].trimmingCharacters(in: .whitespacesAndNewlines) else { throw invalidGeometry() }
            owned.append(range)
            retainedLines.append(retained)
        }
        let cuts = NativeRenderWrapQuality.wordCutOffsets(text, ranges: owned)
        var isolated = 0
        for (index, range) in owned.enumerated() {
            let line = retainedLines[index]
            guard line.count == 1, let character = line.first, character.isLetter || character.isNumber,
                  cuts.contains(range.location) || cuts.contains(NSMaxRange(range)) else { continue }
            isolated += 1
        }
        return (owned.count, isolated, cuts.count)
    }

    /// Font recovery does not compensate repeated single-grapheme fragmentation.
    /// An occasional additional soft cut remains subject to the original policy.
    static func capacityRepeatedFragmentation(_ candidate: CapacityMetric, legacy: CapacityMetric) -> Bool {
        candidate.cuts - legacy.cuts >= 2 &&
            candidate.isolatedSingletonRows - legacy.isolatedSingletonRows >= 2 &&
            legacy.rows > 0 && Double(candidate.rows) >= Double(legacy.rows) * 1.5
    }

    struct CapacityGap {
        let first: String
        let second: String
        let horizontal: Bool
        let before: Double
        let after: Double
        let em: Double
        let beforeOverlap: Double
        let afterOverlap: Double
        var usesStyledRows: Bool = false

        // Preserve a minimum whitespace floor, not the exact incumbent gap.
        // A previously tight pair does not veto an independent improvement.
        var regressed: Bool {
            before + 1e-6 >= em * 0.35 && after + 1e-6 < em * 0.20 &&
                before - after > max(2, em * 0.10) + 1e-6
        }
        var audit: [String: Any] {
            ["owners": [first, second], "axis": horizontal ? "horizontal" : "vertical",
                "legacyGapPixels": before, "candidateGapPixels": after, "comparisonFontPixels": em,
                "minimumGapPixels": em * 0.20, "legacyOverlapPixels": beforeOverlap,
                "candidateOverlapPixels": afterOverlap, "gapRegressed": regressed,
                "authority": usesStyledRows ? "completed current prepared styled-alpha row-envelope minimum; no debug witness dependency" : "completed finalPaintAdmission readable bounds; positive cross-axis overlap in both attempts"]
        }
    }

    private static func capacityBounds(_ value: Any?) -> CGRect? {
        guard let values = value as? [Any], values.count == 4 else { return nil }
        let numbers = values.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { return nil }
        let bounds = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        return bounds.maxX.isFinite && bounds.maxY.isFinite ? bounds : nil
    }

    /// Compare the same incumbent separation axis/order, not diagonal distance.
    /// Positive overlap on the perpendicular axis is required in both layouts.
    static func capacityGaps(_ candidate: [String: CapacityMetric],
                                     legacy: [String: CapacityMetric]) -> [CapacityGap] {
        let ids = legacy.keys.sorted()
        var result: [CapacityGap] = []
        for (index, first) in ids.enumerated() {
            guard let a = legacy[first], let c = candidate[first] else { continue }
            for second in ids.dropFirst(index + 1) {
                guard let b = legacy[second], let d = candidate[second] else { continue }
                let em = min(a.fontPixels, b.fontPixels, c.fontPixels, d.fontPixels)
                for horizontal in [true, false] {
                    let beforeOverlap = horizontal ? min(a.readable.maxY, b.readable.maxY) - max(a.readable.minY, b.readable.minY)
                        : min(a.readable.maxX, b.readable.maxX) - max(a.readable.minX, b.readable.minX)
                    let afterOverlap = horizontal ? min(c.readable.maxY, d.readable.maxY) - max(c.readable.minY, d.readable.minY)
                        : min(c.readable.maxX, d.readable.maxX) - max(c.readable.minX, d.readable.minX)
                    guard beforeOverlap > 0, afterOverlap > 0 else { continue }
                    let firstBefore = horizontal ? a.readable.maxX <= b.readable.minX : a.readable.maxY <= b.readable.minY
                    let secondBefore = horizontal ? b.readable.maxX <= a.readable.minX : b.readable.maxY <= a.readable.minY
                    guard firstBefore || secondBefore else { continue }
                    var before = horizontal ? (firstBefore ? b.readable.minX - a.readable.maxX : a.readable.minX - b.readable.maxX)
                        : (firstBefore ? b.readable.minY - a.readable.maxY : a.readable.minY - b.readable.maxY)
                    var after = horizontal ? (firstBefore ? d.readable.minX - c.readable.maxX : c.readable.minX - d.readable.maxX)
                        : (firstBefore ? d.readable.minY - c.readable.maxY : c.readable.minY - d.readable.maxY)
                    let aa=horizontal ? a.styledRowGaps:a.styledColumnGaps
                    let cc=horizontal ? c.styledRowGaps:c.styledColumnGaps
                    let styled = NativeStyledRowGap.styledArbitrationEnabled && aa[second] != nil && cc[second] != nil
                    if styled {before=CGFloat(aa[second]!);after=CGFloat(cc[second]!)}
                    result.append(CapacityGap(first: first, second: second, horizontal: horizontal,
                        before: Double(before), after: Double(after), em: em,
                        beforeOverlap: Double(beforeOverlap), afterOverlap: Double(afterOverlap), usesStyledRows:styled))
                }
            }
        }
        return result
    }

    /// Read only completed, fully-owned results. No pixel sampling or plan mutation.
    static func capacityMetrics(_ layer: NativeAOTTranslationPageComposer.TextLayer,
                                        items: [Item], scale: Double) throws -> [String: CapacityMetric] {
        guard layer.complete, layer.expectedItems == items.count, layer.paintedItems == items.count,
              scale.isFinite, scale > 0,
              Set(items.map(\.id)).count == items.count,
              let rows = layer.audit["rawNativeItems"] as? [[String: Any]], rows.count == items.count,
              let placements = layer.audit["finalPaintAdmission"] as? [[String: Any]], placements.count == items.count else {
            throw invalidGeometry()
        }
        let expected = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.text.utf16.count) })
        let texts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.text) })
        var bounds: [String: (paint: CGRect, readable: CGRect)] = [:]
        for row in placements {
            try Task.checkCancellation()
            guard let id = row["owner"] as? String, expected[id] != nil, bounds[id] == nil,
                  let paint = capacityBounds(row["finalFootprintOutputPixels"]),
                  let readable = capacityBounds(row["readableBoundsOutputPixels"]),
                  paint.insetBy(dx: -0.01, dy: -0.01).contains(readable) else { throw invalidGeometry() }
            bounds[id] = (paint, readable)
        }
        var metrics: [String: CapacityMetric] = [:]
        for row in rows {
            try Task.checkCancellation()
            guard let id = row["id"] as? String, let length = expected[id], metrics[id] == nil,
                  row["sourceUTF16"] as? Int == length, row["visibleUTF16"] as? Int == length,
                  let font = (row["fontSize"] as? NSNumber)?.doubleValue, font.isFinite, font > 0,
                  let footprint = bounds[id], (font * scale).isFinite,
                  let ranges = row["lineRangesUTF16"] as? [[Int]],
                  let lines = row["actualCoreTextLineStrings"] as? [String],
                  let cuts = row["softWordCuts"] as? Int, cuts >= 0 else { throw invalidGeometry() }
            let segmentation = try capacitySegmentation(text: texts[id]!, ranges: ranges, lines: lines)
            guard segmentation.cuts == cuts else { throw invalidGeometry() }
            metrics[id] = CapacityMetric(font: font, cuts: cuts, rows: segmentation.rows,
                isolatedSingletonRows: segmentation.isolatedSingletonRows, fontPixels: font * scale,
                paint: footprint.paint, readable: footprint.readable)
        }
        if NativeStyledRowGap.metricIsCurrent(layer.audit["completedStyledRowPairMetric"],admission:placements),
           let wrapper=layer.audit["completedStyledRowPairMetric"]as?[String:Any],
           let pairs=wrapper["pairs"]as?[[String:Any]] {
            for pair in pairs {
                if let ids=pair["owners"]as?[String],ids.count==2,let gap=(pair["minimumGapPixels"]as?NSNumber)?.doubleValue {
                    if pair["axis"]as?String=="vertical" {
                        metrics[ids[0]]?.styledColumnGaps[ids[1]]=gap
                        metrics[ids[1]]?.styledColumnGaps[ids[0]]=gap
                    } else {
                        metrics[ids[0]]?.styledRowGaps[ids[1]]=gap
                        metrics[ids[1]]?.styledRowGaps[ids[0]]=gap
                    }
                }
            }
        }
        return metrics
    }

    private static func capacityInitialFonts(_ items: [Item], options: [String: [String: Any]]) -> [String: Double] {
        let groups = Dictionary(grouping: items.filter { options[$0.id]?["typographyGroupID"] is String },
            by: { options[$0.id]!["typographyGroupID"] as! String })
        let medians = groups.mapValues { members -> Double in
            let fonts = members.map { Double($0.fontSize) }.sorted()
            return fonts[fonts.count / 2]
        }
        return Dictionary(uniqueKeysWithValues: items.map { item in
            let median = (options[item.id]?["typographyGroupID"] as? String).flatMap { medians[$0] }
            return (item.id, median ?? Double(item.fontSize))
        })
    }

    static func capacityBadOwners(_ candidate: [String: CapacityMetric],
                                          legacy: [String: CapacityMetric]) -> Set<String> {
        var bad = Set(legacy.keys.filter { id in
            guard let actual = candidate[id], let prior = legacy[id] else { return true }
            return actual.font < prior.font - 0.01 ||
                (abs(actual.font - prior.font) <= 0.01 && actual.cuts > prior.cuts) ||
                capacityRepeatedFragmentation(actual, legacy: prior)
        })
        for gap in capacityGaps(candidate, legacy: legacy) where gap.regressed {
            bad.insert(gap.first); bad.insert(gap.second)
        }
        return bad
    }

    /// A quadratic peer comparison is bounded to the existing final-admission
    /// owner cap (NativeFinalTextPaintAdmission.place). Above it, use the old
    /// renderer/fallback path rather than introduce a new arbitration failure.
    static func capacityArbitrationWithinBudget(itemCount: Int) -> Bool {
        (0...256).contains(itemCount)
    }

    static func capacityCanSkipLegacy(_ metrics: [String: CapacityMetric], initial: [String: Double]) -> Bool {
        guard metrics.count < 2 else { return false }
        return metrics.allSatisfy { id, value in
            guard let font = initial[id] else { return false }
            return value.font >= font && value.cuts == 0
        }
    }

    /// Transitive family/body closure, never page IDs or hand-picked owners.
    private static func capacityClosure(_ seeds: Set<String>, items: [Item],
                                        options: [String: [String: Any]]) throws -> Set<String> {
        let ids = Set(items.map(\.id))
        var result = seeds.intersection(ids)
        while true {
            try Task.checkCancellation()
            let families = Set(result.compactMap { options[$0]?["typographyGroupID"] as? String })
            let fontFits = Set(result.compactMap { options[$0]?["sourceFontFitGroupID"] as? String })
            let bodies = Set(result.compactMap { (options[$0]?["balloonPlacement"] as? [String: Any])?["bodyID"] as? String })
            let before = result.count
            for id in ids {
                if let family = options[id]?["typographyGroupID"] as? String, families.contains(family) { result.insert(id) }
                if let fit = options[id]?["sourceFontFitGroupID"] as? String, fontFits.contains(fit) { result.insert(id) }
                if let body = (options[id]?["balloonPlacement"] as? [String: Any])?["bodyID"] as? String,
                   bodies.contains(body) { result.insert(id) }
            }
            if result.count == before { return result }
        }
    }

    private static func capacityComparisons(_ candidate: [String: CapacityMetric],
                                            legacy: [String: CapacityMetric]) -> [[String: Any]] {
        legacy.keys.sorted().compactMap { id in
            guard let actual = candidate[id], let prior = legacy[id] else { return nil }
            return ["id": id, "candidateFont": actual.font, "legacyFont": prior.font,
                "fontDelta": actual.font - prior.font, "candidateCuts": actual.cuts, "legacyCuts": prior.cuts,
                "candidateRows": actual.rows, "legacyRows": prior.rows,
                "candidateIsolatedSingletonRows": actual.isolatedSingletonRows,
                "legacyIsolatedSingletonRows": prior.isolatedSingletonRows,
                "repeatedSegmentationRegression": capacityRepeatedFragmentation(actual, legacy: prior),
                "segmentationGuardReason": capacityRepeatedFragmentation(actual, legacy: prior)
                    ? "at-least-two-new-soft-cuts-and-cut-adjacent-singletons;rows-at-least-1.5x"
                    : "no-repeated-fragmentation",
                "candidatePaintPixels": [actual.paint.minX, actual.paint.minY, actual.paint.width, actual.paint.height],
                "legacyPaintPixels": [prior.paint.minX, prior.paint.minY, prior.paint.width, prior.paint.height],
                "candidateReadablePixels": [actual.readable.minX, actual.readable.minY, actual.readable.width, actual.readable.height],
                "legacyReadablePixels": [prior.readable.minX, prior.readable.minY, prior.readable.width, prior.readable.height],
                "fontDecrease": actual.font < prior.font - 0.01,
                "sameFontMoreCuts": abs(actual.font - prior.font) <= 0.01 && actual.cuts > prior.cuts,
                "fontRecoveryCutTradeoff": actual.font > prior.font + 0.01 && actual.cuts > prior.cuts,
                "fontRecoveryCutTradeoffAllowed": actual.font > prior.font + 0.01 && actual.cuts > prior.cuts &&
                    !capacityRepeatedFragmentation(actual, legacy: prior)]
        }
    }

    private static func capacityAnnotated(_ layer: NativeAOTTranslationPageComposer.TextLayer,
                                          metadata: [String: Any]) -> NativeAOTTranslationPageComposer.TextLayer {
        var audit = layer.audit
        audit["capacityIncumbentArbitration"] = metadata
        return .init(image: layer.image, expectedItems: layer.expectedItems,
            paintedItems: layer.paintedItems, complete: layer.complete, audit: audit)
    }

    /// Whole-page arbitration with an explicit rollback switch. Every attempt retains ordinary hard admission;
    /// only the legacy capacity counterfactual is task-local, never an env mutation.
    private static func renderImpl(items:[Item],viewport:CGSize,restored:CGImage,allowShrink:Bool,
                                   contours:[String:NativeRawBalloonCapacity.Contour],options:[String:[String:Any]]=[:],
                                   completePeerContext:Bool=true)throws->NativeAOTTranslationPageComposer.TextLayer {
        guard NativeWholeWordWrap.initialWordObjectiveEnabled else {
            return try renderImplCapacity(items:items,viewport:viewport,restored:restored,allowShrink:allowShrink,
                contours:contours,options:options,completePeerContext:completePeerContext)
        }
        // Compare completed page layouts, since changing one owner's breakpoints
        // can otherwise shrink a peer during global capacity arbitration.
        let baseline = try NativeWholeWordWrap.withInitialWordObjective(false) {
            try renderImplCapacity(items:items,viewport:viewport,restored:restored,allowShrink:allowShrink,
                contours:contours,options:options,completePeerContext:completePeerContext)
        }
        let scale=Double(restored.width)/Double(viewport.width)
        let old=try capacityMetrics(baseline,items:items,scale:scale)
        guard old.values.contains(where:{$0.cuts>0}) else{return baseline}
        do {
            let candidate=try renderImplCapacity(items:items,viewport:viewport,restored:restored,allowShrink:allowShrink,
                contours:contours,options:options,completePeerContext:completePeerContext)
            let actual=try capacityMetrics(candidate,items:items,scale:scale)
            let cutRegressions=Set(old.keys.filter {id in
                guard let a=actual[id],let b=old[id] else{return true}
                return a.cuts>b.cuts
            })
            let bad=capacityBadOwners(actual,legacy:old).union(cutRegressions)
            let improved=old.keys.filter {id in
                guard let a=actual[id],let b=old[id] else{return false}
                return a.cuts<b.cuts && a.font>=b.font-0.01
            }.sorted()
            let accepted=bad.isEmpty && !improved.isEmpty
            var selected=accepted ? candidate:baseline
            var audit=selected.audit
            audit["initialWordObjective"]=[
                "accepted":accepted,"improvedOwnerIDs":accepted ? improved:[],"rejectedOwnerIDs":bad.sorted(),
                "authority":"completed page; fonts, cuts, peer gaps and existing final-alpha admission",
                "wholeQualityAccepted":false] as [String:Any]
            selected = .init(image:selected.image,expectedItems:selected.expectedItems,paintedItems:selected.paintedItems,
                complete:selected.complete,audit:audit)
            return selected
        } catch is CancellationError {throw CancellationError()}
        catch {
            try Task.checkCancellation()
            var audit=baseline.audit
            audit["initialWordObjective"]=["accepted":false,"candidateError":String(reflecting:error),"baselineRetained":true]
            return .init(image:baseline.image,expectedItems:baseline.expectedItems,paintedItems:baseline.paintedItems,
                complete:baseline.complete,audit:audit)
        }
    }

    /// V3 wraps, rather than replaces, the successful incumbent-policy selection.
    private static func renderImplCapacity(items:[Item],viewport:CGSize,restored:CGImage,allowShrink:Bool,
        contours:[String:NativeRawBalloonCapacity.Contour],options:[String:[String:Any]]=[:],
        completePeerContext:Bool=true)throws->NativeAOTTranslationPageComposer.TextLayer {
        guard NativeStyledRowGap.v3Enabled else {
            return try renderImplCapacityPolicy(items:items,viewport:viewport,restored:restored,allowShrink:allowShrink,
                contours:contours,options:options,completePeerContext:completePeerContext)
        }
        let memo=NativeStyledRowGap.AttemptMemo()
        return try NativeStyledRowGap.$attemptMemo.withValue(memo) {
            func policy()throws->NativeAOTTranslationPageComposer.TextLayer {
                try renderImplCapacityPolicy(items:items,viewport:viewport,restored:restored,allowShrink:allowShrink,
                    contours:contours,options:options,completePeerContext:completePeerContext)
            }
            let incumbent=try NativeStyledRowGap.$incumbentPolicy.withValue(true) {try policy()}
            let scale=Double(restored.width)/Double(viewport.width)
            let before=try capacityMetrics(incumbent,items:items,scale:scale)
            let gaps=capacityGaps(before,legacy:before)
            let crowded=gaps.filter{$0.usesStyledRows && $0.after < $0.em*0.20}
            var receipt:[String:Any]=["version":3,"incumbentAuthority":"successful unchanged bbox arbitration policy; current native raster",
                "crowdedPairs":crowded.map(\.audit),"sourceDistanceIncreaseCapEm":0.5,
                "unrelatedCutsOrRowsMayIncrease":false,"relatedAdditionalCutCap":1,"relatedAdditionalRowCap":1,
                "physicalContainmentProven":false]
            func result(_ layer:NativeAOTTranslationPageComposer.TextLayer,_ selection:String)->NativeAOTTranslationPageComposer.TextLayer {
                var audit=layer.audit;var record=receipt;record["selection"]=selection;record["work"]=memo.audit
                audit["styledRowGapIncumbentRepair"]=record
                return .init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,complete:layer.complete,audit:audit)
            }
            guard !crowded.isEmpty else {return result(incumbent,"incumbent-no-actual-styled-crowding")}
            let related=try capacityClosure(Set(crowded.flatMap{[$0.first,$0.second]}),items:items,options:options)
            receipt["relatedOwners"]=related.sorted()
            do {
                let candidate=try policy()
                let after=try capacityMetrics(candidate,items:items,scale:scale)
                let comparisons=capacityGaps(after,legacy:before)
                var improved=false,rejections:[String]=[],sourceDrift:[[String:Any]]=[]
                for target in crowded {
                    guard let pair=comparisons.first(where:{$0.first==target.first && $0.second==target.second && $0.horizontal==target.horizontal && $0.usesStyledRows}) else {rejections.append("missing-current-target-pair");continue}
                    if pair.after < target.after-0.01 {rejections.append("target-clearance-worse")}
                    if pair.after>=pair.em*0.35 && pair.after-target.after>max(2,pair.em*0.10) {improved=true}
                }
                for pair in capacityGaps(after,legacy:after) where pair.usesStyledRows && pair.after<pair.em*0.20 {
                    let prior=gaps.first{$0.first==pair.first && $0.second==pair.second && $0.horizontal==pair.horizontal}
                    if prior==nil || pair.after < prior!.after-0.01 {rejections.append("new-or-worse-styled-crowding")}
                }
                let page=CGRect(x:0,y:0,width:restored.width,height:restored.height)
                for item in items {
                    guard let b=before[item.id],let a=after[item.id] else {rejections.append("missing-owner");continue}
                    if abs(a.font-b.font)>0.01 {rejections.append("font-change")}
                    let allowance=related.contains(item.id) ? 1:0
                    if a.cuts>b.cuts+allowance || a.rows>b.rows+allowance || capacityRepeatedFragmentation(a,legacy:b) {rejections.append("cut-or-row-collateral:"+item.id)}
                    if a.paint != b.paint {
                        guard let guide=try NativeTextPlacementGuide.decode(options[item.id]?["textPlacementGuide"]) else {rejections.append("missing-source-guide:"+item.id);continue}
                        let source=guide.rect(in:page)
                        let old=hypot(b.paint.midX-source.midX,b.paint.midY-source.midY)
                        let new=hypot(a.paint.midX-source.midX,a.paint.midY-source.midY)
                        let em=(new-old)/CGFloat(min(a.fontPixels,b.fontPixels))
                        sourceDrift.append(["owner":item.id,"beforePixels":old,"afterPixels":new,"increaseEm":em])
                        if em>0.5+1e-6 {rejections.append("source-drift:"+item.id)}
                    }
                }
                receipt["sourceDrift"]=sourceDrift;receipt["rejections"]=rejections
                receipt["improvedCrowdedTarget"]=improved
                if improved && rejections.isEmpty {return result(candidate,"guarded-current-native-repair")}
                return result(incumbent,"incumbent-retained-candidate-not-dominant")
            } catch is CancellationError {throw CancellationError()}
            catch {receipt["candidateError"]=String(reflecting:error);return result(incumbent,"incumbent-retained-candidate-error-or-budget")}
        }
    }

    private static func renderImplCapacityPolicy(items: [Item], viewport: CGSize, restored: CGImage, allowShrink: Bool,
                                   contours: [String: NativeRawBalloonCapacity.Contour], options: [String:[String:Any]] = [:],
                                   completePeerContext:Bool=true) throws -> NativeAOTTranslationPageComposer.TextLayer {
        guard ProcessInfo.processInfo.environment["AIDOKU_CAPACITY_INCUMBENT_ARBITRATION"] != "0",
              NativeTextSpacing.usesResolvedEffectExtent,
              capacityArbitrationWithinBudget(itemCount: items.count) else {
            return try renderImplAttempt(items: items, viewport: viewport, restored: restored, allowShrink: allowShrink,
                contours: contours, options: options, completePeerContext: completePeerContext)
        }
        try Task.checkCancellation()
        guard Set(items.map(\.id)).count == items.count else { throw invalidGeometry() }
        let initial = capacityInitialFonts(items, options: options)
        var invocationCount = 0, mixedCount = 0
        var history: [[String: Any]] = []
        var actualMetrics: [String: CapacityMetric]?
        var legacyMetrics: [String: CapacityMetric]?
        var conservative = Set<String>()
        var actualTuple:NativeStyledRowGap.Tuple?
        func attempt(_ mode: String, legacy: Bool = false, raw: [String: [String: Any]]) throws
            -> (layer: NativeAOTTranslationPageComposer.TextLayer, metrics: [String: CapacityMetric]) {
            try Task.checkCancellation()
            invocationCount += 1
            do {
                let layer: NativeAOTTranslationPageComposer.TextLayer
                let captured:NativeStyledRowGap.CompletedTupleCapture? = NativeStyledRowGap.enabled && mode=="actual"
                    ? (NativeStyledRowGap.attemptMemo?.capture ?? NativeStyledRowGap.CompletedTupleCapture()):nil
                func execute()throws->NativeAOTTranslationPageComposer.TextLayer {
                if legacy {
                    return try NativeTextSpacing.withLegacyCapacity {
                        try renderImplAttempt(items: items, viewport: viewport, restored: restored, allowShrink: allowShrink,
                            contours: contours, options: raw, completePeerContext: completePeerContext)
                    }
                } else {
                    return try renderImplAttempt(items: items, viewport: viewport, restored: restored, allowShrink: allowShrink,
                        contours: contours, options: raw, completePeerContext: completePeerContext)
                }
                }
                func memoizedExecute()throws->NativeAOTTranslationPageComposer.TextLayer {
                    if let memo=NativeStyledRowGap.attemptMemo {return try memo.run(legacy:legacy,raw:raw,operation:execute)}
                    return try execute()
                }
                if let captured {
                    let observer=NativeStyledRowGap.forwardingObserver(to:NativeAOTTranslationPageComposer.completedPaintObserver,capture:captured)
                    layer=try NativeAOTTranslationPageComposer.$completedPaintObserver.withValue(observer) {try memoizedExecute()}
                    actualTuple=captured.selectedTuple(for:layer)
                } else {layer=try memoizedExecute()}
                let metrics = try capacityMetrics(layer, items: items, scale: Double(restored.width) / Double(viewport.width))
                var record: [String: Any] = ["mode": mode, "complete": true,
                    "conservativeOwnerIDs": conservative.sorted()]
                if let incumbent = legacyMetrics {
                    record["versusLegacy"] = capacityComparisons(metrics, legacy: incumbent)
                    record["peerGapsVersusLegacy"] = capacityGaps(metrics, legacy: incumbent).map(\.audit)
                    record["badOwnerIDs"] = capacityBadOwners(metrics, legacy: incumbent).sorted()
                }
                record["completedStyledRowPairMetric"]=layer.audit["completedStyledRowPairMetric"]
                if let captured {
                    let memory=captured.stats()
                    record["exactCompletedTupleCaptured"]=actualTuple != nil
                    record["completedTupleCapture"]=["entries":memory.entries,"uniqueCarrierImages":memory.uniqueCarrierImages,
                        "carrierPixels":memory.carrierPixels,"carrierRowBytes":memory.carrierRowBytes,
                        "conservativeChargedBytes":memory.conservativeChargedBytes,"compositeImagesStronglyRetained":0]
                }
                history.append(record)
                return (layer, metrics)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                history.append(["mode": mode, "complete": false, "error": String(reflecting: error)])
                throw error
            }
        }
        func annotated(_ result: (layer: NativeAOTTranslationPageComposer.TextLayer, metrics: [String: CapacityMetric]),
                       selection: String) throws -> NativeAOTTranslationPageComposer.TextLayer {
            try Task.checkCancellation()
            let drift: [[String: Any]] = items.map { item in
                let metric = result.metrics[item.id]!, requested = initial[item.id]!
                return ["id": item.id, "initialFamilyMedianFont": requested, "selectedFont": metric.font,
                    "fontDelta": metric.font - requested, "belowInitialFamilyMedian": metric.font < requested - 0.01,
                    "selectedCuts": metric.cuts, "selectedRows": metric.rows,
                    "selectedIsolatedSingletonRows": metric.isolatedSingletonRows]
            }
            let selectedComparison = legacyMetrics.map { capacityComparisons(result.metrics, legacy: $0) } ?? []
            let changedIDs = selectedComparison.compactMap { row -> String? in
                guard let delta = row["fontDelta"] as? Double, let cuts = row["candidateCuts"] as? Int,
                      let oldCuts = row["legacyCuts"] as? Int, delta != 0 || cuts != oldCuts else { return nil }
                return row["id"] as? String
            }
            let compared = actualMetrics.flatMap { actual in legacyMetrics.map { capacityComparisons(actual, legacy: $0) } } ?? []
            let actualGaps = actualMetrics.flatMap { actual in legacyMetrics.map { capacityGaps(actual, legacy: $0).map(\.audit) } } ?? []
            let selectedGaps = legacyMetrics.map { capacityGaps(result.metrics, legacy: $0).map(\.audit) } ?? []
            var metadata:[String:Any] = ["enabled": true, "selection": selection,
                "invocationCount": invocationCount, "attemptBudget": 4, "mixedInvocationCount": mixedCount, "mixedBudget": 2,
                "invocationScope": "whole renderImplAttempt calls; internal existing retries are unchanged",
                "attempts": history, "legacyComplete": legacyMetrics != nil, "actualComplete": actualMetrics != nil,
                "actualVersusLegacy": compared, "selectedVersusLegacy": selectedComparison,
                "actualPeerGapsVersusLegacy": actualGaps, "selectedPeerGapsVersusLegacy": selectedGaps,
                "peerGapIncumbentRequired": items.count > 1, "peerGapComparisonAvailable": legacyMetrics != nil,
                "peerGapPolicy": "positive cross-axis overlap in both layouts; incumbent gap>=.35em; candidate gap<.20em; drop>max(2px,.10em); seed both owners",
                "peerGapFontUnit": "minimum of both owners' actual and legacy output-pixel fonts",
                "peerGapPairBudget": 32640, "peerGapThresholdVisualAcceptanceClaimed": false,
                "segmentationPolicy": "new cuts>=2 AND new cut-adjacent single-alphanumeric rows>=2 AND row inflation>=1.5; veto even with font recovery",
                "initialFontDrift": drift, "conservativeOwnerIDs": conservative.sorted(), "changedOwnerIDs": changedIDs,
                "changedOwnerIDsScope": "font/cut metrics versus complete legacy only; no raster comparison",
                "retainedWithoutLegacyIncumbent": legacyMetrics == nil, "automaticQualityAccepted": false]
            if NativeStyledRowGap.styledArbitrationEnabled {
                metadata["selectedPeerGapsVersusActual"]=actualMetrics.map{capacityGaps(result.metrics,legacy:$0).map(\.audit)} ?? []
            }
            return capacityAnnotated(result.layer,metadata:metadata)
        }
        let actual: (layer: NativeAOTTranslationPageComposer.TextLayer, metrics: [String: CapacityMetric])
        do {
            actual = try attempt("actual", raw: options)
            actualMetrics = actual.metrics
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            let originalError = error
            do {
                let legacy = try attempt("legacy-after-actual-error", legacy: true, raw: options)
                legacyMetrics = legacy.metrics
                return try annotated(legacy, selection: "legacy-rollback-after-actual-error")
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                throw originalError
            }
        }
        // With peers, even zero cuts and recovered fonts cannot certify whitespace.
        // The legacy comparison remains within the same four-attempt budget.
        if capacityCanSkipLegacy(actual.metrics, initial: initial) {
            return try annotated(actual, selection: "actual-no-peers-initial-fonts-and-zero-cuts;legacy-not-needed")
        }
        let legacy: (layer: NativeAOTTranslationPageComposer.TextLayer, metrics: [String: CapacityMetric])
        do {
            legacy = try attempt("legacy-incumbent", legacy: true, raw: options)
            legacyMetrics = legacy.metrics
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return try annotated(actual, selection: "actual-retained-legacy-failed;initial-font-drift-reported")
        }
        let bad = capacityBadOwners(actual.metrics, legacy: legacy.metrics)
        if bad.isEmpty { return try annotated(actual, selection: "actual-dominates-legacy") }
        if NativeStyledRowGap.styledArbitrationEnabled,let tuple=actualTuple {
            let gaps=capacityGaps(actual.metrics,legacy:legacy.metrics).filter{$0.horizontal && $0.usesStyledRows && $0.regressed}
            let requests=gaps.map{($0.first,$0.second,ceil($0.em*0.35-$0.after))}
            if let repaired=try NativeStyledRowGap.nudge(layer:actual.layer,tuple:tuple,restored:restored,requests:requests) {
                let metrics=try capacityMetrics(repaired,items:items,scale:Double(restored.width)/Double(viewport.width))
                if capacityBadOwners(metrics,legacy:legacy.metrics).isEmpty && capacityBadOwners(metrics,legacy:actual.metrics).isEmpty {
                    history.append(["mode":"actual-row-gap-nudge","complete":true,"completedStyledRowPairMetric":repaired.audit["completedStyledRowPairMetric"] as Any])
                    return try annotated((repaired,metrics),selection:"actual-row-gap-nudge-dominates-actual-and-legacy")
                }
            }
        }
        conservative = try capacityClosure(bad, items: items, options: options)
        for index in 1...2 {
            try Task.checkCancellation()
            var mixedOptions = options
            for id in conservative {
                var raw = mixedOptions[id] ?? [:]
                raw["renderConservativeCapacity"] = true
                mixedOptions[id] = raw
            }
            mixedCount += 1
            do {
                let mixed = try attempt("mixed-\(index)", raw: mixedOptions)
                let remaining = capacityBadOwners(mixed.metrics, legacy: legacy.metrics).union(
                    NativeStyledRowGap.styledArbitrationEnabled ? capacityBadOwners(mixed.metrics,legacy:actual.metrics):[])
                if remaining.isEmpty { return try annotated(mixed, selection: "mixed-dominates-legacy") }
                let expanded = try capacityClosure(conservative.union(remaining), items: items, options: options)
                if expanded == conservative { break }
                conservative = expanded
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                break
            }
        }
        if NativeStyledRowGap.styledArbitrationEnabled,!capacityBadOwners(legacy.metrics,legacy:actual.metrics).isEmpty {
            return try annotated(actual,selection:"actual-retained-cross-reference-row-gap-veto")
        }
        return try annotated(legacy, selection: "complete-legacy-fallback-after-mixed-budget-or-error")
    }

    typealias FixedFontAttempt = (value:NativeAOTTranslationPageComposer.TextLayer,
        excludedOwners:Set<String>,primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive])
    struct FixedFontPreparedBatch {
        let audit:[[String:Any]]
        let primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive]
    }
    struct FixedFontPreparedFailure:Error {
        let cause:String
        let prepared:FixedFontPreparedBatch
    }
    struct FontContractFailure:Error {let group:String;let requestedFonts:[Double]}
    struct FixedFontRecoveryFailure: Error {
        let cause:String
        let receipt:NativeFixedFontRecovery.Receipt
        let rejectedPlans:[String:Int]
        var cacheBudget:[String:Int]?=nil
        var diagnostics:[String:Any]=[:]
    }
    struct FixedFontShapeCandidate {
        let widthPlan:NativeOwnerOutputWidthPlan?
        let batch:FixedFontPreparedBatch
    }
    struct FixedFontRecoveryOutcome {
        let attempt:FixedFontAttempt?
        let receipt:NativeFixedFontRecovery.Receipt
        let audit:[String:Any]
        let rejectedPlans:[String:Int]
    }
    static func permitsCapacityFontReduction(allowShrink:Bool,affected:Set<String>,
                                             options:[String:[String:Any]]) -> Bool {
        allowShrink && !affected.isEmpty && affected.allSatisfy {
            options[$0]?["renderPreserveRequestedFontSize"] as? Bool != true
        }
    }
    private static func fixedFontClosure(_ seeds:Set<String>,items:[Item],
                                         options:[String:[String:Any]])throws -> Set<String> {
        var affected=try capacityClosure(seeds,items:items,options:options)
        while true {
            let clusters=Set(affected.compactMap {
                (options[$0]?["sourceClusterAlignment"] as? [String:Any])?["groupID"] as? String
            })
            let additions=Set(items.compactMap { item -> String? in
                guard let cluster=(options[item.id]?["sourceClusterAlignment"] as? [String:Any])?["groupID"] as? String,
                      clusters.contains(cluster) else {return nil}
                return item.id
            })
            let next=try capacityClosure(affected.union(additions),items:items,options:options)
            if next==affected {return affected};affected=next
        }
    }

    /// Each returned candidate retains the actual glyph primitive and native row
    /// audit. At most eight generation attempts, including a reused incumbent.
    static func fixedFontShapeAlternatives(item:Item,items:[Item],viewport:CGSize,restored:CGImage,
        contours:[String:NativeRawBalloonCapacity.Contour],options:[String:[String:Any]],
        incumbent:FixedFontShapeCandidate?,rejected:inout [String:Int])throws -> [FixedFontShapeCandidate] {
        let scale=CGFloat(restored.width)/viewport.width
        let page=CGRect(x:0,y:0,width:restored.width,height:restored.height)
        let raw=options[item.id] ?? [:]
        guard item.fontSize.isFinite,item.fontSize>0,item.frame.width>0,item.frame.height>0 else {throw invalidGeometry()}
        let policy=try NativeTextExpansionPolicy.decode(raw["textExpansionPolicy"])
        _=try NativeSourceStylePaint.style(raw)
        _=try NativeTextPlacementGuide.decode(raw["textPlacementGuide"])
        _=try NativeSourceClusterAlignment.decode(raw["sourceClusterAlignment"])
        _=try NativeBalloonPlacement.decode(raw["balloonPlacement"])
        let capacity=policy.map {NativeTextExpansionPolicy.rect($0.allowedRectNormalized,page:page)} ??
            contours[item.id].map {$0.rect.applying(CGAffineTransform(scaleX:scale,y:scale))} ?? page
        let fontPixels=item.fontSize*scale
        let baseWidth=min(capacity.width,item.frame.width*scale)
        let outward=NativeTextSpacing.outwardExtent(raw:raw,fontSize:fontPixels)
        let inset=outward+NativeTextSpacing.padding(fontSize:fontPixels)
        let font=CTFontCreateWithName(try sourceFontName(raw:raw) as CFString,fontPixels,nil)
        let attributed=NSAttributedString(string:item.text,attributes:[.init(kCTFontAttributeName as String):font])
        // Real lexical endpoints receive budget before synthetic fractional fills.
        let lexical=capacity.width>2*inset ? NativeRenderWrapQuality.lexicalLineWidths(attributed,
            minimumWidth:max(1,min(baseWidth-2*inset,fontPixels)),maximumWidth:capacity.width-2*inset,
            limit:8).map {$0+2*inset}:[]
        // Reserve six slots for measured lexical endpoints sampled over their
        // whole range, plus a capacity endpoint; fractions only fill vacancies.
        let measured=lexical.reversed().prefix(6).map {$0.rounded(.up)+1}
        var jointWidths:[CGFloat]=[]
        if promotedFailurePlanning,let policy,!policy.insideBalloon,
           let cluster=try NativeSourceClusterAlignment.decode(raw["sourceClusterAlignment"]),cluster.axis == .top,
           cluster.anchorsToSourceStart == true,let incumbent {
            let cohort=items.filter {(options[$0.id]?["sourceClusterAlignment"]as?[String:Any])?["groupID"]as?String == cluster.groupID}
            let starts=try cohort.compactMap {other -> CGFloat? in
                guard let guide=try NativeTextPlacementGuide.decode(options[other.id]?["textPlacementGuide"])else{return nil}
                return guide.rect(in:page).minY
            }.sorted()
            if cohort.count>1,starts.count==cohort.count {
                let n=starts.count,cross=(n%2==1 ? starts[n/2]:(starts[n/2-1]+starts[n/2])/2).rounded()
                let bounds=try NativeFinalTextPaintAdmission.retainedFootprint(incumbent.batch.primitives[0]).bounds
                let intervals=policy.exteriorPackingIntervals(crossStart:cross,crossExtent:bounds.height,horizontal:true,page:page)
                let gap=ceil(cohort.map {$0.fontSize*scale}.max()! * 0.12)+1
                for interval in intervals {
                    let share=floor((interval.1-interval.0-gap*CGFloat(n-1))/CGFloat(n))
                    if share>2*inset,share<=capacity.width {jointWidths.append(share)}
                }
                jointWidths=Array(jointWidths.sorted().prefix(1))
            }
        }
        let ordinary=jointWidths + measured + [capacity.width,baseWidth] +
            (policy?.candidates.map {CGFloat($0[2])*page.width} ?? []) +
            [capacity.width*0.5,capacity.width*0.75,capacity.width*0.375,capacity.width*0.25]
        // The same-font fallback must try the incumbent allocation before the
        // finite lexical endpoint list consumes all shape slots.
        let prioritized=NativeEffectSafePitch.current != nil ? [baseWidth]+ordinary:ordinary
        let generated=NativeFixedFontRecovery.metrics?.count(owner:item.id,fontPixels:fontPixels) ?? (incumbent == nil ? 0:1)
        let remaining:Int
        if let budget=NativeRecoveryDrawBudget.current,budget.recoveryActive {
            remaining=min(budget.remaining(owner:item.id,fontPixels:fontPixels),8-(incumbent == nil ? 0:1))
        } else {remaining=max(0,8-generated)}
        var plans:[NativeOwnerOutputWidthPlan?]=incumbent == nil && remaining>0 ? [nil]:[]
        var seenWidths=Set<Int>()
        for width in prioritized where width.isFinite && width>2*inset && width<=capacity.width {
            if plans.count>=remaining {break}
            if seenWidths.insert(Int((width*16).rounded())).inserted {plans.append(.init(outputPixels:width))}
            if plans.count>=remaining {break}
        }
        var alternatives=incumbent.map {[$0]} ?? [],seenShapes=Set<String>()
        func shapeKey(_ batch:FixedFontPreparedBatch)->String {
            let row=batch.audit[0],frame=batch.primitives[0].frame
            return "\(row["lineRangesUTF16"] ?? "")|\(row["retainedLinePitchOutputPixels"] ?? "")|\(frame.width)|\(frame.height)"
        }
        if let incumbent {seenShapes.insert(shapeKey(incumbent.batch))}
        for plan in plans {
            try Task.checkCancellation()
            let map=plan.map {[item.id:$0]} ?? [:]
            do {
                let shape=try renderPrimitives(items:[item],viewport:viewport,restored:restored,allowShrink:false,
                    contours:contours,options:options,excludedTailOwners:[],recordRefinement:{_ in},
                    outputWidthPlans:map,pitchFamilyItems:items)
                var keepGeneratedShape=false
                defer {
                    if !keepGeneratedShape {
                        for primitive in shape.primitives {
                            NativeFixedFontRecovery.metrics?.activeCache?.releaseDiscarded(image:primitive.image)
                        }
                    }
                }
                guard shape.audit.count==1,shape.primitives.count==1,
                      let row=shape.audit.first,let actualFont=row["fontSize"] as? Double,
                      abs(actualFont-Double(item.fontSize))<0.0000001,
                      row["visibleUTF16"] as? Int==item.text.utf16.count else {throw invalidGeometry()}
                let batch=FixedFontPreparedBatch(audit:shape.audit,primitives:shape.primitives)
                if seenShapes.insert(shapeKey(batch)).inserted,alternatives.count<8 {
                    alternatives.append(.init(widthPlan:plan,batch:batch))
                    keepGeneratedShape=true
                }
            } catch is CancellationError {throw CancellationError()}
            catch let e as NativeRecoveryDrawBudget.Failure {rejected["additionalDrawBudget:\(e)",default:0]+=1;break}
            catch let e as NativeEffectSafePitch.Failure {rejected["measuredEffectPitch:\(e)",default:0]+=1}
            catch NativeWholeWordWrap.Failure.noFittingLayout {rejected["noFittingLayout",default:0]+=1}
            catch NativeFinalTextPaintAdmission.Failure.noSafePlacement {rejected["noSafePlacement",default:0]+=1}
            catch Failure.incompleteText {rejected["incompleteShape",default:0]+=1}
            catch Failure.invalidGeometry where plan != nil {
                // Source/style/guide packets were validated before enumeration.
                // Only this typed width changed. Preserve the original cause.
                rejected["invalidWidthPlanGeometry",default:0]+=1
            }
        }
        func quality(_ candidate:FixedFontShapeCandidate)->(Int,Int,CGFloat) {
            let ranges=(candidate.batch.audit[0]["lineRangesUTF16"] as? [[Int]] ?? [])
                .map {NSRange(location:$0[0],length:$0[1])}
            return (NativeRenderWrapQuality.wordCutOffsets(item.text,ranges:ranges).count,
                ranges.count,abs(candidate.batch.primitives[0].frame.width-baseWidth))
        }
        let first=incumbent == nil ? 0:1
        if alternatives.count>first {
            let ranked=alternatives.dropFirst(first).enumerated().sorted { a,b in
                let x=quality(a.element),y=quality(b.element)
                if x.0 != y.0 {return x.0<y.0}
                if x.1 != y.1 {return x.1<y.1}
                return x.2==y.2 ? a.offset<b.offset:x.2<y.2
            }.map(\.element)
            alternatives=Array(alternatives.prefix(first))+ranked
        }
        return alternatives
    }

    /// Apply the existing position-only final polish without surrendering the
    /// successful fixed-font transaction or any unaffected peer pin. No paint.
    private static func polishFixedFontAdmission(
        _ admitted:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
        page:CGRect,fixedPeerOrigins:[String:CGPoint])throws
        ->(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]) {
        try Task.checkCancellation()
        let proposed=NativeFinalTextPaintAdmission.refineFinalPlacement(admitted,page:page)
        try Task.checkCancellation()
        guard proposed.fills.count==admitted.fills.count,proposed.audit.count==admitted.audit.count else{return admitted}
        do {
            for i in admitted.fills.indices {
                let old=admitted.fills[i],new=proposed.fills[i]
                guard let owner=old.ownerID,
                      proposed.audit[i]["owner"] as? String == owner,
                      NativeBodySourceAnchorRecovery.carrierPreserved(old,new,
                        shift:CGPoint(x:new.frame.minX-old.frame.minX,y:new.frame.minY-old.frame.minY)),
                      try NativeMandatoryDisplayStroke.rgba(old.image)==NativeMandatoryDisplayStroke.rgba(new.image) else{return admitted}
                if let pin=fixedPeerOrigins[owner] {
                    guard old.frame==new.frame,
                          try NativeFinalTextPaintAdmission.retainedFootprint(new).bounds.origin==pin else{return admitted}
                }
            }
            var candidate=proposed
            candidate.audit=try NativeBalloonPlacement.RetainedState.preservingKnownSnapshots(
                priorAudit:admitted.audit,admittedAudit:candidate.audit,unknownPolicy:.preservePriorUncertainty)
            if admitted.audit.contains(where:{$0[NativeSourceCohortCenterBalance.auditKey] != nil}) {
                candidate=try NativeSourceCohortCenterBalance.preservingReceipts(prior:admitted,admitted:candidate,page:page)
            }
            return candidate
        } catch is CancellationError {throw CancellationError()}
        catch {return admitted}
    }

    @TaskLocal static var failedRequestCohortPlanning = false
    private static var promotedFailurePlanning:Bool {
        failedRequestCohortPlanning || NativeRecoveryDrawBudget.current?.recoveryActive == true
    }
    static func recoverFixedFont(items:[Item],viewport:CGSize,restored:CGImage,
        contours:[String:NativeRawBalloonCapacity.Contour],options:[String:[String:Any]],cause:String,
        prepared:FixedFontPreparedBatch?=nil)throws -> FixedFontRecoveryOutcome {
        if promotedFailurePlanning {
            return try recoverPromotedFixedFont(items:items,viewport:viewport,restored:restored,
                contours:contours,options:options,cause:cause,prepared:prepared)
        }
        return try recoverIncumbentFixedFont(items:items,viewport:viewport,restored:restored,
            contours:contours,options:options,cause:cause,prepared:prepared)
    }
    /// A successful recovery is a fallback, not proof that its first row plan
    /// is source-nearest. Reuse retained shapes; never draw or unpin a peer.
    private static func preferSourceNearFixedFont(
        _ incumbent:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
        rows:[[String:Any]], texts:[String:String], alternatives:[String:[FixedFontShapeCandidate]],
        page:CGRect,restored:CGImage,verification:NativeAOTTranslationPageComposer.FixedFontVerifiedAdmission
    ) throws -> (admission:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
                 changed:[String:FixedFontShapeCandidate],verified:NativeAOTTranslationPageComposer.FixedFontVerifiedAdmission?) {
        var current=incumbent,changed:[String:FixedFontShapeCandidate]=[:],attempts=0
        var verified:NativeAOTTranslationPageComposer.FixedFontVerifiedAdmission?
        func trace(_ owner:String,_ stage:String,_ detail:[String:Any]=[:]) {
            guard let metrics=NativeFixedFontRecovery.metrics,metrics.sourceNearDiagnostics.count<32 else{return}
            metrics.sourceNearDiagnostics.append(detail.merging(["owner":owner,"stage":stage]){_,new in new})
        }
        let rowByID=Dictionary(uniqueKeysWithValues:rows.compactMap { row -> (String,[String:Any])? in
            (row["id"] as? String).map {($0,row)}
        })
        func ranges(_ row:[String:Any]) -> [NSRange]? {
            guard let raw=row["lineRangesUTF16"] as? [[Int]],raw.allSatisfy({$0.count==2}) else{return nil}
            return raw.map {NSRange(location:$0[0],length:$0[1])}
        }
        for i in current.fills.indices {
            try Task.checkCancellation()
            let old=current.fills[i]
            guard let owner=old.ownerID,let choices=alternatives[owner],
                  old.textExpansionPolicy?.insideBalloon == true,old.balloonTargetRelaxed,
                  let guide=old.textPlacementGuide,guide.valid,
                  abs(guide.sourceRotationRadians ?? 0)<1e-6,
                  let oldRow=rowByID[owner],let oldRanges=ranges(oldRow),
                  let text=texts[owner] else{continue}
            let support=try NativeFinalTextPaintAdmission.retainedFootprint(old)
            let source=guide.rect(in:page),font=max(1,old.fontOutputPixels)
            guard source.height>=2*font,source.height>=source.width*0.8,
                  support.bounds.width>max(source.width*1.25,font*3.5),
                  hypot(support.bounds.midX-source.midX,support.bounds.midY-source.midY)>font else{continue}
            for choice in choices {
                if attempts>=8 {break}
                if let row=choice.batch.audit.first,let candidateRanges=ranges(row) {
                    trace(owner,"candidate-preflight",["ranges":candidateRanges.map{[$0.location,$0.length]},
                        "qualityAllows":NativeBalloonReadabilityReflow.qualityAllows(.init(text:text,ranges:oldRanges),candidateRanges),
                        "softWordCuts":row["softWordCuts"] ?? NSNull(),"oneCharacterRowsProxy":row["oneCharacterRowsProxy"] ?? NSNull(),
                        "shortSoftTails":row["shortSoftTails"] ?? NSNull()])
                }
                guard let row=choice.batch.audit.first,let newRanges=ranges(row),
                      (1...2).contains(newRanges.count-oldRanges.count),
                      row["visibleUTF16"] as? Int == text.utf16.count,
                      NativeBalloonReadabilityReflow.validOwnership(text,newRanges),
                      NativeBalloonReadabilityReflow.qualityAllows(.init(text:text,ranges:oldRanges),newRanges),
                      let primitive=choice.batch.primitives.first,
                      primitive.fontOutputPixels==old.fontOutputPixels,
                      (row["softWordCuts"] as? Int ?? Int.max)<=(oldRow["softWordCuts"] as? Int ?? 0),
                      (row["oneCharacterRowsProxy"] as? Int ?? Int.max)<=(oldRow["oneCharacterRowsProxy"] as? Int ?? 0),
                      (row["shortSoftTails"] as? Int ?? Int.max)<=(oldRow["shortSoftTails"] as? Int ?? 0) else{continue}
                var replacement=old
                replacement.image=primitive.image;replacement.frame=primitive.frame
                // Keep the candidate's shape-bound paint snapshot exactly.
                replacement.sourceStyle=primitive.sourceStyle
                trace(owner,"row-quality-eligible",["oldAppearancePresent":old.sourceAppearance != nil,
                    "candidateAppearancePresent":primitive.sourceAppearance != nil,
                    "appearanceEqual":old.sourceAppearance.map {NSDictionary(dictionary:$0).isEqual(to:primitive.sourceAppearance ?? [:])} ?? (primitive.sourceAppearance == nil)])
                guard (old.sourceAppearance == nil && primitive.sourceAppearance == nil) ||
                    (old.sourceAppearance.map {NSDictionary(dictionary:$0).isEqual(to:primitive.sourceAppearance ?? [:])} ?? false)
                    else{continue}
                replacement.sourceAppearance=primitive.sourceAppearance
                // Admission normalizes transparent padding before translation.
                // Bind the snapshot to that same retained raster, so harmless
                // cropping cannot masquerade as changed glyph/style pixels.
                replacement=try NativeFinalTextPaintAdmission.tight(replacement)
                trace(owner,"paint-carrier-eligible")
                let proposed=try NativeFinalTextPaintAdmission.retainedFootprint(replacement)
                guard proposed.bounds.width<support.bounds.width else{continue}
                let shift=guide.preferredShift(bounds:proposed.bounds,page:page)
                let target=proposed.bounds.offsetBy(dx:shift.x,dy:shift.y)
                let oldShift=guide.preferredShift(bounds:support.bounds,page:page)
                guard hypot(target.midX-source.midX,target.midY-source.midY) + 1 <
                        hypot(support.bounds.midX-source.midX,support.bounds.midY-source.midY),
                      hypot(oldShift.x,oldShift.y)>1 else{continue}
                let before=try current.fills.map {try NativeFinalTextPaintAdmission.retainedFootprint($0)}
                var fixed=Dictionary(uniqueKeysWithValues:current.fills.indices.map {
                    (current.fills[$0].ownerID!,before[$0].bounds.origin)
                })
                fixed[owner]=target.origin
                var fills=current.fills;fills[i]=replacement
                attempts+=1
                trace(owner,"native-admission-attempt")
                do {
                    NativeFixedFontRecovery.metrics?.placementAttempts += 1
                    let admitted=try NativeFinalTextPaintAdmission.place(fills,page:page,fixedOrigins:fixed)
                    if admitted.fills.count==current.fills.count {
                        trace(owner,"admitted-carrier-check",["packetChangedOwners":admitted.fills.indices.filter {
                            admitted.fills[$0].balloonPlacement != current.fills[$0].balloonPlacement
                        }.compactMap {current.fills[$0].ownerID},"relaxationChangedOwners":admitted.fills.indices.filter {
                            admitted.fills[$0].balloonTargetRelaxed != current.fills[$0].balloonTargetRelaxed
                        }.compactMap {current.fills[$0].ownerID}])
                    }
                    guard admitted.fills.count==current.fills.count,
                          admitted.fills.indices.allSatisfy({ j in
                              admitted.fills[j].balloonPlacement==current.fills[j].balloonPlacement &&
                              (j == i ? !admitted.fills[j].balloonTargetRelaxed || current.fills[j].balloonTargetRelaxed :
                                admitted.fills[j].balloonTargetRelaxed==current.fills[j].balloonTargetRelaxed)
                          }) else{continue}
                    let after=try admitted.fills.map {try NativeFinalTextPaintAdmission.retainedFootprint($0)}
                    let actual=admitted.fills[i]
                    let actualShift=CGPoint(x:actual.frame.minX-replacement.frame.minX,
                        y:actual.frame.minY-replacement.frame.minY)
                    trace(owner,"shape-snapshot-check",["boundsExact":after[i].bounds==target,
                        "carrierExact":NativeBodySourceAnchorRecovery.carrierPreserved(replacement,actual,shift:actualShift,preserveRelaxation:false),
                        "pendingContourExact":actual.sourceStyle?.pendingRoundedContour?.identity == replacement.sourceStyle?.pendingRoundedContour?.identity,
                        "rgbaExact":try NativeMandatoryDisplayStroke.rgba(actual.image)==NativeMandatoryDisplayStroke.rgba(replacement.image)])
                    guard after[i].bounds==target,
                          NativeBodySourceAnchorRecovery.carrierPreserved(replacement,actual,
                            shift:actualShift,preserveRelaxation:false),
                          actual.sourceStyle?.pendingRoundedContour?.identity == replacement.sourceStyle?.pendingRoundedContour?.identity,
                          try NativeMandatoryDisplayStroke.rgba(actual.image)==NativeMandatoryDisplayStroke.rgba(replacement.image)
                          else{continue}
                    var peersPreserved=true
                    for j in fills.indices where j != i {
                        let samePeerRaster = try NativeMandatoryDisplayStroke.rgba(current.fills[j].image) ==
                            NativeMandatoryDisplayStroke.rgba(admitted.fills[j].image)
                        if admitted.fills[j].frame != current.fills[j].frame || after[j].bounds != before[j].bounds ||
                            !NativeBodySourceAnchorRecovery.carrierPreserved(current.fills[j],admitted.fills[j],shift:.zero) ||
                            !samePeerRaster {
                            peersPreserved=false;break
                        }
                        let desired=ceil(min(old.fontOutputPixels,current.fills[j].fontOutputPixels)*0.35)
                        let a=NativeAdaptiveTextGutter.clearance(before[i].readableBounds ?? before[i].bounds,
                            before[j].readableBounds ?? before[j].bounds) ?? desired
                        let b=NativeAdaptiveTextGutter.clearance(after[i].readableBounds ?? after[i].bounds,
                            after[j].readableBounds ?? after[j].bounds) ?? desired
                        if b+0.01<min(a,desired){peersPreserved=false;break}
                    }
                    if let packet=old.balloonPlacement {
                        for j in fills.indices where j != i && current.fills[j].balloonPlacement?.bodyID==packet.bodyID {
                            guard let peer=current.fills[j].balloonPlacement,peer.order != packet.order else {
                                peersPreserved=false;break
                            }
                            let a=packet.flow == .row ? after[i].bounds.midX:after[i].bounds.midY
                            let b=packet.flow == .row ? after[j].bounds.midX:after[j].bounds.midY
                            if peer.order<packet.order ? b>=a:b<=a {peersPreserved=false;break}
                            // Packet order is not a substitute for source flow.
                            guard let peerGuide=current.fills[j].textPlacementGuide,peerGuide.valid else {
                                peersPreserved=false;break
                            }
                            let peerSource=peerGuide.rect(in:page)
                            let sourceA=packet.flow == .row ? source.midX:source.midY
                            let sourceB=packet.flow == .row ? peerSource.midX:peerSource.midY
                            if sourceB<sourceA && b>=a || sourceB>sourceA && b<=a {
                                peersPreserved=false;break
                            }
                        }
                    }
                    guard peersPreserved else{trace(owner,"peer-or-flow-veto");continue}
                    if let proof=NativeEffectSafePitch.current {
                        var trialRows=rows
                        if let k=trialRows.firstIndex(where:{$0["id"] as? String == owner}) {trialRows[k]=row}
                        try proof.validateFamilies(trialRows);try proof.recordAdmission()
                    }
                    NativeFixedFontRecovery.metrics?.verificationAttempts += 1
                    let proof=try NativeAOTTranslationPageComposer.verifyFixedFontAdmission(restored:restored,admitted:admitted,reusing:verification)
                    var audit=current.audit;audit[i]=admitted.audit[i]
                    audit[i]["fixedFontSourceNearRecovery"]=["retainedShapeOnly":true,"fixedPeers":fixed.keys.sorted(),
                        "oldBounds":[support.bounds.minX,support.bounds.minY,support.bounds.width,support.bounds.height],
                        "newBounds":[target.minX,target.minY,target.width,target.height],"attempts":attempts]
                    current=(admitted.fills,audit);changed[owner]=choice;verified=proof
                    return (current,changed,verified)
                } catch is CancellationError {throw CancellationError()}
                catch {trace(owner,"native-verification-rejected",["error":String(reflecting:error)]);continue} // Keep the already verified complete fallback.
            }
        }
        return (current,changed,verified)
    }

    private static func recoverIncumbentFixedFont(items:[Item],viewport:CGSize,restored:CGImage,
        contours:[String:NativeRawBalloonCapacity.Contour],options:[String:[String:Any]],cause:String,
        prepared:FixedFontPreparedBatch?=nil)throws -> FixedFontRecoveryOutcome {
        if NativeFixedFontRecovery.metrics == nil {
            return try NativeFixedFontRecovery.withMetrics {
                try recoverFixedFont(items:items,viewport:viewport,restored:restored,contours:contours,
                    options:options,cause:cause,prepared:prepared)
            }
        }
        let recoveryMetrics=NativeFixedFontRecovery.metrics!
        recoveryMetrics.beginRecovery()
        defer {recoveryMetrics.recoveryActive=false}
        let closure=try fixedFontClosure(Set(cause.split(separator:",").map(String.init)),items:items,options:options)
        let page=CGRect(x:0,y:0,width:restored.width,height:restored.height)
        var baseline:[String:FixedFontShapeCandidate]=[:],rejected:[String:Int]=[:]
        if let prepared {
            let known=Set(items.map(\.id))
            guard prepared.audit.count==prepared.primitives.count,prepared.audit.count<=items.count else {throw invalidGeometry()}
            for index in prepared.audit.indices {
                guard let owner=prepared.audit[index]["id"] as? String,known.contains(owner),baseline[owner]==nil,
                      prepared.primitives[index].ownerID==owner else {throw invalidGeometry()}
                baseline[owner] = .init(widthPlan:nil,batch:.init(audit:[prepared.audit[index]],primitives:[prepared.primitives[index]]))
            }
        }
        // Charge only this actual supplied batch, once at recovery entry.
        // Ordinary discarded candidate rasters were never cache-owned.
        for owner in baseline.keys.sorted() {
            let primitive=baseline[owner]!.batch.primitives[0]
            let support=try NativeFinalTextPaintAdmission.retainedFootprint(primitive)
            try recoveryMetrics.cache.retain(owner:owner,image:primitive.image,runCount:support.runs.count)
            recoveryMetrics.baselineChargedOwners.insert(owner)
            recoveryMetrics.baselineShapesByFont["\(owner)|\(Double(primitive.fontOutputPixels).bitPattern)"]=1
        }
        var alternatives:[String:[FixedFontShapeCandidate]]=[:]
        for item in items {
            if closure.contains(item.id) {
                alternatives[item.id]=try fixedFontShapeAlternatives(item:item,items:items,viewport:viewport,
                    restored:restored,contours:contours,options:options,incumbent:baseline[item.id],rejected:&rejected)
            } else if baseline[item.id]==nil {
                // The original failure preceded a complete batch. Prepare each
                // untouched peer exactly once, with the COMPLETE family pitch.
                let shape=try renderPrimitives(items:[item],viewport:viewport,restored:restored,allowShrink:false,
                    contours:contours,options:options,excludedTailOwners:[],recordRefinement:{_ in},pitchFamilyItems:items)
                guard shape.audit.count==1,shape.primitives.count==1 else {throw invalidGeometry()}
                baseline[item.id] = .init(widthPlan:nil,batch:.init(audit:shape.audit,primitives:shape.primitives))
            }
        }
        let owners=closure.sorted {
            let a=alternatives[$0]!.count,b=alternatives[$1]!.count
            return a==b ? $0<$1:a<b
        }
        let peers=items.filter {!closure.contains($0.id)}.map {baseline[$0.id]!.batch.primitives[0]}
        // Closure includes entire body/type/fit/source-cluster groups. Therefore
        // admitting this peer set cannot split an unaffected group.
        let retainedPeers:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]])
        NativeFixedFontRecovery.metrics?.peerPreparationCalls += 1
        do {retainedPeers=try NativeFinalTextPaintAdmission.place(peers,page:page)}
        catch NativeFinalTextPaintAdmission.Failure.noSafePlacement(let peerCause) {
            let receipt=NativeFixedFontRecovery.Receipt(status:.unaffectedPeerAdmissionFailed,combinations:0,nodes:0,selected:nil)
            var audit=receipt.audit;audit["originalCause"]=cause;audit["unaffectedPeerCause"]=peerCause
            return .init(attempt:nil,receipt:receipt,audit:audit,rejectedPlans:["unaffectedPeerAdmission":1])
        }
        var fixed:[String:CGPoint]=[:],peerByID:[String:NativeAOTTranslationPageComposer.TranslatedFillPrimitive]=[:]
        for peer in retainedPeers.fills {
            guard let owner=peer.ownerID else {throw invalidGeometry()}
            fixed[owner]=try NativeFinalTextPaintAdmission.retainedFootprint(peer).bounds.origin
            peerByID[owner]=peer
        }
        var selectedBatch:FixedFontPreparedBatch?,selectedPlans:[String:Double]=[:]
        var selectedVerification:NativeAOTTranslationPageComposer.FixedFontVerifiedAdmission?
        var selectedAdmission:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]])?
        var receipt=try NativeFixedFontRecovery.search(counts:owners.map {alternatives[$0]!.count},maxCombinations:NativeSourceObstructionRecovery.current == nil ? 64:8) { indices in
            var byID=baseline
            for (index,owner) in owners.enumerated() {byID[owner]=alternatives[owner]![indices[index]]}
            var fills=items.map {peerByID[$0.id] ?? byID[$0.id]!.batch.primitives[0]}
            var rows=items.map {byID[$0.id]!.batch.audit[0]}
            do {
                if let proof=NativeEffectSafePitch.current {try proof.validateFamilies(rows);try proof.recordAdmission()}
                NativeFixedFontRecovery.metrics?.placementAttempts += 1
                let admitted=try NativeFinalTextPaintAdmission.place(fills,page:page,fixedOrigins:fixed)
                for peer in admitted.fills where fixed[peer.ownerID ?? ""] != nil {
                    let support=try NativeFinalTextPaintAdmission.retainedFootprint(peer)
                    guard support.bounds.origin==fixed[peer.ownerID!] else {throw invalidGeometry()}
                }
                if NativeEffectSafePitch.current != nil {
                    guard admitted.fills.allSatisfy({$0.frame == $0.frame.integral}) else {throw NativeEffectSafePitch.Failure.unsafeRows}
                }
                var finalAdmission=try polishFixedFontAdmission(admitted,page:page,fixedPeerOrigins:fixed)
                if let quality=NativeSourceObstructionRecovery.current {
                    finalAdmission=quality.prefer(original:admitted,polished:finalAdmission,page:page)
                }
                NativeFixedFontRecovery.metrics?.verificationAttempts += 1
                var verified:NativeAOTTranslationPageComposer.FixedFontVerifiedAdmission
                do {
                    verified=try NativeAOTTranslationPageComposer.verifyFixedFontAdmission(restored:restored,admitted:finalAdmission)
                } catch is CancellationError {throw CancellationError()}
                catch {
                    // A polish rejection cannot discard a successful original
                    // placement. Validate that original before the ONE paint.
                    finalAdmission=admitted
                    NativeFixedFontRecovery.metrics?.verificationAttempts += 1
                    verified=try NativeAOTTranslationPageComposer.verifyFixedFontAdmission(restored:restored,admitted:admitted)
                }
                if NativeEffectSafePitch.current != nil {
                    guard finalAdmission.fills.allSatisfy({$0.frame == $0.frame.integral}) else {throw NativeEffectSafePitch.Failure.unsafeRows}
                }
                do {
                let sourceNear=try preferSourceNearFixedFont(finalAdmission,rows:rows,
                    texts:Dictionary(uniqueKeysWithValues:items.map {($0.id,$0.text)}),
                    alternatives:alternatives,page:page,restored:restored,verification:verified)
                if let sourceVerified=sourceNear.verified {
                    verified=sourceVerified
                    finalAdmission=sourceNear.admission
                    for (owner,shape) in sourceNear.changed {byID[owner]=shape}
                    fills=items.map {peerByID[$0.id] ?? byID[$0.id]!.batch.primitives[0]}
                    rows=items.map {byID[$0.id]!.batch.audit[0]}
                }
                } catch is CancellationError {throw CancellationError()}
                catch { /* Optional recovery cannot discard a verified fallback. */ }
                selectedBatch = .init(audit:rows,primitives:fills);selectedAdmission=finalAdmission;selectedVerification=verified
                selectedPlans=Dictionary(uniqueKeysWithValues:owners.compactMap {owner in
                    byID[owner]!.widthPlan.map {(owner,Double($0.outputPixels))}
                })
                return true
            } catch is CancellationError {throw CancellationError()}
            catch is NativeEffectSafePitch.Failure {rejected["effectPitchProofRejected",default:0]+=1;return false}
            catch NativeFinalTextPaintAdmission.Failure.noSafePlacement {rejected["nativePlacementRejected",default:0]+=1;return false}
            catch NativeFinalTextPaintAdmission.Failure.finalInvariant {
                rejected["nativeFinalInvariant",default:0]+=1;return false
            }
            catch NativeFinalTextPaintAdmission.Failure.clippedEffects {
                rejected["nativeClippedEffects",default:0]+=1;return false
            }
            catch NativeFinalTextPaintAdmission.Failure.finalCollision {
                rejected["nativeFinalCollision",default:0]+=1;return false
            }
            catch NativeFinalTextPaintAdmission.Failure.invalidGeometry {
                // All primitive input was prepared/validated once. This failure
                // is a combination incompatibility, not a source input rewrite.
                rejected["nativeCombinationGeometry",default:0]+=1;return false
            }
        }
        var audit=receipt.audit
        audit["retainedShapeEligibility"]=alternatives.mapValues { shapes in shapes.map { shape -> [String:Any] in
            let row=shape.batch.audit[0]
            return ["widthPlan":shape.widthPlan.map {Double($0.outputPixels)} as Any? ?? NSNull(),
                "ranges":row["lineRangesUTF16"] ?? NSNull(),"font":row["fontSize"] ?? NSNull(),
                "pitch":row["retainedLinePitchOutputPixels"] ?? NSNull(),
                "visibleUTF16":row["visibleUTF16"] ?? NSNull()]
        } }
        audit["selectedShapeIndicesScope"]="first feasible fallback before optional retained-shape source-near challenge"
        audit["sourceNearDiagnostics"]=NativeFixedFontRecovery.metrics?.sourceNearDiagnostics ?? []
        audit["sourceNearShapeRecoveries"]=selectedAdmission?.audit.compactMap { row -> [String:Any]? in
            guard let detail=row["fixedFontSourceNearRecovery"] else{return nil}
            return ["owner":row["owner"] ?? "unknown","detail":detail]
        } ?? []
        audit["originalCause"]=cause
        audit["owners"]=owners;audit["shapeCounts"]=owners.map {alternatives[$0]!.count}
        audit["outputWidthsPixels"]=selectedPlans;audit["fixedPeerOwners"]=fixed.keys.sorted()
        audit["fixedPeerOriginsPixels"]=fixed.mapValues {[Double($0.x),Double($0.y)]}
        audit["rejectedPlans"]=rejected;audit["completePeerAdmissionRequired"]=true
        audit["shapeGenerations"]=NativeFixedFontRecovery.metrics?.shapeGenerations ?? [:]
        audit["ordinaryShapeGenerations"]=recoveryMetrics.ordinaryShapeGenerations
        audit["baselineChargedOwners"]=recoveryMetrics.baselineChargedOwners.sorted()
        audit["cacheScope"]="supplied recovery baseline and retained recovery candidates only; ordinary discarded rasters not retained"
        audit["placementAttempts"]=NativeFixedFontRecovery.metrics?.placementAttempts ?? receipt.combinations
        audit["verificationAttempts"]=NativeFixedFontRecovery.metrics?.verificationAttempts ?? 0
        audit["cacheBudget"]=NativeFixedFontRecovery.metrics?.cache.audit ?? [:]
        audit["cacheAccounting"]="conservative charged image/witness/run data, including discarded alternatives; not process RSS or native solver transient memory"
        audit["nativePlacementCallScope"]="placementAttempts counts combination trials; these counters exclude internal native solve nodes"
        audit["initialPlacementCalls"]=NativeFixedFontRecovery.metrics?.initialPlacementCalls ?? 0
        audit["peerPreparationCalls"]=NativeFixedFontRecovery.metrics?.peerPreparationCalls ?? 0
        audit["combinationGraphNodeScope"]="bounded queue entries, not native placement internal nodes"
        guard let batch=selectedBatch,let admitted=selectedAdmission,let verified=selectedVerification else {
            return .init(attempt:nil,receipt:receipt,audit:audit,rejectedPlans:rejected)
        }
        NativeFixedFontRecovery.metrics?.paintCalls += 1
        let painted:NativeAOTTranslationPageComposer.TextLayer
        do {
            painted=try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(verified:verified,
                expectedItems:items.count,textComplete:true)
        } catch NativeFinalTextPaintAdmission.Failure.noSafePlacement {
            receipt = .init(status:.finalVerificationRejected,combinations:receipt.combinations,nodes:receipt.nodes,selected:nil)
            rejected["finalVerificationRejected",default:0]+=1
            audit.merge(receipt.audit) {_,new in new};audit["rejectedPlans"]=rejected
            return .init(attempt:nil,receipt:receipt,audit:audit,rejectedPlans:rejected)
        }
        var metadata=painted.audit
        var rows=batch.audit
        if let decisions=metadata["endpointDecisions"] as? [[String:Any]] {
            for i in rows.indices {
                rows[i]["finalStrokeDecision"]=decisions[i]
                rows[i]["finalDisplayFill"]=decisions[i]["displayFillRGB"]
                rows[i]["finalDisplayStroke"]=decisions[i]["finalDisplayStroke"] ?? decisions[i]["finalEndpoint"].map {[$0,$0,$0]}
            }
        }
        metadata["rawNativeItems"]=rows;metadata["legacyPrepareTextBoxesInvoked"]=false
        metadata["forcedCapacityFallback"]=false;metadata["fontRefitForHalo"]=false
        metadata["opaquePanelsPainted"]=false
        metadata["baselineLimitations"]="bounded same-font recovery; saved source policy/masks are proxies, not independent physical or visual proof"
        metadata["recoverySourceScope"]="retained source/text/style packets; no fresh source inference or OCR"
        metadata["semanticCompletenessAuthority"]="caller text and native visible UTF16 accounting; no semantic inference"
        audit["paintCalls"]=NativeFixedFontRecovery.metrics?.paintCalls ?? 1
        metadata["fixedFontRecovery"]=audit
        let layer=NativeAOTTranslationPageComposer.TextLayer(image:painted.image,expectedItems:items.count,
            paintedItems:painted.paintedItems,complete:painted.complete,audit:metadata)
        return .init(attempt:(value:layer,excludedOwners:[],primitives:admitted.fills),receipt:receipt,audit:audit,rejectedPlans:rejected)
    }

    private static func recoverPromotedFixedFont(items:[Item],viewport:CGSize,restored:CGImage,
        contours:[String:NativeRawBalloonCapacity.Contour],options:[String:[String:Any]],cause:String,
        prepared:FixedFontPreparedBatch?=nil)throws -> FixedFontRecoveryOutcome {
        if NativeFixedFontRecovery.metrics == nil {
            return try NativeFixedFontRecovery.withMetrics {
                try recoverFixedFont(items:items,viewport:viewport,restored:restored,contours:contours,
                    options:options,cause:cause,prepared:prepared)
            }
        }
        let recoveryMetrics=NativeFixedFontRecovery.metrics!
        recoveryMetrics.beginRecovery()
        defer {recoveryMetrics.recoveryActive=false}
        var closure=try fixedFontClosure(Set(cause.split(separator:",").map(String.init)),items:items,options:options)
        let page=CGRect(x:0,y:0,width:restored.width,height:restored.height)
        var baseline:[String:FixedFontShapeCandidate]=[:],rejected:[String:Int]=[:]
        if let prepared {
            let known=Set(items.map(\.id))
            guard prepared.audit.count==prepared.primitives.count,prepared.audit.count<=items.count else {throw invalidGeometry()}
            for index in prepared.audit.indices {
                guard let owner=prepared.audit[index]["id"] as? String,known.contains(owner),baseline[owner]==nil,
                      prepared.primitives[index].ownerID==owner else {throw invalidGeometry()}
                baseline[owner] = .init(widthPlan:nil,batch:.init(audit:[prepared.audit[index]],primitives:[prepared.primitives[index]]))
            }
        }
        // Charge only this actual supplied batch, once at recovery entry.
        // Ordinary discarded candidate rasters were never cache-owned.
        for owner in baseline.keys.sorted() {
            let primitive=baseline[owner]!.batch.primitives[0]
            let support=try NativeFinalTextPaintAdmission.retainedFootprint(primitive)
            try recoveryMetrics.cache.retain(owner:owner,image:primitive.image,runCount:support.runs.count)
            recoveryMetrics.baselineChargedOwners.insert(owner)
            recoveryMetrics.baselineShapesByFont["\(owner)|\(Double(primitive.fontOutputPixels).bitPattern)"]=1
        }
        // A peer is provisional until THIS complete recovery baseline admits it.
        // Promote actual failing peers through the full existing ownership closure;
        // never pin an unadmitted group or spend alternative draws before this step.
        var promotions:[[String:Any]]=[]
        var retainedPeerValue:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]])?
        for round in 0..<min(8,items.count) {
            try Task.checkCancellation()
            for item in items where !closure.contains(item.id) && baseline[item.id]==nil {
                let shape=try renderPrimitives(items:[item],viewport:viewport,restored:restored,allowShrink:false,
                    contours:contours,options:options,excludedTailOwners:[],recordRefinement:{_ in},pitchFamilyItems:items)
                guard shape.audit.count==1,shape.primitives.count==1 else {throw invalidGeometry()}
                baseline[item.id] = .init(widthPlan:nil,batch:.init(audit:shape.audit,primitives:shape.primitives))
            }
            let peers=items.filter {!closure.contains($0.id)}.map {baseline[$0.id]!.batch.primitives[0]}
            NativeFixedFontRecovery.metrics?.peerPreparationCalls += 1
            do {
                retainedPeerValue=try NativeFinalTextPaintAdmission.place(peers,page:page)
                break
            } catch NativeFinalTextPaintAdmission.Failure.noSafePlacement(let peerCause) {
                let next=try fixedFontClosure(closure.union(peerCause.split(separator:",").map(String.init)),items:items,options:options)
                promotions.append(["round":round,"actualFailedPeers":peerCause,"oldClosure":closure.sorted(),"newClosure":next.sorted()])
                guard next != closure, round+1<min(8,items.count) else {
                    let receipt=NativeFixedFontRecovery.Receipt(status:.unaffectedPeerAdmissionFailed,combinations:0,nodes:0,selected:nil)
                    var audit=receipt.audit;audit["originalCause"]=cause;audit["unaffectedPeerCause"]=peerCause
                    audit["peerClosurePromotions"]=promotions
                    return .init(attempt:nil,receipt:receipt,audit:audit,rejectedPlans:["unaffectedPeerAdmission":1])
                }
                closure=next
            }
        }
        guard let retainedPeers=retainedPeerValue else {throw invalidGeometry()}
        var alternatives:[String:[FixedFontShapeCandidate]]=[:]
        for item in items where closure.contains(item.id) {
            alternatives[item.id]=try fixedFontShapeAlternatives(item:item,items:items,viewport:viewport,
                restored:restored,contours:contours,options:options,incumbent:baseline[item.id],rejected:&rejected)
        }
        let owners=closure.sorted {
            let a=alternatives[$0]!.count,b=alternatives[$1]!.count
            return a==b ? $0<$1:a<b
        }
        var fixed:[String:CGPoint]=[:],peerByID:[String:NativeAOTTranslationPageComposer.TranslatedFillPrimitive]=[:]
        for peer in retainedPeers.fills {
            guard let owner=peer.ownerID else {throw invalidGeometry()}
            fixed[owner]=try NativeFinalTextPaintAdmission.retainedFootprint(peer).bounds.origin
            peerByID[owner]=peer
        }
        var selectedBatch:FixedFontPreparedBatch?,selectedPlans:[String:Double]=[:]
        var selectedVerification:NativeAOTTranslationPageComposer.FixedFontVerifiedAdmission?
        var selectedAdmission:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]])?
        var receipt=try NativeFixedFontRecovery.search(counts:owners.map {alternatives[$0]!.count},maxCombinations:NativeSourceObstructionRecovery.current == nil ? 64:8) { indices in
            var byID=baseline
            for (index,owner) in owners.enumerated() {byID[owner]=alternatives[owner]![indices[index]]}
            var fills=items.map {peerByID[$0.id] ?? byID[$0.id]!.batch.primitives[0]}
            var rows=items.map {byID[$0.id]!.batch.audit[0]}
            do {
                if let proof=NativeEffectSafePitch.current {try proof.validateFamilies(rows);try proof.recordAdmission()}
                NativeFixedFontRecovery.metrics?.placementAttempts += 1
                let admitted=try NativeFinalTextPaintAdmission.place(fills,page:page,fixedOrigins:fixed)
                for peer in admitted.fills where fixed[peer.ownerID ?? ""] != nil {
                    let support=try NativeFinalTextPaintAdmission.retainedFootprint(peer)
                    guard support.bounds.origin==fixed[peer.ownerID!] else {throw invalidGeometry()}
                }
                if NativeEffectSafePitch.current != nil {
                    guard admitted.fills.allSatisfy({$0.frame == $0.frame.integral}) else {throw NativeEffectSafePitch.Failure.unsafeRows}
                }
                var finalAdmission=try polishFixedFontAdmission(admitted,page:page,fixedPeerOrigins:fixed)
                if let quality=NativeSourceObstructionRecovery.current {
                    finalAdmission=quality.prefer(original:admitted,polished:finalAdmission,page:page)
                }
                NativeFixedFontRecovery.metrics?.verificationAttempts += 1
                var verified:NativeAOTTranslationPageComposer.FixedFontVerifiedAdmission
                do {
                    verified=try NativeAOTTranslationPageComposer.verifyFixedFontAdmission(restored:restored,admitted:finalAdmission)
                } catch is CancellationError {throw CancellationError()}
                catch {
                    // A polish rejection cannot discard a successful original
                    // placement. Validate that original before the ONE paint.
                    finalAdmission=admitted
                    NativeFixedFontRecovery.metrics?.verificationAttempts += 1
                    verified=try NativeAOTTranslationPageComposer.verifyFixedFontAdmission(restored:restored,admitted:admitted)
                }
                if NativeEffectSafePitch.current != nil {
                    guard finalAdmission.fills.allSatisfy({$0.frame == $0.frame.integral}) else {throw NativeEffectSafePitch.Failure.unsafeRows}
                }
                do {
                let sourceNear=try preferSourceNearFixedFont(finalAdmission,rows:rows,
                    texts:Dictionary(uniqueKeysWithValues:items.map {($0.id,$0.text)}),
                    alternatives:alternatives,page:page,restored:restored,verification:verified)
                if let sourceVerified=sourceNear.verified {
                    verified=sourceVerified
                    finalAdmission=sourceNear.admission
                    for (owner,shape) in sourceNear.changed {byID[owner]=shape}
                    fills=items.map {peerByID[$0.id] ?? byID[$0.id]!.batch.primitives[0]}
                    rows=items.map {byID[$0.id]!.batch.audit[0]}
                }
                } catch is CancellationError {throw CancellationError()}
                catch { /* Optional recovery cannot discard a verified fallback. */ }
                selectedBatch = .init(audit:rows,primitives:fills);selectedAdmission=finalAdmission;selectedVerification=verified
                selectedPlans=Dictionary(uniqueKeysWithValues:owners.compactMap {owner in
                    byID[owner]!.widthPlan.map {(owner,Double($0.outputPixels))}
                })
                return true
            } catch is CancellationError {throw CancellationError()}
            catch is NativeEffectSafePitch.Failure {rejected["effectPitchProofRejected",default:0]+=1;return false}
            catch NativeFinalTextPaintAdmission.Failure.noSafePlacement {rejected["nativePlacementRejected",default:0]+=1;return false}
            catch NativeFinalTextPaintAdmission.Failure.finalInvariant {
                rejected["nativeFinalInvariant",default:0]+=1;return false
            }
            catch NativeFinalTextPaintAdmission.Failure.clippedEffects {
                rejected["nativeClippedEffects",default:0]+=1;return false
            }
            catch NativeFinalTextPaintAdmission.Failure.finalCollision {
                rejected["nativeFinalCollision",default:0]+=1;return false
            }
            catch NativeFinalTextPaintAdmission.Failure.invalidGeometry {
                // All primitive input was prepared/validated once. This failure
                // is a combination incompatibility, not a source input rewrite.
                rejected["nativeCombinationGeometry",default:0]+=1;return false
            }
        }
        var audit=receipt.audit
        audit["retainedShapeEligibility"]=alternatives.mapValues { shapes in shapes.map { shape -> [String:Any] in
            let row=shape.batch.audit[0]
            return ["widthPlan":shape.widthPlan.map {Double($0.outputPixels)} as Any? ?? NSNull(),
                "ranges":row["lineRangesUTF16"] ?? NSNull(),"font":row["fontSize"] ?? NSNull(),
                "pitch":row["retainedLinePitchOutputPixels"] ?? NSNull(),
                "visibleUTF16":row["visibleUTF16"] ?? NSNull()]
        } }
        audit["selectedShapeIndicesScope"]="first feasible fallback before optional retained-shape source-near challenge"
        audit["sourceNearDiagnostics"]=NativeFixedFontRecovery.metrics?.sourceNearDiagnostics ?? []
        audit["sourceNearShapeRecoveries"]=selectedAdmission?.audit.compactMap { row -> [String:Any]? in
            guard let detail=row["fixedFontSourceNearRecovery"] else{return nil}
            return ["owner":row["owner"] ?? "unknown","detail":detail]
        } ?? []
        audit["originalCause"]=cause
        audit["owners"]=owners;audit["shapeCounts"]=owners.map {alternatives[$0]!.count}
        audit["peerClosurePromotions"]=promotions
        audit["outputWidthsPixels"]=selectedPlans;audit["fixedPeerOwners"]=fixed.keys.sorted()
        audit["fixedPeerOriginsPixels"]=fixed.mapValues {[Double($0.x),Double($0.y)]}
        audit["rejectedPlans"]=rejected;audit["completePeerAdmissionRequired"]=true
        audit["shapeGenerations"]=NativeFixedFontRecovery.metrics?.shapeGenerations ?? [:]
        audit["ordinaryShapeGenerations"]=recoveryMetrics.ordinaryShapeGenerations
        audit["baselineChargedOwners"]=recoveryMetrics.baselineChargedOwners.sorted()
        audit["cacheScope"]="supplied recovery baseline and retained recovery candidates only; ordinary discarded rasters not retained"
        audit["placementAttempts"]=NativeFixedFontRecovery.metrics?.placementAttempts ?? receipt.combinations
        audit["verificationAttempts"]=NativeFixedFontRecovery.metrics?.verificationAttempts ?? 0
        audit["cacheBudget"]=NativeFixedFontRecovery.metrics?.cache.audit ?? [:]
        audit["cacheAccounting"]="conservative charged image/witness/run data, including discarded alternatives; not process RSS or native solver transient memory"
        audit["nativePlacementCallScope"]="placementAttempts counts combination trials; these counters exclude internal native solve nodes"
        audit["initialPlacementCalls"]=NativeFixedFontRecovery.metrics?.initialPlacementCalls ?? 0
        audit["peerPreparationCalls"]=NativeFixedFontRecovery.metrics?.peerPreparationCalls ?? 0
        audit["combinationGraphNodeScope"]="bounded queue entries, not native placement internal nodes"
        guard let batch=selectedBatch,let admitted=selectedAdmission,let verified=selectedVerification else {
            return .init(attempt:nil,receipt:receipt,audit:audit,rejectedPlans:rejected)
        }
        NativeFixedFontRecovery.metrics?.paintCalls += 1
        let painted:NativeAOTTranslationPageComposer.TextLayer
        do {
            painted=try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(verified:verified,
                expectedItems:items.count,textComplete:true)
        } catch NativeFinalTextPaintAdmission.Failure.noSafePlacement {
            receipt = .init(status:.finalVerificationRejected,combinations:receipt.combinations,nodes:receipt.nodes,selected:nil)
            rejected["finalVerificationRejected",default:0]+=1
            audit.merge(receipt.audit) {_,new in new};audit["rejectedPlans"]=rejected
            return .init(attempt:nil,receipt:receipt,audit:audit,rejectedPlans:rejected)
        }
        var metadata=painted.audit
        var rows=batch.audit
        if let decisions=metadata["endpointDecisions"] as? [[String:Any]] {
            for i in rows.indices {
                rows[i]["finalStrokeDecision"]=decisions[i]
                rows[i]["finalDisplayFill"]=decisions[i]["displayFillRGB"]
                rows[i]["finalDisplayStroke"]=decisions[i]["finalDisplayStroke"] ?? decisions[i]["finalEndpoint"].map {[$0,$0,$0]}
            }
        }
        metadata["rawNativeItems"]=rows;metadata["legacyPrepareTextBoxesInvoked"]=false
        metadata["forcedCapacityFallback"]=false;metadata["fontRefitForHalo"]=false
        metadata["opaquePanelsPainted"]=false
        metadata["baselineLimitations"]="bounded same-font recovery; saved source policy/masks are proxies, not independent physical or visual proof"
        metadata["recoverySourceScope"]="retained source/text/style packets; no fresh source inference or OCR"
        metadata["semanticCompletenessAuthority"]="caller text and native visible UTF16 accounting; no semantic inference"
        audit["paintCalls"]=NativeFixedFontRecovery.metrics?.paintCalls ?? 1
        metadata["fixedFontRecovery"]=audit
        let layer=NativeAOTTranslationPageComposer.TextLayer(image:painted.image,expectedItems:items.count,
            paintedItems:painted.paintedItems,complete:painted.complete,audit:metadata)
        return .init(attempt:(value:layer,excludedOwners:[],primitives:admitted.fills),receipt:receipt,audit:audit,rejectedPlans:rejected)
    }

    private static func recoverMeasuredEffectPitch(items:[Item],viewport:CGSize,restored:CGImage,
        contours:[String:NativeRawBalloonCapacity.Contour],options:[String:[String:Any]],cause:String,
        prepared:FixedFontPreparedBatch?,prior:FixedFontRecoveryOutcome)throws->FixedFontRecoveryOutcome {
        guard !items.contains(where:{vertical(options[$0.id])}) else{return prior}
        let page=CGRect(x:0,y:0,width:restored.width,height:restored.height),scale=page.width/viewport.width
        // Reuse already prepared rasters to diagnose complete unaffected groups
        // BEFORE allocating any new pitch/shape alternatives.
        var seeds=Set(cause.split(separator:",").map(String.init))
        if let c=prior.audit["unaffectedPeerCause"] as?String {seeds.formUnion(c.split(separator:",").map(String.init))}
        if let prepared,prepared.primitives.count==items.count {
            for _ in 0..<min(8,items.count) {
                let closure=try fixedFontClosure(seeds,items:items,options:options)
                let peers=prepared.primitives.filter {!closure.contains($0.ownerID ?? "")}
                do {_ = try NativeFinalTextPaintAdmission.place(peers,page:page);break}
                catch NativeFinalTextPaintAdmission.Failure.noSafePlacement(let ids) {
                    let next=seeds.union(ids.split(separator:",").map(String.init))
                    guard next != seeds else{return prior};seeds=next
                }
            }
        }
        do {
            let configs=try items.map {item -> NativeEffectSafePitch.Config in
                let raw=options[item.id] ?? [:],font=item.fontSize*scale
                let family=(raw["typographyGroupID"] as?String).map {"family:"+$0} ?? "owner:"+item.id
                return .init(owner:item.id,text:item.text,font:font,face:try sourceFontName(raw:raw),family:family,
                    minimum:max(item.lineHeight*scale,CGFloat(raw["lineHeightEm"] as?Double ?? 0)*font),raw:raw,
                    style:try NativeSourceStylePaint.style(raw),sourceOnly:NativeOperationalAppearance.sourceContourOnly(raw))
            }
            let context=try NativeEffectSafePitch.Context(configs,page:page)
            // This is a distinct fallback family, not more slots charged to
            // ordinary wrapping. Both families retain their explicit bounds.
            let limit=NativeFixedFontRecovery.metrics!.cache
            let result=try NativeFixedFontRecovery.withMetrics {
                NativeFixedFontRecovery.metrics!.cache=NativeFixedFontRecovery.CacheBudget(
                    maxPixels:limit.maxPixels,maxRuns:limit.maxRuns,maxBytes:limit.maxBytes)
                return try NativeEffectSafePitch.$current.withValue(context) {
                    try recoverFixedFont(items:items,viewport:viewport,restored:restored,contours:contours,
                        options:options,cause:seeds.sorted().joined(separator:","),prepared:prepared)
                }
            }
            var audit=result.audit;audit["measuredEffectPitch"]=context.audit
            audit["candidateFamily"]="native-measured-effect-safe-pitch"
            if let attempt=result.attempt {
                var metadata=attempt.value.audit;metadata["measuredEffectPitch"]=context.audit
                let layer=NativeAOTTranslationPageComposer.TextLayer(image:attempt.value.image,expectedItems:attempt.value.expectedItems,
                    paintedItems:attempt.value.paintedItems,complete:attempt.value.complete,audit:metadata)
                return .init(attempt:(value:layer,excludedOwners:attempt.excludedOwners,primitives:attempt.primitives),receipt:result.receipt,audit:audit,rejectedPlans:result.rejectedPlans)
            }
            return .init(attempt:nil,receipt:result.receipt,audit:audit,rejectedPlans:result.rejectedPlans)
        } catch is CancellationError {throw CancellationError()}
        catch {var audit=prior.audit;audit["measuredEffectPitchError"]=String(reflecting:error)
            return .init(attempt:nil,receipt:prior.receipt,audit:audit,rejectedPlans:prior.rejectedPlans)}
    }

    private static func renderImplAttempt(items: [Item], viewport: CGSize, restored: CGImage, allowShrink: Bool,
                                   contours: [String: NativeRawBalloonCapacity.Contour], options: [String:[String:Any]] = [:],
                                   completePeerContext:Bool=true) throws -> NativeAOTTranslationPageComposer.TextLayer {
        if NativeFixedFontRecovery.metrics == nil {
            return try NativeFixedFontRecovery.withMetrics {
                try renderImplAttempt(items:items,viewport:viewport,restored:restored,allowShrink:allowShrink,
                    contours:contours,options:options,completePeerContext:completePeerContext)
            }
        }
        let families=Dictionary(grouping:items.filter {options[$0.id]?["typographyGroupID"] is String},
            by:{options[$0.id]!["typographyGroupID"] as! String})
        let familyFonts=families.mapValues { members in
            let values=members.map(\.fontSize).sorted()
            return values[values.count/2]
        }
        for (group,members) in families where !allowShrink || members.contains(where:{options[$0.id]?["renderPreserveRequestedFontSize"] as? Bool == true}) {
            let fonts=members.map {Double($0.fontSize)}
            guard (fonts.max()! - fonts.min()!)<0.0000001 else {throw FontContractFailure(group:group,requestedFonts:fonts)}
        }
        var current=items.map {item -> Item in
            guard let family=options[item.id]?["typographyGroupID"] as? String,
                  let font=familyFonts[family] else {return item}
            let protected = !allowShrink || families[family]!.contains {
                options[$0.id]?["renderPreserveRequestedFontSize"] as? Bool == true
            }
            let selected=protected ? item.fontSize:font
            return .init(id:item.id,text:item.text,frame:item.frame,fontSize:selected,
                lineHeight:item.lineHeight*selected/item.fontSize,chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
        }
        for retry in 0...8 {
            if let metrics=NativeFixedFontRecovery.metrics {
                let budget=metrics.cache
                metrics.cache=NativeFixedFontRecovery.CacheBudget(maxPixels:budget.maxPixels,maxRuns:budget.maxRuns,maxBytes:budget.maxBytes)
            }
            do {
                var recoveryAudit:[String:Any]?
                let attempt:FixedFontAttempt
                do {
                    attempt=try sourceGuardedAttempt(items:current,viewport:viewport,restored:restored,allowShrink:allowShrink,
                        contours:contours,options:options,capturePreparedFailure:true)
                } catch {
                    let cause:String,prepared:FixedFontPreparedBatch?
                    if let failure=error as? FixedFontPreparedFailure {
                        cause=failure.cause;prepared=failure.prepared
                    } else if let budget=error as? NativeFixedFontRecovery.CacheBudgetFailure {
                        throw FixedFontRecoveryFailure(cause:budget.owner,
                            receipt:.init(status:.cacheBudget,
                                combinations:NativeFixedFontRecovery.metrics?.combinationEvaluations ?? 0,
                                nodes:NativeFixedFontRecovery.metrics?.combinationQueueNodes ?? 0,selected:nil),
                            rejectedPlans:["cacheBudget:"+budget.resource:1],cacheBudget:budget.audit)
                    } else if case NativeFinalTextPaintAdmission.Failure.noSafePlacement(let owners)=error {
                        cause=owners;prepared=nil
                    } else {throw error}
                    var recovered:FixedFontRecoveryOutcome
                    do {
                        if let ledger=NativeRecoveryDrawBudget.current,ledger.recoveryActive,
                           let prior=ledger.legacyFailure as? FixedFontRecoveryFailure {
                            // The entire legacy page (including ordinary width recovery)
                            // already failed. Do not spend new recovery credits replaying it.
                            var priorAudit=prior.diagnostics.merging(prior.receipt.audit) {_,actual in actual}
                            priorAudit["reusedLegacyFailure"]=true;priorAudit["originalCause"]=prior.cause
                            recovered = .init(attempt:nil,receipt:prior.receipt,audit:priorAudit,rejectedPlans:prior.rejectedPlans)
                        } else {
                            recovered=try recoverFixedFont(items:current,viewport:viewport,restored:restored,
                                contours:contours,options:options,cause:cause,prepared:prepared)
                        }
                    } catch let budget as NativeFixedFontRecovery.CacheBudgetFailure {
                        throw FixedFontRecoveryFailure(cause:cause,
                            receipt:.init(status:.cacheBudget,
                                combinations:NativeFixedFontRecovery.metrics?.combinationEvaluations ?? 0,
                                nodes:NativeFixedFontRecovery.metrics?.combinationQueueNodes ?? 0,selected:nil),
                            rejectedPlans:["cacheBudget:"+budget.resource:1],cacheBudget:budget.audit)
                    }
                    if recovered.attempt==nil,NativeEffectSafePitch.fallbackEnabled {
                        recovered=try recoverMeasuredEffectPitch(items:current,viewport:viewport,restored:restored,
                            contours:contours,options:options,cause:cause,prepared:prepared,prior:recovered)
                    }
                    guard let value=recovered.attempt else {
                        let affected=try capacityClosure(Set(cause.split(separator:",").map(String.init)),items:current,options:options)
                        if retry < 8 && options.values.contains(where:{$0["textExpansionPolicy"] is [String:Any]}) &&
                            permitsCapacityFontReduction(allowShrink:allowShrink,affected:affected,options:options) {
                            throw NativeFinalTextPaintAdmission.Failure.noSafePlacement(cause)
                        }
                        throw FixedFontRecoveryFailure(cause:cause,receipt:recovered.receipt,rejectedPlans:recovered.rejectedPlans,diagnostics:recovered.audit)
                    }
                    attempt=value;recoveryAudit=recovered.audit
                }
                let layer=attempt.value
                var metadata=layer.audit
                metadata["jointCapacityRetries"]=retry
                if let recoveryAudit {metadata["fixedFontRecovery"]=recoveryAudit}
                if var records=metadata["rawNativeItems"] as? [[String:Any]] {
                    let requested=Dictionary(uniqueKeysWithValues:items.map {($0.id,Double($0.fontSize))})
                    for i in records.indices {
                        guard let id=records[i]["id"] as? String,let initial=requested[id],
                              let displayed=records[i]["fontSize"] as? Double else {continue}
                        records[i]["capacityRetryInputFontSize"]=records[i]["requestedDisplayFontSize"]
                        records[i]["requestedDisplayFontSize"]=initial
                        records[i]["fontShrunkForCapacity"]=displayed<initial-0.01
                    }
                    metadata["rawNativeItems"]=records
                }
                if !attempt.excludedOwners.isEmpty {
                    metadata["tailRefinementBaselineRetry"]=true
                    metadata["tailRefinementExcludedOwners"]=attempt.excludedOwners.sorted()
                    metadata["tailRefinementBaselineRetryPolicy"]="bounded owner-specific retry; preserve independent refinements and final alpha admission"
                }
                let retained=NativeAOTTranslationPageComposer.TextLayer(image:layer.image,expectedItems:layer.expectedItems,
                    paintedItems:layer.paintedItems,complete:layer.complete,audit:metadata)
                // Recovery already performed complete pinned admission and final
                // paint. Optional terminal geometry must not unpin cached peers.
                if recoveryAudit != nil {
                    if let scope=NativeJointSourceWidthPacking.scope,
                       let admission=retained.audit["finalPaintAdmission"] as? [[String:Any]] {
                        let tuple=(fills:attempt.primitives,audit:admission)
                        scope.record(retained,carrierPixels:tuple.fills.reduce(0){$0+$1.image.width*$1.image.height}) { winner in
                            let lookup=Dictionary(uniqueKeysWithValues:current.map{($0.id,$0)})
                            let oldByID=Dictionary(uniqueKeysWithValues:tuple.fills.compactMap{f in f.ownerID.map{($0,f)}})
                            let shaped=try NativeJointSourceWidthPacking.refine(layer:winner,baseline:tuple,
                                texts:Dictionary(uniqueKeysWithValues:current.map{($0.id,$0.text)}),
                                page:CGRect(x:0,y:0,width:restored.width,height:restored.height),restored:restored,recoveredSelection:true) { id,width,pitch in
                                guard let old=oldByID[id],let item=lookup[id]else{return nil}
                                let scale=CGFloat(restored.width)/viewport.width
                                let proposed=Item(id:id,text:item.text,frame:item.frame,fontSize:old.fontOutputPixels/scale,
                                    lineHeight:pitch/scale,chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
                                let raw=try renderPrimitives(items:[proposed],viewport:viewport,restored:restored,allowShrink:false,
                                    contours:contours,options:options,excludedTailOwners:[id],recordRefinement:{_ in},
                                    retainedPitch:pitch,terminalExteriorContentWidth:width,terminalExteriorFont:old.fontOutputPixels,
                                    terminalExteriorWholeWords:true,pitchFamilyItems:current)
                                guard raw.primitives.count==1,raw.audit.count==1 else{return nil}
                                return(raw.primitives[0],raw.audit[0])
                            }
                            let proof=try NativeJointSourceWidthPacking.verifyPinnedPeers(before:tuple,after:shaped.baseline,
                                beforeLayer:winner,afterLayer:shaped.layer,changed:shaped.changed)
                            var audit=shaped.layer.audit;audit["jointSourceWidthPackingPinProof"]=proof
                            audit["jointRecoveryRegistration"]="exact completed recovery admission; prior fixed peers remain pinned"
                            return .init(image:shaped.layer.image,expectedItems:shaped.layer.expectedItems,
                                paintedItems:shaped.layer.paintedItems,complete:shaped.layer.complete,audit:audit)
                        }
                    }
                    return retained
                }
                if ProcessInfo.processInfo.environment["AIDOKU_ADAPTIVE_GUTTER"] != "0" ||
                    ProcessInfo.processInfo.environment["AIDOKU_CONTOUR_CLEARANCE"] != "0" ||
                    ProcessInfo.processInfo.environment["AIDOKU_INK_CONTOUR_CLEARANCE"] != "0" ||
                    (NativeBalloonReadabilityReflow.exteriorEnabled || NativeBalloonReadabilityReflow.interiorWordsEnabled) ||
                    NativeSourcePhysicalInteriorContext.current != nil ||
                    (NativeSourceCohortCenterBalance.enabled && NativeSourceCohortCenterBalance.currentBoundaryContext != nil) ||
                    ProcessInfo.processInfo.environment["AIDOKU_BODY_SOURCE_ANCHOR_RECOVERY"] != "0" {
                    do {return try finalReadability(layer:retained,primitives:attempt.primitives,
                        items:current,viewport:viewport,restored:restored,contours:contours,options:options,
                        allowWordReflow:completePeerContext)}
                    catch is CancellationError {throw CancellationError()}
                    catch {try Task.checkCancellation()}
                }
                return retained
            } catch NativeFinalTextPaintAdmission.Failure.noSafePlacement(let cause) {
                let affected = try capacityClosure(Set(cause.split(separator: ",").map(String.init)),
                    items: current, options: options)
                guard retry < 8,options.values.contains(where:{$0["textExpansionPolicy"] is [String:Any]}),
                      permitsCapacityFontReduction(allowShrink:allowShrink,affected:affected,options:options) else {
                    throw NativeFinalTextPaintAdmission.Failure.noSafePlacement(cause)
                }
                current=current.map { item in
                    guard affected.contains(item.id) else { return item }
                    return .init(id:item.id,text:item.text,frame:item.frame,fontSize:item.fontSize*0.9,
                        lineHeight:item.lineHeight*0.9,chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
                }
            }
        }
        throw invalidGeometry()
    }

    /// Terminal-only optional word reflow. Candidate failures return retained
    /// paint; they cannot enter the font, owner, mask or global fallback loops.
    private static func finalReadability(layer:NativeAOTTranslationPageComposer.TextLayer,
        primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],items:[Item],viewport:CGSize,
        restored:CGImage,contours:[String:NativeRawBalloonCapacity.Contour],options:[String:[String:Any]],allowWordReflow:Bool)throws
        ->NativeAOTTranslationPageComposer.TextLayer {
        let interiorPlacementEnabled = ProcessInfo.processInfo.environment["AIDOKU_ADAPTIVE_GUTTER"] != "0" ||
            ProcessInfo.processInfo.environment["AIDOKU_CONTOUR_CLEARANCE"] != "0" ||
            ProcessInfo.processInfo.environment["AIDOKU_INK_CONTOUR_CLEARANCE"] != "0"
        guard allowWordReflow,interiorPlacementEnabled,ProcessInfo.processInfo.environment["AIDOKU_BALLOON_READABILITY_REFLOW"] != "0",
              let records=layer.audit["rawNativeItems"]as?[[String:Any]] else {
            let final = try NativeAOTTranslationPageComposer.refineFinalReadability(layer:layer,fills:primitives,restored:restored)
            guard allowWordReflow, NativeBalloonReadabilityReflow.exteriorEnabled || NativeBalloonReadabilityReflow.interiorWordsEnabled ||
                NativeSourcePhysicalInteriorContext.current != nil ||
                (NativeSourceCohortCenterBalance.enabled && NativeSourceCohortCenterBalance.currentBoundaryContext != nil) ||
                ProcessInfo.processInfo.environment["AIDOKU_BODY_SOURCE_ANCHOR_RECOVERY"] != "0" else { return final }
            do {
                let initial = try NativeFinalTextPaintAdmission.place(primitives,page:CGRect(x:0,y:0,width:restored.width,height:restored.height))
                let baseline = NativeFinalTextPaintAdmission.refineFinalPlacement(initial,page:CGRect(x:0,y:0,width:restored.width,height:restored.height))
                return try finalExteriorReadability(layer:final,baseline:baseline,items:items,viewport:viewport,
                    restored:restored,contours:contours,options:options)
            } catch {
                if error is CancellationError {throw error}
                try Task.checkCancellation()
                var audit=final.audit;audit["exteriorReadabilityRollback"]="retained-pre-exterior-layer: \(error)"
                return .init(image:final.image,expectedItems:final.expectedItems,paintedItems:final.paintedItems,complete:final.complete,audit:audit)
            }
        }
        let page=CGRect(x:0,y:0,width:restored.width,height:restored.height),scale=page.width/viewport.width
        let initial=try NativeFinalTextPaintAdmission.place(primitives,page:page)
        let baseline=NativeFinalTextPaintAdmission.refineFinalPlacement(initial,page:page)
        let lookup=Dictionary(uniqueKeysWithValues:items.map {($0.id,$0)})
        let recordByID=Dictionary(uniqueKeysWithValues:records.compactMap {row -> (String,[String:Any])? in
            guard let id=row["id"]as?String else{return nil};return (id,row)
        })
        let baselineByID=Dictionary(uniqueKeysWithValues:baseline.fills.compactMap {fill -> (String,NativeAOTTranslationPageComposer.TranslatedFillPrimitive)? in
            fill.ownerID.map {($0,fill)}
        })
        var descriptors:[String:NativeBalloonReadabilityReflow.Descriptor]=[:]
        for item in items where !vertical(options[item.id]) {
            guard let ranges=recordByID[item.id]?["lineRangesUTF16"]as?[[Int]],ranges.allSatisfy({$0.count==2})else{continue}
            descriptors[item.id] = .init(text:item.text,ranges:ranges.map {NSRange(location:$0[0],length:$0[1])})
        }
        let reflow=try NativeBalloonReadabilityReflow.refine(baseline,descriptors:descriptors,page:page) {id,width,frame in
            guard let item=lookup[id],let retained=baselineByID[id],!retained.hasFinalEffects,
                  let pitch=recordByID[id]?["retainedLinePitchOutputPixels"]as?Double,pitch>0 else{return nil}
            let proposed=Item(id:id,text:item.text,frame:CGRect(x:frame.minX/scale,y:frame.minY/scale,
                width:frame.width/scale,height:frame.height/scale),fontSize:retained.fontOutputPixels/scale,
                lineHeight:CGFloat(pitch)/scale,chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
            let attempt=try renderAttempt(items:[proposed],viewport:viewport,restored:restored,allowShrink:false,
                contours:contours,options:options,excludedTailOwners:[id],recordRefinement:{_ in},
                boundedInteriorWidth:width,retainedPitch:CGFloat(pitch))
            guard let painted=attempt.primitives.first,
                  let row=(attempt.layer.audit["rawNativeItems"]as?[[String:Any]])?.first,
                  let ranges=row["lineRangesUTF16"]as?[[Int]],ranges.allSatisfy({$0.count==2}),
                  abs(painted.fontOutputPixels-retained.fontOutputPixels)<0.0001 else{return nil}
            var fill=retained;fill.image=painted.image;fill.frame=painted.frame
            fill.sourceStyle = try NativeSourceStylePaint.transferringDeferredContour(from: retained.sourceStyle, shaped: painted.sourceStyle)
            return .init(fill:fill,ranges:ranges.map {NSRange(location:$0[0],length:$0[1])},
                metadata:["rawNativeItem":row])
        }
        var metadata=layer.audit,updated=records
        for i in updated.indices {
            guard let id=updated[i]["id"]as?String,let selected=reflow.selected[id],
                  let row=selected.metadata["rawNativeItem"]as? [String:Any]else{continue}
            updated[i].merge(row){_,new in new};updated[i]["balloonReadabilityReflow"]=true
            if let delta=selected.metadata["placementDeltaOutputPixels"]as?[Double],delta.count==2 {
                for key in ["frameOutputTopLeft","retainedFillBoundsOutput"] {
                    if var rect=updated[i][key]as?[CGFloat],rect.count==4 {
                        rect[0]+=CGFloat(delta[0]);rect[1]+=CGFloat(delta[1]);updated[i][key]=rect
                    }
                }
                updated[i]["readabilityReflowPlacementDeltaOutputPixels"]=delta
            }
        }
        metadata["rawNativeItems"]=updated
        if !reflow.selected.isEmpty {metadata["balloonReadabilityReflowOwners"]=reflow.selected.keys.sorted()}
        let retained=NativeAOTTranslationPageComposer.TextLayer(image:layer.image,expectedItems:layer.expectedItems,
            paintedItems:layer.paintedItems,complete:layer.complete,audit:metadata)
        let final = try NativeAOTTranslationPageComposer.refineFinalReadability(layer:retained,fills:primitives,
            restored:restored,admittedOverride:(reflow.fills,reflow.audit),forceRepaint:!reflow.selected.isEmpty)
        return try finalExteriorReadability(layer:final,baseline:(reflow.fills,reflow.audit),items:items,viewport:viewport,
            restored:restored,contours:contours,options:options)
    }

    /// Optional transaction after the unchanged interior result has been painted.
    /// Any exterior failure returns that result, never the outer font retry loop.
    private static func finalExteriorReadability(layer:NativeAOTTranslationPageComposer.TextLayer,
        baseline:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
        items:[Item],viewport:CGSize,restored:CGImage,contours:[String:NativeRawBalloonCapacity.Contour],
        options:[String:[String:Any]])throws->NativeAOTTranslationPageComposer.TextLayer {
        let exterior: (layer:NativeAOTTranslationPageComposer.TextLayer,
            baseline:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]))
        if NativeBalloonReadabilityReflow.exteriorEnabled {
            exterior=try finalExteriorReadabilityAttempt(layer:layer,baseline:baseline,items:items,viewport:viewport,
                restored:restored,contours:contours,options:options)
        } else { exterior=(layer,baseline) }
        let terminal: (layer:NativeAOTTranslationPageComposer.TextLayer,
            baseline:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]))
        if NativeBalloonReadabilityReflow.interiorWordsEnabled {
            terminal = try finalInteriorWordsReadability(layer:exterior.layer,baseline:exterior.baseline,items:items,
                viewport:viewport,restored:restored,contours:contours,options:options)
        } else { terminal = exterior }
        var declaredCohorts:[String:Set<String>] = [:]
        if NativeSourceCohortCenterBalance.enabled,
           NativeSourceCohortCenterBalance.currentBoundaryContext != nil {
            // This wrapper is reached only with completePeerContext. Include
            // ALL declared members, including ineligible ones, so filtering can
            // never turn an incomplete source cohort into a complete candidate.
            let ids = items.map(\.id), retained = terminal.baseline.fills.compactMap(\.ownerID)
            guard Set(ids).count == ids.count, Set(ids) == Set(retained), retained.count == ids.count else { throw invalidGeometry() }
            for (id, raw) in options {
                if let packet = try NativeSourceClusterAlignment.decode(raw["sourceClusterAlignment"]) {
                    declaredCohorts[packet.groupID,default:[]].insert(id)
                }
            }
        }
        var declaredStyleCohorts:[String:Set<String>] = [:]
        for (id, raw) in options {
            if let group = raw["sourceStyleGroupID"] as? String {
                declaredStyleCohorts[group,default:[]].insert(id)
            }
        }
        var completedTuple = terminal.baseline
        let completed = try finalSourcePhysicalInterior(layer:terminal.layer,baseline:terminal.baseline,restored:restored,
            lexicalOriginals:exterior.baseline,declaredCohorts:declaredCohorts,
            declaredStyleCohorts:declaredStyleCohorts,completedCapture:{completedTuple = $0})
        if let scope = NativeJointSourceWidthPacking.scope {
            let retainedCohorts = declaredCohorts, retainedStyles = declaredStyleCohorts
            scope.record(completed,carrierPixels:terminal.baseline.fills.reduce(0){$0+$1.image.width*$1.image.height}) { winner in
                let lookup=Dictionary(uniqueKeysWithValues:items.map{($0.id,$0)})
                let oldByID=Dictionary(uniqueKeysWithValues:terminal.baseline.fills.compactMap{f in f.ownerID.map{($0,f)}})
                let shaped = try NativeJointSourceWidthPacking.refine(layer:terminal.layer,baseline:terminal.baseline,
                    texts:Dictionary(uniqueKeysWithValues:items.map{($0.id,$0.text)}),
                    page:CGRect(x:0,y:0,width:restored.width,height:restored.height),restored:restored) {id,width,pitch in
                    guard let old=oldByID[id],let item=lookup[id] else{return nil}
                    let scale=CGFloat(restored.width)/viewport.width
                    let proposed=Item(id:id,text:item.text,frame:item.frame,fontSize:old.fontOutputPixels/scale,
                        lineHeight:pitch/scale,chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
                    let raw=try renderPrimitives(items:[proposed],viewport:viewport,restored:restored,allowShrink:false,
                        contours:contours,options:options,excludedTailOwners:[id],recordRefinement:{_ in},
                        retainedPitch:pitch,terminalExteriorContentWidth:width,terminalExteriorFont:old.fontOutputPixels,
                        terminalExteriorWholeWords:true,pitchFamilyItems:items)
                    guard raw.primitives.count==1,raw.audit.count==1 else{return nil}
                    return(raw.primitives[0],raw.audit[0])
                }
                guard !shaped.changed.isEmpty else {
                    return NativeJointSourceWidthPacking.annotate(winner,shaped.layer.audit["jointSourceWidthPacking"] as! [String:Any])
                }
                var actualTuple = shaped.baseline
                let actual=try finalSourcePhysicalInterior(layer:shaped.layer,baseline:shaped.baseline,restored:restored,
                    lexicalOriginals:exterior.baseline,declaredCohorts:retainedCohorts,declaredStyleCohorts:retainedStyles,
                    completedCapture:{actualTuple = $0})
                // Mandatory typed proof, even with all debug/PNG capture OFF.
                // No current receipt is reconstructed from debug JSON arrays.
                let pinProof=try NativeJointSourceWidthPacking.verifyPinnedPeers(before:completedTuple,after:actualTuple,
                    beforeLayer:winner,afterLayer:actual,changed:shaped.changed)
                var audit=actual.audit;audit["jointSourceWidthPackingPinProof"]=pinProof
                return .init(image:actual.image,expectedItems:actual.expectedItems,
                    paintedItems:actual.paintedItems,complete:actual.complete,audit:audit)
            }
        }
        return completed
    }

    private static func finalExteriorReadabilityAttempt(layer:NativeAOTTranslationPageComposer.TextLayer,
        baseline:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
        items:[Item],viewport:CGSize,restored:CGImage,contours:[String:NativeRawBalloonCapacity.Contour],
        options:[String:[String:Any]])throws->(layer:NativeAOTTranslationPageComposer.TextLayer,
        baseline:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]])) {
        do {
            let page=CGRect(x:0,y:0,width:restored.width,height:restored.height),scale=page.width/viewport.width
            guard let rows=layer.audit["rawNativeItems"]as?[[String:Any]], rows.count==baseline.fills.count else{return (layer,baseline)}
            let lookup=Dictionary(uniqueKeysWithValues:items.map {($0.id,$0)})
            let byID=Dictionary(uniqueKeysWithValues:rows.enumerated().map {($0.element["id"]as!String,$0.offset)})
            let retained=Dictionary(uniqueKeysWithValues:baseline.fills.compactMap {f in f.ownerID.map {($0,f)}})
            var descriptors:[String:NativeBalloonReadabilityReflow.Descriptor]=[:]
            var content:[String:CGFloat]=[:],pitches:[String:CGFloat]=[:]
            for item in items {
                guard let i=byID[item.id],let fill=retained[item.id],!fill.hasFinalEffects,
                      fill.textExpansionPolicy?.kind=="source-near-limited-expansion",fill.balloonPlacement==nil,
                      !vertical(options[item.id]),rows[i]["nativeBalloonMaskBoundaryApplied"]as?Bool != true,
                      (rows[i]["appliedTrackingPixels"]as?NSNumber)?.doubleValue == 0,
                      let b=rows[i]["frameOutputTopLeft"]as?[CGFloat],b.count==4,b[2].isFinite,b[2]>0,
                      let pitch=rows[i]["retainedLinePitchOutputPixels"]as?Double,pitch.isFinite,pitch>0,
                      let ranges=rows[i]["lineRangesUTF16"]as?[[Int]],ranges.allSatisfy({$0.count==2}),
                      !NativeRenderWrapQuality.wordCutOffsets(item.text,ranges:ranges.map {NSRange(location:$0[0],length:$0[1])}).isEmpty,
                      let palette=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(fill,restored:restored),
                      NativeBalloonReadabilityReflow.paintDecisionMatches(rows[i]["finalStrokeDecision"] as? [String:Any] ?? [:], palette:palette),
                      palette["displayFillRGB"]as?[Int] == rows[i]["finalDisplayFill"]as?[Int] else{continue}
                descriptors[item.id] = .init(text:item.text,ranges:ranges.map {NSRange(location:$0[0],length:$0[1])})
                guard let width=retainedExteriorContentWidth(outerWidth:b[2],font:fill.fontOutputPixels,
                    raw:options[item.id]) else {continue}
                content[item.id]=width;pitches[item.id]=CGFloat(pitch)
            }
            let reflow=try NativeBalloonReadabilityReflow.refineExterior(baseline,descriptors:descriptors,
                page:page,completePeerContext:true,restored:restored,widths:{id in
                    guard let fill=retained[id],let policy=fill.textExpansionPolicy,let width=content[id],
                          let descriptor=descriptors[id] else{return []}
                    let font=CTFontCreateWithName(try sourceFontName(raw:options[id])as CFString,fill.fontOutputPixels,nil)
                    let inset=NativeTextSpacing.outwardExtent(raw:options[id],fontSize:fill.fontOutputPixels)+NativeTextSpacing.padding(fontSize:fill.fontOutputPixels)
                    return NativeFinalTextFlow.terminalExteriorContentWidths(text:descriptor.text,ranges:descriptor.ranges,
                        font:font,current:width,maximum:NativeTextExpansionPolicy.rect(policy.allowedRectNormalized,page:page).width-2*inset)
                },make:{id,width,frame in
                    guard let item=lookup[id],let old=retained[id],let pitch=pitches[id]else{return nil}
                    let inset=NativeTextSpacing.outwardExtent(raw:options[id],fontSize:old.fontOutputPixels)+NativeTextSpacing.padding(fontSize:old.fontOutputPixels)
                    let outer=width+2*inset
                    let proposed=Item(id:id,text:item.text,frame:CGRect(x:frame.minX/scale,y:frame.minY/scale,
                        width:outer/scale,height:frame.height/scale),fontSize:old.fontOutputPixels/scale,
                        lineHeight:pitch/scale,chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
                    let attempt=try renderPrimitives(items:[proposed],viewport:viewport,restored:restored,allowShrink:false,
                        contours:contours,options:options,excludedTailOwners:[id],recordRefinement:{_ in},retainedPitch:pitch,
                        terminalExteriorContentWidth:width,terminalExteriorFont:old.fontOutputPixels)
                    guard let painted=attempt.primitives.first,
                          let row=attempt.audit.first,
                          painted.fontOutputPixels==old.fontOutputPixels,
                          row["retainedLinePitchOutputPixels"]as?Double == Double(pitch),
                          (row["appliedTrackingPixels"]as?NSNumber)?.doubleValue == 0,
                          let ranges=row["lineRangesUTF16"]as?[[Int]],ranges.allSatisfy({$0.count==2})else{return nil}
                    var fill=old;fill.image=painted.image;fill.frame=painted.frame
                    fill.sourceStyle = try NativeSourceStylePaint.transferringDeferredContour(from: old.sourceStyle, shaped: painted.sourceStyle)
                    return .init(fill:fill,ranges:ranges.map {NSRange(location:$0[0],length:$0[1])},metadata:["rawNativeItem":row])
                })
            var metadata=layer.audit
            metadata["exteriorReadabilityReflowDiagnostics"]=reflow.diagnostics
            guard !reflow.selected.isEmpty else{
                return (.init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,complete:layer.complete,audit:metadata),baseline)
            }
            var updated=rows
            for (id,candidate) in reflow.selected {
                guard let i=byID[id],let row=candidate.metadata["rawNativeItem"]as?[String:Any]else{throw invalidGeometry()}
                updated[i]["preExteriorRawNativeItem"]=rows[i]
                updated[i]["preExteriorLineRangesUTF16"]=rows[i]["lineRangesUTF16"]
                for key in ["lineRangesUTF16","actualCoreTextLineStrings","shortSoftTails","softWordCuts",
                            "oneCharacterRowsProxy","horizontalFlowQuality","frameOutputTopLeft","retainedFillBoundsOutput"] {
                    updated[i][key]=row[key]
                }
                if let delta=candidate.metadata["placementDeltaOutputPixels"]as?[Double],delta.count==2 {
                    for key in ["frameOutputTopLeft","retainedFillBoundsOutput"] {
                        if var rect=updated[i][key]as?[CGFloat],rect.count==4 {
                            rect[0]+=CGFloat(delta[0]);rect[1]+=CGFloat(delta[1]);updated[i][key]=rect
                        }
                    }
                }
                updated[i]["exteriorReadabilityReflow"]=true
                updated[i]["exteriorFinalPalette"]=candidate.metadata["exteriorFinalPalette"]
                updated[i]["exteriorRetainedFontOutputPixels"]=candidate.fill.fontOutputPixels
                updated[i]["exteriorRetainedFace"]=try sourceFontName(raw:options[id])
                updated[i]["exteriorRetainedPitchOutputPixels"]=pitches[id]
                updated[i]["certifiedLayoutConsumed"]=false
                updated[i]["tailRefinementOriginWidthPixels"]=NSNull()
            }
            metadata["rawNativeItems"]=updated
            metadata["exteriorReadabilityReflowOwners"]=reflow.selected.keys.sorted()
            metadata["exteriorReadabilityReflowTerminalOnly"]=true
            let staged=NativeAOTTranslationPageComposer.TextLayer(image:layer.image,expectedItems:layer.expectedItems,
                paintedItems:layer.paintedItems,complete:layer.complete,audit:metadata)
            let final=try NativeAOTTranslationPageComposer.refineFinalReadability(layer:staged,fills:baseline.fills,
                restored:restored,admittedOverride:(reflow.fills,reflow.audit),forceRepaint:true)
            // Check actual paint decisions, not only the factory's declaration.
            guard let decisions=final.audit["endpointDecisions"]as?[[String:Any]],decisions.count==rows.count,
                  let radii=final.audit["outwardRadiiOutputPixels"]as?[CGFloat],
                  let priorDecisions=layer.audit["endpointDecisions"]as?[[String:Any]],priorDecisions.count==rows.count,
                  let priorRadii=layer.audit["outwardRadiiOutputPixels"]as?[CGFloat],priorRadii.count==radii.count else{throw invalidGeometry()}
            for i in rows.indices {
                guard let palette = try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(baseline.fills[i],restored:restored),
                      let afterPalette = try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(reflow.fills[i],restored:restored),
                      NSDictionary(dictionary:palette).isEqual(to:afterPalette),
                      NativeBalloonReadabilityReflow.paintDecisionMatches(priorDecisions[i],palette:palette),
                      NativeBalloonReadabilityReflow.paintDecisionMatches(decisions[i],palette:afterPalette),
                      radii.indices.contains(i),radii[i]==priorRadii[i]else{throw invalidGeometry()}
            }
            for (id,candidate) in reflow.selected {
                let i=byID[id]!
                guard let palette=candidate.metadata["exteriorFinalPalette"]as?[String:Any],
                      NativeBalloonReadabilityReflow.paintDecisionMatches(decisions[i],palette:palette),
                      radii.indices.contains(i),Double(radii[i]) == palette["outwardPixels"]as?Double else{throw invalidGeometry()}
            }
            var verified=final.audit;verified["exteriorFinalOutputPaletteVerified"]=true
            return (.init(image:final.image,expectedItems:final.expectedItems,paintedItems:final.paintedItems,complete:final.complete,audit:verified),(reflow.fills,reflow.audit))
        } catch {
            if error is CancellationError {throw error}
            try Task.checkCancellation()
            var audit=layer.audit;audit["exteriorReadabilityRollback"]="retained-pre-exterior-layer: \(error)"
            return (.init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,complete:layer.complete,audit:audit),baseline)
        }
    }

    /// Reviewed terminal lexical repair over the complete post-exterior page;
    /// Measured widths are bounded; new origin/row alternatives require a
    /// source-bound gate frozen to the actual pre-reflow glyph support.
    /// Unsupported receipts or any final paint drift retain the whole old pass.
    private static func finalInteriorWordsReadability(layer:NativeAOTTranslationPageComposer.TextLayer,
        baseline:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
        items:[Item],viewport:CGSize,restored:CGImage,contours:[String:NativeRawBalloonCapacity.Contour],
        options:[String:[String:Any]])throws->(layer:NativeAOTTranslationPageComposer.TextLayer,
            baseline:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]])) {
        try Task.checkCancellation()
        var rollbackStage="input-binding"
        var rollbackDetails:[String:Any]=[:]
        do {
            let page=CGRect(x:0,y:0,width:restored.width,height:restored.height),scale=page.width/viewport.width
            guard NativeBalloonReadabilityReflow.interiorWordsEnabled,scale.isFinite,scale>0,
                  layer.complete,layer.expectedItems==items.count,layer.paintedItems==items.count,
                  let rows=layer.audit["rawNativeItems"]as?[[String:Any]],rows.count==items.count,
                  baseline.fills.count==items.count,baseline.audit.count==items.count,
                  Set(items.map(\.id)).count==items.count else{return (layer,baseline)}
            let ids=rows.compactMap {$0["id"]as?String}
            guard ids.count==rows.count,Set(ids).count==rows.count,Set(ids)==Set(items.map(\.id)),
                  baseline.fills.indices.allSatisfy({baseline.fills[$0].ownerID==ids[$0] &&
                      baseline.audit[$0]["owner"]as?String==ids[$0]})else{return (layer,baseline)}
            let lookup=Dictionary(uniqueKeysWithValues:items.map {($0.id,$0)})
            let byID=Dictionary(uniqueKeysWithValues:ids.enumerated().map {($0.element,$0.offset)})
            var descriptors:[String:NativeBalloonReadabilityReflow.Descriptor]=[:]
            var widths:[String:CGFloat]=[:],pitches:[String:CGFloat]=[:]
            for i in rows.indices {
                let id=ids[i],fill=baseline.fills[i],row=rows[i]
                guard let item=lookup[id],fill.textExpansionPolicy?.insideBalloon==true,
                      !vertical(options[id]),!fill.hasFinalEffects,
                      // Source appearance can carry a validated empty style.
                      // Its mere presence must not suppress a plain reflow;
                      // actual source bands/shadows retain their separate path.
                      fill.sourceStyle.map({$0.bands.isEmpty && $0.shadow == nil}) ?? true,
                      (row["appliedTrackingPixels"]as?NSNumber)?.doubleValue==0,
                      row["sourceUTF16"]as?Int==item.text.utf16.count,
                      row["visibleUTF16"]as?Int==item.text.utf16.count,
                      let width=row["interiorWordOuterLayoutWidthOutputPixels"]as?Double,width.isFinite,width>0,
                      let pitch=row["retainedLinePitchOutputPixels"]as?Double,pitch.isFinite,pitch>0,
                      row["interiorWordRetainedFontOutputPixels"]as?Double==Double(fill.fontOutputPixels),
                      let face=row["interiorWordRetainedFace"]as?String,
                      face==CTFontCopyPostScriptName(CTFontCreateWithName(try sourceFontName(raw:options[id])as CFString,
                          fill.fontOutputPixels,nil))as String,
                      let ranges=row["lineRangesUTF16"]as?[[Int]],ranges.allSatisfy({$0.count==2})else{continue}
                let owned=ranges.map {NSRange(location:$0[0],length:$0[1])}
                guard !NativeRenderWrapQuality.wordCutOffsets(item.text,ranges:owned).isEmpty else{continue}
                descriptors[id] = .init(text:item.text,ranges:owned)
                widths[id]=CGFloat(width);pitches[id]=CGFloat(pitch)
            }
            guard !descriptors.isEmpty else{return (layer,baseline)}
            // Freeze BEFORE either width pass. Neither a newly shaped glyph
            // nor a selected first-pass candidate may authorize its own source
            // hole exemptions during a later alternative.
            var shapeGate:NativeBalloonReadabilityReflow.ShapeGate?
            var contourAnchors:[String:CGRect]=[:]
            if let context=NativeSourcePhysicalInteriorContext.current {
                let originals=Dictionary(uniqueKeysWithValues:try descriptors.keys.map {id in
                    let i=byID[id]!
                    return (id,try NativeFinalTextPaintAdmission.retainedFootprint(baseline.fills[i]))
                })
                contourAnchors=originals.mapValues { $0.bounds }
                shapeGate={id,_,after in
                    guard let i=byID[id],let before=originals[id] else {
                        return (nil,["status":"missing-original-reflow-support","evidenceAvailable":false])
                    }
                    return context.shapeClearance(incumbent:baseline.fills[i],before:before,after:after,page:page)
                }
            }
            // R120 keeps its single exact outer width unless measured capacity
            // is explicitly enabled; measuring never grants placement admission.
            let measuredWidthsEnabled=NativeBalloonReadabilityReflow.interiorMeasuredWidthsEnabled
            var authorizedWidths:[String:[CGFloat]]=[:]
            var extraOuterWidths:((String)throws->[CGFloat])?=nil
            if measuredWidthsEnabled {
                extraOuterWidths={id in
                    try Task.checkCancellation()
                    guard let i=byID[id],let current=widths[id],let descriptor=descriptors[id],
                          let policy=baseline.fills[i].textExpansionPolicy else{return []}
                    let fill=baseline.fills[i]
                    let inset=NativeTextSpacing.outwardExtent(raw:options[id],fontSize:fill.fontOutputPixels) +
                        NativeTextSpacing.padding(fontSize:fill.fontOutputPixels)
                    let maximum=NativeTextExpansionPolicy.rect(policy.allowedRectNormalized,page:page).width
                    let content=current-2*inset
                    guard inset.isFinite,content.isFinite,content>0,maximum.isFinite,maximum>current else{return []}
                    let font=CTFontCreateWithName(try sourceFontName(raw:options[id])as CFString,fill.fontOutputPixels,nil)
                    let measured=NativeFinalTextFlow.terminalExteriorContentWidths(text:descriptor.text,ranges:descriptor.ranges,
                        font:font,current:content,maximum:maximum-2*inset)
                        .filter {$0>content}.map {$0+2*inset}.filter {$0.isFinite && $0>current && $0<=maximum}
                    let extra=Array(measured.prefix(2))
                    authorizedWidths[id]=extra
                    return extra
                }
            }
            // Contour is a second family supplied only to the terminal wrapper.
            // Parent selection preserves every R140 winner before invoking it.
            var makeContour:((String,CGFloat,CGRect)throws->NativeBalloonReadabilityReflow.Candidate?)?=nil
            if shapeGate != nil {
                makeContour={id,width,frame in
                    try Task.checkCancellation()
                    guard let item=lookup[id],let i=byID[id],let pitch=pitches[id],let current=widths[id],
                          let descriptor=descriptors[id],let anchor=contourAnchors[id],
                          options[id]?["textAlignment"] as? String == nil || options[id]?["textAlignment"] as? String == "center"
                    else{return nil}
                    let old=baseline.fills[i]
                    guard width==current || (measuredWidthsEnabled && width.isFinite && width>current &&
                        authorizedWidths[id]?.contains(width)==true && old.textExpansionPolicy.map {
                            width<=NativeTextExpansionPolicy.rect($0.allowedRectNormalized,page:page).width
                        }==true) else{return nil}
                    let proposed=Item(id:id,text:item.text,frame:CGRect(x:frame.minX/scale,y:frame.minY/scale,
                        width:width/scale,height:frame.height/scale),fontSize:old.fontOutputPixels/scale,
                        lineHeight:pitch/scale,chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
                    let attempt=try renderPrimitives(items:[proposed],viewport:viewport,restored:restored,allowShrink:false,
                        contours:contours,options:options,excludedTailOwners:[id],recordRefinement:{_ in},retainedPitch:pitch,
                        terminalInteriorOuterWidth:width,terminalInteriorFont:old.fontOutputPixels,
                        terminalInteriorContourRanges:descriptor.ranges,terminalInteriorContourAnchor:anchor)
                    guard attempt.primitives.count==1,let painted=attempt.primitives.first,let row=attempt.audit.first,
                          painted.fontOutputPixels==old.fontOutputPixels,
                          row["interiorWordOuterLayoutWidthOutputPixels"]as?Double==Double(width),
                          row["interiorWordRetainedFace"]as?String==rows[i]["interiorWordRetainedFace"]as?String,
                          row["interiorWordRetainedFontOutputPixels"]as?Double==Double(old.fontOutputPixels),
                          row["retainedLinePitchOutputPixels"]as?Double==Double(pitch),
                          (row["appliedTrackingPixels"]as?NSNumber)?.doubleValue==0,
                          row["sourceUTF16"]as?Int==item.text.utf16.count,
                          row["visibleUTF16"]as?Int==item.text.utf16.count,
                          row["interiorContourWordWrap"]as?Bool==true,
                          let diagnostic=row["interiorContourWordDiagnostics"]as?[String:Any],
                          let ranges=row["lineRangesUTF16"]as?[[Int]],ranges.allSatisfy({$0.count==2})else{return nil}
                    var fill=old;fill.image=painted.image;fill.frame=painted.frame
                    fill.sourceStyle = try NativeSourceStylePaint.transferringDeferredContour(from: old.sourceStyle, shaped: painted.sourceStyle)
                    return .init(fill:fill,ranges:ranges.map {NSRange(location:$0[0],length:$0[1])},
                        metadata:["rawNativeItem":row,"interiorWordOuterLayoutWidthOutputPixels":Double(width),
                            "interiorWordRetainedFace":row["interiorWordRetainedFace"]!,
                            "interiorWordRetainedFontOutputPixels":Double(old.fontOutputPixels),
                            "interiorWordRetainedPitchOutputPixels":Double(pitch),"interiorWordTrackingPixels":0,
                            "interiorContourWordWrap":true,"interiorContourWordDiagnostics":diagnostic])
                }
            }
            let reflow=try NativeBalloonReadabilityReflow.refineInteriorWords(baseline,descriptors:descriptors,
                page:page,completePeerContext:true,restored:restored,outerWidths:{widths[$0]},
                extraOuterWidths:extraOuterWidths,allowRowReduction:measuredWidthsEnabled,shapeGate:shapeGate,makeContour:makeContour,make:{id,width,frame in
                    try Task.checkCancellation()
                    guard let item=lookup[id],let i=byID[id],let pitch=pitches[id],let current=widths[id]else{return nil}
                    let old=baseline.fills[i]
                    // Exact requests only: no width search or owner-only admission.
                    guard width==current || (measuredWidthsEnabled && width.isFinite && width>current &&
                        authorizedWidths[id]?.contains(width)==true && old.textExpansionPolicy.map {
                            width<=NativeTextExpansionPolicy.rect($0.allowedRectNormalized,page:page).width
                        }==true) else{return nil}
                    let proposed=Item(id:id,text:item.text,frame:CGRect(x:frame.minX/scale,y:frame.minY/scale,
                        width:width/scale,height:frame.height/scale),fontSize:old.fontOutputPixels/scale,
                        lineHeight:pitch/scale,chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
                    let attempt=try renderPrimitives(items:[proposed],viewport:viewport,restored:restored,allowShrink:false,
                        contours:contours,options:options,excludedTailOwners:[id],recordRefinement:{_ in},retainedPitch:pitch,
                        terminalInteriorOuterWidth:width,terminalInteriorFont:old.fontOutputPixels)
                    guard attempt.primitives.count==1,let painted=attempt.primitives.first,let row=attempt.audit.first,
                          painted.fontOutputPixels==old.fontOutputPixels,
                          row["interiorWordOuterLayoutWidthOutputPixels"]as?Double==Double(width),
                          row["interiorWordRetainedFace"]as?String==rows[i]["interiorWordRetainedFace"]as?String,
                          row["interiorWordRetainedFontOutputPixels"]as?Double==Double(old.fontOutputPixels),
                          row["retainedLinePitchOutputPixels"]as?Double==Double(pitch),
                          (row["appliedTrackingPixels"]as?NSNumber)?.doubleValue==0,
                          row["sourceUTF16"]as?Int==item.text.utf16.count,
                          row["visibleUTF16"]as?Int==item.text.utf16.count,
                          let ranges=row["lineRangesUTF16"]as?[[Int]],ranges.allSatisfy({$0.count==2})else{return nil}
                    // Keep source membership, body/domain, cohorts and every
                    // paint parameter; only the newly shaped raster is replaced.
                    var fill=old;fill.image=painted.image;fill.frame=painted.frame
                    fill.sourceStyle = try NativeSourceStylePaint.transferringDeferredContour(from: old.sourceStyle, shaped: painted.sourceStyle)
                    return .init(fill:fill,ranges:ranges.map {NSRange(location:$0[0],length:$0[1])},
                        metadata:["rawNativeItem":row,"interiorWordOuterLayoutWidthOutputPixels":Double(width),
                            "interiorWordRetainedFace":row["interiorWordRetainedFace"]!,
                            "interiorWordRetainedFontOutputPixels":Double(old.fontOutputPixels),
                            "interiorWordRetainedPitchOutputPixels":Double(pitch),"interiorWordTrackingPixels":0])
                })
            guard !reflow.selected.isEmpty else {
                var audit=layer.audit
                audit["interiorWordReadabilityReflowDiagnostics"]=reflow.diagnostics
                return (.init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,
                    complete:layer.complete,audit:audit),baseline)
            }
            guard reflow.fills.count==rows.count,reflow.audit.count==rows.count else{throw invalidGeometry()}
            var palettes:[[String:Any]]=[]
            for i in rows.indices {
                try Task.checkCancellation()
                rollbackStage="palette-preflight:"+ids[i]
                let before=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(baseline.fills[i],restored:restored)
                let after=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(reflow.fills[i],restored:restored)
                rollbackDetails=["owner":ids[i],"selected":reflow.selected[ids[i]] != nil,
                    "before":before as Any,"after":after as Any,
                    "sameImage":baseline.fills[i].image === reflow.fills[i].image,
                    "sameFrame":baseline.fills[i].frame==reflow.fills[i].frame,
                    "beforeHasFinalEffects":baseline.fills[i].hasFinalEffects,
                    "afterHasFinalEffects":reflow.fills[i].hasFinalEffects]
                guard let before,let after,
                      NSDictionary(dictionary:before).isEqual(to:after),
                      ["mandatory-final-palette","source-contour-only"].contains(after["kind"]as?String ?? "")
                else{throw invalidGeometry()}
                palettes.append(after)
            }
            var updated=rows
            for (id,candidate) in reflow.selected {
                guard let i=byID[id],let row=candidate.metadata["rawNativeItem"]as?[String:Any]else{throw invalidGeometry()}
                rollbackStage="row-metadata:"+id
                updated[i]["preInteriorWordRawNativeItem"]=rows[i]
                if measuredWidthsEnabled {
                    updated[i]["preInteriorWordOuterLayoutWidthOutputPixels"]=rows[i]["interiorWordOuterLayoutWidthOutputPixels"]
                    updated[i]["interiorWordOuterLayoutWidthOutputPixels"]=row["interiorWordOuterLayoutWidthOutputPixels"]
                }
                for key in ["lineRangesUTF16","actualCoreTextLineStrings","shortSoftTails","softWordCuts",
                            "oneCharacterRowsProxy","horizontalFlowQuality","frameOutputTopLeft","retainedFillBoundsOutput"] {
                    updated[i][key]=row[key]
                }
                if let delta=candidate.metadata["placementDeltaOutputPixels"]as?[Double],delta.count==2 {
                    for key in ["frameOutputTopLeft","retainedFillBoundsOutput"] {
                        if var rect=updated[i][key]as?[CGFloat],rect.count==4 {
                            rect[0]+=CGFloat(delta[0]);rect[1]+=CGFloat(delta[1]);updated[i][key]=rect
                        }
                    }
                }
                if row["interiorContourWordWrap"]as?Bool==true {
                    updated[i]["interiorContourWordWrap"]=true
                    updated[i]["interiorContourWordDiagnostics"]=row["interiorContourWordDiagnostics"]
                }
                updated[i]["interiorWordReadabilityReflow"]=true
                updated[i]["interiorWordFinalPalette"]=palettes[i]
                updated[i]["certifiedLayoutConsumed"]=false
                updated[i]["tailRefinementOriginWidthPixels"]=NSNull()
            }
            var metadata=layer.audit
            metadata["rawNativeItems"]=updated
            metadata["interiorWordReadabilityReflowOwners"]=reflow.selected.keys.sorted()
            metadata["interiorWordReadabilityReflowDiagnostics"]=reflow.diagnostics
            metadata["interiorWordReadabilityReflowTerminalOnly"]=true
            let staged=NativeAOTTranslationPageComposer.TextLayer(image:layer.image,expectedItems:layer.expectedItems,
                paintedItems:layer.paintedItems,complete:layer.complete,audit:metadata)
            rollbackStage="final-repaint"
            let final=try NativeAOTTranslationPageComposer.refineFinalReadability(layer:staged,fills:baseline.fills,
                restored:restored,admittedOverride:(reflow.fills,reflow.audit),forceRepaint:true)
            rollbackStage="final-paint-receipts"
            guard final.complete==layer.complete,final.expectedItems==layer.expectedItems,final.paintedItems==layer.paintedItems,
                  let decisions=final.audit["endpointDecisions"]as?[[String:Any]],decisions.count==rows.count,
                  let prior=layer.audit["endpointDecisions"]as?[[String:Any]],prior.count==rows.count,
                  let radii=final.audit["outwardRadiiOutputPixels"]as?[CGFloat],radii.count==rows.count,
                  let oldRadii=layer.audit["outwardRadiiOutputPixels"]as?[CGFloat],oldRadii.count==rows.count else{throw invalidGeometry()}
            for i in rows.indices {
                rollbackStage="actual-final-palette:"+ids[i]
                rollbackDetails=["owner":ids[i],"selected":reflow.selected[ids[i]] != nil,
                    "expected":palettes[i],"before":prior[i],"after":decisions[i],
                    "beforeRadius":Double(oldRadii[i]),"afterRadius":Double(radii[i])]
                guard let outward=palettes[i]["outwardPixels"]as?Double,
                      let actualPalette=try NativeBalloonReadabilityReflow.exteriorPaletteReceipt(reflow.fills[i],restored:restored),
                      NSDictionary(dictionary:palettes[i]).isEqual(to:actualPalette),
                      NativeBalloonReadabilityReflow.paintDecisionMatches(decisions[i],palette:actualPalette),
                      NativeBalloonReadabilityReflow.paintDecisionMatches(prior[i],palette:palettes[i]),
                      Double(radii[i])==outward,radii[i]==oldRadii[i]else{throw invalidGeometry()}
            }
            try Task.checkCancellation()
            var verified=final.audit;verified["interiorWordFinalOutputPaletteVerified"]=true
            return (.init(image:final.image,expectedItems:final.expectedItems,paintedItems:final.paintedItems,complete:final.complete,audit:verified),(reflow.fills,reflow.audit))
        } catch {
            if error is CancellationError {throw error}
            try Task.checkCancellation()
            var audit=layer.audit;audit["interiorWordReadabilityRollback"]="retained-post-exterior-layer: \(error)"
            audit["interiorWordRollbackStage"]=rollbackStage
            audit["interiorWordRollbackDetails"]=rollbackDetails
            return (.init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,complete:layer.complete,audit:audit),baseline)
        }
    }

    /// Last source-anchor and physical-interior transaction after word/peer
    /// refinements. Later shaping cannot overwrite its admitted fixed rasters.
    static func finalSourcePhysicalInterior(layer:NativeAOTTranslationPageComposer.TextLayer,
        baseline:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
        restored:CGImage,lexicalOriginals:NativeSourcePhysicalInteriorContext.Tuple? = nil,
        declaredCohorts:[String:Set<String>] = [:],declaredStyleCohorts:[String:Set<String>] = [:],
        completedCapture:((NativeTerminalRoundedSourcePaint.Tuple)->Void)? = nil)throws->NativeAOTTranslationPageComposer.TextLayer {
        // Establish the exact unrounded completed result FIRST. Terminal paint
        // cannot change any metric observed by the enclosing layout arbitration.
        var plainTuple = baseline
        let plain = try sourcePhysicalInteriorAttempt(layer:layer,baseline:baseline,restored:restored,
            lexicalOriginals:lexicalOriginals,declaredCohorts:declaredCohorts,capture:{ plainTuple = $0 })
        guard roundedSourceJoinsEnabled, NativeSourceStylePaint.roundedContourBindingEnabled,
              baseline.fills.contains(where: { $0.sourceStyle?.pendingRoundedContour != nil }) else {
            completedCapture?(plainTuple);return plain
        }
        if let scope = NativeTerminalRoundedSourcePaint.selectionScope {
            let pixels = baseline.fills.reduce(0) { $0 + $1.image.width * $1.image.height }
            scope.record(plain,carrierPixels:pixels) { selectedPlain in
                try roundedSourcePhysicalAttempt(plain:selectedPlain,plainTuple:plainTuple,
                    layer:layer,baseline:baseline,restored:restored,lexicalOriginals:lexicalOriginals,
                    declaredCohorts:declaredCohorts,declaredStyleCohorts:declaredStyleCohorts)
            }
            completedCapture?(plainTuple)
            return plain
        }
        return try roundedSourcePhysicalAttempt(plain:plain,plainTuple:plainTuple,layer:layer,baseline:baseline,
            restored:restored,lexicalOriginals:lexicalOriginals,declaredCohorts:declaredCohorts,
            declaredStyleCohorts:declaredStyleCohorts,completedCapture:completedCapture)
    }

    private static func roundedSourcePhysicalAttempt(plain:NativeAOTTranslationPageComposer.TextLayer,
        plainTuple:NativeTerminalRoundedSourcePaint.Tuple,layer:NativeAOTTranslationPageComposer.TextLayer,
        baseline:NativeTerminalRoundedSourcePaint.Tuple,restored:CGImage,
        lexicalOriginals:NativeSourcePhysicalInteriorContext.Tuple?,declaredCohorts:[String:Set<String>],
        declaredStyleCohorts:[String:Set<String>],
        completedCapture:((NativeTerminalRoundedSourcePaint.Tuple)->Void)? = nil)throws->NativeAOTTranslationPageComposer.TextLayer {
        var returnedTuple=plainTuple
        defer {completedCapture?(returnedTuple)}
        do {
            // PRE-center activation: later transactions bind the ACTUAL active
            // style from inception. No historical cohort receipt is rebound.
            let activated = try NativeTerminalRoundedSourcePaint.refine(layer:layer,baseline:baseline,
                declaredStyleCohorts:declaredStyleCohorts,restored:restored,enabled:true)
            guard activated.baseline.fills.contains(where: { $0.sourceStyle?.roundedContour != nil }) else {
                return NativeTerminalRoundedSourcePaint.annotating(plain,
                    status:"incumbent-retained-no-eligible-cohort",details:activated.layer.audit["terminalRoundedSourcePaint"])
            }
            var actualTuple = activated.baseline
            let actual = try sourcePhysicalInteriorAttempt(layer:activated.layer,baseline:activated.baseline,
                restored:restored,lexicalOriginals:lexicalOriginals,declaredCohorts:declaredCohorts,
                capture:{ actualTuple = $0 })
            try NativeTerminalRoundedSourcePaint.verifyCompletedSelection(plain:plain,plainTuple:plainTuple,
                candidate:actual,candidateTuple:actualTuple,restored:restored)
            let selected = NativeTerminalRoundedSourcePaint.preservingPlainSelectionHistory(actual,selected:plain)
            returnedTuple=actualTuple
            return NativeTerminalRoundedSourcePaint.annotating(selected,status:"selected-fixed-layout-and-peer-origins")
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return NativeTerminalRoundedSourcePaint.annotating(plain,status:"whole-page-incumbent-retained",
                details:String(reflecting:error))
        }
    }

    private static func sourcePhysicalInteriorAttempt(layer:NativeAOTTranslationPageComposer.TextLayer,
        baseline:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
        restored:CGImage,lexicalOriginals:NativeSourcePhysicalInteriorContext.Tuple? = nil,
        declaredCohorts:[String:Set<String>] = [:],
        capture: ((NativeTerminalRoundedSourcePaint.Tuple)->Void)? = nil)throws->NativeAOTTranslationPageComposer.TextLayer {
        var returnedTuple = baseline
        defer { capture?(returnedTuple) }
        let context=NativeSourcePhysicalInteriorContext.current
        let cohortContext=NativeSourceCohortCenterBalance.currentBoundaryContext
        let bodyEnabled=ProcessInfo.processInfo.environment["AIDOKU_BODY_SOURCE_ANCHOR_RECOVERY"] != "0"
        let edgeEnabled=ProcessInfo.processInfo.environment["AIDOKU_RETAINED_PAGE_EDGE_RECOVERY"] != "0"
        guard context != nil || bodyEnabled || edgeEnabled || (NativeSourceCohortCenterBalance.enabled && cohortContext != nil) else{return layer}
        let page=CGRect(x:0,y:0,width:restored.width,height:restored.height)
        let beforeDecisions=layer.audit["endpointDecisions"]as?[[String:Any]]
        func preservedPalettes(_ trial:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]])) -> [[String:Any]]? {
            guard trial.fills.count==baseline.fills.count,let before=beforeDecisions,before.count==trial.fills.count else{return nil}
            var palettes:[[String:Any]]=[]
            for i in trial.fills.indices {
                guard let old=try? NativeBalloonReadabilityReflow.exteriorPaletteReceipt(baseline.fills[i],restored:restored),
                      let new=try? NativeBalloonReadabilityReflow.exteriorPaletteReceipt(trial.fills[i],restored:restored),
                      NSDictionary(dictionary:old).isEqual(to:new),
                      NativeBalloonReadabilityReflow.paintDecisionMatches(before[i],palette:old) else{return nil}
                palettes.append(new)
            }
            return palettes
        }
        let boundaryGate: NativeBodySourceAnchorRecovery.BoundaryGate? = context.map { source in
            { before,after in source.boundaryClearance(before:before,after:after) }
        }
        // Exterior edge cohorts settle first. Later body/physical passes own
        // interior glyphs only; their complete peer checks use these new origins.
        var stageBaseline=baseline
        var edgeRollback:String?
        if edgeEnabled {
            let edge=NativeRetainedPageEdgeRecovery.refine(baseline,page:page,boundaryGate:boundaryGate)
            if edge.fills.count==baseline.fills.count,edge.audit.count==baseline.audit.count,
               edge.fills.map(\.ownerID)==baseline.fills.map(\.ownerID) {
                if edge.fills.indices.contains(where:{edge.fills[$0].frame != baseline.fills[$0].frame}) {
                    if preservedPalettes(edge) != nil {stageBaseline=edge}
                    else {edgeRollback="palette-or-final-paint-receipt-unavailable"}
                }
            } else {edgeRollback="malformed-page-edge-carrier"}
        }
        let edgeChanged=baseline.fills.indices.filter {stageBaseline.fills[$0].frame != baseline.fills[$0].frame}
        let edgeStage=stageBaseline
        var cohortRollback:String?
        if let cohortContext,!declaredCohorts.isEmpty,
           NativeSourceCohortCenterBalance.enabled {
            let protected=Set(edgeChanged.compactMap {baseline.fills[$0].ownerID})
            let balanced=NativeSourceCohortCenterBalance.refine(edgeStage,page:page,declaredCohorts:declaredCohorts,
                boundaryGate:NativeSourceCohortCenterBalance.originalSourceBoundaryGate(cohortContext),protectedOwners:protected)
            if balanced.fills.count==baseline.fills.count,balanced.audit.count==baseline.audit.count,
               balanced.fills.map(\.ownerID)==baseline.fills.map(\.ownerID) {
                if balanced.fills.indices.contains(where:{balanced.fills[$0].frame != edgeStage.fills[$0].frame}) {
                    if preservedPalettes(balanced) != nil {stageBaseline=balanced}
                    else {cohortRollback="palette-or-final-paint-receipt-unavailable"}
                }
            } else {cohortRollback="malformed-cohort-center-carrier"}
        }
        let cohortChanged=baseline.fills.indices.filter {stageBaseline.fills[$0].frame != edgeStage.fills[$0].frame}
        var anchored=bodyEnabled ? NativeBodySourceAnchorRecovery.refine(stageBaseline,page:page,boundaryGate:boundaryGate):stageBaseline
        var bodyRollback:String?
        if anchored.fills.count != baseline.fills.count || anchored.audit.count != baseline.audit.count ||
            anchored.fills.map(\.ownerID) != baseline.fills.map(\.ownerID) {
            anchored=stageBaseline;bodyRollback="malformed-body-recovery-carrier"
        }
        if stageBaseline.audit.contains(where:{$0[NativeSourceCohortCenterBalance.auditKey] != nil}) {
            do { anchored=try NativeSourceCohortCenterBalance.preservingReceipts(prior:stageBaseline,admitted:anchored,page:page) }
            catch { anchored=stageBaseline;bodyRollback="body-readmission-cohort-receipt-or-peer-gutter" }
        }
        var bodyChanged=baseline.fills.indices.filter {anchored.fills[$0].frame != stageBaseline.fills[$0].frame}
        if !bodyChanged.isEmpty,preservedPalettes(anchored)==nil {
            anchored=stageBaseline;bodyChanged=[];bodyRollback="palette-or-final-paint-receipt-unavailable"
        }
        var lineageRollback:String?
        func physicalRefinement(_ prior:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]))
            -> (fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]) {
            guard let context else{return prior}
            var trial=context.refine(prior,page:page)
            guard trial.fills.count==prior.fills.count,trial.audit.count==prior.audit.count,
                  trial.fills.map(\.ownerID)==prior.fills.map(\.ownerID) else {
                lineageRollback="physical-readmission-changed-retained-body-state"
                return prior
            }
            let transitionedBodies=Set(prior.fills.indices.filter {
                !prior.fills[$0].balloonTargetRelaxed && trial.fills[$0].balloonTargetRelaxed
            }.compactMap {prior.fills[$0].balloonPlacement?.bodyID})
            let marked=prior.fills.indices.allSatisfy { i in
                guard let body=prior.fills[i].balloonPlacement?.bodyID,transitionedBodies.contains(body) else{return true}
                guard let marker=trial.audit[i]["retainedBalloonPhysicalReadmission"]as?[String:Any] else{return false}
                return marker["reason"]as?String=="physical-readmission-body-relaxation" &&
                    marker["bodyID"]as?String==body && marker["completeGroup"]as?Bool==true
            }
            guard marked,let retained=try? NativeBalloonPlacement.RetainedState.preservingPhysicalReadmission(
                    priorAudit:prior.audit,admittedAudit:trial.audit,transitionedBodyIDs:transitionedBodies,
                    unknownPolicy:.preservePriorUncertainty,
                    inputPolicy:.unchangedInputPacket) else {
                lineageRollback="physical-readmission-changed-retained-body-state"
                return prior
            }
            trial.audit=retained
            if prior.audit.contains(where:{$0[NativeSourceCohortCenterBalance.auditKey] != nil}) {
                do { trial=try NativeSourceCohortCenterBalance.preservingReceipts(prior:prior,admitted:trial,page:page) }
                catch { lineageRollback="physical-readmission-cohort-receipt-or-peer-gutter";return prior }
            }
            return trial
        }
        var refined=physicalRefinement(anchored)
        guard refined.fills.count==baseline.fills.count,refined.audit.count==baseline.audit.count else{return layer}
        var terminalBodyValidation: NativeBodySourceAnchorRecovery.Validation?
        if !bodyChanged.isEmpty {
            // Validate the complete final tuple with the SAME contract as the
            // helper, including stationary body members later moved by physical
            // correction, source-aware gaps, mask margins, order and flow axis.
            let bodies = Set(bodyChanged.compactMap { baseline.fills[$0].balloonPlacement?.bodyID })
            let validation = NativeBodySourceAnchorRecovery.validateTerminal(stageBaseline,terminal:refined,
                recoveredBodyIDs:bodies,page:page,boundaryGate:boundaryGate)
            terminalBodyValidation = validation
            if !validation.accepted {
                anchored=stageBaseline;bodyChanged=[]
                bodyRollback="physical-reconciliation-source-contract: \(validation.reason)"
                // A rejected body trial must not suppress the original physical
                // pass; retry from the unchanged original raster transaction.
                refined=physicalRefinement(stageBaseline)
            }
        }
        guard refined.fills.count==baseline.fills.count,refined.audit.count==baseline.audit.count else{return layer}
        if !edgeChanged.allSatisfy({refined.fills[$0].frame==stageBaseline.fills[$0].frame}) {
            // Keep the independently admitted exterior transaction if a later
            // pass unexpectedly changes its owners; do not retain a mixed tuple.
            refined=stageBaseline;anchored=stageBaseline;bodyChanged=[]
            terminalBodyValidation=nil
            bodyRollback="later-pass-changed-admitted-edge-cohort"
        }
        if !cohortChanged.isEmpty {
            do { refined=try NativeSourceCohortCenterBalance.preservingReceipts(prior:stageBaseline,admitted:refined,page:page) }
            catch {
                // Preserve the independent edge+cohort transaction and retry the
                // physical-only path; no mixed or partially rebound receipt.
                anchored=stageBaseline;bodyChanged=[];terminalBodyValidation=nil
                bodyRollback="terminal-cohort-receipt-or-peer-gutter"
                refined=physicalRefinement(stageBaseline)
            }
        }
        // A later fixed-raster move cannot rebase a reshaped owner's source
        // exemptions onto the NEW glyph alpha. Recheck any such move against
        // the same original pre-lexical owner, or retain the already gated layer.
        var lexicalSourceGates:[[String:Any]]=[]
        if let context,let originals=lexicalOriginals {
            guard originals.fills.count==baseline.fills.count,
                  originals.fills.map(\.ownerID)==baseline.fills.map(\.ownerID) else {
                var audit=layer.audit;audit["lexicalTerminalSourceGateRollback"]="original-owner-binding"
                return .init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,
                    complete:layer.complete,audit:audit)
            }
            for i in baseline.fills.indices where originals.fills[i].image !== baseline.fills[i].image &&
                refined.fills[i].frame != baseline.fills[i].frame {
                try Task.checkCancellation()
                let gate=context.shapeClearance(incumbent:originals.fills[i],
                    before:try NativeFinalTextPaintAdmission.retainedFootprint(originals.fills[i]),
                    after:try NativeFinalTextPaintAdmission.retainedFootprint(refined.fills[i]),page:page)
                lexicalSourceGates.append(["owner":baseline.fills[i].ownerID ?? "",
                    "allowed":gate.allowed as Any? ?? NSNull(),"audit":gate.audit])
                guard gate.allowed==true else {
                    var audit=layer.audit;audit["lexicalTerminalSourceGateRollback"]="later-move-not-original-source-gated"
                    audit["lexicalTerminalSourceGates"]=lexicalSourceGates
                    return .init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,
                        complete:layer.complete,audit:audit)
                }
            }
        }
        var metadata=layer.audit
        if !cohortChanged.isEmpty {metadata["sourceCohortCenterBalance"]=stageBaseline.audit}
        if let cohortRollback {metadata["sourceCohortCenterBalanceRollback"]=cohortRollback}
        if !lexicalSourceGates.isEmpty {metadata["lexicalTerminalSourceGates"]=lexicalSourceGates}
        if context != nil {metadata["sourcePhysicalInterior"] = refined.audit}
        if let bodyRollback {metadata["bodySourceAnchorRecoveryRollback"]=bodyRollback}
        if let terminalBodyValidation {metadata["bodySourceAnchorRecoveryTerminalValidation"] = terminalBodyValidation.audit}
        if !bodyChanged.isEmpty {metadata["bodySourceAnchorRecovery"]=anchored.audit}
        if !edgeChanged.isEmpty {metadata["retainedPageEdgeRecovery"]=stageBaseline.audit}
        if let edgeRollback {metadata["retainedPageEdgeRecoveryRollback"]=edgeRollback}
        if let lineageRollback {metadata["retainedBalloonStateRollback"]=lineageRollback}
        let changed=baseline.fills.indices.filter {baseline.fills[$0].frame != refined.fills[$0].frame}
        guard !changed.isEmpty else {
            return .init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,
                complete:layer.complete,audit:metadata)
        }
        var repaintStage="palette-before-repaint"
        do {
            guard let palettes=preservedPalettes(refined) else{throw invalidGeometry()}
            if var rows=metadata["rawNativeItems"]as?[[String:Any]],rows.count==refined.fills.count {
                for i in changed {
                    let dx=refined.fills[i].frame.minX-baseline.fills[i].frame.minX
                    let dy=refined.fills[i].frame.minY-baseline.fills[i].frame.minY
                    for key in ["frameOutputTopLeft","retainedFillBoundsOutput"] {
                        if var box=rows[i][key]as?[CGFloat],box.count==4 {box[0]+=dx;box[1]+=dy;rows[i][key]=box}
                    }
                    if context != nil {rows[i]["sourcePhysicalInterior"] = refined.audit[i]}
                    if let body=refined.audit[i]["bodySourceAnchorRecovery"] {rows[i]["bodySourceAnchorRecovery"]=body}
                    if let cohort=refined.audit[i][NativeSourceCohortCenterBalance.auditKey] {
                        rows[i][NativeSourceCohortCenterBalance.auditKey]=cohort
                    }
                    if let edge=stageBaseline.audit[i]["retainedPageEdgeRecovery"] {rows[i]["retainedPageEdgeRecovery"]=edge}
                }
                metadata["rawNativeItems"] = rows
            }
            let staged=NativeAOTTranslationPageComposer.TextLayer(image:layer.image,expectedItems:layer.expectedItems,
                paintedItems:layer.paintedItems,complete:layer.complete,audit:metadata)
            repaintStage="terminal-repaint"
            let final=try NativeAOTTranslationPageComposer.refineFinalReadability(layer:staged,fills:baseline.fills,
                restored:restored,admittedOverride:refined,forceRepaint:true)
            repaintStage="palette-after-repaint"
            guard let after=final.audit["endpointDecisions"]as?[[String:Any]],after.count==palettes.count,
                  after.indices.allSatisfy({NativeBalloonReadabilityReflow.paintDecisionMatches(after[$0],palette:palettes[$0])})else{throw invalidGeometry()}
            repaintStage="final-body-state-binding"
            guard let finalAdmission=final.audit["finalPaintAdmission"]as?[[String:Any]],
                  finalAdmission.count==refined.audit.count else{throw invalidGeometry()}
            let stateKey=NativeBalloonPlacement.RetainedState.auditKey
            for i in finalAdmission.indices {
                let paintedState=try JSONSerialization.data(withJSONObject:["state":finalAdmission[i][stateKey] ?? NSNull()],options:.sortedKeys)
                let retainedState=try JSONSerialization.data(withJSONObject:["state":refined.audit[i][stateKey] ?? NSNull()],options:.sortedKeys)
                guard finalAdmission[i]["owner"]as?String==refined.fills[i].ownerID,
                      paintedState==retainedState else{throw invalidGeometry()}
                let proofKey=NativeSourceCohortCenterBalance.auditKey
                let paintedProof=try JSONSerialization.data(withJSONObject:["proof":finalAdmission[i][proofKey] ?? NSNull()],options:.sortedKeys)
                let retainedProof=try JSONSerialization.data(withJSONObject:["proof":refined.audit[i][proofKey] ?? NSNull()],options:.sortedKeys)
                guard paintedProof==retainedProof else{throw invalidGeometry()}
            }
            var audit=final.audit
            if !cohortChanged.isEmpty {
                audit["sourceCohortCenterBalanceApplied"]=cohortChanged.filter {changed.contains($0)}.compactMap {refined.fills[$0].ownerID}
                audit["sourceCohortCenterBalanceTerminalOnly"]=true
            }
            let physicalChanged=refined.fills.indices.filter {refined.fills[$0].frame != anchored.fills[$0].frame}
            if !physicalChanged.isEmpty {
                audit["sourcePhysicalInteriorApplied"]=physicalChanged.compactMap{refined.fills[$0].ownerID}
                audit["sourcePhysicalInteriorTerminalOnly"]=true
            }
            if !bodyChanged.isEmpty {
                audit["bodySourceAnchorRecoveryApplied"]=bodyChanged.filter {changed.contains($0)}.compactMap{refined.fills[$0].ownerID}
                audit["bodySourceAnchorRecoveryTerminalOnly"]=true
            }
            if !edgeChanged.isEmpty {
                audit["retainedPageEdgeRecoveryApplied"]=edgeChanged.compactMap {refined.fills[$0].ownerID}
                audit["retainedPageEdgeRecoveryTerminalOnly"]=true
            }
            returnedTuple = refined
            return .init(image:final.image,expectedItems:final.expectedItems,paintedItems:final.paintedItems,
                complete:final.complete,audit:audit)
        }catch{
            if error is CancellationError{throw error}
            var audit=layer.audit
            audit["finalSourcePhysicalInteriorRollbackStage"]=repaintStage
            audit[context != nil ? "sourcePhysicalInteriorRollback":"bodySourceAnchorRecoveryRollback"]="retained-incumbent: \(error)"
            return .init(image:layer.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,
                complete:layer.complete,audit:audit)
        }
    }

    /// The unmasked retained frame includes both paint reservation and padding.
    /// Terminal width requests use only the shaping content, in output pixels.
    private static func retainedExteriorContentWidth(outerWidth:CGFloat,font:CGFloat,raw:[String:Any]?) -> CGFloat? {
        guard outerWidth.isFinite, font.isFinite, font>0 else {return nil}
        let inset=NativeTextSpacing.outwardExtent(raw:raw,fontSize:font)+NativeTextSpacing.padding(fontSize:font)
        let width=outerWidth-2*inset
        guard inset.isFinite, width.isFinite, width>0 else {return nil}
        return width
    }

    /// Raster proposals only. Complete-peer final admission and painting belong
    /// to the caller; terminal exterior candidates must never compose a page here.
    private static func renderPrimitives(items: [Item], viewport: CGSize, restored: CGImage, allowShrink: Bool,
                                      contours: [String: NativeRawBalloonCapacity.Contour], options: [String:[String:Any]],
                                      excludedTailOwners:Set<String>, recordRefinement:(String)->Void,
                                      boundedInteriorWidth:CGFloat?=nil,retainedPitch:CGFloat?=nil,
                                      terminalExteriorContentWidth:CGFloat?=nil,terminalExteriorFont:CGFloat?=nil,
                                      terminalExteriorWholeWords:Bool=false,
                                      terminalInteriorOuterWidth:CGFloat?=nil,terminalInteriorFont:CGFloat?=nil,
                                      terminalInteriorContourRanges:[NSRange]?=nil,terminalInteriorContourAnchor:CGRect?=nil,
                                      outputWidthPlans:[String:NativeOwnerOutputWidthPlan]=[:],
                                      preferredOuterWidths:[String:CGFloat]=[:],retainedFontPixels:[String:CGFloat]=[:],
                                      pitchFamilyItems:[Item]?=nil,collectFixedFontFailures:Bool=false) throws
        ->(audit:[[String:Any]],primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive]) {
        try Task.checkCancellation()
        guard viewport.width > 0, viewport.height > 0, items.count <= 4096 else { throw invalidGeometry() }
        let sx = CGFloat(restored.width)/viewport.width, sy = CGFloat(restored.height)/viewport.height
        guard abs(sx-sy) < 0.01 else { throw invalidGeometry() }
        let page = CGRect(x:0,y:0,width:restored.width,height:restored.height)
        let contourRequested=terminalInteriorContourRanges != nil || terminalInteriorContourAnchor != nil
        guard !contourRequested || (items.count==1 && terminalInteriorOuterWidth != nil && terminalInteriorFont != nil &&
            retainedPitch != nil && terminalInteriorContourRanges != nil && terminalInteriorContourAnchor != nil) else {throw invalidGeometry()}
        var primitives: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive] = []
        var audit: [[String: Any]] = []
        var paintedFrames: [CGRect] = []
        var paintedInk: [CGRect] = []
        let protected = protectedRects(rawItems: Array(options.values), viewport: viewport, scale: sx)
        var failedShapeOwners=Set<String>()
        var sharedPitches:[String:CGFloat]=[:]
        for item in pitchFamilyItems ?? items {
            guard let family=options[item.id]?["typographyGroupID"] as? String else { continue }
            let pixels=max(2,item.fontSize*sx)
            let font=CTFontCreateWithName(try sourceFontName(raw:options[item.id]) as CFString,pixels,nil)
            let outward=NativeTextSpacing.outwardExtent(raw:options[item.id],fontSize:pixels)
            let measured=NativeTextSpacing.pitch(text:item.text,font:font,fontSize:pixels,outwardExtent:outward)
            let em=(options[item.id]?["lineHeightEm"] as? Double).map { CGFloat($0)*pixels } ?? 0
            sharedPitches[family]=max(sharedPitches[family] ?? 0,measured,em)
        }
        for item in items {
            do {
            guard item.fontSize.isFinite, item.fontSize > 0, item.lineHeight.isFinite,
                  !item.text.isEmpty, !item.frame.isNull, item.frame.width > 0, item.frame.height > 0,
                  [item.frame.minX,item.frame.minY,item.frame.maxX,item.frame.maxY].allSatisfy(\.isFinite) else {
                throw invalidGeometry()
            }
            var base = CGRect(x:item.frame.minX*sx,y:item.frame.minY*sy,
                width:item.frame.width*sx,height:item.frame.height*sy)
            if terminalExteriorContentWidth == nil, terminalInteriorOuterWidth == nil, let slot = options[item.id]?["balloonLayoutRectNormalized"] as? [Double] {
                guard slot.count == 4, slot.allSatisfy(\.isFinite), slot[2] > 0, slot[3] > 0 else { throw invalidGeometry() }
                let proposed = CGRect(x: slot[0] * page.width, y: slot[1] * page.height,
                    width: slot[2] * page.width, height: slot[3] * page.height)
                guard page.contains(proposed) else { throw invalidGeometry() }
                base = proposed
            }
            let ownerWidthPlan=outputWidthPlans[item.id]
            if let proof=NativeEffectSafePitch.current {
                try proof.activate(item.id)
                if ownerWidthPlan != nil {try proof.recordShape(item.id)}
            }
            guard ownerWidthPlan.map({ $0.outputPixels.isFinite && $0.outputPixels > 0 }) ?? true else {
                throw invalidGeometry()
            }
            var surfaceCapacity:CGRect?
            let preserveFont = ownerWidthPlan != nil || terminalInteriorOuterWidth != nil || terminalExteriorContentWidth != nil || boundedInteriorWidth != nil || options[item.id]?["renderPreserveRequestedFontSize"] as? Bool == true ||
                options[item.id]?["typographyGroupID"] is String
            if let descriptor=options[item.id]?["originalClosedSurfaceCapacity"] as? [String:Any] {
                guard descriptor["version"] as? Int==1,
                      let r=descriptor["slotNormalized"] as? [Double],r.count==4,r.allSatisfy(\.isFinite),r[2]>0,r[3]>0,
                      CGRect(x:0,y:0,width:1,height:1).contains(CGRect(x:r[0],y:r[1],width:r[2],height:r[3])) else {
                    throw invalidGeometry()
                }
                // The original source patch is not the whole balloon. Preserve the
                // established requested-font expansion policy when explicitly enabled.
                if !preserveFont {
                    surfaceCapacity=CGRect(x:r[0]*page.width,y:r[1]*page.height,width:r[2]*page.width,height:r[3]*page.height)
                }
            }
            let contourCapacity = NativeRawBalloonCapacity.connectedContour(raw: options[item.id] ?? [:], viewport: viewport)
                .map { $0.rect.applying(CGAffineTransform(scaleX: sx, y: sy)).intersection(page) }
            let expansionPolicy = try NativeTextExpansionPolicy.decode(options[item.id]?["textExpansionPolicy"])
            let sourceGuide=try NativeTextPlacementGuide.decode(options[item.id]?["textPlacementGuide"])
            // A source bbox is a preferred width, never a legacy outer layout
            // width or an authority to change the external font/cluster EM.
            let sourcePreferredWidth=sourceGuide?.rect(in:page).width ?? item.frame.width*sx
            let lineSizeLimit=sourceGuide.flatMap { guide in expansionPolicy?.sourceLineSizeLimit(source:guide.rect(in:page)) }
            let capacity = expansionPolicy.map { NativeTextExpansionPolicy.rect($0.allowedRectNormalized,page:page) }
                ?? surfaceCapacity ?? contourCapacity ?? page
            let nativeMaskSurface = renderMaskSurface(raw: options[item.id], viewport: viewport, scale: sx)
            let foreignSourceRects = options.values.filter { $0["id"] as? String != item.id }.compactMap { raw -> CGRect? in
                guard let b = raw["sourceBounds"] as? [Double], b.count == 4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0 else { return nil }
                return CGRect(x: b[0]*page.width, y: b[1]*page.height, width: b[2]*page.width, height: b[3]*page.height)
            }
            let isVertical = vertical(options[item.id])
            let expected = item.text.utf16.count
            // One bounded owner-local table also serves CJK evidence and
            // repeated width proposals; cached lines never depend on width.
            let measurements = NativeScopedShapePlanCache.Measurements(enabled: true)
            var maskFrameTrace: [[String: Double]] = []
            let traceMask = ProcessInfo.processInfo.environment["AIDOKU_TRACE_RENDER_MASK"] == "1"
            var selected: (NativeFinalTextFlow.Plan,CGRect,CGFloat,CGFloat)?
            var collisionCandidate: (NativeFinalTextFlow.Plan,CGRect,CGFloat,CGFloat,CGFloat)?
            let requestedLock = !preserveFont && options[item.id]?["ensembleLockLayout"] as? Bool == true
            var locked=requestedLock
            for lockAttempt in requestedLock ? [true,false] : [false] {
            locked=lockAttempt
            collisionCandidate=nil
            let singleWidthIngress=NativeSimpleTextLayout.widthFitEnabled && !locked && !isVertical &&
                ownerWidthPlan == nil && terminalInteriorOuterWidth == nil && terminalExteriorContentWidth == nil &&
                boundedInteriorWidth == nil && NativeEffectSafePitch.current == nil
            let scales: [CGFloat] = locked ? [1] : (allowShrink && !preserveFont) ?
                (surfaceCapacity == nil ? [] : [1]) + [0.82,0.74,0.66,0.58,0.50,0.42,0.34,0.26,0.18,0.12,0.08] : [1]
            let fullPageGrowth = max(capacity.width / max(base.width, item.fontSize * sx),
                capacity.height / max(base.height, item.lineHeight * sx * 2))
            let growthPasses: [[CGFloat]] = locked ? [[1]] : (allowShrink && !preserveFont) ? [[1],[1.12,1.25]] : [[1,1.25,1.5,2,2.5,3,4,6,8,max(8,fullPageGrowth * 1.34)]]
            let maskGrowthPasses = singleWidthIngress || ownerWidthPlan != nil || terminalInteriorOuterWidth != nil ? [[CGFloat(1)]] : terminalExteriorContentWidth != nil || boundedInteriorWidth != nil ? [[CGFloat(1)]]:nativeMaskSurface != nil && !locked
                ? [[CGFloat(1),0.95,0.9,0.85,0.8,0.75,0.7,0.65,0.6,0.5] + growthPasses.flatMap { $0 }]
                : growthPasses
            for growthPass in maskGrowthPasses {
            for scale in scales {
                let fontPixels = retainedFontPixels[item.id] ?? terminalInteriorFont ?? terminalExteriorFont ?? max(2,item.fontSize*sx*scale)
                let font = CTFontCreateWithName(try sourceFontName(raw:options[item.id]) as CFString,fontPixels,nil)
                let outward = NativeTextSpacing.outwardExtent(raw: options[item.id], fontSize: fontPixels)
                var pitch = NativeTextSpacing.pitch(text: item.text, font: font,
                    fontSize: fontPixels, outwardExtent: outward)
                if let em = options[item.id]?["lineHeightEm"] as? Double {
                    guard em.isFinite, (1...4).contains(em) else { throw invalidGeometry() }
                    pitch = max(pitch, fontPixels * CGFloat(em))
                }
                if let family=options[item.id]?["typographyGroupID"] as? String,let shared=sharedPitches[family] {
                    pitch=max(pitch,shared*fontPixels/max(0.001,item.fontSize*sx))
                }
                if let retainedPitch {pitch=retainedPitch}
                if ownerWidthPlan != nil,let proof=NativeEffectSafePitch.current {pitch=try proof.pitchFloor()}
                let singleWidthFit:NativeSimpleTextLayout.SingleWidthFit?
                if singleWidthIngress {
                    singleWidthFit=try NativeSimpleTextLayout.fitSingleWidth(text:item.text,font:font,size:fontPixels,
                        preferredOuterWidth:preferredOuterWidths[item.id] ?? sourcePreferredWidth,
                        maximumOuterWidth:capacity.width,availableHeight:capacity.height,
                        outwardExtent:outward,padding:NativeTextSpacing.padding(fontSize:fontPixels),
                        minimumLineHeight:pitch,color:item.chosenFill)
                    // No feasible width is a real shape failure. Existing
                    // bounded font/cohort recovery owns the next transaction.
                    guard singleWidthFit != nil else {continue}
                } else {singleWidthFit=nil}
                var alignment = CTTextAlignment.center
                switch options[item.id]?["textAlignment"] as? String {
                case "left": alignment = .left
                case "right": alignment = .right
                default: break
                }
                if NativeSimpleTextLayout.enabled {
                    alignment = expansionPolicy?.insideBalloon == true ? .center : .left
                }
                let paragraph: CTParagraphStyle = withUnsafePointer(to:&alignment) { ap in
                    var minimumHeight = pitch, maximumHeight = pitch
                    return withUnsafePointer(to:&minimumHeight) { minp in
                        withUnsafePointer(to:&maximumHeight) { maxp in
                            let settings = [
                                CTParagraphStyleSetting(spec:.alignment,valueSize:MemoryLayout<CTTextAlignment>.size,value:ap),
                                CTParagraphStyleSetting(spec:.minimumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:minp),
                                CTParagraphStyleSetting(spec:.maximumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:maxp)]
                            return CTParagraphStyleCreate(settings,settings.count)
                        }
                    }
                }
                var attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String):font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):item.chosenFill,
                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String):paragraph]
                if let tracking = options[item.id]?["trackingEm"] as? Double {
                    guard tracking.isFinite, tracking == 0 else { throw invalidGeometry() }
                    attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = 0
                }
                if isVertical { attributes[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true }
                let text = NSAttributedString(string: item.text, attributes: attributes)
                let setter = isVertical ? CTFramesetterCreateWithAttributedString(text) : nil
                var measuredGrowth:[CGFloat]=[]
                if !singleWidthIngress,terminalInteriorOuterWidth == nil,terminalExteriorContentWidth == nil,!locked,!isVertical,expansionPolicy?.insideBalloon==false {
                    let padding=2*(outward+NativeTextSpacing.padding(fontSize:fontPixels))
                    let readable=preserveFont ? fontPixels*min(3.5,CGFloat(max(1,item.text.count))):fontPixels
                    let basis=max(base.width,readable)
                    measuredGrowth=NativeRenderWrapQuality.lexicalLineWidths(text,minimumWidth:max(1,basis-padding),
                        maximumWidth:capacity.width-padding,limit:8,lineFactory:measurements.line).map {($0+padding)/basis}
                }
                for growth in growthPass+measuredGrowth {
                    // Source Japanese column width is not a readable Korean line width.
                    let readableWidth = preserveFont ? fontPixels * min(3.5, CGFloat(max(1, item.text.count))) : fontPixels
                    let proposedWidth:CGFloat
                    if let fit=singleWidthFit {
                        proposedWidth=fit.outerWidth
                    } else if let plan=ownerWidthPlan {
                        guard plan.outputPixels <= capacity.width else {continue}
                        proposedWidth=plan.outputPixels
                    } else if let width=terminalInteriorOuterWidth {
                        proposedWidth=width
                    } else if let width=terminalExteriorContentWidth {
                        proposedWidth=width+2*(outward+NativeTextSpacing.padding(fontSize:fontPixels))
                    } else if let width=boundedInteriorWidth {
                        proposedWidth=min(capacity.width,width)
                    } else {
                        proposedWidth=locked ? base.width:min(capacity.width,max(base.width,isVertical ? pitch:readableWidth)*growth)
                    }
                    let inset = outward + NativeTextSpacing.padding(fontSize:fontPixels)
                    guard proposedWidth > inset*2, capacity.height > inset*2,
                          (terminalExteriorContentWidth == nil && terminalInteriorOuterWidth == nil) || proposedWidth <= capacity.width else { continue }
                    let suggested = setter.map { CTFramesetterSuggestFrameSizeWithConstraints($0,
                        CFRange(location: 0, length: expected), nil,
                        CGSize(width: proposedWidth-inset*2, height: capacity.height-inset*2), nil) } ?? .zero
                    let flowOptions: [NativeFinalTextFlow.Plan?]
                    do {
                    if let fit=singleWidthFit {
                        guard let flow=try NativeFinalTextFlow.horizontalSingleWidth(fit,outwardExtent:outward,
                            padding:NativeTextSpacing.padding(fontSize:fontPixels)) else {continue}
                        flowOptions=[flow]
                    } else if contourRequested {
                        guard !isVertical,alignment == .center,
                              let originalRanges=terminalInteriorContourRanges,let anchor=terminalInteriorContourAnchor,
                              let policy=expansionPolicy,policy.valid,policy.insideBalloon,
                              let contour=try NativeFinalTextFlow.horizontalContourWords(text:item.text,font:font,size:fontPixels,
                                  width:proposedWidth-2*inset,minimumLineHeight:pitch,outwardExtent:outward,
                                  policy:policy,page:page,anchor:anchor,originalRanges:originalRanges,
                                  color:item.chosenFill,lineFactory:measurements.line) else{continue}
                        flowOptions=[contour]
                    } else if isVertical {
                        flowOptions = [nil]
                    } else if ownerWidthPlan != nil || terminalInteriorOuterWidth != nil || boundedInteriorWidth != nil || terminalExteriorContentWidth != nil {
                        let positioner:NativeFinalTextFlow.RowPositioner? = NativeEffectSafePitch.current.map { proof in
                            { wrapped,width in try proof.certify(wrapped).position(wrapped,width:width) }
                        }
                        guard let fixed=try NativeFinalTextFlow.horizontalFixedWidth(text:item.text,
                            font:font,size:fontPixels,width:proposedWidth-2*inset,minimumLineHeight:pitch,
                            outwardExtent:outward,color:item.chosenFill,lineFactory:measurements.line,
                            preferWholeWords:ownerWidthPlan != nil || terminalInteriorOuterWidth != nil || terminalExteriorWholeWords,
                            certifiedPositioner:positioner)else{continue}
                        if terminalInteriorOuterWidth != nil || terminalExteriorContentWidth != nil {
                            guard fixed.appliedTracking == 0,
                                  fixed.baselines.indices.dropFirst().allSatisfy({
                                      abs(fixed.baselines[$0].y-fixed.baselines[$0-1].y-pitch)<0.0001
                                  }) else {continue}
                        }
                        flowOptions=[fixed]
                    } else {
                        let candidates = try NativeFinalTextFlow.horizontalCandidates(text: item.text,
                            font: font, size: fontPixels, width: proposedWidth - 2 * inset,
                            maximumWidth: capacity.width - 2 * inset,
                            minimumLineHeight: pitch, outwardExtent: outward, color: item.chosenFill,
                            allowRefinement: !excludedTailOwners.contains(item.id) && !locked,
                            preferCompactRefinement: expansionPolicy?.insideBalloon == false && options[item.id]?["renderLegacyWordRefinement"]as?Bool != true,
                            lineFactory: measurements.line)
                        if candidates.isEmpty { continue }
                        flowOptions = candidates.map { Optional($0) }
                    }
                    } catch NativeWholeWordWrap.Failure.noFittingLayout {continue}
                    // Every option passes the same containment and peer checks.
                    // If a wider refinement is rejected, the unchanged initial
                    // fit remains next in this bounded list.
                    for horizontalFlow in flowOptions {
                        let width = horizontalFlow?.refinementOriginWidth == nil ? proposedWidth :
                            min(capacity.width, (horizontalFlow?.size.width ?? 0) + 2 * inset)
                        let measuredHeight = horizontalFlow?.size.height ?? suggested.height
                        let height = terminalInteriorOuterWidth != nil ? capacity.height : locked ? base.height : isVertical ? min(capacity.height, max(base.height, fontPixels * CGFloat(min(10, max(1, item.text.count)))) * growth) : (preserveFont || singleWidthFit != nil)
                            ? min(capacity.height, max(pitch * 1.25+inset*2, ceil(measuredHeight + pitch * 0.25+inset*2)))
                            : min(capacity.height,max(base.height,pitch*2)*max(1,growth*0.75))
                        let offsets: [(CGFloat,CGFloat)] = [(0,0)]
                        for (dx,dy) in offsets {
                            let x = locked ? base.minX : max(capacity.minX,min(capacity.maxX-width,base.midX-width/2+dx*width))
                            let desiredY=surfaceCapacity == nil ? base.midY : capacity.midY
                            let y = locked ? base.minY : max(capacity.minY,min(capacity.maxY-height,desiredY-height/2+dy*height))
                            var box = CGRect(x:x,y:y,width:width,height:height).intersection(page)
                            guard !box.isEmpty else { continue }
                            if surfaceCapacity != nil,!capacity.contains(box) {continue}
                            guard let content = NativeTextSpacing.contentRect(box, fontSize: fontPixels,
                                outwardExtent: outward) else { continue }
                            let quartzBox = CGRect(x:content.minX,y:page.height-content.maxY,width:content.width,height:content.height)
                            let frameAttributes = isVertical
                                ? [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary : nil
                            let frame: NativeFinalTextFlow.Plan
                            if isVertical {
                                guard let setter else { continue }
                                let vertical = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                    CGPath(rect: quartzBox, transform: nil), frameAttributes)
                                frame = NativeFinalTextFlow.vertical(frame: vertical, size: content.size, expectedUTF16: expected)
                            } else {
                                guard let flow = horizontalFlow?.aligned(alignment).centered(height: content.height,
                                      usingInkCapacity:singleWidthFit != nil || (preserveFont && NativeTextSpacing.useInkCapacity(raw:options[item.id]))),
                                      abs(flow.size.width - content.width) <= 0.01 else { continue }
                                frame = flow
                            }
                            var drawingBox = content
                            guard frame.complete else { continue }
                            if let nativeMaskSurface {
                                var actual = CGRect.null
                                for i in frame.lines.indices {
                                    let bounds = frame.imageAndGlyphPathBounds(at: i)
                                    if !bounds.isNull && !bounds.isEmpty {
                                        actual = actual.union(CGRect(x:content.minX+frame.baselines[i].x+bounds.minX,
                                            y:content.minY+frame.baselines[i].y-bounds.maxY,width:bounds.width,height:bounds.height))
                                    }
                                }
                                guard !actual.isNull && !actual.isEmpty else { continue }
                                // Shaping includes transparent line-height capacity.
                                // Fit the actual rendered bbox, including all effects,
                                // rather than demanding that unused capacity fit too.
                                let footprint = (isVertical ? content.union(actual).insetBy(dx:-fontPixels,dy:-fontPixels)
                                    : actual.insetBy(dx:-2,dy:-2)).integral.insetBy(dx:-outward,dy:-outward)
                                let margin = max(2,fontPixels*0.2)
                                if traceMask && maskFrameTrace.count<64 {
                                    maskFrameTrace.append(["width":Double(footprint.width),"height":Double(footprint.height),"font":Double(fontPixels),"outward":Double(outward)])
                                }
                                guard let aligned = nativeMaskSurface.containedRenderBox(footprint, within:capacity,
                                    margin:margin, protectedRects:foreignSourceRects+paintedFrames) else {continue}
                                drawingBox=drawingBox.offsetBy(dx:aligned.minX-footprint.minX,
                                    dy:aligned.minY-footprint.minY)
                                box=aligned
                            }
                            if !isVertical {
                                let ink = frame.inkBounds
                                guard !ink.isNull, CGRect(origin: .zero, size: content.size)
                                    .insetBy(dx: -0.01, dy: -0.01).contains(ink) else { continue }
                                if frame.refinementOriginWidth != nil,let policy=expansionPolicy,
                                   let original=flowOptions.compactMap({$0}).first(where:{$0.refinementOriginWidth==nil}) {
                                    let words=NativeRenderWrapQuality.wordJoinWidths(text,ranges:original.ranges,
                                        includeAttachedPunctuation:true)
                                    let word=options[item.id]?["renderLegacyWordRefinement"]as?Bool == true ?
                                        words.min():words.max()
                                    if !policy.allowsRefinementShape(original:original.inkBounds,proposed:ink,
                                        font:fontPixels,requiredWordWidth:word) {continue}
                                }
                                if let limit=lineSizeLimit,
                                   ink.width+2*outward+4>limit.width || ink.height+2*outward+4>limit.height { continue }
                            }
                            if surfaceCapacity != nil {
                                let lines = frame.lines, origins = frame.baselines
                                let halo = NativeTextSpacing.outwardExtent(raw: options[item.id], fontSize: fontPixels)
                                    + NativeTextSpacing.padding(fontSize: fontPixels)
                                guard lines.indices.allSatisfy({ i in
                                    let ink = frame.glyphPathBounds(at: i)
                                    if ink.isEmpty {return true}
                                    let row=CGRect(x:drawingBox.minX+origins[i].x+ink.minX,y:drawingBox.minY+origins[i].y-ink.maxY,width:ink.width,height:ink.height)
                                    return capacity.contains(row.insetBy(dx:-halo,dy:-halo))
                                }) else{continue}
                            }
                            let overlap = paintedFrames.reduce(CGFloat.zero) { total,peer in
                                let intersection=peer.intersection(box)
                                return total+(intersection.isNull ? 0 : intersection.width*intersection.height)
                            }
                            if overlap == 0 {selected=(frame,drawingBox,fontPixels,width);break}
                            if collisionCandidate == nil || overlap < collisionCandidate!.3 {
                                collisionCandidate=(frame,drawingBox,fontPixels,overlap,width)
                            }
                        }
                        if selected != nil {break}
                    }
                    if selected != nil {break}
                }
                if selected != nil {break}
            }
            if selected != nil {break}
            }
            // This is only a proposal. Final effect-alpha admission below must
            // relocate it safely or reject the transaction, including fallback.
            if selected == nil,let candidate=collisionCandidate {selected=(candidate.0,candidate.1,candidate.2,candidate.4)}
            if selected != nil {break}
            }
            guard let (frame,box,fontPixels,retainedOuterLayoutWidth) = selected else {
                if lineSizeLimit != nil || (expansionPolicy != nil &&
                    (constrainedShapeCapacityRetryEnabled || !allowShrink || preserveFont)) {
                    // Every complete frame was rejected by the supplied capacity.
                    // Preserve the domain and route through the existing bounded
                    // owner/body/font-cohort fit retry; never report missing text.
                    throw NativeFinalTextPaintAdmission.Failure.noSafePlacement(item.id)
                }
                if traceMask, nativeMaskSurface != nil,
                   let data = try? JSONSerialization.data(withJSONObject: maskFrameTrace, options: [.sortedKeys]) {
                    fputs("Native render mask capacity trace: " + String(decoding:data,as:UTF8.self) + "\n",stderr)
                }
                throw Failure.incompleteText(item.id)
            }
            let retainedFace=CTFontCreateWithName(try sourceFontName(raw:options[item.id]) as CFString,fontPixels,nil)
            let retainedOutward=NativeTextSpacing.outwardExtent(raw:options[item.id],fontSize:fontPixels)
            let familyPitch=(options[item.id]?["typographyGroupID"]as?String).flatMap {sharedPitches[$0]}
                .map {$0*fontPixels/max(0.001,item.fontSize*sx)} ?? 0
            let selectedPitch=NativeEffectSafePitch.current?.certificate(lines:frame.lines)?.pitch ?? retainedPitch ?? (frame.baselines.count>1 ?
                frame.baselines[1].y-frame.baselines[0].y:max(familyPitch,
                    NativeTextSpacing.pitch(text:item.text,font:retainedFace,fontSize:fontPixels,outwardExtent:retainedOutward),
                    CGFloat(options[item.id]?["lineHeightEm"]as?Double ?? 0)*fontPixels))
            if frame.refinementOriginWidth != nil { recordRefinement(item.id) }
            let originalString = item.text as NSString
            let actualLineTexts = frame.ranges.map { range -> String in
                guard range.location >= 0, range.length >= 0, range.location + range.length <= originalString.length else {return ""}
                return originalString.substring(with:NSRange(location:range.location,length:range.length))
                    .trimmingCharacters(in:.whitespacesAndNewlines)
            }
            let certificationDeviation = [abs(box.minX-base.minX),abs(box.minY-base.minY),
                abs(box.width-base.width),abs(box.height-base.height)].max() ?? 0
            let lines = frame.lines, origins = frame.baselines
            var fullInk = CGRect.null
            for i in lines.indices {
                let bounds = frame.imageAndGlyphPathBounds(at: i)
                if !bounds.isNull && !bounds.isEmpty {
                    fullInk = fullInk.union(CGRect(x: box.minX + origins[i].x + bounds.minX,
                        y: box.minY + origins[i].y - bounds.maxY, width: bounds.width, height: bounds.height))
                }
            }
            guard !fullInk.isNull, !fullInk.isEmpty else { throw Failure.incompleteText(item.id) }
            // CoreText line image bounds can describe only a horizontal cell
            // for vertical runs. Retain the complete vertical frame before
            // measuring actual alpha, so later glyphs cannot be cropped away.
            let crop = isVertical ? box.union(fullInk).insetBy(dx: -fontPixels, dy: -fontPixels).integral
                : fullInk.insetBy(dx: -2, dy: -2).integral
            guard crop.width <= 16_384, crop.height <= 16_384, crop.width <= 8_000_000 / crop.height else { throw Failure.allocation }
            try NativeFixedFontRecovery.metrics?.activeCache?.checkImage(owner:item.id,width:Int(crop.width),height:Int(crop.height))
            guard let context = CGContext(data:nil,width:Int(crop.width),height:Int(crop.height),
                bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.allocation }
            context.translateBy(x:-crop.minX,y:-(page.height-crop.maxY))
            context.textMatrix = .identity
            let boundSourceOnly = NativeOperationalAppearance.sourceContourOnly(options[item.id])
            if let proof=NativeEffectSafePitch.current,proof.certificate(lines:frame.lines) != nil {
                try proof.verify(lines:frame.lines,ranges:frame.ranges,origins:frame.baselines,box:box,font:fontPixels)
            }
            try NativeRecoveryDrawBudget.current?.chargeDraw(owner:item.id,fontPixels:fontPixels,
                stage:NativeEffectSafePitch.current != nil ? "measured-pitch":
                    (NativeFixedFontRecovery.metrics?.recoveryActive == true ? "fixed-font-recovery":"source-guarded-replay"))
            frame.draw(in: context, box: box, pageHeight: page.height)
            NativeFixedFontRecovery.metrics?.recordShape(owner:item.id,fontPixels:fontPixels)
            guard let image = context.makeImage() else { throw Failure.allocation }
            let bytes = try NativeMandatoryDisplayStroke.rgba(image)
            var rows: [(Int, Int, Int)] = []
            var ink = CGRect.null
            for y in 0..<image.height {
                var left = image.width, right = -1
                for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > 0 {
                    left = min(left, x)
                    right = x
                }
                if right >= left {
                    rows.append((y, left, right))
                    ink = ink.union(CGRect(x:left,y:y,width:right-left+1,height:1))
                }
            }
            var paintedCrop = crop
            var centeredPixels: CGFloat = 0
            var centeringAuthority = "source-box-proxy; not balloon center"
            if !ink.isNull && !locked {
                let contour = contours[item.id]
                var targetY = surfaceCapacity?.midY ?? base.midY
                if let contour, !contour.spans.isEmpty {
                    let widths = contour.spans.map { $0.1 - $0.0 }
                    if let maximum = widths.max(), maximum > 0 {
                        let step = contour.rect.height / CGFloat(widths.count)
                        var weightedY: CGFloat = 0, weight: CGFloat = 0
                        for i in widths.indices where widths[i] >= maximum * 0.65 {
                            weightedY += (contour.rect.minY + (CGFloat(i) + 0.5) * step) * widths[i]
                            weight += widths[i]
                        }
                        if weight > 0 { targetY = weightedY / weight * sy }
                    }
                }
                let targets: [(CGFloat, Bool)] = contour == nil ? [(targetY, false)] : [(targetY, true), (base.midY, false)]
                for (target, usesContour) in targets {
                        let shift = (target - (crop.minY + ink.midY)).rounded()
                        let proposed = crop.offsetBy(dx:0,dy:shift)
                        let halo = NativeTextSpacing.outwardExtent(raw:options[item.id],fontSize:fontPixels) + NativeTextSpacing.padding(fontSize:fontPixels)
                        let proposedInk = ink.offsetBy(dx:proposed.minX,dy:proposed.minY)
                        let clearOfPeers = paintedInk.allSatisfy { !$0.insetBy(dx:-halo,dy:-halo)
                            .intersects(proposedInk.insetBy(dx:-halo,dy:-halo)) }
                        let maskAllowsShift = nativeMaskSurface.map {
                            $0.contains(proposed.insetBy(dx: -max(2, fontPixels * 0.2)-halo,
                                dy: -max(2, fontPixels * 0.2)-halo))
                        } ?? true
                        let inside = maskAllowsShift && rows.allSatisfy { y,left,right in
                            let row = CGRect(x:(proposed.minX + CGFloat(left) - halo) / sx,
                                y:(proposed.minY + CGFloat(y) - halo) / sy,
                                width:(CGFloat(right-left+1) + 2*halo) / sx,
                                height:(1 + 2*halo) / sy)
                            if surfaceCapacity != nil {
                                guard capacity.contains(CGRect(x:row.minX*sx,y:row.minY*sy,width:row.width*sx,height:row.height*sy)) else{return false}
                            }
                            if usesContour { return contour?.contains(row) == true }
                            if surfaceCapacity != nil {return true}
                            return base.contains(CGRect(x:row.minX*sx,y:row.minY*sy,width:row.width*sx,height:row.height*sy))
                        }
                        if abs(shift) >= 1, page.contains(proposed), clearOfPeers, inside {
                            paintedCrop = proposed
                            centeredPixels = shift
                            centeringAuthority = usesContour ? "estimated-body-centroid; retained-glyph-and-halo-check; see rfBalloonContours" :
                                "source-box-proxy; model proposal unavailable or rejected"
                            break
                        }
                }
            }
            var nativeMaskBBoxRefit = CGPoint.zero
            if let nativeMaskSurface {
                let outward = NativeTextSpacing.outwardExtent(raw: options[item.id], fontSize: fontPixels)
                let margin = max(2, fontPixels * 0.2)
                let footprint = paintedCrop.insetBy(dx:-outward,dy:-outward)
                guard let repaired = nativeMaskSurface.containedRenderBox(footprint, within:page, margin:margin,
                    protectedRects:foreignSourceRects+paintedFrames) else {
                    if traceMask { fputs("Native render mask bbox cannot be refitted without clipping\n",stderr) }
                    throw Failure.incompleteText(item.id)
                }
                nativeMaskBBoxRefit = CGPoint(x:repaired.minX-footprint.minX,y:repaired.minY-footprint.minY)
                paintedCrop = paintedCrop.offsetBy(dx:nativeMaskBBoxRefit.x,dy:nativeMaskBBoxRefit.y)
                guard nativeMaskSurface.contains(paintedCrop.insetBy(dx:-outward-margin,dy:-outward-margin)) else {
                    throw Failure.incompleteText(item.id)
                }
            }
            if !ink.isNull { paintedInk.append(ink.offsetBy(dx:paintedCrop.minX,dy:paintedCrop.minY)) }
            if surfaceCapacity != nil {
                let halo=NativeTextSpacing.outwardExtent(raw:options[item.id],fontSize:fontPixels)+NativeTextSpacing.padding(fontSize:fontPixels)
                guard !ink.isNull,capacity.contains(ink.offsetBy(dx:paintedCrop.minX,dy:paintedCrop.minY).insetBy(dx:-halo,dy:-halo)) else {
                    throw Failure.incompleteText(item.id)
                }
            }
            let endpoint=(options[item.id]?["ensembleDisplayStroke"] as? [Double])?.first
            var primitive = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image:image,frame:paintedCrop,fontOutputPixels:fontPixels,
                displayStrokeEndpoint:endpoint.map {UInt8($0 > 127 ? 255 : 0)},displayStrokeRatio:(options[item.id]?["ensembleStrokeRatio"] as? Double).map {CGFloat($0)},
                recheckFinalEndpoint:options[item.id]?["ensembleFinalStrokeRecheck"] as? Bool == true,
                minimumFillStrokeContrast:options[item.id]?["ensembleFinalStrokeContrastFloor"] as? Double ?? 3,
                minimumCoverageGain:options[item.id]?["ensembleFinalStrokeMinimumGain"] as? Double ?? 0.05,
                sourceStyle:try NativeSourceStylePaint.style(options[item.id]))
            primitive.ownerID = item.id
            primitive.sourceAppearance = options[item.id]?["sourceAppearance"] as? [String:Any]
            primitive.sourceContourOnly = NativeOperationalAppearance.sourceContourOnly(options[item.id])
            if roundedSourceJoinsEnabled, NativeSourceStylePaint.roundedContourBindingEnabled,
               boundSourceOnly, !isVertical, frame.appliedTracking == 0,
               frame.discretionaryHyphenOffsets.isEmpty,
               abs(sourceGuide?.sourceRotationRadians ?? 0) <= 1e-6,
               let style = primitive.sourceStyle {
                let rows = actualLineTexts.map { NSAttributedString(string: $0, attributes: [
                    .init(kCTFontAttributeName as String): retainedFace,
                    .init(kCTForegroundColorAttributeName as String): item.chosenFill,
                    .init(kCTKernAttributeName as String): 0]) }
                let baselines = origins.map { CGPoint(x: box.minX + $0.x - crop.minX,
                    y: box.minY + $0.y - crop.minY) }
                do {
                    if let bound = try NativeSourceStylePaint.bindingRoundedContour(style, fill:image,rows:rows,
                        baselines:baselines,fontPixels:fontPixels,enabled:true) {
                        primitive.sourceStyle = NativeSourceStylePaint.deferringRoundedContour(bound)
                    }
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    // Unsupported derived paint evidence cannot alter line selection.
                }
            }
            primitive.sourceClusterAlignment = try NativeSourceClusterAlignment.decode(options[item.id]?["sourceClusterAlignment"])
            primitive.balloonPlacement = try NativeBalloonPlacement.decode(options[item.id]?["balloonPlacement"])
            primitive.textPlacementGuide = try NativeTextPlacementGuide.decode(options[item.id]?["textPlacementGuide"])
            primitive.placementDomain = placementDomain(raw: options[item.id] ?? [:], viewport: viewport, scale: sx, protected: protected)
            if let expansionPolicy {
                primitive.textExpansionPolicy=expansionPolicy
                let previous=primitive.placementDomain
                primitive.placementDomain={ expansionPolicy.allows($0,page:page) && (previous?($0) ?? true) }
            }
            primitive.certifyNativeDomainSubrects()
            if let guide=primitive.textPlacementGuide {
                // Rotate the retained native glyph before effect-alpha admission.
                // Source bands follow that glyph; observed shadow vectors stay
                // in their original page coordinates, preserving source lighting.
                (primitive.image,primitive.frame)=try guide.rotatedRaster(primitive.image,frame:primitive.frame)
            }
            let sourceRotationApplied=abs(primitive.textPlacementGuide?.sourceRotationRadians ?? 0)>1e-6
            let rotatedFillBounds=sourceRotationApplied ? try NativeFinalTextPaintAdmission.tight(primitive).frame:nil
            if let cache=NativeFixedFontRecovery.metrics?.activeCache {
                let support=try NativeFinalTextPaintAdmission.retainedFootprint(primitive)
                try cache.retain(owner:item.id,image:primitive.image,runCount:support.runs.count,
                    metadataBytes:4096+item.text.utf16.count*8+frame.ranges.count*16)
            }
            primitives.append(primitive)
            let collisions = paintedFrames.filter { $0.intersects(box) }.count
            paintedFrames.append(box)
            if locked, let flow = options[item.id]?["ensembleSharedFlowAudit"] as? [String:Any],
               let authority = flow["centerAuthority"] as? String {
                centeringAuthority = authority
            } else if locked,let near=options[item.id]?["sourceNearLayout"] as? [String:Any],
                      near["version"] as? Int==2,near["verticalAnchorMetric"] as? String=="source-top" {
                centeringAuthority="source-top-contract-v2; original OCR top geometry proxy, not balloon centering"
            }
            audit.append(["writingMode": isVertical ? "vertical-rl" : "horizontal-tb", "id":item.id,"sourceUTF16":expected,"visibleUTF16":frame.visibleUTF16,
                "lineBreakPolicy": isVertical ? "CoreText vertical forms"
                    : (NativeSimpleTextLayout.enabled ? NativeSimpleTextLayout.version : NativeLineBreakPolicy.version),
                "appliedTrackingPixels": frame.appliedTracking,
                "discretionaryHyphenUTF16Offsets": frame.discretionaryHyphenOffsets,
                "horizontalFlowQuality": frame.quality?.audit ?? [:],
                "tailRefinementOriginWidthPixels": frame.refinementOriginWidth.map { Double($0) as Any } ?? NSNull(),
                "lineMeasurementCache": ["hits": measurements.hits, "misses": measurements.misses,
                    "peakEntries": measurements.peak, "scope": "single owner; exact attributed UTF16; bounded"],
                "fontSize":Double(fontPixels/sx),"fontShrunkForCapacity":fontPixels < item.fontSize*sx-0.01,
                "retainedLinePitchOutputPixels":Double(selectedPitch),
                "simpleWidthIngressEnabled":NativeSimpleTextLayout.widthFitEnabled,
                "simpleWidthIngressApplied":NativeSimpleTextLayout.widthFitEnabled && !locked && !isVertical &&
                    ownerWidthPlan == nil && terminalInteriorOuterWidth == nil && terminalExteriorContentWidth == nil &&
                    boundedInteriorWidth == nil && NativeEffectSafePitch.current == nil,
                "preferredSourceWidthOutputPixels":Double(sourcePreferredWidth),
                "preferredWidthAuthority":sourceGuide == nil ? "legacy-item-frame-fallback;not-a-source-guide" : "source-placement-guide-bbox",
                "simpleWidthPreferenceOutputPixels":Double(preferredOuterWidths[item.id] ?? sourcePreferredWidth),
                "simpleWidthPreferenceAuthority":preferredOuterWidths[item.id] == nil ? "source-preferred" : "current-caller-layout-hint-final-admission-retry",
                "currentCallerOuterWidthOutputPixels":Double(base.width),
                "currentCallerOuterWidthAuthority":options[item.id]?["balloonLayoutRectNormalized"] == nil ? "current-caller-item-frame" : "current-caller-balloon-layout-slot",
                "fixedFontOutputWidthPixels":ownerWidthPlan.map {Double($0.outputPixels)} as Any? ?? NSNull(),
                "frameOutputTopLeft": nativeMaskSurface == nil ? [box.minX,box.minY,box.width,box.height]
                    : [paintedCrop.minX,paintedCrop.minY,paintedCrop.width,paintedCrop.height],
                "nativeBalloonMaskBoundaryApplied": nativeMaskSurface != nil,
                "nativeBalloonMaskBBoxRefitOutputPixels": [nativeMaskBBoxRefit.x,nativeMaskBBoxRefit.y],
                "nativeBalloonMaskMinimumOwnerCoverage": Double(NativeRawBalloonCapacity.minimumOwnerMaskCoverage),
                "nativeBalloonMaskMarginOutputPixels": nativeMaskSurface == nil ? 0 : Double(max(2,fontPixels*0.2)),
                "capacityExpanded":box.width > base.width+0.01 || box.height > base.height+0.01,
                "balloonVerticalShiftPixels":Double(centeredPixels),
                "balloonCenterAuthority":centeringAuthority,
                "potentialPeerFrameCollisions":collisions,
                "collisionAuthority":"proposal rectangle proxy; final retained effect-alpha admission required",
                "requestedCertifiedLayout":requestedLock,"itemCapacityFallbackUsed":requestedLock && !locked,
                "sourceColorAuthority":item.colorAuthority,
                "certifiedLayoutConsumed":locked,"certifiedGeometryDeviationPixels":locked ? certificationDeviation : -1,
                "actualCoreTextLineStrings":actualLineTexts,
                "lineRangesUTF16":frame.ranges.map {[$0.location,$0.length]},
                "shortSoftTails":NativeRenderWrapQuality.shortTailOffsets(item.text,ranges:frame.ranges).count,
                "softWordCuts":NativeRenderWrapQuality.wordCutOffsets(item.text,ranges:frame.ranges).count,
                "oneCharacterRowsProxy":actualLineTexts.filter {$0.count == 1}.count,
                "retainedFillBoundsOutput":ink.isNull ? [] : [paintedCrop.minX+ink.minX,paintedCrop.minY+ink.minY,ink.width,ink.height],
                "interiorPaddingOutputPixels":Double(NativeTextSpacing.padding(fontSize:fontPixels)),
                "baselineAuthority":"native CoreText runs; visible-ink block alignment",
                "lineAuthority":isVertical ? "CoreText vertical frame; observed retained fill" : "shared kinsoku rows and measured glyph baselines; no final rebreaking"])
            if let diagnostic=frame.contourWordDiagnostics {
                audit[audit.count-1]["interiorContourWordWrap"]=true
                audit[audit.count-1]["interiorContourWordDiagnostics"]=diagnostic
            }
            if NativeBalloonReadabilityReflow.interiorWordsEnabled {
                // Capture the exact chosen outer layout width before any mask
                // refit; neither the drawing box nor the raster is its proxy.
                audit[audit.count-1]["interiorWordOuterLayoutWidthOutputPixels"]=Double(retainedOuterLayoutWidth)
                audit[audit.count-1]["interiorWordRetainedFace"]=CTFontCopyPostScriptName(retainedFace) as String
                audit[audit.count-1]["interiorWordRetainedFontOutputPixels"]=Double(fontPixels)
            }
            audit[audit.count-1].merge(NativeSourceFontAudit.record(raw:options[item.id],
                requestedDisplay:Double(item.fontSize),displayed:Double(fontPixels/sx))) { _, new in new }
            if sourceRotationApplied,let angle=primitive.textPlacementGuide?.sourceRotationRadians {
                audit[audit.count-1]["sourceObservedRotationRadians"]=angle
                audit[audit.count-1]["rotationBeforeFinalAlphaAdmission"]=true
                audit[audit.count-1]["sourceRotationAnchorNormalized"]=primitive.textPlacementGuide?.rotationAnchorNormalized as Any? ?? NSNull()
                audit[audit.count-1]["sourceRotationObservation"]=options[item.id]?["sourceRotationObservation"] ?? ["authority":"explicit-placement-guide-radians"]
                audit[audit.count-1]["frameOutputTopLeft"]=[primitive.frame.minX,primitive.frame.minY,primitive.frame.width,primitive.frame.height]
                if let bounds=rotatedFillBounds {audit[audit.count-1]["retainedFillBoundsOutput"]=[bounds.minX,bounds.minY,bounds.width,bounds.height]}
            }
            if let surfaceCapacity {
                audit[audit.count-1]["originalClosedSurfaceSlotOutputPixels"]=[surfaceCapacity.minX,surfaceCapacity.minY,surfaceCapacity.width,surfaceCapacity.height]
                audit[audit.count-1]["retainedFillAndStrokeInsideOriginalSurface"]=true
                audit[audit.count-1]["surfaceAuthority"]="original uniform rectangular source surface + removal ownership, not RF/semantic balloon truth"
            }
            } catch NativeFinalTextPaintAdmission.Failure.noSafePlacement(let cause) where collectFixedFontFailures {
                failedShapeOwners.formUnion(cause.split(separator:",").map(String.init))
            } catch Failure.incompleteText(let owner) where collectFixedFontFailures {
                failedShapeOwners.insert(owner)
            }
        }
        try Task.checkCancellation()
        if !failedShapeOwners.isEmpty {
            throw FixedFontPreparedFailure(cause:failedShapeOwners.sorted().joined(separator:","),
                prepared:.init(audit:audit,primitives:primitives))
        }
        return (audit,primitives)
    }

    private static func renderAttempt(items: [Item], viewport: CGSize, restored: CGImage, allowShrink: Bool,
                                      contours: [String: NativeRawBalloonCapacity.Contour], options: [String:[String:Any]],
                                      excludedTailOwners:Set<String>, recordRefinement:(String)->Void,
                                      boundedInteriorWidth:CGFloat?=nil,retainedPitch:CGFloat?=nil,
                                      terminalExteriorContentWidth:CGFloat?=nil,terminalExteriorFont:CGFloat?=nil,
                                      outputWidthPlans:[String:NativeOwnerOutputWidthPlan]=[:],capturePreparedFailure:Bool=false) throws
        ->(layer:NativeAOTTranslationPageComposer.TextLayer,primitives:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive]) {
        let raw=try renderPrimitives(items:items,viewport:viewport,restored:restored,allowShrink:allowShrink,
            contours:contours,options:options,excludedTailOwners:excludedTailOwners,recordRefinement:recordRefinement,
            boundedInteriorWidth:boundedInteriorWidth,retainedPitch:retainedPitch,
            terminalExteriorContentWidth:terminalExteriorContentWidth,terminalExteriorFont:terminalExteriorFont,
            outputWidthPlans:outputWidthPlans,collectFixedFontFailures:capturePreparedFailure)
        var audit=raw.audit
        var primitives=raw.primitives
        let result:NativeAOTTranslationPageComposer.TextLayer
        var widthFallbackReceipt:[String:Any]?
        do {
            NativeFixedFontRecovery.metrics?.initialPlacementCalls += 1
            result=try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(restored:restored,
                fills:primitives,expectedItems:items.count,textComplete:true)
        } catch NativeFinalTextPaintAdmission.Failure.noSafePlacement(let initialCause) {
            let initialFailure=NativeFinalTextPaintAdmission.Failure.noSafePlacement(initialCause)
            let canRetry=NativeSimpleFinalWidthFallback.enabled && boundedInteriorWidth == nil && retainedPitch == nil &&
                terminalExteriorContentWidth == nil && terminalExteriorFont == nil && outputWidthPlans.isEmpty &&
                NativeEffectSafePitch.current == nil && primitives.count == items.count && audit.count == items.count &&
                primitives.map(\.ownerID) == items.map {Optional($0.id)}
            guard canRetry else {
                if capturePreparedFailure {
                    throw FixedFontPreparedFailure(cause:initialCause,prepared:.init(audit:audit,primitives:primitives))
                }
                throw initialFailure
            }
            let initialAudit=audit,initialPrimitives=primitives
            let eligible=Set(audit.compactMap { row -> String? in
                row["simpleWidthIngressApplied"] as? Bool == true ? row["id"] as? String:nil
            })
            let scale=CGFloat(restored.width)/viewport.width
            do {
                let recovered=try NativeSimpleFinalWidthFallback.recover(initialFailure:initialFailure,
                    owners:items.map(\.id),eligible:eligible,cause:{error in
                        guard case NativeFinalTextPaintAdmission.Failure.noSafePlacement(let owner)=error else{return nil}
                        return owner
                    },replace:{owner in
                        guard let index=items.firstIndex(where:{$0.id==owner}),
                              let pitch=(initialAudit[index]["retainedLinePitchOutputPixels"]as?NSNumber)?.doubleValue,
                              pitch.isFinite,pitch>0 else{return false}
                        let item=items[index],font=initialPrimitives[index].fontOutputPixels
                        let preferred=try NativeSimpleFinalWidthFallback.callerWidth(frameOutputWidth:item.frame.width*scale,
                            slotNormalized:options[owner]?["balloonLayoutRectNormalized"]as?[Double],
                            pageOutputWidth:CGFloat(restored.width))
                        let replacement=try renderPrimitives(items:[item],viewport:viewport,restored:restored,allowShrink:false,
                            contours:contours,options:options,excludedTailOwners:excludedTailOwners,recordRefinement:recordRefinement,
                            retainedPitch:CGFloat(pitch),preferredOuterWidths:[owner:preferred.pixels],retainedFontPixels:[owner:font],
                            pitchFamilyItems:items)
                        guard replacement.primitives.count==1,replacement.audit.count==1,
                              replacement.audit[0]["simpleWidthIngressApplied"]as?Bool==true,
                              replacement.primitives[0].ownerID==owner,replacement.primitives[0].fontOutputPixels==font,
                              replacement.audit[0]["sourceUTF16"]as?Int==initialAudit[index]["sourceUTF16"]as?Int,
                              replacement.audit[0]["visibleUTF16"]as?Int==initialAudit[index]["visibleUTF16"]as?Int else{return false}
                        var row=replacement.audit[0]
                        row["simpleFinalWidthFallbackAuthority"]=preferred.authority
                        row["simpleFinalWidthFallbackPreferredOutputPixels"]=Double(preferred.pixels)
                        row["simpleFinalWidthFallbackFontOutputPixels"]=Double(font)
                        audit[index]=row;primitives[index]=replacement.primitives[0]
                        return true
                    },attempt:{
                        try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(restored:restored,
                            fills:primitives,expectedItems:items.count,textComplete:true)
                    })
                result=recovered.value;widthFallbackReceipt=recovered.receipt.audit
            } catch let failure as NativeSimpleFinalWidthFallback.Failure {
                for index in audit.indices {audit[index]["simpleFinalWidthFallback"]=failure.receipt.audit}
                if capturePreparedFailure,case NativeFinalTextPaintAdmission.Failure.noSafePlacement(let cause)=failure.cause {
                    throw FixedFontPreparedFailure(cause:cause,prepared:.init(audit:audit,primitives:primitives))
                }
                throw failure.cause
            }
        }
        var metadata = result.audit
        if let widthFallbackReceipt {metadata["simpleFinalWidthFallback"]=widthFallbackReceipt}
        if let decisions=result.audit["endpointDecisions"] as? [[String:Any]] {
            for i in audit.indices where i<decisions.count {
                audit[i]["finalStrokeDecision"]=decisions[i]
                audit[i]["finalDisplayFill"]=decisions[i]["displayFillRGB"]
                if primitives[i].sourceContourOnly {
                    audit[i]["finalDisplayStroke"] = primitives[i].sourceStyle?.bands.first?.rgb
                    audit[i]["sourceContourOnly"] = true
                } else { audit[i]["finalDisplayStroke"]=decisions[i]["finalEndpoint"].map {[$0,$0,$0]} }
            }
        }
        metadata["rawNativeItems"] = audit
        metadata["legacyPrepareTextBoxesInvoked"] = false
        metadata["opaquePanelsPainted"] = false
        metadata["forcedCapacityFallback"] = allowShrink
        metadata["baselineLimitations"] = "bounded source-near placement; no independent visual/semantic quality claim"
        return (NativeAOTTranslationPageComposer.TextLayer(image:result.image,expectedItems:result.expectedItems,
            paintedItems:result.paintedItems,complete:result.complete,audit:metadata),primitives)
    }
}
