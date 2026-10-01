import CoreGraphics
import Foundation

/// Retained source canvas for conditional final typography trials. The original
/// restoration is immutable until a caller commits a measured candidate.
final class NativeRestorationCandidate {
    typealias Surface = NativeResidualTopology.Surface
    let descriptor: NativeSpatialSourceCrop.Prepared
    let imageSize: CGSize
    let frame: CGRect
    let sourceBounds: [Double]
    let auxiliaryInkRects: [[Double]]
    let sourceFontSize: Double?
    let erasureComplete: Bool
    let sourceGlyphsVerified: Bool
    let sourceErasureVerified: Bool
    let sourceRemainingInk: Int?
    let sourceCorePixels: Int?
    var provisional: Bool
    let localRestorationProposal: Bool
    var partialErasureCertified = false
    var sourceResidualFilled: Int?
    let method: String?
    let surfaceQuality: [String: Any]?
    private(set) var surface: Surface
    private var cachedImage: CGImage?
    private var cachedRevision = -1

    init?(prepared: NativeSpatialSourceCrop.Prepared, repaired: NativeRestorationPixels, luminance: [UInt8],
          imageSize: CGSize, frame: CGRect, item: NativeTranslationLayoutItem, sourceErasureVerified: Bool? = nil, canvasErasureComplete: Bool? = nil) {
        guard let safe = repaired.layoutSafe, safe.count == repaired.count, luminance.count == repaired.count,
              repaired.rgba.count == repaired.count * 4 else { return nil }
        descriptor = prepared; self.imageSize = imageSize; self.frame = frame
        sourceBounds = item.sourceBounds.map(Double.init); auxiliaryInkRects = item.auxiliaryInkRects.map { $0.map(Double.init) }
        sourceFontSize = item.sourceFontSize.map(Double.init); erasureComplete = canvasErasureComplete ?? repaired.erasureComplete
        sourceGlyphsVerified = repaired.glyphsVerified; self.sourceErasureVerified = sourceErasureVerified ?? repaired.sourceErasureVerified ?? repaired.erasureComplete
        sourceRemainingInk = repaired.sourceRemainingInk; sourceCorePixels = repaired.sourceCorePixels; provisional = repaired.localProposal
        localRestorationProposal = repaired.localProposal
         method = repaired.method; surfaceQuality = repaired.surfaceQuality
        surface = Surface(width: repaired.width, height: repaired.height, rgba: repaired.rgba, safe: safe, luminance: luminance)
    }
    var revision: Int { surface.surfaceRevision }
    var rawRGBA: [UInt8] { surface.rgba }
    var originalRGBA: [UInt8] { descriptor.pixels.rgba }
    var safe: [UInt8] { surface.safe }
    var luminance: [UInt8] { surface.luminance }
    var coreRects: [[Double]] { ([descriptor.box] + descriptor.auxiliary).map(NativeSlantedGeometry.array) }
    var glyphSize: Double {
        max(4, (sourceFontSize ?? 8) * Double(imageSize.width) / Double(frame.width) * Double(descriptor.sx))
    }
    var compositeRGBA: [UInt8] {
        var rgba = originalRGBA
        for i in 0..<surface.width * surface.height {
            let alpha = Double(surface.rgba[i * 4 + 3]) / 255
            if alpha == 0 { continue }
            for channel in 0..<3 {
                rgba[i * 4 + channel] = NativeRestorationPixels.clamp(Double(surface.rgba[i * 4 + channel]) * alpha +
                    Double(originalRGBA[i * 4 + channel]) * (1 - alpha))
            }
            rgba[i * 4 + 3] = 255
        }
        return rgba
    }
    func image() -> CGImage? {
        if cachedRevision == revision { return cachedImage }
        var pixels = NativeRestorationPixels(width: surface.width, height: surface.height); pixels.rgba = surface.rgba
        cachedImage = pixels.image(); cachedRevision = revision
        return cachedImage
    }
    func beginTrial() -> Surface { surface }
    func cacheProof(coreClear: Bool? = nil, innerCoreClear: Bool? = nil, residualLettering: Bool? = nil) {
        if let coreClear { surface.coreClear = coreClear }
        if let innerCoreClear { surface.innerCoreClear = innerCoreClear }
        if let residualLettering { surface.residualLettering = residualLettering }
    }
    /// Helpers can increment the revision themselves. Ordinary caller edits use
    /// the next revision, while a rejected identical trial remains unchanged.
    @discardableResult func commit(_ proposed: Surface) -> Bool {
        guard proposed.width == surface.width, proposed.height == surface.height,
              proposed.rgba.count == surface.rgba.count, proposed.safe.count == surface.safe.count,
              proposed.luminance.count == surface.luminance.count else { return false }
        guard proposed != surface else { return true }
        var next = proposed
        next.surfaceRevision = max(surface.surfaceRevision + 1, next.surfaceRevision)
        surface = next
        return true
    }
    func undo(_ previous: Surface) {
        guard previous.width == surface.width, previous.height == surface.height else { return }
        let revision = surface.surfaceRevision + 1
        surface = previous; surface.surfaceRevision = revision
    }
    /// Source cells and card coverage remain distinct inputs to each proof.
    func viewportRegions(_ rectangles: [CGRect]) -> [[Double]] {
        rectangles.map { r in
            let source = CGRect(x: (r.minX - frame.minX) * imageSize.width / frame.width,
                y: (r.minY - frame.minY) * imageSize.height / frame.height,
                width: r.width * imageSize.width / frame.width, height: r.height * imageSize.height / frame.height)
            return NativeSlantedGeometry.array(descriptor.local(source))
        }
    }
    func hiddenForeignRepaint(plate: CGRect, detachedProposal: Bool) -> Int {
        NativeResidualTopology.hiddenForeignRepaint(width: surface.width, height: surface.height, imageSize: imageSize, frame: frame,
            cropOrigin: descriptor.crop.origin, scale: CGSize(width: descriptor.sx, height: descriptor.sy), sourceFontSize: sourceFontSize,
            sourceBounds: sourceBounds, auxiliaryInkRects: auxiliaryInkRects, plate: plate, detachedProposal: detachedProposal, rgba: surface.rgba)
    }
}

// The transport setter publishes only the caller's accepted or undone trial.
extension NativeRestorationCandidate: NativeFinalRestorationCandidate {
    var trialSurface: NativeResidualTopology.Surface {
        get { beginTrial() }
        set { _ = commit(newValue) }
    }
}
