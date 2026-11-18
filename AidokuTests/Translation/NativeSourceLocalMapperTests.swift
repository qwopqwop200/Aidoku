import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Exercises the production adapter only; no models, corpus pixels, or renderer calls.
struct NativeSourceLocalMapperTests {
    private func source() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 80, height: 120,
            bitsPerComponent: 8, bytesPerRow: 80 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
        return try #require(context.makeImage())
    }

    private func layout(_ frame: CGRect) -> NativeTranslationLayout {
        NativeTranslationLayout(imageSize: CGSize(width: 80, height: 120),
            sourceRect: frame, viewport: CGSize(width: 160, height: 240), items: [])
    }

    private func number(_ item: [String: Any], _ key: String) throws -> Double {
        try #require(item[key] as? NSNumber).doubleValue
    }

    private func canonical(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    @Test func letterboxCornersBecomeExactSourceCorners() throws {
        let image = try source()
        // A centered 80x120 source displayed at half size with viewport margins.
        let mapper = try NativeMainEnsembleRenderer.sourceLocalMapper(
            layout: layout(CGRect(x: 12, y: 20, width: 40, height: 60)), source: image)
        let whole = mapper.map(["x": 12.0, "y": 20.0, "width": 40.0, "height": 60.0])
        let end = mapper.map(["x": 52.0, "y": 80.0])
        #expect(try number(whole, "x") == 0)
        #expect(try number(whole, "y") == 0)
        #expect(try number(whole, "width") == Double(image.width))
        #expect(try number(whole, "height") == Double(image.height))
        #expect(try number(end, "x") == Double(image.width))
        #expect(try number(end, "y") == Double(image.height))
        #expect(whole["sourceFrame"] as? [Double] == [0, 0, 80, 120])
        #expect(whole["enableVerticalDisplayTitles"] as? Bool == true)
    }

    @Test func typographyUsesHorizontalScaleWhileVerticalGeometryUsesVerticalScale() throws {
        let mapper = try NativeMainEnsembleRenderer.sourceLocalMapper(
            layout: layout(CGRect(x: 12, y: 20, width: 40, height: 30)), source: source())
        let row = mapper.map([
            "x": 17.0, "y": 23.0, "width": 10.0, "height": 5.0,
            "fontSize": 6.0, "sourceFontSize": 7.0, "lineHeight": 8.0,
            "paddingLeft": 1.0, "paddingRight": 2.0,
            "paddingTop": 3.0, "paddingBottom": 4.0, "inspectionHeight": 9.0
        ])
        #expect(mapper.sx == 2)
        #expect(mapper.sy == 4)
        let expected: [String: Double] = [
            "x": 10, "y": 12, "width": 20, "height": 20,
            "fontSize": 12, "sourceFontSize": 14, "lineHeight": 16,
            "paddingLeft": 2, "paddingRight": 4,
            "paddingTop": 12, "paddingBottom": 16, "inspectionHeight": 36
        ]
        for (key, value) in expected { #expect(try number(row, key) == value) }
    }

    @Test func normalizedSourceEvidenceAndOwnerIdentityRemainUnchanged() throws {
        let image = try source()
        let mapper = try NativeMainEnsembleRenderer.sourceLocalMapper(
            layout: layout(CGRect(x: 12, y: 20, width: 40, height: 30)), source: image)
        let evidence: [String: Any] = [
            "id": "owner-a", "text": "A\u{301} 글",
            "sourceBounds": [0.25, 0.5, 0.25, 0.25],
            "sourcePolygon": [[0.25, 0.5], [0.5, 0.5], [0.5, 0.75], [0.25, 0.75]],
            "sourceQuad": [[0.25, 0.5], [0.5, 0.5], [0.5, 0.75], [0.25, 0.75]],
            "auxiliaryInkRects": [[0.1, 0.2, 0.05, 0.05]],
            "auxiliaryInkPolygons": [[[0.1, 0.2], [0.15, 0.2], [0.1, 0.25]]],
            "unitMemberRects": [[0.25, 0.5, 0.25, 0.25]],
            "balloonLayoutRectNormalized": [0.1, 0.2, 0.8, 0.7],
            "textExpansionPolicy": ["maskRectNormalized": [0.1, 0.2, 0.8, 0.7],
                "maskIntervalRowsNormalized": [[0.1, 0.3, 0.6, 0.9]]],
            "lineHeightEm": 1.2, "trackingEm": 0.0, "typographyGroupID": "group-a"
        ]
        let original = try canonical(evidence)
        let mapped = mapper.map(evidence)
        let retained = mapped.filter { evidence[$0.key] != nil }
        #expect(try canonical(retained) == original)
        #expect(try canonical(evidence) == original)
        // Source evidence remains directly usable against original pixels, without
        // applying the letterbox offset or anisotropic viewport scale a second time.
        let bounds = try #require(mapped["sourceBounds"] as? [Double])
        let pixels = CGRect(x: bounds[0] * Double(image.width), y: bounds[1] * Double(image.height),
            width: bounds[2] * Double(image.width), height: bounds[3] * Double(image.height))
        #expect(pixels == CGRect(x: 20, y: 60, width: 20, height: 30))
    }

    @Test func nestedAlternativesUseSameSourceFrameWithoutMutatingEvidence() throws {
        let mapper = try NativeMainEnsembleRenderer.sourceLocalMapper(
            layout: layout(CGRect(x: 12, y: 20, width: 40, height: 30)), source: source())
        let leaf: [String: Any] = ["x": 17.0, "y": 23.0, "width": 10.0, "height": 5.0,
            "fontSize": 6.0, "lineHeight": 8.0, "sourceBounds": [0.25, 0.5, 0.25, 0.25]]
        let input: [String: Any] = ["uprightAlternative": leaf,
            "columnLayout": ["uprightAlternative": leaf, "columnLayout": leaf]]
        let original = try canonical(input)
        let mapped = mapper.map(input)
        let upright = try #require(mapped["uprightAlternative"] as? [String: Any])
        let column = try #require(mapped["columnLayout"] as? [String: Any])
        let nestedUpright = try #require(column["uprightAlternative"] as? [String: Any])
        let nestedColumn = try #require(column["columnLayout"] as? [String: Any])
        for row in [upright, nestedUpright, nestedColumn] {
            #expect(try number(row, "x") == 10)
            #expect(try number(row, "y") == 12)
            #expect(try number(row, "fontSize") == 12)
            #expect(try number(row, "lineHeight") == 16)
            #expect(row["sourceBounds"] as? [Double] == [0.25, 0.5, 0.25, 0.25])
            #expect(row["sourceFrame"] as? [Double] == [0, 0, 80, 120])
        }
        #expect(try canonical(input) == original)
    }

    @Test func invalidSourceFramesRefuseMapperBeforeProducingCoordinates() throws {
        let image = try source()
        let invalid: [CGRect] = [
            .zero,
            CGRect(x: 12, y: 20, width: 0, height: 30),
            CGRect(x: 12, y: 20, width: 40, height: 0),
            CGRect(x: CGFloat.nan, y: 20, width: 40, height: 30),
            CGRect(x: 12, y: CGFloat.infinity, width: 40, height: 30),
            CGRect(x: 12, y: 20, width: CGFloat.infinity, height: 30),
            CGRect(x: 12, y: 20, width: 40, height: CGFloat.nan)
        ]
        for frame in invalid {
            #expect(throws: NativeTranslationRenderer.RenderError.self) {
                _ = try NativeMainEnsembleRenderer.sourceLocalMapper(layout: layout(frame), source: image)
            }
        }
    }
}
