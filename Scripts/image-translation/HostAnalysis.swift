import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import CryptoKit
import Darwin

/// Reads saved stage outputs; deliberately independent of the evolving app/OCR types.
enum HostAnalysis {
    // Successful reports may be reused only within one frozen pipeline invocation.
    final class GenerationReceipts {
        struct Receipt { let inputs: [String: String]; let outputs: [String: String] }
        private var receipts: [String: Receipt] = [:]
        private(set) var hits = 0
        private(set) var generations = 0
        private(set) var failures = 0
        private(set) var invalidations = 0
        private(set) var hashingCPU = 0.0
        static func hash(_ url: URL) throws -> String {
            try autoreleasepool {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                var hash = SHA256()
                while true {
                    let count = try autoreleasepool { () throws -> Int in
                        guard let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty else { return 0 }
                        hash.update(data: bytes); return bytes.count
                    }
                    if count == 0 { break }
                }
                return hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
        }
        static func cpu() -> Double {
            var r = rusage(); getrusage(RUSAGE_SELF, &r)
            return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1_000_000
        }
        static func inputs(_ page: URL, root: URL) throws -> [String: String] {
            var result: [String: String] = [:]
            let files = try HostAnalysis.stageFiles(in: page) + [page.appendingPathComponent("input.png")]
            for url in files { result[url.lastPathComponent] = try hash(url) }
            for name in ["final.png", "final.json", "quality-comparison.json"] {
                let url = page.appendingPathComponent(name)
                result[name] = FileManager.default.fileExists(atPath: url.path) ? try hash(url) : "ABSENT"
            }
            result.merge(HostAnalysis.pairedReportDependencies(page)) { _, new in new }
            result["$template"] = try hash(root.appendingPathComponent("Scripts/image-translation/analysis-template.html"))
            result["$root"] = root.standardizedFileURL.path
            // The session cannot outlive/change its compiled generator or loaded font frame.
            result["$generator"] = "invocation-local-compiled-frame-v1"
            return result
        }
        static func outputs(_ page: URL) throws -> [String: String] {
            let folder = page.appendingPathComponent("analysis")
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            var result: [String: String] = [:]
            for url in urls { result["analysis/" + url.lastPathComponent] = try hash(url) }
            for name in ["analysis.json", "analysis.html"] { result[name] = try hash(page.appendingPathComponent(name)) }
            return result
        }
        func generate(_ page: URL, root: URL, force: Bool = false) throws {
            let key = page.standardizedFileURL.path
            let start = Self.cpu()
            let before = try? Self.inputs(page, root: root)
            if !force, let old = receipts[key], let before, before == old.inputs,
               let outputs = try? Self.outputs(page), outputs == old.outputs {
                hashingCPU += Self.cpu() - start; hits += 1; return
            }
            hashingCPU += Self.cpu() - start
            if receipts.removeValue(forKey: key) != nil { invalidations += 1 }
            generations += 1
            do { try HostAnalysis.generate(imageDirectory: page, root: root) }
            catch { failures += 1; throw error }
            let endStart = Self.cpu()
            if let before, let after = try? Self.inputs(page, root: root), before == after,
               let outputs = try? Self.outputs(page) { receipts[key] = Receipt(inputs: after, outputs: outputs) }
            hashingCPU += Self.cpu() - endStart
        }
    }

