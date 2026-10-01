import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCaptionPanelBackgroundTests {
    @Test(arguments: [false, true], [false, true])
    func onlyPlainPanelsCanBeTrimmedAfterRuleImageRestoration(hasImage: Bool, hasForeignFills: Bool) throws {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let original = CGRect(x: 0, y: 0, width: 100, height: 40)
        let context = try #require(CGContext(data: nil, width: 100, height: 40, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(original)
        let image = try #require(context.makeImage())
        var panel = NativeTranslationSourceStylePostPolish.Panel(rect: original, background: [255,255,255], coverage: [original])
        panel.sourceFrameImage = hasImage ? image : nil
        let a = NativeTranslationCaptionPanelPolish.Entry(id: "a", sourceTextOnly: false, rotation: 0, vertical: false,
            lettering: nil, wrappingScript: "korean", font: 10, frame: frame, sources: [CGRect(x: 42, y: 12, width: 16, height: 6)],
            balancedColumn: false, column: nil, columnPaddingTop: 0, ink: CGRect(x: 40, y: 10, width: 20, height: 10),
            panels: [panel], hasForeignFills: hasForeignFills)
        let b = NativeTranslationCaptionPanelPolish.Entry(id: "b", sourceTextOnly: false, rotation: 0, vertical: false,
            lettering: nil, wrappingScript: "korean", font: 10, frame: frame, sources: [CGRect(x: 5, y: 12, width: 10, height: 8)],
            balancedColumn: false, column: nil, columnPaddingTop: 0, ink: CGRect(x: 5, y: 12, width: 10, height: 8), panels: [])
        let output = NativeTranslationCaptionPanelPolish.polish([a,b], opacity: 1, kept: [])
        #expect(output[0].panels.count == 1 && output[0].ink == a.ink)
        let result = try #require(output[0].panels.first)
        #expect(result.rect == (hasImage || hasForeignFills ? original : CGRect(x: 36, y: 0, width: 28, height: 40)))
        if hasImage {
            #expect(result.sourceFrameImage === image)
            #expect(result.coverage == [original])
        } else {
            #expect(result.sourceFrameImage == nil)
        }
    }
}
