import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Output identity between the optimized pixel kernels and their former
/// implementations, kept verbatim below as test-only oracles.
struct ReaderTranslationPixelKernelIdentityTests {
    @Test(arguments: 0..<6)
    func outlinedInkMatchesFormerDictionaryImplementation(seed: Int) throws {
        let (image, columns) = Self.scene(seed: UInt64(seed), width: 420, height: 640)
        var generator = SceneRandom(seed: UInt64(seed) &* 7 &+ 3)
        var compared = 0, sampled = 0
        let random = (0..<160).map { _ in
            CGRect(x: generator.next(in: -20...400), y: generator.next(in: -20...600),
                   width: generator.next(in: 2...140), height: generator.next(in: 8...420))
        }
        for rect in columns + random {
            let actual = ReaderTranslationBalloonMerger.outlinedInk(in: image, rect: rect)
            let reference = FormerOutlinedInk.candidates(in: image, rect: rect)
            compared += 1
            if actual != nil { sampled += 1 }
            if reference.count <= 1 {
                // A unique maximal bin (or none): exactly the former result.
                #expect(Self.same(actual, reference.first ?? nil), "rect \(rect)")
            } else {
                // Former tie order depended on the Dictionary hash seed; the new
                // result must still be one of the tied former outcomes.
                #expect(reference.contains { Self.same(actual, $0) }, "rect \(rect)")
            }
        }
        #expect(compared == columns.count + 160)
        #expect(sampled > 0)
    }

    @Test(arguments: 0..<6)
    func enclosedBackgroundFloodMatchesFormerImplementation(seed: Int) throws {
        let (image, columns) = Self.scene(seed: UInt64(seed) &+ 100, width: 480, height: 720)
        var generator = SceneRandom(seed: UInt64(seed) &* 13 &+ 5)
        let size = CGSize(width: image.width, height: image.height)
        var nonEmpty = 0
        for round in 0..<12 {
            let random = (0..<Int(generator.next(in: 1...12))).map { _ in
                CGRect(x: generator.next(in: 0...440), y: generator.next(in: 0...680),
                       width: generator.next(in: 3...60), height: generator.next(in: 6...160))
            }
            let rects = round.isMultiple(of: 3) ? random : columns + random
            let inputs = rects.enumerated().map { index, rect in
                ReaderTranslationEnclosedBackground.Input(id: "c\(index)", text: "テキスト", rect: rect)
            }
            for alternate in [false, true] {
                for reuse in [false, true] {
                    let actual = ReaderTranslationEnclosedBackground.enclosedRegionGroups(in: image,
                        candidateInputs: inputs, coordinateSize: size,
                        checkingAlternateSeeds: alternate, reusingCompletedComponents: reuse)
                    let reference = FormerEnclosedBackground.enclosedRegionGroups(in: image,
                        candidateInputs: inputs, coordinateSize: size,
                        checkingAlternateSeeds: alternate, reusingCompletedComponents: reuse)
                    #expect(actual == reference)
                    if !actual.isEmpty { nonEmpty += 1 }
                }
            }
        }
        #expect(nonEmpty > 0)
    }

