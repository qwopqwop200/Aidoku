import CoreGraphics
import Foundation

/// S2a: PP-OCRv6 Manga DB text detection; boxes become `PipelineLine` fragments in page pixels
/// (polygon TL, TR, BR, BL) that `PipelineLineAssembly.assemble` joins afterwards.
@available(iOS 18.0, *)
enum PipelineDetection {
    /// The legacy Manga binarization (0.85, unclip 1.4); with line assembly it beat a
    /// low-threshold candidate on GT dev.
    static var configuration: NativeCoreMLDBPostprocessConfiguration {
        let tuning = PipelineTuning.current
        return NativeCoreMLDBPostprocessConfiguration(threshold: tuning.detectionThreshold, boxThreshold: tuning.detectionBoxThreshold,
                                                      unclipRatio: tuning.detectionUnclipRatio,
                                                      maximumCandidates: NativeCoreMLDBPostprocessConfiguration.manga.maximumCandidates)
    }

    static func detect(_ page: PipelinePage, detector: NativeCoreMLDetector) async throws -> [PipelineLine] {
        // Geometry only: no legacy evidence, input digest or MLTensor round trip (bit-identical boxes).
        let boxes = try await detector.detectGeometry(image: page.image, configuration: configuration)
        return boxes.compactMap { line(polygon: $0.polygon, score: $0.score) }
    }

    /// Detection on one pooled resident detector (one page per instance at a time).
    static func detect(_ page: PipelinePage, models: PipelineModels) async throws -> [PipelineLine] {
        try await models.detectors.with { try await detect(page, detector: $0) }
    }

    /// Detection from the RGBA frame S3 recognition reuses.
    static func detect(frame: NativeOCRRGBAFrame, models: PipelineModels) async throws -> [PipelineLine] {
        try await models.detectors.with { detector in
            let boxes = try await detector.detectGeometry(frame: frame, configuration: configuration)
            return boxes.compactMap { line(polygon: $0.polygon, score: $0.score) }
        }
    }

    static func line(polygon: [CGPoint], score: Double) -> PipelineLine? {
        guard polygon.count >= 3, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        // The reading quad recognition uses: a tilted column keeps its short edge on top.
        let ordered = NativeOCRDirectionGeometry.readingQuad(polygon) ?? polygon
        let xs = ordered.map(\.x)
        let ys = ordered.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return PipelineLine(polygon: ordered, bounds: bounds, vertical: bounds.height >= bounds.width, detectionScore: Float(score))
    }
}
