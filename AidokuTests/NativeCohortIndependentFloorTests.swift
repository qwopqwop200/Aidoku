import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeCohortIndependentFloorTests {
    @Test func floorLimitedPeerDoesNotVetoAnotherCompleteFamily() throws {
        typealias P = NativeCohortFitPlanner
        let fonts:[CGFloat]=[12.538208279003216,21.25848334099585,21.25848334099585]
        let requested=fonts.enumerated().map {index,font in
            NativeAOTRawTextPainter.Item(id:String(index),text:"Alpha beta",
                frame:CGRect(x:20+index*110,y:30,width:100,height:180),fontSize:font,lineHeight:font*1.4,
                chosenFill:CGColor(gray:0,alpha:1),colorAuthority:"synthetic-floor-regression")
        }
        let declared:[[String:Any]]=requested.enumerated().map {index,item in
            var row:[String:Any]=["id":item.id,"text":item.text,"fontSize":Double(item.fontSize)]
            if index>0 {row["typographyGroupID"]="complete-family"}
            return row
        }
        var observed:[[NativeAOTRawTextPainter.Item]]=[]
        do {
            _ = try P.run(items:requested,authenticatedOptions:declared,declaredRaw:declared,
                membershipRaw:declared,policy:.onFailure,outputScale:1,record:nil,render:{proposal in
                    observed.append(proposal)
                    // Exercise request enumeration, not a fabricated raster success.
                    throw NativeFinalTextPaintAdmission.Failure.noSafePlacement("1")
                })
            Issue.record("All synthetic placements were deliberately rejected")
        } catch P.Failure.boundedPlanningUnresolved { }
        #expect(observed.count==P.scales.count)
        for (index,proposal) in observed.enumerated() {
            #expect(proposal.map(\.id)==requested.map(\.id))
            #expect(proposal.map(\.text)==requested.map(\.text))
            #expect(proposal.map(\.frame)==requested.map(\.frame))
            #expect(proposal[0].fontSize==requested[0].fontSize)
            #expect(proposal[1].fontSize==proposal[2].fontSize)
            #expect(abs(proposal[1].fontSize-requested[1].fontSize*P.scales[index])<1e-7)
            #expect(proposal.allSatisfy {$0.fontSize>=12})
        }
    }
}
