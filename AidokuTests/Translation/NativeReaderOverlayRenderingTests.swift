import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct NativeReaderOverlayRenderingTests {
    @Test func opaqueSampledPanelsKeepFiniteReadableInkAcrossByteColors() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        for value in 0...255 {
            // The green/blue permutations include exactly representable byte colors
            // whose converted luminance was rounded below the low endpoint at alpha=1.
            for channels in [[value, value, value], [value, (value * 37) % 256, (value * 73) % 256]] {
                let surface = try #require(CGColor(colorSpace: space, components: channels.map { CGFloat($0) / 255 } + [1]))
                let ink = NativeTranslationRenderer.panelForeground(surface, opacity: 1)
                let rgb = try #require(ink.components)
                let finite = rgb.allSatisfy { $0.isFinite }
                #expect(finite)
                #expect(rgb.last == 1)
            }
        }
        let dark = NativeTranslationRenderer.panelForeground(CGColor(red: 1, green: 1, blue: 1, alpha: 1), opacity: 1)
        let light = NativeTranslationRenderer.panelForeground(CGColor(red: 0, green: 0, blue: 0, alpha: 1), opacity: 1)
        #expect(dark.components?.prefix(3).map { Int(($0 * 255).rounded()) } == [17, 18, 23])
        #expect(light.components?.prefix(3).map { Int(($0 * 255).rounded()) } == [255, 255, 255])
    }

    @Test(arguments: ["Hello, world!", "말풍선 안의 번역", "縦書きの台詞", "对白与标点。"])
    func shapedTextIsCompleteAndPaintsInsideHorizontalPanel(text: String) throws {
        let available = CGSize(width: 220, height: 100)
        let layout = NativeTranslationTypography.layout(text: text, in: available, style: .init(fontSize: 18))
        #expect(layout.fits)
        #expect(layout.visibleUTF16Range == NSRange(location: 0, length: text.utf16.count))
        #expect(layout.lineCount > 0)
        #expect(CGRect(origin: .zero, size: available).insetBy(dx: -1, dy: -1).contains(layout.inkBounds))
        let bitmap = UIGraphicsImageRenderer(size: available, format: bitmapFormat()).image {
            NativeTranslationTypography.draw(layout: layout, in: $0.cgContext)
        }
        #expect(try paintedPixelCount(bitmap) > 20)
    }

    @Test(arguments: ["こんにちは。", "한국어 세로 조판"])
    func verticalGlyphsPaintAndKeepTheirCompleteString(text: String) throws {
        let size = CGSize(width: 100, height: 240)
        let layout = NativeTranslationTypography.layout(text: text, in: size, style: .init(fontSize: 18, vertical: true))
        #expect(layout.fits)
        #expect(layout.visibleUTF16Range.length == text.utf16.count)
        #expect(layout.inkBounds.height > layout.inkBounds.width)
        let bitmap = UIGraphicsImageRenderer(size: size, format: bitmapFormat()).image {
            NativeTranslationTypography.draw(layout: layout, in: $0.cgContext)
        }
        #expect(try paintedPixelCount(bitmap) > 20)
    }

    @Test func overflowIsReportedRatherThanAcceptedAsAClippedSuccess() {
        for vertical in [false, true] {
            let text = String(repeating: "overflow text ", count: 30)
            let layout = NativeTranslationTypography.layout(text: text, in: CGSize(width: 30, height: 30),
                                                            style: .init(fontSize: 20, vertical: vertical))
            #expect(!layout.fits)
        }
    }

    @Test(arguments: [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: CGFloat.infinity, height: 10)])
    func invalidTextPanelHasNoGlyphOutput(size: CGSize) {
        let layout = NativeTranslationTypography.layout(text: "visible", in: size, style: .init(fontSize: 18))
        #expect(!layout.fits)
        #expect(layout.visibleUTF16Range.length == 0)
        #expect(layout.lineCount == 0)
    }

    @Test(arguments: IPhoneOverlayMode.allCases)
    func renderingModeKeepsTranslationAndReservedSourceGeometry(mode: IPhoneOverlayMode) throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = mode
        let item = BrowserOverlayItem(rect: CGRect(x: 100, y: 150, width: 180, height: 110),
                                      sourceText: "Hello", translatedText: "안녕, 그대", confidence: 1,
                                      sourceOrientation: .horizontal)
        let size = CGSize(width: 600, height: 900)
        let viewport = CGSize(width: 300, height: 450)
        let layout = try NativeTranslationLayoutPlanner.plan(items: [item], imageSize: size,
            sourceRect: CGRect(origin: .zero, size: viewport), settings: settings, targetLanguage: "ko", viewport: viewport)
        let card = try #require(layout.items.first)
        #expect(card.text.contains("안녕, 그대"))
        let sourceRect = card.sourceRect(in: size)
        #expect(abs(sourceRect.minX - item.rect.minX) < 0.001 && abs(sourceRect.minY - item.rect.minY) < 0.001)
        #expect(abs(sourceRect.width - item.rect.width) < 0.001 && abs(sourceRect.height - item.rect.height) < 0.001)
        #expect(card.rect.minX >= -0.5 && card.rect.minY >= -0.5)
        #expect(card.rect.maxX <= viewport.width + 0.5 && card.rect.maxY <= viewport.height + 0.5)
        #expect(card.fontSize > 0)
        if mode == .originalAndTranslation { #expect(card.text.contains("Hello")) }
    }

    @Test func storedLayoutReplaysExactlyTheSameNativePixels() async throws {
        let size = CGSize(width: 300, height: 450)
        let item = BrowserOverlayItem(rect: CGRect(x: 35, y: 70, width: 180, height: 90),
                                      sourceText: "HELLO", translatedText: "다시 그려도 같은 번역", confidence: 1,
                                      sourceOrientation: .horizontal)
        let settings = ReaderTranslationSettings.defaultOverlay
        let initial = try await NativeTranslationRenderer.render(image: nil, imageSize: size, items: [item],
            settings: settings, targetLanguage: "ko", viewport: size, scale: 1, aspectFit: false)
        let replay = try await NativeTranslationRenderer.render(image: nil, imageSize: size, items: [item],
            settings: settings, targetLanguage: "ko", viewport: size, scale: 1, aspectFit: false,
            preparedLayout: initial.layoutData)
        #expect(try pixels(initial.image).bytes == pixels(replay.image).bytes)
        #expect(initial.renderedItemCount == 1 && replay.renderedItemCount == 1)
        let decoded = try JSONDecoder().decode(NativeTranslationLayout.self, from: replay.layoutData)
        #expect(decoded.viewport == size)
        #expect(decoded.version == NativeTranslationLayout.currentVersion)
    }

    @Test func reusablePlanDoesNotApplyFontCohortGrowthTwice() throws {
        let size = CGSize(width: 300, height: 150)
        let items = try [CGPoint(x: 10, y: 10), CGPoint(x: 180, y: 80)].enumerated().map { index, point in
            let descriptor: [String: Any] = ["id": "cohort-\(index)", "text": "문자", "x": point.x, "y": point.y,
                "width": 100, "height": 50, "fontSize": 5, "lineHeight": 6, "fontScript": "korean", "wrappingScript": "korean",
                "sourceTextOnly": false, "sourceColorEligible": true, "sourceFontSize": 20,
                "sourceBounds": [point.x / 300, point.y / 150, 100.0 / 300, 50.0 / 150], "sourceFrame": [0,0,300,150]]
            return try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        }
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: items)
        let first = try NativeTranslationRenderer.renderSynchronously(layout: layout, image: nil, settings: ReaderTranslationSettings.defaultOverlay)
        let reusable = try JSONDecoder().decode(NativeTranslationLayout.self, from: first.layoutData)
        #expect(reusable == layout)
        let replay = try NativeTranslationRenderer.renderSynchronously(layout: reusable, image: nil, settings: ReaderTranslationSettings.defaultOverlay)
        let firstPixels = try pixels(first.image).bytes, replayPixels = try pixels(replay.image).bytes
        #expect(firstPixels == replayPixels)
    }

    @Test(arguments: [CGFloat(0), CGFloat(22), CGFloat(-22)])
    func rotatedTextPaintsWithoutTouchingDistantArtwork(rotation: CGFloat) throws {
        let size = CGSize(width: 220, height: 220)
        let card = try descriptor(rotation: rotation, vertical: false)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: [card])
        let result = try NativeTranslationRenderer.renderSynchronously(layout: layout, image: nil,
                                                                      settings: ReaderTranslationSettings.defaultOverlay)
        let frame = try pixels(result.image)
        #expect(result.renderedItemCount == 1)
        #expect(try paintedPixelCount(result.image) > 20)
        // A centered 120 x 60 card rotated by 22 degrees cannot reach these margins.
        let distantPixels = (0..<frame.height).flatMap { y in
            (0..<frame.width).filter { x in x < 15 || x >= 205 || y < 15 || y >= 205 }.map { x in
                frame.bytes[y * frame.bytesPerRow + x * 4 + 3]
            }
        }
        #expect(distantPixels.allSatisfy { $0 == 0 })
    }

    @Test func keptSourceLetteringDoesNotEraseOrTypesetTheProtectedBox() async throws {
        let size = CGSize(width: 80, height: 80)
        let source = UIGraphicsImageRenderer(size: size, format: bitmapFormat()).image {
            UIColor.red.setFill(); $0.fill(CGRect(origin: .zero, size: size))
        }
        let protected = BrowserOverlayItem(rect: CGRect(x: 10, y: 10, width: 50, height: 50), sourceText: "SFX",
            translatedText: "SFX", confidence: 1, keepsSourceLettering: true)
        let result = try await NativeTranslationRenderer.render(image: source, imageSize: size, items: [protected],
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: size, aspectFit: false)
        #expect(result.renderedItemCount == 0)
        #expect(try pixels(result.image).bytes == pixels(source).bytes)
    }

    @Test func cancelledLayoutAndRenderPublishNoResult() async {
        let task = Task { @MainActor in
            return try await NativeTranslationRenderer.render(image: nil, imageSize: CGSize(width: 80, height: 80),
                items: [], settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: CGSize(width: 80, height: 80))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let planner = Task { @MainActor in
            return try await NativeTranslationLayoutPlanner.prepareLayoutData(items: [], imageSize: CGSize(width: 80, height: 80),
                sourceRect: CGRect(x: 0, y: 0, width: 80, height: 80), settings: ReaderTranslationSettings.defaultOverlay,
                targetLanguage: "ko", viewport: CGSize(width: 80, height: 80))
        }
        planner.cancel()
        await #expect(throws: CancellationError.self) { try await planner.value }
    }

    @Test func koreanWrappingPreservesCharactersAndKeepsClosingPunctuationOffLineStart() throws {
        let text = "그대는 (정말로) 다음 장으로 넘어갈 생각인가?"
        let lines = try #require(NativeTranslationTypography.koreanLines(text: text,
            available: CGSize(width: 110, height: 220), style: .init(fontScript: "korean", fontSize: 18)))
        #expect(lines.joined() == text)
        #expect(lines.count > 1)
        let closing: Set<Character> = [")", "]", "}", "!", "?", ",", "."]
        #expect(lines.dropFirst().allSatisfy { line in
            guard let first = line.first(where: { !$0.isWhitespace }) else { return false }
            return !closing.contains(first)
        })
    }

    @Test func browserAssetVersionAndInsufficientRasterDensityAreRejected() throws {
        let size = CGSize(width: 80, height: 80)
        let source = UIGraphicsImageRenderer(size: size, format: bitmapFormat()).image {
            UIColor.white.setFill(); $0.fill(CGRect(origin: .zero, size: size))
        }
        let region = ReaderTranslationRegion(id: "density", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2),
                                             source: "Hello", translation: "안녕")
        let asset = ReaderTranslationRenderAsset(typography: try #require(source.pngData()),
            layers: .init(masks: [], surfaces: [], paintBounds: []), displayRect: CGRect(origin: .zero, size: size),
            sourceSize: size, regions: [region], sourceDigest: ReaderTranslationRenderAsset.digestSource(source), typographySize: size)
        #expect(asset.isValid)
        #expect(asset.supportsOutputSize(size))
        #expect(!asset.supportsOutputSize(CGSize(width: 160, height: 160)))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(asset)) as? [String: Any])
        object["version"] = 2
        let browserAsset = try JSONDecoder().decode(ReaderTranslationRenderAsset.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(!browserAsset.isValid)
        #expect(!browserAsset.matches(regions: [region], sourceSize: size,
                                      sourceDigest: ReaderTranslationRenderAsset.digestSource(source)))
    }

    @Test func legacyBrowserLayoutCannotBeReplayedAsNativePlan() async throws {
        let size = CGSize(width: 80, height: 80)
        let legacyPayload = Data("[{\"id\":\"old\",\"text\":\"stale\"}]".utf8)
        let item = BrowserOverlayItem(rect: CGRect(x: 10, y: 10, width: 60, height: 40), sourceText: "Hello",
                                      translatedText: "현재 번역", confidence: 1, sourceOrientation: .horizontal)
        let result = try await NativeTranslationRenderer.render(image: nil, imageSize: size, items: [item],
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: size,
            aspectFit: false, preparedLayout: legacyPayload)
        let layout = try JSONDecoder().decode(NativeTranslationLayout.self, from: result.layoutData)
        #expect(layout.items.map(\.text) == ["현재 번역"])
        #expect(result.renderedItemCount == 1)
    }

    private func descriptor(rotation: CGFloat, vertical: Bool) throws -> NativeTranslationLayoutItem {
        let object: [String: Any] = ["id": "fixed", "text": "안녕, 그대", "x": 50, "y": 80, "width": 120, "height": 60,
            "fontSize": 18, "lineHeight": 22, "paddingTop": 4, "paddingBottom": 4, "paddingLeft": 4, "paddingRight": 4,
            "rotation": Double(rotation), "vertical": vertical, "sourceTextOnly": false, "clipsText": true,
            "sourceBounds": [0.2, 0.3, 0.4, 0.2], "sourceFrame": [50, 80, 120, 60], "fontScript": "korean", "wrappingScript": "korean", "lightSurface": true]
        return try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func bitmapFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return format
    }

    private func pixels(_ image: UIImage) throws -> NativeOCRRGBAFrame {
        try #require(image.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
    }

    private func paintedPixelCount(_ image: UIImage) throws -> Int {
        let frame = try pixels(image)
        return stride(from: 0, to: frame.bytes.count, by: 4).filter { frame.bytes[$0 + 3] > 50 }.count
    }
}
