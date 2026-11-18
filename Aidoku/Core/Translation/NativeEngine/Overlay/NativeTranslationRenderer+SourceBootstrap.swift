import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension NativeTranslationRenderer {
    static func prepareTextBoxes(layout: NativeTranslationLayout, image: UIImage?, settings: IPhoneOverlaySettings,
                                 scale: CGFloat, renderBounds: CGRect?, composeSource: Bool, outputPixelSize: CGSize?,
                                 collectDiagnostics: Bool, capturePDF: Bool, pdfDeviceScale: CGFloat,
                                 recordStage: ((String) -> Void)?, auditCardObserver: AuditCardObserver? = nil) throws -> PreparedRender {
        let protectsPanels = true
        func run(_ policy: Bool, observer: AuditCardObserver?) throws -> PreparedRender {
            try prepareParagraphOrdinaryWorld(layout: layout, image: image, settings: settings,
                scale: scale, renderBounds: renderBounds, composeSource: composeSource, outputPixelSize: outputPixelSize,
                collectDiagnostics: collectDiagnostics, capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale,
                recordStage: nil, auditCardObserver: observer,
                paragraphGuardEnabled: policy, paragraphPanelSupport: policy && protectsPanels)
        }
        var events: [(AuditCardStage, Card)] = []
        let observer: AuditCardObserver? = auditCardObserver == nil ? nil : { events.append(($0, $1)) }
        let candidate = try run(true, observer: observer)
        let screen = try screenFinalParagraphWorld(candidate, protectsPanels: protectsPanels)
        let selected: PreparedRender
        if screen.passed {
            selected = candidate
        } else {
            // At most one independent legacy transaction; never recursively retry.
            // Each transaction retains its original source quotas. The aggregate
            // worst case is four ordinary source passes, not quota forgiveness.
            events.removeAll(keepingCapacity: true)
            selected = try run(false, observer: observer)
        }
        if let auditCardObserver { for (stage, card) in events { auditCardObserver(stage, card) } }
        var result = selected
        if collectDiagnostics {
            let checked = screen.audit["checkedIDs"] as? [String] ?? []
            let value: [String: Any] = ["paragraphFinalAdmission": [
                "candidateAccepted": screen.passed && !checked.isEmpty,
                "finalAlphaMeasured": screen.passed && !checked.isEmpty,
                "selected": screen.passed ? (checked.isEmpty ? "unchanged" : "guarded") : "completed-legacy-world",
                "audit": screen.audit, "maximumOrdinaryWorlds": 2, "maximumSourcePasses": 4,
                "legacyFallbackIsImprovement": false, "sourceQuotasPerTransactionUnchanged": true,
                "capturePDF": capturePDF,
                "inputBinding": ["imageSize": [Double(layout.imageSize.width), Double(layout.imageSize.height)],
                    "owners": layout.items.map { item -> [String: Any] in
                        ["id": item.id, "sourceBounds": item.sourceBounds,
                         "textUTF8SHA256": NativeWidthFinalArtifactAdmission.hash(Data((item.typesettingText ?? item.text).utf8))]
                    }]]]
            var diagnostics = try selected.diagnosticData.flatMap {
                try JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            diagnostics["paragraphFinalAdmission"] = value["paragraphFinalAdmission"]
            result = replacingDiagnosticData(selected, with:
                try JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]))
        }
        recordStage?("native.solidTextBoxes")
        return result
    }

    private static func screenFinalParagraphWorld(_ plan: PreparedRender, protectsPanels: Bool) throws
        -> (passed: Bool, audit: [String: Any]) {
        let initial = plan.cards.indices.filter {
            plan.cards[$0].harmonyRecord["paragraphInkSeparationAudit"] is [String: Any]
        }
        var selected = Set(initial)
        var audit: [String: Any] = ["initialIDs": initial.map { plan.cards[$0].item.id },
            "authority": "final retained Card dual-bitmap alpha; not serialized PDF or artwork GT",
            "maximumOwners": 64, "maximumAlphaPixels": 8_000_000, "serializedPDFMeasured": false]
        guard plan.cards.count <= 512 else { audit["reason"] = "owner-inventory-limit"; return (false, audit) }
        if selected.isEmpty { audit["reason"] = "no-guarded-stage-candidate"; return (true, audit) }
        let regions = plan.cards.map { card in card.sourcePlateRect.union(cardInkRect(card)) }
        // Include affected neighbors, not just the Card with the earlier shift.
        for _ in 0..<64 {
            try Task.checkCancellation()
            let next = Set(plan.cards.indices.filter { i in
                selected.contains(i) || selected.contains { j in valid(regions[i].intersection(regions[j])) }
            })
            guard next.count <= 64 else { audit["reason"] = "neighbor-inventory-limit"; return (false, audit) }
            if next == selected { break }
            selected = next
        }
        var budget = NativeSourceBootstrapBirth.Budget()
        var measured: [String: Any] = [:]
        for index in selected.sorted() {
            try Task.checkCancellation()
            let card = plan.cards[index]
            guard card.typography.fits else {
                audit["reason"] = "final-fit-debt"; audit["failedID"] = card.item.id
                audit["measured"] = measured; return (false, audit)
            }
            if protectsPanels {
                let scale = min(plan.pixels.width / plan.bounds.width, plan.pixels.height / plan.bounds.height)
                guard let later = paragraphIncompatibleLaterPanels(index: index, cards: plan.cards, outputScale: scale) else {
                    audit["reason"] = "final-backdrop-color-unavailable"; audit["failedID"] = card.item.id
                    return (false, audit)
                }
                let glyphs = card.typography.glyphBounds.map { $0.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y) }
                if later.contains(where: { other in glyphs.contains { valid($0.intersection(other.rect)) } }) {
                    audit["reason"] = "final-low-contrast-panel-support"; audit["failedID"] = card.item.id
                    return (false, audit)
                }
            }
            let result = try NativeSourceBootstrapBirth.admitAlpha(card: card,
                peers: plan.cards.indices.filter { $0 != index }.map { plan.cards[$0] },
                bounds: plan.bounds, sourceRect: plan.layout.sourceRect, pixels: plan.pixels,
                pdfScale: plan.pdfDeviceScale, budget: &budget)
            measured[card.item.id] = result.audit
            guard result.accepted else {
                audit["reason"] = result.reason; audit["failedID"] = card.item.id
                audit["alphaPixelsCharged"] = budget.charged; audit["measured"] = measured
                return (false, audit)
            }
        }
        audit["reason"] = "measured-final-peer-and-clip-zero"
        audit["checkedIDs"] = selected.sorted().map { plan.cards[$0].item.id }
        audit["alphaPixelsCharged"] = budget.charged; audit["measured"] = measured
        return (true, audit)
    }

    private static func prepareParagraphOrdinaryWorld(layout: NativeTranslationLayout, image: UIImage?, settings: IPhoneOverlaySettings,
                                 scale: CGFloat, renderBounds: CGRect?, composeSource: Bool, outputPixelSize: CGSize?,
                                 collectDiagnostics: Bool, capturePDF: Bool, pdfDeviceScale: CGFloat,
                                 recordStage: ((String) -> Void)?, auditCardObserver: AuditCardObserver?,
                                 paragraphGuardEnabled: Bool, paragraphPanelSupport: Bool) throws -> PreparedRender {
        let started = ProcessInfo.processInfo.systemUptime
        let sourceReuse=NativeBootstrapSourceReuse(ownerCount:layout.items.count)
        defer { sourceReuse.release() }
        var proposals: [String: NativeSourceBootstrapBirth.Proposal] = [:]
        var baseEvents: [(AuditCardStage,Card)] = [], trialEvents: [(AuditCardStage,Card)] = []
        let baseObserver: AuditCardObserver? = auditCardObserver == nil ? nil : { baseEvents.append(($0,$1)) }
        let trialObserver: AuditCardObserver? = auditCardObserver == nil ? nil : { trialEvents.append(($0,$1)) }
        let base = try prepareSourceTextBoxesPass(layout: layout, image: image, settings: settings,
            scale: scale, renderBounds: renderBounds, composeSource: composeSource, outputPixelSize: outputPixelSize,
            collectDiagnostics: collectDiagnostics, capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale,
            recordStage: nil, auditCardObserver: baseObserver, birthsAllowed: [], proposals: &proposals, sourceReuse:sourceReuse, secondPass:false,
            paragraphGuardEnabled: paragraphGuardEnabled, paragraphPanelSupport: paragraphPanelSupport)
        var chosen = base, committed = false
        func deliver() -> PreparedRender {
            if let auditCardObserver {
                for (stage,card) in committed ? trialEvents : baseEvents { auditCardObserver(stage,card) }
            }
            recordStage?("native.solidTextBoxes")
            return chosen
        }
        guard !proposals.isEmpty, proposals.count <= NativeSourceBootstrapBirth.Budget.maximumBirths,
              base.retainedWidthArtifact == nil, bootstrapPlainWorld(base.cards) else { return deliver() }
        let ids = Set(proposals.keys)
        var second: [String: NativeSourceBootstrapBirth.Proposal] = [:]
        let trial: PreparedRender
        do { trial = try prepareSourceTextBoxesPass(layout: layout, image: image, settings: settings,
            scale: scale, renderBounds: renderBounds, composeSource: composeSource, outputPixelSize: outputPixelSize,
            collectDiagnostics: collectDiagnostics, capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale,
            recordStage: nil, auditCardObserver: trialObserver, birthsAllowed: ids, proposals: &second, sourceReuse:sourceReuse, secondPass:true,
            paragraphGuardEnabled: paragraphGuardEnabled, paragraphPanelSupport: paragraphPanelSupport)
        } catch is CancellationError { throw CancellationError() }
        catch { return deliver() }
        guard trial.retainedWidthArtifact == nil, bootstrapPlainWorld(trial.cards) else { return deliver() }
        let old = Dictionary(uniqueKeysWithValues: base.cards.map { ($0.item.id,$0) })
        guard old.keys.allSatisfy({ id in trial.cards.contains { $0.item.id == id } }) else { return deliver() }
        let births = trial.cards.filter { old[$0.item.id] == nil }
        guard !births.isEmpty, births.count <= NativeSourceBootstrapBirth.Budget.maximumBirths,
              births.allSatisfy({ ids.contains($0.item.id) }) else { return deliver() }
        let changed = trial.cards.filter { c in old[c.item.id].map { !bootstrapPaintUnchanged($0,c) } ?? true }
        var budget = NativeSourceBootstrapBirth.Budget(), audit: [String:Any] = [:]
        var passed = true
        let admissionStarted = ProcessInfo.processInfo.systemUptime
        for card in changed {
            let peers = trial.cards.filter { $0.item.id != card.item.id }
            let n: NativeSourceBootstrapBirth.Admission
            if old[card.item.id] == nil {
                guard let p = second[card.item.id] else { passed = false; break }
                n = try NativeSourceBootstrapBirth.admit(card: card, proposal: p, peers: peers, sourceBaselinePanels: base.cards,
                    fixedOwners: p.fixedOtherOwners, bounds: base.bounds, sourceRect: base.layout.sourceRect,
                    pixels: base.pixels, pdfScale: pdfDeviceScale, budget: &budget)
                audit[card.item.id] = ["domain": p.domain.rawValue,
                    "balloonContainment": p.surface.map { $0.contains(card.sourcePlateRect) } as Any? ?? NSNull(),
                    "nilSurfaceMeansNoBalloon": false, "incumbentTextAlpha": "known-empty", "admission": n.audit]
            } else {
                guard let before = old[card.item.id], before.item.text == card.item.text,
                      before.item.typesettingText == card.item.typesettingText else { passed = false; break }
                n = try NativeSourceBootstrapBirth.admitAlpha(card: card, peers: peers, bounds: base.bounds,
                    sourceRect: base.layout.sourceRect, pixels: base.pixels, pdfScale: pdfDeviceScale, budget: &budget)
                audit[card.item.id] = ["existingChanged": true, "admission": n.audit]
            }
            if !n.accepted { passed = false }
        }
        committed = passed
        let selected = passed ? trial : base
        var ds = try selected.diagnosticData.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String:Any] }
        if collectDiagnostics {
            ds?["sourceBootstrapTransaction"] = ["proposedIDs": ids.sorted(), "bornIDs": births.map { $0.item.id },
                "committed": passed, "birthAdmission": audit, "runtimeCheckedIDs": changed.map { $0.item.id },
                "alphaPixelsCharged": budget.charged, "maximumAlphaPixels": NativeSourceBootstrapBirth.Budget.maximumAlphaPixels,
                "maximumBirths": NativeSourceBootstrapBirth.Budget.maximumBirths,
                "admissionMilliseconds": (ProcessInfo.processInfo.systemUptime-admissionStarted)*1000,
                "twoPassMilliseconds": (ProcessInfo.processInfo.systemUptime-started)*1000,
                "existingWorld": "commit whole ordinary downstream trial only if all changed paint and births pass",
                "atomicRollback": "literal original completed prebirth world; no recursive reprepare",
                "serializedPDFMeasured": false]
            ds?["sourceBootstrapSourceReuse"] = sourceReuse.audit
            chosen = PreparedRender(inputLayout: selected.inputLayout, layout: selected.layout, image: selected.image, source: selected.source,
                restoration: selected.restoration, cards: selected.cards, glossCards: selected.glossCards, gloss: selected.gloss, settings: selected.settings,
                bounds: selected.bounds, pixels: selected.pixels, scale: selected.scale, composeSource: selected.composeSource,
                capturePDF: selected.capturePDF, pdfDeviceScale: selected.pdfDeviceScale, sourcePatches: selected.sourcePatches,
                sourcePieces: selected.sourcePieces, limitations: selected.limitations,
                diagnosticData: try ds.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
        } else { chosen = selected }
        return deliver()
    }
}
