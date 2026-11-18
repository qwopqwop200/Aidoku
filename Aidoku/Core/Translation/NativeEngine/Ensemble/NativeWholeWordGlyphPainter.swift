import CoreText
import CoreGraphics
import Foundation

enum NativeWholeWordGlyphPainter {
    struct PositionedRows {
        let wrapped: NativeWholeWordWrap.Result
        let baselines: [CGPoint] // top-left, relative to logical owner origin
        let fillBounds: CGRect
        let size: CGSize
    }
    enum Failure: Error { case unresolvedGlyphs, clippedFill, emptyFill, allocation, invalidSpacing }

    static func position(_ result: NativeWholeWordWrap.Result, width: CGFloat,
                         minimumLineHeight: CGFloat, outwardExtent: CGFloat = 0) throws -> PositionedRows {
        guard width.isFinite, width > 0, minimumLineHeight.isFinite, minimumLineHeight >= 0,
              outwardExtent.isFinite, outwardExtent >= 0 else { throw Failure.invalidSpacing }
        guard result.completeOwnership, result.unresolvedGlyphRanges.isEmpty else { throw Failure.unresolvedGlyphs }
        let top = result.rows.map(\.upperExtent).max() ?? 0
        let bottom = result.rows.map(\.lowerExtent).max() ?? 0
        let inkTop = result.rows.map {max(0,$0.inkBounds.maxY)}.max() ?? 0
        let inkBottom = result.rows.map {max(0,-$0.inkBounds.minY)}.max() ?? 0
        let leading = result.rows.map(\.leading).max() ?? 0
        let face = CTFontCreateWithName(result.requestedFontName as CFString, result.requestedFontSize, nil)
        let step = NativeTextSpacing.baselineStep(fontSize: result.requestedFontSize,
            bodyHeight: inkTop + inkBottom,
            leading: max(leading, CTFontGetLeading(face)), outwardExtent: outwardExtent,
            minimumLineHeight: minimumLineHeight)
        var baseline: CGFloat = top, bounds = CGRect.null
        var positions: [CGPoint] = []
        for (index, row) in result.rows.enumerated() {
            baseline = top + CGFloat(index) * step
            let x = row.centeredBaselineX(width: width)
            positions.append(CGPoint(x:x,y:baseline))
            if !row.inkBounds.isEmpty {
                bounds = bounds.union(CGRect(x:x+row.inkBounds.minX,y:baseline-row.inkBounds.maxY,
                    width:row.inkBounds.width,height:row.inkBounds.height))
            }
        }
        return PositionedRows(wrapped:result,baselines:positions,fillBounds:bounds,
                              size:CGSize(width:width,height:baseline+bottom))
    }

    /// Explicit retained-font contour plans already have a measured common
    /// pitch. Match the saved painter's safety guard without applying the
    /// ordinary line-height floor, extra leading or 0.1em quantization again.
    /// Metrics and centered row origins remain unchanged.
    static func positionRetainedPitch(_ result: NativeWholeWordWrap.Result, width: CGFloat,
                                      pitch: CGFloat, outwardExtent: CGFloat = 0) throws -> PositionedRows {
        guard width.isFinite, width > 0, pitch.isFinite, pitch > 0,
              outwardExtent.isFinite, outwardExtent >= 0 else { throw Failure.invalidSpacing }
        guard result.completeOwnership, result.unresolvedGlyphRanges.isEmpty,
              !result.rows.isEmpty else { throw Failure.unresolvedGlyphs }
        let top = result.rows.map(\.upperExtent).max() ?? 0
        let bottom = result.rows.map(\.lowerExtent).max() ?? 0
        let inkTop = result.rows.map {max(0,$0.inkBounds.maxY)}.max() ?? 0
        let inkBottom = result.rows.map {max(0,-$0.inkBounds.minY)}.max() ?? 0
        guard top.isFinite, bottom.isFinite, top >= 0, bottom >= 0,
              inkTop + inkBottom + 2 * outwardExtent + 1 <= pitch + 0.01 else { throw Failure.invalidSpacing }
        var positions: [CGPoint] = [], bounds = CGRect.null
        for (index, row) in result.rows.enumerated() {
            let baseline = top + CGFloat(index) * pitch
            let x = row.centeredBaselineX(width: width)
            guard baseline.isFinite, x.isFinite else { throw Failure.invalidSpacing }
            positions.append(CGPoint(x: x, y: baseline))
            if !row.inkBounds.isEmpty {
                bounds = bounds.union(CGRect(x: x + row.inkBounds.minX, y: baseline - row.inkBounds.maxY,
                    width: row.inkBounds.width, height: row.inkBounds.height))
            }
        }
        return PositionedRows(wrapped: result, baselines: positions, fillBounds: bounds,
            size: CGSize(width: width, height: top + CGFloat(result.rows.count - 1) * pitch + bottom))
    }

    /// Actual complete fill crop, with one top-left coordinate conversion.
    /// Rejects unsupported or clipped bodies instead of certifying a partial row.
    static func raster(_ plan: PositionedRows, origin: CGPoint, scale: CGFloat,
                       pagePixels: CGSize) throws -> NativeAOTTranslationPageComposer.TranslatedFillPrimitive {
        guard !plan.fillBounds.isNull, !plan.fillBounds.isEmpty else { throw Failure.emptyFill }
        let painted = plan.fillBounds.offsetBy(dx:origin.x,dy:origin.y)
            .applying(CGAffineTransform(scaleX:scale,y:scale))
        let page = CGRect(origin:.zero,size:pagePixels)
        guard page.contains(painted) else { throw Failure.clippedFill }
        let crop = painted.insetBy(dx:-1,dy:-1).integral.intersection(page)
        guard let context = CGContext(data:nil,width:Int(crop.width),height:Int(crop.height),bitsPerComponent:8,
            bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.allocation }
        context.translateBy(x:-crop.minX,y:crop.height+crop.minY)
        context.scaleBy(x:scale,y:-scale)
        context.textMatrix = CGAffineTransform(scaleX:1,y:-1)
        for (row,p) in zip(plan.wrapped.rows,plan.baselines) {
            context.textPosition = CGPoint(x:origin.x+p.x,y:origin.y+p.y)
            CTLineDraw(row.line,context)
        }
        guard let image = context.makeImage() else { throw Failure.allocation }
        return .init(image:image,frame:crop,fontOutputPixels:plan.wrapped.requestedFontSize*scale)
    }
}

extension NativeAOTRawTextPainter {
    /// Parent bridge: same raw Item contract and baseline face. A parent with
    /// predicted font/style supplies fontForItem explicitly, before stroke.
    /// Allocator owns free space and peer admission; this is a typed proposal API.
    static func wholeWordProposal(for item: Item, fontForItem: (Item) -> CTFont,
                                  maximumWidth: CGFloat) throws -> [NativeWholeWordWrap.Proposal] {
        try NativeWholeWordWrap.proposals(text:item.text,font:fontForItem(item),size:item.fontSize,
            width:item.frame.width,maximumWidth:maximumWidth,color:item.chosenFill)
    }
}
