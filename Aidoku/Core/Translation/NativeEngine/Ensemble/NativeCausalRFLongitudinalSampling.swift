import CoreGraphics
import Foundation

/// Original-pixel recognition context only; never source/removal authority.
enum NativeCausalRFLongitudinalSampling {
    typealias P = NativeCausalRFParagraphRecognition
    struct Evidence: Equatable, Sendable {
        let version: String
        let fraction: Double
        let pitch: Double
        let canvasWidth: Double
        let canvasHeight: Double
        let keepouts: [P.Owner] // every OTHER actual live source owner
    }

    static var configuredFraction: Double {
        guard let raw = ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_PARAGRAPH_LONGITUDINAL_PADDING"],
              let value = Double(raw), [0, 0.1, 0.2].contains(value) else { return 0 }
        return value
    }
    static var cacheVersion: String { "rf-original-longitudinal-v1:\(configuredFraction)" }

    static func evidence(fraction: Double, centers: [CGFloat], canvas: CGSize,
                         originals: [P.Owner], current: [P.Owner]) -> Evidence? {
        guard [0.1, 0.2].contains(fraction), centers.count >= 2,
              canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return nil }
        let pitch = zip(centers.dropFirst(), centers).map { abs($0 - $1) }.min()!
        guard pitch.isFinite, pitch >= 6 else { return nil }
        let ids = Set(originals.map(\.id))
        return Evidence(version: "rf-original-longitudinal-v1", fraction: fraction, pitch: pitch,
            canvasWidth: canvas.width, canvasHeight: canvas.height,
            keepouts: current.filter { !ids.contains($0.id) }.sorted { $0.id < $1.id })
    }

    static func matchesCurrent(_ evidence: Evidence, originals: [P.Owner], current: [P.Owner]) -> Bool {
        let ids = Set(originals.map(\.id))
        return evidence.keepouts == current.filter { !ids.contains($0.id) }.sorted { $0.id < $1.id }
    }

    /// Reconstructable from base strips plus the recorded live-source snapshot.
    /// Keepout contact limits context; it never shrinks the original source Y.
    static func padded(_ base: CGRect, source: CGRect, evidence: Evidence) -> CGRect? {
        guard evidence.version == "rf-original-longitudinal-v1", [0.1, 0.2].contains(evidence.fraction),
              evidence.pitch.isFinite, evidence.pitch >= 6,
              evidence.canvasWidth.isFinite, evidence.canvasHeight.isFinite,
              evidence.canvasWidth > 0, evidence.canvasHeight > 0,
              CGRect(x: 0, y: 0, width: evidence.canvasWidth, height: evidence.canvasHeight).contains(source),
              base.minY == source.minY, base.maxY == source.maxY else { return nil }
        let amount = min(32, evidence.pitch * evidence.fraction)
        var top = max(0, base.minY - amount)
        var bottom = min(evidence.canvasHeight, base.maxY + amount)
        for owner in evidence.keepouts {
            let b = owner.bounds
            guard [b.minX, b.minY, b.maxX, b.maxY].allSatisfy(\.isFinite), b.width > 0, b.height > 0 else { return nil }
            guard min(base.maxX, b.maxX) > max(base.minX, b.minX) else { continue }
            if b.maxY <= base.minY { top = max(top, b.maxY) }
            else if b.minY >= base.maxY { bottom = min(bottom, b.minY) }
            else { return nil } // existing foreign source, not padding permission
        }
        guard top <= base.minY, bottom >= base.maxY else { return nil }
        return CGRect(x: base.minX, y: top, width: base.width, height: bottom - top)
    }

    static func validatedPitch(_ evidence: Evidence, centers: [CGFloat]) -> Bool {
        guard centers.count >= 2 else { return false }
        let pitch = zip(centers.dropFirst(), centers).map { abs($0 - $1) }.min()!
        return pitch.isFinite && abs(pitch - evidence.pitch) < 1e-6 &&
            evidence.keepouts.count <= 256 && Set(evidence.keepouts.map(\.id)).count == evidence.keepouts.count
    }
}
