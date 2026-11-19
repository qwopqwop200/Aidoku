import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct V2RemovalMaskTests {
    /// White page with black glyph-like bars inside one horizontal line polygon.
    private func page(width: Int = 400, height: Int = 200, ink: [CGRect], background: UInt8 = 255) -> [UInt8] {
        var rgba = [UInt8](repeating: background, count: width * height * 4)
        for rect in ink {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let i = (y * width + x) * 4
                    rgba[i] = 0; rgba[i + 1] = 0; rgba[i + 2] = 0
                }
            }
        }
        return rgba
    }

    private func block(_ rect: CGRect, role: V2Role = .dialogue) -> V2Block {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let line = V2Line(polygon: corners, bounds: rect, vertical: false, detectionScore: 1)
        return V2Block(id: 0, lines: [line], bounds: rect, polygon: corners, vertical: false, readingOrder: 0,
                       sourceText: "", balloon: nil, role: role)
    }

    private let strokes = [CGRect(x: 110, y: 82, width: 6, height: 36), CGRect(x: 130, y: 97, width: 40, height: 6),
                           CGRect(x: 190, y: 82, width: 6, height: 36), CGRect(x: 230, y: 82, width: 30, height: 5)]

    @Test func erasesInkAndItsFringeButNotTheBalloon() {
        let width = 400, height = 200
        let rgba = page(ink: strokes)
        let mask = V2RemovalMask.build(rgba: rgba, width: width, height: height,
                                       blocks: [block(CGRect(x: 100, y: 75, width: 170, height: 50))], layout: [])
        #expect(mask.count == width * height)
        #expect(mask.allSatisfy { $0 == 0 || $0 == 255 })
        var inkPixels = 0, covered = 0
        for rect in strokes {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    inkPixels += 1
                    if mask[y * width + x] != 0 { covered += 1 }
                }
            }
        }
        #expect(covered == inkPixels)
        // Antialias fringe: one pixel beyond every stroke edge is erased too.
        #expect(mask[100 * width + 109] == 255 && mask[100 * width + 116] == 255)
        // Far from any stroke (blank balloon inside and outside the ROI) stays untouched.
        #expect(mask[30 * width + 30] == 0 && mask[160 * width + 350] == 0 && mask[110 * width + 215] == 0)
        // Recall-first halo stays within 10 px of a stroke (artwork false-positive guard).
        let near = strokes.map { $0.insetBy(dx: -10, dy: -10) }
        var far = 0
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] != 0 {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if !near.contains(where: { $0.contains(point) }) { far += 1 }
            }
        }
        #expect(far == 0)
    }

    @Test func blankBlockAndBackgroundRoleEraseNothing() {
        let width = 400, height = 200
        let blank = V2RemovalMask.build(rgba: page(ink: []), width: width, height: height,
                                        blocks: [block(CGRect(x: 100, y: 75, width: 170, height: 50))], layout: [])
        #expect(blank.reduce(0) { $0 + ($1 != 0 ? 1 : 0) } < 200)
        let skipped = V2RemovalMask.build(rgba: page(ink: strokes), width: width, height: height,
                                          blocks: [block(CGRect(x: 100, y: 75, width: 170, height: 50), role: .background)],
                                          layout: [])
        #expect(skipped.allSatisfy { $0 == 0 })
        #expect(V2RemovalMask.build(rgba: [], width: width, height: height, blocks: [], layout: []).allSatisfy { $0 == 0 })
    }

    @Test func blockTouchingPageEdgeIsClipped() {
        let width = 120, height = 60
        let rgba = page(width: width, height: height, ink: [CGRect(x: 0, y: 10, width: 8, height: 40)])
        let mask = V2RemovalMask.build(rgba: rgba, width: width, height: height,
                                       blocks: [block(CGRect(x: -20, y: 5, width: 60, height: 50))], layout: [])
        #expect(mask.count == width * height)
        #expect(mask[30 * width + 3] == 255)
    }

    @Test func morphologyMatchesBruteForce() {
        let w = 23, h = 17
        var state: UInt32 = 7
        let plane = (0..<(w * h)).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
        for radius in [1, 3, 9] {
            for isMax in [true, false] {
                var fast = plane
                V2RemovalMask.morph(&fast, width: w, height: h, radius: radius, max: isMax)
                for y in 0..<h {
                    for x in 0..<w {
                        var v: Float = isMax ? -.infinity : .infinity
                        for yy in max(0, y - radius)...min(h - 1, y + radius) {
                            for xx in max(0, x - radius)...min(w - 1, x + radius) {
                                v = isMax ? max(v, plane[yy * w + xx]) : min(v, plane[yy * w + xx])
                            }
                        }
                        #expect(fast[y * w + x] == v)
                    }
                }
            }
        }
        let blurred = V2RemovalMask.boxBlur([Float](repeating: 0.5, count: w * h), width: w, height: h, radius: 4)
        #expect(blurred.allSatisfy { abs($0 - 0.5) < 1e-5 })
    }

    @Test func lineThicknessUsesMinimumAreaRectangle() {
        let angle = 0.3, length: Double = 200, thickness: Double = 40
        let ux = cos(angle), uy = sin(angle)
        let zero: Double = 0
        let quad = [(zero, zero), (length, zero), (length, thickness), (zero, thickness)].map { u, v in
            CGPoint(x: 50 + u * ux - v * uy, y: 50 + u * uy + v * ux)
        }
        #expect(abs(V2RemovalMask.minimumRectSide(quad) - thickness) < 1e-6)
    }

    private static func noise(_ count: Int, seed: UInt32, levels: UInt32 = 1 << 24) -> [Float] {
        var state = seed
        return (0..<count).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float((state >> 8) % levels) / Float(levels)
        }
    }

    @Test func closingPairMatchesTwoMorphs() {
        let w = 31, h = 19
        let plane = Self.noise(w * h, seed: 11)
        for radius in [1, 2, 5, 12] {
            for firstMax in [true, false] {
                var reference = plane
                V2RemovalMask.morph(&reference, width: w, height: h, radius: radius, max: firstMax)
                V2RemovalMask.morph(&reference, width: w, height: h, radius: radius, max: !firstMax)
                var fused = plane
                let space = V2RemovalMask.Workspace(width: w, height: h)
                fused.withUnsafeMutableBufferPointer {
                    V2RemovalMask.morph2($0.baseAddress!, width: w, height: h, radius: radius, firstMax: firstMax, space: space)
                }
                #expect(fused == reference)
            }
        }
    }

    /// The classic two-pass 3x3 chamfer raster scan (the pre-optimisation implementation).
    private static func referenceChamfer(_ plane: [Float], width w: Int, height h: Int) -> [Float] {
        let a: Float = 0.955, b: Float = 1.3693, far: Float = 1e6
        var d = plane.map { $0 > 0 ? far : 0 }
        for y in 0..<h {
            for x in 0..<w where d[y * w + x] > 0 {
                var v = d[y * w + x]
                if x > 0 { v = min(v, d[y * w + x - 1] + a) }
                if y > 0 {
                    v = min(v, d[(y - 1) * w + x] + a)
                    if x > 0 { v = min(v, d[(y - 1) * w + x - 1] + b) }
                    if x + 1 < w { v = min(v, d[(y - 1) * w + x + 1] + b) }
                }
                d[y * w + x] = v
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] > 0 {
                var v = d[y * w + x]
                if x + 1 < w { v = min(v, d[y * w + x + 1] + a) }
                if y + 1 < h {
                    v = min(v, d[(y + 1) * w + x] + a)
                    if x + 1 < w { v = min(v, d[(y + 1) * w + x + 1] + b) }
                    if x > 0 { v = min(v, d[(y + 1) * w + x - 1] + b) }
                }
                d[y * w + x] = v
            }
        }
        return d
    }

    @Test func chamferMatchesClassicRasterScan() {
        for (w, h) in [(1, 1), (1, 9), (9, 1), (2, 2), (37, 23)] {
            for seed: UInt32 in [1, 2, 3] {
                // Sparse and dense seeds, including a patch away from the borders.
                let random = Self.noise(w * h, seed: seed)
                for cut: Float in [0.05, 0.6] {
                    var plane = random.map { $0 > cut ? Float(1) : 0 }
                    #expect(V2RemovalMask.chamfer(plane, width: w, height: h) == Self.referenceChamfer(plane, width: w, height: h))
                    let inverse = plane.map { $0 > 0 ? Float(0) : 1 }
                    var fast = [Float](repeating: 0, count: w * h)
                    plane.withUnsafeBufferPointer { p in
                        fast.withUnsafeMutableBufferPointer {
                            V2RemovalMask.chamfer(p.baseAddress!, into: $0.baseAddress!, width: w, height: h, inverted: true)
                        }
                    }
                    #expect(fast == Self.referenceChamfer(inverse, width: w, height: h))
                    plane = [Float](repeating: 0, count: w * h)
                    if w > 4, h > 4 { for y in 2..<(h - 2) { for x in 3..<(w - 1) { plane[y * w + x] = 1 } } }
                    #expect(V2RemovalMask.chamfer(plane, width: w, height: h) == Self.referenceChamfer(plane, width: w, height: h))
                }
            }
        }
    }

    @Test func selectionOrderStatisticsMatchSorting() {
        for count in [1, 2, 3, 10, 101, 1000] {
            // Few levels so ties are common.
            let plane = Self.noise(count, seed: UInt32(count), levels: 7)
            let indices = Array(0..<count)
            let sorted = plane.sorted()
            #expect(V2RemovalMask.orderMedian(plane, at: indices) == V2RemovalMask.median(plane))
            for q: Float in [0, 10, 50, 90, 100] {
                #expect(V2RemovalMask.orderPercentile(plane, at: indices, q) == V2RemovalMask.percentile(sorted: sorted, q))
            }
        }
    }
}
