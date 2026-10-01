import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeFinalExportPanelContourAcceptanceTests {
    struct Fixture {
        var reference: [UInt8]
        var actual: [UInt8]
        var card: [String: Any]
        var layers: [[String: Any]]
        let edgePixel: Int
        let width = 180
        let height = 180
        func evaluate() -> NativeFinalExportPanelContourAcceptance.Evidence? {
            NativeFinalExportPanelContourAcceptance.evaluate(reference: reference, actual: actual,
                width: width, height: height, scale: 1, nativeCard: card, webLayers: layers)
        }
    }

    static func fixture() -> Fixture {
        let frame = CGRect(x: 40, y: 30, width: 70, height: 100), angle = 0.2
        let t = CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: angle).translatedBy(x: -frame.midX, y: -frame.midY)
        var transform = t
        let path = CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: &transform)
        let rect: [Double] = [40,30,70,100], ink: [Double] = [60,70,30,20]
        let panel: [String: Any] = ["rect": rect, "coverage": [rect], "radius": 6.0,
            "background": [32,64,48], "overflowClip": false, "sourceBridgeClipped": false]
        let card: [String: Any] = ["id": "rotated-caption", "sourceBackgroundKind": "rotated-panel",
            "hidden": false, "removed": false, "drawsPanel": false, "foreignFills": [Any](),
            "backings": [Any](), "panels": [panel], "rect": rect, "ink": ink, "rotation": angle]
        let bounds = frame.applying(t)
        let style: [String: Any] = ["display": "block", "overflow": "visible", "backgroundImage": "none",
            "opacity": "1", "scale": "none", "rotate": "none", "translate": "none", "borderRadius": "6px",
            "backgroundColor": "rgb(32, 64, 48)", "left": "40px", "top": "30px", "width": "70px", "height": "100px",
            "transform": "matrix(\(cos(angle)), \(sin(angle)), \(-sin(angle)), \(cos(angle)), 0, 0)",
            "transformOrigin": "35px 50px", "clipPath": "none"]
        let web: [String: Any] = ["id": "rotated-caption", "kind": "source-rotated-panel", "parentKind": "root",
            "childElementCount": 0, "style": style, "rect": ["x": Double(bounds.minX),"y": Double(bounds.minY),"width": Double(bounds.width),"height": Double(bounds.height)]]
        let item: [String: Any] = ["id": "rotated-caption", "kind": "item", "ink": ["x": 60.0,"y": 70.0,"width": 30.0,"height": 20.0]]
        var bytes = [UInt8](repeating: 255, count: 180 * 180 * 4)
        for y in 0..<180 {
            for x in 0..<180 where path.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let offset = (y * 180 + x) * 4
                bytes[offset] = 32; bytes[offset + 1] = 64; bytes[offset + 2] = 48
            }
        }
        // Independent right-edge midpoint, rotated around the declared center.
        let midpoint = CGPoint(x: frame.maxX, y: frame.midY).applying(t)
        let pixel = Int(floor(midpoint.y)) * 180 + Int(floor(midpoint.x))
        var reference = bytes, actual = bytes
        reference.replaceSubrange(pixel*4..<pixel*4+4, with: [143,160,152,255])
        actual.replaceSubrange(pixel*4..<pixel*4+4, with: [121,140,131,255])
        return Fixture(reference: reference, actual: actual, card: card, layers: [web,item], edgePixel: pixel)
    }

    @Test func onlyTheMatchedRoundedEdgeReceivesEvidence() throws {
        let f = Self.fixture()
        // Recorded JSON supplies Double/NSNumber values; preserve that schema in the fixture.
        let webRect = f.layers[0]["rect"] as? [String: Double]
        let numericRectangle = webRect != nil
        #expect(numericRectangle)
        let result = f.evaluate()
        let evidence = try #require(result)
        let exactIndices = evidence.certifiedPixels == [f.edgePixel]
        #expect(exactIndices)
    }

    @Test(arguments: ["fill", "radius", "rotation", "image", "child", "clip", "nonfinite"])
    func semanticOrGeometryMismatchCannotBorrowTheEdge(kind: String) {
        var f = Self.fixture(), style = f.layers[0]["style"] as! [String: Any]
        switch kind {
        case "fill": style["backgroundColor"] = "rgb(40, 64, 48)"
        case "radius": style["borderRadius"] = "7px"
        case "rotation": f.card["rotation"] = 0.3
        case "image": style["backgroundImage"] = "linear-gradient(red, blue)"
        case "child": f.layers[0]["childElementCount"] = 1
        case "clip": style["clipPath"] = "polygon(0px 0px, 30px 0px, 30px 100px, 0px 100px)"
        default: f.card["rotation"] = Double.nan
        }
        f.layers[0]["style"] = style
        let missing = f.evaluate() == nil
        #expect(missing)
    }

    @Test func changingInteriorDoesNotReceivePanelEvidence() {
        var f = Self.fixture(); f.actual = f.reference
        let offset = (55 * f.width + 75) * 4
        f.actual.replaceSubrange(offset..<offset+4, with: [240,240,240,255])
        let missing = f.evaluate() == nil
        #expect(missing)
    }

    @Test func unrelatedHueAtTheBoundaryIsNotAntialiasing() {
        var f = Self.fixture()
        f.actual.replaceSubrange(f.edgePixel*4..<f.edgePixel*4+4, with: [250,5,70,255])
        let missing = f.evaluate() == nil
        #expect(missing)
    }

    @Test func alphaChangeAtTheBoundaryIsRejected() {
        var f = Self.fixture(); f.actual[f.edgePixel*4+3] = 200
        let missing = f.evaluate() == nil
        #expect(missing)
    }

    @Test func onePixelOfAddedPanelThicknessFailsMaterialArea() {
        var f = Self.fixture()
        let original = f.actual
        for y in 1..<(f.height - 1) {
            for x in 1..<(f.width - 1) {
                var neighbor = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        let offset = ((y + dy) * f.width + x + dx) * 4
                        neighbor = neighbor || (original[offset] == 32 && original[offset+1] == 64 && original[offset+2] == 48)
                    }
                }
                if neighbor {
                    let offset = (y * f.width + x) * 4
                    f.actual.replaceSubrange(offset..<offset+4, with: [32,64,48,255])
                }
            }
        }
        let missing = f.evaluate() == nil
        #expect(missing)
    }
    @Test(arguments: [Double.nan, Double.infinity, 0.0, 4.01, 1e-100, 1e100])
    func nonfiniteOrUnrepresentableScaleReturnsNoCertificate(scale: Double) {
        let f = Self.fixture()
        let evidence = NativeFinalExportPanelContourAcceptance.evaluate(reference: f.reference, actual: f.actual,
            width: f.width, height: f.height, scale: scale, nativeCard: f.card, webLayers: f.layers)
        let missing = evidence == nil
        #expect(missing)
    }

    @Test func enormousMalformedDimensionsCannotOverflowOrAllocate() {
        let f = Self.fixture()
        let evidence = NativeFinalExportPanelContourAcceptance.evaluate(reference: f.reference, actual: f.actual,
            width: Int.max, height: Int.max, scale: 1, nativeCard: f.card, webLayers: f.layers)
        let missing = evidence == nil
        #expect(missing)
    }

    @Test func excessiveEdgeChangeCannotUseAConstantFillAsAWaiver() {
        var f = Self.fixture()
        f.reference.replaceSubrange(f.edgePixel*4..<f.edgePixel*4+4, with: [255,255,255,255])
        f.actual.replaceSubrange(f.edgePixel*4..<f.edgePixel*4+4, with: [32,64,48,255])
        let missing = f.evaluate() == nil
        #expect(missing)
    }

    @Test func matchedButExtremeFiniteGeometryIsRejectedBeforeCoreGraphics() {
        var f = Self.fixture()
        let frame = CGRect(x: 1e300, y: 1e300, width: 1e300, height: 1e300)
        let box: [Double] = [1e300,1e300,1e300,1e300]
        var panels = f.card["panels"] as! [[String: Any]]
        panels[0]["rect"] = box; panels[0]["coverage"] = [box]
        f.card["rect"] = box; f.card["panels"] = panels
        var style = f.layers[0]["style"] as! [String: Any]
        for key in ["left", "top", "width", "height"] { style[key] = "1e300px" }
        style["transformOrigin"] = "5e299px 5e299px"
        f.layers[0]["style"] = style
        let transform = CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: 0.2).translatedBy(x: -frame.midX, y: -frame.midY)
        let bounds = frame.applying(transform)
        f.layers[0]["rect"] = ["x": Double(bounds.minX),"y": Double(bounds.minY),"width": Double(bounds.width),"height": Double(bounds.height)]
        let missing = f.evaluate() == nil
        #expect(missing)
    }

}
