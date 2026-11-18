import CoreGraphics
import CoreText
import Foundation
import Darwin
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeFinalTextPaintAdmissionTests {
    private func image(width: Int, height: Int, rectangles: [CGRect], white: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
        for rect in rectangles { context.fill(rect) }
        return try #require(context.makeImage())
    }
    private func page(_ w: Int = 160, _ h: Int = 120) throws -> CGImage {
        try image(width: w, height: h, rectangles: [CGRect(x: 0, y: 0, width: w, height: h)], white: true)
    }
    private func square(_ id: String, x: Int, y: Int) throws -> NativeAOTTranslationPageComposer.TranslatedFillPrimitive {
        var p = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(
            image: try image(width: 8, height: 8, rectangles: [CGRect(x: 0, y: 0, width: 8, height: 8)]),
            frame: CGRect(x: x, y: y, width: 8, height: 8), fontOutputPixels: 10)
        p.ownerID = id
        return p
    }

    @Test func actualAlphaAllowsDisjointInkInsideOverlappingRectangles() throws {
        let ring = try image(width: 24, height: 24, rectangles: [CGRect(x: 0, y: 0, width: 24, height: 2),
            CGRect(x: 0, y: 22, width: 24, height: 2), CGRect(x: 0, y: 0, width: 2, height: 24),
            CGRect(x: 22, y: 0, width: 2, height: 24)])
        var a = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image: ring,
            frame: CGRect(x: 20, y: 20, width: 24, height: 24), fontOutputPixels: 10)
        a.hasFinalEffects = true
        var b = try square("inside", x: 28, y: 28); b.hasFinalEffects = true
        let placed = try NativeFinalTextPaintAdmission.place([a, b], page: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(placed.fills[0].frame == a.frame)
        #expect(placed.fills[1].frame == b.frame)
    }

    @Test func shadowOnlyCollisionIsResolvedWithoutFontOrTextLoss() throws {
        var a = try square("shadow-owner", x: 20, y: 30)
        a.sourceStyle = .init(sourceFontPixels: 10, bands: [], shadow: .init(rgb: [50, 50, 50], offset: [24, 0]))
        let b = try square("peer", x: 46, y: 30)
        let result = try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(restored: page(), fills: [a, b],
            expectedItems: 2, textComplete: true)
        let placements = try #require(result.audit["finalPaintAdmission"] as? [[String: Any]])
        let shift = try #require(placements[1]["shiftOutputPixels"] as? [CGFloat])
        #expect(shift != [0, 0])
        #expect(result.complete && result.paintedItems == 2)
        #expect(placements.allSatisfy { $0["fontChanged"] as? Bool == false })
        #expect(result.audit["finalPaintBoundsChecked"] as? Bool == true)
    }

    @Test func pageEdgesIncludeOutlineBandsAndNegativeShadowOffset() throws {
        var p = try square("edge", x: 0, y: 0)
        p.sourceStyle = .init(sourceFontPixels: 10, bands: [.init(rgb: [40, 70, 100], width: 4)],
            shadow: .init(rgb: [90, 90, 90], offset: [-10, -5]))
        let result = try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(restored: page(), fills: [p],
            expectedItems: 1, textComplete: true)
        let placements = try #require(result.audit["finalPaintAdmission"] as? [[String: Any]])
        let shift = try #require(placements[0]["shiftOutputPixels"] as? [CGFloat])
        #expect(shift[0] >= 10 && shift[1] >= 5)
        #expect(placements[0]["effectsIncluded"] as? Bool == true)
        #expect(placements[0]["pageContained"] as? Bool == true)
    }

    @Test func impossibleFootprintFailsInsteadOfClippingOrDroppingOwner() throws {
        let fill = try square("cannot-fit", x: 0, y: 0)
        #expect(throws: NativeFinalTextPaintAdmission.Failure.self) {
            _ = try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(restored: page(8, 8), fills: [fill],
                expectedItems: 1, textComplete: true)
        }
    }

    @Test func recoveryRastersShareTheSameCollisionGateWithoutPaintingEffectsAgain() throws {
        var a = try square("a", x: 20, y: 20), b = try square("b", x: 20, y: 20)
        a.hasFinalEffects = true; b.hasFinalEffects = true
        let result = try NativeFinalTextPaintAdmission.place([a, b], page: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!result.fills[0].frame.intersects(result.fills[1].frame))
        #expect(result.audit.allSatisfy { $0["paintedPixels"] as? Int == 64 })
    }

    @Test func oneBlockedInitialBodyKeepsIndependentBodyTarget() throws {
        let key = "AIDOKU_LOCAL_INITIAL_BODY_FALLBACK"
        let previous = ProcessInfo.processInfo.environment[key]
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        setenv(key, "1", 1)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        var good = try square("good", x: 36, y: 36)
        var blocked = try square("blocked", x: 170, y: 80)
        good.hasFinalEffects = true; blocked.hasFinalEffects = true
        func packet(_ id: String, _ rect: [Double]) -> NativeBalloonPlacement {
            .init(bodyID: id, rectNormalized: rect, biasNormalized: [0, 0], flow: .row,
                  paddingEm: 0, gapEm: 0, maskSHA256: String(repeating: "a", count: 64), order: 0)
        }
        good.balloonPlacement = packet("body-good", [0.1, 20.0/120, 0.2, 40.0/120])
        blocked.balloonPlacement = packet("body-blocked", [0.65, 20.0/120, 0.2, 40.0/120])
        good.placementDomain = { CGRect(x: 20, y: 20, width: 40, height: 40).contains($0) }
        blocked.placementDomain = { CGRect(x: 170, y: 80, width: 8, height: 8).contains($0) }
        let result = try NativeFinalTextPaintAdmission.place([good, blocked], page: bounds)
        let rows = Dictionary(uniqueKeysWithValues: result.audit.map { ($0["owner"] as! String, $0) })
        #expect(rows["good"]?["balloonBodyPlaced"] as? Bool == true)
        #expect(rows["good"]?["balloonTargetRelaxed"] as? Bool == false)
        #expect(rows["blocked"]?["balloonBodyPlaced"] as? Bool == false)
        #expect(rows["blocked"]?["balloonTargetFallbackReason"] as? String == "initial-local-domain-peer")
        #expect(result.fills.count == 2 && result.fills.map(\.fontOutputPixels) == [10, 10])
        #expect(result.fills[0].frame == CGRect(x: 36, y: 36, width: 8, height: 8))
        #expect(result.fills[1].frame == blocked.frame)
    }

    @Test func backtrackingKeepsRestrictedOwnerInsideItsDomain() throws {
        var flexible = try square("flexible", x: 20, y: 20)
        var restricted = try square("restricted", x: 20, y: 20)
        flexible.hasFinalEffects = true; restricted.hasFinalEffects = true
        restricted.placementDomain = { CGRect(x: 20, y: 20, width: 8, height: 8).contains($0) }
        let result = try NativeFinalTextPaintAdmission.place([flexible, restricted],
            page: CGRect(x: 0, y: 0, width: 80, height: 80))
        #expect(result.fills[1].frame == restricted.frame)
        #expect(result.fills[0].frame != flexible.frame)
        #expect(!result.fills[0].frame.intersects(result.fills[1].frame))
    }

    @Test func spatialGridIncludesReadableSpacingAndRemovesBacktrackedLevels() throws {
        typealias Admission = NativeFinalTextPaintAdmission
        let grid = try #require(Admission.PeerGrid(page: CGRect(x: 0, y: 0, width: 2048, height: 1536), count: 8))
        func shape(_ bounds: CGRect, _ readable: CGRect? = nil) -> Admission.Footprint {
            .init(runs: [], bounds: bounds, pixels: 0, readableBounds: readable)
        }
        let left = shape(CGRect(x: 70, y: 120, width: 20, height: 25), CGRect(x: 55, y: 105, width: 75, height: 90))
        let far = shape(CGRect(x: 1300, y: 800, width: 10, height: 10))
        grid.toggle(left, padding: 8, level: 1)
        grid.toggle(far, padding: 8, level: 5)
        let nearReadableEdge = shape(CGRect(x: 139.5, y: 155, width: 5, height: 7))
        #expect(grid.peers(nearReadableEdge, padding: 8) == 2)
        #expect(grid.peers(far, padding: 8) == 32)
        #expect(grid.peers(nearReadableEdge, padding: .nan) == 34)
        #expect(grid.peers(shape(.infinite), padding: 8) == 34)
        grid.toggle(left, padding: 8, level: 1)
        #expect(grid.peers(nearReadableEdge, padding: 8) == 0)
        #expect(grid.peers(far, padding: 8) == 32)
    }

    @Test func packedAlphaMatchesRunScanAtEveryWordAlignment() throws {
        typealias Admission = NativeFinalTextPaintAdmission
        var runs: [Admission.Run] = []
        for y in -8..<16 {
            runs.append(.init(y: y, left: -92 + y % 5, right: -59 + y % 5))
            runs.append(.init(y: y, left: 3 + y % 7, right: 4 + y % 7))
            if y % 4 == 0 { runs.append(.init(y: y, left: 28, right: 194)) }
        }
        let shape = Admission.Footprint(runs: runs, bounds: CGRect(x: -100, y: -8, width: 294, height: 24),
            pixels: runs.reduce(0) { $0 + $1.right - $1.left })
        var budget = 4096
        let bits = try #require(Admission.CollisionBits(shape, remainingWords: &budget))
        var smallBudget = 1
        #expect(Admission.CollisionBits(shape, remainingWords: &smallBudget) == nil)
        let fixed = shape.translated(CGPoint(x: -17, y: 9))
        for dy in [-19, -13, 4, 9, 24, 35] {
            let exact = (-330...330).allSatisfy { dx in
                let moving = shape.translated(CGPoint(x: dx, y: dy))
                let byWords = bits.intersects(bits, dx: -17, dy: 9, otherDX: dx, otherDY: dy)
                return byWords == Admission.intersects(fixed, moving)
            }
            #expect(exact)
        }
    }

    @Test func repeatedSearchFailureRechecksChangedDomain() throws {
        let page = CGRect(x: 0, y: 0, width: 180, height: 180)
        let narrow = CGRect(x: 30, y: 30, width: 60, height: 60)
        let frame = CGRect(x: 44, y: 44, width: 32, height: 32)
        let raster = try image(width: 32, height: 32, rectangles: [CGRect(origin: .zero, size: frame.size)])
        var fills = ["a", "b"].map { owner in
            var fill = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image: raster, frame: frame,
                fontOutputPixels: 10)
            fill.ownerID = owner
            fill.hasFinalEffects = true
            fill.placementDomain = { narrow.contains($0) }
            fill.certifyNativeDomainSubrects()
            return fill
        }
        try NativeFinalTextPaintAdmission.withRetainedFootprintMemo {
            func failure(on bounds: CGRect) -> String? {
                do { _ = try NativeFinalTextPaintAdmission.place(fills, page: bounds) }
                catch NativeFinalTextPaintAdmission.Failure.noSafePlacement(let owners) { return owners }
                catch {}
                return nil
            }
            let first = try #require(failure(on: page))
            #expect(failure(on: page) == first)
            var suffix = fills[1]
            suffix.ownerID = "suffix"
            suffix.frame = frame.offsetBy(dx: 72, dy: 10)
            suffix.placementDomain = { page.contains($0) }
            suffix.certifyNativeDomainSubrects()
            fills.append(suffix)
            #expect(failure(on: page) == first)
            fills.removeLast()
            fills[0].ownerID = "renamed"
            #expect(failure(on: page) == "renamed,b")
            fills[1].placementDomain = { page.contains($0) }
            #expect(!fills[1].domainContainsSubrects)
            fills[1].certifyNativeDomainSubrects()
            let revised = try NativeFinalTextPaintAdmission.place(fills, page: page)
            #expect(revised.fills.count == 2)
            #expect(narrow.contains(revised.fills[0].frame))
            #expect(!revised.fills[0].frame.intersects(revised.fills[1].frame))

            let widePage = CGRect(x: 0, y: 0, width: 50_000, height: 180)
            let farDomain = narrow.offsetBy(dx: 40_000, dy: 0)
            for i in fills.indices {
                fills[i].frame = frame.offsetBy(dx: 40_000, dy: 0)
                fills[i].placementDomain = { farDomain.contains($0) }
                fills[i].certifyNativeDomainSubrects()
            }
            #expect(failure(on: widePage) == "renamed,b")
            #expect(failure(on: widePage) == "renamed,b")
        }
    }

    @Test func horizontalFrameAwayFromOriginRetainsEveryGlyph() throws {
        let fill = try #require(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 1]))
        let text = "번역문 전체 보존"
        let item = NativeAOTRawTextPainter.Item(id: "horizontal", text: text,
            frame: CGRect(x: 120, y: 160, width: 140, height: 60), fontSize: 20, lineHeight: 24,
            chosenFill: fill, colorAuthority: "test")
        let result = try NativeAOTRawTextPainter.renderCentered(items: [item],
            rawItems: [["id": "horizontal", "renderPreserveRequestedFontSize": true]],
            viewport: CGSize(width: 400, height: 300), restored: page(400, 300))
        let rows = try #require(result.audit["rawNativeItems"] as? [[String: Any]])
        #expect(rows[0]["writingMode"] as? String == "horizontal-tb")
        #expect(rows[0]["visibleUTF16"] as? Int == text.utf16.count)
        let ink = try #require(rows[0]["retainedFillBoundsOutput"] as? [CGFloat])
        #expect(ink[0] > 60 && ink[1] > 100)
        #expect(result.audit["finalCompositeAlphaVerified"] as? Bool == true)
        #expect(result.complete && result.paintedItems == 1)
    }

    @Test func explicitVerticalWritingReachesMainPainterAndPreservesFullString() throws {
        let fill = try #require(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 1]))
        let text = "日本語の縦書き"
        let item = NativeAOTRawTextPainter.Item(id: "vertical", text: text, frame: CGRect(x: 70, y: 30, width: 35, height: 200),
            fontSize: 20, lineHeight: 24, chosenFill: fill, colorAuthority: "test")
        let result = try NativeAOTRawTextPainter.renderCentered(items: [item],
            rawItems: [["id": "vertical", "vertical": true, "renderPreserveRequestedFontSize": true]],
            viewport: CGSize(width: 200, height: 300), restored: page(200, 300))
        let rows = try #require(result.audit["rawNativeItems"] as? [[String: Any]])
        #expect(rows[0]["writingMode"] as? String == "vertical-rl")
        #expect(rows[0]["sourceUTF16"] as? Int == text.utf16.count)
        #expect(rows[0]["visibleUTF16"] as? Int == text.utf16.count)
        let ink = try #require(rows[0]["retainedFillBoundsOutput"] as? [CGFloat])
        #expect(ink[3] > ink[2] * 2)
        #expect(result.complete)
        #expect(!NativeAOTRawTextPainter.vertical(["sourceVertical": true]))
    }
    @Test func plannedGuardMatchesTheActualSuppliedPaintRadius() throws {
        let key="AIDOKU_RESOLVED_EFFECT_EXTENT", prior=ProcessInfo.processInfo.environment["AIDOKU_RESOLVED_EFFECT_EXTENT"]
        defer { if let prior {setenv(key,prior,1)} else {unsetenv(key)} }
        setenv(key,"1",1)
        let glyph=try image(width:20,height:20,rectangles:[CGRect(x:0,y:0,width:20,height:20)])
        let painted=try NativeMandatoryDisplayStroke.prepare(fill:glyph,restored:page(320,240),
            fontOutputPixels:80,outwardEm:0.0625,fillFrame:CGRect(x:80,y:80,width:20,height:20),forcedEndpoint:255)
        let raw:[String:Any]=["ensembleStrokeRatio":0.0625]
        #expect(painted.outwardPixels==5)
        #expect(NativeTextSpacing.outwardExtent(raw:raw,fontSize:80)==painted.outwardPixels)
        #expect(NativeTextSpacing.outwardExtent(raw:nil,fontSize:80)==16)
        setenv(key,"0",1)
        #expect(NativeTextSpacing.outwardExtent(raw:raw,fontSize:80)==16)
    }

    @Test func fixedFontInkFitsWithoutRequiringTransparentLineLeading() throws {
        let text="가나다라마바사아자차카타파하",size:CGFloat=40
        let font=CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString,size,nil)
        let measured=try NativeFinalTextFlow.horizontalFixedWidth(text:text,font:font,size:size,
            width:170,minimumLineHeight:64,outwardExtent:4,color:CGColor(gray:0,alpha:1))
        let plan=try #require(measured)
        #expect(plan.complete && plan.visibleUTF16==text.utf16.count)
        let ink=plan.inkBounds
        #expect(!ink.isEmpty && !ink.isNull && plan.size.height>ink.height+0.1)
        let tight=(plan.size.height+ink.height)/2
        #expect(plan.centered(height:tight)==nil)
        let retained=try #require(plan.centered(height:tight,usingInkCapacity:true))
        #expect(retained.ranges==plan.ranges && retained.visibleUTF16==plan.visibleUTF16)
        #expect(retained.lines.map(CTLineGetGlyphCount)==plan.lines.map(CTLineGetGlyphCount))
        #expect(CGRect(x:0,y:0,width:170,height:tight).insetBy(dx:-0.01,dy:-0.01).contains(retained.inkBounds))
        #expect(plan.centered(height:ink.height-1,usingInkCapacity:true)==nil)
        for i in plan.baselines.indices.dropFirst() {
            #expect(abs((retained.baselines[i].y-retained.baselines[i-1].y)-(plan.baselines[i].y-plan.baselines[i-1].y))<0.0001)
        }
    }

}