    @Test func languageDetectionCacheReturnsUncachedResults() {
        let samples = ["こんにちは", "안녕하세요", "这是一个简体中文句子", "這是一個繁體中文句子",
                       "Hello there, how are you doing today?", "Bonjour tout le monde, comment ça va",
                       "  ", "ABC", "漢字", "Hola amigos, ¿cómo están ustedes?"]
        for _ in 0..<2 {
            for text in samples {
                for hint in [nil, "ja", "zh", "zh-Hant", "en"] as [String?] {
                    #expect(AutomaticSourceLanguageDetector.detect(text, sourceHint: hint)
                        == AutomaticSourceLanguageDetector.detectUncached(text, sourceHint: hint))
                }
            }
        }
    }

    private static func same(_ a: (Double, Double, Double)?, _ b: (Double, Double, Double)?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.0.bitPattern == b.0.bitPattern && a.1.bitPattern == b.1.bitPattern
            && a.2.bitPattern == b.2.bitPattern
        default: false
        }
    }

    /// Noise background, outlined white balloons, and coloured lettering
    /// with white outlines (including equal-count colour pairs for ties).
    static func scene(seed: UInt64, width: Int, height: Int) -> (CGImage, [CGRect]) {
        var random = SceneRandom(seed: seed)
        var columns: [CGRect] = []
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            for y in stride(from: 0, to: height, by: 8) {
                for x in stride(from: 0, to: width, by: 8) {
                    UIColor(red: random.next(in: 0...1), green: random.next(in: 0...1),
                            blue: random.next(in: 0...1), alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
            for _ in 0..<7 {
                let balloon = CGRect(x: random.next(in: 0...360), y: random.next(in: 0...560),
                                     width: random.next(in: 40...160), height: random.next(in: 60...260))
                let path = UIBezierPath(ovalIn: balloon)
                UIColor.white.setFill(); path.fill()
                UIColor.black.setStroke(); path.lineWidth = random.next(in: 0...1) < 0.3 ? 0.5 : 3; path.stroke()
                let colours: [UIColor] = [.magenta, .orange, .red, .blue, .green, .cyan, .black]
                for column in 0..<Int(random.next(in: 1...4)) {
                    let colour = colours[Int(random.next(in: 0...6.99))]
                    let x = balloon.midX - 20 + CGFloat(column) * 14
                    columns.append(CGRect(x: x - 1, y: balloon.minY + 19, width: 11, height: max(12, balloon.height - 38)))
                    for y in stride(from: balloon.minY + 20, to: balloon.maxY - 20, by: 12) {
                        UIColor.white.setFill(); context.fill(CGRect(x: x, y: y, width: 9, height: 9))
                        colour.setFill(); context.fill(CGRect(x: x + 1, y: y + 1, width: 7, height: 7))
                    }
                }
            }
        }.cgImage!
        return (image, columns)
    }
}

struct SceneRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

/// The former `outlinedInk`, returning the outcome for every maximal bin.
private enum FormerOutlinedInk {
    static func candidates(in image: CGImage, rect: CGRect) -> [(Double, Double, Double)?] {
        guard let crop = image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) else { return [nil] }
        let w = min(96, crop.width), h = min(384, crop.height)
        guard w >= 4, h >= 16 else { return [nil] }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [nil] }
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int, rows: Set<Int>)] = [:]
        let offsets: [Int] = [-4, 4, -w * 4, w * 4]
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = (y * w + x) * 4
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                guard max(r, g, b) >= 110, max(r, g, b) - min(r, g, b) >= 65 else { continue }
                var whiteNeighbour = false
                for offset in offsets {
                    let neighbour = i + offset
                    if rgba[neighbour] >= 200 && rgba[neighbour + 1] >= 200 && rgba[neighbour + 2] >= 200 {
                        whiteNeighbour = true
                        break
                    }
                }
                guard whiteNeighbour else { continue }
                let key = (r / 64) * 16 + (g / 64) * 4 + b / 64
                var bin = bins[key] ?? (0, 0, 0, 0, [])
                bin.count += 1; bin.r += r; bin.g += g; bin.b += b; bin.rows.insert(y * 12 / h)
                bins[key] = bin
            }
        }
        guard let top = bins.values.map(\.count).max() else { return [nil] }
        return bins.values.filter { $0.count == top }.map { best -> (Double, Double, Double)? in
            guard best.count >= 24, best.rows.count >= 6 else { return nil }
            let r = Double(best.r) / Double(best.count), g = Double(best.g) / Double(best.count), b = Double(best.b) / Double(best.count)
            let low = min(r, g, b), chroma = max(r, g, b) - low
            guard chroma >= 65 else { return nil }
            return ((r - low) * 255 / chroma, (g - low) * 255 / chroma, (b - low) * 255 / chroma)
        }
    }
}

/// The former enclosed-background implementation (per-seed [Bool] floods).
private enum FormerEnclosedBackground {
    private struct Component {
        let count: Int
        let minimumPoint: Int
        let minX: Int, maxX: Int, minY: Int, maxY: Int
    }
    typealias Input = ReaderTranslationEnclosedBackground.Input
    static func enclosedRegionGroups(in image: CGImage,
                                     candidateInputs candidates: [Input],
                                     coordinateSize: CGSize, checkingAlternateSeeds: Bool = false,
                                     reusingCompletedComponents: Bool = true) -> [[String]] {
        guard coordinateSize.width > 0, coordinateSize.height > 0,
              coordinateSize.width.isFinite, coordinateSize.height.isFinite else { return [] }
        guard !candidates.isEmpty else { return [] }
        let scale = min(1, 512 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [] }
        var labels = [Int](repeating: -1, count: reusingCompletedComponents ? pixels.count : 0)
        var components: [Component] = []
        var groups: [Int: [String]] = [:]
        for input in candidates.prefix(64) {
            let rect = CGRect(x: input.rect.minX / coordinateSize.width * CGFloat(width),
                              y: input.rect.minY / coordinateSize.height * CGFloat(height),
                              width: input.rect.width / coordinateSize.width * CGFloat(width),
                              height: input.rect.height / coordinateSize.height * CGFloat(height))
            if let component = enclosed(rect, pixels: pixels, width: width, height: height, checkingAlternateSeeds: checkingAlternateSeeds, labels: &labels, components: &components) { groups[component, default: []].append(input.id) }
        }
        return groups.keys.sorted().map { groups[$0]! }
    }

