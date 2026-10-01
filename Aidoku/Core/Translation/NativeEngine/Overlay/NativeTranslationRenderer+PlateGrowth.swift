import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// The accepted wide trial changes overflow only on its actual parent plate.
    /// This does not release another card's plate or an unparented caption.
    static func releaseWidePlateOverflow(_ card: inout Card, cardIndex: Int, panelIndex: Int) {
        guard card.captionParentPlate,
              card.captionParentOwner == .init(cardIndex: cardIndex, panelIndex: panelIndex),
              card.sourcePanels.indices.contains(panelIndex) else { return }
        card.sourcePanels[panelIndex].overflowClip = false
    }
    /// One synchronous page search shared by initial growth and later harmony.
    /// Re-fits keep the original caption snapshots, failed-room cache, page
    /// layout/pixel budgets and retained source reader rather than restarting.
    final class PlateGrowthSession {
        struct Snapshot: Equatable {
            let originalFonts: [String: Double]
            let readablePeers: [String: Double]
            let sourceReaderIdentity: ObjectIdentifier?
            let roomLayouts: Int
            let liftLayouts: Int
            let flatRoomPixels: Int
            let wideningPixels: Int
            let refusedRoomMeasurements: Int
        }
        private var refitter: ((inout [Card], String, Double, Bool, Double) -> Double?)?
        private var inspect: (() -> Snapshot)?
        private var release: (() -> Void)?

        var snapshot: Snapshot? { inspect?() }

        /// The caller may pass temporary cards for a larger transaction. A
        /// failed search restores its original caption, matching growPlate.
        @discardableResult
        func refit(id: String, cap: Double, strict: Bool, styleGlyph: Double,
                   cards: inout [Card]) -> Double? {
            guard let refitter else { return nil }
            return refitter(&cards, id, cap, strict, styleGlyph)
        }

        fileprivate func install(refit: @escaping (inout [Card], String, Double, Bool, Double) -> Double?,
                                 inspect: @escaping () -> Snapshot, release: @escaping () -> Void) {
            close()
            self.refitter = refit
            self.inspect = inspect
            self.release = release
        }
        func close() {
            refitter = nil
            inspect = nil
            release?()
            release = nil
        }
        deinit { release?() }
    }

    /// The escaping search retains a concrete page owner. The caller's inout
    /// array and this stored array are separate slots even when their values
    /// share a CoW buffer; no array is returned through a closure tuple.
    private final class PlateGrowthCards {
        var cards: [Card]
        init(_ cards: [Card]) { self.cards = cards }
    }

    /// The typography owner supplies its original per-page growth session.
    /// A failed re-fit can still restore the caption's original committed state.
    struct PlateRestoredGrowthBridge {
        var growers: [NativeTypographyPlateGrowth.Grower]
        var refit: (_ id: String, _ cap: Double, _ strict: Bool, _ current: [Card]) -> (card: Card?, size: Double?)
        var peerFont: (_ id: String, _ font: Double, _ beforeInterior: Bool) -> Double
        var interiorGaps: (_ id: String, _ font: Double, _ current: [Card]) -> Int
        var state: (_ id: String) -> NativeTypographyPlateGrowth.GrowthState? = { _ in nil }
    }
    struct PlateGrowthDiagnostic {
        let id: String
        let originalFont: Double
        var font: Double?
        var cohort: Double?
        var released: Double?
        var styleCap: Double?
        var interiorRefit: Double?
        var room: [Double]?
    }

    struct PlateGrowthScrollMetrics {
        let scrollWidth: Double
        let clientWidth: Double
        let scrollHeight: Double
        let clientHeight: Double
        let usesCSSLayout: Bool
        var fits: Bool { scrollWidth <= clientWidth && scrollHeight <= clientHeight }
    }

    /// Measure the candidate's CSS layout overflow, independently of glyph ink
    /// containment. The pure policies retain their own .5/1px allowances.
    static func plateGrowthScrollMetrics(_ card: Card) -> PlateGrowthScrollMetrics? {
        var item = card.item
        item.fontSize = card.style.fontSize
        item.lineHeight = card.style.lineHeight
        item.typesettingWidthScale = card.style.horizontalScale == 1 ? nil : card.style.horizontalScale
        if let metrics = NativeTypographyPostPolish.contentFitMetrics(item: item, typography: card.typography) {
            return .init(scrollWidth: Double(metrics.scrollWidth), clientWidth: Double(metrics.clientWidth),
                         scrollHeight: Double(metrics.scrollHeight), clientHeight: Double(metrics.clientHeight),
                         usesCSSLayout: true)
        }
        // Preserve the existing fallback only when the separate vertical
        // layout adapter cannot supply metrics. An invalid horizontal scale
        // must not become an invented fit.
        guard item.vertical else { return nil }
        let overflow: Double = card.typography.fits ? 0 : 2
        return .init(scrollWidth: Double(item.width) + overflow, clientWidth: Double(item.width),
                     scrollHeight: Double(item.height) + overflow, clientHeight: Double(item.height),
                     usesCSSLayout: false)
    }

    /// plateTry/widen replace textContent unconditionally. roomLayout only
    /// replaces it when the concatenated retained child text differs from the
    /// original caption; word-line spans may therefore survive that branch.
    @discardableResult
    static func preparePlateGrowthText(item: inout NativeTranslationLayoutItem,
                                       style: inout NativeTranslationTypography.Style,
                                       preservingControlledChildren: Bool) -> Bool {
        let retainsChildren = preservingControlledChildren && (item.typesettingQuoteMode != nil || item.typesettingPreformattedRows == true) &&
            item.typesettingText.map { $0.replacingOccurrences(of: "\n", with: "") == item.text } == true
        // Every prepare step first restores display:flex, including a room
        // probe whose controlled children survive the textContent comparison.
        item.typesettingBlockDisplay = nil
        style.blockWordLayoutUsesTopPadding = false
        if !retainsChildren {
            item.typesettingText = nil
            item.typesettingQuoteMode = nil
            item.typesettingPreservedBlockWrapper = nil
            item.typesettingPreformattedRows = nil
            style.usesBlockWordLayout = false
            style.usesPreformattedBlockRows = false
        } else {
            style.usesBlockWordLayout = item.typesettingQuoteMode != nil
            style.usesPreformattedBlockRows = item.typesettingPreformattedRows == true
        }
        return retainsChildren
    }

    /// textContent replacement removes the actual absolute unit children as
    /// well as controlled spans. A room retry keeps children only when their
    /// concatenated DOM text already equals the original caption.
    @discardableResult
    static func preparePlateGrowthCard(_ card: inout Card,
                                       preservingControlledChildren: Bool) -> Bool {
        let retainsParts = preservingControlledChildren && !card.unitTextParts.isEmpty &&
            card.unitTextParts.map(\.text).joined() == card.item.text
        if retainsParts {
            card.item.typesettingBlockDisplay = nil
            card.style.blockWordLayoutUsesTopPadding = false
            return true
        }
        let retained = preparePlateGrowthText(item: &card.item, style: &card.style,
                                             preservingControlledChildren: preservingControlledChildren)
        if !retained {
            card.unitTextParts = []
            card.unitTextPartsOrigin = nil
        }
        return retained
    }

    static func syncRestoredPlateTextStyle(item: NativeTranslationLayoutItem,
                                           style: inout NativeTranslationTypography.Style) {
        style.usesBlockWordLayout = item.typesettingText != nil && item.typesettingQuoteMode != nil
        style.usesPreformattedBlockRows = item.typesettingText != nil && item.typesettingPreformattedRows == true
        style.blockWordLayoutUsesTopPadding = (style.usesBlockWordLayout || style.usesPreformattedBlockRows) && (item.typesettingBlockDisplay ?? false)
    }

    /// Commit accepted restored growth through the same CSS layout units as
    /// other geometry producers, retaining authored coordinates separately.
    static func commitRestoredPlateGrowth(_ item: NativeTranslationLayoutItem,
                                         to next: inout Card,
                                         style: NativeTranslationTypography.Style) {
        let priorOrigin = CGPoint(x:next.item.x+next.textShift.x,y:next.item.y+next.textShift.y)
        let authoredOrigin = CGPoint(x:item.x,y:item.y)
        if authoredOrigin != priorOrigin {next.authoredTextOrigin=authoredOrigin}
        next.item=usedLayoutItem(item);next.style=style;next.finalFontSize=item.fontSize;next.textShift = .zero
        next.typographyDisplayGrowth = item.typesettingDisplayGrowth
        next.typographyWidth=nil;next.lineOffsets=[];next.typography=remeasureTypography(next)
    }

    /// Source lettering geometry follows the retained cleanup image. When
    /// unavailable, the frozen source-glyph/cohort helpers use the individual
    /// item frame; paper-room sampling has no such fallback.
    static func plateGrowthSourceFrame(item: NativeTranslationLayoutItem,
                                       cleanup: NativeSourceSurfaceGeometry.Geometry?) -> CGRect {
        if let cleanup { return cleanup.frame }
        return CGRect(x: item.sourceFrame[0], y: item.sourceFrame[1],
                      width: item.sourceFrame[2], height: item.sourceFrame[3])
    }

    static func plateGrowthSourceRect(item: NativeTranslationLayoutItem,
                                      cleanup: NativeSourceSurfaceGeometry.Geometry?) -> CGRect? {
        pageRect(item.sourceBounds, frame: plateGrowthSourceFrame(item: item, cleanup: cleanup))
    }

    static func plateGrowthTrial(_ baseline: Card,_ p: NativeTypographyPlateGrowth.Proposal,
                                 parentOrigin: CGPoint = .zero) -> Card? {
        guard valid(p.box),p.font.isFinite,p.font>0,p.horizontalScale.isFinite,p.horizontalScale>0 else{return nil}
        var proposed=baseline
        preparePlateGrowthCard(&proposed,preservingControlledChildren:p.room)
        var item=proposed.item,style=proposed.style
        // Native horizontalScale already acts inside the physical box.
        // The policy's box is the CSS layout box before its scale.
        // Frozen plate/room trials shift the existing authored CSS left/top
        // by the proposal's page displacement from the saved bounding box.
        // The residual survives; a proposal box is not a new CSS origin.
        let physicalOrigin = baseline.item.rect.origin.applying(CGAffineTransform(translationX:baseline.textShift.x,y:baseline.textShift.y))
        let savedOrigin = baseline.authoredTextOrigin ?? physicalOrigin
        let assignedOrigin = CGPoint(x:savedOrigin.x+p.box.minX-physicalOrigin.x,
                                     y:savedOrigin.y+p.box.minY-physicalOrigin.y)
        item.x=assignedOrigin.x-parentOrigin.x;item.y=assignedOrigin.y-parentOrigin.y
        item.width=p.box.width;item.height=p.box.height
        item.paddingTop=CGFloat(p.padding);item.paddingBottom=CGFloat(p.padding)
        item.paddingLeft=CGFloat(p.padding/p.horizontalScale);item.paddingRight=CGFloat(p.padding/p.horizontalScale)
        item.fontSize=CGFloat(p.font);item.lineHeight=CGFloat(p.pitch)
        item.typesettingWidthScale=p.horizontalScale==1 ? nil:CGFloat(p.horizontalScale)
        item.balancedColumn=false
        style.fontSize=CGFloat(p.font);style.lineHeight=CGFloat(p.pitch);style.tracking = -CGFloat(p.font)*0.012
        style.horizontalScale=CGFloat(p.horizontalScale);style.alignsToTop=false;style.horizontalAlignment = .center
        style.optimizesKoreanWrapping=false
        style.koreanQuoteMode=0
        proposed.authoredTextOrigin = assignedOrigin
        item=usedScaledTextItem(item,scale:CGFloat(p.horizontalScale))
        item.x += parentOrigin.x;item.y += parentOrigin.y
        proposed.item=item;proposed.style=style;proposed.textShift = .zero
        proposed.typographyWidth=nil;proposed.lineOffsets=[]
        proposed.typography=remeasureTypography(proposed)
        proposed.finalFontSize=CGFloat(p.font)
        return proposed
    }

    /// The retained title is a visible compact text node. Its hidden original
    /// card can retain the OCR-sized frame for source geometry, but that frame
    /// is not an opaque displayed obstacle for restored typography.
    static func retainedGlossGrowthObstacles(cards: [Card], gloss: NativeTranslationEffectGloss.Refinement) -> [String: [CGRect]] {
        guard cards.count <= 256, gloss.notes.count <= 256 else { return [:] }
        var result: [String: [CGRect]] = [:]
        for note in gloss.notes {
            guard note.title, note.retainedTypography != nil,
                  gloss.hiddenIDs.contains(note.id) || gloss.removedLayerIDs.contains(note.id), note.text.utf16.count <= 512,
                  note.placement.angle == nil || note.placement.angle == 0,
                  [note.placement.size, note.placement.width, note.placement.lineHeight].allSatisfy({ $0.isFinite && $0 > 0 }),
                  note.placement.moves.count == 1,
                  let move = note.placement.moves.first, move.x.isFinite, move.y.isFinite,
                  note.origin.x.isFinite, note.origin.y.isFinite,
                  let card = cards.first(where: { $0.item.id == note.id }), !card.item.keptLettering else { continue }
            let style = glossStyle(card: card, size: note.placement.size, lineHeight: note.placement.lineHeight,
                title: note.title, retained: note.retainedTypography)
            let typography = NativeTranslationTypography.layout(text: glossText(note.text, title: note.title),
                in: note.contentSize, style: style)
            guard let local = NativeTranslationTypography.wholeRangeBounds(layout: typography, style: style, available: note.contentSize),
                  valid(local) else { continue }
            let displayed = local.offsetBy(dx: note.origin.x + move.x, dy: note.origin.y + move.y)
            guard valid(displayed) else { continue }
            result[note.id, default: []].append(displayed)
        }
        return result
    }

    /// Original ordering: plate growth, restored growth, then their combined
    /// live font cohorts. The caller invokes this after caption packing.
    @discardableResult
    static func growPlateTypography(cards inputCards: inout [Card], layout: NativeTranslationLayout,
                                     restoration: NativeTranslationRestoration.Result,
                                     settings: IPhoneOverlaySettings, source: CGImage?,
                                     gloss: NativeTranslationEffectGloss.Refinement = .init(),
                                     restoredBridge suppliedBridge: PlateRestoredGrowthBridge? = nil,
                                     growthSession: NativeTypographyPostPolish.RendererGrowthSession? = nil,
                                     plateSession: PlateGrowthSession? = nil) throws -> [PlateGrowthDiagnostic] {
        guard settings.renderedBackgroundOpacity == 1, layout.items.count <= 256 else {plateSession?.close();return []}
        let pageCards = PlateGrowthCards(inputCards)
        typealias Policy = NativeTypographyPlateGrowth
        func currentItem(_ card: Card) -> NativeTranslationLayoutItem {
            var item=card.item
            item.fontSize=card.finalFontSize;item.lineHeight=card.style.lineHeight
            item.x += card.textShift.x;item.y += card.textShift.y
            return item
        }
        func currentItems(_ values: [Card]) -> [NativeTranslationLayoutItem] {
            layout.items.map {item in values.first(where:{$0.item.id==item.id}).map(currentItem) ?? item}
        }
        let cleanup=restoration.cleanupGeometry
        let budget=Policy.Budget(),widenBudget=NativeTypographyDisplayWidening.Budget()
        var flatRoomIDs=Set<String>()
        let reader=source.map {NativeSourcePixelReader(image:$0)}
        defer {if plateSession == nil {reader?.release()}}
        var originals:[String:Card]=[:],states:[String:Policy.State]=[:],readablePeers:[String:Double]=[:]
        var diagnostics:[String:PlateGrowthDiagnostic]=[:]
        var events:[String:[[String:Any]]]=[:]
        func box(_ rect:CGRect)->[Double] {[Double(rect.minX),Double(rect.minY),Double(rect.width),Double(rect.height)]}
        func wholeInk(_ card: Card) -> CGRect { cardWholeRangeRect(card) ?? .zero }
        func shape(_ card:Card)->[String:Any] {
            ["font":Double(card.finalFontSize),"rect":box(card.item.rect),"ink":box(wholeInk(card)),
             "panels":card.sourcePanels.map {["rect":box($0.rect),"coverage":$0.coverage.map(box),
                 "background":$0.background,"sourceErasure":$0.sourceErasure] as [String:Any]}]
        }
        let entering=Dictionary(uniqueKeysWithValues:pageCards.cards.map {($0.item.id,shape($0))})
        func visible(_ card: Card) -> Bool {
            !card.item.keptLettering && !card.item.text.isEmpty && !gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id)
        }
        func glyph(_ card: Card) -> Double {
            if let value=card.item.sourceFontSize,value.isFinite,value>0{return Double(value)}
            guard let r=plateGrowthSourceRect(item:card.item,cleanup:cleanup) else{return .nan}
            return Double(min(r.width,r.height))
        }
        func ownPlate(_ card: Card) -> Int? {card.sourcePanels.firstIndex(where:{!$0.sourceErasure && !$0.rotated})}
        func wordWidth(_ text: String,_ size: Double,_ baseline: Card) -> Double {
            var style=baseline.style
            style.fontSize=CGFloat(size);style.tracking=0;style.horizontalScale=1
            return Double(NativeTranslationTypography.measuredWidth(text:text,style:style))
        }
        func proposalKey(_ p: Policy.Proposal) -> String {
            [Double(p.box.minX),Double(p.box.minY),Double(p.box.width),Double(p.box.height),p.font,p.pitch,p.padding,p.horizontalScale]
                .map {String($0.bitPattern)}.joined(separator:"|")
        }
        func trial(_ baseline: Card,_ p: Policy.Proposal) -> Card? {
            var parentOrigin = CGPoint.zero
            if baseline.captionParentPlate,let identity=baseline.captionParentOwner,
               pageCards.cards.indices.contains(identity.cardIndex) {
                let owner=pageCards.cards[identity.cardIndex]
                if identity.panelIndex == -1 { parentOrigin=owner.glyphCoverOwnerPanel?.rect.origin ?? .zero }
                else if owner.sourcePanels.indices.contains(identity.panelIndex) {
                    parentOrigin=owner.sourcePanels[identity.panelIndex].rect.origin
                }
            }
            return plateGrowthTrial(baseline,p,parentOrigin:parentOrigin)
        }
        func lineFlags(_ card: Card) -> (badStart:Bool,lone:Int) {
            let text=card.typography.shapedText as NSString,closing=Set("、。，．,.！？!?…‥）)]」』】》〉:;".unicodeScalars)
            var bad=false,lone=0,hasVisibleRow=false
            for range in card.typography.lineRanges where range.location>=0 && NSMaxRange(range)<=text.length {
                let raw=text.substring(with:range)
                let visible=raw.unicodeScalars.filter {!CharacterSet.whitespacesAndNewlines.contains($0)}
                if let first=visible.first {
                    if hasVisibleRow,closing.contains(first){bad=true}
                    hasVisibleRow=true
                }
                let letters=visible.filter {!CharacterSet.punctuationCharacters.contains($0)}
                if letters.count==1,let scalar=letters.first,
                   [(0x1100...0x11FF), (0x302E...0x302F), (0x3131...0x318E), (0x3200...0x321E),
                    (0x3260...0x327E), (0xA960...0xA97C), (0xAC00...0xD7A3), (0xD7B0...0xD7C6),
                    (0xD7CB...0xD7FB), (0xFFA0...0xFFBE), (0xFFC2...0xFFC7), (0xFFCA...0xFFCF),
                    (0xFFD2...0xFFD7), (0xFFDA...0xFFDC)].contains(where:{$0.contains(Int(scalar.value))}){lone+=1}
            }
            return (bad,lone)
        }
        func ownAxisRows(_ card:Card)->[CGRect] {
            // Word ranges contain no whitespace. Union the actual scalar
            // ranges on each physical row, preserving full font ascent/descent.
            var rows:[CGRect]=[]
            for local in card.typography.rangeBounds where local.width>0 && local.height>0 {
                let rect=local.offsetBy(dx:card.textOrigin.x,dy:card.textOrigin.y)
                if let i=rows.firstIndex(where:{abs($0.minY-rect.minY)<rect.height*0.5}) {rows[i]=rows[i].union(rect)}
                else {rows.append(rect)}
            }
            return rows.sorted {$0.minY<$1.minY}
        }
        func ownAxisInk(_ card:Card)->CGRect {
            card.typography.rangeBounds.reduce(CGRect.null) {$0.union($1)}
                .offsetBy(dx:card.textOrigin.x,dy:card.textOrigin.y)
        }
        func rotatedKey(_ p:NativeTypographyRotatedGrowth.Trial)->String {
            [p.font,p.side,p.scale,p.pitch,p.shift].map {String($0.bitPattern)}.joined(separator:"|")
        }
        func rotatedTrial(_ baseline:Card,_ p:NativeTypographyRotatedGrowth.Trial)->Card? {
            guard p.font.isFinite,p.font>0 else{return nil}
            var next=baseline
            preparePlateGrowthCard(&next,preservingControlledChildren:false)
            var item=next.item,style=next.style
            item.fontSize=CGFloat(p.font);item.lineHeight=CGFloat(p.pitch)
            item.balancedColumn=false
            item.typesettingWidthScale=p.scale==1 ? nil:CGFloat(p.scale)
            if p.side>0 {
                item.paddingTop=CGFloat(max(0,p.shift*2));item.paddingBottom=CGFloat(max(0,-p.shift*2))
                // The CSS content box is scaled back to the same physical
                // plate, so its horizontal padding is already scaled here.
                item.paddingLeft=CGFloat(p.side);item.paddingRight=CGFloat(p.side)
            }
            style.fontSize=CGFloat(p.font);style.lineHeight=CGFloat(p.pitch);style.horizontalScale=CGFloat(p.scale)
            style.tracking = -CGFloat(p.font)*0.012;style.alignsToTop=false;style.horizontalAlignment = .center
            style.optimizesKoreanWrapping=false;style.koreanQuoteMode=0
            next.item=usedLayoutItem(item);next.style=style;next.finalFontSize=CGFloat(p.font)
            next.textShift = .zero;next.typographyWidth=nil;next.lineOffsets=[];next.typography=remeasureTypography(next)
            return next
        }
        func tryRotatedPlate(_ id:String,_ cap:Double,_ strict:Bool)->Double? {
            typealias Rotated=NativeTypographyRotatedGrowth
            guard let index=pageCards.cards.firstIndex(where:{$0.item.id==id}),visible(pageCards.cards[index]),pageCards.cards[index].item.rotation != 0,
                  pageCards.cards[index].rotatesSourcePanels,pageCards.cards[index].sourceBackgroundKind=="rotated-panel" else{return nil}
            if originals[id]==nil {originals[id]=pageCards.cards[index];states[id]=Policy.State()}
            guard let baseline=originals[id] else{return nil}
            let before=shape(pageCards.cards[index]),font=Double(baseline.finalFontSize),others=pageCards.cards.filter {$0.item.id != id && visible($0)}
            let peerValues=others.map {other -> Rotated.Peer in
                let f=Double(other.finalFontSize)
                let peer=min(Double(growthSession?.peerFont(id:other.item.id,font:CGFloat(f),beforeInterior:false) ?? CGFloat(f)),
                             readablePeers[other.item.id] ?? f)
                return .init(text:other.item.text,script:other.item.fontScript,glyph:glyph(other),font:peer,
                             source:pageRect(other.item.sourceBounds,frame:plateGrowthSourceFrame(item:baseline.item,cleanup:cleanup)))
            }
            func corners(_ rect:CGRect)->[[Double]] {
                [[Double(rect.minX),Double(rect.minY)],[Double(rect.maxX),Double(rect.minY)],
                 [Double(rect.maxX),Double(rect.maxY)],[Double(rect.minX),Double(rect.maxY)]]
            }
            let input=Rotated.Input(text:baseline.item.text,script:baseline.item.fontScript,font:font,glyph:glyph(baseline),
                box:baseline.item.rect,source:plateGrowthSourceRect(item:baseline.item,cleanup:cleanup),itemBox:baseline.item.rect,
                rotation:Double(baseline.item.rotation),upright:baseline.effectiveTextRotation==0,cap:cap,
                ratio:Double(baseline.style.lineHeight)/font,strict:strict,rotatingPanel:baseline.rotatesSourcePanels,
                backgroundKind:baseline.sourceBackgroundKind ?? "",vertical:baseline.item.vertical,
                wrappingScript:baseline.item.wrappingScript,visible:visible(baseline),
                plainText:baseline.unitTextParts.isEmpty &&
                    !(baseline.item.typesettingText != nil &&
                      (baseline.item.typesettingQuoteMode != nil || baseline.item.typesettingPreformattedRows == true)) &&
                    (baseline.item.typesettingText==nil || baseline.item.typesettingText==baseline.item.text),
                opaque:baseline.sourcePanels.contains {!$0.sourceErasure && $0.background.count==3} ||
                    (baseline.drawsPanel && baseline.background.alpha==1),
                originalRows:ownAxisRows(baseline),originalPageInk:wholeInk(baseline),peers:peerValues,
                otherLinePolygons:others.map {cardPageLineRects($0).filter {$0.width>0 && $0.height>0}.map(corners)},
                others:others.map(wholeInk).filter {$0.width>0 && $0.height>0},
                foreignCards:others.flatMap {other in other.sourcePanels.filter {!$0.sourceErasure}.map {panel in
                    other.rotatesSourcePanels ? rotatedBounds(panel.rect,about:other.sourcePlateRect,angle:other.item.rotation):panel.rect
                } + other.backings.map(\.frame) + (other.drawsPanel ? [rotatedBounds(other.item.rect,about:other.item.rect,angle:other.effectiveTextRotation)]:[])})
            var measured:[String:Card]=[:]
            let result=Rotated.grow(input,advance:{wordWidth($0,$1,baseline)},metrics:{size in
                var style=baseline.style;style.fontSize=CGFloat(size)
                guard let m=NativeTranslationTypography.canvasTextMetrics(text:baseline.item.text,style:style) else{return nil}
                return .init(fontAscent:Double(m.fontAscent),fontDescent:Double(m.fontDescent),actualAscent:Double(m.actualAscent),
                    actualDescent:Double(m.actualDescent),actualLeft:Double(m.actualLeft),actualRight:Double(m.actualRight),advance:Double(m.advance))
            },measure:{proposal in
                guard let card=rotatedTrial(baseline,proposal) else{return nil};measured[rotatedKey(proposal)]=card
                guard let metrics=plateGrowthScrollMetrics(card) else{return nil}
                return .init(rows:ownAxisRows(card),ink:ownAxisInk(card),scrollWidth:metrics.scrollWidth,
                    clientWidth:metrics.clientWidth,scrollHeight:metrics.scrollHeight,clientHeight:metrics.clientHeight,
                    badLineStart:lineFlags(card).badStart)
            },convexOverlap:NativeSlantedGeometry.convexOverlap,containsUpright:{ink in
                let item=baseline.item,quad=NativeSlantedGeometry.rotatedCard(cx:Double(item.rect.midX),cy:Double(item.rect.midY),
                    width:Double(item.width),height:Double(item.height),angle:Double(item.rotation),margin:2)
                return corners(ink).allSatisfy {NativeSlantedGeometry.pointInConvex(quad,point:$0)}
            })
            guard let result,let next=measured[rotatedKey(result.trial)] else {
                pageCards.cards[index]=baseline
                events[id,default:[]].append(["phase":"rotated-plate","accepted":false,"before":before,"after":shape(baseline),
                    "measurements":measured.count,"cap":cap.isFinite ? cap as Any:"Infinity","strict":strict])
                return nil
            }
            pageCards.cards[index]=next
            if !result.body {
                pageCards.cards[index].typographyDisplayGrowth="rotated-plate"
                pageCards.cards[index].item.typesettingDisplayGrowth="rotated-plate"
            }
            events[id,default:[]].append(["phase":result.body ? "rotated-body":"rotated-display","accepted":true,
                "before":before,"after":shape(next),"measurements":measured.count,"scale":result.trial.scale,
                "shift":result.trial.shift,"cap":cap.isFinite ? cap as Any:"Infinity","strict":strict])
            diagnostics[id] = .init(id:id,originalFont:font,font:result.trial.font)
            return result.trial.font
        }
        func tryPlate(_ id: String,_ cap: Double,_ strict: Bool,_ styleGlyph: Double = 0) -> Double? {
            if let card=pageCards.cards.first(where:{$0.item.id==id}),card.item.rotation != 0 {return tryRotatedPlate(id,cap,strict)}
            guard let index=pageCards.cards.firstIndex(where:{$0.item.id==id}),visible(pageCards.cards[index]),
                  let plateIndex=ownPlate(pageCards.cards[index]) else{return nil}
            if originals[id]==nil {originals[id]=pageCards.cards[index];states[id]=Policy.State()}
            guard let baseline=originals[id],let state=states[id],baseline.sourcePanels.indices.contains(plateIndex),
                  cardWholeRangeRect(baseline) != nil else{return nil}
            // Every cohort retry starts from the original font/plate snapshot.
            let before=shape(pageCards.cards[index])
            flatRoomIDs.remove(id)
            let owner=baseline.sourcePanels[plateIndex],g=glyph(baseline),font=Double(baseline.finalFontSize)
            let otherCards=pageCards.cards.indices.filter {$0 != index && visible(pageCards.cards[$0])}.map {pageCards.cards[$0]}
            let otherInk=pageCards.cards.filter {$0.item.id != id && !$0.item.keptLettering && !gloss.removedLayerIDs.contains($0.item.id)}
                .map(wholeInk).filter {$0.width>0 && $0.height>0}
            let otherPlates=otherCards.flatMap {other in other.sourcePanels.filter {!$0.sourceErasure}.map(\.rect) +
                (other.rotatesSourcePanels ? [other.item.rect]:[])}
            let otherPaint=otherCards.flatMap {other in other.sourcePanels.filter {!$0.sourceErasure}.map(\.rect) + other.backings.map(\.frame) +
                (other.item.rotation != 0 && other.drawsPanel ? [other.item.rect]:[])}
            var input=Policy.Input(text:baseline.item.text,font:font,originalFont:font,sourceGlyph:g,
                cap:cap,styleGlyph:styleGlyph,ratio:Double(baseline.style.lineHeight)/font,wrappingScript:baseline.item.wrappingScript,
                vertical:baseline.item.vertical,rotated:baseline.item.rotation != 0,allowsRecovery:baseline.item.allowsAutomaticFontRecovery,
                strict:strict,plate:owner.rect,currentInk:wholeInk(baseline),
                coverage:owner.coverage.isEmpty ? nil:owner.coverage,frame:cleanup?.frame,
                others:otherInk,foreignPlates:otherPlates,foreignCards:otherPaint)
            input.plateVisible=true
            if input.wrappingScript=="korean",g.isFinite,g>0,g*0.9<9 {
                readablePeers[id]=max(readablePeers[id] ?? 0,font,floor(min(32,max(g,styleGlyph)*0.95)*4)/4)
            }
            var measured:[String:Card]=[:],probes:[[String:Any]]=[]
            let result=Policy.grow(input,state:state,budget:budget,advance:{wordWidth($0,$1,baseline)},measure:{p in
                guard let card=trial(baseline,p),cardWholeRangeRect(card) != nil else{return nil};measured[proposalKey(p)]=card
                guard let metrics=plateGrowthScrollMetrics(card) else{return nil}
                let flags=lineFlags(card),fit=metrics.fits
                let text=card.typography.shapedText as NSString
                let lineTexts=card.typography.lineRanges.filter {$0.location>=0 && NSMaxRange($0)<=text.length}.map {text.substring(with:$0)}
                probes.append(["font":p.font,"box":box(card.item.rect),"ink":box(wholeInk(card)),"padding":p.padding,
                    "pitch":p.pitch,"scale":p.horizontalScale,"room":p.room,"lifting":p.lifting,"fits":fit,
                    "scrollWidth":metrics.scrollWidth,"clientWidth":metrics.clientWidth,
                    "scrollHeight":metrics.scrollHeight,"clientHeight":metrics.clientHeight,"usesCSSLayout":metrics.usesCSSLayout,"blockWordLayout":card.style.usesBlockWordLayout,
                    "lines":lineTexts,"badStart":flags.badStart,"loneSyllables":flags.lone,
                    "longestWord":baseline.item.text.split(whereSeparator:{$0.isWhitespace}).map {wordWidth(String($0),p.font,baseline)}.max() ?? 0])
                return .init(ink:wholeInk(card),lineRects:cardPageLineRects(card),
                    scrollWidth:metrics.scrollWidth,clientWidth:metrics.clientWidth,
                    scrollHeight:metrics.scrollHeight,clientHeight:metrics.clientHeight,
                    badLineStart:flags.badStart,loneSyllableLines:flags.lone)
            },roomProvider:{_,reach in
                guard let source,let reader,let cleanup else{return nil}
                let flat=Policy.FlatRoomInput(plate:owner.rect,glyph:reach,covered:owner.coverage.isEmpty ? [owner.rect]:owner.coverage,
                    frame:cleanup.frame,imageWidth:source.width,imageHeight:source.height,color:owner.background,
                    hasImage:!baseline.foreignFills.isEmpty,transformed:baseline.rotatesSourcePanels || baseline.item.rotation != 0)
                return Policy.flatRoom(flat,budget:budget,read:{x,y,w,h in
                    try? reader.read(x:Double(x),y:Double(y),sourceWidth:Double(w),sourceHeight:Double(h),width:w,height:h)
                })
            })
            guard let result, var accepted=measured[proposalKey(result.proposal)] else{
                pageCards.cards[index]=baseline
                events[id,default:[]].append(["phase":"plate","cap":cap.isFinite ? cap as Any:"Infinity","strict":strict,
                    "ownerIndex":plateIndex,"accepted":false,"baseline":shape(baseline),"before":before,"after":shape(baseline),
                    "measurements":measured.count,"probes":probes])
                return nil
            }
            commitPlateGrowthCoverage(&accepted.sourcePanels[plateIndex], result: result)
            pageCards.cards[index]=accepted
            if let room=result.flatRoom,!room.isEmpty {flatRoomIDs.insert(id)}
            events[id,default:[]].append(["phase":"plate","cap":cap.isFinite ? cap as Any:"Infinity","strict":strict,
                "ownerIndex":plateIndex,"accepted":true,"baseline":shape(baseline),"before":before,"after":shape(accepted),
                "measurements":measured.count,"probes":probes,"room":result.flatRoom as Any? ?? NSNull()])
            diagnostics[id]=PlateGrowthDiagnostic(id:id,originalFont:font,font:result.proposal.font,room:result.flatRoom)
            return result.proposal.font
        }
        func tryPlateWide(_ id:String,_ cap:Double,_ strict:Bool)->Double? {
            let grown=tryPlate(id,cap,strict)
            guard let index=pageCards.cards.firstIndex(where:{$0.item.id==id}),let baseline=originals[id],
                  let ownerIndex=ownPlate(pageCards.cards[index]),let source,let reader,let cleanup else{return grown}
            let owner=pageCards.cards[index].sourcePanels[ownerIndex],ink=wholeInk(baseline)
            var visiblePlate=owner.rect
            if !owner.coverage.isEmpty {
                let owners=owner.coverage.filter {$0.minX<=ink.midX && ink.midX<=$0.maxX && $0.minY<=ink.midY && ink.midY<=$0.maxY}
                    .sorted {$0.width*$0.height>$1.width*$1.height}
                guard let largest=owners.first else{return grown};visiblePlate=largest
            }
            let pageGlyphs=layout.items.filter {!$0.keptLettering}.compactMap {item -> Double? in
                if let value=item.sourceFontSize,value>0 {return Double(value)}
                guard let r=plateGrowthSourceRect(item:item,cleanup:cleanup) else{return nil}
                let value=Double(min(r.width,r.height));return value>0 ? value:nil
            }.sorted()
            let pageGlyph=pageGlyphs.isEmpty ? Double.nan:pageGlyphs[(pageGlyphs.count-1)/2]
            guard let sourceRect=plateGrowthSourceRect(item:baseline.item,cleanup:cleanup) else{return grown}
            let foreign=pageCards.cards.filter {$0.item.id != id && visible($0)}
            let input=NativeTypographyDisplayWidening.Input(text:baseline.item.text,font:Double(baseline.finalFontSize),
                glyph:glyph(baseline),pageGlyph:pageGlyph,cap:cap,grown:grown,flatRoom:flatRoomIDs.contains(id),
                rotation:baseline.item.rotation != 0,vertical:baseline.item.vertical,sourceVertical:baseline.item.sourceVertical,
                allowsRecovery:baseline.item.allowsAutomaticFontRecovery,wrappingScript:baseline.item.wrappingScript,
                visible:visible(baseline),ratio:Double(baseline.style.lineHeight/baseline.finalFontSize),strict:strict,
                plate:owner.rect,visiblePlate:visiblePlate,color:owner.background,frame:cleanup.frame,source:sourceRect,
                imageWidth:source.width,imageHeight:source.height,others:foreign.map(wholeInk),
                foreignCards:foreign.flatMap {$0.sourcePanels.filter {!$0.sourceErasure}.map(\.rect) + $0.backings.map(\.frame) +
                    ($0.item.rotation != 0 && $0.drawsPanel ? [$0.item.rect]:[])},
                foreignSourceRects:layout.items.filter {$0.id != id && !$0.keptLettering}.flatMap {item in
                    ([item.sourceBounds]+item.auxiliaryInkRects).compactMap {pageRect($0,frame:cleanup.frame)}
                })
            let before=shape(pageCards.cards[index]);var measured:[String:Card]=[:]
            let result=NativeTypographyDisplayWidening.widen(input,budget:widenBudget,advance:{wordWidth($0,$1,baseline)},
                read:{crop,w,h in try? reader.read(x:Double(crop.minX),y:Double(crop.minY),sourceWidth:Double(crop.width),
                    sourceHeight:Double(crop.height),width:w,height:h)},measure:{p in
                    guard let next=trial(baseline,p),cardWholeRangeRect(next) != nil else{return nil};measured[proposalKey(p)]=next
                    guard let metrics=plateGrowthScrollMetrics(next) else{return nil}
                    return .init(ink:wholeInk(next),lineRects:cardPageLineRects(next),
                        scrollWidth:metrics.scrollWidth,clientWidth:metrics.clientWidth,
                        scrollHeight:metrics.scrollHeight,clientHeight:metrics.clientHeight,badLineStart:lineFlags(next).badStart)
                })
            guard let result,var next=measured[proposalKey(result.proposal)] else{return grown}
            // The wider text uses the current plate verbatim, including any
            // accepted axis pass. No expanded source erasure/coverage is added.
            next.sourcePanels=pageCards.cards[index].sourcePanels;next.backings=pageCards.cards[index].backings;next.displayCardGrowth=true
            releaseWidePlateOverflow(&next,cardIndex:index,panelIndex:ownerIndex)
            pageCards.cards[index]=next
            events[id,default:[]].append(["phase":"widen","before":before,"after":shape(next),"sampledPixels":result.sampledPixels])
            diagnostics[id] = .init(id:id,originalFont:Double(baseline.finalFontSize),font:result.proposal.font)
            return result.proposal.font
        }
        var growers:[Policy.Grower]=[]
        for id in pageCards.cards.filter(visible).map({$0.item.id}) {
            if let size=tryPlateWide(id,.infinity,false),let card=pageCards.cards.first(where:{$0.item.id==id}) {
                growers.append(.init(id:id,source:glyph(card),script:card.item.fontScript,vertical:card.item.vertical,size:size))
            }
        }
        // Original collect order: all plate growers, then one restored-surface
        // growth pass. Upfront refining runs only initial cohort/word repair.
        if let session=growthSession {
            session.context.growth.displayedGlossObstacles = retainedGlossGrowthObstacles(cards: pageCards.cards, gloss: gloss)
            let foregrounds=Dictionary(uniqueKeysWithValues:pageCards.cards.map {($0.item.id,$0.style.foreground)})
            let grown: [NativeTranslationLayoutItem]
            do {
                grown = try session.growRestored(items:currentItems(pageCards.cards),
                    lockedIDs:gloss.hiddenIDs.union(gloss.removedLayerIDs),foregrounds:foregrounds)
            } catch {
                inputCards = pageCards.cards
                throw error
            }
            for index in pageCards.cards.indices {
                guard let item=grown.first(where:{$0.id==pageCards.cards[index].item.id}),item != currentItem(pageCards.cards[index]) else{continue}
                let before=shape(pageCards.cards[index]);var next=pageCards.cards[index],style=next.style
                style.fontSize=item.fontSize;style.lineHeight=item.lineHeight;style.tracking = -item.fontSize*0.012
                style.horizontalScale=item.typesettingWidthScale ?? 1;style.alignsToTop=item.balancedColumn
                style.koreanQuoteMode=item.typesettingQuoteMode ?? 0;style.strictLineBreak=item.typesettingStrictLineBreak ?? false
                syncRestoredPlateTextStyle(item:item,style:&style)
                style.foreground=item.typesettingForeground.map {color($0.map {CGFloat($0)})} ?? style.foreground
                style.outline=item.typesettingOutlineRGB.map {color($0.map {CGFloat($0)})} ?? style.outline
                style.outlineWidth=item.typesettingOutlineWidth ?? style.outlineWidth
                if item.typesettingOutlineRGB != nil, item.typesettingOutlineRGB != next.item.typesettingOutlineRGB ||
                    item.typesettingOutlineWidth != next.item.typesettingOutlineWidth { style.outlinePaintOrder = .strokeThenFill }
                commitRestoredPlateGrowth(item,to:&next,style:style);pageCards.cards[index]=next
                events[item.id,default:[]].append(["phase":"initial-restored","before":before,"after":shape(next)])
            }
        }
        let restoredBridge:PlateRestoredGrowthBridge?
        if let suppliedBridge {restoredBridge=suppliedBridge}
        else if let session=growthSession {
            let records=session.records(items:pageCards.cards.map(currentItem))
            restoredBridge=PlateRestoredGrowthBridge(growers:records.map {record in
                .init(id:record.id,source:Double(record.sourceGlyph),script:record.original.fontScript,vertical:record.vertical,
                      inPlace:record.inPlace,size:Double(record.font),extended:record.extended,base:Double(record.base),
                      interiorBase:record.interiorGrowth ? Double(record.beforeInteriorFont):nil)
            },refit:{id,cap,strict,current in
                guard let card=current.first(where:{$0.item.id==id}),let record=records.first(where:{$0.id==id}),
                      let item=session.grow(item:currentItem(card),others:currentItems(current),cap:CGFloat(cap),
                                            strict:strict,foreground:card.style.foreground) else{return (nil,nil)}
                var next=card,style=card.style
                style.fontSize=item.fontSize;style.lineHeight=item.lineHeight;style.tracking = -item.fontSize*0.012
                style.horizontalScale=item.typesettingWidthScale ?? 1;style.alignsToTop=item.balancedColumn
                style.koreanQuoteMode=item.typesettingQuoteMode ?? 0;style.strictLineBreak=item.typesettingStrictLineBreak ?? false
                syncRestoredPlateTextStyle(item:item,style:&style)
                style.foreground=item.typesettingForeground.map {color($0.map {CGFloat($0)})} ?? style.foreground
                style.outline=item.typesettingOutlineRGB.map {color($0.map {CGFloat($0)})} ?? style.outline
                style.outlineWidth=item.typesettingOutlineWidth ?? style.outlineWidth
                if item.typesettingOutlineRGB != nil, item.typesettingOutlineRGB != next.item.typesettingOutlineRGB ||
                    item.typesettingOutlineWidth != next.item.typesettingOutlineWidth { style.outlinePaintOrder = .strokeThenFill }
                commitRestoredPlateGrowth(item,to:&next,style:style)
                return (next,item.fontSize>=record.original.fontSize*1.08 ? Double(item.fontSize):nil)
            },peerFont:{id,font,before in Double(session.peerFont(id:id,font:CGFloat(font),beforeInterior:before))},
            interiorGaps:{id,font,current in session.interiorGaps(id:id,font:CGFloat(font),items:currentItems(current))},
            state:{id in
                let history = session.context.growth
                guard history.original[id] != nil else { return nil }
                return .init(extended:history.extended.contains(id), base:Double(history.base[id] ?? 0),
                    interiorBase:history.interior.contains(id) ? history.interiorBase[id].map(Double.init) : nil)
            })
        } else {restoredBridge=nil}
        // Restored growth is supplied by its own persistent typography session;
        // a final font alone cannot fabricate its original/base/interior flags.
        if let bridge=restoredBridge {growers += bridge.growers}
        func sampledRGB(_ value: Any?) -> [Double]? {NativeRestorationPixels.rgb(value)?.channels}
        func members() -> [Policy.Member] {
            pageCards.cards.filter(visible).map {card in
                let item=card.item,font=Double(card.finalFontSize),sample=restoration.appearances[item.id]?.sourceSample ?? [:]
                let ink=sampledRGB(sample["foreground"]),paper=sampledRGB(sample["background"])
                let style=[NativeTranslationSourceStylePostPolish.colorClass(ink ?? []),NativeTranslationSourceStylePostPolish.colorClass(paper ?? []),card.style.outlineWidth>0 ? "true":"false"].joined(separator:"|")
                let peer=readablePeers[item.id]
                let cohort=min(restoredBridge?.peerFont(item.id,font,true) ?? font,peer ?? font)
                let current=min(restoredBridge?.peerFont(item.id,font,false) ?? font,peer ?? font)
                return .init(id:item.id,source:glyph(card),script:item.fontScript,vertical:item.vertical,sourceVertical:item.sourceVertical,
                    sourceRect:plateGrowthSourceRect(item:item,cleanup:cleanup),cohortFont:cohort,memberFont:current,styleKey:style,
                    rotation:Double(item.rotation),nearUprightRotation:Double(item.nearUprightRotation ?? 0))
            }
        }
        let kept=layout.items.filter(\.keptLettering).compactMap {item -> Policy.Member? in
            guard let source=item.sourceFontSize,source.isFinite,source>0 else{return nil}
            let font=min(32,Double(source)*0.9)
            return .init(id:item.id,source:Double(source),script:item.fontScript,vertical:item.vertical,sourceVertical:item.sourceVertical,
                sourceRect:plateGrowthSourceRect(item:item,cleanup:cleanup),cohortFont:font,memberFont:font)
        }
        let inPlace=Set(growers.filter(\.inPlace).map(\.id))
        Policy.reconcile(&growers,members:members,kept:kept,run:{id,cap,strict in
            if inPlace.contains(id),let bridge=restoredBridge {
                let before=pageCards.cards.first(where:{$0.item.id==id}).map(shape)
                let outcome=bridge.refit(id,cap,strict,pageCards.cards)
                events[id,default:[]].append(["phase":"restored","cap":cap.isFinite ? cap as Any:"Infinity","strict":strict,
                    "accepted":outcome.size != nil,"before":before as Any? ?? NSNull(),
                    "after":outcome.card.map(shape) as Any? ?? NSNull()])
                if let card=outcome.card,let index=pageCards.cards.firstIndex(where:{$0.item.id==id}) {pageCards.cards[index]=card}
                return outcome.size
            }
            return tryPlateWide(id,cap,strict)
        },readableHold:{id in
            guard let card=pageCards.cards.first(where:{$0.item.id==id}) else{return 0}
            return Policy.readableHold(source:glyph(card),script:card.item.fontScript,font:Double(card.finalFontSize),
                ink:wholeInk(card),otherVisibleInk:pageCards.cards.filter {visible($0) && $0.item.id != id}.map(wholeInk))
        },plateFilled:{id in
            guard let card=pageCards.cards.first(where:{$0.item.id==id}),let index=ownPlate(card) else{return false}
            return Policy.plateFilled(plate:card.sourcePanels[index].rect,font:Double(card.finalFontSize),
                wordWidths:card.item.text.split(whereSeparator:{$0.isWhitespace}).map {wordWidth(String($0),Double(card.finalFontSize),card)},
                inkHeight:Double(wholeInk(card).height),displayCardGrowth:card.displayCardGrowth)
        },interiorGaps:{id,font in restoredBridge?.interiorGaps(id,font,pageCards.cards) ?? 0},
          growthState:{id in restoredBridge?.state(id)})
        for grower in growers {
            var record=diagnostics[grower.id] ?? .init(id:grower.id,originalFont:grower.base,font:grower.size)
            record.font=grower.size;record.cohort=grower.cohortTarget;record.released=grower.releasedTarget
            record.styleCap=grower.styleCap;record.interiorRefit=grower.interiorRefit
            diagnostics[grower.id]=record
        }
        let displayCaps = capRotatedDisplayPeers(cards: &pageCards.cards, cleanup: cleanup,
            hiddenIDs: gloss.hiddenIDs, removedIDs: gloss.removedLayerIDs)
        for (id, sizes) in displayCaps {
            events[id, default: []].append(["phase": "display-peer-cap", "beforeFont": sizes[0], "afterFont": sizes[1]])
        }
        for index in pageCards.cards.indices {
            let id=pageCards.cards[index].item.id
            pageCards.cards[index].plateGrowthRecord=["entering":entering[id] as Any? ?? NSNull(),"leaving":shape(pageCards.cards[index]),
                "events":events[id] ?? [],"grew":diagnostics[id]?.font as Any? ?? NSNull(),
                "cohort":diagnostics[id]?.cohort as Any? ?? NSNull()]
        }
        plateSession?.install(refit: { current, id, cap, strict, styleGlyph in
            pageCards.cards = current
            let size = tryPlate(id,cap,strict,styleGlyph)
            if let index = pageCards.cards.firstIndex(where: {$0.item.id == id}) {
                var record = pageCards.cards[index].plateGrowthRecord ?? [:]
                record["harmonyEvents"] = events[id] ?? []
                record["harmonyStyleGlyph"] = styleGlyph
                pageCards.cards[index].plateGrowthRecord = record
            }
            current = pageCards.cards
            return size
        }, inspect: {
            .init(originalFonts: originals.mapValues {Double($0.finalFontSize)}, readablePeers:readablePeers,
                  sourceReaderIdentity: reader.map(ObjectIdentifier.init),
                  roomLayouts: budget.roomLayouts, liftLayouts: budget.liftLayouts,
                  flatRoomPixels: budget.flatRoomPixels, wideningPixels: widenBudget.pixels,
                  refusedRoomMeasurements: states.values.reduce(0) {$0 + $1.roomRefused.count})
        }, release: {reader?.release()})
        let result = pageCards.cards.compactMap {diagnostics[$0.item.id]}
        inputCards = pageCards.cards
        return result
    }
}
