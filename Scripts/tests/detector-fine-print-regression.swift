import CoreGraphics
import Foundation

// Compile this focused native test with NativeCoreMLDBPostprocessor.swift.
// The detector itself imports Core ML; this identical value type keeps the
// standalone geometry test independent of model loading and shared CLI caches.
struct NativeCoreMLDetectionBox: Equatable, Sendable {
    let polygon: [CGPoint]
    let score: Double
    let erasurePolygons: [[CGPoint]]
    let recognitionPolygon: [CGPoint]?
    let isThinFinePrintRecovery: Bool
    let finePrintRetryPolygons: [[CGPoint]]
    init(polygon: [CGPoint], score: Double, erasurePolygons: [[CGPoint]] = [],
         recognitionPolygon: [CGPoint]? = nil, isThinFinePrintRecovery: Bool = false,
         finePrintRetryPolygons: [[CGPoint]] = []) {
        self.polygon = polygon
        self.score = score
        self.erasurePolygons = erasurePolygons
        self.recognitionPolygon = recognitionPolygon
        self.isThinFinePrintRecovery = isThinFinePrintRecovery
        self.finePrintRetryPolygons = finePrintRetryPolygons
    }
}

@main
struct DetectorFinePrintRegression {
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func fill(_ values: inout [Float], width: Int, x: Int, y: Int, w: Int, h: Int, score: Float) {
        for row in y..<(y + h) { for column in x..<(x + w) { values[row * width + column] = score } }
    }

    static func decode(_ map: NativeCoreMLDetectionMap, enabled: Bool = true, minimum: Double = 3,
                       maximum: Int = 3_000, geometry: NativeCoreMLDetectionMapGeometry? = nil,
                       sourceWidth: Int = 300, sourceHeight: Int = 240) throws -> NativeCoreMLDBPostprocessResult {
        try NativeCoreMLDBPostprocessor.decode(
            map: map, sourceWidth: sourceWidth, sourceHeight: sourceHeight, geometry: geometry,
            configuration: .init(threshold: 0.3, boxThreshold: 0.3, unclipRatio: 1.5,
                                 maximumCandidates: maximum, minimumBoxSide: minimum),
            allowsThinFinePrintRecovery: enabled
        )
    }

    static func fixture(thinScore: Float = 0.7, neighbor: Bool = true, vertical: Bool = false, thinWidth: Int = 16) -> NativeCoreMLDetectionMap {
        var values = [Float](repeating: 0, count: 100 * 80)
        if neighbor { fill(&values, width: 100, x: 10, y: 10, w: 24, h: 8, score: 0.9) }
        fill(&values, width: 100, x: 14, y: 29, w: vertical ? 2 : thinWidth, h: vertical ? 16 : 2, score: thinScore)
        return .init(width: 100, height: 80, values: values)
    }

