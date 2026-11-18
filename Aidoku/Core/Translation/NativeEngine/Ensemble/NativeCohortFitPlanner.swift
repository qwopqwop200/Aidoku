import Foundation
import CoreGraphics
import CoreFoundation

/// Plans NEW display requests after a demonstrated complete-page native failure.
/// Source packets, authenticated render options, source estimates and masks are immutable.
/// All successful proposals still traverse the ordinary final native painter.
enum NativeCohortFitPlanner {
    typealias Item = NativeAOTRawTextPainter.Item
    typealias Layer = NativeAOTTranslationPageComposer.TextLayer
    enum Failure: Error {
        case invalidPolicy, invalidInventory
        case unboundCompletedPaint, boundedPlanningUnresolved
    }
    struct Policy {
        let minimumOutputFontPixels: Double
        let fixedOwners: Set<String>
        let authority: String
        var refineRecoveredSoftCuts = false
        static let onFailure = Policy(minimumOutputFontPixels: 12, fixedOwners: [],
            authority: "main-on-failure-consistent-families-v1", refineRecoveredSoftCuts: true)
    }
    static let scales: [Double] = [1, 0.95, 0.9, 0.85, 0.8, 0.75, 0.7, 0.65]
    struct Family {
        let owners: [String] // Includes declared held/absent members; never split.
        let indices: [Int]
        let lockReasons: [String]
        var locked: Bool { !lockReasons.isEmpty }
    }
    struct Result { let layer: Layer; let receipt: [String: Any] }

