import Foundation
import CoreGraphics

while let line = readLine() {
    do {
        let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let args = value["args"] as! [Any]
        func decode<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        }
        func encoded<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        }
        typealias P = NativeTypographyPostPolish
        let output: Any
        switch value["op"] as! String {
        case "captionFontFloor":
            let a = args[0] as! [Double]; output = P.captionFontFloor(original: a[0], minimum: a[1]) as Any? ?? NSNull()
        case "restoredFontFloor":
            let a = args[0] as! [Double]; output = P.restoredFontFloor(original: a[0], minimum: a[1]) as Any? ?? NSNull()
        case "artworkFontSizes":
            let a = args[0] as! [Double]; output = P.artworkFontSizes(font: a[0], minimum: a[1])
        case "balloonFontSizes":
            let a = args[0] as! [Double]; output = P.balloonFontSizes(font: a[0], minimum: a[1])
        case "emergencyBalloonFontSizes":
            let a = args[0] as! [Any]; output = P.emergencyBalloonFontSizes(font: a[0] as! Double, minimum: a[1] as! Double, preferred: (a[2] as! [Double]).map { CGFloat($0) })
        case "balloonShape":
            let rect = (args[0] as! [Double]).map { CGFloat($0) }, center = (args[1] as! [Double]).map { CGFloat($0) }
            let f = args[3] as! [Double], points = args[4] as! [[Double]], bounds = args[5] as! [[Double]]
            if let shape = P.balloonShape(rect: rect, center: center, spans: args[2] as! [Double],
                frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3])) {
                output = ["area":shape.area,"rectangularity":shape.rectangularity,
                    "center":[shape.center.x,shape.center.y],
                    "contains":points.map { shape.contains(CGPoint(x: $0[0], y: $0[1])) },
                    "rows":points.map { shape.rowSpan($0[1]) as Any? ?? NSNull() },
                    "outside":bounds.map { shape.outside(CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3])) }]
            } else { output = NSNull() }
        case "wordLines":
            let a = args[0] as! [String: Any], text = a["text"] as! String
            let font = (a["font"] as! NSNumber).doubleValue, width = (a["width"] as! NSNumber).doubleValue
            let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font, optimizesKoreanWrapping: false)
            let chars = text.unicodeScalars.map { String($0) }
            var widths: [String: CGFloat] = [:]
            for i in chars.indices {
                for j in (i + 1)...chars.count {
                    let part = chars[i..<j].joined()
                    widths[Data(part.utf8).base64EncodedString()] = NativeTranslationTypography.measuredWidth(text: part, style: style)
                        - CGFloat(max(0, part.unicodeScalars.count - 1)) * style.tracking
                }
            }
            let result = P.wordLines(text: text, size: CGSize(width: width, height: 1000), style: style,
                maxLines: a["maxLines"] as! Int, wide: a["wide"] as! Bool, strict: a["strict"] as? Bool, any: a["any"] as! Bool)
            var wideStyle = style; wideStyle.koreanQuoteMode = 2
            let first = NativeTranslationTypography.koreanLines(text: text,
                available: CGSize(width: width - 1, height: 1000), style: wideStyle, maxLines: (a["maxLines"] as! Int), measuresScalars: true)
            output = ["widths": widths, "first": first as Any? ?? NSNull(), "actual": result as Any? ?? NSNull()]
        case "condensedSizes":
            let a = args[0] as! [Double]; output = P.condensedSizes(base: a[0], target: a[1])
        case "condensedWordBound":
            let a = args[0] as! [Double]; output = P.condensedWordBound(longest: a[0], available: a[1])
        case "growthKeepsLineLength":
            let a = args[0] as! [Any]; output = P.growthKeepsLineLength(text: a[0] as! String, originalLines: a[1] as! Int, lines: a[2] as! Int)
        case "badBreak":
            let a = args[0] as! [Any]; output = P.badBreak(text: a[0] as! String, offset: a[1] as! Int)
        case "reduplicationBreak":
            let a = args[0] as! [Any]; output = P.reduplicationBreak(text: a[0] as! String, offset: a[1] as! Int)
        case "interfaceRows":
            let boxes = args[0] as! [[String:Any]], texts = boxes.map { $0["text"] as! String }
            output = P.interfaceRows(try decode(boxes, as: [P.SourceBox?].self), texts: texts, frame: (args[1] as! [Double]).map { CGFloat($0) })
        case "fontClusters": output = try encoded(P.fontClusters(decode(args[0], as: [P.FontEntry].self)))
        case "fontClusterTargets": output = try encoded(P.fontClusterTargets(decode(args[0], as: [P.FontEntry].self),
            kept: decode(args[1], as: [P.FontEntry].self), raisable: { $0.column }))
        case "pageStyleGroups": output = try encoded(P.pageStyleGroups(decode(args[0], as: [P.StyleRecord].self),
            tolerance: CGFloat((args[1] as! NSNumber).doubleValue)))
        case "alignedGroups": output = try encoded(P.alignedGroups(decode(args[0], as: [P.SourceBox?].self)))
        case "columnRowLinks": output = try encoded(P.columnRowLinks(decode(args[0], as: [P.SourceBox?].self)))
        case "cohortFontCandidates":
            let a = args[0] as! [Double]
            output = try encoded(P.cohortFontCandidates(original: a[0], target: a[1], minimum: a[2]))
        case "fontFlowFits":
            let a = args[0] as! [Any]
            output = try P.fontFlowFits(decode(a[0], as: P.Profile.self), decode(a[1], as: P.Profile.self), extraWordBreaks: a[2] as! Int)
        case "koreanWrapImproves":
            let a = args[0] as! [Any]
            output = try P.koreanWrapImproves(decode(a[0], as: P.Profile.self), decode(a[1], as: P.Profile.self))
        default: throw CocoaError(.fileReadCorruptFile)
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.fragmentsAllowed, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } catch { print("{\"error\":\"\(error)\"}") }
}
