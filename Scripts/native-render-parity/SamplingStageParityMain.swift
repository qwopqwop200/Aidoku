import CoreGraphics
import Foundation

@main
struct SamplingStageParityMain {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let fixtures = try JSONSerialization.jsonObject(with: input) as! [[String: Any]]
        var output: [[String: Any]] = []
        for fixture in fixtures {
            let width = fixture["width"] as! Int, height = fixture["height"] as! Int
            let rgba = (fixture["rgba"] as! [NSNumber]).map { $0.uint8Value }
            let provider = CGDataProvider(data: Data(rgba) as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            let budgetValues = fixture["budget"] as! [String: Int]
            let budget = NativeSourceColorSamplingStage.Budget(pixels: budgetValues["pixels"]!, detailPixels: budgetValues["detailPixels"]!,
                remainingSamples: budgetValues["remainingSamples"])
            let reader = NativeSourcePixelReader(image: image)
            defer { reader.release() }
            var stages: [String: NativeSourceColorSamplingStage] = [:]
            var queries: [[String: Any]] = []
            for query in fixture["queries"] as! [[String: Any]] {
                let phase = query["phase"] as? String ?? "ocr"
                let stage = stages[phase] ?? NativeSourceColorSamplingStage(image: image, enabled: fixture["enabled"] as? Bool ?? true,
                    phase: phase, budget: budget, pixelReader: reader)
                stages[phase] = stage
                let bounds = (query["bounds"] as! [NSNumber]).map(\.doubleValue)
                let result = stage.sample(bounds: bounds, geometry: query["geometry"] as? [String: Any])
                queries.append(["result": result as Any? ?? NSNull(), "stats": ["pixels": stage.stats.pixels,
                    "hits": stage.stats.hits, "samples": stage.stats.samples],
                    "budget": ["pixels": budget.pixels, "detailPixels": budget.detailPixels,
                        "remainingSamples": budget.remainingSamples as Any? ?? NSNull()]])
            }
            output.append(["name": fixture["name"]!, "queries": queries])
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