    private static func enclosed(_ rect: CGRect, pixels: [UInt8], width: Int, height: Int, checkingAlternateSeeds: Bool, labels: inout [Int], components: inout [Component]) -> Int? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              rect.width > 0, rect.height > 0, rect.minX >= 0, rect.minY >= 0,
              rect.maxX < CGFloat(width), rect.maxY < CGFloat(height) else { return nil }
        let x0 = Int(floor(rect.minX)) - 2, y0 = Int(floor(rect.minY)) - 2
        let x1 = Int(ceil(rect.maxX)) + 2, y1 = Int(ceil(rect.maxY)) + 2
        guard x0 > 0, y0 > 0, x1 < width - 1, y1 < height - 1,
              x1 - x0 >= 6, y1 - y0 >= 6 else { return nil }
        var perimeter: [Int] = []
        for x in x0...x1 { perimeter.append(y0 * width + x); perimeter.append(y1 * width + x) }
        for y in (y0 + 1)..<y1 { perimeter.append(y * width + x0); perimeter.append(y * width + x1) }
        guard let seed = perimeter.first(where: { pixels[$0] >= 235 }) else { return nil }
        let middleX = (x0 + x1) / 2, middleY = (y0 + y1) / 2
        let seeds = checkingAlternateSeeds
            ? [seed, middleY * width + x0, middleY * width + x1,
               y0 * width + middleX, y1 * width + middleX] : [seed]
        var remaining = min(pixels.count / 3, max(256, (x1 - x0) * (y1 - y0) * 12))
        var attempted = Set<Int>()
        for seed in seeds where pixels[seed] >= 235 && !attempted.contains(seed) {
            guard remaining > 0 else { return nil }
            if !labels.isEmpty, labels[seed] >= 0 {
                let label = labels[seed], component = components[label]
                guard remaining >= component.count else { return nil }
                remaining -= component.count
                for candidate in seeds where labels[candidate] == label { attempted.insert(candidate) }
                guard perimeter.filter({ labels[$0] == label }).count * 5 >= perimeter.count * 4,
                      component.minX < x0, component.maxX > x1, component.minY < y0, component.maxY > y1,
                      component.maxX - component.minX < width * 3 / 4,
                      component.maxY - component.minY < height * 3 / 4 else { continue }
                return component.minimumPoint
            }
            var seen = [Bool](repeating: false, count: pixels.count)
            var queue = [seed]
            seen[seed] = true; remaining -= 1
            var cursor = 0, minX = width, maxX = 0, minY = height, maxY = 0
            var touchesEdge = false
            while cursor < queue.count {
                let point = queue[cursor]; cursor += 1
                let x = point % width, y = point / width
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { touchesEdge = true; break }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for next in [point - 1, point + 1, point - width, point + width] where !seen[next] && pixels[next] >= 235 {
                    guard remaining > 0 else { return nil }
                    remaining -= 1; seen[next] = true; queue.append(next)
                }
            }
            if !touchesEdge, !labels.isEmpty {
                let label = components.count
                components.append(Component(count: queue.count, minimumPoint: queue.min()!,
                    minX: minX, maxX: maxX, minY: minY, maxY: maxY))
                for point in queue { labels[point] = label }
            }
            for candidate in seeds where seen[candidate] { attempted.insert(candidate) }
            guard !touchesEdge,
                  perimeter.filter({ seen[$0] }).count * 5 >= perimeter.count * 4,
                  minX < x0, maxX > x1, minY < y0, maxY > y1,
                  maxX - minX < width * 3 / 4, maxY - minY < height * 3 / 4 else { continue }
            return queue.min()
        }
        return nil
    }
}
