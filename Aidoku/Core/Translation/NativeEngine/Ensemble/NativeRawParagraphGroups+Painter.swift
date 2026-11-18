import CoreGraphics
import Foundation

extension NativeRawParagraphGroups {
    /// Source metadata must align by identity. Unknown relationships stay unchanged.
    /// Only accepted owners change; explicit line breaks preserve whole words in CTFrame.
    static func apply(_ result: Result, source: [Item], to paint: [NativeAOTRawTextPainter.Item]) -> [NativeAOTRawTextPainter.Item] {
        paint.map { item in
            guard let proposal = result.proposals.first(where: { source[$0.index].key == item.id }) else { return item }
            return .init(id:item.id,text:proposal.lines.joined(separator:"\n"),frame:proposal.frame,
                fontSize:proposal.font,lineHeight:proposal.font*1.24,
                chosenFill:item.chosenFill,colorAuthority:item.colorAuthority)
        }
    }
}
