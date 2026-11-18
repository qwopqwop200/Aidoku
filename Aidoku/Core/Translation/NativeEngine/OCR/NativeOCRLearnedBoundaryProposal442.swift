import Foundation

enum NativeOCRLearnedBoundaryProposal442 {
    struct Generator {
        let model: NativeOCRLearnedBoundaryModel442.Bundle
        init(data: Data) throws {
            enum Bad: Error { case schema }
            guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  object["schema"] as? String == "source-current72-pixel-residual-runtime-v1",
                  object["featureCount"] as? Int == 344,
                  object["targetNames"] as? [String] == ["normalLow","normalHigh","alongLow","alongHigh","angle"],
                  object["labelOrRowTablesIncluded"] as? Bool == false,
                  let q = object["trainingResidualQuantiles"] as? [[Double]],q.count == 5,
                  q.allSatisfy({ $0.count == 5 && $0.allSatisfy(\.isFinite) }) else { throw Bad.schema }
            self.model = try NativeOCRLearnedBoundaryModel442.Bundle(data:data)
        }
    }
}
