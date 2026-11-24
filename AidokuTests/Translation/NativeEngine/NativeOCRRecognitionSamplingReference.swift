import CoreGraphics
import Foundation
@testable import Aidoku

/// Frozen scalar sampler: shares the production crop plan but evaluates the homography,
/// bilinear reads and normalization independently, in the original operation order.
enum NativeOCRRecognitionSamplingReference {
    static func prepare(frame: NativeOCRRGBAFrame, polygon: [CGPoint]) -> NativeCoreMLPreparedTensor? {
        guard let plan = NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon) else { return nil }
        let targetHeight = NativeCoreMLRecognitionPreprocessor.targetHeight
        let targetWidth = plan.bucket.width
        let planeSize = targetHeight * targetWidth
        let homography = plan.homography
        var values = [Float](repeating: 0, count: planeSize * 3)
        for row in 0..<targetHeight {
            for column in 0..<plan.resizedWidth {
                let orientedX = (Double(column) + 0.5) * Double(plan.orientedWidth) / Double(plan.resizedWidth) - 0.5
                let orientedY = (Double(row) + 0.5) * Double(plan.orientedHeight) / Double(targetHeight) - 0.5
                let warpedX = plan.rotatedCounterClockwise ? Double(plan.cropWidth - 1) - orientedY : orientedX
                let warpedY = plan.rotatedCounterClockwise ? orientedX : orientedY
                let u = min(max(warpedX / Double(plan.cropWidth), 0), 1)
                let v = min(max(warpedY / Double(plan.cropHeight), 0), 1)
                let denominator = homography.g * u + homography.h * v + 1
                guard denominator.isFinite, abs(denominator) > 0.000_000_1 else { return nil }
                let x = min(max((homography.a * u + homography.b * v + homography.c) / denominator, 0),
                            Double(frame.width - 1))
                let y = min(max((homography.d * u + homography.e * v + homography.f) / denominator, 0),
                            Double(frame.height - 1))
                let x0 = Int(floor(x)), y0 = Int(floor(y))
                let x1 = min(x0 + 1, frame.width - 1), y1 = min(y0 + 1, frame.height - 1)
                let xWeight = x - Double(x0), yWeight = y - Double(y0)
                func channel(_ x: Int, _ y: Int, _ offset: Int) -> Double {
                    Double(frame.bytes[y * frame.bytesPerRow + x * 4 + offset])
                }
                func normalized(_ offset: Int) -> Float {
                    let top = channel(x0, y0, offset) * (1 - xWeight) + channel(x1, y0, offset) * xWeight
                    let bottom = channel(x0, y1, offset) * (1 - xWeight) + channel(x1, y1, offset) * xWeight
                    return Float((top * (1 - yWeight) + bottom * yWeight) / 127.5 - 1)
                }
                let destination = row * targetWidth + column
                values[destination] = normalized(2)
                values[planeSize + destination] = normalized(1)
                values[planeSize * 2 + destination] = normalized(0)
            }
        }
        return NativeCoreMLPreparedTensor(values: values, resizedWidth: plan.resizedWidth, bucket: plan.bucket,
                                          rotatedCounterClockwise: plan.rotatedCounterClockwise)
    }
}
