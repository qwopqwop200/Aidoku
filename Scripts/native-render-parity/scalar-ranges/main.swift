import Foundation
import CoreGraphics
while let line = readLine() {
    do {
        let v = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let size = v["size"] as! [Double], vertical = v["vertical"] as! Bool
        let style = NativeTranslationTypography.Style(fontScript: v["script"] as! String, fontSize: v["font"] as! Double,
            vertical: vertical, lineHeight: v["pitch"] as! Double, optimizesKoreanWrapping: false,
            balancesHorizontalLines: !vertical)
        let layout = NativeTranslationTypography.layout(text: v["text"] as! String, in: CGSize(width: size[0], height: size[1]), style: style)
        func box(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        print(String(data: try JSONSerialization.data(withJSONObject: ["ranges":layout.rangeBounds.map(box),
            "lines": NativeTranslationTypography.captionLineMetrics(layout: layout).map { box($0.rect) }, "text": layout.shapedText], options: .sortedKeys), encoding: .utf8)!)
    } catch { print("{\"error\":\"\(error)\"}") }
}
