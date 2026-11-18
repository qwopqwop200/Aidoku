import CoreGraphics
import CryptoKit
import Foundation

/// Platform resource/settings adapter to the SAME shared Reader ensure.
/// Settings recovered from old stages authorize a NEW current prediction, not
/// retroactive proof of an old model/map. No REC/provider/owner mutation here.
enum HostDBProbability {
    /// Explicit offline render QA can permit its one pre-ensure prediction,
    /// then require every render-side lookup to use that retained capability.
    @MainActor static var requiresCachedProbability = false
    struct Configuration {
        let value:ReaderOCRConfiguration
        let authority:String
    }
    private static func decode(_ value:[String:Any]) throws -> ReaderOCRConfiguration {
        try JSONDecoder().decode(ReaderOCRConfiguration.self,from:JSONSerialization.data(withJSONObject:value))
    }
    static func configuration(arguments:[String:Any],original:CGImage,stageDirectory:URL) throws -> Configuration {
        if let value=arguments["nativeOCRConfiguration"] as? [String:Any] {
            return .init(value:try decode(value),authority:"explicit-payload-current-OCR-settings-not-model-proof")
        }
        var candidates=[ReaderOCRConfiguration]()
        for file in try HostAnalysis.stageFiles(in:stageDirectory) {
            guard file.pathExtension=="json",
                  let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any],
                  let stage=envelope["stage"] as? String,stage=="input" || stage=="runtime-settings",
                  let value=envelope["value"] as? [String:Any] else {continue}
            if stage=="input" {
                guard value["width"] as? Int==original.width,value["height"] as? Int==original.height else {
                    throw HostError.message("Saved OCR settings source dimensions differ")
                }
            }
            let raw=(stage=="input" ? value["configuration"]:value["ocr"]) as? [String:Any]
            if let raw {candidates.append(try decode(raw))}
        }
        guard let first=candidates.first,candidates.allSatisfy({$0==first}) else {
            throw HostError.message("Missing or conflicting saved OCR settings; required DB capability cannot assume manga defaults")
        }
        return .init(value:first,authority:"legacy-saved-input-settings-new-current-prediction-not-historical-model-proof")
    }
    static func prepare(arguments:[String:Any],original:CGImage,stageDirectory:URL,root:URL) async throws -> NativeMainEnsemblePreparedDB {
        try Task.checkCancellation()
        let selection=try configuration(arguments:arguments,original:original,stageDirectory:stageDirectory)
        // render-only startup may not have this tier's DET. Prepare ONLY it;
        // no REC compilation/dictionary/recognizer/RF/AOT demand is introduced.
        try HostResources.prepare(root:root,tier:selection.value.modelTier,renderOnly:true,detectorOnly:true)
        let cachedOnly = await requiresCachedProbability
        let result=try await ReaderOCRService.shared.ensureSourceProbability(original:original,
            configuration:selection.value,allowOneCurrentDetector:!cachedOnly)
        HostDump.captureJSONObject("render-db-capability",[
            "configurationAuthority":selection.authority,"required":true,
            "actualDetectorCalls":result.detectorCalls,"additionalRECRequestedByEnsure":false,
            "RECClaimAuthority":"shared ensure has no recognizer call; not an independent global model counter",
            "currentModelProducerAttested":true,
            "mapSHA256":result.probability.capability?.mapSHA256 ?? "",
            "observedConsumerSHA256":result.probability.capability?.consumerConfigurationSHA256 ?? "",
            "currentConsumerSHA256":result.currentConsumerConfigurationSHA256 ?? "",
            "historicalMapParityClaimed":false])
        return result
    }
}
