import Foundation
import CoreGraphics
while let line = readLine() {
    do {
        let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let size = value["size"] as! [Double], font = value["font"] as! Double
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font,
            lineHeight: value["pitch"] as! Double, optimizesKoreanWrapping: false, balancesHorizontalLines: true)
        let layout = NativeTranslationTypography.layout(text: value["text"] as! String, in: CGSize(width: size[0], height: size[1]), style: style)
        func box(_ r: CGRect) -> [Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
        let result: [String:Any] = ["shaped":layout.shapedText,"rangeBounds":layout.rangeBounds.map(box),
            "lines":NativeTranslationTypography.captionLineMetrics(layout:layout).map { box($0.rect) }]
        print(String(data: try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
    } catch { print("{\"error\":\"\(error)\"}") }
}
