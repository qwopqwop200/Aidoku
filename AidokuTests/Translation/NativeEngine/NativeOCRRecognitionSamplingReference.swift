import CoreGraphics
import Foundation
@testable import Aidoku

/// Frozen scalar CGPoint/closure sampler, compiled only into AidokuTests in
/// both Debug and Release. It preserves the former sampling operation order
/// instead of using the production precomputed-coordinate implementation.
/// Canonical quad and bucket policy are shared as in the original oracle;
/// homography evaluation, bilinear reads and normalization remain independent.
/// Provenance: NativeCoreMLRecognizer.swift reference and support routines at
/// SHA256 ad72462760dc3baace5d9e401b17880858ca07260234d70b2fd8fc2dc0379dac. No model loading or prediction is involved.
enum NativeOCRRecognitionSamplingReference {
    private static let targetHeight = 48
    private static let maximumTargetWidth = 2_000

    struct Plan: Sendable {
        let resizedWidth: Int
        let bucket: NativeCoreMLRecognitionBucket
        let rotatedCounterClockwise: Bool
        fileprivate let cropWidth: Int
        fileprivate let cropHeight: Int
        fileprivate let orientedWidth: Int
        fileprivate let orientedHeight: Int
        fileprivate let homography: Homography
    }

    fileprivate struct Quad: Sendable {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomRight: CGPoint
        let bottomLeft: CGPoint
    }

    fileprivate struct Homography: Sendable {
        let a: Double
        let b: Double
        let c: Double
        let d: Double
        let e: Double
        let f: Double
        let g: Double
        let h: Double

        func sourcePoint(u: Double, v: Double) -> CGPoint? {
            let denominator = g * u + h * v + 1
            guard denominator.isFinite, abs(denominator) > 0.000_000_1
            else {
                return nil
            }
            return CGPoint(
                x: (a * u + b * v + c) / denominator,
                y: (d * u + e * v + f) / denominator
            )
        }
    }

    static func plan(
        polygon: [CGPoint],
        dynamicWidth: Bool = false,
        maximumWidth: Int = 2_000,
        useProvidedOrder: Bool = false
    ) -> Plan? {
        guard let quad = makeQuad(polygon, useProvidedOrder: useProvidedOrder),
              let homography = makeHomography(quad)
        else { return nil }
        let widthTop = distance(quad.topLeft, quad.topRight)
        let widthBottom = distance(quad.bottomLeft, quad.bottomRight)
        let heightLeft = distance(quad.topLeft, quad.bottomLeft)
        let heightRight = distance(quad.topRight, quad.bottomRight)
        let width = max(widthTop, widthBottom)
        let height = max(heightLeft, heightRight)
        // Finite input points can still produce overflowing distances or
        // dimensions outside Int's range. Reject before converting geometry.
        guard width.isFinite, height.isFinite,
              width < Double(Int.max), height < Double(Int.max) else { return nil }
        let cropWidth = max(1, Int(floor(width)))
        let cropHeight = max(1, Int(floor(height)))
        guard cropWidth > 1, cropHeight > 1 else { return nil }

        let rotated = Double(cropHeight) / Double(cropWidth) >= 1.5
        let orientedWidth = rotated ? cropHeight : cropWidth
        let orientedHeight = rotated ? cropWidth : cropHeight
        let ratio = Double(orientedWidth) / Double(max(1, orientedHeight))
        let desiredWidth = Int(min(
            Double(maximumTargetWidth),
            max(1, ceil(Double(targetHeight) * ratio))
        ))
        let bucket = NativeCoreMLRecognitionBucket.containing(
            desiredWidth: desiredWidth,
            dynamicWidth: dynamicWidth,
            maximumWidth: maximumWidth
        )
        let resizedWidth = min(bucket.width, desiredWidth)
        return Plan(
            resizedWidth: resizedWidth,
            bucket: bucket,
            rotatedCounterClockwise: rotated,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            orientedWidth: orientedWidth,
            orientedHeight: orientedHeight,
            homography: homography
        )
    }

    /// Preserves the former CGPoint/closure implementation as a test-only
    /// oracle for the optimized contiguous sampling kernel.
    static func prepare(
        frame: NativeOCRRGBAFrame,
        polygon: [CGPoint]
    ) -> NativeCoreMLPreparedTensor? {
        guard let plan = plan(polygon: polygon) else { return nil }
        let targetWidth = plan.bucket.width
        let planeSize = targetHeight * targetWidth
        var values = [Float](repeating: 0, count: planeSize * 3)
        for row in 0..<targetHeight {
            for column in 0..<plan.resizedWidth {
                let orientedX =
                    (Double(column) + 0.5) * Double(plan.orientedWidth)
                    / Double(plan.resizedWidth) - 0.5
                let orientedY =
                    (Double(row) + 0.5) * Double(plan.orientedHeight)
                    / Double(targetHeight) - 0.5
                let warpedX: Double
                let warpedY: Double
                if plan.rotatedCounterClockwise {
                    warpedX = Double(plan.cropWidth - 1) - orientedY
                    warpedY = orientedX
                } else {
                    warpedX = orientedX
                    warpedY = orientedY
                }
                let u = min(max(warpedX / Double(plan.cropWidth), 0), 1)
                let v = min(max(warpedY / Double(plan.cropHeight), 0), 1)
                guard let source = plan.homography.sourcePoint(u: u, v: v)
                else {
                    return nil
                }
                let rgba = sampleBilinear(frame: frame, at: source)
                let destination = row * targetWidth + column
                values[destination] = normalize(rgba.blue)
                values[planeSize + destination] = normalize(rgba.green)
                values[planeSize * 2 + destination] = normalize(rgba.red)
            }
        }
        return NativeCoreMLPreparedTensor(
            values: values,
            resizedWidth: plan.resizedWidth,
            bucket: plan.bucket,
            rotatedCounterClockwise: plan.rotatedCounterClockwise
        )
    }

