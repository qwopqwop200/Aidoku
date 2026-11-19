import CoreGraphics
import Foundation

// TEMPORARY STAND-INS for V2 stages whose real file does not exist yet.
// TO BE DELETED once every stage file is in Aidoku/Core/Translation/V2/.
//
// The host launcher compiles this file with `-D V2_HAS_<FileStem>` for every
// V2 stage file that exists, so a real implementation always replaces its
// stub automatically. Stubs are deliberately simple and are NOT the contract
// implementation; they only keep the orchestrator runnable end to end.

#if !V2_HAS_V2RemovalMask
/// STUB (S6): erase every line polygon of the given blocks, dilated by 3 px.
enum V2RemovalMask {
    static let isStub = true

    static func build(_ page: V2Page, blocks: [V2Block], layout: [V2LayoutRegion]) -> [UInt8] {
        let width = page.width, height = page.height
        var mask = [UInt8](repeating: 0, count: width * height)
        mask.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            // Top-left page coordinates.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            context.setLineWidth(6)
            context.setLineJoin(.round)
            context.setShouldAntialias(false)
            for line in blocks.flatMap(\.lines) where line.polygon.count >= 3 {
                context.beginPath()
                context.addLines(between: line.polygon)
                context.closePath()
                context.drawPath(using: .fillStroke)
            }
        }
        return mask.map { $0 == 0 ? 0 : 255 }
    }
}
#endif

#if !V2_HAS_V2Style
/// STUB (S8): black fill, white 2 px stroke, font from the median line short side.
extension V2Style {
    static func estimate(_ page: V2Page, blocks: [V2Block]) -> [V2Block] {
        blocks.map { block in
            var output = block
            let sides = block.lines.map { min($0.bounds.width, $0.bounds.height) }.sorted()
            let font = sides.isEmpty ? 16 : max(10, sides[sides.count / 2] * 0.8)
            output.style = V2Style(fontPixels: font, bold: false, textColor: V2RGB(r: 0, g: 0, b: 0),
                                   strokeColor: V2RGB(r: 255, g: 255, b: 255), strokeWidth: 2)
            return output
        }
    }
}
#endif

/// Stage stubs compiled into this host binary (reported in the run summary).
enum V2HostStubs {
    static var active: [String] {
        var names: [String] = []
#if !V2_HAS_V2RemovalMask
        names.append("V2RemovalMask")
#endif
#if !V2_HAS_V2Style
        names.append("V2Style")
#endif
        return names
    }
}
