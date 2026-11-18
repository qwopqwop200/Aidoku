import CoreGraphics
import CoreText
import CryptoKit
import Foundation

/// Project observed source bands/composite shadow behind the mandatory display
/// outline. Source measurements remain unchanged and separate from paint policy.
enum NativeSourceStylePaint {
    /// Enable only shape-bound terminal rounding; unknown plans retain the
    /// incumbent. Explicit zero preserves the unrounded source-contour path.
    static var roundedContourBindingEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_NATIVE_ROUNDED_CONTOUR_BINDING"] != "0"
    }
    struct Band {
        let rgb: [Double]
        let width: Double // observed original source pixels
    }
    struct Shadow {
        let rgb: [Double]
        let offset: [Double] // observed original source pixels
    }
    struct Style {
        let sourceFontPixels: Double
        let bands: [Band]
        let shadow: Shadow?
        let roundedContour: RoundedContour?
        /// Inactive shape-local evidence. No proposal/admission/paint reads this
        /// field; activation is exclusively a terminal fixed-geometry operation.
        let pendingRoundedContour: RoundedContour?

        init(sourceFontPixels: Double, bands: [Band], shadow: Shadow?, roundedContour: RoundedContour? = nil, pendingRoundedContour: RoundedContour? = nil) {
            self.sourceFontPixels = sourceFontPixels; self.bands = bands; self.shadow = shadow
            self.roundedContour = roundedContour; self.pendingRoundedContour = pendingRoundedContour
        }
    }

    /// Derived paint evidence, never a replacement for observed source fields.
    /// Construction requires exact reproduction of the native fill raster.
    final class RoundedContour {
        let identity: String
        fileprivate let fillKey: String
        fileprivate let image: CGImage
        fileprivate let relativeFrame: CGRect
        fileprivate let baselines: [CGPoint]
        let directCoreTextComparison: [String: Int]
        fileprivate init(identity: String, fillKey: String, image: CGImage, relativeFrame: CGRect,
                         baselines: [CGPoint], directCoreTextComparison: [String: Int]) {
            self.identity = identity; self.fillKey = fillKey; self.image = image; self.relativeFrame = relativeFrame
            self.baselines = baselines
            self.directCoreTextComparison = directCoreTextComparison
        }
    }

    /// Call on the exact native binding result at each final shape factory.
    /// Earlier layout/admission sees ONLY the incumbent plain source style.
    static func deferringRoundedContour(_ bound: Style) -> Style {
        Style(sourceFontPixels: bound.sourceFontPixels, bands: bound.bands, shadow: bound.shadow,
              pendingRoundedContour: bound.roundedContour)
    }

    /// Reflow must transport evidence for the NEW glyphs, never the old key.
    /// Logical source fields stay authoritative; unsupported new shape clears
    /// the pending evidence rather than inheriting another raster's receipt.
    static func replacingDeferredContour(_ old: Style, with shaped: Style?) throws -> Style {
        guard old.roundedContour == nil else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
        if let shaped {
            guard shaped.roundedContour == nil, shaped.sourceFontPixels == old.sourceFontPixels,
                  shaped.bands.count == old.bands.count,
                  zip(shaped.bands, old.bands).allSatisfy({ pair in pair.0.rgb == pair.1.rgb && pair.0.width == pair.1.width }),
                  shaped.shadow == nil, old.shadow == nil else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
        }
        return Style(sourceFontPixels: old.sourceFontPixels, bands: old.bands, shadow: old.shadow,
                     pendingRoundedContour: shaped?.pendingRoundedContour)
    }

    static func transferringDeferredContour(from old: Style?, shaped: Style?) throws -> Style? {
        guard let old else { return nil }
        guard old.pendingRoundedContour != nil || shaped?.pendingRoundedContour != nil else { return old }
        return try replacingDeferredContour(old, with: shaped)
    }

    /// Rechecks exact canonical retained fill RGBA and font/source-band key.
    /// Also witnesses every opaque native fill pixel in the SAME shared oracle.
    static func activatingDeferredContour(_ plain: Style, fill: CGImage, fontPixels: CGFloat) throws -> Style? {
        guard plain.roundedContour == nil, let pending = plain.pendingRoundedContour else { return nil }
        let active = Style(sourceFontPixels: plain.sourceFontPixels, bands: plain.bands,
                           shadow: plain.shadow, roundedContour: pending)
        let painted = try renderRoundedContour(active, fill: fill, fontPixels: fontPixels)
        let before = try NativeMandatoryDisplayStroke.rgba(fill)
        let after = try NativeMandatoryDisplayStroke.rgba(painted.image)
        let dx = Int(painted.fillFrame.minX), dy = Int(painted.fillFrame.minY)
        guard painted.fillFrame.minX == CGFloat(dx), painted.fillFrame.minY == CGFloat(dy),
              dx >= 0, dy >= 0, dx + fill.width <= painted.image.width,
              dy + fill.height <= painted.image.height else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
        for y in 0..<fill.height { for x in 0..<fill.width {
            let a = (y * fill.width + x) * 4
            if before[a + 3] == 255 {
                let b = ((y + dy) * painted.image.width + x + dx) * 4
                guard before[a..<a+4].elementsEqual(after[b..<b+4]) else {
                    throw NativeMandatoryDisplayStroke.Failure.invalidInput
                }
            }
        } }
        return active
    }

    static func sameRoundedContour(_ a: Style?, _ b: Style?) -> Bool {
        a?.roundedContour?.identity == b?.roundedContour?.identity
    }

    private static func canonicalFill(_ fill: CGImage) throws -> (rect: CGRect, bytes: Data) {
        let bytes = try NativeMandatoryDisplayStroke.rgba(fill)
        var left = fill.width, top = fill.height, right = -1, bottom = -1
        for y in 0..<fill.height { for x in 0..<fill.width where bytes[(y * fill.width + x) * 4 + 3] > 0 {
            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
        } }
        guard right >= left else { throw NativeMandatoryDisplayStroke.Failure.emptyFill }
        var data = Data()
        for y in top...bottom { data.append(contentsOf: bytes[(y * fill.width + left) * 4..<(y * fill.width + right + 1) * 4]) }
        return (CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1), data)
    }

    private static func fillKey(_ fill: CGImage, style: Style, fontPixels: CGFloat) throws -> (String, CGRect) {
        let canonical = try canonicalFill(fill)
        let metadata: [String: Any] = ["font": Double(fontPixels), "sourceFont": style.sourceFontPixels,
            "bands": style.bands.map { ["rgb": $0.rgb, "width": $0.width] as [String: Any] },
            "size": [canonical.rect.width, canonical.rect.height]]
        var data = try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
        data.append(canonical.bytes)
        return (SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), canonical.rect)
    }

    /// Rows and top-left baselines are local to the ORIGINAL native fill image.
    /// No rebreaking, font fitting or path approximation. Unsupported geometry
    /// returns nil, preserving the old contour for the complete source cohort.
    static func bindingRoundedContour(_ style: Style, fill: CGImage, rows: [NSAttributedString],
                                      baselines: [CGPoint], fontPixels: CGFloat, enabled: Bool) throws -> Style? {
        guard enabled, rows.count == baselines.count, !rows.isEmpty, rows.count <= 1024,
              fontPixels.isFinite, fontPixels > 0, style.shadow == nil, style.bands.count == 1 else { return nil }
        try validateSourceContourOnly(style)
        guard style.bands[0].rgb.max()! - style.bands[0].rgb.min()! >= 16 else { return nil }
        let radius = style.bands[0].width * Double(fontPixels) / style.sourceFontPixels
        guard radius.isFinite, radius > 0, radius <= 256,
              baselines.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let padding = Int(ceil(radius)) + 4
        let w = fill.width + padding * 2, h = fill.height + padding * 2
        guard w > 0, h > 0, w <= 16_384, h <= 16_384, w <= 8_000_000 / h else { return nil }
        func canvas(_ width: Int, _ height: Int) throws -> CGContext {
            guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
            result.textMatrix = .identity
            return result
        }
        let witness = try canvas(fill.width, fill.height)
        var strokeLines: [CTLine] = []
        for (row, baseline) in zip(rows, baselines) {
            witness.textPosition = CGPoint(x: baseline.x, y: CGFloat(fill.height) - baseline.y)
            CTLineDraw(CTLineCreateWithAttributedString(row), witness)
        }
        guard let glyph = witness.makeImage(),
              try NativeMandatoryDisplayStroke.rgba(glyph) == NativeMandatoryDisplayStroke.rgba(fill) else { return nil }
        let stroke = try canvas(w, h)
        stroke.setLineJoin(.round)
        let color = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: style.bands[0].rgb.map { CGFloat($0 / 255) } + [1])!
        for (row, baseline) in zip(rows, baselines) {
            let attributed = NSMutableAttributedString(attributedString: row)
            attributed.addAttributes([.init(kCTStrokeColorAttributeName as String): color,
                .init(kCTStrokeWidthAttributeName as String): radius * 200 / Double(fontPixels)],
                range: NSRange(location: 0, length: attributed.length))
            stroke.textPosition = CGPoint(x: baseline.x + CGFloat(padding), y: CGFloat(h - padding) - baseline.y)
            let line = CTLineCreateWithAttributedString(attributed)
            strokeLines.append(line); CTLineDraw(line, stroke)
        }
        guard let image = stroke.makeImage() else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
        // Historical direct CTLine composition is a diagnostic, NOT the oracle:
        // image source-over introduces a separate premultiplication/rounding
        // step. The renderer contract is bound stroke first, retained fill last.
        let direct = try canvas(w, h), composed = try canvas(w, h)
        direct.setLineJoin(.round); direct.beginTransparencyLayer(auxiliaryInfo: nil)
        for (line, baseline) in zip(strokeLines, baselines) {
            direct.textPosition = CGPoint(x: baseline.x + CGFloat(padding), y: CGFloat(h - padding) - baseline.y)
            CTLineDraw(line, direct)
        }
        for (row, baseline) in zip(rows, baselines) {
            direct.textPosition = CGPoint(x: baseline.x + CGFloat(padding), y: CGFloat(h - padding) - baseline.y)
            CTLineDraw(CTLineCreateWithAttributedString(row), direct)
        }
        direct.endTransparencyLayer()
        composed.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        composed.draw(fill, in: CGRect(x: padding, y: padding, width: fill.width, height: fill.height))
        guard let directImage = direct.makeImage(), let composedImage = composed.makeImage() else { return nil }
        let directBytes = try NativeMandatoryDisplayStroke.rgba(directImage)
        let composedBytes = try NativeMandatoryDisplayStroke.rgba(composedImage)
        let glyphBytes = try NativeMandatoryDisplayStroke.rgba(fill)
        var changed = 0, alphaChanged = 0, maximumError = 0, opaqueGlyphChanged = 0
        for j in stride(from: 0, to: directBytes.count, by: 4) {
            if !directBytes[j..<j + 4].elementsEqual(composedBytes[j..<j + 4]) { changed += 1 }
            if directBytes[j + 3] != composedBytes[j + 3] { alphaChanged += 1 }
            for c in 0..<4 { maximumError = max(maximumError, abs(Int(directBytes[j + c]) - Int(composedBytes[j + c]))) }
        }
        // Opaque native glyph fill remains EXACT, not an AA tolerance check.
        for y in 0..<fill.height { for x in 0..<fill.width {
            let j = (y * fill.width + x) * 4, k = ((y + padding) * w + x + padding) * 4
            if glyphBytes[j + 3] == 255 && !glyphBytes[j..<j + 4].elementsEqual(composedBytes[k..<k + 4]) {
                opaqueGlyphChanged += 1
            }
        } }
        guard opaqueGlyphChanged == 0 else { return nil }
        let key = try fillKey(fill, style: style, fontPixels: fontPixels)
        let relative = CGRect(x: -CGFloat(padding) - key.1.minX, y: -CGFloat(padding) - key.1.minY,
            width: CGFloat(w), height: CGFloat(h))
        var identity = Data(key.0.utf8)
        identity.append(contentsOf: try NativeMandatoryDisplayStroke.rgba(image))
        identity.append(try JSONSerialization.data(withJSONObject: [relative.minX, relative.minY, relative.width, relative.height]))
        let bound = RoundedContour(identity: SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined(),
            fillKey: key.0, image: image, relativeFrame: relative,
            baselines: baselines.map { CGPoint(x: $0.x - key.1.minX, y: $0.y - key.1.minY) },
            directCoreTextComparison: ["changedRGBAPixels": changed, "changedAlphaPixels": alphaChanged,
                "maximumChannelError": maximumError, "opaqueNativeGlyphFillChangedPixels": opaqueGlyphChanged])
        return Style(sourceFontPixels: style.sourceFontPixels, bands: style.bands, shadow: style.shadow, roundedContour: bound)
    }

    struct RoundedRender {
        let image: CGImage
        /// Position of the unchanged input fill in the returned local canvas.
        let fillFrame: CGRect
        let audit: [String: Any]
    }

    /// Shared saved/main comparison oracle. No CTLine re-rasterization of fill:
    /// exactly the same bound stroke image followed by the retained fill image
    /// as final native composition. Historical direct CTLine pixels are separate.
    static func renderRoundedContour(_ style: Style, fill: CGImage, fontPixels: CGFloat) throws -> RoundedRender {
        guard let bound = style.roundedContour else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
        let actual = try fillKey(fill, style: style, fontPixels: fontPixels)
        guard actual.0 == bound.fillKey else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
        let stroke = bound.relativeFrame.offsetBy(dx: actual.1.minX, dy: actual.1.minY)
        let region = stroke.union(CGRect(x: 0, y: 0, width: fill.width, height: fill.height)).integral
        guard region.width > 0, region.height > 0, region.width <= 16_384, region.height <= 16_384,
              region.width <= 8_000_000 / region.height,
              let context = CGContext(data: nil, width: Int(region.width), height: Int(region.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
        let frame = CGRect(x: -region.minX, y: -region.minY, width: CGFloat(fill.width), height: CGFloat(fill.height))
        let audit = try paint(style, fill: fill, frame: frame, fontPixels: fontPixels,
            mandatoryOutward: 0, pageHeight: Int(region.height), context: context)
        context.saveGState(); context.setBlendMode(.normal); context.setAlpha(1)
        context.draw(fill, in: CGRect(x: frame.minX, y: region.height - frame.maxY, width: frame.width, height: frame.height))
        context.restoreGState()
        guard let image = context.makeImage() else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
        return RoundedRender(image: image, fillFrame: frame, audit: audit)
    }

    /// Authentication belongs to the producer; reject structurally invalid
    /// opt-ins instead of silently painting a fill without its source contour.
    static func validateSourceContourOnly(_ style: Style?) throws {
        guard let style, style.sourceFontPixels.isFinite, style.sourceFontPixels > 0,
              style.bands.count == 1, style.shadow == nil,
              let band = style.bands.first, band.width.isFinite, band.width > 0, band.width <= 256,
              band.rgb.count == 3, band.rgb.allSatisfy({ $0.isFinite && (0...255).contains($0) })
        else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
    }

    static func style(_ raw: [String: Any]?) throws -> Style? {
        guard let raw, let prediction=raw["sourceAppearance"] as? [String:Any] else { return nil }
        guard let font=(raw["sourceFontSize"] as? NSNumber)?.doubleValue,font.isFinite,font>0 else {
            throw NativeMandatoryDisplayStroke.Failure.invalidInput
        }
        func color(_ value:Any?) throws -> [Double] {
            guard let numbers=value as? [NSNumber],numbers.count==3 else {
                throw NativeMandatoryDisplayStroke.Failure.invalidInput
            }
            let rgb=numbers.map(\.doubleValue)
            guard rgb.allSatisfy({$0.isFinite && (0...255).contains($0)}) else {throw NativeMandatoryDisplayStroke.Failure.invalidInput}
            return rgb
        }
        var bands:[Band]=[]
        if let outline=prediction["outline"] as? [String:Any],outline["present"] as? Bool == true,
           let observed=outline["observedLayers"] as? [[String:Any]] {
            guard observed.count<=8 else {throw NativeMandatoryDisplayStroke.Failure.invalidInput}
            for layer in observed {
                guard let width=(layer["widthPx"] as? NSNumber)?.doubleValue,width.isFinite,width>0,width<=256 else {
                    throw NativeMandatoryDisplayStroke.Failure.invalidInput
                }
                bands.append(.init(rgb:try color(layer["rgb"]),width:width))
            }
        }
        if bands.isEmpty,let outline=prediction["outline"] as? [String:Any],outline["present"] as? Bool == true,
           let width=(outline["widthPx"] as? NSNumber)?.doubleValue,width.isFinite,width>0,width<=256 {
            bands.append(.init(rgb:try color(outline["rgb"]),width:width))
        }
        if bands.count==1,let width=(raw["renderSourceOutlineWidthPx"] as? NSNumber)?.doubleValue,width.isFinite,width>0,width<=256 {
            let colour=try (raw["renderSourceOutlineRGB"] != nil ? color(raw["renderSourceOutlineRGB"]) : bands[0].rgb)
            bands=[.init(rgb:colour,width:width)]
        }
        var shadow:Shadow?
        if let observed=prediction["shadow"] as? [String:Any],observed["present"] as? Bool == true,
           let rgb=observed["rgb"],!(rgb is NSNull),let numbers=observed["offsetPx"] as? [NSNumber] {
            let offset=numbers.map(\.doubleValue)
            guard offset.count==2,offset.allSatisfy({$0.isFinite && abs($0)<=1024}) else {
                throw NativeMandatoryDisplayStroke.Failure.invalidInput
            }
            shadow = .init(rgb:try color(rgb),offset:offset)
        }
        return .init(sourceFontPixels:font,bands:bands,shadow:shadow)
    }

    /// One verified paint tuple only. Entries hold their source image so object
    /// identity cannot be recycled. Never stores placement or safety results.
    final class PlaneMemo {
        fileprivate struct Key: Hashable {
            let fillID: ObjectIdentifier
            let scaleInputs: [UInt64]
            let bands: [[UInt64]]
            let shadowColor: [UInt64]?
            let shadowOffset: [UInt64]?

            init(style: Style, fill: CGImage, font: CGFloat, outward: CGFloat) {
                fillID = ObjectIdentifier(fill)
                scaleInputs = [style.sourceFontPixels, Double(font), Double(outward)].map(\.bitPattern)
                bands = style.bands.map { ([$0.width] + $0.rgb).map(\.bitPattern) }
                shadowColor = style.shadow?.rgb.map(\.bitPattern)
                shadowOffset = style.shadow?.offset.map(\.bitPattern)
            }
        }
        fileprivate struct Entry {
            let fill: CGImage
            let padding: Int
            let scale: Double
            let planes: [(image: CGImage, offset: [Double])]
            let audit: [String: Any]
        }
        fileprivate var entries: [Key: Entry] = [:]
        private(set) var retainedBytes = 0
        private(set) var hits = 0

        fileprivate func entry(_ key: Key) -> Entry? {
            guard let entry = entries[key] else { return nil }
            hits += 1
            return entry
        }

        fileprivate func canRetain(planeBytes: Int, count: Int) -> Bool {
            entries.count < 128 && count > 0 && count <= (16 * 1024 * 1024 - retainedBytes) / planeBytes
        }

        fileprivate func retain(_ entry: Entry, key: Key, bytes: Int) {
            entries[key] = entry
            retainedBytes += bytes
        }
    }

    /// Uses the retained final translated alpha, so fallback glyphs and font
    /// shrinking receive the same measured source style. All effects precede BW
    /// strokes and fills; no later halo can erase a retained glyph interior.
    static func paint(_ style:Style, fill:CGImage, frame:CGRect, fontPixels:CGFloat,
                      mandatoryOutward:CGFloat,pageHeight:Int,context:CGContext,memo:PlaneMemo?=nil) throws -> [String:Any] {
        if let bound = style.roundedContour {
            try validateSourceContourOnly(style)
            guard mandatoryOutward == 0 else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
            let actual = try fillKey(fill, style: style, fontPixels: fontPixels)
            guard actual.0 == bound.fillKey else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
            let target = bound.relativeFrame.offsetBy(dx: frame.minX + actual.1.minX, dy: frame.minY + actual.1.minY)
            context.saveGState(); defer { context.restoreGState() }
            context.setAlpha(1); context.setBlendMode(.normal); context.interpolationQuality = .none
            context.draw(bound.image, in: CGRect(x: target.minX, y: CGFloat(pageHeight) - target.maxY,
                width: target.width, height: target.height))
            return ["sourceLayerCount": 1, "sourceLayerWidthsPixels": style.bands.map(\.width),
                "displayCumulativeRadiiPixels": [style.bands[0].width * Double(fontPixels) / style.sourceFontPixels],
                "sourceToDisplayScale": Double(fontPixels) / style.sourceFontPixels, "shadowRendered": false,
                "roundedSourceContourBinding": bound.identity, "fillRasterBindingVerified": true,
                "directCoreTextStrokeFillRGBAExact": bound.directCoreTextComparison["changedRGBAPixels"] == 0,
                "historicalDirectCoreTextComparison": bound.directCoreTextComparison,
                "renderOracle": "bound-stroke-raster-first-unchanged-retained-fill-raster-last",
                "opaqueNativeGlyphFillRGBAExact": true,
                "canonicalFillOriginOutputPixels": [frame.minX + actual.1.minX, frame.minY + actual.1.minY],
                "baselinesRelativeToCanonicalFill": bound.baselines.map { [$0.x, $0.y] },
                "layerPolicy": "native CoreText round source stroke; observed source fields retained",
                "paintOrder": "bound-source-stroke then unchanged retained-fill"]
        }
        func draw(_ image: CGImage, padding: Int, offset: [Double], scale: Double) {
            // Alpha rasters use CGImage row order; source offsets are top-left.
            let expanded = frame.insetBy(dx: -CGFloat(padding), dy: -CGFloat(padding))
            let target = expanded.offsetBy(dx: offset[0] * scale, dy: offset[1] * scale)
            context.draw(image, in: CGRect(x: target.minX, y: CGFloat(pageHeight) - target.maxY,
                                           width: target.width, height: target.height))
        }
        let key = memo.map { _ in PlaneMemo.Key(style: style, fill: fill, font: fontPixels, outward: mandatoryOutward) }
        if let key, let entry = memo?.entry(key), entry.fill === fill {
            for plane in entry.planes { draw(plane.image, padding: entry.padding, offset: plane.offset, scale: entry.scale) }
            return entry.audit
        }
        let scale=Double(fontPixels)/style.sourceFontPixels
        guard scale.isFinite,scale>0 else {throw NativeMandatoryDisplayStroke.Failure.invalidInput}
        let rgba=try NativeMandatoryDisplayStroke.rgba(fill)
        let original=stride(from:3,to:rgba.count,by:4).map {rgba[$0]}
        let total=Double(mandatoryOutward)+style.bands.reduce(0){$0+$1.width*scale}
        guard total.isFinite, total >= 0, total <= 510 else {
            throw NativeMandatoryDisplayStroke.Failure.invalidInput
        }
        let padding=Int(ceil(total))+2
        guard padding<=512,fill.width+padding*2<=16_384,fill.height+padding*2<=16_384,
              (fill.width+padding*2)*(fill.height+padding*2)<=8_000_000 else {
            throw NativeMandatoryDisplayStroke.Failure.invalidInput
        }
        let w=fill.width+padding*2,h=fill.height+padding*2
        var alpha=[UInt8](repeating:0,count:w*h)
        for y in 0..<fill.height {for x in 0..<fill.width {alpha[(y+padding)*w+x+padding]=original[y*fill.width+x]}}
        func raster(_ plane:[UInt8],_ rgb:[Double]) throws -> CGImage {
            var bytes=[UInt8](repeating:0,count:w*h*4)
            for i in plane.indices {
                let a=Double(plane[i])/255
                for c in 0..<3 {bytes[i*4+c]=UInt8((rgb[c]*a).rounded())}
                bytes[i*4+3]=plane[i]
            }
            return try NativeMandatoryDisplayStroke.image(bytes,width:w,height:h)
        }
        let planeBytes = w * h * 4
        let retain = memo?.canRetain(planeBytes: planeBytes, count: style.bands.count + (style.shadow == nil ? 0 : 1)) == true
        var planes: [(image: CGImage, offset: [Double])] = []
        func paintPlane(_ image: CGImage, offset: [Double] = [0, 0]) {
            draw(image, padding: padding, offset: offset, scale: scale)
            if retain { planes.append((image, offset)) }
        }
        if let shadow=style.shadow {paintPlane(try raster(alpha,shadow.rgb),offset:shadow.offset)}
        var cumulative=Double(mandatoryOutward), radii:[Double]=[]
        for band in style.bands {cumulative+=band.width*scale;radii.append(cumulative)}
        for index in style.bands.indices.reversed() {
            let dilated=dilate(alpha,width:w,height:h,radius:Int(ceil(radii[index])))
            paintPlane(try raster(dilated,style.bands[index].rgb))
        }
        let audit = ["sourceLayerCount":style.bands.count,"sourceLayerWidthsPixels":style.bands.map(\.width),
            "displayCumulativeRadiiPixels":radii,"sourceToDisplayScale":scale,
            "shadowRendered":style.shadow != nil,
            "shadowPolicy":"observed composite RGB translated-alpha silhouette; display opacity=1/blur=0; intrinsic source parameters remain unknown",
            "layerPolicy":mandatoryOutward == 0
                ? "source bands from retained fill; no synthetic guard offset; source widths preserved separately"
                : "observed ordered bands projected outside mandatory BW display outline; source widths preserved separately",
            "paintOrder":mandatoryOutward == 0
                ? "source-shadow/source-bands then retained-fill"
                : "source-shadow/source-bands then mandatory-BW then retained-fill"] as [String:Any]
        if retain, let key {
            memo?.retain(.init(fill: fill, padding: padding, scale: scale, planes: planes, audit: audit),
                         key: key, bytes: planeBytes * planes.count)
        }
        return audit
    }

    /// Disk max filter. The two vertical displacements at each distance share
    /// one horizontal max filter per source row.
    static func dilate(_ alpha: [UInt8], width w: Int, height h: Int, radius: Int) -> [UInt8] {
        guard radius > 0, w > 0, h > 0 else { return alpha }
        if let result = NativeDiskAlphaMaximum.flatSmallDisk(alpha, width: w, height: h, radius: radius) {
            return result
        }
        var spans: [(y: Int, first: Int, last: Int)] = []
        for y in 0..<h {
            let row = y * w
            var first = 0, last = w - 1
            while first < w, alpha[row + first] == 0 { first += 1 }
            guard first < w else { continue }
            while last > first, alpha[row + last] == 0 { last -= 1 }
            spans.append((y, first, last))
        }
        var result = [UInt8](repeating: 0, count: alpha.count)
        var queue = [Int](repeating: 0, count: w)
        for dy in 0...min(radius, h - 1) {
            let reach = Int(sqrt(Double(radius * radius - dy * dy)))
            for (sy, first, last) in spans {
                let upper = sy >= dy ? (sy - dy) * w : -1
                let lower = dy > 0 && sy + dy < h ? (sy + dy) * w : -1
                guard upper >= 0 || lower >= 0 else { continue }
                let source = sy * w
                var head = 0, tail = 0, next = first
                // Outside this interval the horizontal maximum is zero.
                for x in max(0, first - reach)...min(w - 1, last + reach) {
                    while next <= min(last, x + reach) {
                        while tail > head, alpha[source + queue[tail - 1]] <= alpha[source + next] { tail -= 1 }
                        queue[tail] = next
                        tail += 1
                        next += 1
                    }
                    while head < tail, queue[head] < x - reach { head += 1 }
                    if head < tail {
                        let value = alpha[source + queue[head]]
                        if upper >= 0 { result[upper + x] = max(result[upper + x], value) }
                        if lower >= 0 { result[lower + x] = max(result[lower + x], value) }
                    }
                }
            }
        }
        return result
    }
}
