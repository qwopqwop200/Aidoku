import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeTextPaintGeometryTests {
    @Test(arguments: [
        [23.195930681272998, 86.73797607421875],
        [19.751686426828076, 88.46009826660156],
    ])
    func centeredInlineWidthNarrowsBeforeAbsoluteFloatAnchor(_ values: [Double]) throws {
        // Actual iOS native Core Text widths and frozen WebKit paint anchors.
        // Using the raw double width selects the adjacent lower FloatPoint.
        let box = NativeTextPaintGeometry.FlexBox(origin: 0, width: 26.5625)
        let relative = try #require(box.lineOrigin(lineWidth: CGFloat(values[0])))
        let point = try #require(NativeTextPaintGeometry.paintOrigin(
            CGPoint(x: 85.0546875 + relative, y: 287), deviceScale: 3))
        #expect(point.x == CGFloat(values[1]))
        #expect(CGFloat(Float(85.0546875 + (26.5625 - values[0]) / 2)) != point.x)
        #expect(box.lineOrigin(lineWidth: CGFloat(values[0]), alignment: 0) == 0)
        #expect(box.lineOrigin(lineWidth: CGFloat(values[0]), alignment: 1) == CGFloat(26.5625 - values[0]))
    }

    // Actual macOS WebKit full-line Range origins; the widths come from Canvas.
    // Wrapped rows are supplied explicitly, so these do not test line breaking.
    @Test(arguments: [
        [183.1875, 84.34574890136719, 84.34574890136719, 90.4130630493164],
        [183.1875, 84.34574890136719, 72.9314956665039, 96.12019348144531],
        [183.1875, 396.8482666015625, 156.59323120117188, 54.29713439941406],
        [100.015625, 396.8482666015625, 72.9314956665039, 54.54206466674805],
        [183.1875, 39.45999526977539, 39.45999526977539, 112.86375427246094],
        [70, 39.45999526977539, 39.45999526977539, 56.27000427246094],
        [183.1875, 16.7705020904541, 16.7705020904541, 124.20849609375],
        [55.234375, 78.9055404663086, 29.002002716064453, 54.116188049316406],
    ])
    func anonymousFlexLineOriginsMatchObservedWebCoordinates(_ values: [Double]) throws {
        let box = try #require(NativeTextPaintGeometry.anonymousFlexBox(contentWidth: CGFloat(values[0]),
            maximumContentWidth: CGFloat(values[1])))
        let relative = try #require(box.lineOrigin(lineWidth: CGFloat(values[2])))
        #expect(abs(41 + relative - CGFloat(values[3])) < 0.00004)
    }

    @Test(arguments: [[0.0, 41.0], [1.0, 139.8417510986328]])
    func sourceAlignmentAppliesToBothFlexAndLinePlacement(_ values: [Double]) throws {
        let alignment = CGFloat(values[0])
        let box = try #require(NativeTextPaintGeometry.anonymousFlexBox(contentWidth: 183.1875,
            maximumContentWidth: 84.34574890136719, justification: alignment))
        let relative = try #require(box.lineOrigin(lineWidth: 84.34574890136719, alignment: alignment))
        #expect(abs(41 + relative - CGFloat(values[1])) < 0.00004)
    }

    @Test func baselineUsesLayoutUnitsBeforeDevicePixelRounding() throws {
        // Raw Float(1/6)*3 rounds to 1; truncation to 1/64 must precede it.
        let positive = try #require(NativeTextPaintGeometry.paintOrigin(CGPoint(x: 90.4130625, y: 1.0 / 6), deviceScale: 3))
        let negative = try #require(NativeTextPaintGeometry.paintOrigin(CGPoint(x: -2, y: -1.0 / 6), deviceScale: 3))
        #expect(positive.y == 0 && negative.y == 0)
        #expect(positive.x == CGFloat(Float(90.4130625)))
        let tie = try #require(NativeTextPaintGeometry.paintOrigin(CGPoint(x: 0, y: -0.5), deviceScale: 1))
        #expect(tie.y == 0)
    }

    @Test func malformedGeometryDoesNotReachFloatOrIntegerConversions() {
        #expect(NativeTextPaintGeometry.anonymousFlexBox(contentWidth: .nan, maximumContentWidth: 20) == nil)
        #expect(NativeTextPaintGeometry.anonymousFlexBox(contentWidth: 20, maximumContentWidth: .infinity) == nil)
        #expect(NativeTextPaintGeometry.paintOrigin(CGPoint(x: 0, y: CGFloat.infinity), deviceScale: 3) == nil)
        #expect(NativeTextPaintGeometry.paintOrigin(.zero, deviceScale: 0) == nil)
    }
}
