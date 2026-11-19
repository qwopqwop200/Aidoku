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
    /// followed by line assembly beats the low-threshold candidate below on
    /// recall@0.5, precision and matched IoU (recall@0.7 is within 0.1 pt).
    static let configuration = NativeCoreMLDBPostprocessConfiguration.manga
    /// Low-threshold candidate (pixel 0.4, unclip 1.3), evaluated and kept for comparison.
    static let lowThresholdConfiguration = NativeCoreMLDBPostprocessConfiguration(
        threshold: 0.4,
        boxThreshold: 0.25,
        unclipRatio: 1.3,
        maximumCandidates: 3_000
    )

    static func detect(
        _ page: V2Page,
        detector: NativeCoreMLDetector,
        configuration: NativeCoreMLDBPostprocessConfiguration = V2Detection.configuration
    ) async throws -> [V2Line] {
        // Geometry-only entry point: skips the legacy evidence V2 never reads, the input digest
        // and the MLTensor round trip (multiarray feature-provider prediction, bit-identical output).
        let result = try await detector.detectGeometry(image: page.image, requestID: page.id, configuration: configuration)
        return result.boxes.compactMap { line(polygon: $0.polygon, score: $0.score) }
    }

    /// Detection from an RGBA frame the caller already converted (shared with S3 recognition).
    static func detect(
        frame: NativeOCRRGBAFrame,
        page: V2Page,
        detector: NativeCoreMLDetector,
        configuration: NativeCoreMLDBPostprocessConfiguration = V2Detection.configuration
    ) async throws -> [V2Line] {
        let result = try await detector.detectGeometry(frame: frame, requestID: page.id, configuration: configuration)
        return result.boxes.compactMap { line(polygon: $0.polygon, score: $0.score) }
    }

    /// Detection followed by fragment assembly.
    static func detectLines(
        _ page: V2Page,
        detector: NativeCoreMLDetector,
        layout: [V2LayoutRegion]
    ) async throws -> [V2Line] {
        V2LineAssembly.assemble(try await detect(page, detector: detector), layout: layout)
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

    /// TL, TR, BR, BL for a quadrilateral (sort by x, then each side by y); other polygons unchanged.
    static func orderedQuad(_ polygon: [CGPoint]) -> [CGPoint] {
        guard polygon.count == 4 else { return polygon }
        let sorted = polygon.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        let left = sorted[0..<2].sorted { $0.y < $1.y }
        let right = sorted[2..<4].sorted { $0.y < $1.y }
        return [left[0], right[0], right[1], left[1]]
    }
}
