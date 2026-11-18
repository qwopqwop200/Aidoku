import CoreGraphics
import CryptoKit
import Foundation
@testable import Aidoku

/// Explicit injected composition input, NOT an actual DET prediction, package,
/// current neural-model attestation, recognition, or whole-page quality proof.
/// Never registers into production's global evidence/cache stores.
@available(iOS 18.0, *)
enum NativeDBCompositionFixture {
    enum Failure:Error {case sourceTooSmall}
    static func prepared(original:CGImage) throws -> NativeMainEnsemblePreparedDB {
        guard original.width>=32,original.height>=32 else {throw Failure.sourceTooSmall}
        let decoded=try NativeRFDETRSourceImage.decode(original)
        func sha(_ value:String)->String {
            SHA256.hash(data:Data(value.utf8)).map {String(format:"%02x",$0)}.joined()
        }
        let source=NativeMainEnsembleDBCapability.Source(canonicalIdentity:decoded.identity,
            detectorInputIdentity:sha("injected-rgb-fixture-input-v1|"+decoded.identity),
            width:original.width,height:original.height)
        let producer=NativeMainEnsembleDBCapability.Producer(
            modelResource:"INJECTED-COMPOSITION-FIXTURE-NO-NEURAL-MODEL",
            modelPackageSHA256:sha("no-package; deterministic32x32-zero-fixture-v1"),
            backend:"injected-test-data-not-model-proof",computeUnits:"none-no-prediction",
            preprocessABI:"injected-rgb-fixture-v1",preprocessSHA256:sha("fixture-declaration-only"),
            effectiveConfigurationSHA256:sha("fixture32x32-full-zero-grid-v1"),maximumSide:32,
            canvasWidth:32,canvasHeight:32,resizedWidth:32,resizedHeight:32)
        let values=[Float](repeating:0,count:32*32)
        let grid=NativeMainEnsembleDBCapability.Grid(sourceWidth:original.width,sourceHeight:original.height,
            resizedWidth:32,resizedHeight:32,regionX:0,regionY:0,regionWidth:32,regionHeight:32,
            width:32,height:32,values:values)
        // "live" describes locally generated fixture data, never a live model.
        let record=NativeMainEnsembleDBCapability.Record(source:source,producer:producer,grid:grid,
            mapSHA256:NativeMainEnsembleDBCapability.digest(values),origin:.live)
        let probability=NativeMainAOTRemovalMaskBuilder.SourceProbability(original:original,
            width:32,height:32,values:values,capability:record)
        return try .init(probability:probability,expected:.init(source:source,producer:producer),
            detectorCalls:0,lease:.init(release:{}))
    }
}
