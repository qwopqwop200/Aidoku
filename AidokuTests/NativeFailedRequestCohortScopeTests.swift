import CoreGraphics
import Foundation
import Testing
@testable import Aidoku
@Suite(.serialized)
struct NativeFailedRequestCohortScopeTests {
    @Test func onlyPostFailureRequestsEnablePromotedPlanningAndScopeRestores() throws {
        let raw:[[String:Any]]=[["id":"a","text":"A","typographyGroupID":"T"],["id":"b","text":"A","typographyGroupID":"T"]]
        let items:[NativeAOTRawTextPainter.Item]=["a","b"].map {
            .init(id:$0,text:"A",frame:CGRect(x:5,y:5,width:40,height:30),fontSize:20,lineHeight:28,
                chosenFill:CGColor(gray:0,alpha:1),colorAuthority:"synthetic-scope-test")
        }
        #expect(!NativeAOTRawTextPainter.failedRequestCohortPlanning)
        var flags:[Bool]=[]
        #expect(throws:NativeCohortFitPlanner.Failure.self) {
            try NativeCohortFitPlanner.run(items:items,authenticatedOptions:raw,declaredRaw:raw,membershipRaw:raw,
                policy:.onFailure,outputScale:1) {_ in
                flags.append(NativeAOTRawTextPainter.failedRequestCohortPlanning)
                throw NativeFinalTextPaintAdmission.Failure.noSafePlacement("synthetic-scope-trigger")
            }
        }
        #expect(flags == [false,true,true,true,true,true,true,true])
        #expect(!NativeAOTRawTextPainter.failedRequestCohortPlanning)
        var locked=raw;locked[0]["noShrink"]=true;flags=[]
        #expect(throws:NativeCohortFitPlanner.Failure.self) {
            try NativeCohortFitPlanner.run(items:items,authenticatedOptions:locked,declaredRaw:locked,membershipRaw:locked,
                policy:.onFailure,outputScale:1) {_ in
                flags.append(NativeAOTRawTextPainter.failedRequestCohortPlanning)
                throw NativeFinalTextPaintAdmission.Failure.noSafePlacement("synthetic-scope-trigger")
            }
        }
        #expect(flags == [false])
    }
}
