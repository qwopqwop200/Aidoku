import Foundation
import CoreGraphics
let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/native-render-parity/outlined-pdf-residual/flex-capture.json")
let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
var maximum: CGFloat = 0, count = 0
for row in cases {
    let input = row["a"] as! [String: Any]
    let alignment: CGFloat = input["align"] as? String == "left" ? 0 : input["align"] as? String == "right" ? 1 : 0.5
    let box = NativeTextPaintGeometry.anonymousFlexBox(contentWidth: (input["width"] as! NSNumber).doubleValue,
        maximumContentWidth: (row["maxContent"] as! NSNumber).doubleValue, justification: alignment)!
    for line in row["rowMeasured"] as! [[String: Any]] {
        let actual = (line["actualX"] as! NSNumber).doubleValue
        let predicted = 41 + box.lineOrigin(lineWidth: (line["width"] as! NSNumber).doubleValue, alignment: alignment)!
        maximum = max(maximum, abs(actual - predicted)); count += 1
        precondition(abs(actual - predicted) < 0.00004)
    }
}
print("Actual native helper verified against \(cases.count) WebKit cases / \(count) rows; maximum Float coordinate delta \(maximum). Conditional on captured line breaks; not a pixel equality claim.")
