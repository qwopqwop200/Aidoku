import Foundation

/// Measured color/structure profiles, not a foreground or ownership mask.
/// Coordinates are the current source rectangle; there are no IDs or labels.
enum NativeOCRLearnedBoundaryRGB442 {
    static func features(rgba: [UInt8], width: Int, height: Int,
                         bytesPerRow: Int, polygon q: [[Double]],
                         normalPadding: Double = 0.4, alongPadding: Double = 1) -> [Double]? {
        guard width > 0, height > 0, width < Int.max / 4,
              bytesPerRow >= width * 4, bytesPerRow <= Int.max / height,
              rgba.count >= bytesPerRow * height, q.count == 4,
              normalPadding.isFinite, alongPadding.isFinite, normalPadding >= 0, alongPadding >= 0,
              q.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        var a = [0.0, 0.0], longest = 0.0
        for i in 0..<4 {
            let e = [q[(i+1)%4][0]-q[i][0], q[(i+1)%4][1]-q[i][1]]
            let length = hypot(e[0], e[1])
            if length > longest { longest = length; a = e }
        }
        guard longest > 0 else { return nil }
        a = a.map { $0 / longest }
        if a[1] < 0 || (a[1] == 0 && a[0] < 0) { a = a.map { -$0 } }
        let n = [a[1], -a[0]], c = [(q.map { $0[0] }.reduce(0,+))/4, (q.map { $0[1] }.reduce(0,+))/4]
        let ns = q.map { ($0[0]-c[0])*n[0]+($0[1]-c[1])*n[1] }
        let aa = q.map { ($0[0]-c[0])*a[0]+($0[1]-c[1])*a[1] }
        let w = ns.max()! - ns.min()!
        guard w > 0, w.isFinite else { return nil }
        let n0 = ns.min()! - normalPadding*w, n1 = ns.max()! + normalPadding*w
        let a0 = aa.min()! - alongPadding*w, a1 = aa.max()! + alongPadding*w
        let rows = Int(min(768, max(64, ((a1-a0)/w*36).rounded(.toNearestOrEven))))
        let columns = 64, total = rows * columns
        var rgb = [Float](repeating: 0, count: total*3)
        func pixel(_ x: Int, _ y: Int, _ channel: Int) -> Int {
            let xx = min(width-1,max(0,x)), yy = min(height-1,max(0,y))
            return Int(rgba[yy*bytesPerRow+xx*4+channel])
        }
        for y in 0..<rows {
            let v = a0+(a1-a0)*Double(y)/Double(rows-1)
            for x in 0..<columns {
                let u = n0+(n1-n0)*Double(x)/Double(columns-1)
                let wx = Float(c[0]+u*n[0]+v*a[0]), wy = Float(c[1]+u*n[1]+v*a[1])
                guard wx.isFinite, wy.isFinite, abs(wx) < 1e8, abs(wy) < 1e8 else { return nil }
                let ix = Int((wx*32).rounded(.toNearestOrEven)), iy = Int((wy*32).rounded(.toNearestOrEven))
                let x0 = Int(floor(Double(ix)/32)), y0 = Int(floor(Double(iy)/32))
                let fx = ix-x0*32, fy = iy-y0*32
                for ch in 0..<3 {
                    let sum = pixel(x0,y0,ch)*(32-fx)*(32-fy)+pixel(x0+1,y0,ch)*fx*(32-fy)
                        + pixel(x0,y0+1,ch)*(32-fx)*fy+pixel(x0+1,y0+1,ch)*fx*fy
                    rgb[(y*columns+x)*3+ch] = Float((sum+512)>>10)
                }
            }
        }
        func reflect(_ x: Int, _ length: Int) -> Int {
            var z = x
            while z < 0 || z >= length { z = z < 0 ? -z : 2*length-z-2 }
            return z
        }
        var kernel = (-5...5).map { exp(-Double($0*$0)/(2*1.3*1.3)) }
        let norm = kernel.reduce(0,+); kernel = kernel.map { $0/norm }
        let k = kernel.map(Float.init)
        var temp = [Float](repeating: 0,count: rgb.count), smooth = temp
        for y in 0..<rows { for x in 0..<columns { for ch in 0..<3 {
            var sum: Float = 0
            for i in -5...5 { sum += rgb[(y*columns+reflect(x+i,columns))*3+ch]*k[i+5] }
            temp[(y*columns+x)*3+ch] = sum
        } } }
        for y in 0..<rows { for x in 0..<columns { for ch in 0..<3 {
            var sum: Float = 0
            for i in -5...5 { sum += temp[(reflect(y+i,rows)*columns+x)*3+ch]*k[i+5] }
            smooth[(y*columns+x)*3+ch] = sum
        } } }
        var distance = [Float](repeating:0,count:total), detail = distance
        for y in 0..<rows {
            var med = [Float](repeating:0,count:3)
            for ch in 0..<3 {
                let values = (Array(0..<8)+Array(56..<64)).map { rgb[(y*columns+$0)*3+ch] }.sorted()
                med[ch] = (values[7]+values[8])/2
            }
            for x in 0..<columns {
                let i = y*columns+x
                for ch in 0..<3 {
                    distance[i] = max(distance[i],abs(rgb[i*3+ch]-med[ch]))
                    detail[i] = max(detail[i],abs(rgb[i*3+ch]-smooth[i*3+ch]))
                }
            }
        }
        var out = [Double]()
        for (plane,threshold) in [(distance,Float(20)),(distance,45),(detail,12),(detail,28)] {
            for axis in 0..<2 {
                let length = axis == 0 ? columns : rows
                var start = 0
                for bin in 0..<16 {
                    let count = length/16+(bin < length%16 ? 1 : 0)
                    var positive = 0
                    if axis == 0 {
                        for y in 0..<rows { for x in start..<(start+count) { if plane[y*columns+x] > threshold { positive += 1 } } }
                    } else {
                        for y in start..<(start+count) { for x in 0..<columns { if plane[y*columns+x] > threshold { positive += 1 } } }
                    }
                    out.append(Double(positive)/Double(count*(axis == 0 ? rows : columns)));start += count
                }
            }
        }
        for plane in [distance,detail] {
            // Use Float accumulation to match the exported source feature schema.
            let mean = plane.reduce(Float(0),+)/Float(total)
            let variance = plane.reduce(Float(0)) { $0+($1-mean)*($1-mean) }/Float(total)
            out += [Double(mean),Double(sqrt(variance))]
        }
        return out.count == 132 && out.allSatisfy(\.isFinite) ? out : nil
    }
}
