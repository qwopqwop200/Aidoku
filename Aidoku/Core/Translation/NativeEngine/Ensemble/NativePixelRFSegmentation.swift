import CoreGraphics
import Foundation

/// Calibrated source glyph segmentation. Runtime inputs are pixels, localization
/// and source-bound RF outputs; the classifier is a single global model.
enum NativePixelRFSegmentation {
    enum Failure: Error { case invalidGeometry, sourceMismatch }
    struct Result {
        let bounds: CGRect
        let mask: [UInt8]
        let audit: [String: Any]
    }
    struct WeakRescuePolicy: Codable, Sendable {
        let probabilityThreshold: Float
        let supportThreshold: Float
    }

    /// Independent RF corroboration restores uncertain glyph pixels. It never
    /// adds pixels below the classifier floor or clips the mask to a bbox.
    static func rescueWeak(mask: [UInt8], probabilities: [Float], support: [Float],
                           policy: WeakRescuePolicy) throws -> (mask: [UInt8], added: Int) {
        guard !mask.isEmpty, mask.count <= 1_500_000, probabilities.count == mask.count, support.count == mask.count,
              policy.probabilityThreshold.isFinite, (0...1).contains(policy.probabilityThreshold),
              policy.supportThreshold.isFinite, (0...1).contains(policy.supportThreshold),
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              support.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidGeometry }
        var result = mask, added = 0
        for i in result.indices where result[i] == 0 &&
            probabilities[i] >= policy.probabilityThreshold && support[i] >= policy.supportThreshold {
            result[i] = 255
            added += 1
        }
        return (result, added)
    }

    static func segmentCrop(rgb: [UInt8], width: Int, height: Int, polygons: [[CGPoint]],
                            fontPixels: Double, coarseRF: [Float], fullRF: [Float]?,
                            model: NativePixelRFForest,
                            captureClassifier: (([Float], [UInt8]) throws -> Void)? = nil,
                            weakRescue: WeakRescuePolicy? = nil) throws -> Result {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              rgb.count == width * height * 3, !polygons.isEmpty, polygons.count <= 256,
              polygons.allSatisfy({ (3...16).contains($0.count) && $0.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) }),
              fontPixels.isFinite, fontPixels > 0 else { throw Failure.invalidGeometry }
        typealias Factory = NativeMainRemovalSourceFactory
        let source = Factory.NativeCurrentMaskCaller.Source(width: width, height: height,
            rgb: rgb, revision: "fresh-source-crop")
        let owners = polygons.enumerated().map { index, polygon in
            Factory.NativeCurrentMaskCaller.Owner(id: String(index), polygon: polygon,
                fontPixels: fontPixels, translated: true, balloon: false)
        }
        let base = try Factory.NativeSourceBaseMask.extract(source: source, owners: owners)
        let chroma = try Factory.NativeChromaticMaskCompletion.complete(rgb: rgb, width: width, height: height,
            base: base.mask, protection: [UInt8](repeating: 0, count: width * height),
            owners: owners.map { .init(id: $0.id, polygon: $0.polygon, fontPixels: $0.fontPixels) })
        let probabilities = try model.cropProbabilities(.init(width: width, height: height, rgb: rgb,
            nativeMask: chroma.mask, polygons: polygons, fontPixels: fontPixels, coarseRF: coarseRF, fullRF: fullRF))
        try captureClassifier?(probabilities, chroma.mask)
        let completed = try complete(probabilities: probabilities, nativeMask: chroma.mask, width: width,
            height: height, fontPixels: fontPixels, model: model)
        guard let weakRescue else { return completed }
        guard let fullRF, fullRF.count == width * height * 27 else { throw Failure.invalidGeometry }
        var support = [Float](repeating: 0, count: width * height)
        for i in support.indices {
            let offset = i * 27
            let text: Float = fullRF[offset + 15] * fullRF[offset + 16]
            let sfx: Float = fullRF[offset + 17] * fullRF[offset + 18]
            support[i] = max(text, sfx)
        }
        let rescued = try rescueWeak(mask: completed.mask, probabilities: probabilities, support: support, policy: weakRescue)
        var audit = completed.audit
        audit["weakRFRescueAdded"] = rescued.added
        audit["weakRFRescueProbabilityThreshold"] = Double(weakRescue.probabilityThreshold)
        audit["weakRFRescueSupportThreshold"] = Double(weakRescue.supportThreshold)
        audit["maskPixels"] = rescued.mask.filter { $0 != 0 }.count
        return Result(bounds: completed.bounds, mask: rescued.mask, audit: audit)
    }

    /// Shared by live extraction and source-bound classifier replay. Cached
    /// probabilities are observations, never masks or target-label decisions.
    static func complete(probabilities: [Float], nativeMask: [UInt8], width: Int, height: Int,
                         fontPixels: Double, model: NativePixelRFForest) throws -> Result {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              probabilities.count == width * height, nativeMask.count == width * height,
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              fontPixels.isFinite, fontPixels > 0 else { throw Failure.invalidGeometry }
        var mask: [UInt8] = probabilities.map { $0 >= model.threshold ? 255 : 0 }
        let classifierPixels = mask.filter { $0 != 0 }.count
        var radius = 0
        if let completion = model.completion {
            if completion.unionNative {
                for i in mask.indices where nativeMask[i] != 0 { mask[i] = 255 }
            }
            let scaled = min(Double(completion.maximumRadiusPixels),
                max(0, (fontPixels * completion.radiusFontScale).rounded(.toNearestOrEven)))
            radius = max(completion.minimumRadiusPixels, Int(scaled))
            if radius > 0 {
                mask = expand(mask, width: width, height: height, radius: radius,
                    kernel: completion.kernel ?? "square")
            }
            if let fringe = completion.fringeThreshold, fringe > 0 {
                for i in mask.indices where probabilities[i] < fringe { mask[i] = 0 }
            }
        }
        var weakPixelsAdded = 0
        if let weak = model.completion?.weakThreshold {
            for i in mask.indices where mask[i] == 0 && probabilities[i] >= weak {
                mask[i] = 255
                weakPixelsAdded += 1
            }
        }
        return Result(bounds: CGRect(x: 0, y: 0, width: width, height: height), mask: mask,
            audit: ["classifier": "source-pixel-rf-global-forest", "modelSHA256": model.sourceModelSHA256,
                "featureVariant": model.sourceFeatureVariant, "threshold": Double(model.threshold),
                "featureCount": model.featureCount, "pixels": width * height,
                "nativeBasePixels": nativeMask.filter { $0 != 0 }.count,
                "classifierPixels": classifierPixels, "completionRadiusPixels": radius,
                "completionUnionNative": model.completion?.unionNative ?? false,
                "completionKernel": model.completion?.kernel ?? "square",
                "completionFringeThreshold": Double(model.completion?.fringeThreshold ?? 0),
                "completionWeakPixelsAdded": weakPixelsAdded,
                "maskPixels": mask.filter { $0 != 0 }.count, "GTRead": false,
                "localizationIsFinalMaskClip": false, "restoredPixelsRead": false])
    }

    /// A single expansion from strong seeds; recovered fringe pixels never
    /// become seeds. Ellipse rows follow the integer OpenCV morphology kernel.
    static func expand(_ seed: [UInt8], width: Int, height: Int, radius: Int, kernel: String) -> [UInt8] {
        if radius == 0 { return seed }
        if kernel == "square" {
            return NativeMainRemovalSourceFactory.NativeSourceRoleMask.dilate(seed.map { $0 == 0 ? 0 : 1 },
                width: width, height: height, radius: radius).map { $0 == 0 ? 0 : 255 }
        }
        var result = [UInt8](repeating: 0, count: seed.count)
        for dy in -radius...radius {
            let extent = kernel == "cross" ? (dy == 0 ? radius : 0) :
                Int((Double(radius * radius - dy * dy).squareRoot()).rounded(.toNearestOrEven))
            let firstY = max(0, -dy), lastY = min(height, height - dy)
            guard firstY < lastY else { continue }
            for y in firstY..<lastY {
                for x in 0..<width where seed[y * width + x] != 0 {
                    let start = max(0, x - extent), end = min(width - 1, x + extent)
                    let offset = (y + dy) * width
                    for targetX in start...end { result[offset + targetX] = 255 }
                }
            }
        }
        return result
    }

    static func segment(source: NativeRFDETRSourceImage, polygons: [[CGPoint]], fontPixels: Double,
                        evidence: NativePixelRFEvidence, model: NativePixelRFForest,
                        weakRescue: WeakRescuePolicy? = nil) throws -> Result {
        guard evidence.width == source.width, evidence.height == source.height,
              evidence.imageIdentity == source.identity else { throw Failure.sourceMismatch }
        guard !polygons.isEmpty, polygons.count <= 256,
              polygons.allSatisfy({ (3...16).contains($0.count) && $0.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) }) else {
            throw Failure.invalidGeometry
        }
        let points = polygons.flatMap { $0 }
        let left = points.map(\.x).min()!, right = points.map(\.x).max()!
        let top = points.map(\.y).min()!, bottom = points.map(\.y).max()!
        guard right > left, bottom > top else { throw Failure.invalidGeometry }
        // The bbox defines the context ROI, not foreground. Preserve complete
        // glyph evidence beyond the localization edge within 15% context.
        let padX = floor((right - left) * 0.15), padY = floor((bottom - top) * 0.15)
        let bounds = CGRect(x: max(0, floor(left) - padX), y: max(0, floor(top) - padY),
            width: min(CGFloat(source.width), ceil(right) + padX) - max(0, floor(left) - padX),
            height: min(CGFloat(source.height), ceil(bottom) + padY) - max(0, floor(top) - padY))
        guard bounds.width > 0, bounds.height > 0,
              bounds.width <= 1_500_000 / bounds.height else { throw Failure.invalidGeometry }
        let w = Int(bounds.width), h = Int(bounds.height)
        let support = try evidence.support(crop: bounds, polygons: polygons, sourceIdentity: evidence.imageIdentity)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        source.rgb.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for y in 0..<h {
                let offset = ((Int(bounds.minY) + y) * source.width + Int(bounds.minX)) * 3
                for x in 0..<(w * 3) { rgb[y * w * 3 + x] = bytes[offset + x] }
            }
        }
        let local = polygons.map { polygon in polygon.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) } }
        let result = try segmentCrop(rgb: rgb, width: w, height: h, polygons: local, fontPixels: fontPixels,
            coarseRF: support.coarse, fullRF: model.featureCount == 62 ? support.full : nil, model: model, weakRescue: weakRescue)
        var audit = result.audit
        audit["RFQueries"] = 300; audit["RFOwnerQueries"] = support.ownerQueries
        audit["sourceIdentity"] = evidence.imageIdentity
        return Result(bounds: bounds, mask: result.mask, audit: audit)
    }
}
