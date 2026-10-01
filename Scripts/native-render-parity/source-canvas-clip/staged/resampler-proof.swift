import CoreGraphics
import Foundation

func image(_ bytes: Data, _ width: Int, _ height: Int) -> CGImage {
    CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw NSError(domain: label, code: 1) }
    print("PASS \(label)")
}
func crop(_ data: Data, width: Int, rect: CGRect) -> Data {
    var output = Data()
    for row in Int(rect.minY)..<Int(rect.maxY) {
        output.append(data[((row * width + Int(rect.minX)) * 4)..<((row * width + Int(rect.maxX)) * 4)])
    }
    return output
}
@main struct Proof {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
        var comparisons: [[String: Any]] = []
        for scene in ["original-six", "negative-global", "negative-global-half"] {
            let directory = root.appendingPathComponent(scene)
            let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("web-dom-and-saved-masks.json"))) as! [String: Any]
            let session = NativeCanvasTextureResampler.Session()
            var canvas = Data(repeating: 255, count: 1920 * 3000 * 4)
            for record in doc["records"] as! [[String: Any]] {
                let id = record["id"] as! String, used = record["used"] as! [Double]
                let left = Int(floor(used[0] + 0.5) * 3), top = Int(floor(used[1] + 0.5) * 3)
                let width = Int((floor(used[0] + used[2] + 0.5) - floor(used[0] + 0.5)) * 3)
                let height = Int((floor(used[1] + used[3] + 0.5) - floor(used[1] + 0.5)) * 3)
                guard width > 0, height > 0 else { continue }
                let source = image(try Data(contentsOf: directory.appendingPathComponent("source-\(id).rgba")), 20, 20)
                let visible = CGRect(x: max(0, -left), y: max(0, -top), width: min(1920, left + width) - max(0, left), height: min(3000, top + height) - max(0, top))
                guard visible.width > 0, visible.height > 0 else { continue }
                let tile = try NativeCanvasTextureResampler.canvasImage(image: source, destinationPixels: CGSize(width: width, height: height), cropPixels: visible, session: session)
                let data = bytes(tile)
                for row in 0..<tile.height {
                    let target = ((max(0, top) + row) * 1920 + max(0, left)) * 4
                    canvas.replaceSubrange(target..<(target + tile.width * 4), with: data[(row * tile.width * 4)..<((row + 1) * tile.width * 4)])
                }
            }
            try check(canvas == Data(contentsOf: directory.appendingPathComponent("web-live-640.rgba")), "\(scene) full RGBA native-DPR3")
            let small = try NativeCanvasTextureResampler.resample(image: image(canvas, 1920, 3000), outputPixelSize: CGSize(width: 960, height: 1500))
            try check(bytes(small) == Data(contentsOf: directory.appendingPathComponent("web-live-320.rgba")), "\(scene) full RGBA capture reduction")
            session.close()
            comparisons.append(["scene": scene, "nativeDPR3Exact": true, "captureReductionExact": true])
        }
        var alpha = Data(count: 16 * 12 * 4)
        for i in 0..<(16 * 12) {
            let a = [0, 64, 128, 255][i % 4]
            alpha[i * 4] = UInt8((i * 23 % 256) * a / 255); alpha[i * 4 + 1] = UInt8((i * 41 % 256) * a / 255)
            alpha[i * 4 + 2] = UInt8((i * 11 % 256) * a / 255); alpha[i * 4 + 3] = UInt8(a)
        }
        let alphaImage = image(alpha, 16, 12), size = CGSize(width: 173, height: 91)
        try check(bytes(NativeCanvasTextureResampler.resample(image: alphaImage, outputPixelSize: CGSize(width: 16, height: 12))) == alpha, "premultiplied alpha identity")
        let full = try NativeCanvasTextureResampler.resample(image: alphaImage, outputPixelSize: size)
        let fullBytes = bytes(full)
        var bounded = true
        for i in stride(from: 0, to: fullBytes.count, by: 4) {
            let a = fullBytes[i + 3]
            bounded = bounded && fullBytes[i] <= a && fullBytes[i + 1] <= a && fullBytes[i + 2] <= a
        }
        try check(bounded, "premultiplied alpha bounds after filtering")
        let rects = [CGRect(x: 0, y: 0, width: 11, height: 17), CGRect(x: 63, y: 27, width: 71, height: 47), CGRect(x: 170, y: 88, width: 3, height: 3)]
        for (index, rect) in rects.enumerated() {
            let tile = try NativeCanvasTextureResampler.canvasImage(image: alphaImage, destinationPixels: size, cropPixels: rect)
            try check(bytes(tile) == crop(fullBytes, width: full.width, rect: rect), "alpha tile \(index) retains full UV")
        }
        let tiny = try NativeCanvasTextureResampler.canvasImage(image: alphaImage, destinationPixels: CGSize(width: 16384, height: 16384), cropPixels: CGRect(x: 16000, y: 16000, width: 8, height: 8))
        try check(tiny.width == 8 && tiny.height == 8 && bytes(tiny).count == 256, "large offscreen destination allocates only visible tile")
        let session = NativeCanvasTextureResampler.Session()
        let cached = try NativeCanvasTextureResampler.resample(image: alphaImage, outputPixelSize: size, session: session)
        try check(bytes(cached) == fullBytes, "page session preserves filtered bytes")
        session.close()
        do { _ = try NativeCanvasTextureResampler.resample(image: alphaImage, outputPixelSize: size, session: session); throw NSError(domain: "closed session repopulated", code: 1) }
        catch NativeCanvasTextureResampler.Failure.closedSession { print("PASS closed page session rejects reuse") }
        let cancellation = Task.detached { () throws -> CGImage in
            while !Task.isCancelled { await Task.yield() }
            return try NativeCanvasTextureResampler.resample(image: alphaImage, outputPixelSize: size)
        }
        cancellation.cancel()
        do { _ = try await cancellation.value; throw NSError(domain: "cancellation did not throw", code: 1) }
        catch is CancellationError { print("PASS cancelled operation does not publish image") }
        let record: [String: Any] = ["comparisons": comparisons, "alphaScope": "PMA8 identity, channel bounds and exact full/tile equivalence only; no semi-transparent WK over-composition claim", "pixelGate": "zero tolerance", "sourceCapPixels": NativeCanvasTextureResampler.maximumPixels, "largeDestination": [16384, 16384], "allocatedOutput": [8, 8]]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
}
