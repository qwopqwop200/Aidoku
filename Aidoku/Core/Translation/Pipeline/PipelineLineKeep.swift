import CoreGraphics
import Foundation

/// S3 line-keep gate after the confidence cut: a LightGBM forest (Resources/Translation/PipelineLineKeep.json, fit on
/// TRAIN pages against GT line boxes) over the read, the line geometry, page context and S1 region coverage. A line
/// below the file's threshold (lossless on train under page, size and chunk folds) is not text and is dropped.
/// Trees as flat arrays: `x[f] <= split` goes left, a node with `left < 0` is a leaf; p = sigmoid(sum of leaves).
struct PipelineLineKeep: Decodable, Sendable {
    let features: [String]
    let threshold: Double
    let roots: [Int]
    let feature: [Int]
    let split: [Double]
    let left: [Int]
    let right: [Int]
    let value: [Double]

    static let shared: PipelineLineKeep? = {
        var urls = [Bundle.main.url(forResource: "PipelineLineKeep", withExtension: "json")].compactMap { $0 }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/PipelineLineKeep.json"))
        }
        return urls.lazy.compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(PipelineLineKeep.self, from: $0) }.first
    }()

    func probability(_ x: [Double]) -> Double {
        var z = 0.0
        for root in roots {
            var node = root
            while left[node] >= 0 { node = x[feature[node]] <= split[node] ? left[node] : right[node] }
            z += value[node]
        }
        return 1 / (1 + exp(-z))
    }

    /// The lines the gate keeps, in input order (all of them without the model file).
    static func filter(_ lines: [PipelineLine], layout: [PipelineLayoutRegion], pageSize: CGSize) -> [PipelineLine] {
        let scale = PipelineTuning.current.lineKeepScale
        guard let model = shared, !lines.isEmpty, scale > 0 else { return lines }
        let rows = features(lines, layout: layout, pageSize: pageSize)
        let threshold = scale == 1 ? model.threshold : model.threshold * scale
        return zip(lines, rows).compactMap { model.probability($1) >= threshold ? $0 : nil }
    }

    // MARK: features (order of `features` in the JSON; Python reference Scripts/pipeline/tools/retrain/linekeep/features.py)

    private static let space: Set<UInt32> = [0x20, 0x3000, 0x09, 0x0A, 0x0D]
    private static let punctuation: Set<UInt32> = [
        0x21, 0x28, 0x29, 0x2C, 0x2D, 0x2E, 0x3F, 0x7E, 0x2015, 0x2026, 0x2605, 0x2606, 0x2661, 0x2665, 0x3001, 0x3002,
        0x300C, 0x300D, 0x300E, 0x300F, 0x301C, 0x30FB, 0x30FC, 0xFF01, 0xFF08, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1F
    ]

    /// Non-space scalar count, then kana, kanji, Latin, digit, other, punctuation, longest run and distinct shares,
    /// and whether any kana or kanji is present.
    static func textFeatures(_ text: String) -> [Double] {
        let s = text.unicodeScalars.map(\.value).filter { !space.contains($0) }
        let n = Double(s.count), d = max(n, 1)
        func count(_ test: (UInt32) -> Bool) -> Double { Double(s.lazy.filter(test).count) }
        let kana = count { (0x3040...0x30FF).contains($0) || (0xFF66...0xFF9D).contains($0) }
        let kanji = count { (0x3400...0x9FFF).contains($0) || (0xF900...0xFAFF).contains($0) }
        let latin = count {
            (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || (0xFF21...0xFF3A).contains($0) || (0xFF41...0xFF5A).contains($0)
        }
        let digit = count { (0x30...0x39).contains($0) || (0xFF10...0xFF19).contains($0) }
        let punct = count { punctuation.contains($0) }
        var run = 1, best = s.isEmpty ? 0 : 1
        for i in s.indices.dropFirst() {
            run = s[i] == s[i - 1] ? run + 1 : 1
            best = max(best, run)
        }
        return [n, kana / d, kanji / d, latin / d, digit / d, (n - kana - kanji - latin - digit) / d, punct / d,
                Double(best) / d, Double(Set(s).count) / d, kana + kanji > 0 ? 1 : 0]
    }

    private struct Box {
        let x0, y0, x1, y1: Double
        init(_ r: CGRect) { x0 = r.minX; y0 = r.minY; x1 = r.maxX; y1 = r.maxY }
        var area: Double { max(0, x1 - x0) * max(0, y1 - y0) }
        func inter(_ o: Box) -> Double { max(0, min(x1, o.x1) - max(x0, o.x0)) * max(0, min(y1, o.y1) - max(y0, o.y0)) }
        /// Share of this box inside `o`.
        func covered(by o: Box) -> Double { area > 0 ? inter(o) / area : 0 }
        func iou(_ o: Box) -> Double {
            let i = inter(o), u = area + o.area - i
            return u > 0 ? i / u : 0
        }
    }

    static func features(_ lines: [PipelineLine], layout: [PipelineLayoutRegion], pageSize: CGSize) -> [[Double]] {
        let width = Double(pageSize.width), height = Double(pageSize.height), side = max(width, height)
        let boxes = lines.map { Box($0.bounds) }
        let thickness = zip(lines, boxes).map { $0.vertical ? $1.x1 - $1.x0 : $1.y1 - $1.y0 }
        let confident = zip(lines, thickness).filter { Double($0.0.confidence) >= 0.6 }.map { $0.1 }.sorted()
        let pageThickness = confident.isEmpty ? 1
            : confident.count % 2 == 1 ? confident[confident.count / 2]
            : (confident[confident.count / 2 - 1] + confident[confident.count / 2]) / 2
        let regions = [PipelineLayoutKind.text, .balloon, .sfx, .frame].map { kind in
            layout.filter { $0.kind == kind }.map { (Box($0.bounds), Double($0.score)) }
        }
        return lines.indices.map { i in
            let line = lines[i], b = boxes[i], w = b.x1 - b.x0, h = b.y1 - b.y0
            let t = thickness[i], length = line.vertical ? h : w, clamped = max(t, 1)
            let text = textFeatures(line.text)
            var row = [Double(line.detectionScore), Double(line.confidence), text[0] / max(length / clamped, 0.3)] + text
            for kind in regions {
                row.append(kind.map { b.covered(by: $0.0) * $0.1 }.reduce(0, max))
                row.append(kind.map { b.covered(by: $0.0) }.reduce(0, max))
            }
            let cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2
            var overlap = 0.0, inside = 0.0, neighbours = 0
            for j in lines.indices where j != i {
                let o = boxes[j]
                overlap = max(overlap, b.iou(o))
                if lines[j].confidence > line.confidence { inside = max(inside, b.covered(by: o)) }
                if abs((o.x0 + o.x1) / 2 - cx) < 3 * clamped + w / 2, abs((o.y0 + o.y1) / 2 - cy) < 3 * clamped + h / 2 {
                    neighbours += 1
                }
            }
            row += [t / side, length / side, length / clamped, w * h / (width * height), line.vertical ? 1 : 0,
                    t / max(pageThickness, 1), cx / width, cy / height,
                    min(b.x0, width - b.x1, b.y0, height - b.y1) / side, overlap, inside, Double(neighbours), Double(lines.count)]
            return row
        }
    }
}
