import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Runs after every peer-sizing pass and source-frame-line preservation.
    /// An opaque source quad can grow only over its own flat-paper colour.
    static func liftFinalRotatedReadability(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                           layout: NativeTranslationLayout, source: CGImage?, settings: IPhoneOverlaySettings) throws -> NativeRotatedReadability.Budget {
        typealias Policy = NativeRotatedReadability
        var budget = Policy.Budget()
        guard settings.renderedBackgroundOpacity == 1,layout.items.count <= 256 else { return budget }
        let reader = source.map { NativeSourcePixelReader(image: $0) }
        defer { reader?.release() }
        func rectangle(_ r: CGRect) -> Policy.Polygon {[[r.minX,r.minY],[r.maxX,r.minY],[r.maxX,r.maxY],[r.minX,r.maxY]]}
        func localLines(_ card: Card) -> [CGRect] {
            if !card.unitTextParts.isEmpty {
                return card.unitTextParts.flatMap { part in
                    let frame = textPartFrame(part,card:card)
                    return NativeTranslationTypography.captionLineMetrics(layout:part.typography).map { $0.rect.offsetBy(dx:frame.minX,dy:frame.minY) }
                }
            }
            return NativeTranslationTypography.captionLineMetrics(layout: card.typography).map { $0.rect.offsetBy(dx: card.textOrigin.x,dy: card.textOrigin.y) }
        }
        func paintedLines(_ card: Card) -> [Policy.Polygon] {
            let cx = Double(card.item.rect.midX),cy = Double(card.item.rect.midY),cs = cos(Double(card.effectiveTextRotation)),sn = sin(Double(card.effectiveTextRotation))
            return localLines(card).map { r in rectangle(r).map { p in
                let dx = p[0] - cx,dy = p[1] - cy
                return [cx + dx * cs - dy * sn,cy + dx * sn + dy * cs]
            } }
        }
        for index in cards.indices {
            try Task.checkCancellation()
            let original = cards[index],item = original.item
            let sourcePanel = original.sourcePanels.first(where: { !$0.sourceErasure })
            let background = original.rotatesSourcePanels ? sourcePanel?.background : rgb(original.background)
            guard let background else { continue }
            var e = Policy.Entry(text: item.text,renderedText: item.typesettingText ?? item.text,rect: item.rect,
                font: Double(original.style.fontSize),pitch: Double(original.style.lineHeight),scale: Double(original.style.horizontalScale),
                angle: Double(original.effectiveTextRotation),background: background,
                frame: layout.sourceRect,imageSize: source.map { CGSize(width:$0.width,height:$0.height) })
            e.padding = [item.paddingTop,item.paddingRight,item.paddingBottom,item.paddingLeft].map(Double.init)
            e.rotatingPanel = original.rotatesSourcePanels || original.drawsPanel && item.rotation != 0
            e.backgroundKind = original.sourceBackgroundKind ?? ""
            e.visible = !gloss.hiddenIDs.contains(item.id) && !gloss.removedLayerIDs.contains(item.id)
            e.uprightQuad = item.drawsUprightQuadText || original.finalUprightText
            e.childCount = original.unitTextParts.count
            e.vertical = item.vertical;e.korean = item.wrappingScript == "korean"
            e.opaque = original.rotatesSourcePanels || !original.usesFallbackVeil && original.background.alpha >= 1
            e.hasBackgroundImage = sourcePanel?.sourceFrameImage != nil || !original.columnFrameImages.isEmpty || original.glyphCoverPatch != nil
            for peer in cards where peer.item.id != item.id && !gloss.hiddenIDs.contains(peer.item.id) && !gloss.removedLayerIDs.contains(peer.item.id) {
                let peerBox = peer.sourcePlateRect
                if peer.rotatesSourcePanels || peer.drawsPanel && peer.item.rotation != 0 {
                    e.others.append(NativeSlantedGeometry.rotatedCard(cx:peerBox.midX,cy:peerBox.midY,
                        width:peerBox.width * peer.style.horizontalScale,height:peerBox.height,angle:peer.item.rotation))
                }
                let lines = paintedLines(peer)
                e.lettering += lines
                // getClientRects under a transform supplies the page envelope;
                // lettering separately keeps the exact turned line polygon.
                e.others += lines.compactMap { polygon in
                    guard let left = polygon.map({ $0[0] }).min(),let top = polygon.map({ $0[1] }).min(),
                          let right = polygon.map({ $0[0] }).max(),let bottom = polygon.map({ $0[1] }).max() else { return nil }
                    return rectangle(CGRect(x:left,y:top,width:right-left,height:bottom-top))
                }
                for panel in peer.sourcePanels where !peer.rotatesSourcePanels {
                    let r = peer.rotatesSourcePanels ? rotatedBounds(panel.rect,about:peer.sourcePlateRect,angle:peer.item.rotation) : panel.rect
                    if r.width > 0 && r.height > 0 { e.others.append(rectangle(r)) }
                }
                e.others += peer.backings.filter { $0.frame.width > 0 && $0.frame.height > 0 }.map { rectangle($0.frame) }
            }
            guard Policy.valid(e,opacity: settings.renderedBackgroundOpacity,itemCount: layout.items.count) else { continue }
            var proposals: [(Policy.Candidate,NativeTranslationTypography.Layout,NativeTranslationTypography.Style)] = []
            func shape(_ candidate: Policy.Candidate) -> Policy.Measurement? {
                let padding = candidate.padding,available = CGSize(width:(candidate.rect.width - padding[1] - padding[3]) * candidate.scale,
                    height:candidate.rect.height - padding[0] - padding[2])
                guard available.width > 0,available.height > 0 else { return nil }
                var style = original.style
                style.fontSize = CGFloat(candidate.font);style.lineHeight = CGFloat(candidate.pitch)
                style.tracking = -style.fontSize * 0.012;style.horizontalScale = CGFloat(candidate.scale)
                style.optimizesKoreanWrapping = false;style.balancesHorizontalLines = false;style.alignsToTop = false
                var measurementStyle = style
                measurementStyle.outline = nil;measurementStyle.outlineWidth = 0;measurementStyle.outlineGlow = 0
                let measured = NativeTranslationTypography.layout(text:item.text,in:available,style:measurementStyle)
                let lines = NativeTranslationTypography.captionLineMetrics(layout:measured)
                guard !lines.isEmpty,let metrics = NativeTranslationTypography.canvasTextMetrics(text:item.text,style:measurementStyle) else { return nil }
                let range = lines.map { m in CGRect(x: m.rect.minX / candidate.scale + padding[3],y:m.rect.minY + padding[0],
                                                   width:m.rect.width / candidate.scale,height:m.rect.height) }.reduce(CGRect.null) { $0.union($1) }
                let lead = (candidate.pitch - Double(metrics.fontAscent) - Double(metrics.fontDescent)) / 2
                let top = Double(range.minY) + lead + Double(metrics.fontAscent) - Double(metrics.actualAscent)
                let bottom = Double(range.maxY) - lead - Double(metrics.fontDescent) + Double(metrics.actualDescent)
                let ink = CGRect(x:range.minX,y:top,width:range.width,height:bottom-top)
                let flow = NativeTranslationTypography.wordFlow(layout:measured,originalText:item.text)
                let painted = NativeTranslationTypography.layout(text:item.text,in:available,style:style)
                proposals.append((candidate,painted,style))
                return .init(rows:flow.displayedLines,broken:flow.wordSplits > 0,
                    overflowWidth:measured.size.width > available.width + 0.5,
                    overflowHeight:!measured.fits || measured.size.height > available.height + 0.5,ink:ink)
            }
            let result = Policy.run(e,opacity:settings.renderedBackgroundOpacity,itemCount:layout.items.count,budget:&budget,hooks:.init(
                measure:shape,longestWord:{font in
                    var style = original.style;style.fontSize = CGFloat(font);style.tracking = 0
                    return Double(NativeTranslationTypography.widestWord(text:item.text,style:style))
                },read:{ crop in
                    guard let reader else { return nil }
                    return try? reader.read(x:Double(crop.minX),y:Double(crop.minY),sourceWidth:Double(crop.width),sourceHeight:Double(crop.height),width:Int(crop.width),height:Int(crop.height))
                }))
            guard let result,let shaped = proposals.last(where: { $0.0.rect == result.candidate.rect && $0.0.font == result.candidate.font && $0.0.scale == result.candidate.scale }) else { continue }
            let c = result.candidate
            var changed = item
            changed.x = c.rect.minX;changed.y = c.rect.minY;changed.width = c.rect.width;changed.height = c.rect.height
            changed.fontSize = CGFloat(c.font);changed.lineHeight = CGFloat(c.pitch)
            changed.paddingTop = 0;changed.paddingBottom = 0;changed.paddingLeft = c.side / c.scale;changed.paddingRight = c.side / c.scale
            changed.typesettingWidthScale = CGFloat(c.scale)
            cards[index].item = changed;cards[index].typography = shaped.1;cards[index].style = shaped.2
            cards[index].typographyWidth = changed.contentRect.width * c.scale;cards[index].lineOffsets = []
            let physicalLeft = changed.rect.midX - changed.rect.width * c.scale / 2
            cards[index].textShift = CGPoint(x:physicalLeft + c.side - changed.contentRect.minX,y:0)
            cards[index].finalFontSize = CGFloat(c.font);cards[index].slantedClip = result.clip
            cards[index].sourcePlateOwnerRect = c.rect
            let plate = CGRect(x:c.rect.midX - c.paintedWidth / 2,y:c.rect.minY,width:c.paintedWidth,height:c.rect.height)
            if original.rotatesSourcePanels || original.drawsPanel {
                cards[index].drawsPanel = false;cards[index].rotatesSourcePanels = true
                cards[index].sourcePanels = [.init(rect:plate,background:background,radius:6,coverage:[plate])]
            }
            cards[index].rotatedReadability = result.metadata
            cards[index].sourceBackgroundKind = "rotated-panel"
        }
        return budget
    }
}
