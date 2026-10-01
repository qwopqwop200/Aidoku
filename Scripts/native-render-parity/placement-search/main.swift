import Foundation
import CoreGraphics
while let line = readLine() {
    do {
        let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        func rect(_ value: [Double]) -> CGRect { CGRect(x: value[0], y: value[1], width: value[2], height: value[3]) }
        let table = NativeTypographyPlacementSearch.Table(safe: (value["safe"] as! [Int]).map { UInt8($0) },
            width: value["width"] as! Int, height: value["height"] as! Int, crop: rect(value["crop"] as! [Double]),
            obstacles: (value["obstacles"] as! [[Double]]).map(rect))
        let result = table?.nearestShift(frame: rect(value["frame"] as! [Double]), size: value["size"] as! Double,
            region: rect(value["region"] as! [Double]), reachGlyph: value["glyph"] as! Double)
        let output: Any = result.map { [$0.x, $0.y] } as Any? ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: output, options: .fragmentsAllowed)
        print(String(data: data, encoding: .utf8)!)
    } catch { print("{\"error\":\"\(error)\"}") }
}
