import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCertifiedExteriorSurfaceTests {
    @Test(arguments: [(true, false, false), (true, true, true), (false, true, false)])
    func actualExteriorLightingToleranceRequiresBothColumnAndSourceCertificate(flags: (Bool, Bool, Bool)) throws {
        let (balanced, verified, accepted) = flags
        let value: [String: Any] = ["id": "exterior-certificate", "text": "검증", "sourceTextOnly": false,
            "sourceBounds": [0.25, 0.25, 0.25, 0.25], "sourceFrame": [0, 0, 80, 80],
            "x": 42, "y": 23, "width": 20, "height": 18, "fontSize": 8, "lineHeight": 9.6,
            "fontScript": "korean", "wrappingScript": "korean", "balancedColumn": balanced]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: value))
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 80, height: 80), sourceRect: CGRect(x: 0, y: 0, width: 80, height: 80),
            viewport: CGSize(width: 80, height: 80), items: [item])
        var source = NativeRestorationPixels(width: 80, height: 80)
        for i in 0..<source.count { source.rgba.replaceSubrange(i * 4..<i * 4 + 4, with: [235, 235, 235, 255]) }
        let image = try #require(source.image())
        var repaired = NativeRestorationPixels(width: 20, height: 20)
        repaired.rgba = [UInt8](repeating: 255, count: repaired.count * 4)
        repaired.layoutSafe = [UInt8](repeating: 1, count: repaired.count)
        repaired.erasureComplete = true
        repaired.sourceErasureVerified = verified
        repaired.surfaceQuality = ["safe": true, "coefficients": [[255.0, 0, 0], [255.0, 0, 0], [255.0, 0, 0]]]
        let prepared = NativeSpatialSourceCrop.Prepared(pixels: repaired, crop: CGRect(x: 20, y: 20, width: 20, height: 20),
            source: CGRect(x: 20, y: 20, width: 20, height: 20), box: CGRect(x: 0, y: 0, width: 20, height: 20),
            auxiliary: [], excluded: [], marks: [], leadingRule: false, sx: 1, sy: 1, synthetic: [])
        let candidate = try #require(NativeRestorationCandidate(prepared: prepared, repaired: repaired,
            luminance: [UInt8](repeating: 255, count: repaired.count), imageSize: layout.imageSize, frame: layout.sourceRect, item: item))
        var restoration = NativeTranslationRestoration.Result()
        restoration.patches = [.init(image: try #require(candidate.image()), rect: prepared.crop, itemID: item.id, surfaceQuality: repaired.surfaceQuality, candidate: candidate)]
        restoration.appearances[item.id] = .init(foreground: CGColor(gray: 0, alpha: 1), background: CGColor(gray: 1, alpha: 1),
            restored: true, erasureComplete: true)
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        let context = NativeTypographyPostPolish.rendererGrowthSession(layout: layout, restoration: restoration,
            settings: settings, sourceImage: image).context
        let shaped = context.candidate(item)
        #expect(context.contentFits(shaped))
        #expect(shaped.inkFrame.minX > prepared.crop.maxX)
        let range = context.inspectedSurface(shaped, allowExterior: true, lookupLimit: 65_536)
        #expect((range != nil) == accepted)
    }
}
