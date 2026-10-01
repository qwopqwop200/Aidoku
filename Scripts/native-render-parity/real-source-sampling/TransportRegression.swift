import CoreGraphics
import Foundation
import ImageIO

@main struct TransportRegression {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let capture = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, nil)!
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as! [String: Any]
        let rows = data["rows"] as! [[String: Any]]
        var report: [[String: Any]] = []
        for row in rows {
            let rect = (row["rect"] as! [NSNumber]).map(\.doubleValue)
            let size = row["size"] as! [Int]
            let native = try NativeSourcePixelReader.draw(image: image, x: rect[0], y: rect[1],
                sourceWidth: rect[2], sourceHeight: rect[3], width: size[0], height: size[1])
            let web = Data(base64Encoded: row["webRGBA"] as! String)!
            let changed = native.indices.filter { native[$0] != web[$0] }
            report.append(["id": row["id"]!, "bytes": native.count, "changedBytes": changed.count,
                "maximumDelta": changed.map { abs(Int(native[$0])-Int(web[$0])) }.max() ?? 0,
                "exact": changed.isEmpty])
        }
        let result: [String: Any] = ["scope": "Actual iOS production source reader against bounded frozen Canvas capture, same prepared PNG pixels. No palette thresholds or fixture-coordinate changes.",
            "imageSize": [image.width,image.height],"cases": report.count,
            "exact": report.filter { $0["exact"] as? Bool == true }.count,"rows": report]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys,.prettyPrinted]).write(to: output)
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        guard report.allSatisfy({ $0["exact"] as? Bool == true }) else { exit(1) }
    }
}
