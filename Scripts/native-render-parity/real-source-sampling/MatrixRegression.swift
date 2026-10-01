import CoreGraphics
import Foundation
import UIKit

@main struct MatrixRegression {
    static func source(width: Int, height: Int, alpha: Bool) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            if alpha {
                pixels[i] = x % 3 == 0 ? 255 : 0
                pixels[i+1] = y % 3 == 0 ? 255 : 0
                pixels[i+2] = (x+y) % 3 == 0 ? 255 : 0
                pixels[i+3] = [64,128,192,255][(x + 3*y) % 4]
            } else {
                pixels[i] = UInt8((17*x + 31*y + x*y) % 256)
                pixels[i+1] = UInt8((47*x + 13*y + 3*x*y) % 256)
                pixels[i+2] = UInt8((7*x + 53*y + 5*x*y) % 256)
                pixels[i+3] = 255
            }
        }}
        let original = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        return UIImage(data: UIImage(cgImage: original).pngData()!)!.cgImage!
    }
    static func main() throws {
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String:Any]
        let rows = input["rows"] as! [[String:Any]]
        var current = "", image: CGImage?, report: [[String:Any]] = []
        for row in rows {
            let sourceSize = row["imageSize"] as! [Int], alpha = row["alpha"] as! Bool
            let key = "\(sourceSize)-\(alpha)"
            if current != key { image = try source(width: sourceSize[0],height: sourceSize[1],alpha: alpha);current = key }
            let rect = (row["rect"] as! [NSNumber]).map(\.doubleValue), size = row["size"] as! [Int]
            let native = try NativeSourcePixelReader.draw(image: image!,x: rect[0],y: rect[1],sourceWidth: rect[2],sourceHeight: rect[3],width: size[0],height: size[1])
            let web = Data(base64Encoded: row["webRGBA"] as! String)!
            let changed = native.indices.filter { native[$0] != web[$0] }
            report.append(["id":row["id"]!,"imageSize":sourceSize,"alpha":alpha,"bytes":native.count,
                "changedBytes":changed.count,"maximumDelta":changed.map{abs(Int(native[$0])-Int(web[$0]))}.max() ?? 0,"exact":changed.isEmpty])
        }
        let result: [String:Any] = ["scope":"Actual production reader on the existing iOS simulator, same generated PNG sources and bounded live Canvas captures; no source thresholds.","cases":report.count,"exact":report.filter{$0["exact"] as? Bool == true}.count,"rows":report]
        try JSONSerialization.data(withJSONObject: result,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(result["exact"]!)/\(report.count) actual iOS Canvas transport cases exact")
        for row in report where row["exact"] as? Bool != true { print(row) }
        guard report.allSatisfy({$0["exact"] as? Bool == true}) else {exit(1)}
    }
}