    private static func bool(_ row: [String: Any], _ key: String, nullableInput: Bool = false) throws -> Bool? {
        guard let value = row[key] else { return nil }
        if nullableInput, value is NSNull { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw Failure.invalidPolicy
        }
        return n.boolValue
    }
    private static func number(_ value: Any?) throws -> Double {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite else { throw Failure.invalidPolicy }
        return n.doubleValue
    }
    private static func inventory(_ rows: [[String: Any]]) throws -> [String: [String: Any]] {
        guard rows.count <= 4096 else { throw Failure.invalidInventory }
        var result: [String: [String: Any]] = [:]
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 1024,
                  result[id] == nil else { throw Failure.invalidInventory }
            for key in ["keptLettering", "sourceTextOnly", "ensembleLockLayout", "renderPreserveRequestedFontSize", "noShrink", "allowShrink"] {
                _ = try bool(row, key, nullableInput: true)
            }
            // Optional source metadata may encode absence as JSON null/empty.
            // Validate supplied nonempty values without rewriting the source packet.
            for key in ["typographyGroupID", "sourceTypographyGroup"] {
                _ = try optionalGroup(row, key)
            }
            result[id] = row
        }
        return result
    }

    private static func optionalGroup(_ row: [String: Any], _ key: String) throws -> String? {
        guard let value = row[key], !(value is NSNull) else { return nil }
        guard let group = value as? String, group.utf8.count <= 256 else { throw Failure.invalidInventory }
        if group.isEmpty { return nil } // NativeTypographyConsistency treats empty as no group.
        guard !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidInventory }
        return group
    }

    /// Explicit host page opt-in. This parser runs AFTER saved-corpus authentication;
    /// nothing here authorizes changing a saved source header or request packet.
    static func explicitHostPolicy(_ value: Any, items: [Item], declaredRaw: [[String: Any]]) throws -> Policy {
        let declared = try inventory(declaredRaw)
        let keys: Set<String> = ["version", "authority", "mayAdjustRequestedDisplayFont",
            "completeDeclaredOwnerInventory", "declaredOwnerIDs", "scales", "minimumOutputFontPixels",
            "originalRequestedFonts", "fixedOwners"]
        guard let p = value as? [String: Any], keys.isSubset(of: Set(p.keys)),
              Set(p.keys).isSubset(of: keys.union(["refineRecoveredSoftCuts"])),
              try number(p["version"]) == 1,
              p["authority"] as? String == "explicit-caller-cohort-fit-planning-v1",
              try bool(p, "mayAdjustRequestedDisplayFont") == true,
              try bool(p, "completeDeclaredOwnerInventory") == true,
              let ids = p["declaredOwnerIDs"] as? [String], Set(ids).count == ids.count,
              Set(ids) == Set(declared.keys),
              let rawScales = p["scales"] as? [Any], rawScales.count == scales.count,
              try rawScales.map({ try number($0) }) == scales,
              let binding = p["originalRequestedFonts"] as? [String: Any],
              Set(items.map(\.id)).count == items.count, Set(binding.keys) == Set(items.map(\.id)),
              let fixed = p["fixedOwners"] as? [String], Set(fixed).count == fixed.count,
              Set(fixed).isSubset(of: Set(declared.keys)) else { throw Failure.invalidPolicy }
        for item in items {
            guard try number(binding[item.id]) == Double(item.fontSize) else { throw Failure.invalidPolicy }
        }
        let minimum = try number(p["minimumOutputFontPixels"])
        guard minimum >= 12 else { throw Failure.invalidPolicy }
        return Policy(minimumOutputFontPixels: minimum, fixedOwners: Set(fixed),
            authority: "explicit-caller-cohort-fit-planning-v1",
            refineRecoveredSoftCuts: try bool(p, "refineRecoveredSoftCuts") ?? false)
    }

    static func requireCompletePeerContext(_ supplied: Any?) throws {
        guard let supplied else { return } // native Host default is true
        guard let n = supplied as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue else {
            throw Failure.invalidPolicy
        }
    }

    /// Use caller declarations BEFORE renderer preserve flags are injected.
    /// Renderer membership may add native typography relations, but cannot erase
    /// caller native typography relations/locks. Old/current native relations form
    /// a conservative union. sourceTypographyGroup and sourceFontFitGroup* are
    /// upstream linkage, NEVER native equal-font typography authority.
    static func families(items: [Item], declaredRaw: [[String: Any]], membershipRaw: [[String: Any]],
                         policy: Policy) throws -> [Family] {
        let declared = try inventory(declaredRaw), membership = try inventory(membershipRaw)
        let ids = items.map(\.id), rendered = Set(ids)
        guard ids.count <= 256, rendered.count == ids.count,
              Set(membership.keys).isSubset(of: Set(declared.keys)),
              rendered.isSubset(of: Set(membership.keys)),
              policy.fixedOwners.isSubset(of: Set(declared.keys)),
              policy.minimumOutputFontPixels.isFinite, policy.minimumOutputFontPixels >= 12 else {
            throw Failure.invalidInventory
        }
        for item in items {
            guard item.fontSize.isFinite, item.fontSize > 0, item.lineHeight.isFinite, item.lineHeight > 0,
                  item.frame.minX.isFinite, item.frame.minY.isFinite, item.frame.maxX.isFinite,
                  item.frame.maxY.isFinite, item.frame.width > 0, item.frame.height > 0,
                  membership[item.id]?["text"] as? String == item.text, !item.text.isEmpty else {
                throw Failure.invalidInventory
            }
        }
        var adjacency = Dictionary(uniqueKeysWithValues: declared.keys.map { ($0, Set<String>()) })
        var groups: [String: Set<String>] = [:]
        for rows in [declaredRaw, membershipRaw] {
            for row in rows {
                guard let id = row["id"] as? String else { throw Failure.invalidInventory }
                if let group = try optionalGroup(row, "typographyGroupID") {
                    groups[group, default: []].insert(id)
                }
            }
        }
        // A star per group avoids quadratic graph construction for held inventories.
        for members in groups.values {
            guard let first = members.sorted().first else { continue }
            for id in members { adjacency[first, default: []].insert(id); adjacency[id, default: []].insert(first) }
        }
        let itemIndex = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        var visited = Set<String>(), result: [Family] = []
        for seed in declared.keys.sorted() where !visited.contains(seed) {
            var stack = [seed], owners = Set<String>()
            while let id = stack.popLast() {
                guard visited.insert(id).inserted else { continue }
                owners.insert(id)
                stack.append(contentsOf: adjacency[id, default: []].filter { !visited.contains($0) })
            }
            let indices = owners.compactMap { itemIndex[$0] }.sorted()
            guard !indices.isEmpty else { continue }
            var reasons = Set<String>()
            if !owners.isSubset(of: rendered) { reasons.insert("incomplete-rendered-family") }
            for id in owners {
                if policy.fixedOwners.contains(id) { reasons.insert("caller-fixed-owner") }
                for row in [declared[id], membership[id]].compactMap({ $0 }) {
                    if try bool(row, "keptLettering", nullableInput: true) == true || bool(row, "sourceTextOnly", nullableInput: true) == true {
                        reasons.insert("held-member")
                    }
                }
                // ONLY original caller flags lock. membershipRaw may contain injected preserve=true.
                guard let row = declared[id] else { throw Failure.invalidInventory }
                if try bool(row, "renderPreserveRequestedFontSize", nullableInput: true) == true { reasons.insert("caller-preserve") }
                if try bool(row, "noShrink", nullableInput: true) == true || bool(row, "allowShrink", nullableInput: true) == false { reasons.insert("caller-no-shrink") }
                if try bool(row, "ensembleLockLayout", nullableInput: true) == true { reasons.insert("caller-fixed-layout") }
            }
            let fonts = indices.map { items[$0].fontSize }
            if let first = fonts.first, !fonts.allSatisfy({ abs($0 - first) < 1e-7 }) {
                // Never normalize incompatible typography under this planner.
                reasons.insert("incompatible-requested-fonts")
            }
            result.append(Family(owners: owners.sorted(), indices: indices, lockReasons: reasons.sorted()))
        }
        guard result.flatMap(\.indices).sorted() == Array(items.indices) else { throw Failure.invalidInventory }
        return result
    }

    /// A whole-page contract/style failure must not become a singleton-owner success.
    static func exhaustedCapacityFallback<T>(after error: Error, perform: () throws -> T) throws -> T {
        guard case Failure.boundedPlanningUnresolved = error else { throw error }
        try Task.checkCancellation()
        return try perform()
    }

    static func retryable(_ error: Error) -> Bool {
        if error is NativeAOTRawTextPainter.FixedFontRecoveryFailure { return true }
        if case NativeFinalTextPaintAdmission.Failure.noSafePlacement = error { return true }
        return false
    }

    // MARK: Below-minimum-scale terminal fallback
    //
    // Engages ONLY after the complete planner ladder (`scales`, down to 0.65) AND
    // the individual-owner fallback have both failed with a capacity error, i.e.
    // only where the page is otherwise refused. Pages that succeed today never
    // reach it. Only the families named by the capacity failure step down; every
    // other family keeps exactly its 0.65-attempt request. The ordinary native
    // painter still enforces every peer, domain, mask, risk and raster rule.
    static let belowMinimumScales: [Double] = [0.6, 0.55, 0.5, 0.45, 0.4, 0.35, 0.3, 0.25, 0.2]

    /// Owner IDs named by a capacity failure ("3" or "3,5"); empty for any other error.
    static func capacityCauseOwners(_ error: Error) -> Set<String> {
        let text: String
        if let failure = error as? NativeAOTRawTextPainter.FixedFontRecoveryFailure {
            text = failure.cause
        } else if case NativeFinalTextPaintAdmission.Failure.noSafePlacement(let owners) = error {
            text = owners
        } else { return [] }
        return Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Per-family scale for one below-minimum step. Cause families step to `scale`,
    /// clamped so no member falls under the absolute output-pixel floor and never
    /// above the 0.65 request; other families repeat the final ladder rule exactly.
    static func belowMinimumFamilyScales(items: [Item], families: [Family], stepped: Set<Int>, scale: Double,
                                         minimumOutputFontPixels: Double, outputScale: CGFloat) -> [Double] {
        let base = scales.last ?? 1
        return families.enumerated().map { index, family in
            guard !family.locked, let smallest = family.indices.map({ Double(items[$0].fontSize * outputScale) }).min(),
                  smallest > 0 else { return 1 }
            let belowFloorAtBase = smallest * base < minimumOutputFontPixels
            guard stepped.contains(index) else { return belowFloorAtBase ? 1 : base }
            guard !belowFloorAtBase else { return 1 }
            return min(base, max(scale, minimumOutputFontPixels / smallest))
        }
    }

    /// Returns nil when not applicable or when every step was rejected; the caller
    /// then rethrows its original terminal failure unchanged.
    static func belowMinimumScaleFallback(items: [Item], authenticatedOptions: [[String: Any]], declaredRaw: [[String: Any]],
                                          membershipRaw: [[String: Any]], policy: Policy, outputScale: CGFloat,
                                          after terminal: Error, record: (([String: Any]) -> Void)? = nil,
                                          render: ([Item]) throws -> Layer) throws -> Result? {
        guard retryable(terminal), !capacityCauseOwners(terminal).isEmpty, !items.isEmpty, items.count <= 256,
              outputScale.isFinite, outputScale > 0,
              policy.minimumOutputFontPixels.isFinite, policy.minimumOutputFontPixels >= 12,
              let options = try? inventory(authenticatedOptions),
              items.allSatisfy({ options[$0.id]?["text"] as? String == $0.text }),
              let families = try? self.families(items: items, declaredRaw: declaredRaw, membershipRaw: membershipRaw, policy: policy)
        else { return nil }
        return try NativeFinalTextPaintAdmission.withRetainedFootprintMemo { () throws -> Result? in
            var receipt: [String: Any] = ["status": "below-minimum-scale-fallback-started",
                "fallbackScales": belowMinimumScales, "minimumOutputFontPixels": policy.minimumOutputFontPixels,
                "outputScale": Double(outputScale), "initialTerminalFailure": String(reflecting: terminal)]
            var attempts: [[String: Any]] = []
            var stepped = Set<Int>(), previous: [Double]?, lastError: Error = terminal
            for scale in belowMinimumScales {
                try Task.checkCancellation()
                let causes = capacityCauseOwners(lastError)
                for (index, family) in families.enumerated() where !family.locked {
                    let named = family.indices.contains(where: { causes.contains(items[$0].id) })
                        || family.owners.contains(where: { causes.contains($0) })
                    if named { stepped.insert(index) }
                }
                guard !stepped.isEmpty else { break }
                let familyScales = belowMinimumFamilyScales(items: items, families: families, stepped: stepped, scale: scale,
                    minimumOutputFontPixels: policy.minimumOutputFontPixels, outputScale: outputScale)
                guard familyScales != previous else { break } // every cause family is at the pixel floor
                previous = familyScales
                var proposed = items, byOwner: [String: Double] = [:]
                for (family, familyScale) in zip(families, familyScales) {
                    for i in family.indices {
                        let old = items[i], factor = CGFloat(familyScale)
                        byOwner[old.id] = familyScale
                        proposed[i] = Item(id: old.id, text: old.text, frame: old.frame, fontSize: old.fontSize * factor,
                            lineHeight: old.lineHeight * factor, chosenFill: old.chosenFill, colorAuthority: old.colorAuthority)
                    }
                }
                let plannedFonts = Dictionary(uniqueKeysWithValues: proposed.map { ($0.id, Double($0.fontSize)) })
                let observed = Completions()
                let prior = NativeAOTTranslationPageComposer.completedPaintObserver
                let observer = NativeAOTTranslationPageComposer.CompletedPaintObserver { image, fills, audit in
                    prior?.observe(image, fills, audit)
                    observed.observe(image, fills, audit)
                }
                do {
                    let layer = try NativeAOTTranslationPageComposer.$completedPaintObserver.withValue(observer) {
                        try NativeAOTRawTextPainter.$failedRequestCohortPlanning.withValue(true) { try render(proposed) }
                    }
                    try validate(layer, proposed: proposed, options: authenticatedOptions, outputScale: outputScale, observed: observed)
                    attempts.append(["scale": scale, "status": "real-native-final-paint-bound", "familyScalesByOwner": byOwner])
                    receipt["status"] = "below-minimum-scale-fallback-native-admitted"
                    receipt["fallbackScale"] = scale
                    receipt["fallbackFamilyScalesByOwner"] = byOwner
                    receipt["fallbackSteppedOwners"] = stepped.flatMap { family in families[family].indices.map { items[$0].id } }.sorted()
                    receipt["plannedFonts"] = plannedFonts
                    receipt["attempts"] = attempts
                    record?(receipt)
                    return Result(layer: layer, receipt: receipt)
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    attempts.append(["scale": scale, "status": retryable(error) ? "native-rejected" : "noncapacity-rejection-no-retry",
                        "error": String(reflecting: error), "plannedFonts": plannedFonts])
                    guard retryable(error) else { break } // fail closed: caller rethrows the original failure
                    lastError = error
                }
            }
            receipt["status"] = "below-minimum-scale-fallback-exhausted"; receipt["attempts"] = attempts; record?(receipt)
            return nil
        }
    }

    struct RowQuality {
        let cuts: Int
        let isolatedRows: Int
        var audit: [String: Int] { ["softWordCuts": cuts, "isolatedSingletonRows": isolatedRows] }
    }
    static func trustedRecoveredMarker(_ layer: Layer) -> Bool {
        guard let ledger = layer.audit["recoveryDrawBudget"] as? [String: Any] else { return false }
        return (try? bool(ledger, "recoveryActive")) == true
        // NEVER use historical fixedFontRecovery.status as a trigger.
    }
    static func rowQuality(_ layer: Layer, items: [Item]) throws -> [String: RowQuality] {
        guard Set(items.map(\.id)).count == items.count,
              let rows = layer.audit["rawNativeItems"] as? [[String: Any]], rows.count == items.count else {
            throw Failure.unboundCompletedPaint
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var result: [String: RowQuality] = [:]
        for row in rows {
            guard let id = row["id"] as? String, let item = byID[id], result[id] == nil,
                  let ranges = row["lineRangesUTF16"] as? [[Int]], let strings = row["actualCoreTextLineStrings"] as? [String],
                  let reported = row["softWordCuts"] as? Int, reported >= 0 else { throw Failure.unboundCompletedPaint }
            // Reuse existing native segmentation/word accounting; no new tokenizer.
            let q = try NativeAOTRawTextPainter.capacitySegmentation(text: item.text, ranges: ranges, lines: strings)
            guard q.cuts == reported else { throw Failure.unboundCompletedPaint }
            result[id] = RowQuality(cuts: q.cuts, isolatedRows: q.isolatedSingletonRows)
        }
        return result
    }
    static func strictlyImproves(_ after: [String: RowQuality], _ before: [String: RowQuality]) -> Bool {
        guard Set(after.keys) == Set(before.keys) else { return false }
        var improved = false
        for (id, old) in before {
            guard let new = after[id], new.cuts <= old.cuts, new.isolatedRows <= old.isolatedRows else { return false }
            if new.cuts < old.cuts { improved = true }
        }
        return improved // remaining small cuts are NOT a hard rejection
    }

    /// Tiny render-local observation: no glyph PNG export, no retained candidate
    /// planes. Weak identity avoids retaining every full-page counterfactual image.
    /// Native Composer invokes this ONLY after real geometry/style/raster checks.
    private final class Completion {
        weak var image: CGImage?
        let ids: [String]
        let fonts: [CGFloat]
        let contours: [Bool]
        let audit: [[String: Any]]
        let fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive]
        init(_ image: CGImage, _ fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive], _ audit: [[String: Any]],retainFills:Bool=true) {
            self.image = image; self.ids = fills.compactMap(\.ownerID)
            self.fonts = fills.map(\.fontOutputPixels); self.fills=retainFills ? fills:[]; self.contours = fills.map(\.sourceContourOnly); self.audit = audit
        }
    }
    private final class Completions {
        var live: [Completion] = []
        var exceeded = false
        func observe(_ image: CGImage, _ fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive], _ audit: [[String: Any]]) {
            live.removeAll { $0.image == nil }
            guard live.count < 128 else { exceeded = true; return }
            let pixels=live.reduce(0){$0+$1.fills.reduce(0){$0+$1.image.width*$1.image.height}}
            let retain=NativeSourceObstructionRecovery.sourceContext != nil && pixels+fills.reduce(0,{$0+$1.image.width*$1.image.height})<=8_000_000
            live.append(Completion(image, fills, audit,retainFills:retain))
        }
    }
    private static func validate(_ layer: Layer, proposed: [Item], options: [[String: Any]],
                                 outputScale: CGFloat, observed: Completions) throws {
        let expected = Set(proposed.map(\.id))
        guard !observed.exceeded, layer.complete, layer.expectedItems == proposed.count,
              layer.paintedItems == proposed.count,
              let completion = observed.live.last(where: { $0.image === layer.image }),
              completion.ids.count == proposed.count, completion.fonts.count == proposed.count,
              completion.contours.count == proposed.count, Set(completion.ids) == expected,
              let rows = layer.audit["rawNativeItems"] as? [[String: Any]], rows.count == proposed.count,
              let admissions = layer.audit["finalPaintAdmission"] as? [[String: Any]],
              NSArray(array: admissions).isEqual(to: completion.audit),
              layer.audit["finalPaintBoundsChecked"] as? Bool == true,
              layer.audit["finalCompositeAlphaVerified"] as? Bool == true else { throw Failure.unboundCompletedPaint }
        var byID: [String: [String: Any]] = [:]
        for row in rows {
            guard let id = row["id"] as? String, expected.contains(id), byID[id] == nil else { throw Failure.unboundCompletedPaint }
            byID[id] = row
        }
        let contours = try NativeOperationalAppearance.withChosenFills(proposed.map { ($0.id,$0.chosenFill) }) {
            Set(NativeOperationalAppearance.annotateContourPolicies(options)
                .filter { NativeOperationalAppearance.sourceContourOnly($0) }.compactMap { $0["id"] as? String }).intersection(expected)
        }
        let actualContours = Set(zip(completion.ids, completion.contours).filter { $0.1 }.map { $0.0 })
        guard contours == actualContours else { throw Failure.unboundCompletedPaint }
        let fonts = Dictionary(uniqueKeysWithValues: zip(completion.ids, completion.fonts))
        for item in proposed {
            guard let row = byID[item.id], let font = row["fontSize"] as? Double,
                  let paintedFont = fonts[item.id], abs(paintedFont - item.fontSize * outputScale) < 1e-6,
                  abs(font - Double(item.fontSize)) < 1e-6,
                  row["fontShrunkForCapacity"] as? Bool == false,
                  row["sourceUTF16"] as? Int == item.text.utf16.count,
                  row["visibleUTF16"] as? Int == item.text.utf16.count else { throw Failure.unboundCompletedPaint }
        }
        // The real native verifier enforces policy/domain/peers/risk and style;
        // this helper binds that actual completion, not a JSON physical certificate.
    }

    static func run(items: [Item], authenticatedOptions: [[String: Any]], declaredRaw: [[String: Any]],
                    membershipRaw: [[String: Any]], policy: Policy, outputScale: CGFloat,
                    record: (([String: Any]) -> Void)? = nil,
                    render: ([Item]) throws -> Layer) throws -> Result {
        try NativeFinalTextPaintAdmission.withRetainedFootprintMemo {
            func annotated(_ receipt: [String: Any]) -> [String: Any] {
                guard let memo = NativeFinalTextPaintAdmission.retainedFootprintMemo else { return receipt }
                var result = receipt
                result["retainedFootprintMemo"] = memo.audit
                return result
            }
            let forwardingRecord: (([String: Any]) -> Void)? = record.map { callback in
                { receipt in callback(annotated(receipt)) }
            }
            let result = try runWithFootprintMemo(items: items, authenticatedOptions: authenticatedOptions,
                declaredRaw: declaredRaw, membershipRaw: membershipRaw, policy: policy,
                outputScale: outputScale, record: forwardingRecord, render: render)
            return Result(layer: result.layer, receipt: annotated(result.receipt))
        }
    }

    private static func runWithFootprintMemo(items: [Item], authenticatedOptions: [[String: Any]], declaredRaw: [[String: Any]],
                    membershipRaw: [[String: Any]], policy: Policy, outputScale: CGFloat,
                    record: (([String: Any]) -> Void)?, render: ([Item]) throws -> Layer) throws -> Result {
        guard outputScale.isFinite, outputScale > 0,
              policy.minimumOutputFontPixels.isFinite, policy.minimumOutputFontPixels >= 12 else { throw Failure.invalidPolicy }
        let options = try inventory(authenticatedOptions)
        guard Set(items.map(\.id)).count == items.count,
              Set(items.map(\.id)).isSubset(of: Set(options.keys)) else { throw Failure.invalidInventory }
        var receipt: [String: Any] = ["version": 1, "authority": policy.authority,
            "allowedScales": scales, "minimumOutputFontPixels": policy.minimumOutputFontPixels,
            "outputScale": Double(outputScale), "painterAllowShrink": false, "familiesEvaluated": false,
            "originalRequestedFonts": Dictionary(uniqueKeysWithValues: items.map { ($0.id, Double($0.fontSize)) }),
            "originalRequestedLineHeights": Dictionary(uniqueKeysWithValues: items.map { ($0.id, Double($0.lineHeight)) }),
            "originalRequestFrames": Dictionary(uniqueKeysWithValues: items.map { ($0.id,
                [Double($0.frame.minX), Double($0.frame.minY), Double($0.frame.width), Double($0.frame.height)]) }),
            "originalSourceReferences": declaredRaw.map { row -> [String: Any] in
                var reference: [String: Any] = ["id": row["id"] ?? NSNull()]
                for key in ["fontSize", "sourceFontSize", "sourceRequestedDisplayFontSize", "fontReference"] {
                    reference[key] = row[key] ?? NSNull()
                }
                return reference
            },
            "sourcePacketsModified": false, "physicalContainmentCertified": false]
        var attempts: [[String: Any]] = []
        var recoveredIncumbent: Layer?
        var recoveredQuality: [String: RowQuality]?
        var originalObservation: Completions?
        func keep(_ layer: Layer, _ status: String) -> Result {
            receipt["status"] = status; receipt["attempts"] = attempts; receipt["selectedScale"] = 1.0
            receipt["selectedOriginalRequest"] = true; record?(receipt)
            return Result(layer: layer, receipt: receipt)
        }
        func paint(_ proposed: [Item], validatePlanned: Bool) throws -> Layer {
            let observed = Completions()
            let prior = NativeAOTTranslationPageComposer.completedPaintObserver
            let observer = NativeAOTTranslationPageComposer.CompletedPaintObserver { image, fills, audit in
                prior?.observe(image, fills, audit)
                observed.observe(image, fills, audit)
            }
            let layer = try NativeAOTTranslationPageComposer.$completedPaintObserver.withValue(observer) {
                try NativeAOTRawTextPainter.$failedRequestCohortPlanning.withValue(validatePlanned) {
                    try render(proposed)
                }
            }
            if validatePlanned { try validate(layer, proposed: proposed, options: authenticatedOptions, outputScale: outputScale, observed: observed) }
            originalObservation = observed
            return layer
        }
        do {
            let original: Layer
            if policy.refineRecoveredSoftCuts || NativeSourceObstructionRecovery.sourceContext != nil {original=try paint(items,validatePlanned:false)}
            else {original=try render(items)}
            attempts = [["scale": 1.0, "status": "native-success"]]
            if let completion=originalObservation?.live.last(where:{$0.image === original.image}),
               let source=NativeSourceObstructionRecovery.sourceContext {
                let fs=try? self.families(items:items,declaredRaw:declaredRaw,membershipRaw:membershipRaw,policy:policy)
                if let fs {
                    receipt["familiesEvaluated"] = true
                    receipt["families"] = fs.map { ["owners": $0.owners, "renderedOwners": $0.indices.map { items[$0].id },
                        "locked": $0.locked, "lockReasons": $0.lockReasons] as [String: Any] }
                }
                if let fs,let improved=try NativeSourceObstructionRecovery.refine(incumbent:original,fills:completion.fills,
                    items:items,families:fs,minimumFont:policy.minimumOutputFontPixels,outputScale:outputScale,source:source,
                    page: CGRect(x:0,y:0,width:original.image.width,height:original.image.height),
                    render:{try paint($0,validatePlanned:true)},completed:{image in
                        originalObservation?.live.last(where:{$0.image === image})?.fills
                    }) {
                    receipt["status"]="native-success-with-optional-source-obstruction-quality"
                    receipt["sourcePacketsModified"]=false
                    if let quality=improved.audit["sourceObstructionRecovery"]as?[String:Any],
                       quality["status"]as?String=="source-obstruction-recovered" {
                        receipt["qualityPlanScope"]="complete unlocked families intersecting material owners; unrelated families retain original requests"
                        receipt["affectedMaterialOwners"]=quality["materialOwners"]
                        let affected=Set(quality["affectedFamilyOwners"] as? [String] ?? [])
                        let selectedScale=quality["selectedScale"] as? Double ?? 1.0
                        receipt["families"] = fs.map { family in
                            ["owners":family.owners,"renderedOwners":family.indices.map {items[$0].id},
                             "locked":family.locked,"lockReasons":family.lockReasons,
                             "selectedScale":family.owners.contains(where:{affected.contains($0)}) ? selectedScale : 1.0,
                             "qualityAffected":family.owners.contains(where:{affected.contains($0)})] as [String:Any]
                        }
                        receipt["plannedFonts"]=quality["selectedFonts"]
                        receipt["plannedLineHeights"]=quality["selectedLineHeights"]
                        receipt["selectedScale"]=quality["selectedScale"]
                        receipt["selectedOriginalRequest"]=false
                        receipt["completionAuthority"]="actual final native completed paint; planned font/face/rows verified before source quality selection; no paint after proof"
                    } else {receipt["selectedScale"]=1.0;receipt["selectedOriginalRequest"]=true}
                    record?(receipt)
                    return Result(layer:improved,receipt:receipt)
                }
            }

            guard policy.refineRecoveredSoftCuts, trustedRecoveredMarker(original) else {
                return keep(original, "original-native-success-returned-exactly")
            }
            do {
                let quality = try rowQuality(original, items: items)
                guard quality.values.contains(where: { $0.cuts > 0 }) else {
                    return keep(original, "trusted-recovery-no-soft-cut-issue-returned-exactly")
                }
                guard let observed = originalObservation else { throw Failure.unboundCompletedPaint }
                try validate(original, proposed: items, options: authenticatedOptions, outputScale: outputScale, observed: observed)
                recoveredIncumbent = original; recoveredQuality = quality
                receipt["qualityIssue"] = ["scope": "trusted recoveryDrawBudget.recoveryActive only",
                    "owners": quality.mapValues(\.audit), "minorCutsAreHardFailure": false] as [String: Any]
                attempts = [["scale": 1.0, "status": "trusted-same-font-recovery-soft-cut-quality-issue"]]
                receipt["status"] = "optional-recovered-quality-planning"; receipt["attempts"] = attempts; record?(receipt)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                receipt["qualityInspectionError"] = String(reflecting: error)
                return keep(original, "valid-recovered-incumbent-retained-quality-inspection-unavailable")
            }
        } catch {
            try Task.checkCancellation()
            attempts.append(["scale": 1.0, "status": "actual-complete-page-native-failure", "error": String(reflecting: error)])
            receipt["status"] = retryable(error) ? "original-native-failed" : "original-noncapacity-failure-no-planning"
            receipt["attempts"] = attempts; record?(receipt)
            guard retryable(error) else { throw error }
        }
        // Planning bounds cannot exclude an otherwise successful original request.
        guard items.count <= 256 else {
            receipt["status"] = "planning-owner-budget-unavailable"; record?(receipt)
            if let incumbent = recoveredIncumbent { return keep(incumbent, "valid-recovered-incumbent-retained-planning-budget") }
            throw Failure.boundedPlanningUnresolved
        }
        let families: [Family]
        do {
            families = try self.families(items: items, declaredRaw: declaredRaw, membershipRaw: membershipRaw, policy: policy)
            let membership = try inventory(membershipRaw)
            guard Set(options.keys) == Set(membership.keys),
                  items.allSatisfy({ options[$0.id]?["text"] as? String == $0.text }) else { throw Failure.invalidInventory }
        } catch {
            receipt["status"] = "planning-declaration-rejected"; receipt["planningError"] = String(reflecting: error)
            if let incumbent = recoveredIncumbent { return keep(incumbent, "valid-recovered-incumbent-retained-planning-declaration-rejected") }
            record?(receipt); throw error
        }
        receipt["familiesEvaluated"] = true
        receipt["families"] = families.map { ["owners": $0.owners, "renderedOwners": $0.indices.map { items[$0].id },
            "locked": $0.locked, "lockReasons": $0.lockReasons] as [String: Any] }
        for scale in scales.dropFirst() {
            try Task.checkCancellation()
            var proposed = items, changed = false
            var floorRetainedFamilies:[[String]]=[]
            var familyScales:[String:Double]=[:]
            for family in families {
                // The readability floor belongs to a complete typography family,
                // not unrelated paragraphs elsewhere on the page. Keep every
                // member of a floor-limited family at its original request.
                let belowFloor=family.indices.contains {
                    items[$0].fontSize * CGFloat(scale) * outputScale < CGFloat(policy.minimumOutputFontPixels)
                }
                let familyScale=family.locked || belowFloor ? 1.0:scale
                for i in family.indices {familyScales[items[i].id]=familyScale}
                if !family.locked && belowFloor {floorRetainedFamilies.append(family.owners)}
                guard familyScale<1 else {continue}
                for i in family.indices {
                    let old = items[i], font = old.fontSize * CGFloat(familyScale)
                    proposed[i] = Item(id: old.id, text: old.text, frame: old.frame, fontSize: font,
                        lineHeight: old.lineHeight * CGFloat(familyScale), chosenFill: old.chosenFill, colorAuthority: old.colorAuthority)
                    changed = true
                }
            }
            receipt["candidateFamilyScalesByOwner"]=familyScales
            receipt["floorRetainedCompleteFamilies"]=floorRetainedFamilies
            guard changed else {
                attempts.append(["scale": scale, "status": floorRetainedFamilies.isEmpty ? "all-families-locked":"all-unlocked-families-at-output-font-floor"])
                continue // no per-owner clamping, font enlargement or partial family request
            }
            let started = Date()
            let plannedFonts = Dictionary(uniqueKeysWithValues: proposed.map { ($0.id, Double($0.fontSize)) })
            let plannedPitches = Dictionary(uniqueKeysWithValues: proposed.map { ($0.id, Double($0.lineHeight)) })
            do {
                let selected = try paint(proposed, validatePlanned: true)
                if let before = recoveredQuality {
                    let after = try rowQuality(selected, items: proposed)
                    receipt["lastCandidateQuality"] = after.mapValues(\.audit)
                    guard strictlyImproves(after, before) else {
                        attempts.append(["scale": scale, "status": "native-valid-no-strict-soft-cut-gain-incumbent-kept",
                            "quality": after.mapValues(\.audit), "plannedFonts": plannedFonts])
                        receipt["attempts"] = attempts; record?(receipt)
                        continue
                    }
                    receipt["selectedQuality"] = after.mapValues(\.audit)
                }
                attempts.append(["scale": scale, "status": "real-native-final-paint-bound", "seconds": Date().timeIntervalSince(started)])
                receipt["status"] = "planned-request-native-admitted-quality-unclaimed"
                receipt["attempts"] = attempts; receipt["selectedScale"] = scale
                receipt["plannedFonts"] = plannedFonts
                receipt["plannedLineHeights"] = plannedPitches
                receipt["completionAuthority"] = "native Composer after actual style, geometry, peer, domain and final raster verification; selected image identity bound"
                record?(receipt)
                return Result(layer: selected, receipt: receipt)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                attempts.append(["scale": scale, "status": retryable(error) ? "native-rejected" : "noncapacity-rejection-no-retry", "error": String(reflecting: error),
                    "seconds": Date().timeIntervalSince(started), "plannedFonts": plannedFonts, "plannedLineHeights": plannedPitches])
                receipt["status"] = "planning"; receipt["attempts"] = attempts; record?(receipt)
                // Binding/style/policy errors are NOT capacity failures. Fail closed.
                if !retryable(error), let incumbent = recoveredIncumbent {
                    return keep(incumbent, "valid-recovered-incumbent-retained-improvement-rejected")
                }
                guard retryable(error) else { throw error }
            }
        }
        if let incumbent = recoveredIncumbent { return keep(incumbent, "valid-recovered-incumbent-retained-no-admitted-quality-gain") }
        receipt["status"] = "bounded-planning-unresolved"; receipt["attempts"] = attempts; record?(receipt)
        throw Failure.boundedPlanningUnresolved
    }
}
