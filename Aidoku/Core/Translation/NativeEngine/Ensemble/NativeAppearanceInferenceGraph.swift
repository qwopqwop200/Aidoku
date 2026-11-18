import CryptoKit
import Foundation

/// Synchronous request-scoped audit sink. Callers must own their storage and
/// support Sendable capture; no observer or source packet is retained globally.
typealias NativeSourceFeatureObserver = @Sendable (_ sourceIndex:Int,_ stage:String,_ payload:[String:Any]) throws -> Void

/// Accepted source-head ordering shared by both native platforms. Required
/// physical policies are explicit dependencies; absence is an error, never a
/// successful prediction using the historical palette or an omitted head.
final class NativeAppearanceInferenceGraph {
    typealias Packet=NativeAppearanceSourceFeatures209.Packet
    typealias Ops=any NativeAppearanceImageOperations
    typealias Normal=(SourceNativeInput,Packet,[String:Any],NativeAppearanceModelHeads,Ops,String,[String:Any]?) throws -> [String:Any]
    typealias Layers=(SourceNativeInput,Packet,[String:Any],Ops) throws -> [String:Any]
    typealias Shadow=(SourceNativeInput,[String:Any],[String:Any],Double,NativeAppearanceModelHeads,Ops) throws -> [String:Any]
    typealias Late=(SourceNativeInput,Packet,[String:Any],NativeAppearanceModelHeads,Ops) throws -> [String:Any]
    struct Policies {
        let normalPrimary:Normal
        let outlineLayers:Layers
        let shadow:Shadow
        let lateGradientAndOuterShell:Late
    }
    private final class State: @unchecked Sendable {let lock=NSLock();var policies:Policies?}
    private static let state=State()
    /// Concrete native adapters install their complete implementations once.
    /// This is not an optional policy switch; predict() requires every stage.
    static func installAcceptedPolicies(_ policies:Policies) {
        state.lock.lock();defer {state.lock.unlock()};state.policies=policies
    }
    static func installBuiltInPolicies() {
        installAcceptedPolicies(.init(normalPrimary:{input,packet,prediction,heads,ops,root,configuration in
            try NativeAppearanceNormalProfiles.correctPrimary(input:input,packet:packet,prediction:prediction,
                heads:heads,ops:ops,roleRoot:root,roleConfiguration:configuration)
        },outlineLayers:{input,packet,prediction,ops in
            try NativeAppearanceNormalProfiles.attachLayers(input:input,packet:packet,prediction:prediction,ops:ops)
        },shadow:{input,prediction,reference,width,heads,ops in
            try NativeAppearanceShadowObservation.apply(input:input,prediction:prediction,featurePrediction:reference,
                referenceWidth:width,heads:heads,ops:ops)
        },lateGradientAndOuterShell:{input,packet,prediction,heads,ops in
            try NativeAppearanceLateGradient.refine(input:input,packet:packet,prediction:prediction,heads:heads,ops:ops)
        }))
    }
    private static func requiredPolicies() throws -> Policies {
        state.lock.lock();defer {state.lock.unlock()}
        guard let policies=state.policies else {throw Failure.requiredNativePoliciesUnavailable}
        return policies
    }
    enum Failure:Error {case requiredNativePoliciesUnavailable,invalidPolicy(String)}
    let checkpointIdentity:String
    private let heads:NativeAppearanceModelHeads
    private let ops:Ops
    init(heads:NativeAppearanceModelHeads,ops:Ops=NativeOpenCVAppearanceImageOperations()) throws {
        _ = try Self.requiredPolicies()
        self.heads=heads;self.ops=ops
        let metadata=try Data(contentsOf:heads.directory.appendingPathComponent("appearance-metadata.json"))
        checkpointIdentity=SHA256.hash(data:metadata).map {String(format:"%02x",$0)}.joined()
        let policies=try heads.configuration("appearance/policies")
        for key in ["SHADOW-OBSERVATION-POLICY.json","FINAL-BACKGROUND-POLICY.json",
                    "NATIVE-GRADIENT-CONTOUR-POLICY.json","NATIVE-OUTER-SHELL-POLICY.json"] {
            guard let value=policies[key] as? [String:Any],value["enabled"] as? Bool == true else {throw Failure.invalidPolicy(key)}
        }
    }
    static func featureContext(input:SourceNativeInput,packet:Packet,heads:NativeAppearanceModelHeads,ops:Ops) throws -> [String:Any] {
        let policies=try requiredPolicies(),pixelConfig=try heads.configuration("appearance/pixel-role-model")
        guard let context=pixelConfig["featureContext"] as? [String:Any],
              let roleModel=context["roleModel"] as? [String:Any],let contextPolicy=context["pipelinePolicy"] as? [String:Any] else {
            throw Failure.invalidPolicy("independent pixel-role feature context")
        }
        let root="appearance/pixel-role-model/featureContext/roleModel"
        var reference=try heads.primary(packet,root:root,configuration:roleModel)
        if contextPolicy["sourceNestedContourVersion"] != nil {reference=try NativeAppearanceNestedOutline.recover(input,prediction:reference,ops:ops)}
        if contextPolicy["sourcePrimaryContourVersion"] != nil {reference=try policies.normalPrimary(input,packet,reference,heads,ops,root,roleModel)}
        return reference
    }
    func predict(_ input:SourceNativeInput,sourceIndex:Int=0,diagnostics:NativeSourceFeatureObserver?=nil) throws -> [String:Any] {
        try input.validate();try Task.checkCancellation()
        let featureStart=diagnostics == nil ? nil:DispatchTime.now().uptimeNanoseconds
        let policies=try Self.requiredPolicies(),packet=try NativeAppearanceSourceFeatures209.extract(input,ops:ops)
        if let diagnostics {
            try diagnostics(sourceIndex,"appearance-features",[
                "schema":"aidoku-native-source-features-v1","sourceOnly":true,"GTAtInference":false,
                "sourceIdentity":input.sourceIdentity,"checkpointSHA256":checkpointIdentity,
                "rfModelWeightsSHA256":input.rfModelWeightsSHA256,
                "version":NativeAppearanceSourceFeatures209.version,"colors":packet.colors,
                "features":packet.features,"pair":packet.pair,"fontPixels":packet.fontPixels,
                "maskFraction":packet.maskFraction,
                "extractionMicroseconds":Double(DispatchTime.now().uptimeNanoseconds-featureStart!)/1000])
        }
        var prediction=try heads.primary(packet)
        prediction=try NativeAppearanceNestedOutline.recover(input,prediction:prediction,ops:ops)
        prediction=try policies.normalPrimary(input,packet,prediction,heads,ops,"appearance/model",nil)
        let width=try NativeAppearanceWidth.apply(input,packet:packet,prediction:prediction,heads:heads,ops:ops,sourceIndex:sourceIndex,diagnostics:diagnostics)
        prediction=try policies.outlineLayers(input,packet,width.prediction,ops)
        prediction=try NativeAppearancePalettes.background(input,packet:packet,prediction:prediction,heads:heads,ops:ops)
        let reference=try Self.featureContext(input:input,packet:packet,heads:heads,ops:ops)
        prediction["pixelRoleEvidence"]=try NativeAppearancePalettes.pixelRoles(input,featurePrediction:reference,
            sourcePrediction:prediction,heads:heads,ops:ops)
        prediction=try NativeAppearancePalettes.fill(packet,prediction:prediction,heads:heads,ops:ops)
        prediction=try policies.shadow(input,prediction,reference,width.referenceWidth,heads,ops)
        prediction=try NativeAppearanceFinalBackground.apply(input,prediction:prediction,heads:heads,ops:ops)
        prediction=try policies.lateGradientAndOuterShell(input,packet,prediction,heads,ops)
        prediction["nativeSourceInference"]=["featureVersion":NativeAppearanceSourceFeatures209.version,
            "sourceFeatureCount":209,"pixelRoleFeatureCount":71,"sourceOnly":true,"GTAtInference":false,
            "backend":"native-selected-source-graph","requiredPhysicalPoliciesExecuted":true,
            "checkpointSHA256":checkpointIdentity] as [String:Any]
        return prediction
    }
}
