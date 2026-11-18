import CryptoKit
import Foundation

/// One builder used by metadata expectation AND actual detector emission.
/// Actual emission receives its own actual prepared tensor/loaded predictor,
/// never a caller's expected key or a historical trace with new defaults.
@available(iOS 18.0, *)
enum NativeCoreMLDBProvenance {
    struct Expectation: Sendable {
        let producer: NativeMainEnsembleDBCapability.Producer
        let detectorInputIdentity: String
        let consumerConfigurationSHA256: String
    }
    static func sha(_ string:String)->String {
        SHA256.hash(data:Data(string.utf8)).map {String(format:"%02x",$0)}.joined()
    }
    static func consumerConfigurationSHA256(configuration:NativeCoreMLDBPostprocessConfiguration,
                                            maximumSide:Int,mainMangaPolicy:Bool)->String {
        let c=configuration
        let configurationParts=[String(c.threshold.bitPattern),String(c.boxThreshold.bitPattern),
            String(c.unclipRatio.bitPattern),String(c.maximumCandidates),String(c.minimumBoxSide.bitPattern),
            c.recoveryBoxThreshold.map {String($0.bitPattern)} ?? "nil",String(maximumSide),String(mainMangaPolicy)]
        return sha(configurationParts.joined(separator:"|"))
    }
    static func producer(resource:String,packageSHA256:String,computeUnits:String,
                         prepared:NativeCoreMLDetectionPreparedTensor)
        -> NativeMainEnsembleDBCapability.Producer {
        let rawContract="raw-db-v1|x:float32:1x3x"+String(prepared.canvas.height)+"x"+String(prepared.canvas.width)+"|fetch_name_0|source-grid-float32"
        return .init(modelResource:resource,modelPackageSHA256:packageSHA256,
            backend:"CoreML|"+ProcessInfo.processInfo.operatingSystemVersionString,
            computeUnits:computeUnits,preprocessABI:NativeCoreMLDetectionPreprocessor.provenanceABI,
            preprocessSHA256:NativeCoreMLDetectionPreprocessor.normalizationConfigurationSHA256,
            effectiveConfigurationSHA256:sha(rawContract),
            maximumSide:max(prepared.canvas.width,prepared.canvas.height),canvasWidth:prepared.canvas.width,
            canvasHeight:prepared.canvas.height,resizedWidth:prepared.resizedWidth,resizedHeight:prepared.resizedHeight)
    }
}
