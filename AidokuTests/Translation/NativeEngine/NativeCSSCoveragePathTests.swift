import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCSSCoveragePathTests {
    private func points(_ path: CGPath) -> [CGPoint] {
        var result: [CGPoint] = []
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                result.append(element.pointee.points[0])
            }
        }
        return result
    }

    @Test func absoluteSVGTranslatesIndividualFloatVertices() throws {
        // Actual real25/panel7 CSS union M0,0 H33.84375 V59.359375 H0.
        let owner = CGRect(x: 117.34375, y: 240.125, width: 33.84375, height: 59.359375)
        let declaration = try #require(NativeCSSCoveragePath.declaration(coverage: [owner], origin: owner.origin, commands: .absolute))
        let reference = NativeSourceCanvasClip.referenceRect(domRect: owner, deviceScale: 3)
        let path = try #require(NativeCSSCoveragePath.path(declaration, referenceBox: reference))
        let actual = points(path)
        #expect(actual[0].x == CGFloat(Float(117 + 1.0 / 3)))
        #expect(actual[1].x == CGFloat(Float(Float(117 + 1.0 / 3) + Float(33.84375))))
        #expect(actual[1].x - actual[0].x == 33.84375762939453)
        // A translated CGRect/addRect preserves the old Double width instead.
        #expect(actual[1].x - actual[0].x != owner.width)
    }

    @Test func relativeReverseCommandRetainsItsFloatAccumulation() throws {
        let coverage = CGRect(x: 10.1, y: -1.2, width: 0.2, height: 0.7)
        let absolute = try #require(NativeCSSCoveragePath.declaration(coverage: [coverage], origin: CGPoint(x: 10, y: -2), commands: .absolute))
        let relative = try #require(NativeCSSCoveragePath.declaration(coverage: [coverage], origin: CGPoint(x: 10, y: -2), commands: .relative))
        #expect(absolute.subpaths[0][3].x == absolute.subpaths[0][0].x)
        #expect(relative.subpaths[0][3].x != relative.subpaths[0][0].x)
        #expect(relative.subpaths[0][3].x == CGFloat(Float(Float(0.1) + Float(0.2)) + Float(-0.2)))
    }

    @Test func copiedLocalDeclarationMovesWithoutRebuildingCoverage() throws {
        let frame = CGRect(x: -10.25, y: -3.5, width: 40.25, height: 30.25)
        let pieces = [CGRect(x: -12.4, y: -1.2, width: 9.7, height: 13.3), CGRect(x: 5.1, y: 3.2, width: 8.3, height: 11.1)]
        let declaration = try #require(NativeCSSCoveragePath.declaration(coverage: pieces, origin: frame.origin, commands: .relative))
        var copied = NativeTranslationSourceStylePostPolish.Panel(rect: frame, background: [20, 40, 60], coverage: pieces, clipped: true, coverageClip: declaration)
        copied.rect.origin.x += 17.03125
        copied.rect.size.width += 3
        let stored = try #require(copied.coverageClip)
        let path = try #require(NativeCSSCoveragePath.path(stored, referenceBox: copied.rect))
        #expect(points(path).count == 8)
        #expect(copied.coverage == pieces)
        #expect(copied.coverageClip?.subpaths == declaration.subpaths)
        #expect(points(path)[0].x == CGFloat(Float(Double(Float(copied.rect.minX)) + Double(Float(declaration.subpaths[0][0].x)))))
    }

    @Test func percentInsetReevaluatesAgainstTheClipReferenceSize() throws {
        let owner = CGRect(x: 150.25, y: 20.25, width: 33.84375, height: 59.359375)
        let declaration = try #require(NativeCSSCoveragePath.inset([10, 20, 30, 40], unit: .percent))
        let reference = NativeSourceCanvasClip.referenceRect(domRect: owner, deviceScale: 2)
        let border = NativeTranslationPDFCapture.snappedRect(owner, deviceScale: 2)
        #expect(reference.width == 34 && border.width == 33.5)
        let path = try #require(NativeCSSCoveragePath.path(declaration, referenceBox: reference))
        let resized = try #require(NativeCSSCoveragePath.path(declaration, referenceBox: CGRect(x: reference.minX, y: reference.minY, width: 60, height: 80)))
        #expect(points(path)[0].x == CGFloat(Float(reference.minX) + Float(13.6)))
        #expect(points(resized)[0].x == CGFloat(Float(reference.minX) + Float(24)))
        #expect(points(path)[0] != points(resized)[0])
    }

    @Test func snappedZeroSizeIsAValidEmptyShapeOrNegativeInsetExpansion() throws {
        let owner = CGRect(x: 10.25, y: 20.25, width: 0.1, height: 0.1)
        let reference = NativeSourceCanvasClip.referenceRect(domRect: owner, deviceScale: 2)
        #expect(reference.width == 0 && reference.height == 0)
        let empty = try #require(NativeCSSCoveragePath.inset([0, 0, 0, 0], unit: .pixels))
        let emptyPath = try #require(NativeCSSCoveragePath.path(empty, referenceBox: reference))
        #expect(points(emptyPath).count == 5)
        #expect(emptyPath.boundingBoxOfPath.width == 0)
        let grown = try #require(NativeCSSCoveragePath.inset([-1, -2, -3, -4], unit: .pixels))
        let grownPath = try #require(NativeCSSCoveragePath.path(grown, referenceBox: reference))
        #expect(grownPath.boundingBoxOfPath.width == 6 && grownPath.boundingBoxOfPath.height == 4)
    }

    @Test func emptyInsetReplacesAPendingPathAndClipsAllPaint() throws {
        let owner = CGRect(x: 0, y: 0, width: 10, height: 10)
        let declaration = try #require(NativeCSSCoveragePath.inset([0, 11, 0, 0], unit: .pixels))
        var pixels = [UInt8](repeating: 0, count: 20 * 20 * 4)
        try pixels.withUnsafeMutableBytes { memory in
            let context = try #require(CGContext(data: memory.baseAddress, width: 20, height: 20,
                bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // A pending path must not turn a genuine empty CSS shape into paint.
            context.addRect(CGRect(x: 0, y: 0, width: 20, height: 20))
            NativeTranslationRenderer.applyCoverageClip(declaration, coverage: [owner], owner: owner, context: context, pixelSnapScale: 1)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        #expect(pixels.allSatisfy { $0 == 0 })
    }
}
