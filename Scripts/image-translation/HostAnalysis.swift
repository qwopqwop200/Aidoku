import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Reads saved stage outputs; deliberately independent of the evolving app/OCR types.
enum HostAnalysis {
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
    static func stages(in directory: URL, width: Double, height: Double) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.first?.isNumber == true }.sorted { $0.path < $1.path }
        for file in files {
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let name = root["stage"] as? String else { continue }
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
        let input = imageDirectory.appendingPathComponent("input.png")
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AnalysisError.invalidImage
        }
        let output = imageDirectory.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var stages = try stages(in: imageDirectory, width: Double(image.width), height: Double(image.height))
        for index in stages.indices {
            let filename = String(format: "%02d-", index + 1) + (stages[index]["name"] as? String ?? "stage") + ".png"
            stages[index]["preview"] = "analysis/" + filename
            try preview(image, stage: stages[index], to: output.appendingPathComponent(filename))
        }
        let stageFiles = try FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.first?.isNumber == true }.sorted { $0.path < $1.path }
        var metrics: [[String: Any]] = [], maps: [[String: Any]] = [], segmentation: [[String: Any]] = []
        for file in stageFiles {
            if let data = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], let name = data["stage"] as? String {
                if name.contains("metric") || name.contains("phases") || name.contains("timing") { metrics.append(data) }
                if name == "render-dom", let value = data["value"] as? [String: Any], let root = value["root"] as? [String: Any] {
                    metrics.append(["stage": "render-dom-root", "value": root])
                }
                if name == "detector-probability-map", let map = data["value"] as? [String: Any] { maps.append(map) }
                if name == "segmentation-trace", let trace = data["value"] as? [String: Any] { segmentation.append(trace) }
            }
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
        let safeJSON = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
        try html.replacingOccurrences(of: "/*__ANALYSIS_DATA__*/null", with: safeJSON)
            .write(to: imageDirectory.appendingPathComponent("analysis.html"), atomically: true, encoding: .utf8)
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
        try Data(contentsOf: final).write(to: destination, options: .atomic)
    }
    static func generateRun(_ directory: URL, root: URL) throws {
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
                try generate(imageDirectory: image, root: root)
                try publishFinal(imageDirectory: image, runDirectory: directory)
                let prefix = image == directory ? "" : image.lastPathComponent + "/"
                let preview = manager.fileExists(atPath: image.appendingPathComponent("final.png").path) ? "final.png" : "input.png"
                entries.append("<a class=card href=\"\(escaped(prefix))analysis.html\"><img src=\"\(escaped(prefix))\(preview)\"><h2>\(escaped(image.lastPathComponent))</h2><p>단계별 OCR · 방향 · 각도 · 세그멘테이션</p></a>")
            } catch { failures.append("\(image.lastPathComponent): \(error)") }
        }
        let index = """
        <!doctype html><html lang="ko"><meta charset="utf-8"><title>OCR pipeline analysis</title><style>
        body{font:16px system-ui;background:#101722;color:#eaf0f8;margin:36px}a{color:inherit;text-decoration:none}
        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:20px}.card{background:#1b2635;padding:16px;border-radius:14px}
        img{width:100%;height:220px;object-fit:contain;background:#fff}p{color:#94a6bd}
        </style><h1>OCR 파이프라인 분석</h1><p>이미지를 선택해 단계와 원문을 비교할 수 있습니다.</p><div class="grid">\(entries.joined())</div>
        <p>\(failures.map(escaped).joined(separator: "<br>"))</p></html>
        """
        try index.write(to: directory.appendingPathComponent("analysis-index.html"), atomically: true, encoding: .utf8)
        if !failures.isEmpty { throw NSError(domain: "HostAnalysis", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}
