import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCondensedCropSearchTests {
    private func fixture(safeWidth: Int) throws -> (NativeTypographyPostPolish.Context, NativeTranslationLayoutItem) {
        let data = Data(#"{"id":"condensed-crop","text":"검증문구","sourceBounds":[0.25,0.25,0.5,0.5],"sourceFrame":[0,0,80,80],"sourceFontSize":14,"sourceColorEligible":true,"sourceTextOnly":false,"allowsAutomaticFontRecovery":true,"lightSurface":true,"fontScript":"korean","wrappingScript":"korean","x":28,"y":20,"width":24,"height":40,"fontSize":7,"lineHeight":8.4,"paddingTop":0,"paddingRight":0,"paddingBottom":0,"paddingLeft":0}"#.utf8)
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: data)
        let rect = CGRect(x: 0, y: 0, width: 80, height: 80)
        let bitmap = try #require(CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(rect)
        let image = try #require(bitmap.makeImage())
        var safe = [UInt8](repeating: 0, count: 6400)
        if safeWidth > 0 {
            let left = (80 - safeWidth) / 2
            for y in 0..<80 { for x in left..<(left + safeWidth) { safe[y * 80 + x] = 1 } }
        }
        var restoration = NativeTranslationRestoration.Result()
        restoration.patches = [.init(image: image, rect: rect, itemID: item.id,
            layoutSafe: safe, surfaceLuminance: [UInt8](repeating: 255, count: 6400))]
        restoration.appearances[item.id] = .init(foreground: CGColor(gray: 0, alpha: 1),
            background: CGColor(gray: 1, alpha: 1), restored: true, erasureComplete: true)
        let layout = NativeTranslationLayout(imageSize: rect.size, sourceRect: rect, viewport: rect.size, items: [item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceBackgroundColor = true
        let context = NativeTypographyPostPolish.rendererGrowthSession(layout: layout, restoration: restoration,
            settings: settings, sourceImage: nil).context
        let eligible = context.eligible(item), restored = context.restored(item.id)
        try #require(eligible && restored, "Every control must reach the condensed search and its surface proofs")
        return (context, item)
    }

    @Test func safeCropCanOfferACompressedWholeWordBeyondTheOriginalCard() throws {
        let (context, item) = try fixture(safeWidth: 30)
        let original = context.candidate(item)
        let shared = [context.growth.balloonTypeRemaining, context.growth.balloonSurfaceRemaining, context.reader.exteriorBudget]
        let proposal = context.condensed(item, cap: 8.75, others: [item])
        let changed = try #require(proposal)
        #expect(changed.fontSize > item.fontSize)
        #expect(changed.typesettingWidthScale == 0.9)
        #expect(changed.width > item.width)
        #expect(changed.sourceBounds == item.sourceBounds && changed.text == item.text)
        let candidate = context.candidate(changed)
        #expect(candidate.profile.lines == 1 && candidate.profile.breaks.isEmpty)
        #expect(candidate.profile.hangulIsolated <= original.profile.hangulIsolated)
        #expect(context.contentFits(candidate))
        #expect(context.holdsSurface(candidate, expands: true, allowExterior: true))
        #expect(context.growth.balloonCondensedRemaining < 1_048_576)
        #expect(shared == [context.growth.balloonTypeRemaining, context.growth.balloonSurfaceRemaining, context.reader.exteriorBudget])
    }

    @Test func compressionIsRejectedWhenTheSameSizeFitsWithoutIt() throws {
        let (context, item) = try fixture(safeWidth: 80)
        let refused = context.condensed(item, cap: 8.75, others: [item]) == nil
        #expect(refused)
    }

    @Test func missingSafeSurfaceNeverAuthorizesCompressedGrowth() throws {
        let (context, item) = try fixture(safeWidth: 0)
        let refused = context.condensed(item, cap: 8.75, others: [item]) == nil
        #expect(refused)
    }

    @Test func exhaustedCondensedBudgetDoesNotBorrowOrdinaryGrowthBudget() throws {
        let (context, item) = try fixture(safeWidth: 30)
        context.growth.balloonCondensedRemaining = 0
        let shared = [context.growth.balloonTypeRemaining, context.growth.balloonSurfaceRemaining]
        let refused = context.condensed(item, cap: 8.75, others: [item]) == nil
        #expect(refused)
        #expect(shared == [context.growth.balloonTypeRemaining, context.growth.balloonSurfaceRemaining])
    }
}
