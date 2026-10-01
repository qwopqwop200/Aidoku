import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct NativeRenderAsyncBridgeTests {
    @Test func ownedBitmapMatchesOriginalUIKitFormatAndBalancesGraphicsStack() async throws {
        try await Task.detached {
            let size = CGSize(width: 32, height: 24), scale: CGFloat = 3
            let pixels = CGSize(width: size.width * scale, height: size.height * scale)
            let bounds = CGRect(origin: .zero, size: size)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.preferredRange = .standard; format.opaque = false
            let source = try Self.sourceImage()
            let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 6,
                foreground: UIColor.black.cgColor, tracking: -0.05, lineHeight: 7)
            let typography = NativeTranslationTypography.layout(text: "A가", in: CGSize(width: 16, height: 12), style: style)
            func paint(_ context: CGContext) {
                let initialTransform = context.ctm
                let initialClip = context.boundingBoxOfClipPath
                context.setFillColor(UIColor(red: 0.7, green: 0.1, blue: 0.2, alpha: 0.5).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 7))
                context.setFillColor(UIColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1).cgColor)
                context.fill(CGRect(x: 5, y: 17, width: 20, height: 7))
                context.setFillColor(UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 0.6).cgColor)
                context.fillEllipse(in: CGRect(x: 12.25, y: 4.5, width: 12.125, height: 14.25))
                UIImage(cgImage: source).draw(in: CGRect(x: 2.5, y: 9, width: 10.5, height: 8.25))
                NativeTranslationTypography.draw(layout: typography, in: context, at: CGPoint(x: 15.25, y: 10.5))
                #expect(context.ctm == initialTransform)
                #expect(context.boundingBoxOfClipPath == initialClip)
            }
            let original = UIGraphicsImageRenderer(size: pixels, format: format).image { renderer in
                renderer.cgContext.scaleBy(x: scale, y: scale)
                paint(renderer.cgContext)
            }
            let owned = try NativeTranslationRenderer.WorkerLiveBitmap(pixels: pixels, bounds: bounds)
            defer { owned.close() }
            let context = try #require(owned.context)
            let stackBefore = UIGraphicsGetCurrentContext()
            NativeTranslationRenderer.withWorkerGraphicsContext(context) {
                #expect(UIGraphicsGetCurrentContext() === context)
                paint(context)
            }
            #expect(UIGraphicsGetCurrentContext() === stackBefore)
            let image = try #require(context.makeImage())
            let expected = try Self.rgba(try #require(original.cgImage))
            let actual = try Self.rgba(image)
            #expect(actual == expected)
            #expect(owned.backing?.matchesFreshState(context) == true)
        }.value
    }

    @Test func sourceRequestRejectsCleanupClipExpansionAndFractionalDeviceFrame() throws {
        let image = try Self.sourceImage()
        let viewport = CGSize(width: 80, height: 80)
        let rect = CGRect(x: 5, y: 7, width: 12, height: 14)
        let patch = NativeTranslationRenderer.SourcePatch(image: image, rect: rect)
        #expect(NativeTranslationRenderer.admittedDirectSourceFrame(patch, viewport: viewport, scale: 3) == rect)
        let clipped = NativeTranslationRenderer.SourcePatch(image: image, rect: rect, cleanupClip: rect)
        #expect(NativeTranslationRenderer.admittedDirectSourceFrame(clipped, viewport: viewport, scale: 3) == nil)
        #expect(NativeTranslationRenderer.admittedDirectSourceFrame(patch, viewport: viewport, scale: 1.25) == nil)
        let expansion = NativeTranslationRenderer.SourcePatch(image: image, rect: CGRect(x: 5, y: 7, width: 60, height: 60))
        #expect(NativeTranslationRenderer.admittedDirectSourceFrame(expansion, viewport: viewport, scale: 3) == nil)
        #expect(NativeTranslationRenderer.admittedDirectSourceFrame(patch, viewport: CGSize(width: 2_000, height: 2_000), scale: 3) == nil)
    }


    @Test(arguments: [1, 2, 3])
    func orderedCommandsKeepPrefixAndLaterNodeOnWorker(scale: Int) async throws {
        // Native source draws use requested pixel density without a foreground
        // window or the current screen's scale. Keep exact scene-order sentinels.
        let scale = CGFloat(scale)
        let pixel = try await Task.detached {
            let viewport = CGSize(width: 40, height: 32), frame = CGRect(origin: .zero, size: viewport)
            let bitmap = try NativeTranslationRenderer.WorkerLiveBitmap(
                pixels: CGSize(width: viewport.width * scale, height: viewport.height * scale), bounds: frame)
            defer { bitmap.close() }
            let context = try #require(bitmap.context)
            let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
                textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
            var before = try Self.card("before", rect: frame, color: UIColor.red.cgColor)
            before.textZ = 0
            var after = try Self.card("after", rect: CGRect(x: 13, y: 13, width: 5, height: 5), color: UIColor.blue.cgColor)
            after.textZ = 2
            let cards = [before, after], gloss = NativeTranslationEffectGloss.Refinement()
            let patch = NativeTranslationRenderer.SourcePatch(image: try Self.sourceImage(),
                rect: CGRect(x: 5, y: 7, width: 12, height: 14), liveOrder: 0)
            let commands = NativeTranslationRenderer.orderedPaintCommands(cards: cards, gloss: gloss,
                settings: settings, latePatches: [patch])
            #expect(commands.count == 3)
            var accepted = false
            for command in commands {
                if case .forced = command.operation {
                    #expect(UIGraphicsGetCurrentContext() == nil)
                    accepted = try NativeTranslationRenderer.paintDirectSourcePatch(patch,
                        context: context, backing: bitmap.backing, viewport: viewport)
                    #expect(UIGraphicsGetCurrentContext() == nil)
                } else {
                    NativeTranslationRenderer.withWorkerGraphicsContext(context) {
                        NativeTranslationRenderer.drawPaintCommand(command, cards: cards, gloss: gloss,
                            settings: settings, context: context, pixelSnapScale: nil, latePatches: [patch],
                            usesLiveTextureSampling: false, canvasSession: nil, canvasBacking: nil,
                            allowsOpaqueAffineSampling: false)
                    }
                }
            }
            #expect(accepted)
            let data = try #require(bitmap.backing?.backgroundRGBA(context: context, userRect: frame))
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let index = Int(CGFloat(y) * scale) * context.width * 4 + Int(CGFloat(x) * scale) * 4
                return Array(data[index..<(index + 4)])
            }
            return [pixel(2,16), pixel(8,11), pixel(15,15)]
        }.value
        #expect(pixel == [[255,0,0,255], [0,255,0,255], [0,0,255,255]])
    }

    private nonisolated static func card(_ id: String, rect: CGRect, color: CGColor) throws -> NativeTranslationRenderer.Card {
        let descriptor: [String: Any] = ["id": id, "text": "", "x": rect.minX, "y": rect.minY,
            "width": rect.width, "height": rect.height, "fontSize": 6, "lineHeight": 7,
            "sourceBounds": [0,0,1,1], "sourceFrame": [0,0,40,32]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 6, foreground: color, lineHeight: 7)
        return NativeTranslationRenderer.Card(item: item,
            typography: NativeTranslationTypography.layout(text: "", in: item.contentRect.size, style: style),
            style: style, drawsPanel: true, background: color, usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 6)
    }

    private nonisolated static func sourceImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return try #require(context.makeImage())
    }
    private nonisolated static func rgba(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
    }
}
