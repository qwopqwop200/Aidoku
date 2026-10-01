import CoreGraphics
import Foundation

extension NativeTranslationRestoration {
    /// The source style allowance is shared in page order. A refused crop does not
    /// consume the remaining pixels; a failed read does, matching the original pass.
    static func sampleLetterStyles(image: CGImage, layout: NativeTranslationLayout, enabled: Bool,
                                   reader: NativeSourcePixelReader) -> [String: NativeRestorationPixels.LetterStyle] {
        guard enabled else { return [:] }
        var remaining = 327_680, styles: [String: NativeRestorationPixels.LetterStyle] = [:]
        for item in layout.items {
            guard item.fontScript == "korean", !item.vertical, item.sourceColorEligible, item.rotation == 0,
                  item.sourceBounds.count == 4, item.sourceBounds.allSatisfy(\.isFinite),
                  item.sourceBounds[2] > 0, item.sourceBounds[3] > 0, remaining > 0 else { continue }
            let frameWidth = layout.sourceRect.width > 0 ? layout.sourceRect.width : (item.sourceFrame.count == 4 ? item.sourceFrame[2] : 0)
            guard frameWidth > 0, let fontSize = item.sourceFontSize else { continue }
            let glyph = fontSize * CGFloat(image.width) / frameWidth
            guard glyph >= 24, glyph <= 240 else { continue }
            let b = item.sourceBounds
            var x = max(0, Int(floor(b[0] * CGFloat(image.width))))
            var y = max(0, Int(floor(b[1] * CGFloat(image.height))))
            var width = min(image.width, Int(ceil((b[0] + b[2]) * CGFloat(image.width)))) - x
            var height = min(image.height, Int(ceil((b[1] + b[3]) * CGFloat(image.height)))) - y
            guard width >= 12, height >= 12 else { continue }
            if width * height > 65_536 {
                if CGFloat(height) * min(CGFloat(width), glyph * 4) > 65_536 {
                    let newHeight = max(12, Int(floor(65_536 / min(CGFloat(width), glyph * 4))))
                    y += (height - newHeight) >> 1; height = newHeight
                }
                let newWidth = max(12, min(width, 65_536 / height))
                x += (width - newWidth) >> 1; width = newWidth
            }
            let count = width * height
            guard count <= remaining else { continue }
            remaining -= count
            guard let rgba = try? reader.read(x: Double(x), y: Double(y), sourceWidth: Double(width),
                sourceHeight: Double(height), width: width, height: height) else { continue }
            var pixels = NativeRestorationPixels(width: width, height: height); pixels.rgba = rgba
            if let style = NativeRestorationPixels.letterStyle(pixels, glyph: glyph) { styles[item.id] = style }
        }
        return styles
    }

    /// Only measured serif seeds can transfer their face to a neighboring source line.
    /// Inherited lines are never inserted into the seed set.
    static func resolvedLetterStyles(layout: NativeTranslationLayout,
                                     styles measured: [String: NativeRestorationPixels.LetterStyle],
                                     sample: (NativeTranslationLayoutItem) -> [String: Any]?) -> [String: NativeRestorationPixels.LetterStyle] {
        var styles = measured
        let seeds = layout.items.filter { measured[$0.id]?.serif == true }
        if !seeds.isEmpty {
            for item in layout.items {
                let own = styles[item.id]
                guard item.fontScript == "korean", !item.vertical, item.sourceColorEligible, !item.sourceVertical,
                      own?.serif != true, own.map({ $0.horizontalCount < 7 && $0.verticalCount < 30 && $0.weight < 0.12 }) ?? true,
                      item.sourceBounds.count == 4, let glyph = item.sourceFontSize, glyph > 0 else { continue }
                let ink = sample(item).flatMap { NativeRestorationPixels.rgb($0["foreground"]) }
                let matching = seeds.contains { other in
                    guard let otherGlyph = other.sourceFontSize, otherGlyph > 0, !other.sourceVertical,
                          max(glyph, otherGlyph) / min(glyph, otherGlyph) <= 1.35, other.sourceBounds.count == 4 else { return false }
                    let frame = other.sourceFrame.count == 4 ? other.sourceFrame : item.sourceFrame
                    guard frame.count == 4 else { return false }
                    let a = item.sourceBounds, b = other.sourceBounds
                    let ax = a[0] * frame[2], ay = a[1] * frame[3], aw = a[2] * frame[2], ah = a[3] * frame[3]
                    let bx = b[0] * frame[2], by = b[1] * frame[3], bw = b[2] * frame[2], bh = b[3] * frame[3]
                    guard max(bx - (ax + aw), ax - (bx + bw)) <= 2.5 * max(glyph, otherGlyph),
                          min(ay + ah, by + bh) - max(ay, by) >= min(ah, bh) * 0.5 else { return false }
                    let otherInk = sample(other).flatMap { NativeRestorationPixels.rgb($0["foreground"]) }
                    guard let ink, let otherInk else { return true }
                    return sqrt(zip(ink.channels, otherInk.channels).reduce(0) { $0 + pow($1.0 - $1.1, 2) }) <= 60
                }
                if matching {
                    styles[item.id] = .init(serif: true, weight: own?.weight ?? 0,
                        horizontalCount: own?.horizontalCount ?? 0, verticalCount: own?.verticalCount ?? 0)
                }
            }
        }
        return styles
    }

    static func inheritLetterStyles(layout: NativeTranslationLayout,
                                    styles measured: [String: NativeRestorationPixels.LetterStyle],
                                    samples: [String: [String: Any]], result: inout Result) {
        applyLetterStyles(resolvedLetterStyles(layout: layout, styles: measured, sample: { samples[$0.id] }), result: &result)
    }

    static func applyLetterStyles(_ styles: [String: NativeRestorationPixels.LetterStyle], result: inout Result) {
        result.sourceLetterWeights = styles.values.map(\.weight).filter { $0 > 0 }.sorted()
        for (id, style) in styles {
            guard let a = result.appearances[id] else { continue }
            result.appearances[id] = Appearance(foreground: a.foreground, background: a.background, restored: a.restored,
                stroke: a.stroke, strokeWidth: a.strokeWidth, erasureComplete: a.erasureComplete,
                letteringStyle: style.serif ? "serif" : "gothic", fontName: style.serif ? "AidokuSerifKR-Bold" : nil,
                sourceStrokeWeight: style.weight, sourceSample: a.sourceSample, restorationMethod: a.restorationMethod,
                sourceGlyphsVerified: a.sourceGlyphsVerified, finalForcedErasure: a.finalForcedErasure, provisional: a.provisional)
        }
    }
}
