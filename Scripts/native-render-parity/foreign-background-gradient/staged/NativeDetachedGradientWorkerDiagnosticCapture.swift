import Testing
import UIKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Same immutable controls as actual59. UIKit is used only by the main caller
/// for screen/resource metadata. The worker's tree and paint path use QuartzCore/Metal only.
@MainActor
struct NativeDetachedGradientWorkerDiagnosticCapture {
    private nonisolated struct Control: Sendable {
        let name: String; let rgb: [Double]; let pngHash: String; let rgbaHash: String
    }
    private enum Failure: Error { case invalidReference, invalidPNG, invalidPixels }
    private let controls = [
        Control(name: "Red", rgb: [220,30,40],
            pngHash: "69c5b246bf9de9411b672ade31734ff40b51f3de75c8048453815a603e25cfa2",
            rgbaHash: "29045ce6342433fdecb081015541f72b07e7866c2d7ce422c59d05de51affe74"),
        Control(name: "Blue", rgb: [30,40,220],
            pngHash: "3b16591e1f92895287587f73ed5ca958a2c2acc99866ad2a6d17c1a4a7cacbb5",
            rgbaHash: "1944e325538ee83e06d277308f472f45c4c388b4c5fda79324d2ccd3a0a25e54")
    ]

    func run() async throws {
        let output = URL.documentsDirectory.appendingPathComponent("NativeDetachedGradientWorkerDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try write(["expectedCount": 2, "count": 0, "passed": false, "reports": []], to: output.appendingPathComponent("report.json"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let scale = scene.screen.scale
        guard scale == 3 else { throw Failure.invalidReference }
        let bundle = Bundle(for: DetachedWorkerFixtureBundle.self)
        var reports: [[String: Any]] = [], failures: [String] = []
        for control in controls {
            let folder = output.appendingPathComponent(control.name.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                let url = try #require(bundle.url(forResource: "NativeGradientActual56" + control.name, withExtension: "bin"))
                let encoded = try Data(contentsOf: url)
                let image = try #require(UIImage(data: encoded)?.cgImage)
                let reference = try pixels(image)
                let valid = hash(encoded) == control.pngHash && hash(reference) == control.rgbaHash &&
                    image.width == 960 && image.height == 480
                let provenance: [String: Any] = ["immutableReference": "same actual56 WK and actual59 detached gradient buffers",
                    "PNGHash": hash(encoded), "expectedPNGHash": control.pngHash, "RGBAHash": hash(reference),
                    "expectedRGBAHash": control.rgbaHash, "sourceValid": valid, "screenScale": scale,
                    "sourceRGB": control.rgb, "pageCSS": [320,160], "sourceFrameCSS": [20,20,96,96]]
                try write(provenance, to: folder.appendingPathComponent("reference-provenance.json"))
                #expect(valid)
                guard valid else { throw Failure.invalidReference }
                try encoded.write(to: folder.appendingPathComponent("web-reference.png"))
                try reference.write(to: folder.appendingPathComponent("web-reference.rgba"))
                let data = try await renderWorker(control: control, reference: reference, scale: scale, folder: folder)
                let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                reports.append(record)
                let checks = try #require(record["guards"] as? [String: Bool])
                #expect(checks.values.allSatisfy { $0 })
                if !checks.values.allSatisfy({ $0 }) { failures.append(control.name + ": source/thread/geometry/pixel guard failed") }
            } catch { failures.append(control.name + ": " + String(describing: error)) }
        }
        try write(["expectedCount": 2, "count": reports.count, "passed": reports.count == 2 && failures.isEmpty,
            "scope": "same two integer opaque gradients on a private off-main Thread; exact immutable reference comparison",
            "reports": reports, "failures": failures, "noFreshWebOracle": true, "noWindowOrView": true],
            to: output.appendingPathComponent("report.json"))
        #expect(reports.count == 2 && failures.isEmpty)
    }

    private func renderWorker(control: Control, reference: Data, scale: CGFloat, folder: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    let result = try NativeDetachedGradientWorkerScene.capture(rgb: control.rgb, scale: scale)
                    // Save raw output before any acceptance. No UIKit API is called in this worker.
                    try result.canonicalRGBA.write(to: folder.appendingPathComponent("native-worker.rgba"))
                    let data = NSMutableData()
                    guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                        throw NativeDetachedWorkerMetalCapture.Failure.image
                    }
                    CGImageDestinationAddImage(encoder, result.image, nil)
                    guard CGImageDestinationFinalize(encoder) else { throw NativeDetachedWorkerMetalCapture.Failure.image }
                    try (data as Data).write(to: folder.appendingPathComponent("native-worker.png"))
                    let checks = ["offMainThread": !Thread.isMainThread,
                        "privateTreeCreatedOffMain": result.metadata["privateTreeCreatedOnMainThread"] as? Bool == false,
                        "rootModelRestored": result.metadata["rootModelRestored"] as? Bool == true,
                        "dimensions": result.width == 960 && result.height == 480,
                        "opaque": result.canonicalRGBA.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 },
                        "exactImmutableReferenceRGBA": result.canonicalRGBA == reference]
                    let digest = SHA256.hash(data: result.canonicalRGBA).map { String(format: "%02x", $0) }.joined()
                    let record: [String: Any] = ["scene": control.name.lowercased(), "width": result.width, "height": result.height,
                        "RGBAHash": digest, "sourceRGB": control.rgb, "guards": checks, "renderer": result.metadata,
                        "actualThreadName": Thread.current.name ?? "nil", "actualThreadIsMain": Thread.isMainThread,
                        "cancellationPolicy": "cooperative Thread.isCancelled admission and post-GPU checks; no GPU preemption claim"]
                    let serialized = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys,.prettyPrinted])
                    try serialized.write(to: folder.appendingPathComponent("capture.json"), options: .atomic)
                    continuation.resume(returning: serialized)
                } catch { continuation.resume(throwing: error) }
            }
            thread.name = "Detached gradient private-tree diagnostic"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        let pointer = try #require(context.data)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: pointer, count: image.width * image.height * 4)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined() }
    private func write(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.prettyPrinted]).write(to: url, options: .atomic)
    }
}
private final class DetachedWorkerFixtureBundle: NSObject {}
