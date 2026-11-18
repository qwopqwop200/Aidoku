import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

struct NativeSourceBaseMaskExactTests {
    private typealias Factory = NativeMainRemovalSourceFactory

    @Test func binarySquareDilationRetainsClippedEdgesAndNormalizesPositiveBytes() {
        for (w,h) in [(1,1), (1,17), (19,1), (5,9), (65,7)] {
            let input = (0..<(w * h)).map { i in UInt8(i % 11 == 0 ? 23 : i % 17 == 3 ? 255 : 0) }
            for radius in [0, 1, 2, 5, 20] {
                let actual = Factory.NativeSourceRoleMask.dilate(input, width: w, height: h, radius: radius)
                let expected = input.indices.map { i -> UInt8 in
                    let y = i / w, x = i % w
                    for yy in max(0,y-radius)...min(h-1,y+radius) {
                        for xx in max(0,x-radius)...min(w-1,x+radius) where input[yy*w+xx] != 0 { return 1 }
                    }
                    return 0
                }
                #expect(actual == expected)
            }
        }
    }

    @Test func baseMaskAndStrokeAuditMatchOriginalErosionsAtPageEdges() throws {
        let w = 39, h = 29
        let polygon = [CGPoint(x: 0,y: 0), CGPoint(x: w-1,y: 0), CGPoint(x: w-1,y: h-1), CGPoint(x: 0,y: h-1)]
        let owner = Factory.NativeCurrentMaskCaller.Owner(id: "edge",polygon: polygon,fontPixels: 33,translated: true,balloon: false)
        // Pixel hashes and stroke proxies come from the scalar replicated-edge erosion.
        let reference = [("bf7956a61a1512efea5b366e00014c4597c514f88a06635a2058e3481eb060d3", 1.0), ("fde6766a1558b02d77d9e77da0ad73466803dcd5587a51a8fd1df2a58b1a01cc", 16.0), ("fde6766a1558b02d77d9e77da0ad73466803dcd5587a51a8fd1df2a58b1a01cc", 2.0)]
        for pattern in reference.indices {
            let rgb = (0..<(w*h*3)).map { i -> UInt8 in
                let p = i/3, x = p%w, y = p/w, c = i%3
                if pattern == 0 { return 223 }
                if pattern == 1 { return c == p%3 ? 255 : 0 }
                if x<9 || (x>24 && y>6 && y<19) { return c == 1 ? 5 : 32 }
                if (x+2*y)%11 < 3 { return c == 2 ? 191 : 61 }
                return 223
            }
            let result = try Factory.NativeSourceBaseMask.extract(source:.init(width:w,height:h,rgb:rgb,revision:"fixture"),owners:[owner])
            let digest = SHA256.hash(data:Data(result.mask)).map {String(format:"%02x",$0)}.joined()
            #expect(digest == reference[pattern].0)
            #expect(result.audit.first?["strokeRadiusProxy"] as? Double == reference[pattern].1)
        }
    }
}
