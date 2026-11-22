import CoreGraphics
import Foundation

/// S2a: PP-OCRv6 Manga DB text detection for one page.
///
/// Wraps the resident `NativeCoreMLDetector` and converts its boxes to
/// `V2Line` values in page pixels (polygon order TL, TR, BR, BL). Lines are
/// detector fragments; `V2LineAssembly.assemble` joins fragments of one column
/// or row afterwards. V2 owns its DB postprocess configuration; legacy
/// defaults are never changed from here.
@available(iOS 18.0, *)
enum V2Detection {
    /// Selected on GT dev: the legacy Manga binarization (0.85, unclip 1.4)
    /// followed by line assembly beats a low-threshold candidate (pixel 0.4,
    /// unclip 1.3) on recall@0.5, precision and matched IoU (recall@0.7 is within 0.1 pt).
    static let configuration = NativeCoreMLDBPostprocessConfiguration.manga

    static func detect(_ page: V2Page, detector: NativeCoreMLDetector) async throws -> [V2Line] {
        // Geometry-only entry point: skips the legacy evidence V2 never reads, the input digest
        // and the MLTensor round trip (multiarray feature-provider prediction, bit-identical output).
        let boxes = try await detector.detectGeometry(image: page.image, configuration: configuration)
        return boxes.compactMap { line(polygon: $0.polygon, score: $0.score) }
    }

    /// Detection from an RGBA frame the caller already converted (shared with S3 recognition).
    static func detect(frame: NativeOCRRGBAFrame, detector: NativeCoreMLDetector) async throws -> [V2Line] {
        let boxes = try await detector.detectGeometry(frame: frame, configuration: configuration)
        return boxes.compactMap { line(polygon: $0.polygon, score: $0.score) }
    }

    /// Detection on one pooled resident detector (one page per instance at a time).
    static func detect(_ page: V2Page, models: V2Models) async throws -> [V2Line] {
        try await models.detectors.with { try await detect(page, detector: $0) }
    }

    /// Frame-sharing variant used by the pipeline (S3 reuses the same frame).
    static func detect(frame: NativeOCRRGBAFrame, models: V2Models) async throws -> [V2Line] {
        try await models.detectors.with { try await detect(frame: frame, detector: $0) }
    }

    static func line(polygon: [CGPoint], score: Double) -> V2Line? {
        guard polygon.count >= 3, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let ordered = orderedQuad(polygon)
        let xs = ordered.map(\.x)
        let ys = ordered.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return V2Line(polygon: ordered, bounds: bounds, vertical: bounds.height >= bounds.width, detectionScore: Float(score))
    }

    /// TL, TR, BR, BL for a quadrilateral: the reading quad recognition uses (top = the most horizontal
    /// rightward edge), so a tilted column keeps its short edge on top; other polygons unchanged.
    static func orderedQuad(_ polygon: [CGPoint]) -> [CGPoint] {
        NativeOCRDirectionGeometry.readingQuad(polygon) ?? polygon
    }
}
