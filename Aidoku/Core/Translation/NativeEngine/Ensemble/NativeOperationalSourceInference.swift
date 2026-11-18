import CoreGraphics
import CoreML
import CryptoKit
import Foundation

/// One real source constructor for the reader and native host. A complete page
/// passes through selected RF→segmentation→appearance→accepted same-page font.
/// Missing resources or an unported required policy fail; no old-graph fallback.
@available(iOS 18.0, macOS 15.0, *)
final class NativeOperationalSourceInference: NativeLiveSourceAppearance.Backend, @unchecked Sendable {
    private final class Shared: @unchecked Sendable {let lock=NSLock();var instance:NativeOperationalSourceInference?}
    private static let shared=Shared()
    static func annotateDefault(source: CGImage, items: [[String: Any]],
                                sourceEvidence: [String: Any]) throws -> NativeLiveSourceAppearance.Output {
        var firstModel: NativeRFDETRLayoutDetector.InitialModel?
        let backend = try defaultBackend { model in
            if requiresSourceRF(items) { firstModel = model }
        }
        return try withExtendedLifetime(firstModel) {
            try backend.annotate(source: source, items: items, sourceEvidence: sourceEvidence)
        }
    }

    static func defaultBackend(onValidatedRF: ((NativeRFDETRLayoutDetector.InitialModel) -> Void)? = nil) throws -> NativeOperationalSourceInference {
        try NativeSourceInferencePolicy.validate()
        shared.lock.lock();defer {shared.lock.unlock()}
        let staged = try NativeSourceInferencePolicy.stagedM1StyleDirectory()
        if let instance=shared.instance, instance.policy == NativeSourceInferencePolicy.selected,
           instance.m1StyleAssetDirectory == staged {return instance}
        let instance=try NativeOperationalSourceInference(bundle:.main,m1StyleDirectory:staged,onValidatedRF:onValidatedRF);shared.instance=instance;return instance
    }
    private let lock=NSLock()
    private let detector:NativeRFDETRLayoutDetector
    private let segmentation:NativeSourceSegmentationExecution
    private let policy: NativeSourceInferencePolicy.Mode
    var inferencePolicy: NativeSourceInferencePolicy.Mode { policy }
    private let appearance:NativeAppearanceInferenceGraph?
    private let font:NativeAcceptedSourceFontInference?
    private let weight:NativeAcceptedSourceWeightInference?
    private let bodyWeight:NativeSingleBodyWeightInference?
    private let m1Page: NativeM1SourcePageInference?
    let m1StyleAssetDirectory: URL?
    private let ops=NativeOpenCVAppearanceImageOperations()

