import Foundation
// Isolated parity harness: exactly the production featureContext sequence,
// without importing unrelated background/shadow graph entrypoints.
enum NativeAppearanceInferenceGraph {
    static func featureContext(input:SourceNativeInput,packet:NativeAppearanceSourceFeatures209.Packet,
                              heads:NativeAppearanceModelHeads,ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        let pixel=try heads.configuration("appearance/pixel-role-model")
        guard let context=pixel["featureContext"] as? [String:Any],let role=context["roleModel"] as? [String:Any],
              let policy=context["pipelinePolicy"] as? [String:Any] else {throw NativeOpenCV.Failure.native("Independent source context required")}
        let root="appearance/pixel-role-model/featureContext/roleModel"
        var result=try heads.primary(packet,root:root,configuration:role)
        if policy["sourceNestedContourVersion"] != nil {result=try NativeAppearanceNestedOutline.recover(input,prediction:result,ops:ops)}
        if policy["sourcePrimaryContourVersion"] != nil {result=try NativeAppearanceNormalProfiles.correctPrimary(input:input,packet:packet,prediction:result,heads:heads,ops:ops,roleRoot:root,roleConfiguration:role)}
        return result
    }
}
// Same frozen identity as Layout/NativeRFDETRLayoutModels.swift; isolate CoreML UI.
enum NativeRFDETRLayoutResource {
    static let highresSourceWeightsSHA256 = "03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255"
}
