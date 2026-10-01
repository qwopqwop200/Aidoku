import CoreGraphics

extension NativeTranslationRenderer {
    /// CSS resolves declared lengths before the centred scale transform. The
    /// native card then retains those transformed, physical lengths directly.
    static func usedScaledTextItem(_ declared:NativeTranslationLayoutItem,scale:CGFloat)->NativeTranslationLayoutItem {
        var item=usedLayoutItem(declared)
        item.x += item.width*(1-scale)/2
        item.width *= scale
        item.paddingLeft *= scale;item.paddingRight *= scale
        return item
    }

    /// A text-only displacement lives in the card's local axes. Its DOM node
    /// centre therefore moves by the displacement rotated into page axes.
    static func shiftedTextNodeRect(_ card:Card)->CGRect {
        let angle=card.effectiveTextRotation,c=cos(angle),s=sin(angle),shift=card.textShift
        return card.item.rect.offsetBy(dx:shift.x*c-shift.y*s,dy:shift.x*s+shift.y*c)
    }

    static func physicalTextNodeRect(_ card:Card)->CGRect {
        let node=shiftedTextNodeRect(card)
        // Native cards already store the painted node width. Core Text
        // expands its wrap measure by 1/scale internally before painting.
        return rotatedBounds(node,about:node,angle:card.effectiveTextRotation)
    }
}
