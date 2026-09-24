//
//  MultiArrayModel.swift
//  Aidoku
//

import CoreML
import CoreGraphics

/// RGB NCHW models whose output has already cropped `shrinkSize` source pixels on each side.
final class MultiArrayModel: ImageProcessingModel {
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let blockSize: Int
    private let shrinkSize: Int
    private let scale: Int
    private let grayscaleOnly: Bool
    private let exactReuse: ReaderUpscaleCanonicalReuse?

    // Protocol/custom model construction does not opt into deterministic reuse.
    required convenience init?(model: MLModel, config: [String: Any]) {
        self.init(model: model, config: config, allowsExactReuse: false)
    }

    init?(model: MLModel, config: [String: Any], allowsExactReuse: Bool) {
        let block = config["blockSize"] as? Int ?? 256
        let shrink = config["shrinkSize"] as? Int ?? 0
        let scale = config["scale"] as? Int ?? 2
        let inputName = config["inputName"] as? String ?? "input"
        let outputName = config["outputName"] as? String ?? "output"
        guard (1...1024).contains(block), shrink >= 0, shrink < (block + 1) / 2,
              (1...4).contains(scale) else { return nil }
        let expectedInput = [1, 3, block, block]
        let outputSize = (block - 2 * shrink) * scale
        let expectedOutput = [1, 3, outputSize, outputSize]
        guard (config["shape"] as? [Int] ?? expectedInput) == expectedInput,
              let input = model.modelDescription.inputDescriptionsByName[inputName]?.multiArrayConstraint,
              let output = model.modelDescription.outputDescriptionsByName[outputName]?.multiArrayConstraint,
              input.dataType == .float32, output.dataType == .float32,
              input.shape.map(\.intValue) == expectedInput,
              (output.shape.isEmpty || output.shape.map(\.intValue) == expectedOutput) else { return nil }
        self.model = model
        self.inputName = inputName
        self.outputName = outputName
        self.blockSize = block
        self.shrinkSize = shrink
        self.scale = scale
        self.grayscaleOnly = config["grayscaleOnly"] as? Bool ?? false
        self.exactReuse = allowsExactReuse ? ReaderUpscaleCanonicalReuse() : nil
    }

    func process(_ image: CGImage) async -> CGImage? {
        let width = image.width
        let height = image.height
        // Cap the output bitmap at 256 MiB before allocating buffers; keep the original on failure.
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 67_108_864 / (scale * scale), !Task.isCancelled else { return nil }
        let outputWidth = width * scale
        let outputHeight = height * scale
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo
            ) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        if grayscaleOnly {
            // Even small colored panels must retain their color; tolerate only JPEG/chroma rounding.
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                if max(red, green, blue) - min(red, green, blue) > 8 { return image }
            }
        }
        var reuseKey: ReaderUpscaleCanonicalReuse.Key?
        if let exactReuse {
            guard !Task.isCancelled else { return nil }
            reuseKey = pixels.withUnsafeBytes {
                ReaderUpscaleCanonicalReuse.key(bytes: $0, width: width, height: height)
            }
            guard !Task.isCancelled else { return nil }
            if let reuseKey, let reused = exactReuse.image(for: reuseKey) {
                guard !Task.isCancelled else { return nil }
                ReaderTranslationDiagnostics.renderingProfile("upscale_model_weak_hit")
                return reused
            }
        }
        // Count actual inference passes after completed-result lookup, not calls
        // that only normalize/hash and reuse already-owned exact output pixels.
        let profileID = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        ReaderTranslationDiagnostics.renderingProfile("upscale_model_begin", count: width * height, revision: profileID)
        var inferenceSucceeded = false
        defer {
            ReaderTranslationDiagnostics.renderingProfile("upscale_model_end", count: inferenceSucceeded ? 1 : 0, revision: profileID)
        }
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: blockSize), NSNumber(value: blockSize)], dataType: .float32),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)]) else { return nil }
        let inputPointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        let inputStrides = input.strides.map(\.intValue)
        let coreSize = blockSize - 2 * shrinkSize
        let outputTileSize = coreSize * scale
        var result = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)

        // One reusable input and one prediction at a time. Tiles write disjoint output rectangles.
        // Clamp padding to the edge, including when the entire image is smaller than one tile.
        for originY in stride(from: 0, to: height, by: coreSize) {
            for originX in stride(from: 0, to: width, by: coreSize) {
                guard !Task.isCancelled else { return nil }
                for y in 0..<blockSize {
                    let sourceY = min(max(originY + y - shrinkSize, 0), height - 1)
                    for x in 0..<blockSize {
                        let sourceX = min(max(originX + x - shrinkSize, 0), width - 1)
                        let source = (sourceY * width + sourceX) * 4
                        for channel in 0..<3 {
                            inputPointer[channel * inputStrides[1] + y * inputStrides[2] + x * inputStrides[3]] =
                                Float(pixels[source + channel]) / 255
                        }
                    }
                }
                let succeeded: Bool = autoreleasepool {
                    guard let prediction = try? model.prediction(from: provider),
                          let output = prediction.featureValue(for: outputName)?.multiArrayValue,
                          output.dataType == .float32,
                          output.shape.map(\.intValue) == [1, 3, outputTileSize, outputTileSize] else { return false }
                    let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
                    let strides = output.strides.map(\.intValue)
                    let copyWidth = min(coreSize, width - originX) * scale
                    let copyHeight = min(coreSize, height - originY) * scale
                    for y in 0..<copyHeight {
                        for x in 0..<copyWidth {
                            let target = ((originY * scale + y) * outputWidth + originX * scale + x) * 4
                            for channel in 0..<3 {
                                let value = pointer[channel * strides[1] + y * strides[2] + x * strides[3]]
                                guard value.isFinite else { return false }
                                result[target + channel] = UInt8((min(max(value, 0), 1) * 255).rounded())
                            }
                        }
                    }
                    return true
                }
                guard succeeded else { return nil }
            }
        }
        guard let provider = CGDataProvider(data: Data(result) as CFData) else { return nil }
        let output = CGImage(
            width: outputWidth, height: outputHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: outputWidth * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
        inferenceSucceeded = output != nil
        if let output, let reuseKey, !Task.isCancelled {
            exactReuse?.store(output, for: reuseKey)
        }
        return output
    }
}
