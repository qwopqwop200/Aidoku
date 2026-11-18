import Foundation

/// Private explicit 376 ABI. Mean-only: no utility file, fake 344 alias, or offer bank.
/// Raw-only source ownership and numericV2 binding are mandatory file-boundary fields.
/// Feature extraction/typed Resolution belongs to agents4/2; no packet/provenance fallback here.
enum NativeOCRLearnedBoundaryGenerator376 {
    static let schema = "source-rgb-rfdet-owned-normal376-residual-runtime-v1"
    static let featureABI = "native-cg-geometric-baseline-v3-source344-plus-db-owned-normal32-v2-nested-candidates-f64-376"
    static let sourceDBNormalABI = "db-owned-normal32-v2-nested-candidates-f64"
    static let sourceOwnerResolutionABI = "current-raw-typed-producer-exactquad-owner-v1"
    static let sourceOwnerContextStage = "pre-learned-current-raw-and-precomputed-refinements-v1"
    static let sourceContextABI = "current-source-det12-rf32-text6-context50-v2-f32-to-f64"
    static let sourceRGBDecoderABI = "native-cgimage-opaque-srgb-white-rgba8-v2"
    static let baselineAssociationABI = "exact-coincident-corrected-baseline-agreement-v1"
    static let featureCount = 376
    enum Failure: Error { case invalidBinding, invalidModel }
    struct Prediction {
        let residual: [Double]
        let polygon: [[Double]]
        let internalOfferCount = 1
        let utilityInvoked = false
    }
    struct Model {
        let featureFreezeSHA256: String
        private let numerical: NativeOCRLearnedBoundaryNumericForest.Bundle
        /// expectedFeatureFreezeSHA256 must come from the independently sealed 376 manifest.
        /// Data/quality promotion is a separate caller decision; no per-row model selection.
        init(data: Data, expectedFeatureFreezeSHA256: String) throws {
            guard expectedFeatureFreezeSHA256.utf8.count == 64,
                  expectedFeatureFreezeSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidBinding
            }
            let fields: Set<String> = ["schema", "featureCount", "sourceFeatureABI", "sourceContextABI",
                "sourceDBNormalABI", "sourceRGBDecoderABI", "baselineAssociationABI", "sourceFeatureFreezeSHA256",
                "sourceOwnerResolutionABI", "sourceOwnerContextStage",
                "targetNames", "models", "trainingResidualQuantiles", "labelOrRowTablesIncluded"]
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == fields,
                  object["schema"] as? String == schema,
                  object["featureCount"] as? Int == featureCount,
                  object["sourceFeatureABI"] as? String == featureABI,
                  object["sourceContextABI"] as? String == sourceContextABI,
                  object["sourceDBNormalABI"] as? String == sourceDBNormalABI,
                  object["sourceOwnerResolutionABI"] as? String == sourceOwnerResolutionABI,
                  object["sourceOwnerContextStage"] as? String == sourceOwnerContextStage,
                  object["sourceRGBDecoderABI"] as? String == sourceRGBDecoderABI,
                  object["baselineAssociationABI"] as? String == baselineAssociationABI,
                  object["sourceFeatureFreezeSHA256"] as? String == expectedFeatureFreezeSHA256,
                  object["labelOrRowTablesIncluded"] as? Bool == false,
                  object["targetNames"] as? [String] == ["normalLow", "normalHigh", "alongLow", "alongHigh", "angle"],
                  let models = object["models"] as? [[String: Any]], models.count == 5,
                  let quantiles = object["trainingResidualQuantiles"] as? [[Double]], quantiles.count == 5,
                  quantiles.allSatisfy({ $0.count == 5 && $0.allSatisfy(\.isFinite) }) else {
                throw Failure.invalidModel
            }
            let forestFields: Set<String> = ["enabled", "fallbackPrediction", "featureNames", "format", "initialBias",
                "learningRate", "margin", "maximumDepth", "nodeFields", "trees"]
            for forest in models {
                guard Set(forest.keys).isSubset(of: forestFields), forest["enabled"] as? Bool == true,
                      forest["format"] as? String == "source-root-boundary435-regression-v1",
                      forest["featureNames"] as? [String] == (0..<featureCount).map({ "f\($0)" }) else {
                    throw Failure.invalidModel
                }
            }
            // No schema relabeling: numerical reader is feature-count parameterized.
            self.numerical = try .init(data: data, featureCount: featureCount)
            self.featureFreezeSHA256 = expectedFeatureFreezeSHA256
        }
        func predict(source376: [Double], current: [[Double]], frame: [Double]) -> Prediction? {
            guard let residual = numerical.predict(features: source376),
                  let polygon = NativeOCRLearnedBoundaryGeometry442.polygon(residual: residual, current: current, frame: frame) else {
                return nil
            }
            return .init(residual: residual, polygon: polygon)
        }
        /// Pure numerical parity hook; availability0 rows remain legitimate inputs.
        func mean(source376: [Double]) -> [Double]? { numerical.predict(features: source376) }
    }
}