    static func main() throws {
        let map = fixture()
        let original = try decode(map, enabled: false)
        let recovered = try decode(map)
        check(original.boxes.count == 1 && recovered.boxes.count == 2, "supported tiny label recovers once")
        check(recovered.boxes.contains(original.boxes[0]), "ordinary detector box remains exact")
        check(recovered.candidateComponents == original.candidateComponents, "component accounting unchanged")
        let thin = recovered.boxes.first { !original.boxes.contains($0) }!
        let height = thin.polygon.map(\.y).max()! - thin.polygon.map(\.y).min()!
        check(height == 15, "five map rows cover tiny source ink")
        check(thin.isThinFinePrintRecovery, "map-supported provenance reaches recovery box")
        let context = thin.recognitionPolygon!
        let ownedWidth = thin.polygon.map(\.x).max()! - thin.polygon.map(\.x).min()!
        let sampledWidth = context.map(\.x).max()! - context.map(\.x).min()!
        check(sampledWidth > ownedWidth && sampledWidth - ownedWidth == 12,
              "two extra map pixels per long side belong only to sampling")
        let narrow = try decode(fixture(thinWidth: 8)).boxes.first { $0.isThinFinePrintRecovery }!
        check(narrow.recognitionPolygon == nil, "correct narrow labels retain original sampling crop")
        check(thin.finePrintRetryPolygons.isEmpty && narrow.finePrintRetryPolygons.count == 2,
              "only narrow map-validated labels carry two empty-read retry contexts")
        let narrowWidth = narrow.polygon.map(\.x).max()! - narrow.polygon.map(\.x).min()!
        let retryWidth = narrow.finePrintRetryPolygons[0].map(\.x).max()!
            - narrow.finePrintRetryPolygons[0].map(\.x).min()!
        check(retryWidth - narrowWidth == 12, "retry contexts preserve exact detector-map scale")
        let supported = try NativeCoreMLDBPostprocessor.addingErasureSupport(
            map: map, boxes: recovered.boxes, sourceWidth: 300, sourceHeight: 240)
        let supportedThin = supported.first { $0.isThinFinePrintRecovery }!
        check(supportedThin.recognitionPolygon == context && supportedThin.polygon == thin.polygon
            && supportedThin.finePrintRetryPolygons == thin.finePrintRetryPolygons,
              "erasure support preserves sampling metadata and detector ownership")
        let stripped = recovered.boxes.map { NativeCoreMLDetectionBox(polygon: $0.polygon, score: $0.score) }
        let withoutContext = try NativeCoreMLDBPostprocessor.addingErasureSupport(
            map: map, boxes: stripped, sourceWidth: 300, sourceHeight: 240)
        check(zip(supported, withoutContext).allSatisfy { $0.erasurePolygons == $1.erasurePolygons },
              "sampling context cannot enlarge erasure evidence")
        check(try decode(fixture(neighbor: false)).boxes.isEmpty, "no independent isolated noise recovery")
        check(try decode(fixture(thinScore: 0.4)).boxes.count == 1, "low score cannot use relaxed geometry")
        check(try decode(fixture(vertical: true)).boxes.count == 1, "thin vertical rule cannot use fine print gate")
        check(try decode(map, minimum: 4).boxes == decode(map, enabled: false, minimum: 4).boxes,
              "custom minimum size remains authoritative")
        check(try decode(map, maximum: 1).boxes == decode(map, enabled: false, maximum: 1).boxes,
              "candidate budget remains authoritative")
        check(try decode(map, sourceWidth: 100, sourceHeight: 80).boxes.count == 1,
              "unscaled tiny source has no fine print bypass")
        var local: [Float] = []
        for y in 5..<55 { local += Array(map.values[(y * 100 + 5)..<(y * 100 + 65)]) }
        let cropped = NativeCoreMLDetectionMap(width: 60, height: 50, values: local)
        check(try decode(cropped, geometry: .init(originX: 5, originY: 5, fullWidth: 100, fullHeight: 80)) == recovered,
              "dirty map ROI recovery matches full map exactly")
        var many = [Float](repeating: 0, count: 100 * 300)
        for index in 0..<10 {
            fill(&many, width: 100, x: 10, y: index * 29 + 2, w: 24, h: 8, score: 0.9)
            fill(&many, width: 100, x: 14, y: index * 29 + 21, w: 16, h: 2, score: 0.7)
        }
        let bounded = try decode(.init(width: 100, height: 300, values: many), sourceWidth: 300, sourceHeight: 900)
        check(bounded.boxes.count == 18, "at most eight fine print additions per page")
        var cancelled = false
        do {
            _ = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 300, sourceHeight: 240,
                                                       allowsThinFinePrintRecovery: true,
                                                       cancellationCheck: { throw CancellationError() })
        } catch is CancellationError { cancelled = true }
        check(cancelled, "cancellation propagates")
        print("PASS detector fine print regression: recovery, preservation, false-positive gates, limits, ROI and cancellation")
        if CommandLine.arguments.count > 1 { try auditSavedRun(CommandLine.arguments[1]) }
    }

    static func auditSavedRun(_ path: String) throws {
        let root = URL(fileURLWithPath: path)
        var additions: [(String, [CGPoint])] = []
        var pages = 0
        let benchmark = CommandLine.arguments.contains("--benchmark")
        var disabledMilliseconds = 0.0, enabledMilliseconds = 0.0
        let singleFlag: Bool? = CommandLine.arguments.contains("--baseline-only") ? false
            : (CommandLine.arguments.contains("--recovery-only") ? true : nil)
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard let metadata = files.first(where: { $0.lastPathComponent.hasSuffix("detector-probability-map.json") }),
                  let input = files.first(where: { $0.lastPathComponent == "001-input.json" }) else { continue }
            let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Any]
            let info = meta["value"] as! [String: Any]
            let inputInfo = (try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any])["value"] as! [String: Any]
            let data = try Data(contentsOf: folder.appendingPathComponent(info["raw"] as! String))
            let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let map = NativeCoreMLDetectionMap(width: info["width"] as! Int, height: info["height"] as! Int, values: values)
            let sw = inputInfo["width"] as! Int, sh = inputInfo["height"] as! Int
            if let singleFlag {
                let start = ProcessInfo.processInfo.systemUptime
                _ = try decode(map, enabled: singleFlag, sourceWidth: sw, sourceHeight: sh)
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                if singleFlag { enabledMilliseconds += elapsed } else { disabledMilliseconds += elapsed }
                pages += 1
                continue
            }
            let before = try decode(map, enabled: false, sourceWidth: sw, sourceHeight: sh)
            let after = try decode(map, sourceWidth: sw, sourceHeight: sh)
            if benchmark {
                // Warm-up above is excluded. Alternate order per page/pass so
                // map cache warmth and CPU scheduling do not favor one flag.
                for pass in 0..<3 {
                    for enabled in (pages + pass).isMultiple(of: 2) ? [false, true] : [true, false] {
                        let start = ProcessInfo.processInfo.systemUptime
                        let result = try decode(map, enabled: enabled, sourceWidth: sw, sourceHeight: sh)
                        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                        check(result == (enabled ? after : before), "benchmark decode drift")
                        if enabled { enabledMilliseconds += elapsed } else { disabledMilliseconds += elapsed }
                    }
                }
            }
            check(before.boxes.allSatisfy(after.boxes.contains), "saved-run original boxes changed")
            for box in after.boxes where !before.boxes.contains(box) {
                additions.append((folder.lastPathComponent, box.polygon))
                let centerX = Int(box.polygon.map(\.x).reduce(0, +) / 4 * CGFloat(map.width) / CGFloat(sw))
                let centerY = Int(box.polygon.map(\.y).reduce(0, +) / 4 * CGFloat(map.height) / CGFloat(sh))
                let x0 = max(0, centerX - 100), y0 = max(0, centerY - 100)
                let x1 = min(map.width, centerX + 100), y1 = min(map.height, centerY + 100)
                var local: [Float] = []
                for y in y0..<y1 { local += Array(values[(y * map.width + x0)..<(y * map.width + x1)]) }
                let roi = NativeCoreMLDetectionMap(width: x1 - x0, height: y1 - y0, values: local)
                let localResult = try decode(roi, geometry: .init(originX: x0, originY: y0,
                    fullWidth: map.width, fullHeight: map.height), sourceWidth: sw, sourceHeight: sh)
                check(localResult.boxes.contains(box), "saved-candidate dirty ROI polygon or score drift")
            }
            pages += 1
        }
        if let singleFlag {
            print("RSS comparison saved maps: \(pages); recovery flag: \(singleFlag); total decode ms: \(singleFlag ? enabledMilliseconds : disabledMilliseconds)")
            return
        }
        print("Saved maps: \(pages); added fine print boxes: \(additions.count); all added-box ROI checks passed")
        for (page, polygon) in additions { print("\(page): \(polygon)") }
        if benchmark {
            let samples = Double(pages * 3)
            print("Timed decode samples per flag: \(Int(samples)); disabled total ms: \(disabledMilliseconds); enabled total ms: \(enabledMilliseconds)")
            print("Mean disabled ms/page: \(disabledMilliseconds / samples); enabled ms/page: \(enabledMilliseconds / samples)")
        }
    }
}
