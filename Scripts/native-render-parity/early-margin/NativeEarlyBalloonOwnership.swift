import CoreGraphics
import Foundation

/// Exact fitBalloon plate-removal admission4548–4619. A restored neighbor can
/// share this owner without forbidding removal; a clipped bounding box cannot
/// prove that a different card will retain all exposed source or caption ink.
enum NativeEarlyBalloonOwnership {
    struct Panel {
        var id: String
        var rect: CGRect
        var opaque = true
        var clipped = false
        var visible = true
        var opacity: Double = 1
        var sourceErasure = false
        var explicitCoverage: [CGRect]?
        var admits: Bool { opaque && !clipped && visible && opacity == 1 }
    }
    struct Caption {
        var id: String
        var sources: [CGRect]
        var ink: CGRect
        var inpainted = false
        var verified = false
        var provisional = false
        var partial = false
        var erasureComplete = false
        var canvasConnected = false
        var canvasSize: CGSize = .zero
    }
    struct Result { var accepted: Bool; var sharedRemoval: Bool }
    static func permits(ownerIndex: Int, panels: [Panel], captions: [Caption], legible: Bool) -> Result {
        guard panels.indices.contains(ownerIndex) else { return .init(accepted:false,sharedRemoval:false) }
        let p=panels[ownerIndex];var shared=false
        func intersects(_ r:CGRect)->Bool { r.minX<p.rect.maxX && r.maxX>p.rect.minX && r.minY<p.rect.maxY && r.maxY>p.rect.minY }
        for other in captions where other.id != p.id {
            if !other.sources.contains(where:{intersects($0.insetBy(dx:-3,dy:-3))}) { continue }
            if other.verified && !other.provisional && !other.partial && other.erasureComplete &&
                other.canvasConnected && other.canvasSize.width>0 && other.canvasSize.height>0 {
                shared=true;continue
            }
            if legible {
                let own=panels.indices.filter { i in
                    i != ownerIndex && panels[i].id == other.id && !panels[i].sourceErasure &&
                    panels[i].explicitCoverage == nil && panels[i].admits
                }.map { panels[$0].rect }
                if !own.isEmpty && other.sources.allSatisfy({ source in
                    let intersection=source.insetBy(dx:-3,dy:-3).intersection(p.rect)
                    return intersection.isNull || intersection.width<=0 || intersection.height<=0 || own.contains { $0.contains(intersection) }
                }) { shared=true;continue }
            }
            return .init(accepted:false,sharedRemoval:shared)
        }
        for other in captions where other.id != p.id {
            let r=other.ink
            let owned=panels.indices.contains { i in
                guard i != ownerIndex,panels[i].id == other.id,panels[i].admits,panels[i].rect.contains(r) else { return false }
                return panels[i].explicitCoverage?.contains { $0.contains(r) } ?? true
            }
            if !intersects(r) { continue }
            if owned || other.inpainted { shared=true;continue }
            return .init(accepted:false,sharedRemoval:shared)
        }
        return .init(accepted:true,sharedRemoval:shared)
    }
}