    private static func makeQuad(_ polygon: [CGPoint], useProvidedOrder: Bool = false) -> Quad? {
        let finite = polygon.filter {
            $0.x.isFinite && $0.y.isFinite
        }
        guard finite.count == polygon.count, finite.count >= 2 else {
            return nil
        }
        if finite.count == 4 {
            guard let p = useProvidedOrder ? finite : NativeOCRScopeGeometry.canonicalQuad(finite) else { return nil }
            let quad = Quad(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3])
            guard abs(signedArea(quad)) > 0.5 else { return nil }
            return quad
        }

        guard let minimumX = finite.map(\.x).min(),
              let maximumX = finite.map(\.x).max(),
              let minimumY = finite.map(\.y).min(),
              let maximumY = finite.map(\.y).max(),
              maximumX - minimumX > 1,
              maximumY - minimumY > 1
        else {
            return nil
        }
        return Quad(
            topLeft: CGPoint(x: minimumX, y: minimumY),
            topRight: CGPoint(x: maximumX, y: minimumY),
            bottomRight: CGPoint(x: maximumX, y: maximumY),
            bottomLeft: CGPoint(x: minimumX, y: maximumY)
        )
    }

    private static func makeHomography(_ quad: Quad) -> Homography? {
        let x0 = Double(quad.topLeft.x)
        let y0 = Double(quad.topLeft.y)
        let x1 = Double(quad.topRight.x)
        let y1 = Double(quad.topRight.y)
        let x2 = Double(quad.bottomRight.x)
        let y2 = Double(quad.bottomRight.y)
        let x3 = Double(quad.bottomLeft.x)
        let y3 = Double(quad.bottomLeft.y)
        let dx1 = x1 - x2
        let dx2 = x3 - x2
        let dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2
        let dy2 = y3 - y2
        let dy3 = y0 - y1 + y2 - y3
        let g: Double
        let h: Double
        if abs(dx3) < 0.000_000_1, abs(dy3) < 0.000_000_1 {
            g = 0
            h = 0
        } else {
            let denominator = dx1 * dy2 - dx2 * dy1
            guard abs(denominator) > 0.000_000_1 else { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / denominator
            h = (dx1 * dy3 - dx3 * dy1) / denominator
        }
        let homography = Homography(
            a: x1 - x0 + g * x1,
            b: x3 - x0 + h * x3,
            c: x0,
            d: y1 - y0 + g * y1,
            e: y3 - y0 + h * y3,
            f: y0,
            g: g,
            h: h
        )
        let values = [
            homography.a, homography.b, homography.c,
            homography.d, homography.e, homography.f,
            homography.g, homography.h,
        ]
        return values.allSatisfy(\.isFinite) ? homography : nil
    }

    private static func signedArea(_ quad: Quad) -> Double {
        let points = [
            quad.topLeft, quad.topRight,
            quad.bottomRight, quad.bottomLeft,
        ]
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += Double(points[index].x * next.y - next.x * points[index].y)
        }
        return area * 0.5
    }

    private static func distance(_ left: CGPoint, _ right: CGPoint) -> Double {
        hypot(Double(right.x - left.x), Double(right.y - left.y))
    }

    private struct SampledRGBA {
        let red: Double
        let green: Double
        let blue: Double
    }

    private static func sampleBilinear(
        frame: NativeOCRRGBAFrame,
        at point: CGPoint
    ) -> SampledRGBA {
        let x = min(max(Double(point.x), 0), Double(frame.width - 1))
        let y = min(max(Double(point.y), 0), Double(frame.height - 1))
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = min(x0 + 1, frame.width - 1)
        let y1 = min(y0 + 1, frame.height - 1)
        let xWeight = x - Double(x0)
        let yWeight = y - Double(y0)

        func channel(_ x: Int, _ y: Int, _ offset: Int) -> Double {
            Double(frame.bytes[y * frame.bytesPerRow + x * 4 + offset])
        }
        func interpolate(_ offset: Int) -> Double {
            let top = channel(x0, y0, offset) * (1 - xWeight)
                + channel(x1, y0, offset) * xWeight
            let bottom = channel(x0, y1, offset) * (1 - xWeight)
                + channel(x1, y1, offset) * xWeight
            return top * (1 - yWeight) + bottom * yWeight
        }
        return SampledRGBA(
            red: interpolate(0),
            green: interpolate(1),
            blue: interpolate(2)
        )
    }

    private static func normalize(_ channel: Double) -> Float {
        Float(channel / 127.5 - 1)
    }
}
