import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeTypographyCleanupFrameTests {
    @Test(arguments: [0.0, 40.0])
    func exteriorPixelsUseNormalizedFrameWithoutChangingOriginalPayload(offset: Double) throws {
        let value: [String: Any] = ["id": "cleanup-frame", "text": "검증", "sourceTextOnly": false,
            "sourceBounds": [0.25, 0.25, 0.25, 0.25], "sourceFrame": [0, 0, 80, 80],
            "x": 42, "y": 23 + offset, "width": 20, "height": 18, "fontSize": 8, "lineHeight": 9.6,
            "fontScript": "korean", "wrappingScript": "korean", "balancedColumn": true]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: value))
        let originalFrame = CGRect(x: 0, y: 0, width: 80, height: 80)
        let normalizedFrame = originalFrame.offsetBy(dx: 0, dy: offset)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 80, height: 80), sourceRect: originalFrame,
            viewport: CGSize(width: 80, height: 80 + offset * 2), items: [item])
        var source = NativeRestorationPixels(width: 80, height: 80)
        for i in 0..<source.count {
            let gray: UInt8 = i / 80 < 50 ? 235 : 0
            source.rgba.replaceSubrange(i * 4..<i * 4 + 4, with: [gray, gray, gray, 255])
        }
        let image = try #require(source.image())
        var repaired = NativeRestorationPixels(width: 20, height: 20)
        repaired.rgba = [UInt8](repeating: 255, count: repaired.count * 4)
        repaired.layoutSafe = [UInt8](repeating: 1, count: repaired.count)
        repaired.erasureComplete = true
        repaired.sourceErasureVerified = true
        repaired.surfaceQuality = ["safe": true, "coefficients": [[255.0, 0, 0], [255.0, 0, 0], [255.0, 0, 0]]]
        let crop = CGRect(x: 20, y: 20, width: 20, height: 20)
        let prepared = NativeSpatialSourceCrop.Prepared(pixels: repaired, crop: crop, source: crop,
            box: CGRect(x: 0, y: 0, width: 20, height: 20), auxiliary: [], excluded: [], marks: [],
            leadingRule: false, sx: 1, sy: 1, synthetic: [])
        let candidate = try #require(NativeRestorationCandidate(prepared: prepared, repaired: repaired,
            luminance: [UInt8](repeating: 255, count: repaired.count), imageSize: layout.imageSize, frame: normalizedFrame, item: item))
        var restoration = NativeTranslationRestoration.Result()
        restoration.cleanupGeometry = .init(frame: normalizedFrame, clip: CGRect(origin: .zero, size: layout.viewport))
        restoration.patches = [.init(image: try #require(candidate.image()), rect: crop.offsetBy(dx: 0, dy: offset),
            itemID: item.id, surfaceQuality: repaired.surfaceQuality, candidate: candidate)]
        restoration.appearances[item.id] = .init(foreground: CGColor(gray: 0, alpha: 1), background: CGColor(gray: 1, alpha: 1),
            restored: true, erasureComplete: true)
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        let context = NativeTypographyPostPolish.rendererGrowthSession(layout: layout, restoration: restoration,
            settings: settings, sourceImage: image).context
        let shaped = context.candidate(item)
        #expect(context.inspectedSurface(shaped, allowExterior: true, lookupLimit: 65_536) != nil)
        #expect(context.sourceFrame == normalizedFrame && context.layout.sourceRect == originalFrame)
        #expect(context.layout.items[0].sourceFrame == item.sourceFrame)
        if offset != 0 {
            // Refresh shares caches. A different source frame must not reuse the
            // successful exterior sample from the previous image placement.
            restoration.cleanupGeometry = nil
            let staleFrame = context.refreshed(restoration: restoration, layout: layout)
            #expect(staleFrame.inspectedSurface(shaped, allowExterior: true, lookupLimit: 65_536) == nil)
        }
    }
}
