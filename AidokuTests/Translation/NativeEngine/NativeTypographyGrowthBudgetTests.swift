import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeTypographyGrowthBudgetTests {
    private func session() throws -> (NativeTypographyPostPolish.RendererGrowthSession, NativeTranslationLayoutItem) {
        let value: [String: Any] = ["id": "budget", "text": "안녕 세상", "sourceTextOnly": false,
            "sourceColorEligible": true, "sourceBounds": [0.25, 0.25, 0.25, 0.25], "sourceFrame": [0, 0, 80, 80],
            "sourceFontSize": 14, "allowsAutomaticFontRecovery": true,
            "x": 20, "y": 20, "width": 40, "height": 40, "fontSize": 8,
            "lineHeight": 9.6, "fontScript": "korean", "wrappingScript": "korean", "paddingTop": 0,
            "paddingBottom": 0, "paddingLeft": 0, "paddingRight": 0]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: value))
        let frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        let bitmap = try #require(CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(frame)
        let image = try #require(bitmap.makeImage())
        var restoration = NativeTranslationRestoration.Result()
        restoration.patches = [.init(image: image, rect: frame, itemID: item.id,
            layoutSafe: [UInt8](repeating: 1, count: 6400), surfaceLuminance: [UInt8](repeating: 255, count: 6400))]
        // A successfully appended canvas can retain source ink outside the new
        // lettering. That independent certificate does not remove membership.
        restoration.appearances[item.id] = .init(foreground: CGColor(gray: 0, alpha: 1), background: CGColor(gray: 1, alpha: 1),
            restored: true, erasureComplete: false)
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        return (NativeTypographyPostPolish.rendererGrowthSession(layout: layout, restoration: restoration,
            settings: settings, sourceImage: image), item)
    }

    @Test func appendedCanvasMembershipYieldsToFinalTextSurfaceProof() throws {
        let (session, item) = try session()
        #expect(session.context.restored(item.id))
        #expect(session.context.holdsSurface(session.context.candidate(item)))
        #expect(session.sourcePanelTextFit(id: item.id) == nil)
        session.context.growth.registered = true; session.context.growth.admitted.insert(item.id)
        session.commitArtwork(item: item, originalFont: item.fontSize, restoredInside: false)
        #expect(!session.context.restored(item.id) && !session.lateWordRepairEntry(id: item.id))
        #expect(session.sourcePanelTextFit(id: item.id) == "caption")
        session.commitArtwork(item: item, originalFont: item.fontSize, restoredInside: true)
        #expect(session.context.restored(item.id) && session.lateWordRepairEntry(id: item.id))
        #expect(session.sourcePanelTextFit(id: item.id) == "inside")
        let refreshed = session.context.refreshed(restoration: session.context.restoration, layout: session.context.layout)
        #expect(refreshed.growth === session.context.growth && refreshed.reader === session.context.reader)
    }

    @Test func balloonSurfaceLoanChargesActualLookupAndCachedRepeatCostsZero() throws {
        let (session, item) = try session()
        let candidate = session.context.candidate(item)
        session.balloonSurfaceRemaining = 65_536
        let originalLookup = session.restoredLookupRemaining
        #expect(session.context.holdsSurface(candidate, usesBalloonBudget: true))
        let remaining = session.balloonSurfaceRemaining
        #expect(remaining < 65_536 && remaining > 0)
        #expect(session.restoredLookupRemaining == originalLookup)
        #expect(session.context.holdsSurface(candidate, usesBalloonBudget: true))
        #expect(session.balloonSurfaceRemaining == remaining)
        session.balloonSurfaceRemaining = 0
        #expect(!session.context.holdsSurface(candidate, usesBalloonBudget: true))
    }

    @Test func actualGrowthProposalsShareTypePoolAndAuxiliarySearchRestoresIt() throws {
        let (session, item) = try session()
        let context = session.context, original = context.candidate(item)
        session.balloonTypeRemaining = 0
        #expect(context.growthLayout(item, size: 10, allowWide: true, liftWide: false, lift: false,
            extraBreaks: 1, original: original, search: .init(), others: [item]) == nil)
        #expect(session.balloonTypeRemaining == 0 && session.balloonSurfaceRemaining == 2_097_152)
        session.balloonTypeRemaining = 32_768
        _ = context.growthLayout(item, size: 10, allowWide: true, liftWide: false, lift: false,
            extraBreaks: 1, original: original, search: .init(), others: [item])
        #expect(session.balloonTypeRemaining < 32_768)
        let saved = [session.balloonTypeRemaining, session.balloonSurfaceRemaining, session.restoredExteriorRemaining]
        _ = context.growthLayout(item, size: 10, allowWide: true, liftWide: false, lift: false, display: true,
            extraBreaks: 1, original: original, search: .init(), others: [item])
        #expect([session.balloonTypeRemaining, session.balloonSurfaceRemaining, session.restoredExteriorRemaining] == saved)
        #expect(context.growth.balloonDisplayRemaining < 1_048_576)
    }

    @Test func retryDoesNotResurrectDeletedDisplayGrowthFromOriginalSnapshot() throws {
        let (session, item) = try session()
        var original = item
        original.typesettingDisplayGrowth = "balloon"
        session.context.growth.original[item.id] = original
        #expect(session.context.growing(item, cap: 0, others: [item]) == nil)
        #expect(session.context.growth.original[item.id]?.typesettingDisplayGrowth == nil)
    }
}
