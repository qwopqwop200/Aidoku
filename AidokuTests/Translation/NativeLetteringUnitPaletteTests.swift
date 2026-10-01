import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeLetteringUnitPaletteTests {
    private func members(_ count: Int = 2) -> [NativeLetteringUnitPalette.Member] {
        (0..<count).map { index in .init(id: String(index),box: CGRect(x:index*30,y:0,width:30,height:30),
            plate:index == 0 ? [240,240,240] : [10,10,10],fill:index == 0 ? [10,10,10] : [240,240,240],
            source:[10,10,10],surface:nil,glyph:24,font:18,stroke:nil,strokeWidth:0,vertical:false) }
    }
    private func resolve(_ input: [NativeLetteringUnitPalette.Member], neighbors: [NativeLetteringUnitPalette.Neighbor] = [],
                         panels: [NativeLetteringUnitPalette.Panel] = []) -> NativeLetteringUnitPalette.Result {
        NativeLetteringUnitPalette.resolve(members:input,neighbors:neighbors,panels:panels,itemCount:input.count,
            opacity:1,preserveText:true,preserveBackground:true)
    }
    @Test func onlyChosenOwnerChangesAndForeignPiecesFollowItsColor() {
        var erasure = NativeLetteringUnitPalette.Panel(id:"1",color:[10,10,10],fills:[]);erasure.owner = false
        let result = resolve(members(),panels:[.init(id:"1",color:[10,10,10],fills:[.init(rect:CGRect(x:0,y:0,width:4,height:4),color:[10,10,10])]),erasure])
        #expect(result.updates.map(\.id) == ["1"])
        #expect(result.updates[0].fill == [10,10,10])
        #expect(result.panels[0].color == [240,240,240])
        #expect(result.panels[0].fills.isEmpty)
        #expect(result.panels[1].color == [10,10,10])
    }
    @Test func foreignInkBlocksOnlyAnAffectedPlate() {
        let unsafe = resolve(members(),neighbors:[.init(id:"foreign",ink:CGRect(x:35,y:5,width:10,height:10),fill:[240,240,240])])
        #expect(unsafe.updates.isEmpty)
        let safe = resolve(members(),neighbors:[.init(id:"foreign",ink:CGRect(x:5,y:5,width:10,height:10),fill:[240,240,240])])
        #expect(safe.updates.count == 1)
    }
    @Test func twelveMemberUnitIsAcceptedAndThirteenIsRejected() {
        #expect(resolve(members(12)).updates.count == 11)
        #expect(resolve(members(13)).updates.isEmpty)
    }
}
