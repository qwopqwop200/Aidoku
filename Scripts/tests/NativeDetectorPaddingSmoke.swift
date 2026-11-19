import Foundation

@main
enum NativeDetectorPaddingSmoke {
    static func main() throws {
        let cases = [(1, 1, 1, 1), (1, 1, 32, 32), (7, 13, 32, 32),
                     (31, 32, 32, 32), (32, 31, 32, 32), (32, 32, 32, 32),
                     (37, 53, 64, 64), (700, 1_000, 704, 1_024),
                     (64, 513, 64, 544), (513, 64, 544, 64)]
        var verifiedScalars = 0
        for (width, height, canvasWidth, canvasHeight) in cases {
            let rowStride = width * 4 + 13
            let bytes = (0..<(height * rowStride)).map { UInt8(truncatingIfNeeded: $0 &* 97 &+ 31) }
            let frame = NativeOCRRGBAFrame(width: width, height: height, bytesPerRow: rowStride, bytes: bytes)
            // Include identity and fractional interpolation on both axes;
            // last cells also exercise clamped source edges.
            let xs = (0..<width).map { ($0, min(width - 1, $0 + 1), Float($0 % 7) / 7) }
            let ys = (0..<height).map { ($0, min(height - 1, $0 + 1), Float($0 % 11) / 11) }
            let plane = canvasWidth * canvasHeight
            // NaN-filled storage proves every padding cell is written.
            var actual = [Float](repeating: .nan, count: plane * 3)
            try actual.withUnsafeMutableBufferPointer { output in
                try NativeCoreMLDetectionPreprocessor.fillBoundedInput(
                    frame: frame, canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                    width: width, height: height, sourceXs: xs, sourceYs: ys, into: output.baseAddress!)
            }
            var expected = [Float](repeating: 0, count: plane * 3)
            let means: [Float] = [0.485, 0.456, 0.406]
            let deviations: [Float] = [0.229, 0.224, 0.225]
            for channel in 0..<3 { for y in 0..<height { for x in 0..<width {
                let (x0, x1, fx) = xs[x], (y0, y1, fy) = ys[y]
                let a = Float(bytes[y0 * rowStride + x0 * 4 + 2 - channel])
                let b = Float(bytes[y0 * rowStride + x1 * 4 + 2 - channel])
                let c = Float(bytes[y1 * rowStride + x0 * 4 + 2 - channel])
                let d = Float(bytes[y1 * rowStride + x1 * 4 + 2 - channel])
                let pixel = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
                expected[channel * plane + y * canvasWidth + x] = (pixel / 255 - means[channel]) / deviations[channel]
            } } }
            precondition(zip(actual, expected).allSatisfy { $0.bitPattern == $1.bitPattern }, "Input bit mismatch")
            verifiedScalars += actual.count
            if height > 256 {
                struct Stop: Error {}
                var checks = 0
                do {
                    try actual.withUnsafeMutableBufferPointer { output in
                        try NativeCoreMLDetectionPreprocessor.fillBoundedInput(
                            frame: frame, canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                            width: width, height: height, sourceXs: xs, sourceYs: ys, into: output.baseAddress!,
                            cancellationCheck: { checks += 1; if checks == 2 { throw Stop() } })
                    }
                    fatalError("Cancellation was ignored")
                } catch is Stop { precondition(checks == 2) }
            }
        }
        print("{\"passed\":true,\"cases\":\(cases.count),\"verifiedScalars\":\(verifiedScalars)}")
    }
}
