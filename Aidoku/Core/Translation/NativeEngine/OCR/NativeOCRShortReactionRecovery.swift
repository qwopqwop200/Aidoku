import CoreGraphics
import Foundation
import Vision

/// A second reader for short vertical reactions that the primary recognizer rejected.
/// It cannot replace accepted text or lower the primary confidence threshold.
@available(iOS 18.0, *)
enum NativeOCRShortReactionRecovery {
    static func recover(frame: NativeOCRRGBAFrame, failed: [NativeCoreMLRecognitionRegion],
                        accepted: [NativeCoreMLRecognizedRegion]) throws -> [NativeCoreMLRecognizedRegion] {
        guard accepted.contains(where: { $0.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) } })
        else { return [] }
        let occupied = accepted.compactMap { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
        var recovered: [NativeCoreMLRecognizedRegion] = [], attempts = 0, pixels = 0
        for region in failed {
            try Task.checkCancellation()
            guard attempts < 4, let box = NativeOCRScopeGeometry.bounds(for: region.polygon),
                  box.width >= 12, box.height >= box.width * 2.5, box.height <= box.width * 12,
                  box.width * box.height <= 65_536,
                  !occupied.contains(where: { NativeOCRScopeGeometry.intersectionArea($0, box) > box.width * box.height * 0.1 })
            else { continue }
            let crop = box.insetBy(dx: -box.width * 0.25, dy: -box.width * 0.25)
                .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height)).integral
            let width = Int(crop.width), height = Int(crop.height)
            guard width > 0, height > 0, pixels + width * height <= 131_072 else { continue }
            pixels += width * height; attempts += 1
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                let source = (Int(crop.minY) + y) * frame.bytesPerRow + Int(crop.minX) * 4
                rgba.replaceSubrange(y * width * 4..<(y + 1) * width * 4, with: frame.bytes[source..<source + width * 4])
            }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { continue }
            let dotCount = repeatedDotCount(rgba, width: width, height: height, columnWidth: box.width)
            guard dotCount >= 4 else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP"]
            request.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: image).perform([request]) }
            catch { try Task.checkCancellation(); continue }
            try Task.checkCancellation()
            let reads = (request.results ?? []).compactMap { $0.topCandidates(1).first }
            // Vision's Japanese punctuation reads use a coarse 0.3 confidence
            // bucket. Independent repeated-dot geometry is required above;
            // this confidence is never applied to ordinary prose.
            guard (1...3).contains(reads.count), reads.allSatisfy({ $0.confidence >= 0.3 }) else { continue }
            let text = reads.map(\.string).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let kana = text.unicodeScalars.filter { $0.properties.isAlphabetic && (0x3040...0x30FF).contains($0.value) }
            guard (1...12).contains(text.count), (1...2).contains(kana.count),
                  text.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) ||
                    CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespaces.contains($0) || $0.value == 0x25CF }) else { continue }
            recovered.append(.init(sourceIndex: region.sourceIndex, polygon: region.polygon,
                                   text: preservingLeadingDots(text, count: dotCount), confidence: Double(reads.map(\.confidence).min() ?? 0)))
        }
        return recovered
    }
    static func hasRepeatedDots(_ rgba: [UInt8], width: Int, height: Int, columnWidth: CGFloat) -> Bool {
        repeatedDotCount(rgba, width: width, height: height, columnWidth: columnWidth) >= 4
    }

    /// Only restores leading punctuation already read as dots; kana remains the recognizer's result.
    static func preservingLeadingDots(_ text: String, count: Int) -> String {
        let dots: Set<Character> = ["●", "・", "·", ".", "…", "⋮", "︙"]
        let prefix = text.prefix { dots.contains($0) }
        guard !prefix.isEmpty, count >= 4, count <= 24 else { return text }
        return String(repeating: "…", count: count / 3) + String(repeating: "・", count: count % 3) + text.dropFirst(prefix.count)
    }

    static func repeatedDotCount(_ rgba: [UInt8], width: Int, height: Int, columnWidth: CGFloat) -> Int {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return 0 }
        var ink = [Bool](repeating: false, count: width * height)
        for i in ink.indices {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            ink[i] = max(r, g, b) < 110 || max(r, g, b) - min(r, g, b) > 70 && (r * 3 + g * 6 + b) / 10 < 180
        }
        var dots: [(x: Double, y: Double, size: Double)] = []
        for start in ink.indices where ink[start] {
            var queue = [start], head = 0, l = width, r = 0, t = height, b = 0
            ink[start] = false
            while head < queue.count {
                let i = queue[head], x = i % width, y = i / width; head += 1
                l = min(l, x); r = max(r, x); t = min(t, y); b = max(b, y)
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) where ink[yy * width + xx] {
                        ink[yy * width + xx] = false; queue.append(yy * width + xx)
                    }
                }
            }
            let w = r - l + 1, h = b - t + 1
            if l > 1 && t > 1 && r < width - 2 && b < height - 2 && min(w, h) >= 3 &&
                Double(max(w, h)) <= Double(columnWidth) * 0.35 && Double(max(w, h)) <= Double(min(w, h)) * 1.6 &&
                Double(queue.count) >= Double(w * h) * 0.5 {
                dots.append((Double(l + r) / 2, Double(t + b) / 2, sqrt(Double(w * h))))
            }
        }
        guard dots.count <= 24 else { return 0 }
        var longest = 0
        for seed in dots {
            let run = dots.filter { abs($0.x - seed.x) <= Double(columnWidth) * 0.12 &&
                $0.size >= seed.size * 0.7 && $0.size <= seed.size * 1.4 }.sorted { $0.y < $1.y }
            guard run.count >= 4 else { continue }
            let gaps = zip(run, run.dropFirst()).map { $1.y - $0.y }
            let median = gaps.sorted()[gaps.count / 2]
            guard median >= seed.size * 1.2, median <= seed.size * 3 else { continue }
            // The exclamation point below the reaction has another circular
            // dot; it must not invalidate the preceding regular ellipsis.
            var consecutive = 1
            for gap in gaps {
                consecutive = gap >= median * 0.65 && gap <= median * 1.4 ? consecutive + 1 : 1
                longest = max(longest, consecutive)
            }
        }
        return longest >= 4 ? longest : 0
    }

}
