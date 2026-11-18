import Foundation

@main
enum NativeOperationalAppearanceSmoke {
    static func main() throws {
        let binding = Dictionary(uniqueKeysWithValues: NativeOperationalAppearance.bindingKeys.map {
            ($0, String(repeating: "a", count: 64))
        })
        let prediction: [String: Any] = [
            "fill": ["rgb": [20, 30, 40]], "outline": ["present": true, "rgb": [255, 255, 255], "widthPx": 2],
            "background": ["rgb": [240, 240, 240]],
            "shadow": ["present": true, "rgb": [80, 85, 90], "offsetPx": [2, 3], "opacity": NSNull(), "blurRadiusPx": NSNull()]
        ]
        let packet: [String: Any] = [
            "schema": "aidoku-live-source-appearance-v1", "binding": binding,
            "sourceOnly": true, "freshInference": true, "GTAtInference": false, "cachedPredictionsRead": false,
            "prediction": prediction
        ]
        let item: [String: Any] = ["id": "detected-owner", "text": "retained text", "fontSize": 22, "sourceBounds": [0.1, 0.2, 0.3, 0.4]]
        func apply(_ value: [String: Any], expected: [String: String]? = nil) throws -> [String: Any] {
            try NativeOperationalAppearance.apply(packet: JSONSerialization.data(withJSONObject: value),
                expectedBinding: expected ?? binding, to: item)
        }
        func rejects(_ value: [String: Any], expected: [String: String]? = nil) throws {
            do { _ = try apply(value, expected: expected) }
            catch { return }
            fatalError("Invalid live appearance was accepted")
        }
        let output = try apply(packet)
        precondition(output["id"] as? String == item["id"] as? String)
        precondition(output["text"] as? String == item["text"] as? String)
        precondition(output["fontSize"] as? Int == 22)
        precondition(output["ensembleDisplayFill"] as? [Double] == [20, 30, 40])
        let retained = output["sourceAppearance"] as! [String: Any]
        precondition((retained["shadow"] as! [String: Any])["opacity"] is NSNull)
        precondition((retained["background"] as! [String: Any])["rgb"] as? [Int] == [240, 240, 240])
        var changed = binding
        changed["rgbSHA256"] = String(repeating: "b", count: 64)
        try rejects(packet, expected: changed)
        changed = binding; changed.removeValue(forKey: "geometrySHA256")
        try rejects(packet, expected: changed)
        for field in ["sourceOnly", "freshInference", "GTAtInference", "cachedPredictionsRead"] {
            var invalid = packet; invalid[field] = !(packet[field] as! Bool)
            try rejects(invalid)
        }
        var invalid = packet, invalidPrediction = prediction
        invalidPrediction["fill"] = ["rgb": [20, 30, 900]]
        invalid["prediction"] = invalidPrediction
        try rejects(invalid)
        var contourPrediction = prediction
        contourPrediction["outline"] = ["present":true,"rgb":[221,90,5],"widthPx":3.0]
        contourPrediction["shadow"] = ["present":false]
        var contourPacket = packet; contourPacket["prediction"] = contourPrediction
        var contour = try apply(contourPacket); contour["sourceFontSize"] = 22.0
        precondition(NativeOperationalAppearance.sourceContourOnly(contour))
        for field in ["sourceContourPaintBinding", "sourceAppearanceBinding", "sourceFontSize"] {
            var missing = contour; missing.removeValue(forKey:field)
            precondition(!NativeOperationalAppearance.sourceContourOnly(missing))
        }
        var mismatch = contour; mismatch["sourceContourPaintBinding"] = changed
        precondition(!NativeOperationalAppearance.sourceContourOnly(mismatch))
        for (field, value) in [("renderSourceOutlineRGB", [220.0,90.0,5.0] as Any), ("renderSourceOutlineWidthPx", 3.5 as Any)] {
            var derived = contour; derived[field] = value
            precondition(!NativeOperationalAppearance.sourceContourOnly(derived))
        }
        var multi = contourPrediction
        multi["outline"] = ["present":true,"rgb":[221,90,5],"widthPx":3.0,
                            "observedLayers":[["rgb":[221,90,5],"widthPx":3.0],["rgb":[0,0,0],"widthPx":1.0]]]
        var invalidContour = contour; invalidContour["sourceAppearance"] = multi
        precondition(!NativeOperationalAppearance.sourceContourOnly(invalidContour))
        invalidContour = contour; invalidContour["sourceAppearance"] = prediction
        precondition(!NativeOperationalAppearance.sourceContourOnly(invalidContour))
        var member = contour; member["sourceStyleGroupID"] = "same-style"
        var peer = member; peer["id"] = "peer"
        precondition(NativeOperationalAppearance.annotateContourPolicies([member,peer]).allSatisfy {
            NativeOperationalAppearance.sourceContourOnly($0)
        })
        peer["renderSourceOutlineWidthPx"] = 3.5
        let blocked = NativeOperationalAppearance.annotateContourPolicies([member,peer])
        precondition(blocked.allSatisfy { !NativeOperationalAppearance.sourceContourOnly($0) })
        precondition(NSDictionary(dictionary:["items":blocked]).isEqual(to:["items":NativeOperationalAppearance.annotateContourPolicies(blocked)]))
        var independent = member; independent["sourceStyleGroupID"] = "separate-style"
        precondition(NativeOperationalAppearance.sourceContourOnly(NativeOperationalAppearance.annotateContourPolicies([member,peer,independent])[2]))
        print("Source contour cohorts: all qualified or all legacy; separate style remains independent")
        print("Bound source contour eligibility: fresh binding required; shadows, multiband and changed render overrides retain legacy")
        print("Native operational appearance: retained all source heads/owners/fonts, rejected stale/missing bindings and cached/GT packets")
    }
}