    // Source bindings hash the native array bytes, including each Float bit.
    // Borrow the crop buffer only for this synchronous update.
    private static func sha256(_ bytes: UnsafeRawBufferPointer) -> String {
        var hash = SHA256()
        hash.update(bufferPointer: bytes)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    init(bundle:Bundle = .main,modelDirectory:URL?=nil,fontResources:URL?=nil,m1StyleDirectory:URL?=nil,
         onValidatedRF: ((NativeRFDETRLayoutDetector.InitialModel) -> Void)? = nil) throws {
        try NativeSourceInferencePolicy.validate()
        policy = NativeSourceInferencePolicy.selected
        let staged = try NativeSourceInferencePolicy.stagedM1StyleDirectory(override: m1StyleDirectory)
        m1StyleAssetDirectory = staged
        if let variant = policy.m1StyleVariant {
            m1Page = try NativeM1SourcePageInference(bundle: bundle, variant: variant,
                modelDirectory: modelDirectory, fontResources: fontResources, styleDirectoryOverride: staged,
                presenceABI: policy.m1PresenceABI)
        } else { m1Page = nil }
        let auxiliaryURL=try Self.auxiliaryURL(bundle:bundle)
        let firstModel: NativeRFDETRLayoutDetector.InitialModel?
        func validateAuxiliary() throws {
            let configuration=MLModelConfiguration();configuration.computeUnits = .cpuAndGPU
            let auxiliary=try MLModel(contentsOf:auxiliaryURL,configuration:configuration)
            try NativeRFDETRLayoutTensorContract.validate(model:auxiliary,
                expectedWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                expectedSourceRevision:NativeRFDETRLayoutResource.highresSourceRevision)
        }
#if targetEnvironment(simulator)
        firstModel = nil
        try validateAuxiliary()
#else
        if let onValidatedRF {
            firstModel = try NativeRFDETRLayoutDetector.InitialModel.validatedIfNeeded(contentsOf: auxiliaryURL)
            if let firstModel { onValidatedRF(firstModel) }
        } else {
            firstModel = nil
            try validateAuxiliary()
        }
#endif
        detector=NativeRFDETRLayoutDetector(retainAllQueryMasks:true,
            expectedWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            expectedSourceRevision:NativeRFDETRLayoutResource.highresSourceRevision,
            initialModel:firstModel,resolveModelURL:{auxiliaryURL})
        segmentation=try NativeSourceSegmentationExecution(bundle:bundle,numericDirectory:modelDirectory)
        if policy.usesAcceptedAppearance {
            let heads=try modelDirectory.map {try NativeAppearanceModelHeads(directory:$0)} ?? NativeAppearanceModelHeads(bundle:bundle)
            NativeAppearanceInferenceGraph.installBuiltInPolicies()
            appearance=try NativeAppearanceInferenceGraph(heads:heads)
            if policy.usesSingleBodyWeight {
                let measurement=try Self.bodyMeasurementSpec(heads:heads,fontResources:fontResources)
                bodyWeight=try NativeSingleBodyWeightInference(heads:heads,measurementSpec:measurement)
            } else { bodyWeight=nil }
            if policy.usesAcceptedWeight {
                let selectedFont=try NativeAcceptedSourceFontInference(heads:heads,fontResources:fontResources)
                font=selectedFont
                weight=try NativeAcceptedSourceWeightInference.productionEnabled(heads:heads) ?
                    NativeAcceptedSourceWeightInference(heads:heads,font:selectedFont,fontResources:fontResources):nil
                if policy != .accepted, weight == nil { throw Failure.requiredWeightUnavailable }
            } else { font=nil; weight=nil }
        } else {
            // Arithmetic-only minimal modes branch before all role heads and
            // metadata. M1p9 modes retain only their explicit BODY/font contract.
            appearance=nil; font=nil; weight=nil; bodyWeight=nil
        }
    }
    /// The current generic weight bridge validates pinned 4/8/4 descriptors.
    /// Resolve them explicitly, but never construct accepted font inference,
    /// PCA metadata heads, prototype tensors or its early/late learned graph.
    private static func bodyMeasurementSpec(heads:NativeAppearanceModelHeads,fontResources:URL?) throws -> [String:Any] {
        let registry=try NativeFrozenSourceModel.Registry(directory:heads.directory,includeMetadata:true)
        let metadata=try registry.metadataTreeFoundation
        guard let font=metadata["font198"] as? [String:Any],
              let graph=font["optimizedGraph"] as? [String:Any],
              let measurement=graph["measurementSpec"] as? [String:Any] else {
            throw Failure.requiredBodyMeasurementSpecUnavailable
        }
        return try NativeSourceFontResolver.resolveMeasurementSpec(measurement,resourceRoot:fontResources)
    }
    private static func auxiliaryURL(bundle:Bundle) throws -> URL {
        for directory:String? in [nil,"Translation","Resources/Translation"] {
            if let url=bundle.url(forResource:"KoharuHighres648FP16",withExtension:"mlmodelc",subdirectory:directory),
               FileManager.default.fileExists(atPath:url.path) {
#if os(iOS)
                return try NativeCoreMLModelStore.shared.modelURL(for: url)
#else
                return url
#endif
            }
        }
        throw NativeRFDETRLayoutError.modelUnavailable
    }
    private final class RFResult: @unchecked Sendable {
        let condition=NSCondition();var result:Result<NativeRFDETRLayoutResult,Error>?
        func complete(_ result:Result<NativeRFDETRLayoutResult,Error>) {condition.lock();self.result=result;condition.broadcast();condition.unlock()}
        func wait() throws -> NativeRFDETRLayoutResult {
            condition.lock();defer {condition.unlock()};while result==nil {condition.wait()};return try result!.get()
        }
    }
    private func sourceRF(_ source:NativeRFDETRSourceImage) throws -> NativeRFDETRLayoutResult {
        let result=RFResult(),detector=detector
        let task=Task.detached(priority:.userInitiated) {
            do {result.complete(.success(try await detector.detect(source:source)))} catch {result.complete(.failure(error))}
        }
        defer {if Task.isCancelled {task.cancel()}}
        return try result.wait()
    }
    struct FontPrediction {
        let values: [Double]
        let stages: [String: [Double]]
        let estimatorIdentity: String
    }
    func predict(_ inputs:[SourceNativeInput],returnFontStages:Bool=false,diagnostics:NativeSourceFeatureObserver?=nil,segmentationObserver:NativeSelectedSourceSegmentationProducer.SourceReplayObserver?=nil) throws -> (inputs:[SourceNativeInput],styles:[[String:Any]],font:FontPrediction,weights:[[String:Any]]?) {
        // A rich replay/bank contract cannot masquerade as minimal observations.
        guard !policy.usesMinimalObservations, let appearance else { throw Failure.minimalEntryRequired }
        let timingStart=diagnostics == nil ? nil:DispatchTime.now().uptimeNanoseconds
        var bboxFontNS:UInt64=0,weightNS:UInt64=0
        var outputs:[SourceNativeInput]=[];outputs.reserveCapacity(inputs.count)
        for input in inputs {try Task.checkCancellation();outputs.append(try segmentation.segment(input,replayObserver:segmentationObserver).input)}
        let segmentationEnd=diagnostics == nil ? nil:DispatchTime.now().uptimeNanoseconds
        // Context is the page-aligned union of independently predicted OWN masks.
        var owners=outputs.enumerated().map {NativeSourceInputFactory.Owner(itemIndex:$0.offset,polygon:$0.element.mergedPolygon,input:$0.element)}
        NativeSourceInputFactory.contexts(&owners);outputs=owners.map(\.input)
        let contextEnd=diagnostics == nil ? nil:DispatchTime.now().uptimeNanoseconds
        if let diagnostics {
            for (i,input) in outputs.enumerated() {
                try diagnostics(i,"source-binding",[
                    "schema":"aidoku-native-source-features-v1","sourceOnly":true,"GTAtInference":false,
                    "sourceIdentity":input.sourceIdentity,"width":input.width,"height":input.height,
                    "rgbSHA256":input.rgb.withUnsafeBytes(Self.sha256),
                    "predictedMaskSHA256":input.ownMask.withUnsafeBytes(Self.sha256),
                    "rfModelWeightsSHA256":input.rfModelWeightsSHA256,
                    "cropBounds":[input.crop.minX,input.crop.minY,input.crop.maxX,input.crop.maxY].map(Double.init),
                    "bbox":[input.bbox.minX,input.bbox.minY,input.bbox.width,input.bbox.height].map(Double.init),
                    "pageSize":[Double(input.pageSize.width),Double(input.pageSize.height)],
                    "fontPriorSourcePixels":input.fontPriorSourcePixels,
                    "memberPolygonsLocal":input.memberPolygons.map {$0.map {[Double($0.x),Double($0.y)]}},
                    "mergedPolygonLocal":input.mergedPolygon.map {[Double($0.x),Double($0.y)]},
                    "sourceTextSHA256":NativeFrozenSourceSHA256.hex(Data(input.sourceText.utf8)),
                    "fullRFSHA256":input.rf.withUnsafeBytes(Self.sha256),
                    "coarseRFSHA256":input.coarseRF.withUnsafeBytes(Self.sha256),
                    "primarySHA256":input.primary.withUnsafeBytes(Self.sha256),
                    "boundarySHA256":input.boundary.withUnsafeBytes(Self.sha256),
                    "ocrSHA256":input.ocr.withUnsafeBytes(Self.sha256),
                    "contextMaskSHA256":input.contextMask.withUnsafeBytes(Self.sha256)])
            }
        }
        let styles=try outputs.enumerated().map {try appearance.predict($0.element,sourceIndex:$0.offset,diagnostics:diagnostics)}
        let appearanceEnd=diagnostics == nil ? nil:DispatchTime.now().uptimeNanoseconds
        // Preserve the exact source-font call's residuals, priors, final ems and
        // segmentation/RF packets for weight inference; never remeasure a donor.
        let fonts:FontPrediction
        var acceptedFontContext:NativeAcceptedSourceFontInference.SourceFontContext?
        if policy == .accepted {
            guard let font else { throw Failure.minimalEntryRequired }
            let accepted=try font.estimate(outputs,styles:styles,returnStages:returnFontStages || diagnostics != nil,returnContext:true)
            fonts = .init(values:accepted.values,stages:accepted.stages,estimatorIdentity:accepted.estimatorIdentity)
            acceptedFontContext=accepted.context
        } else {
            let values=try NativeSourceInferencePolicy.simpleFontConfiguration.estimate(outputs.map {
                .init(bounds:$0.bbox,originalCharacterCount:$0.sourceText.unicodeScalars.count,memberPolygons:$0.memberPolygons)
            })
            fonts = .init(values:values,stages:[:],estimatorIdentity:NativeSimpleSourceFont.identity)
        }
        let firstFontEnd=diagnostics == nil ? nil:DispatchTime.now().uptimeNanoseconds
        if let diagnostics, let context=acceptedFontContext {
            for i in outputs.indices {
                var stageValues:[String:Double]=[:]
                for (stage,values) in fonts.stages {
                    guard values.count==outputs.count else {throw NativeSourceInputFactory.Failure.sourceMismatch}
                    stageValues[stage]=values[i]
                }
                try diagnostics(i,"font-features",["sourceIdentity":outputs[i].sourceIdentity,
                    "style187":context.style187[i],"angle131":context.angles131[i],
                    "originalPrior":context.originalPriors[i],"finalSourceEM":context.finalSourceEMs[i],
                    "stages":stageValues,"sourceOnly":true,"GTAtInference":false])
            }
        }
        var weights:[[String:Any]]?
        if let weight {
            guard let font else { throw Failure.requiredWeightUnavailable }
            // Keep the renderer's original member-aware font estimate intact.
            // Weight normalization uses the source-only bbox contract verified
            // by the operational producer, with its own same-call context.
            let bboxStart=diagnostics == nil ? nil:DispatchTime.now().uptimeNanoseconds
            let normalized=try font.estimate(outputs,styles:styles,returnContext:true,geometry:.bboxOnly)
            if let bboxStart {bboxFontNS=DispatchTime.now().uptimeNanoseconds-bboxStart}
            guard let context=normalized.context else {throw NativeSourceInputFactory.Failure.sourceMismatch}
            if let diagnostics {
                for i in outputs.indices {
                    try diagnostics(i,"weight-font-features",["sourceIdentity":outputs[i].sourceIdentity,
                        "style187":context.style187[i],"angle131":context.angles131[i],
                        "originalPrior":context.originalPriors[i],"finalSourceEM":context.finalSourceEMs[i],
                        "sourceOnly":true,"GTAtInference":false])
                }
            }
            let weightDiagnostics:NativeSourceFeatureObserver?
            if let diagnostics {
                let sourceInputs=outputs
                weightDiagnostics={index,stage,payload in
                    var bound=payload
                    bound["sourceIdentity"]=sourceInputs[index].sourceIdentity
                    bound["rfModelWeightsSHA256"]=sourceInputs[index].rfModelWeightsSHA256
                    bound["originalPrior"]=sourceInputs[index].fontPriorSourcePixels
                    try diagnostics(index,stage,bound)
                }
            } else {weightDiagnostics=nil}
            let weightStart=diagnostics == nil ? nil:DispatchTime.now().uptimeNanoseconds
            weights=try weight.estimate(context,styles:styles,diagnostics:weightDiagnostics)
            if let weightStart {weightNS=DispatchTime.now().uptimeNanoseconds-weightStart}
        }
        if policy == .simpleFontAcceptedStyle {
            weights=try outputs.indices.map { index in
                let input=outputs[index],style=styles[index]
                func colour(_ key:String) throws -> [Double] {
                    guard let role=style[key] as? [String:Any],let values=role["rgb"] as? [NSNumber],values.count==3 else {
                        throw NativeSourceInputFactory.Failure.sourceMismatch
                    }
                    return values.map(\.doubleValue)
                }
                let outline=style["outline"] as? [String:Any]
                guard let outlinePresent=outline?["present"] as? Bool else {
                    throw NativeSourceInputFactory.Failure.sourceMismatch
                }
                let outlineColour=outlinePresent ? (outline?["rgb"] as? [NSNumber])?.map(\.doubleValue):nil
                let outlineWidth=outlinePresent ? (outline?["widthPx"] as? NSNumber)?.doubleValue:0
                guard let outlineWidth, !outlinePresent || outlineColour?.count == 3 else {
                    throw NativeSourceInputFactory.Failure.sourceMismatch
                }
                return try NativePhysicalSourceStyle.estimateAcceptedBody(rgb:input.rgb,width:input.width,height:input.height,
                    mask:input.ownMask,fontPrior:input.fontPriorSourcePixels,bbox:input.bbox,
                    fillRGB:colour("fill"),outlineRGB:outlineColour,
                    outlineWidth:outlineWidth,
                    backgroundRGB:colour("background"),boldThreshold:0.10).weight
            }
        }
        if let bodyWeight {
            let start=diagnostics == nil ? nil:DispatchTime.now().uptimeNanoseconds
            weights=try bodyWeight.estimate(outputs,styles:styles)
            if let start { weightNS=DispatchTime.now().uptimeNanoseconds-start }
        }
        if let diagnostics {
            for i in outputs.indices {
                var payload:[String:Any]=["schema":"aidoku-native-source-features-v1","sourceOnly":true,
                    "GTAtInference":false,"sourceIdentity":outputs[i].sourceIdentity,"style":styles[i],
                    "fontSourcePixels":fonts.values[i]]
                if let weights {payload["weight"]=weights[i]}
                try diagnostics(i,"source-prediction",payload)
            }
        }
        if let diagnostics,let timingStart,let segmentationEnd,let contextEnd,let appearanceEnd,let firstFontEnd,
           let source=outputs.first {
            func milliseconds(_ value:UInt64)->Double {Double(value)/1_000_000}
            try diagnostics(-1,"page-stage-timings",["sourceIdentity":source.sourceIdentity,
                "scope":"page-metadata-not-model-features","owners":outputs.count,
                "segmentationMS":milliseconds(segmentationEnd-timingStart),
                "contextsMS":milliseconds(contextEnd-segmentationEnd),
                "appearanceMS":milliseconds(appearanceEnd-contextEnd),
                "firstFontMS":milliseconds(firstFontEnd-appearanceEnd),
                "bboxOnlyFontMS":milliseconds(bboxFontNS),"weightMS":milliseconds(weightNS),
                "predictTotalMS":milliseconds(DispatchTime.now().uptimeNanoseconds-timingStart),
                "includesOptInObserverCost":true,"modelInput":false])
        }
        return(outputs,styles,fonts,weights)
    }
    enum Failure: Error {
        case minimalEntryRequired, incompatibleMinimalObserver, requiredWeightUnavailable, requiredBodyMeasurementSpecUnavailable
    }
    private static func requiresSourceRF(_ items: [[String: Any]]) -> Bool {
        items.contains(where:{$0["keptLettering"] as? Bool != true && $0["sourceTextOnly"] as? Bool != true && !($0["text"] as? String ?? "").isEmpty})
    }
    func annotate(source:CGImage,items:[[String:Any]],sourceEvidence:[String:Any]) throws -> NativeLiveSourceAppearance.Output {
        try annotate(source: source, items: items, sourceEvidence: sourceEvidence, segmentationObserver: nil)
    }
    func annotate(source:CGImage,items:[[String:Any]],sourceEvidence:[String:Any],
                  segmentationObserver:NativeSelectedSourceSegmentationProducer.SourceReplayObserver?,
                  diagnostics:NativeSourceFeatureObserver?=nil,
                  constructorObserver: (([NativeSourceInputFactory.Owner], NativeRFDETRSourceImage) throws -> Void)? = nil) throws -> NativeLiveSourceAppearance.Output {
        lock.lock();defer {lock.unlock()};try Task.checkCancellation()
        guard Self.requiresSourceRF(items) else {
            return .init(items:items)
        }
        let decoded = try NativeRFDETRSourceImage.decode(source).withPreparedIdentity()
        let rf = try sourceRF(decoded)
        guard rf.imageIdentity==decoded.identity,rf.semanticGrid?.modelWeightsSHA256==NativeRFDETRLayoutResource.highresSourceWeightsSHA256 else {
            throw NativeSourceInputFactory.Failure.sourceMismatch
        }
        let producerIdentity=NativeSelectedSourceSegmentationMasks.ProducerIdentity(producerOriginal:source,decodedSource:decoded)
        let canonicalSourceIdentity=producerIdentity?.canonicalRGBSHA256 ?? decoded.identity
        if policy.usesMinimalObservations {
            guard constructorObserver == nil, segmentationObserver == nil else { throw Failure.incompatibleMinimalObserver }
            return try annotateMinimal(source: source, decoded: decoded, rf: rf, items: items,
                sourceEvidence: sourceEvidence, diagnostics: diagnostics, producerIdentity: producerIdentity)
        }
        guard let appearance else { throw Failure.minimalEntryRequired }
        let owners=try NativeSourceInputFactory.make(source:decoded,items:items,sourceEvidence:sourceEvidence,
            rf:NativePixelRFEvidence(result:rf),ops:ops,geometryFontPriorOnly:policy.usesSimpleFont)
        // Opt-in module-bank receipt at the actual constructor boundary. Nil
        // does not traverse/copy inputs or retain any source arrays.
        try constructorObserver?(owners, decoded)
        if let diagnostics {
            for (i,owner) in owners.enumerated() {
                try diagnostics(i,"owner-binding",["sourceIdentity":owner.input.sourceIdentity,
                    "itemIndex":owner.itemIndex,"ownerIndex":i,"sourceOnly":true,"GTAtInference":false])
            }
        }
        let inference=try predict(owners.map(\.input),diagnostics:diagnostics,segmentationObserver:segmentationObserver)
        guard inference.styles.count==owners.count,inference.font.values.count==owners.count else {throw NativeSourceInputFactory.Failure.sourceMismatch}
        var result=items,entries:[NativeSelectedSourceSegmentationMasks.Entry]=[]
        let sourceWitnessRequest=NativeSourceBackedRFProtection.requested(sourceEvidence,original:source)
        var sourceWitnessWork=0
        func sha(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
        func floatSHA(_ values:[Float])->String {values.withUnsafeBytes(Self.sha256)}
        for i in owners.indices {
            let owner=owners[i],input=inference.inputs[i],style=inference.styles[i],sourceFont=inference.font.values[i]
            let geometry:[String:Any]=["polygons":input.memberPolygons.map {$0.map {[Double($0.x),Double($0.y)]}},
                "mergedPolygon":input.mergedPolygon.map {[Double($0.x),Double($0.y)]},"fontPixels":input.fontPriorSourcePixels]
            let geometryData=try JSONSerialization.data(withJSONObject:geometry,options:[.sortedKeys,.withoutEscapingSlashes])
            let binding:[String:String]=["rgbSHA256":input.rgb.withUnsafeBytes(Self.sha256),"rfSHA256":floatSHA(input.rf),
                "maskSHA256":sha(Data(input.ownMask.map {$0==0 ? 0:1})),
                "contextSHA256":sha(Data(input.contextMask.map {$0==0 ? 0:1})),
                "segPrimarySHA256":floatSHA(input.primary),"segBoundarySHA256":floatSHA(input.boundary),
                "ocrSHA256":floatSHA(input.ocr),"geometrySHA256":sha(geometryData),
                "rfModelWeightsSHA256":input.rfModelWeightsSHA256,"checkpointSHA256":appearance.checkpointIdentity]
            let packet:[String:Any]=["schema":"aidoku-live-source-appearance-v1","sourceOnly":true,"freshInference":true,
                "GTAtInference":false,"cachedPredictionsRead":false,"binding":binding,"prediction":style,
                "geometry":geometry,"width":input.width,"height":input.height]
            var item=try NativeOperationalAppearance.apply(packet:JSONSerialization.data(withJSONObject:packet),expectedBinding:binding,to:items[owner.itemIndex])
            let oldFont=(item["fontSize"] as? NSNumber)?.doubleValue ?? input.fontPriorSourcePixels
            let oldSource=(item["sourceFontSize"] as? NSNumber)?.doubleValue ?? input.fontPriorSourcePixels
            let oldLeading=(item["lineHeight"] as? NSNumber)?.doubleValue ?? oldFont
            let display=policy.usesSimpleFont ? sourceFont:sourceFont*oldFont/max(1,oldSource)
            item["sourceFontSize"]=sourceFont;item["sourceFontAuthority"]="\(inference.font.estimatorIdentity);original-source-pixels;same-page-group"
            item["sourceAppearanceUnits"]="original-source-pixels;native-page-localized"
            item["sourcePredictedStyle"]=style;item["sourceRequestedDisplayFontSize"]=display
            item["fontSize"]=display;item["lineHeight"]=policy.usesSimpleFont ? display:display*max(1,oldLeading/max(1,oldFont))
            if policy.usesSimpleFont {
                item["sourceInferencePolicy"]=NativeSourceInferencePolicy.cacheProjection
                item["sourceFontPriorAuthority"]="recomputed-source-bbox-unicode-scalars;inherited-sourceFontSize-ignored"
                item["sourceFontHeadsRetainedForWeight"]=policy.usesAcceptedWeight
            }
            item["sourceMemberPolygons"]=owner.originalMemberPolygons.map {$0.map {[Double($0.x),Double($0.y)]}}
            item["sourceMemberPolygonsCrop"]=input.memberPolygons.map {$0.map {[Double($0.x),Double($0.y)]}}
            item["sourceFeatureGeometryClipping"]=owner.geometryClippingAudit
            if let weights=inference.weights {
                let decision=weights[i]
                guard let label=decision["sourceWeight"] as? String,["regular","bold","mixed"].contains(label),
                      let bold=decision["renderBold"] as? Bool,bold==(label=="bold") else {
                    throw NativeSourceInputFactory.Failure.sourceMismatch
                }
                item["sourceFontWeight"]=label;item["renderBold"]=bold
                if policy.usesSingleBodyWeight {
                    item["sourceWeightAuthority"]="single-body180-head;raw597-original-constructor-prior;no-font-NN-PCA-prototype-context"
                } else {
                    item["sourceWeightAuthority"]=policy.usesAcceptedWeight ?
                        "accepted-frozen-weight;bbox-accepted-font-context-retained;source-seg-rf-font-style":
                        "accepted-source-fill-physical-stem-density;constructor-geometric-prior;no-weight-head"
                }
                item["sourceWeightEvidence"]=decision
                item.removeValue(forKey:"sourceWeightRuns")
            }
            let erasure: [UInt8]
            if let configuration = NativeSourceInferencePolicy.erasureSegmentationConfiguration {
                // Only the OUTPUT erasure mask changes. Appearance209, body597
                // and any explicit rollback weight context retain actual rich
                // input.ownMask/context and their original feature bindings.
                erasure = try NativeMinimalSourceSegmentation.postprocessPrimary(input.primary,
                    width: input.width, height: input.height, configuration: configuration)
                item["sourceErasurePolicySHA256"] = configuration.policySHA256
                item["sourceErasureMaskAuthority"] = "independent-primary-postprocess;rich-feature-masks-unchanged;no-extra-head"
            } else { erasure = input.ownMask }
            let mask=erasure.map {UInt8($0==0 ? 0:255)}
            item["sourceErasureMaskSHA256"] = mask.withUnsafeBytes(Self.sha256)
            result[owner.itemIndex]=item
            let witness=NativeSourceBackedRFProtection.pack(rawNative:input.rawNative,selected:mask,crop:input.crop,
                sourceIdentity:canonicalSourceIdentity,original:source,request:sourceWitnessRequest,work:&sourceWitnessWork)
            entries.append(.init(ownerPolygon:owner.polygon,crop:input.crop,mask:mask,positiveSourceSeed:witness))
        }
        return .init(items:NativeSourceFontFitGroups.annotate(result),
            sourceSegmentationMasks:.init(original:source,entries:entries,producerIdentity:producerIdentity),
            sourceRF:.init(sourceIdentity:canonicalSourceIdentity,
                modelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                regions:try NativeMainRFRegionAdapter.regions(from:rf,source:decoded)))
    }

    /// Pure output selection, with no backend/model construction. Equal policy
    /// identity reuses the actual observation mask, including typed rollback.
    static func minimalErasureMask(observation: NativeMinimalSourceSegmentation.Output,
                                   width: Int, height: Int,
                                   configuration: NativeMinimalSourceSegmentation.Configuration?) throws -> [UInt8] {
        guard let configuration else { return observation.mask }
        if observation.audit["policySHA256"] as? String == configuration.policySHA256 {
            return observation.mask
        }
        guard let primary = observation.primary else { throw NativeMinimalSourceSegmentation.Failure.missingPrimary }
        return try NativeMinimalSourceSegmentation.postprocessPrimary(primary,
            width: width, height: height, configuration: configuration)
    }

    /// Arithmetic modes use zero SourceModels roles. Explicit M1p9 modes use
    /// one primary62 + five pinned style roles + one BODY180, with real pinned
    /// font measurement/admission costs. No rich209 or accepted style graph.
    private func annotateMinimal(source: CGImage, decoded: NativeRFDETRSourceImage,
        rf: NativeRFDETRLayoutResult, items: [[String: Any]], sourceEvidence: [String: Any],
        diagnostics: NativeSourceFeatureObserver?, producerIdentity: NativeSelectedSourceSegmentationMasks.ProducerIdentity?)
        throws -> NativeLiveSourceAppearance.Output {
        let canonicalSourceIdentity = producerIdentity?.canonicalRGBSHA256 ?? decoded.identity
        let owners = try NativeSourceInputFactory.makeMinimal(source: decoded, items: items,
            sourceEvidence: sourceEvidence, rf: NativePixelRFEvidence(result: rf), observationMode: .sourcePreparation) { input in
                try Task.checkCancellation()
                return .init(segmentation: try segmentation.predictMinimal(input),
                    fullRFSHA256: input.fullRF.withUnsafeBytes(Self.sha256),
                    coarseRFSHA256: input.coarseRF.withUnsafeBytes(Self.sha256),
                    rfModelWeightsSHA256: input.rfModelWeightsSHA256)
            }
        let fonts = try NativeSourceInferencePolicy.simpleFontConfiguration.estimate(owners.map {
            .init(bounds: $0.bbox, originalCharacterCount: $0.sourceText.unicodeScalars.count, memberPolygons: $0.memberPolygons)
        })
        guard fonts.count == owners.count else { throw NativeSourceInputFactory.Failure.sourceMismatch }
        var learnedStyles: [[String: Any]] = [], learnedWeights: [[String: Any]] = []
        if let m1Page {
            guard policy.usesMinimalM1Style else { throw Failure.requiredWeightUnavailable }
            let measured = try owners.map { owner in
                try Task.checkCancellation()
                return try NativeSourceInputFactory.makeM1StyleObservation(owner: owner)
            }
            // Exactly the same coreless bundled seam exercised by activation
            // tests; whole page source order is never GT-matched/subsampled.
            let page = try m1Page.predict(measured)
            learnedStyles = page.styles; learnedWeights = page.weights
            guard learnedStyles.count == owners.count, learnedWeights.count == owners.count else {
                throw NativeSourceInputFactory.Failure.sourceMismatch
            }
        } else if policy.usesMinimalM1Style { throw Failure.requiredWeightUnavailable }
        var result = items, entries: [NativeSelectedSourceSegmentationMasks.Entry] = []
        let witnessRequest = NativeSourceBackedRFProtection.requested(sourceEvidence, original: source)
        var witnessWork = 0
        for i in owners.indices {
            try Task.checkCancellation()
            let owner = owners[i]
            let observation = owner.observation.segmentation
            let style: [String: Any], sourceWeight: [String: Any], display: [String: Any]
            if policy.usesMinimalM1Style {
                style = learnedStyles[i]; sourceWeight = learnedWeights[i]
                guard let fill = (style["fill"] as? [String: Any])?["rgb"] as? [Double], fill.count == 3,
                      fill.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else {
                    throw NativeSourceInputFactory.Failure.sourceMismatch
                }
                let luminance = 0.2126 * fill[0] + 0.7152 * fill[1] + 0.0722 * fill[2]
                display = ["fillRGB": fill, "outlineRGB": luminance >= 127.5 ? [0.0, 0, 0] : [255.0, 255, 255],
                    "outlineWidthPx": max(1, owner.fontPixels * 0.035), "strokeBeforeFill": true,
                    "authority": "predicted-source-fill;mandatory-contrasting-BW-display-stroke"]
            } else {
                let physical = try NativePhysicalSourceStyle.estimate(rgb: owner.rgb, width: owner.width,
                    height: owner.height, mask: observation.mask, fontPrior: owner.fontPixels,
                    bbox: owner.bbox, primary: observation.primary)
                style = physical.style; sourceWeight = physical.weight
                var carrier = physical.display
                carrier["fillRGB"] = (physical.display["fillRGB"] as? [Int])?.map(Double.init)
                carrier["outlineRGB"] = (physical.display["outlineRGB"] as? [Int])?.map(Double.init)
                display = carrier
            }
            var item = items[owner.itemIndex]
            // Never retain cached learned authority, font faces, weight runs or
            // rich-graph paint receipts from an earlier render transaction.
            for key in ["sourceAppearanceBinding", "sourceContourPaintBinding", "sourceFontFace",
                "sourceWeightRuns", "sourceWeightEvidence", "sourceStyleGroupID", "sourceFontFitGroupID",
                "sourceFontFitGroupAuthority", "sourceContourCohortVeto", "renderSourceShadow"] {
                item.removeValue(forKey: key)
            }
            let binding: [String: Any] = ["schema": "aidoku-minimal-source-observations-v1",
                "sourceIdentity": owner.sourceIdentity, "rgbSHA256": owner.rgb.withUnsafeBytes(Self.sha256),
                "maskSHA256": observation.mask.withUnsafeBytes(Self.sha256),
                "fullRFSHA256": owner.observation.fullRFSHA256,
                "coarseRFSHA256": owner.observation.coarseRFSHA256,
                "constructorPriorSourcePixels": owner.fontPixels,
                "constructorPriorF64": String(format: "%016llx", owner.fontPixels.bitPattern),
                "primarySHA256": observation.primary.map { $0.withUnsafeBytes(Self.sha256) } ?? "not-observed",
                "primaryFeatureSamplingPolicy": observation.primary == nil ? "not-executed" : NativePixelRFFeatures.samplingPolicyVersion,
                "rfModelWeightsSHA256": owner.observation.rfModelWeightsSHA256,
                "policy": NativeSourceInferencePolicy.cacheProjection,
                "styleFeatureABI": policy.usesMinimalM1Style ? NativeM1SourceStyleFeatures44.revision : "physical-arithmetic",
                "sourcePageCheckpointSHA256": m1Page?.checkpointIdentity ?? "not-used",
                "styleAndErasureShareActualM1Mask": policy.usesMinimalM1Style &&
                    (observation.audit["policySHA256"] as? String) == NativeSourceSegmentationExecution.erasurePolicySHA256,
                "observations": ["primary": observation.primary != nil,
                    "nativeSeed": observation.nativeSeed != nil, "boundary": false,
                    "ocr8": false, "style187": false, "angle131": false],
                "sourceOnly": true, "GTAtInference": false, "cachedPredictionsRead": false]
            item["sourceMinimalObservationBinding"] = binding
            item["sourceAppearance"] = style; item["sourcePredictedStyle"] = style
            item["sourceAppearanceUnits"] = policy.usesMinimalM1Style ? "original-source-pixels;actual-M1-p9-five-role" :
                "original-source-pixels;minimal-physical-source"
            item["sourceFontSize"] = fonts[i]; item["fontSize"] = fonts[i]
            item["sourceRequestedDisplayFontSize"] = fonts[i]; item["lineHeight"] = fonts[i]
            item["sourceFontAuthority"] = "simple-source-font-geometry-unicode-scalars-v1;no-inherited-font;no-font-head"
            item["sourceFontWeight"] = sourceWeight["sourceWeight"]
            item["renderBold"] = sourceWeight["renderBold"]
            item["renderWeight"] = sourceWeight["renderWeight"]
            item["sourceWeightEvidence"] = sourceWeight
            item["sourceWeightAuthority"] = policy.usesMinimalM1Style ?
                "single-BODY180;dedicated-raw597;original-prior;actual-M1-style-admission" :
                "physical-source-stem-density;constructor-geometric-prior;no-weight-head"
            // The live renderer reads [Double] directly, without a JSON round
            // trip. Do not leave histogram [Int] colours in that typed ABI.
            let fill = display["fillRGB"] as? [Double]
            let stroke = display["outlineRGB"] as? [Double]
            guard let fill, let stroke, fill.count == 3, stroke.count == 3 else {
                throw NativeSourceInputFactory.Failure.sourceMismatch
            }
            item["ensembleDisplayFill"] = fill
            item["renderSourceFillRGB"] = fill
            item["renderSourceOutlineRGB"] = stroke
            item["renderSourceDisplayStrokeRGB"] = stroke
            item["renderSourceOutlineWidthPx"] = display["outlineWidthPx"]
            item["sourceMinimalDisplayPolicy"] = display
            item["ensemblePaletteAudit"] = ["sourceFill": fill, "displayFill": fill,
                "displayStroke": stroke, "authority": policy.usesMinimalM1Style ? NativeM1SourceStyleInference.revision : NativePhysicalSourceStyle.revision,
                "sourceOnly": true, "GTAtInference": false, "noLearnedPaletteHead": !policy.usesMinimalM1Style] as [String: Any]
            item["sourceMemberPolygons"] = owner.originalMemberPolygons.map { $0.map { [Double($0.x), Double($0.y)] } }
            item["sourceMemberPolygonsCrop"] = owner.memberPolygons.map { $0.map { [Double($0.x), Double($0.y)] } }
            item["sourceFeatureGeometryClipping"] = owner.geometryClippingAudit
            // Style/BODY inputs above retain actual M1. Only the final erasure
            // output replays the already-computed p when policy differs.
            let erasure = try Self.minimalErasureMask(observation: observation,
                width: owner.width, height: owner.height,
                configuration: NativeSourceInferencePolicy.erasureSegmentationConfiguration)
            let mask = erasure.map { UInt8($0 == 0 ? 0 : 255) }
            item["sourceErasureMaskSHA256"] = mask.withUnsafeBytes(Self.sha256)
            item["sourceErasurePolicySHA256"] = NativeSourceSegmentationExecution.erasurePolicySHA256
            if observation.primary == nil {
                item["sourceErasureMaskAuthority"] = "actual-minimal-RF-mask;no-primary"
            } else if (observation.audit["policySHA256"] as? String) == NativeSourceSegmentationExecution.erasurePolicySHA256 {
                item["sourceErasureMaskAuthority"] = "reused-actual-primary-mask;same-erasure-policy;no-extra-head"
            } else {
                item["sourceErasureMaskAuthority"] = "independent-primary-postprocess;feature-style-M1-mask-unchanged;no-extra-head"
            }
            item["sourceInferencePolicy"] = NativeSourceInferencePolicy.cacheProjection
            result[owner.itemIndex] = item
            var witness: NativeSourceBackedRFProtection.PackedSeed?
            if let nativeSeed = observation.nativeSeed {
                witness = NativeSourceBackedRFProtection.pack(rawNative: nativeSeed, selected: mask, crop: owner.crop,
                    sourceIdentity: canonicalSourceIdentity, original: source, request: witnessRequest, work: &witnessWork)
            }
            entries.append(.init(ownerPolygon: owner.polygon, crop: owner.crop, mask: mask, positiveSourceSeed: witness))
            if let diagnostics {
                try diagnostics(i, "minimal-source-prediction", ["sourceIdentity": owner.sourceIdentity,
                    "binding": binding, "segmentation": observation.audit, "style": style,
                    "weight": sourceWeight, "fontSourcePixels": fonts[i], "constructorPrior": owner.fontPixels,
                    "sourceModelRoleCount": policy.usesMinimalM1Style ? 6 : 0,
                    "styleRoleForwardCalls": policy.usesMinimalM1Style ? 5 : 0,
                    "BODYPageBatchForwardCalls": policy.usesMinimalM1Style && i == owners.startIndex ? 1 : 0,
                    "BODYOwnerRows": policy.usesMinimalM1Style ? 1 : 0,
                    "primaryModelHeadCalls": observation.primary == nil ? 0 : 1,
                    "fontMeasurementCalls": policy.usesMinimalM1Style ? 1 : 0, "oldWeightMeasurementCalls": 0])
            }
        }
        return .init(items: NativeSourceFontFitGroups.annotate(result),
            sourceSegmentationMasks: .init(original: source, entries: entries, producerIdentity: producerIdentity),
            sourceRF: .init(sourceIdentity: canonicalSourceIdentity,
                modelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                regions: try NativeMainRFRegionAdapter.regions(from: rf, source: decoded)))
    }
}
