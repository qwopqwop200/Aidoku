import Foundation
struct ReferenceInput:Codable {var length:Int;var fontSize:Double?;var paddingIsValid:Bool}
struct CaseInput:Codable {var initial:[ReferenceInput];var dynamic:[ReferenceInput]}
let cases=try JSONDecoder().decode([CaseInput].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
let results=cases.map { c -> [String:Any] in
    func ref(_ r:ReferenceInput)->NativeReferenceRecoveryBudget.Reference {.init(length:r.length,fontSize:r.fontSize,paddingIsValid:r.paddingIsValid)}
    var budget=NativeReferenceRecoveryBudget(references:c.initial.map(ref))
    let original=budget.readableRemaining
    let steps=(c.initial+c.dynamic).map {r -> [String:Any] in
        let admitted=budget.admit(ref(r))
        return ["admitted":admitted,"refinement":budget.refinementRemaining,"readable":budget.readableRemaining]
    }
    return ["initialReadable":original,"steps":steps]
}
try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
