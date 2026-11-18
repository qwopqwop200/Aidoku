import CoreGraphics
import Foundation

/// Exact existing renderer source-palette estimator, exposed before display-only BW selection.
/// No label/cache predictions, changed source roles, or inferred fallback success.
enum Ensemble100PaletteBridge {
    enum Failure: Error { case missingOrInvalidContrastParameter }

    /// Parent-owned entrypoints call this once before shaping. No environment, cache paths or policy presets.
    /// Require the parent to choose its contrast floor explicitly; frozen candidate defaults are not deployment approval.
    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        if parameters["enabled"] == 0 {
            return Ensemble100Proposal(items: page.items, audit: ["paletteBridge": "disabled"])
        }
        guard let floor = parameters["minimumFillStrokeContrast"], floor.isFinite, (3...4.5).contains(floor) else {
            throw Failure.missingOrInvalidContrastParameter
        }
        let annotated = annotate(page.items, original: page.original, cache: NativeMainEnsembleCacheContext.from(page))
        let resolved = Ensemble100Page(sourceSHA256: page.sourceSHA256, original: page.original, restored: page.restored,
            removalMask: page.removalMask, viewport: page.viewport, items: annotated,
            rfRegions: page.rfRegions, savedEvidence: page.savedEvidence)
        var proposal = try EnsembleCandidate07Next.apply(resolved, parameters: parameters)
        proposal.audit["paletteBridge"] = ["inputItems": page.items.count, "outputItems": proposal.items.count,
            "sourceObservation": "existing main sampler plus original-only ROI/topology; source and display independent",
            "contrastFloorAuthority": "explicit parent parameters", "minimumFillStrokeContrast": floor] as [String: Any]
        return proposal
    }

    static func annotate(_ items: [[String: Any]], original: CGImage,
                         cache: NativeMainEnsembleCacheContext? = nil) -> [[String: Any]] {
        let palette = NativeOriginalSourcePalette(original: original)
        return items.map { item in
            guard item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true,
                  let text = item["text"] as? String, !text.isEmpty else { return item }
            // An upstream source/display decision is not ours to overwrite.
            guard item["ensemblePaletteAudit"] == nil else { return item }
            let bounds = item["sourceBounds"] as? [Double] ?? []
            let polygon = item["sourcePolygon"] as? [[Double]]
            let baselineObservation = palette.observeCached(context: cache, originalGeometry: item)
            let observation = baselineObservation.selected.color == nil
                ? NativeCausalParagraphPaletteCompatibility.observePolicyDescriptor(original:original,
                    geometry:item,sourceBounds:bounds) ?? baselineObservation : baselineObservation
            let selected = observation.selected
            let recovered = selected.color == nil ? NativeMainEnsembleCacheContext.neutralShell(context: cache,
                original: original, bounds: bounds, polygon: polygon) {
                    NativeNeutralShellObserver.observe(original: original, bounds: bounds, geometry: item)
                } : nil
            let predicted = recovered?.fill ?? selected.color
            let corrected = observation.evidence.map {
                NativeSourceInkSelection.displaySelection(fill: observation.originalFill,
                    stroke: observation.originalStroke, evidence: $0)
            }
            let display = item["ensembleDisplayFill"] as? [Double] ?? recovered?.fill ?? corrected?.color ?? predicted ?? [0, 0, 0]
            var output = item
            output["ensembleDisplayFill"] = display
            output["ensemblePaletteAudit"] = [
                "sourceFill": (recovered?.fill ?? observation.originalFill) as Any? ?? NSNull(),
                "sourceStroke": (recovered?.stroke ?? observation.originalStroke) as Any? ?? NSNull(),
                "selectedOriginalInk": predicted as Any? ?? NSNull(),
                "displayFill": display, "displayFallback": predicted == nil,
                "selectionPolicy": "display-core-before-low-chroma-area-only-halo-v3",
                "displaySelectionRole": corrected?.role as Any? ?? NSNull(),
                "selectedRole": recovered == nil ? selected.role : "owned-neutral-core-with-bright-exterior-shell",
                "uncertainty": recovered == nil ? observation.unknownReason as Any? ?? NSNull()
                    : "neutral-shell topology estimate;not gold",
                "previousOriginalEvidence": observation.rawPrediction as Any? ?? NSNull(),
                "neutralShellEvidence": recovered?.evidence as Any? ?? NSNull(),
                "authority": "unchanged renderer original-pixel estimator, parent bridge before BW display selection"
            ] as [String: Any]
            return output
        }
    }
}
