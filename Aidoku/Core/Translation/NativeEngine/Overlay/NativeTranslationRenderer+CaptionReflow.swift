import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// CSS declarations retained only between Card construction and the initial
    /// fixed-box reflow. Physical obstacle queries continue to use the used box.
    struct InitialCaptionCSS {
        let width: CGFloat
        let paddingLeft: CGFloat
        let paddingRight: CGFloat
        let usedWidth: CGFloat
        let usedPaddingLeft: CGFloat
        let usedPaddingRight: CGFloat

        init(item: NativeTranslationLayoutItem) {
            width = item.width; paddingLeft = item.paddingLeft; paddingRight = item.paddingRight
            let used = NativeTranslationRenderer.usedLayoutItem(item)
            usedWidth = used.width; usedPaddingLeft = used.paddingLeft; usedPaddingRight = used.paddingRight
        }

        func applies(to item: NativeTranslationLayoutItem) -> Bool {
            item.width == usedWidth && item.paddingLeft == usedPaddingLeft && item.paddingRight == usedPaddingRight
        }
    }

    static func captionReflowProfile(_ card:Card,text:String)->NativeCaptionFixedBoxReflow.Profile? {
        let source=Array(text.unicodeScalars),painted=card.typography.shapedText.unicodeScalars.filter {!CharacterSet.whitespacesAndNewlines.contains($0)}
        guard painted.count==card.typography.rangeBounds.count else {return nil}
        var nonspace:[(Unicode.Scalar,CGRect)]=[]
        for (scalar,rect) in zip(painted,card.typography.rangeBounds) where !CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar.value != 0xFEFF {
            nonspace.append((scalar,rect.offsetBy(dx:card.textOrigin.x,dy:card.textOrigin.y)))
        }
        var glyphs:[NativeCaptionFixedBoxReflow.Glyph]=[],at=0,cursor=0
        for scalar in source {
            defer {at+=scalar.utf16.count}
            if CharacterSet.whitespacesAndNewlines.contains(scalar)||scalar.value==0xFEFF {
                glyphs.append(.init(character:scalar,offset:at,rect:.zero));continue
            }
            guard cursor<nonspace.count,nonspace[cursor].0==scalar else {return nil}
            glyphs.append(.init(character:scalar,offset:at,rect:nonspace[cursor].1));cursor+=1
        }
        guard cursor==nonspace.count else {return nil}
        return NativeCaptionFixedBoxReflow.profile(glyphs:glyphs,pitch:Double(card.style.lineHeight))
    }
    static func captionReflowEntry(_ original: Card, panel: NativeTranslationSourceStylePostPolish.Panel,
                                   text: String, padding: Double, obstacles: [CGRect]) -> NativeCaptionFixedBoxReflow.Entry {
        let item=original.item
        let declarations=original.initialCaptionCSS.flatMap { $0.applies(to:item) ? $0:nil }
        return .init(text:text,x:Double(original.authoredTextOrigin?.x ?? item.x),
            width:Double(declarations?.width ?? item.width),paddingLeft:Double(declarations?.paddingLeft ?? item.paddingLeft),
            paddingRight:Double(declarations?.paddingRight ?? item.paddingRight),panel:panel.authoredRect ?? panel.rect,
            padding:padding,obstacles:obstacles)
    }

    /// Run immediately after the source-readability rectangles become final.
    /// The snapshot panel and all other node boxes remain fixed throughout.
    static func applyCaptionFixedBoxReflow(cards:inout [Card],layout:NativeTranslationLayout,settings:IPhoneOverlaySettings) {
        // These are declarations for this synchronous callback, not a second
        // panel geometry source for later packing or spacing.
        defer {
            for index in cards.indices {
                cards[index].initialCaptionCSS = nil
                for panel in cards[index].sourcePanels.indices { cards[index].sourcePanels[panel].authoredRect = nil }
            }
        }
        guard settings.preserveSourceBackgroundColor,settings.renderedBackgroundOpacity>0 else {return}
        let session=NativeCaptionFixedBoxReflow.Session()
        for index in cards.indices {
            let original=cards[index],item=original.item
            guard item.rotation==0,item.sourceColorEligible,
                item.captionFixedBoxReflowDisabled != true,original.unitTextParts.isEmpty,
                let panel=original.sourcePanels.last(where:{!$0.sourceErasure && !$0.rotated}) else {continue}
            let pad=max(3,min(6,Double(original.style.fontSize)*0.3))
            let displayedText=item.typesettingText.map {item.text.contains("\n") || item.text.contains("\r") ? $0:$0.replacingOccurrences(of:"\n",with:"")} ?? item.text
            var entry=captionReflowEntry(original,panel:panel,text:displayedText,padding:pad,
                obstacles:cards.indices.filter {$0 != index}.map {physicalTextNodeRect(cards[$0])})
            entry.automaticRecovery=item.allowsAutomaticFontRecovery;entry.vertical=item.vertical;entry.script=item.wrappingScript
            entry.opacity=settings.renderedBackgroundOpacity
            var candidate:Card?
            let result=NativeCaptionFixedBoxReflow.reflow(entry,session:session,baseline:{captionReflowProfile(original,text:displayedText)},measure:{x,width in
                var proposal=original
                proposal.item.x=CGFloat(x);proposal.item.width=CGFloat(width)
                proposal.authoredTextOrigin = CGPoint(x:CGFloat(x),y:original.authoredTextOrigin?.y ?? original.item.y)
                proposal.item.paddingLeft=0;proposal.item.paddingRight=0
                proposal.item=usedLayoutItem(proposal.item)
                proposal.typography=remeasureTypography(proposal)
                guard let profile=captionReflowProfile(proposal,text:displayedText) else {return nil}
                candidate=proposal
                return .init(profile:profile,fits:proposal.typography.fits)
            })
            if let result,var candidate {
                // Direct background paint is a separate frozen box after the
                // text-only width change, just as the source readability plate.
                candidate.sourcePlateOwnerRect=original.sourcePlateRect
                candidate.captionReflow=["kind":"inside-fixed-box","originalWidth":result.originalWidth,"originalLines":result.originalLines,"finalLines":result.finalLines]
                cards[index]=candidate
            }
        }
    }
}
