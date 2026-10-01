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
    private func readableInkFixture(safe: Bool = true, verified: Bool = true, complete: Bool = true,
                                    member: Bool = false) throws -> (NativeTypographyPostPolish.RendererGrowthSession, NativeTranslationLayoutItem) {
        let object: [String: Any] = ["id": "readable-ink", "text": "검증", "sourceTextOnly": false,
            "sourceColorEligible": true, "sourceBounds": [0.25, 0.25, 0.25, 0.25], "sourceFrame": [0, 0, 80, 80],
            "sourceFontSize": 18, "allowsAutomaticFontRecovery": true, "fontScript": "korean", "wrappingScript": "korean",
            "x": 20, "y": 20, "width": 40, "height": 40, "fontSize": 10.5, "lineHeight": 12.6,
            "paddingTop": 0, "paddingRight": 0, "paddingBottom": 0, "paddingLeft": 0]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: object))
        let frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        var original = NativeRestorationPixels(width: 80, height: 80)
        original.rgba = Array(repeating: [UInt8](arrayLiteral: 208, 208, 208, 255), count: original.count).flatMap { $0 }
        var repaired = original
        repaired.layoutSafe = Array(repeating: safe ? 1 : 0, count: repaired.count)
        repaired.erasureComplete = complete; repaired.sourceErasureVerified = verified
        let source = CGRect(x: 20, y: 20, width: 20, height: 20)
        let prepared = NativeSpatialSourceCrop.Prepared(pixels: original, crop: frame, source: source, box: source,
            auxiliary: [], excluded: [], marks: [], leadingRule: false, sx: 1, sy: 1, synthetic: [])
        let candidate = try #require(NativeRestorationCandidate(prepared: prepared, repaired: repaired,
            luminance: Array(repeating: 160, count: repaired.count), imageSize: frame.size, frame: frame, item: item))
        let image = try #require(candidate.image())
        var restoration = NativeTranslationRestoration.Result()
        restoration.patches = [.init(image: image, rect: frame, itemID: item.id, candidate: candidate)]
        restoration.appearances[item.id] = .init(foreground: NativeTranslationRenderer.color([233, 247, 245]),
            background: CGColor(gray: 1, alpha: 1), restored: false, erasureComplete: complete)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        let session = NativeTypographyPostPolish.rendererGrowthSession(layout: layout, restoration: restoration,
            settings: settings, sourceImage: image)
        session.context.growth.registered = true; session.context.growth.admitted.insert(item.id)
        session.context.growth.surfaceInspectable.insert(item.id); session.context.growth.finalized.insert(item.id)
        if member { session.context.growth.restoredInside.insert(item.id) }
        return (session, item)
    }

    @Test func readableInkReadmissionEnablesActualSourceSizedGrowthWithoutChangingGeometryOrMask() throws {
        let (session, item) = try readableInkFixture()
        let candidate = session.context.candidate(item)
        #expect(!session.context.holdsSurface(candidate, requiresCommittedRestoration: false))
        #expect(session.grow(item: item, others: [item], cap: .infinity, strict: false) == nil)
        let patch = try #require(session.context.patches[item.id]?.candidate)
        let originalRGBA = patch.rawRGBA, originalSafe = patch.safe, originalRevision = patch.revision
        let adjustedValue = session.restoreReadableInk(item: item, typography: candidate.shaped, foreground: [233, 247, 245])
        let adjusted = try #require(adjustedValue)
        #expect(NativeTranslationSourceStylePostPolish.luminanceContrast(NativeSourceColorSampler.luminance(adjusted),
            159.5 / 255, 160.5 / 255) >= 4.5)
        #expect(session.sourcePanelTextFit(id: item.id) == "inside" && session.context.restored(item.id))
        let grownValue = session.grow(item: item, others: [item], cap: .infinity, strict: false,
            foreground: NativeTranslationRenderer.color(adjusted.map { CGFloat($0) }))
        let grown = try #require(grownValue)
        #expect(grown.fontSize > item.fontSize && grown.fontSize <= 18 * 0.9)
        #expect(grown.sourceBounds == item.sourceBounds && grown.sourceFrame == item.sourceFrame && grown.text == item.text)
        let unchangedPixels = patch.rawRGBA == originalRGBA && patch.safe == originalSafe
        #expect(unchangedPixels && patch.revision == originalRevision)
    }

    @Test(arguments: ["unsafe", "unverified", "incomplete", "uninspected", "disabled"])
    func readableInkCannotReplaceMissingSourceOrSafeSurfaceProof(_ rejected: String) throws {
        let (session, item) = try readableInkFixture(safe: rejected != "unsafe", verified: rejected != "unverified",
            complete: rejected != "incomplete")
        if rejected == "uninspected" { session.context.growth.surfaceInspectable.remove(item.id) }
        if rejected == "disabled" {
            var settings = session.context.settings
            settings.inpaintingEnabled = false
            let disabled = NativeTypographyPostPolish.rendererGrowthSession(layout: session.context.layout,
                restoration: session.context.restoration, settings: settings, sourceImage: session.context.reader.image)
            disabled.context.growth.registered = true; disabled.context.growth.admitted.insert(item.id)
            disabled.context.growth.surfaceInspectable.insert(item.id)
            #expect(disabled.restoreReadableInk(item: item, typography: disabled.context.candidate(item).shaped,
                foreground: [233, 247, 245]) == nil)
            return
        }
        #expect(session.restoreReadableInk(item: item, typography: session.context.candidate(item).shaped,
            foreground: [233, 247, 245]) == nil)
        #expect(session.sourcePanelTextFit(id: item.id) == "caption" && !session.context.restored(item.id))
    }

    @Test func previouslyAdmittedSurfaceStillRequiresCompleteErasureAndSafeCurrentGlyphs() throws {
        let (session, item) = try readableInkFixture(verified: false, member: true)
        #expect(session.restoreReadableInk(item: item, typography: session.context.candidate(item).shaped,
            foreground: [233, 247, 245]) != nil)
        let (incomplete, other) = try readableInkFixture(verified: false, complete: false, member: true)
        #expect(incomplete.restoreReadableInk(item: other, typography: incomplete.context.candidate(other).shaped,
            foreground: [233, 247, 245]) == nil)
    }

    @Test func restoredHarmonyRequiresTheExpandedGlyphSafetyMargin() throws {
        let (initial, item) = try session()
        let candidate = initial.context.candidate(item)
        let patch = try #require(initial.context.patches[item.id])
        let y = Int(floor(candidate.inkFrame.minY)) - 1
        try #require(y >= 0 && y < 80)
        var safe = [UInt8](repeating: 1, count: 6400)
        for x in 0..<80 { safe[y * 80 + x] = 0 }
        var restoration = initial.context.restoration
        restoration.patches = [.init(image: patch.image, rect: patch.rect, itemID: item.id,
            layoutSafe: safe, surfaceLuminance: [UInt8](repeating: 255, count: 6400))]
        let probe = NativeTypographyPostPolish.rendererGrowthSession(layout: initial.context.layout,
            restoration: restoration, settings: initial.context.settings, sourceImage: initial.context.reader.image)
        #expect(probe.context.holdsSurface(candidate))
        #expect(!probe.holdsSurface(item: item, typography: candidate.shaped))
    }

    @Test(arguments: [false, true])
    func restoredHarmonyChecksCertifiedExteriorAgainstOriginalPixels(_ matchingExterior: Bool) throws {
        let (initial, item) = try session()
        let candidate = initial.context.candidate(item)
        let patch = try #require(initial.context.patches[item.id])
        let smallPatch = candidate.inkFrame.insetBy(dx: 1, dy: 1)
        try #require(smallPatch.width > 0 && smallPatch.height > 0)
        var restoration = initial.context.restoration
        restoration.patches = [.init(image: patch.image, rect: smallPatch, itemID: item.id,
            layoutSafe: [UInt8](repeating: 1, count: 6400), surfaceLuminance: [UInt8](repeating: 255, count: 6400),
            surfaceQuality: ["safe": true, "coefficients": [[255.0, 0, 0], [255.0, 0, 0], [255.0, 0, 0]]])]
        let bitmap = try #require(CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: matchingExterior ? 1 : 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let original = try #require(bitmap.makeImage())
        let probe = NativeTypographyPostPolish.rendererGrowthSession(layout: initial.context.layout,
            restoration: restoration, settings: initial.context.settings, sourceImage: original)
        #expect(probe.holdsSurface(item: item, typography: candidate.shaped) == matchingExterior)
    }

    @Test func restoredWidthAllowanceSpansFontSizesAndPreservesMoveBudget() {
        let search = NativeTypographyPostPolish.GrowthSearch()
        search.movedAttempts = 2
        search.beginWidthPass()
        var acceptedSizes: [CGFloat] = []
        // The recorded source-centred search tries four widths at each of two
        // centres per size. The fifth size gets only its first four widths.
        for size in [CGFloat](arrayLiteral: 19.75, 18, 16.5, 15, 13.25, 11.75) {
            for _ in 0..<8 where search.takeWidthAttempt() { acceptedSizes.append(size) }
        }
        #expect(acceptedSizes.count == 36)
        #expect(acceptedSizes.suffix(4).allSatisfy { $0 == 13.25 })
        #expect(!acceptedSizes.contains(11.75))
        #expect(search.widthPassExhausted && search.movedAttempts == 2)
        search.beginWidthPass()
        #expect(!search.widthPassExhausted && search.widthAttempts == 0 && search.movedAttempts == 2)
        #expect(search.takeWidthAttempt())
    }

    @Test func exhaustedPassCannotSpendMoreTypeWorkAtTheNextFontSize() throws {
        let (session, item) = try session()
        let context = session.context, original = context.candidate(item)
        let search = NativeTypographyPostPolish.GrowthSearch()
        search.beginWidthPass()
        for _ in 0..<36 { #expect(search.takeWidthAttempt()) }
        let before = session.balloonTypeRemaining
        #expect(context.growthLayout(item, size: 10, allowWide: true, liftWide: false, lift: false,
            extraBreaks: 1, original: original, search: search, others: [item]) == nil)
        #expect(search.widthPassExhausted && session.balloonTypeRemaining == before)
        // A separate pass receives its own allowance; the same actual layout
        // now consumes the shared type pool rather than being silently skipped.
        search.beginWidthPass()
        _ = context.growthLayout(item, size: 10, allowWide: true, liftWide: false, lift: false,
            extraBreaks: 1, original: original, search: search, others: [item])
        #expect(session.balloonTypeRemaining < before)
    }

}
