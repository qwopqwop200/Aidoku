import CoreGraphics
import Foundation

/// Connects source-owned blank-band fitting to emitted individual geometry.
/// Recognition strings/confidence never decide whether a quad is corrected.
enum NativeOCRBlankGrowthCorrection {
    struct Change {
        let index: Int
        let polygon: [CGPoint]
        let rawIndex: Int
        let measurement: NativeOCRBlankGrowthTrim.Measurement?
    }

    @available(iOS 18.0, *)
    static func changes(polygons: [[CGPoint]], originals: [NativeCoreMLDetectionBox],
                        frame: NativeOCRRGBAFrame) -> [Change] {
        guard ProcessInfo.processInfo.environment["AIDOKU_OCR_BLANK_GROWTH_TRIM"] == "1",
              !polygons.isEmpty, !originals.isEmpty else { return [] }
        typealias Fit = NativeOCRBlankGrowthTrim
        func points(_ polygon: [CGPoint]) -> [Fit.Point] {
            polygon.map { .init(x: Double($0.x), y: Double($0.y)) }
        }
        let image = Fit.Frame(width: frame.width, height: frame.height,
            bytesPerRow: frame.bytesPerRow, channels: 4, pixels: frame.bytes)
        let rawAreas = originals.map { NativeOCRDirectionGeometry.area($0.polygon) }
        var output: [Change] = []
        for (index, polygon) in polygons.enumerated() {
            let area = NativeOCRDirectionGeometry.area(polygon)
            guard area > 0 else { continue }
            let ranking = originals.indices.map { raw -> (Int, Double) in
                let intersection = NativeOCRDirectionGeometry.intersectionArea(polygon, originals[raw].polygon)
                let union = area + rawAreas[raw] - intersection
                return (raw, union > 0 ? Double(intersection / union) : 0)
            }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            guard let best = ranking.first, best.1 >= 0.35,
                  best.1 - (ranking.dropFirst().first?.1 ?? 0) >= 0.08,
                  let evidence = originals[best.0].detectorSeedEvidence,
                  evidence.isValid else { continue }
            let owned = Fit.OwnedEvidence(sourceWidth: evidence.sourceWidth,
                sourceHeight: evidence.sourceHeight, mapFullWidth: evidence.mapFullWidth,
                mapFullHeight: evidence.mapFullHeight, completeCCScan: evidence.completeCCScan == true,
                ambiguousCount: evidence.ambiguousComponents?.count ?? 0,
                candidateCount: evidence.candidateComponents?.count ?? 0,
                components: evidence.components.map { component in
                    component.runs.map { .init(x: $0.x, y: $0.y, count: $0.count) }
                })
            let fitted = Fit.trim(frame: image, owned: owned, raw: points(originals[best.0].polygon),
                current: points(polygon), associationIoU: best.1,
                runnerUpIoU: ranking.dropFirst().first?.1 ?? 0)
            guard fitted.changed else { continue }
            output.append(.init(index: index,
                polygon: fitted.polygon.map { CGPoint(x: $0.x, y: $0.y) },
                rawIndex: best.0, measurement: fitted.measurement))
        }
        return output
    }
}
