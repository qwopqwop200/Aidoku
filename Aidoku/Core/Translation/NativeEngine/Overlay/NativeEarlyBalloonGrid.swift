import CoreGraphics
import Foundation

/// Initial fitBalloon clear-region grid, including plane-certified exterior
/// paper and only the clear component connected to erased source lettering.
enum NativeEarlyBalloonGrid {
    struct Geometry {
        var width: Int
        var height: Int
        var origin: CGPoint
        var sx: Double
        var sy: Double
        var imageWidth: Double
        var imageHeight: Double
        var frame: CGRect
    }
    struct Input {
        var geometry: Geometry
        var safe: [UInt8]
        var paintedRGBA: [UInt8]? = nil
        var surfaceSafe = false
        var coefficients: [[Double]]? = nil
        /// Normalized source OCR box followed by auxiliary ink rectangles.
        var sourceRects: [[Double]]
        var sourceGlyph: Double
        var font: Double
        var clearSearch = true
        var late = false
        var otherLayers: [CGRect] = []
    }
    struct Grid {
        var width: Int
        var height: Int
        var crop: CGRect
        var kx: CGFloat
        var ky: CGFloat
        var sourceSpan: CGRect
        var sourceCentre: CGPoint
        var gridCentre: CGPoint
        var blocked: [UInt8]
        var reached: [UInt8]
        var summedArea: [Int]
        var exteriorPixels: Int
        func clear(_ left: Int, _ top: Int, _ width: Int, _ height: Int) -> Bool {
            guard left >= 0, top >= 0, width >= 0, height >= 0,
                  left <= self.width, top <= self.height,
                  width <= self.width - left, height <= self.height - top else { return false }
            let stride = self.width + 1, right = left + width, bottom = top + height
            return summedArea[bottom * stride + right] - summedArea[top * stride + right]
                - summedArea[bottom * stride + left] + summedArea[top * stride + left] == 0
        }
    }
    /// Exterior reader coordinates are source-image pixels, not display points.
    static func build(_ input: Input, interiorAllows: ((CGPoint) -> Bool)? = nil,
                      readExterior: ((CGRect, Int, Int) -> [UInt8]?)? = nil) -> Grid? {
        let c = input.geometry
        guard c.width > 0, c.height > 0, c.width <= 262_144 / c.height,
              input.safe.count == c.width * c.height,
              c.sx > 0, c.sy > 0, c.imageWidth > 0, c.imageHeight > 0,
              c.frame.width > 0, c.frame.height > 0,
              [c.sx,c.sy,c.imageWidth,c.imageHeight,Double(c.origin.x),Double(c.origin.y),
               Double(c.frame.minX),Double(c.frame.minY),Double(c.frame.width),Double(c.frame.height)].allSatisfy(\.isFinite) else { return nil }
        let kx = c.imageWidth / Double(c.frame.width) * c.sx
        let ky = c.imageHeight / Double(c.frame.height) * c.sy
        let reach: Double = input.clearSearch && !input.late && input.surfaceSafe && input.coefficients != nil ? 64 : 0
        var ex = floor(reach * kx + 0.5), ey = floor(reach * ky + 0.5)
        if (Double(c.width) + 2 * ex) * (Double(c.height) + 2 * ey) > 262_144 { ex = 0; ey = 0 }
        let expandX = Int(ex), expandY = Int(ey), w = c.width + 2 * expandX, h = c.height + 2 * expandY
        let cx0 = Double(c.frame.minX) + Double(c.origin.x) / c.imageWidth * Double(c.frame.width) - ex / kx
        let cy0 = Double(c.frame.minY) + Double(c.origin.y) / c.imageHeight * Double(c.frame.height) - ey / ky
        var blocked = [UInt8](repeating: 1, count: w * h), exterior: [UInt8]?
        if expandX > 0, let readExterior {
            let rect = CGRect(x: Double(c.origin.x) - ex / c.sx, y: Double(c.origin.y) - ey / c.sy,
                              width: Double(w) / c.sx, height: Double(h) / c.sy)
            let sampled = readExterior(rect,w,h)
            if sampled?.count == w * h * 4 { exterior = sampled }
        }
        func plane(_ x: Double, _ y: Double) -> [Double]? {
            guard let coefficients = input.coefficients, coefficients.count == 3,
                  coefficients.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { return nil }
            return coefficients.map { max(0,min(255,$0[0] + $0[1] * x + $0[2] * y)) }
        }
        for yy in 0..<h { for xx in 0..<w {
            let px = Double(c.origin.x) + (Double(xx - expandX) + 0.5) / c.sx
            let py = Double(c.origin.y) + (Double(yy - expandY) + 0.5) / c.sy
            if px < 0 || py < 0 || px > c.imageWidth || py > c.imageHeight { continue }
            let display = CGPoint(x: cx0 + (Double(xx) + 0.5) / kx, y: cy0 + (Double(yy) + 0.5) / ky)
            if let interiorAllows, !interiorAllows(display) { continue }
            let u = xx - expandX, v = yy - expandY, index = yy * w + xx
            if u >= 0, v >= 0, u < c.width, v < c.height {
                if input.safe[v * c.width + u] != 0 { blocked[index] = 0 }
                continue
            }
            guard let exterior, let expected = plane(Double(u) / Double(c.width),Double(v) / Double(c.height)) else { continue }
            let i = index * 4
            if exterior[i+3] >= 254 && abs(Double(exterior[i])-expected[0]) <= 18 &&
                abs(Double(exterior[i+1])-expected[1]) <= 18 && abs(Double(exterior[i+2])-expected[2]) <= 18 { blocked[index] = 0 }
        } }
        for r in input.otherLayers where [r.minX,r.minY,r.maxX,r.maxY].allSatisfy(\.isFinite) {
            let left = max(0,Int(floor((Double(r.minX)-1-cx0)*kx)))
            let top = max(0,Int(floor((Double(r.minY)-0.75-cy0)*ky)))
            let right = min(w,Int(ceil((Double(r.maxX)+1-cx0)*kx)))
            let bottom = min(h,Int(ceil((Double(r.maxY)+0.75-cy0)*ky)))
            if left < right, top < bottom { for yy in top..<bottom { for xx in left..<right { blocked[yy*w+xx] = 1 } } }
        }
        let sources = input.sourceRects.filter { $0.count == 4 && $0.allSatisfy(\.isFinite) }
        let core = sources.map { r in
            [(r[0]*c.imageWidth-Double(c.origin.x))*c.sx+ex,
             (r[1]*c.imageHeight-Double(c.origin.y))*c.sy+ey,
             r[2]*c.imageWidth*c.sx,r[3]*c.imageHeight*c.sy]
        }
        let painted = input.paintedRGBA.flatMap { $0.count == c.width*c.height*4 ? $0:nil }
        var reached = [UInt8](repeating: 0,count:w*h), queue = [Int](repeating:0,count:w*h), tail = 0
        for seedPainted in painted == nil ? [false]:[true,false] {
            for a in core {
                let left = max(0,Int(floor(a[0]))), top = max(0,Int(floor(a[1])))
                let right = min(w,Int(ceil(a[0]+a[2]))), bottom = min(h,Int(ceil(a[1]+a[3])))
                if left >= right || top >= bottom { continue }
                for yy in top..<bottom { for xx in left..<right {
                    let i = yy*w+xx, u = xx-expandX, v = yy-expandY
                    if seedPainted && (u<0 || v<0 || u>=c.width || v>=c.height || painted![(v*c.width+u)*4+3] == 0) { continue }
                    if blocked[i] == 0, reached[i] == 0 { reached[i] = 1; queue[tail] = i; tail += 1 }
                } }
            }
            if tail > 0 { break }
        }
        var head = 0
        while head < tail {
            let i = queue[head], xx = i%w, yy = i/w; head += 1
            for j in [xx>0 ? i-1:-1,xx<w-1 ? i+1:-1,yy>0 ? i-w:-1,yy<h-1 ? i+w:-1] {
                if j >= 0, blocked[j] == 0, reached[j] == 0 { reached[j] = 1; queue[tail] = j; tail += 1 }
            }
        }
        guard tail > 0, let source = sources.first else { return nil }
        for i in 0..<w*h where reached[i] == 0 { blocked[i] = 1 }
        // JavaScript Number(sourceFontSize)||font uses negative values, while
        // NaN and zero select the existing font.
        let sourceGlyph = input.sourceGlyph == 0 || input.sourceGlyph.isNaN ? input.font:input.sourceGlyph
        guard sourceGlyph.isFinite else { return nil }
        let g = sourceGlyph*kx/2
        let left = core.map { $0[0] }.min()! - g, right = core.map { $0[0]+$0[2] }.max()! + g
        let top = core.map { $0[1] }.min()! - g, bottom = core.map { $0[1]+$0[3] }.max()! + g
        var sat = [Int](repeating:0,count:(w+1)*(h+1))
        for yy in 0..<h { var row = 0; for xx in 0..<w {
            row += Int(blocked[yy*w+xx]); sat[(yy+1)*(w+1)+xx+1] = sat[yy*(w+1)+xx+1] + row
        } }
        let sourceCentre = CGPoint(x: Double(c.frame.minX)+(source[0]+source[2]/2)*Double(c.frame.width),
                                   y: Double(c.frame.minY)+(source[1]+source[3]/2)*Double(c.frame.height))
        return Grid(width:w,height:h,crop:CGRect(x:cx0,y:cy0,width:Double(w)/kx,height:Double(h)/ky),kx:CGFloat(kx),ky:CGFloat(ky),
                    sourceSpan:CGRect(x:left,y:top,width:right-left,height:bottom-top),sourceCentre:sourceCentre,
                    gridCentre:CGPoint(x:(Double(sourceCentre.x)-cx0)*kx,y:(Double(sourceCentre.y)-cy0)*ky),
                    blocked:blocked,reached:reached,summedArea:sat,exteriorPixels:exterior == nil ? 0:w*h)
    }
}
