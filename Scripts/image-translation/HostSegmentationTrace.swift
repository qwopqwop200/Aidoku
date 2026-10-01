import Foundation
import CoreGraphics
import ImageIO

/// Persist actual native restoration patches and their alpha coverage for the analysis viewer.
/// Coverage is not an inferred glyph mask: the record states which native paint image it describes.
enum HostSegmentationTrace {
    static func save(rendered: NativeTranslationRenderer.Result, diagnostics: Any, source: CGImage,
                     sourceRect: CGRect, directory: URL) throws {
        let diagnostics = diagnostics as? [String: Any] ?? [:]
        let initial = diagnostics["initialPatches"] as? [[String: Any]] ?? []
        let folderName = "analysis/segmentation/" + UUID().uuidString
        let folder = directory.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var captures: [[String: Any]] = []
        var remainingPixels = 16_000_000
        var dropped = 0

        func capture(_ image: CGImage, frame: CGRect, phase: String, evidence: [String: Any]) throws {
            try Task.checkCancellation()
            let width = image.width, height = image.height
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, pixels > 0, width <= 8_192, height <= 8_192,
                  pixels <= remainingPixels, captures.count < 64 else { dropped += 1; return }
            remainingPixels -= pixels
            let index = captures.count + 1
            let size = CGSize(width: width, height: height)
            let bounds = CGRect(origin: .zero, size: size)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw HostError.message("Cannot allocate native repair diagnostic")
            }
            context.draw(image, in: bounds)
            guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw HostError.message("Missing native repair pixels") }
            var alphaData = Data(count: pixels)
            let selected = alphaData.withUnsafeMutableBytes { storage -> Int in
                let alpha = storage.bindMemory(to: UInt8.self)
                var selected = 0
                for index in 0..<pixels {
                    let value = bytes[index * 4 + 3]
                    alpha[index] = value
                    if value > 0 { selected += 1 }
                }
                return selected
            }
            guard let provider = CGDataProvider(data: alphaData as CFData), let mask = CGImage(width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw HostError.message("Cannot create native repair alpha")
            }
            func saveImage(_ image: CGImage, field: String) throws -> String {
                let name = String(format: "%03d-", index) + field + ".png"
                try HostAnalysis.encodePNG(image, to: folder.appendingPathComponent(name))
                return folderName + "/" + name
            }
            var entry: [String: Any] = ["function": "NativeTranslationRestoration", "kind": "native-repair-alpha",
                "phase": phase, "width": width, "height": height, "box": [frame.minX, frame.minY, frame.width, frame.height],
                "status": "captured", "selectedPixels": selected, "evidence": evidence,
                "mask": try saveImage(mask, field: "alpha"), "patch": try saveImage(image, field: "patch")]
            if frame.width > 0, frame.height > 0, sourceRect.width > 0, sourceRect.height > 0 {
                // Draw the page in crop-local coordinates without rounding or clipping away repair margins.
                context.clear(bounds)
                let imageFrame = CGRect(x: (sourceRect.minX - frame.minX) * size.width / frame.width,
                    y: (frame.maxY - sourceRect.maxY) * size.height / frame.height,
                    width: sourceRect.width * size.width / frame.width, height: sourceRect.height * size.height / frame.height)
                context.draw(source, in: imageFrame)
                guard let original = context.makeImage() else { throw HostError.message("Cannot capture native repair source") }
                entry["source"] = try saveImage(original, field: "source")
                context.draw(image, in: bounds)
                guard let repaired = context.makeImage() else { throw HostError.message("Cannot capture native repaired surface") }
                entry["repaired"] = try saveImage(repaired, field: "repaired")
                context.clear(bounds)
                context.draw(original, in: bounds)
                context.saveGState()
                context.clip(to: bounds, mask: mask)
                context.setFillColor(CGColor(red: 1, green: 0.16, blue: 0.43, alpha: 0.59))
                context.fill(bounds)
                context.restoreGState()
                if let overlay = context.makeImage() { entry["overlay"] = try saveImage(overlay, field: "overlay") }
            }
            captures.append(entry)
        }

        for record in initial {
            guard let encoded = record["png"] as? String, encoded.hasPrefix("data:image/png;base64,"),
                  let data = Data(base64Encoded: String(encoded.dropFirst("data:image/png;base64,".count))),
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  let frame = HostAnalysis.rect(record["frame"]) else {
                dropped += 1
                continue
            }
            var evidence = record
            evidence.removeValue(forKey: "png")
            try capture(image, frame: frame, phase: "initial-restoration", evidence: evidence)
        }
        for patch in rendered.sourcePatches {
            try capture(patch.image, frame: patch.rect, phase: "final-export",
                evidence: ["cleanupClip": patch.cleanupClip.map(HostAnalysis.boxArray) as Any? ?? NSNull()])
        }
        HostDump.capture("segmentation-trace", ["engine": "native-coretext-coregraphics", "captures": captures,
            "dropped": dropped, "captureFailures": diagnostics["initialPatchCaptureFailures"] ?? [],
            "initialPatchCaptureFailures": diagnostics["initialPatchCaptureFailures"] ?? [],
            "finalPatchCaptureFailures": diagnostics["finalPatchCaptureFailures"] ?? []])
    }
}