    /// Publish only saved results; this lightweight index never reruns the pipeline.
    static func publishProgress(run: URL, inputs: [URL], summary: [[String: Any]], finished: Bool) throws {
        let failed = summary.filter { $0["status"] as? String == "failed" }.count
        let progress: [String: Any] = ["status": finished ? "finished" : "running", "total": inputs.count,
            "completed": summary.count, "succeeded": summary.count - failed, "failed": failed,
            "pending": inputs.count - summary.count, "updatedAt": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: run.appendingPathComponent("summary.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: progress, options: [.prettyPrinted, .sortedKeys])
            .write(to: run.appendingPathComponent("progress.json"), options: .atomic)
        let rows = Dictionary(uniqueKeysWithValues: summary.compactMap { row -> (String, [String: Any])? in
            guard let directory = row["directory"] as? String else { return nil }
            return (URL(fileURLWithPath: directory).lastPathComponent, row)
        })
        let cards = inputs.enumerated().map { index, input in
            let name = String(format: "%04d", index + 1), row = rows[name]
            let status = row?["status"] as? String ?? "pending"
            let preview = status == "success" && FileManager.default.fileExists(atPath: run.appendingPathComponent(name + "/final.png").path)
                ? "<a href=\"\(name)/final.html\"><img loading=\"lazy\" src=\"\(name)/final.png\"></a>" : ""
            let error = (row?["error"] as? String).map { "<p>\(escaped($0))</p>" } ?? ""
            let original = FileManager.default.fileExists(atPath: run.appendingPathComponent(name + "/input.png").path)
                ? "<details class=\"original\"><summary>원본 펼쳐 보기</summary><img loading=\"lazy\" src=\"\(name)/input.png\" alt=\"\(name) 원본\"></details>" : ""
            return """
            <article><h2>\(name) · \(escaped(status))</h2><p>\(escaped(input.lastPathComponent))</p>\(preview)\(original)
            <nav><a href="\(name)/input.png">원본</a> <a href="\(name)/ocr-boxes.png">OCR</a>
            <a href="\(name)/final.json">번역 JSON</a> <a href="\(name)/analysis.html">단계 분석</a></nav>\(error)</article>
            """
        }.joined()
        let refresh = "" // Result review refreshes only when the user requests it.
        let html = """
        <!doctype html><html lang="ko"><meta charset="utf-8">\(refresh)<title>이미지 번역 진행 상황</title>
        <style>body{font:16px system-ui;margin:32px;background:#101722;color:#eaf0f8}a{color:#a7d6ff}
        .grid{display:grid;grid-template-columns:minmax(0,1fr);gap:24px;max-width:1000px;margin:auto}
        article{padding:16px;background:#1b2635;border-radius:12px}h2{font-size:18px}p{overflow-wrap:anywhere}
        img{display:block;width:100%;height:auto;object-fit:contain}nav{display:flex;gap:12px;flex-wrap:wrap}
        details.original{margin:12px 0}details.original summary{cursor:pointer;padding:12px 0}</style>
        <h1>이미지 번역 진행 상황</h1><p>완료 \(summary.count)/\(inputs.count) · 성공 \(summary.count - failed) · 실패 \(failed)
        · \(finished ? "실행 종료" : "5초마다 자동 갱신")</p><p>중간 파일은 각 번호 폴더에 생성 즉시 저장됩니다.</p>
        <p><a href="summary.json">결과 요약</a> · <a href="progress.json">진행률 JSON</a> · <a href="analysis-index.html">전체 분석</a></p>
        <div class="grid">\(cards)</div></html>
        """
        try html.write(to: run.appendingPathComponent("progress.html"), atomically: true, encoding: .utf8)
    }
    enum AnalysisError: Error { case invalidImage, invalidRun, missingTemplate }
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    static func point(_ value: Any) -> CGPoint? {
        if let v = value as? [String: Any], let x = number(v["x"]), let y = number(v["y"]) { return CGPoint(x: x, y: y) }
        if let v = value as? [Any], v.count == 2, let x = number(v[0]), let y = number(v[1]) { return CGPoint(x: x, y: y) }
        return nil
    }
    static func rect(_ value: Any?) -> CGRect? {
        if let v = value as? [String: Any], let x = number(v["x"]), let y = number(v["y"]),
           let w = number(v["width"]), let h = number(v["height"]), w > 0, h > 0 {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        if let v = value as? [Any], v.count == 4, let x = number(v[0]), let y = number(v[1]),
           let w = number(v[2]), let h = number(v[3]), w > 0, h > 0 { return CGRect(x: x, y: y, width: w, height: h) }
        return nil
    }
    static func points(_ value: Any?) -> [CGPoint] { (value as? [Any] ?? []).compactMap(point) }
    static func bounds(_ points: [CGPoint]) -> CGRect? {
        guard let x = points.map(\.x).min(), let y = points.map(\.y).min(),
              let right = points.map(\.x).max(), let bottom = points.map(\.y).max(), right > x, bottom > y else { return nil }
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }
    static func boxArray(_ box: CGRect) -> [Double] { [box.minX, box.minY, box.width, box.height].map(Double.init) }
    static func polygonArray(_ polygon: [CGPoint]) -> [[Double]] { polygon.map { [Double($0.x), Double($0.y)] } }
    static func normalizedAngle(_ degrees: Double) -> Double {
        var value = degrees
        while value > 90 { value -= 180 }
        while value <= -90 { value += 180 }
        return value
    }
    static func axes(_ polygon: [CGPoint], direction: String, singleColumn: Bool) -> (Double?, Double?, Double?) {
        guard polygon.count >= 3 else { return (nil, nil, nil) }
        let edges = polygon.indices.map { i -> (length: Double, angle: Double) in
            let next = polygon[(i + 1) % polygon.count], start = polygon[i]
            return (hypot(next.x - start.x, next.y - start.y), normalizedAngle(atan2(next.y - start.y, next.x - start.x) * 180 / .pi))
        }.filter { $0.length > 0.1 }
        guard let longest = edges.max(by: { $0.length < $1.length }) else { return (nil, nil, nil) }
        let reading: Double
        if direction == "vertical" {
            reading = edges.max(by: { abs(sin($0.angle * .pi / 180)) < abs(sin($1.angle * .pi / 180)) })?.angle ?? longest.angle
        } else if direction == "horizontal" {
            reading = edges.max(by: { abs(cos($0.angle * .pi / 180)) < abs(cos($1.angle * .pi / 180)) })?.angle ?? longest.angle
        } else { reading = longest.angle }
        let reference = direction == "vertical" ? 90.0 : 0
        return (longest.angle, reading, normalizedAngle(reading - reference))
    }
    static func record(_ row: [String: Any], normalized: Bool, width: Double, height: Double,
                       index: Int, category: String) -> [String: Any]? {
        let transform: (CGPoint) -> CGPoint = { normalized ? CGPoint(x: $0.x * width, y: $0.y * height) : $0 }
        var polygon = points(row["polygon"] ?? row["poly"] ?? row["sourcePolygon"]).map(transform)
        let storedBox = rect(row["rect"] ?? row["sourceBounds"])
        let box = storedBox.map { normalized ? CGRect(x: $0.minX * width, y: $0.minY * height,
            width: $0.width * width, height: $0.height * height) : $0 } ?? bounds(polygon)
        guard let box else { return nil }
        if polygon.isEmpty {
            polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        }
        let rawDirection = row["sourceOrientation"] as? String ?? row["orientation"] as? String ?? "unknown"
        let direction = ["horizontal", "vertical"].contains(rawDirection) ? rawDirection : "unknown"
        let single = row["sourceSingleVerticalColumn"] as? Bool ?? row["singleVerticalColumn"] as? Bool ?? false
        let angles = axes(polygon, direction: direction, singleColumn: single)
        let inferred = row["orientationIsEstimated"] as? Bool ?? (direction == "unknown")
        var result: [String: Any] = ["id": row["id"] ?? "\(category)-\(row["sourceIndex"] ?? index)",
            "category": category, "polygon": polygonArray(polygon), "rect": boxArray(box),
            "text": row["source"] ?? row["text"] ?? "", "translation": row["translation"] ?? NSNull(),
            "confidence": number(row["confidence"] ?? row["score"]) as Any? ?? NSNull(),
            "direction": direction, "directionEstimated": inferred, "singleColumn": single,
            "longAxisDegrees": angles.0 as Any? ?? NSNull(),
            "readingAxisDegrees": direction == "unknown" ? NSNull() : (angles.1 as Any? ?? NSNull()),
            "tiltDegrees": direction == "unknown" ? NSNull() : (angles.2 as Any? ?? NSNull()), "raw": row]
        let coordinateScale: (CGRect) -> CGRect = { normalized ? CGRect(x: $0.minX * width, y: $0.minY * height,
            width: $0.width * width, height: $0.height * height) : $0 }
        result["auxiliaryRects"] = (row["auxiliaryInkRects"] as? [Any] ?? []).compactMap(rect).map(coordinateScale).map(boxArray)
        result["memberRects"] = (row["unitMemberRects"] as? [Any] ?? []).compactMap(rect).map(coordinateScale).map(boxArray)
        result["supportPolygons"] = (row["erasurePolygons"] as? [Any] ?? []).map { polygonArray(points($0).map(transform)) }
            + (row["auxiliaryInkPolygons"] as? [Any] ?? []).map { polygonArray(points($0).map(transform)) }
        if let interior = row["balloonInterior"] as? [String: Any], let paper = rect(interior["rect"]) {
            result["balloon"] = ["rect": boxArray(coordinateScale(paper)), "spans": interior["spans"] ?? [],
                "normalized": normalized, "members": interior["members"] ?? NSNull(), "verified": interior["contourVerified"] ?? false]
        }
        result["probabilityTiles"] = (row["detectionEvidence"] as? [[String: Any]] ?? []).compactMap { tile -> [String: Any]? in
            guard let box = rect(tile["rect"]), let w = number(tile["width"]), let h = number(tile["height"]),
                  w > 0, h > 0, w <= 4096, h <= 4096, let values = tile["probabilities"] as? [Any], values.count == Int(w * h) else { return nil }
            return ["rect": boxArray(coordinateScale(box)), "width": w, "height": h, "probabilities": values]
        }
        return result
    }
    /// Stage numbers have a minimum width, so 1000 must follow 999 on long or resumed runs.
    static func stageFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.first?.isNumber == true }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
    }
    // Retain the existing entry point for compiled callers and focused fixtures.
    static func stages(in directory: URL, width: Double, height: Double) throws -> [[String: Any]] {
        try stages(in: directory, width: width, height: height, inspect: nil)
    }
    static func stages(in directory: URL, width: Double, height: Double,
                       inspect: (([String: Any]) -> Void)?) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        let files = try stageFiles(in: directory)
        for file in files {
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let name = root["stage"] as? String else { continue }
            inspect?(root)
            let value = root["value"]
            var rows: [(String, [String: Any])] = []
            var normalized = true
            if name == "detector-output" {
                normalized = false
                rows = ((value as? [String: Any])?["boxes"] as? [[String: Any]] ?? []).map { ("detector", $0) }
            } else if name == "recognizer-output" {
                normalized = false
                rows = ((value as? [String: Any])?["regions"] as? [[String: Any]] ?? []).map { ("recognized", $0) }
            } else if ["native-ocr", "native-audit"].contains(name), let native = value as? [String: Any] {
                normalized = false
                for (key, category) in [("lines", "accepted"), ("recoveryCandidates", "recovery"), ("isolatedLines", "isolated"), ("splitLines", "split")] {
                    rows += (native[key] as? [[String: Any]] ?? []).map { (category, $0) }
                }
                rows += (native["gapLines"] as? [[String: Any]] ?? []).compactMap { row in
                    (row["line"] as? [String: Any]).map { ("gap", $0) }
                }
            } else if ["rejected-reads", "recovery-input"].contains(name) {
                normalized = false
                rows = (value as? [[String: Any]] ?? []).map { (name == "rejected-reads" ? "rejected" : "recovery", $0) }
            } else if let regions = value as? [[String: Any]], name.contains("group") || name.contains("regions")
                        || ["after-recovery", "balloon-interiors", "chromatic-grouping", "initial-grouping", "offline-translations"].contains(name) {
                rows = regions.map { ("grouped", $0) }
            } else { continue }
            let records = rows.enumerated().compactMap { record($0.element.1, normalized: normalized,
                width: width, height: height, index: $0.offset, category: $0.element.0) }
            result.append(["name": name, "source": file.lastPathComponent, "records": records])
        }
        return result
    }
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func encodePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw AnalysisError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AnalysisError.invalidImage }
    }
    static func color(_ category: String) -> CGColor {
        switch category {
        case "rejected": CGColor(red: 1, green: 0.22, blue: 0.28, alpha: 1)
        case "recovery", "gap", "isolated", "split": CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)
        case "detector": CGColor(red: 0.23, green: 0.63, blue: 1, alpha: 1)
        default: CGColor(red: 0.1, green: 0.85, blue: 0.62, alpha: 1)
        }
    }
    static func arrow(_ context: CGContext, start: CGPoint, angle: Double, length: Double) {
        let a = angle * .pi / 180, end = CGPoint(x: start.x + cos(a) * length, y: start.y + sin(a) * length)
        context.move(to: start); context.addLine(to: end)
        for delta in [-0.5, 0.5] { context.move(to: end); context.addLine(to: CGPoint(x: end.x - cos(a + delta) * 7, y: end.y - sin(a + delta) * 7)) }
        context.strokePath()
    }
    static func preview(_ image: CGImage, stage: [String: Any], to url: URL) throws {
        let scale = min(1, 1600 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AnalysisError.invalidImage }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        for (index, record) in (stage["records"] as? [[String: Any]] ?? []).enumerated() {
            let polygon = points(record["polygon"]).map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            let category = record["category"] as? String ?? "grouped"
            context.setStrokeColor(color(category)); context.setLineWidth(1.5)
            if let first = polygon.first { context.move(to: first); polygon.dropFirst().forEach { context.addLine(to: $0) }; context.closePath(); context.strokePath() }
            for support in record["supportPolygons"] as? [Any] ?? [] {
                let points = self.points(support).map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
                context.setFillColor(CGColor(red: 1, green: 0.48, blue: 0.08, alpha: 0.18))
                if let first = points.first { context.move(to: first); points.dropFirst().forEach { context.addLine(to: $0) }; context.closePath(); context.fillPath() }
            }
            guard let box = rect(record["rect"]) else { continue }
            let direction = record["direction"] as? String ?? "unknown"
            if var angle = number(record["readingAxisDegrees"]) {
                if direction == "vertical" && sin(angle * .pi / 180) < 0 { angle += 180 }
                if direction == "horizontal" && cos(angle * .pi / 180) < 0 { angle += 180 }
                context.setStrokeColor(color(category))
                arrow(context, start: CGPoint(x: box.midX * scale, y: box.midY * scale), angle: angle,
                    length: max(12, min(45, max(box.width, box.height) * scale * 0.35)))
            }
            let code = direction == "vertical" ? "V" : direction == "horizontal" ? "H" : "?"
            let angleLabel = number(record["tiltDegrees"]).map { String(format: "%+.1f°", $0) } ?? ""
            let label = "\(index + 1) \(code) \(angleLabel)"
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil)
            let attributed = NSAttributedString(string: label, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attributed)
            let length = CTLineGetTypographicBounds(line, nil, nil, nil)
            let x = min(max(0, box.minX * scale), max(0, Double(width) - length - 8)), y = max(12, box.minY * scale)
            context.setFillColor(CGColor(gray: 0.03, alpha: 0.85)); context.fill(CGRect(x: x, y: y - 12, width: length + 8, height: 15))
            context.saveGState(); context.translateBy(x: x + 4, y: y); context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero; CTLineDraw(line, context); context.restoreGState()
        }
        guard let output = context.makeImage() else { throw AnalysisError.invalidImage }
        try encodePNG(output, to: url)
    }
    static func generate(imageDirectory: URL, root: URL) throws {
        try autoreleasepool { try generatePooled(imageDirectory: imageDirectory, root: root) }
    }
    static func generate(imageDirectory: URL, root: URL, receipts: GenerationReceipts) throws {
        try receipts.generate(imageDirectory, root: root)
    }
    private static func generatePooled(imageDirectory: URL, root: URL) throws {
        let input = imageDirectory.appendingPathComponent("input.png")
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AnalysisError.invalidImage
        }
        let output = imageDirectory.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var metrics: [[String: Any]] = [], maps: [[String: Any]] = [], segmentation: [[String: Any]] = []
        // Read every stage once; consume only the small report metadata while its
        // decoded envelope is live, retaining no second page-wide diagnostic graph.
        var stages = try stages(in: imageDirectory, width: Double(image.width), height: Double(image.height)) { data in
            if let name = data["stage"] as? String {
                if name.contains("metric") || name.contains("phases") || name.contains("timing") { metrics.append(data) }
                if name == "native-render-diagnostics", let value = data["value"] as? [String: Any] {
                    metrics.append(["stage": name, "value": ["cards": (value["cards"] as? [Any])?.count ?? 0,
                        "initialPatches": (value["initialPatches"] as? [Any])?.count ?? 0,
                        "finalPatches": (value["finalPatches"] as? [Any])?.count ?? 0,
                        "captureFailures": value["initialPatchCaptureFailures"] ?? [],
                        "initialPatchCaptureFailures": value["initialPatchCaptureFailures"] ?? [],
                        "finalPatchCaptureFailures": value["finalPatchCaptureFailures"] ?? []]])
                }
                if name == "render-dom", let value = data["value"] as? [String: Any], let root = value["root"] as? [String: Any] {
                    metrics.append(["stage": "render-dom-root", "value": root])
                }
                if name == "detector-probability-map", let map = data["value"] as? [String: Any] { maps.append(map) }
                if name == "segmentation-trace", let trace = data["value"] as? [String: Any] { segmentation.append(trace) }
            }
        }
        // These fields are exactly the inputs painted by preview(). Text/confidence
        // stay in every stage's JSON even when their geometric preview is identical.
        let paintedKeys = ["polygon", "supportPolygons", "category", "rect", "direction", "readingAxisDegrees", "tiltDegrees"]
        var previews: [Data: URL] = [:]
        for index in stages.indices {
            let filename = String(format: "%02d-", index + 1) + (stages[index]["name"] as? String ?? "stage") + ".png"
            stages[index]["preview"] = "analysis/" + filename
            let destination = output.appendingPathComponent(filename)
            let records = (stages[index]["records"] as? [[String: Any]] ?? []).map { record in
                Dictionary(uniqueKeysWithValues: paintedKeys.compactMap { key in record[key].map { (key, $0) } })
            }
            let key = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
            // Unlink before any write: a previous report generation may have shared
            // this inode with another stage, which must never be overwritten through it.
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            if let original = previews[key] {
                do { try FileManager.default.linkItem(at: original, to: destination) }
                catch { try FileManager.default.copyItem(at: original, to: destination) }
            } else {
                try preview(image, stage: stages[index], to: destination)
                previews[key] = destination
            }
        }
        if let pair = pairedReportValue(imageDirectory) {
            metrics.append(["stage": "quality-comparison", "value": pair])
        }
        var data: [String: Any] = ["width": image.width, "height": image.height, "image": "input.png", "stages": stages,
            "metrics": metrics, "maps": maps, "segmentation": segmentation, "title": imageDirectory.lastPathComponent]
        if FileManager.default.fileExists(atPath: imageDirectory.appendingPathComponent("final.png").path) { data["finalImage"] = "final.png" }
        if let final = try? Data(contentsOf: imageDirectory.appendingPathComponent("final.json")),
           let finalObject = try? JSONSerialization.jsonObject(with: final) as? [String: Any] { data["input"] = finalObject["input"] }
        let encoded = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        try encoded.write(to: imageDirectory.appendingPathComponent("analysis.json"), options: .atomic)
        let template = root.appendingPathComponent("Scripts/image-translation/analysis-template.html")
        let html = try String(contentsOf: template, encoding: .utf8)
        let reportHTML: String
        let declaration = "const DATA=/*__ANALYSIS_DATA__*/null;"
        if html.contains(declaration), let (packed, _, _) = try? HostAnalysisRawPool.pack(encoded) {
            // Preserve every raw value; repeated canonical byte ranges share one
            // self-contained payload. The readable analysis.json above is unchanged.
            let safeJSON = String(decoding: packed, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
            let restore = "const PACKED=" + safeJSON + ";const DATA=PACKED.data;for(const [s,r,i] of PACKED.rawRefs)DATA.stages[s].records[r].raw=PACKED.rawPool[i];"
            reportHTML = html.replacingOccurrences(of: declaration, with: restore)
        } else {
            let safeJSON = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
            reportHTML = html.replacingOccurrences(of: "/*__ANALYSIS_DATA__*/null", with: safeJSON)
        }
        try reportHTML.write(to: imageDirectory.appendingPathComponent("analysis.html"), atomically: true, encoding: .utf8)
    }
    static func publishFinal(imageDirectory: URL, runDirectory: URL) throws {
        let final = imageDirectory.appendingPathComponent("final.png")
        guard FileManager.default.fileExists(atPath: final.path) else { return }
        let folder = runDirectory.appendingPathComponent("final")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata = try? JSONSerialization.jsonObject(with: Data(contentsOf: imageDirectory.appendingPathComponent("final.json"))) as? [String: Any]
        let input = metadata?["input"] as? String ?? "image"
        let stem = URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent
        let destination = folder.appendingPathComponent(imageDirectory.lastPathComponent + "-" + stem + ".png")
        // Publish the same lossless file without another full-page read/write.
        // A fresh temporary link plus rename also breaks any stale previous inode.
        let temporary = folder.appendingPathComponent(".final-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do { try FileManager.default.linkItem(at: final, to: temporary) }
        catch { try FileManager.default.copyItem(at: final, to: temporary) }
        guard rename(temporary.path, destination.path) == 0 else { throw AnalysisError.invalidImage }
    }
    /// Bound full-corpus disk use after a page has a durable final.json marker.
    /// Keep source, final render, replay payload, and the detector/recognizer
    /// evidence; only duplicated generated reports are retired.
    static func compactPage(_ page: URL, additionalStages: Set<String> = []) throws {
        let manager = FileManager.default
        let finalURL = page.appendingPathComponent("final.json")
        guard manager.fileExists(atPath: page.appendingPathComponent("input.png").path),
              manager.fileExists(atPath: finalURL.path) else {
            throw AnalysisError.invalidImage
        }
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: finalURL)) as? [String: Any]
        let hasRender = manager.fileExists(atPath: page.appendingPathComponent("final.png").path)
        guard hasRender || metadata?["mode"] as? String == "ocr-only" else {
            throw AnalysisError.invalidImage
        }
        let retainedStages: Set<String> = Set(["input", "runtime-settings", "detector-output",
            "recognizer-output", "premerge-training-input", "pre-rec-training-input", "pre-rec-alternative-training-input",
            "all-rec-training-input", "endpoint-glyph-contour-proposals", "context-admission",
            "individual-geometry-output", "individual-geometry-originals",
            "blank-growth-geometry-changes",
            "individual-corrected-geometry-output",
            "rejected-reads", "rf-layout-evidence", "render-payload",
            "native-render-diagnostics", "translation-result", "saved-ocr-replay", "source-utility435-stage",
            "learned-boundary-decisions", "learned-boundary-v2-decisions", "closed-contour-geometry",
            "learned-boundary-376-decisions"]).union(additionalStages)
        let entries = try manager.contentsOfDirectory(at: page, includingPropertiesForKeys: nil)
        var removed: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            let stageName = name.count > 9 && name.prefix(3).allSatisfy(\.isNumber) && name.dropFirst(3).first == "-"
                && name.hasSuffix(".json") ? String(name.dropFirst(4).dropLast(5)) : nil
            let redundant = name == "analysis" || name == "analysis.json" || name == "final-typography.pdf" ||
                (stageName.map { !retainedStages.contains($0) } ?? false)
            guard redundant else { continue }
            try manager.removeItem(at: entry)
            removed.append(name)
        }
        let renderLink = hasRender ? "<a href=\"final.png\">최종 이미지</a> · " : ""
        let renderPreview = hasRender ? "<img src=\"final.png\" alt=\"Rendered result\">" : ""
        let report = """
        <!doctype html><html lang="ko"><meta charset="utf-8"><title>Compact OCR review</title>
        <style>body{font:16px system-ui;background:#101722;color:#eaf0f8;margin:24px}
        a{color:#9dd5ff}img{display:block;max-width:100%;max-height:95vh;margin:20px auto}</style>
        <nav><a href="input.png">원본</a> · <a href="ocr-boxes.png">OCR 상자</a> ·
        \(renderLink)<a href="final.json">결과 JSON</a></nav>
        <img src="input.png" alt="Source"><img src="ocr-boxes.png" alt="OCR boxes">
        \(renderPreview)</html>
        """
        try report.write(to: page.appendingPathComponent("analysis.html"), atomically: true, encoding: .utf8)
        let receiptURL = page.appendingPathComponent("compact-output.json")
        let prior = (try? Data(contentsOf: receiptURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let retired = Set(removed).union(prior?["removed"] as? [String] ?? [])
        let receipt: [String: Any] = ["policy": "compact-generated-reports-v1", "removed": retired.sorted(),
            "retained": ["input.png", "ocr-boxes.png", "final.json", "render-provenance.json",
                "native-layout.json", "analysis.html", "detector-output", "recognizer-output", "render-payload", "saved-ocr-replay"]
                + (hasRender ? ["final.png"] : [])]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            .write(to: receiptURL, options: .atomic)
    }
    // Standalone visualization is always force-regenerated; no disk-cache receipts.
    static func generateRun(_ directory: URL, root: URL) throws {
        try generateRun(directory, root: root, receipts: nil)
    }
    static func generateRun(_ directory: URL, root: URL, receipts: GenerationReceipts?, compact: Bool = false) throws {
        let manager = FileManager.default
        let images: [URL]
        if manager.fileExists(atPath: directory.appendingPathComponent("input.png").path) { images = [directory] }
        else {
            images = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { manager.fileExists(atPath: $0.appendingPathComponent("input.png").path) }.sorted { $0.path < $1.path }
        }
        guard !images.isEmpty else { throw AnalysisError.invalidRun }
        var entries: [String] = [], failures: [String] = []
        for image in images {
            do {
                try autoreleasepool {
                if compact { try compactPage(image) }
                else if let receipts { try receipts.generate(image, root: root) }
                else { try generate(imageDirectory: image, root: root) }
                try publishFinal(imageDirectory: image, runDirectory: directory)
                let prefix = image == directory ? "" : image.lastPathComponent + "/"
                let preview = manager.fileExists(atPath: image.appendingPathComponent("final.png").path) ? "final.png" : "input.png"
                entries.append("<a class=card href=\"\(escaped(prefix))analysis.html\"><img src=\"\(escaped(prefix))\(preview)\"><h2>\(escaped(image.lastPathComponent))</h2><p>단계별 OCR · 방향 · 각도 · 세그멘테이션</p></a>")
                }
            } catch { failures.append("\(image.lastPathComponent): \(error)") }
        }
        let index = """
        <!doctype html><html lang="ko"><meta charset="utf-8"><title>OCR pipeline analysis</title><style>
        body{font:16px system-ui;background:#101722;color:#eaf0f8;margin:36px}a{color:inherit;text-decoration:none}
        .grid{display:grid;grid-template-columns:minmax(0,1fr);gap:24px;max-width:1200px;margin:auto}.card{background:#1b2635;padding:16px;border-radius:14px}
        img{display:block;width:100%;height:auto;object-fit:contain;background:#fff}p{color:#94a6bd}
        </style><h1>OCR 파이프라인 분석</h1><p>이미지를 선택해 단계와 원문을 비교할 수 있습니다.</p><div class="grid">\(entries.joined())</div>
        <p>\(failures.map(escaped).joined(separator: "<br>"))</p></html>
        """
        try index.write(to: directory.appendingPathComponent("analysis-index.html"), atomically: true, encoding: .utf8)
        if !failures.isEmpty { throw NSError(domain: "HostAnalysis", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}

// Scan only stages/records/raw values; pooling exact bytes preserves JSON types,
// escaping and all diagnostics, with bounded spans and the original HTML fallback.
private enum HostAnalysisRawPool {
 struct Entry {let stage:Int;let record:Int;let range:Range<Int>}
 struct Scanner {
  let b:UnsafeBufferPointer<UInt8>;var p=0;var entries:[Entry]=[]
  mutating func whitespace(){while p<b.count && [UInt8(32),10,13,9].contains(b[p]){p+=1}}
  mutating func string()throws->Range<Int>{
   guard p<b.count,b[p]==34 else{throw Failure.invalid};let start=p;p+=1
   while p<b.count{let c=b[p];p+=1;if c==34{return start..<p};if c==92{guard p<b.count else{throw Failure.invalid};p+=1}}
   throw Failure.invalid
  }
  func key(_ range:Range<Int>,_ name:String)->Bool {
   let chars=Array(name.utf8);guard range.count==chars.count+2 else{return false}
   for i in chars.indices where b[range.lowerBound+1+i] != chars[i]{return false};return true
  }
  mutating func value()throws{
   whitespace();guard p<b.count else{throw Failure.invalid}
   if b[p]==34 {_ = try string();return}
   if b[p]==123 || b[p]==91 {
    var depth=0
    repeat {
     guard p<b.count else{throw Failure.invalid};let c=b[p]
     if c==34 {_ = try string();continue}
     p+=1;if c==123 || c==91{depth+=1};if c==125 || c==93{depth-=1}
    }while depth>0
   }else{while p<b.count && b[p] != 44 && b[p] != 93 && b[p] != 125 && b[p] != 32 && b[p] != 10 && b[p] != 13 && b[p] != 9{p+=1}}
  }
  mutating func dictionary(_ role:Int,_ stage:Int=0,_ record:Int=0)throws {
   whitespace();guard p<b.count,b[p]==123 else{throw Failure.invalid};p+=1;whitespace()
   if p<b.count,b[p]==125{p+=1;return}
   while p<b.count {
    whitespace();let k=try string();whitespace();guard p<b.count,b[p]==58 else{throw Failure.invalid};p+=1;whitespace()
    if role==0 && key(k,"stages"){try array(1)}
    else if role==1 && key(k,"records"){try array(2,stage)}
    else if role==2 && key(k,"raw"){let start=p;try value();guard entries.count < 4096 else { throw Failure.budget };entries.append(Entry(stage:stage,record:record,range:start..<p))}
    else{try value()}
    whitespace();guard p<b.count else{throw Failure.invalid};let c=b[p];p+=1;if c==125{return};guard c==44 else{throw Failure.invalid}
   };throw Failure.invalid
  }
  mutating func array(_ role:Int,_ stage:Int=0)throws{
   whitespace();guard p<b.count,b[p]==91 else{throw Failure.invalid};p+=1;whitespace();if p<b.count,b[p]==93{p+=1;return}
   var index=0
   while p<b.count {
    if role==1{try dictionary(1,index)}else{try dictionary(2,stage,index)};index+=1;whitespace();guard p<b.count else{throw Failure.invalid};let c=b[p];p+=1;if c==93{return};guard c==44 else{throw Failure.invalid}
   };throw Failure.invalid
  }
 }
 enum Failure:Error{case invalid, budget, noSavings}
 static func pack(_ input:Data)throws->(Data,Int,Int){
  // The caller already materialized this validated JSON. A byte-size cutoff
  // made the largest reports fall back to embedding every duplicate again.
  // Scan existing storage; the4096-reference bound still caps index metadata.
  guard input.startIndex == 0 else { throw Failure.invalid }
  let entries=try input.withUnsafeBytes{ptr->[Entry] in var scan=Scanner(b:ptr.bindMemory(to:UInt8.self));try scan.dictionary(0);scan.whitespace();guard scan.p==ptr.count else{throw Failure.invalid};return scan.entries}
  var pool:[Data]=[],indices:[Data:Int]=[:],refs:[[Int]]=[],result=Data();result.append(Data("{\"data\":".utf8));var previous=0
  for e in entries {
   let data=input[e.range];let i:Int
   if let old=indices[data]{i=old}else{i=pool.count;pool.append(data);indices[data]=i}
   result.append(input[previous..<e.range.lowerBound]);result.append(Data("null".utf8));previous=e.range.upperBound;refs.append([e.stage,e.record,i])
  }
  result.append(input[previous..<input.count]);result.append(Data(",\"rawPool\":[".utf8))
  for i in pool.indices{if i>0{result.append(44)};result.append(pool[i])}
  result.append(Data("],\"rawRefs\":".utf8));result.append(try JSONSerialization.data(withJSONObject:refs));result.append(125)
  guard result.count < input.count else { throw Failure.noSavings }
  return (result,pool.count,refs.count)
 }
}

// Optional byte-bound comparison; existing metrics remain separately visible.
extension HostAnalysis {
    static func pairedReport(_ page: URL) -> [String: Any]? {
        let file = page.appendingPathComponent("quality-comparison.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max <= 2_097_152,
              let data = try? Data(contentsOf: file),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["schema"] as? String == "aidoku-color-layout-pair-v1" else { return nil }
        return report
    }
    static func pairedReportDependencies(_ page: URL) -> [String: String] {
        guard let report = pairedReport(page), let dependencies = report["dependencies"] as? [[String: String]],
              dependencies.count <= 32 else { return ["$pairDependencies": "UNKNOWN"] }
        var result: [String: String] = [:]
        for entry in dependencies {
            guard let path = entry["path"], path.hasPrefix("/") else { continue }
            result["$pair:" + path] = (try? GenerationReceipts.hash(URL(fileURLWithPath: path))) ?? "MISSING"
        }
        return result
    }
    static func pairedReportValue(_ page: URL) -> [String: Any]? {
        let file = page.appendingPathComponent("quality-comparison.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        func unknown() -> [String: Any] { ["state": "UNKNOWN", "reason": "stale/invalid paired bindings", "quality": NSNull()] }
        guard let report = pairedReport(page), report["id"] as? String == page.lastPathComponent,
              let summary = report["viewerSummary"] as? [String: Any],
              summary["state"] as? String == "byte-bound paired observations",
              let dependencies = report["dependencies"] as? [[String: String]],
              !dependencies.isEmpty, dependencies.count <= 32 else { return unknown() }
        for entry in dependencies {
            guard let path = entry["path"], path.hasPrefix("/"), let expected = entry["SHA256"],
                  (try? GenerationReceipts.hash(URL(fileURLWithPath: path))) == expected else { return unknown() }
        }
        guard let payloadSHA = summary["payloadSHA256"] as? String,
              let inputSHA = summary["inputSHA256"] as? String,
              let finalSHA = (summary["reportAnchorFinalSHA256"] ?? summary["candidateFinalSHA256"]) as? String,
              let stages = try? stageFiles(in: page),
              let payload = stages.last(where: { $0.lastPathComponent.hasSuffix("-render-payload.json") }),
              (try? GenerationReceipts.hash(payload)) == payloadSHA,
              (try? GenerationReceipts.hash(page.appendingPathComponent("input.png"))) == inputSHA,
              (try? GenerationReceipts.hash(page.appendingPathComponent("final.png"))) == finalSHA else { return unknown() }
        if let expected = summary["reportAnchorDiagnosticsSHA256"] as? String {
            guard let stages = try? stageFiles(in: page),
                  let diagnostics = stages.last(where: { $0.lastPathComponent.hasSuffix("-native-render-diagnostics.json") }),
                  (try? GenerationReceipts.hash(diagnostics)) == expected else { return unknown() }
        }
        return summary
    }
}
