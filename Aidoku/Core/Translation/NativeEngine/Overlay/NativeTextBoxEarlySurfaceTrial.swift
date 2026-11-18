import CoreGraphics
import Foundation

/// Opt-in geometry-order trial; source colors and normal observation quotas
/// remain untouched. A smaller proposal is NOT a balloon certificate.
enum NativeTextBoxEarlySurfaceTrial {
    /// Preserve the incumbent erasure obligation independently of a new typing
    /// search domain. Admission still requires an actual rectangular surface and
    /// peer-clearance check by the caller; this is not a source-glyph certificate.
    static func backingUnion(candidate: CGRect, incumbent: CGRect, owner: CGRect,
                             peers: [CGRect], contains: (CGRect) -> Bool) -> CGRect? {
        guard [candidate, incumbent, owner].allSatisfy({ !$0.isNull && !$0.isInfinite
            && $0.width > 0 && $0.height > 0
            && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite) }),
            incumbent.contains(owner), !candidate.contains(incumbent) else { return nil }
        let proposal = candidate.union(incumbent)
        guard contains(proposal), !peers.contains(where: { proposal.intersects($0) }) else { return nil }
        return proposal
    }

    static func sourceCoveredProposal(panel: CGRect, surfaceBounds: CGRect, owner: CGRect) -> CGRect? {
        guard [panel, surfaceBounds, owner].allSatisfy({ !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0
            && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite) }) else { return nil }
        let overlap = panel.intersection(surfaceBounds)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
        let candidate = overlap.union(owner).intersection(panel)
        guard candidate.contains(owner), panel.contains(candidate) else { return nil }
        return candidate
    }

    static func refine(panels: [CGRect], owners: [CGRect], items: [NativeTranslationLayoutItem],
                       reader: NativeSourcePixelReader?, sourceSize: CGSize, sourceRect: CGRect) throws
        -> (panels: [CGRect], observations: [[String: Any]], pixels: Int) {
        guard panels.count == owners.count, panels.count == items.count, let reader else {
            return (panels, [], 0)
        }
        var result = panels, records: [[String: Any]] = [], remainingPixels = 800_000
        for index in panels.indices where !items[index].keptLettering && !items[index].text.isEmpty {
            try Task.checkCancellation()
            guard panels.indices.contains(where: { peer in
                peer != index && panels[index].intersects(panels[peer])
            }) else { continue }
            let owner = owners[index]
            let extent = max(owner.width, owner.height) * 1.2
            let roi = owner.insetBy(dx: -extent, dy: -extent).intersection(sourceRect)
            var surface = NativeTextBoxContainment.known(items[index].balloonInterior ?? items[index].balloonUnit?.interior,
                frame: sourceRect)
            if surface == nil, let projection = NativeTextBoxSourceProjection.project(roi, frame: sourceRect,
                sourceSize: sourceSize) {
                let width = Int(min(320, max(8, ceil(projection.width))))
                let height = Int(min(320, max(8, ceil(projection.height))))
                guard width * height <= remainingPixels else { continue }
                remainingPixels -= width * height
                let rgba = try reader.read(x: Double(projection.minX), y: Double(projection.minY),
                    sourceWidth: Double(projection.width), sourceHeight: Double(projection.height), width: width, height: height)
                surface = try NativeTextBoxContainment.measured(rgba: rgba, width: width, height: height,
                    roi: roi, owner: owner, excluding: owners.indices.filter { $0 != index }.map { owners[$0] })
            }
            guard let surface, surface.certifiedSpans else { continue }
            // Keep every accepted source coordinate, including coordinates that
            // conflict with an imperfect contour. Never claim containment for
            // their union. Normal observation/containment still runs afterwards.
            guard let candidate = sourceCoveredProposal(panel: panels[index], surfaceBounds: surface.rect, owner: owner),
                  candidate != panels[index] else { continue }
            result[index] = candidate
            func values(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
            records.append(["id": items[index].id, "before": values(panels[index]), "after": values(candidate),
                "owner": values(owner), "surfaceBounds": values(surface.rect),
                "observedSurfaceContainsOwner": surface.contains(owner),
                "observedSurfaceContainsProposal": surface.contains(candidate),
                "authority": "geometry-only search-domain proposal; not paint/contour/coverage certification"])
        }
        return (result, records, 800_000 - remainingPixels)
    }
}
